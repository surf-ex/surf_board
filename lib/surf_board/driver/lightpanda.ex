defmodule SurfBoard.Driver.Lightpanda do
  @moduledoc false

  # Lightpanda over CDP. Three ways to get a connection, as three
  # entry points on this one module rather than three separate driver
  # modules: they fail differently (`validate_shared/0` checks a
  # running shared instance, `validate_isolated/0` checks the
  # `lightpanda` package is loaded, connecting has nothing to
  # validate at all — the caller already has a URL) and supervise
  # different things (a shared binary; nothing persistent at all —
  # every session spawns or dials fresh), but everything downstream of
  # "I have a ws_url" — spec/0, the session template, post-connection
  # setup, the User-Agent-unsupported warning — is identical, so it
  # isn't duplicated: it lives once, here.
  #
  #   * `start_link/1` — launches and owns a local Lightpanda process
  #     that every `start_session/2` call against it multiplexes over
  #     (fresh WS per session, fused actor, no extra hop — Lightpanda
  #     accepts many WS to one binary, so nothing is cached; the
  #     shared binary's ws_url is looked up fresh every call):
  #
  #       {:ok, _sup} = Driver.Lightpanda.start_link(name: MyApp.TestLightpanda)
  #       {:ok, session} = Driver.Lightpanda.start_session(MyApp.TestLightpanda, [])
  #
  #   * `spawn_session/1` — spawns a brand-new private Lightpanda
  #     binary for just this one session, starts it, and kills it on
  #     teardown. The slowest way to get a session (pays binary-startup
  #     cost every time) but the most isolated (no contention with any
  #     other session). Uses `SurfBoard.Clients.CDP.Acquire.fresh_ws/3`
  #     for the target/attach sequence and `Clients.CDP.SessionBringUp`
  #     for the rest — the pieces of CDP session bring-up genuinely
  #     shared with `Driver.ChromeCDP`'s own connection logic (a
  #     different `Acquire` shape, same module and `SessionBringUp`).
  #
  #   * `connect_session/2` — connects to a Lightpanda instance this
  #     driver never launches at all, given its `ws_url` directly.
  #     Uses the same `start_session_acquired/3` bring-up as
  #     `spawn_session/1` — the only difference is whether there's a
  #     process to spawn and later kill.

  alias SurfBoard.DependencyError
  alias SurfBoard.Clients.CDP.Acquire
  alias SurfBoard.Clients.CDP.Client, as: CDPClient
  alias SurfBoard.Clients.CDP.SessionBringUp
  alias SurfBoard.Clients.Dialogs
  alias SurfBoard.Driver.Spec
  alias SurfBoard.Clients.Frames
  alias SurfBoard.Launcher.{Metadata, UserAgent}
  alias SurfBoard.Transport.WebSocket
  alias SurfBoard.Clients.Windows

  @base_user_agent "Lightpanda/1.0"

  @lightpanda_server Module.concat([Lightpanda, Server])

  # Lightpanda's engine doesn't support any of CDP's optional
  # capabilities reliably enough to trust — overrides every one of
  # CDPClient.default_strategies/0's picks. Computed at runtime, not in
  # a module attribute — see Driver.ChromeCDP.spec/0's comment for why.
  def spec do
    struct!(
      Spec,
      Map.merge(CDPClient.default_strategies(), %{
        wire_protocol: CDPClient,
        dialogs: Dialogs.Unsupported,
        windows: Windows.Single,
        frames: Frames.Unsupported,
        grant_permissions: nil,
        send_keys_session: nil,
        touch_scroll: nil,
        log_check_interactions?: false,
        native_click_await?: true
      })
    )
  end

  # ----- Reuse an already-running shared Lightpanda binary -----

  defmodule Supervised do
    @moduledoc false
    # Owns the shared Lightpanda binary (`Lightpanda.Server`) as its
    # one child — session start needs no worker of its own here: this
    # entry point caches no connection state (each session opens its
    # own WS fresh, see `start_session/2`), so there's nothing for a
    # second child to hold.
    use Supervisor

    alias SurfBoard.Driver.Lightpanda

    def start_link({name, _opts}) do
      Supervisor.start_link(__MODULE__, name, name: Lightpanda.supervisor_name(name))
    end

    @impl Supervisor
    def init(name) do
      Lightpanda.resolve_binary_path()
      server_name = Lightpanda.server_name(name)

      server_opts = [
        name: server_name,
        extra_args: Lightpanda.server_args(),
        wrapper_script: Lightpanda.wrapper_script()
      ]

      Supervisor.init([{Lightpanda.server_module(), server_opts}], strategy: :one_for_one)
    end
  end

  @default_name __MODULE__.Default

  @doc """
  Launches and owns a local Lightpanda process that every session
  multiplexes over. `:name` defaults to this driver's default instance
  name (what `start_session/1` looks up), so `start_link([])` — or a
  bare `Driver.Lightpanda` in a children list, which resolves to
  `child_spec([])` — spawns and registers *the* default instance
  (assuming the optional `lightpanda` package is on the load path; see
  `maybe_default_child_spec/0` if you want that checked for you rather
  than raised on). Pass your own `:name` to own a second, independent
  instance instead. The returned pid is this construct's Supervisor,
  useful only for putting it under your own supervision tree.
  """
  @spec start_link(keyword) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, @default_name)
    Supervised.start_link({name, opts})
  end

  @doc """
  A child spec for this driver, meant to be added to a supervision
  tree the normal way — bare `SurfBoard.Driver.Lightpanda` (or
  `{SurfBoard.Driver.Lightpanda, []}`) spawns and owns the default
  instance; `{SurfBoard.Driver.Lightpanda, name: MyApp.TestLightpanda}`
  spawns and owns a separate, independently-named one. Unlike
  `maybe_default_child_spec/0`, this doesn't check whether the
  optional `lightpanda` package is loaded first — `start_link/1` (and
  so this) will raise if it isn't. Use `maybe_default_child_spec/0`
  instead if you want that checked for you, with `nil` (nothing to
  start) instead of a raise when the package is missing.
  """
  def child_spec(opts) do
    name = Keyword.get(opts, :name, @default_name)

    %{
      id: name,
      start: {__MODULE__, :start_link, [Keyword.put(opts, :name, name)]},
      type: :supervisor
    }
  end

  @doc false
  def supervisor_name(name), do: Module.concat(name, Supervisor)
  @doc false
  def server_name(name), do: Module.concat(name, Server)
  @doc false
  def server_module, do: @lightpanda_server

  # Lightpanda's --cdp-max-connections defaults to 16, which gets hit
  # at mc=16 plus a few session-isolation tests creating extra sessions.
  @cdp_max_connections 24

  @doc false
  def server_args do
    ["--cdp-max-connections", Integer.to_string(@cdp_max_connections)] ++ user_agent_args()
  end

  @doc false
  def wrapper_script do
    Path.absname("priv/run_command.sh", Application.app_dir(:surf_board))
  end

  # `config :surf_board, user_agent: "..."` is the cross-driver setting; it
  # arrives here as a `--user-agent` flag because Lightpanda's UA is a
  # property of the *process*, not of a CDP session — every session on the
  # shared binary shares it. (The Chrome driver reads the same config key
  # per session.)
  #
  # `:lightpanda_user_agent_suffix` has no Chrome equivalent, so it stays
  # driver-specific: it appends to `Lightpanda/X.Y` rather than replacing
  # it, which keeps the browser identifiable while naming your crawler.
  # Lightpanda documents `--user-agent` as refusing to impersonate other
  # browsers (values containing "Mozilla"), though 0.3.6 doesn't enforce it.
  defp user_agent_args do
    ua = UserAgent.configured()
    suffix = Application.get_env(:surf_board, :lightpanda_user_agent_suffix)

    cond do
      ua && suffix ->
        raise ArgumentError, """
        :user_agent and :lightpanda_user_agent_suffix are mutually exclusive \
        — Lightpanda rejects --user-agent together with --user-agent-suffix. \
        Set one or the other.
        """

      ua ->
        ["--user-agent", ua]

      suffix ->
        ["--user-agent-suffix", suffix]

      true ->
        []
    end
  end

  # Make `SurfBoard.Launcher.BrowserPaths` authoritative for Lightpanda's binary
  # location, mirroring how Chrome resolves through it. We translate the
  # resolved path into `config :lightpanda, :path`, which
  # `Lightpanda.bin_path/0` honors at the top of its precedence.
  #
  # An explicitly-configured `:path` (the dev sibling checkout) wins —
  # we never overwrite it. When BrowserPaths resolves nothing (no env
  # override, no `LIGHTPANDA=` line), we leave config untouched so the
  # package's own resolution (`:install_dir` → `.browsers/`, else
  # `_build/`) applies.
  @doc false
  def resolve_binary_path do
    if is_nil(Application.get_env(:lightpanda, :path)) do
      case SurfBoard.Launcher.BrowserPaths.lightpanda_path() do
        {:ok, path} -> Application.put_env(:lightpanda, :path, path)
        :error -> :ok
      end
    end
  end

  @doc """
  A child spec for this driver's default instance that checks the
  optional `lightpanda` package is loaded first, returning `nil`
  (nothing to start) rather than raising if it isn't — unlike
  `child_spec/1`/`{Driver.Lightpanda, []}`, which assume you already
  know the package is available and let `start_link/1` raise if not.
  Meant to be added to a supervision tree only when you want that
  "skip silently if unavailable" behavior (see
  `integration_test/support/driver_supervisor.ex` for the pattern this
  project's own test suite uses).
  """
  def maybe_default_child_spec do
    if Code.ensure_loaded?(@lightpanda_server) do
      {__MODULE__, name: @default_name}
    end
  end

  @doc false
  def default_name, do: @default_name

  @doc """
  Checks whether `start_link/1` can actually succeed — the `lightpanda`
  package is loaded — without starting anything. Returns
  `:ok | {:error, %SurfBoard.DependencyError{}}`.
  """
  @spec validate_shared() :: :ok | {:error, DependencyError.t()}
  def validate_shared, do: validate_package_loaded()

  @doc """
  Checks whether `spawn_session/1` can actually succeed — the
  `lightpanda` package is loaded — without starting anything. Returns
  `:ok | {:error, %SurfBoard.DependencyError{}}`.
  """
  @spec validate_isolated() :: :ok | {:error, DependencyError.t()}
  def validate_isolated, do: validate_package_loaded()

  defp validate_package_loaded do
    if Code.ensure_loaded?(@lightpanda_server) do
      :ok
    else
      {:error,
       DependencyError.exception(
         "Lightpanda not found. Add the `lightpanda` package as a dependency."
       )}
    end
  end

  @doc """
  Starts a new session against `name` — the name a `start_link/1`
  instance was registered under (not a pid: `server_name/1` derives
  the underlying `Lightpanda.Server`'s own registered name from it,
  which needs the atom you passed to `start_link(name: ...)`, not a
  pid).

  One actor per session, owning its own raw WS directly against the
  shared binary — no separate WebSocket process, no caching
  (Lightpanda accepts many WS to one binary, so every call resolves
  ws_url fresh).
  """
  @spec start_session(atom, keyword) :: {:ok, SurfBoard.Session.t()} | {:error, term}
  def start_session(name, opts) when name != nil and is_list(opts) do
    server_name = server_name(name)

    case Process.whereis(server_name) do
      nil ->
        {:error, :shared_server_not_running}

      _pid ->
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        ws_url = apply(@lightpanda_server, :ws_url, [server_name])
        start_session_fused(ws_url, opts)
    end
  end

  @doc """
  Starts a session against this driver's default *shared* instance
  (see `child_spec/1`/`maybe_default_child_spec/0`).
  """
  @spec start_session(keyword) :: {:ok, SurfBoard.Session.t()} | {:error, term}
  def start_session(opts) when is_list(opts) do
    start_session(@default_name, opts)
  end

  defp start_session_fused(ws_url, opts) do
    template = build_template(opts)
    teardown_fun = fn _ -> :ok end
    owner = Keyword.get(opts, :owner, self())

    actor_config = %SurfBoard.Transport.Actor.Config{
      socket: {:fused, ws_url},
      load: :buffer,
      wire: SurfBoard.Clients.CDP.Wire
    }

    with {:ok, session} <-
           SurfBoard.Transport.Actor.start_link(
             config: actor_config,
             init_fun: fn -> {:ok, template} end,
             teardown_fun: teardown_fun,
             owner: owner
           ),
         {:ok, %{"targetId" => target_id}} <-
           CDPClient.cdp_send(session, "Target.createTarget", %{url: "about:blank"}),
         {:ok, %{"sessionId" => session_id}} <-
           CDPClient.cdp_send(session, "Target.attachToTarget", %{
             targetId: target_id,
             flatten: true
           }) do
      session = update_session_for_target(session, session_id, target_id)

      :ok = CDPClient.enable_page_lifecycle_events(session)
      :ok = CDPClient.install_bootstrap(session)
      :ok = CDPClient.enable_frame_tracking(session)

      post_start(session, opts)
    end
  end

  defp update_session_for_target(%SurfBoard.Session{} = session, session_id, target_id) do
    GenServer.call(session.pid, {:update_browsing_context, session_id, target_id})

    %{
      session
      | browsing_context: session_id,
        driver_state: %{session.driver_state | target_id: target_id}
    }
  end

  # ----- Spawn a brand-new private Lightpanda binary per session -----

  @doc """
  Spawns a fresh, private Lightpanda binary and starts a session
  against it. Fails with `{:error, :lightpanda_package_not_loaded}` if
  the `lightpanda` package isn't on the load path.
  """
  @spec spawn_session(keyword) :: {:ok, SurfBoard.Session.t()} | {:error, term}
  def spawn_session(opts \\ []) do
    if Code.ensure_loaded?(@lightpanda_server) do
      start_link_args = [[name: nil, wrapper_script: wrapper_script()]]
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      {:ok, server_pid} = apply(@lightpanda_server, :start_link, start_link_args)

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      ws_url = apply(@lightpanda_server, :ws_url, [server_pid])
      start_session_acquired(ws_url, server_pid, opts)
    else
      {:error, :lightpanda_package_not_loaded}
    end
  end

  defp stop_server(pid) do
    try do
      GenServer.stop(pid, :normal, 5_000)
    catch
      _, _ -> :ok
    end

    :ok
  end

  # ----- Connect to a Lightpanda instance this driver never launches -----

  @doc """
  Connects to a Lightpanda instance at `ws_url` and starts a session
  against it. Nothing to spawn, nothing to kill on teardown — that's
  the only real difference from `spawn_session/1`, which shares this
  function's bring-up sequence.
  """
  @spec connect_session(String.t(), keyword) :: {:ok, SurfBoard.Session.t()} | {:error, term}
  def connect_session(ws_url, opts \\ []) when is_binary(ws_url) do
    start_session_acquired(ws_url, nil, opts)
  end

  # A fresh WebSocket per session, and (for spawn_session/1) a fresh
  # browser process to go with it. Uses `Acquire.fresh_ws/3` — the
  # target/attach sequence genuinely shared with `Driver.ChromeCDP`'s
  # own :isolated-shaped acquisition — plus `SessionBringUp` for the
  # shared second half.
  #
  # Note: unlike Chrome, this is Lightpanda-only, whose partial CDP
  # implementation may not support Target.setDiscoverTargets — not
  # sent here (`Acquire.fresh_ws/3` doesn't send it either), so
  # Target.detachedFromTarget won't fire for Lightpanda sessions.
  defp start_session_acquired(ws_url, server_pid, opts) do
    template = build_template(opts)
    extra_driver_state = %SurfBoard.Transport.DriverState{server_pid: server_pid}
    on_close = if is_pid(server_pid), do: fn -> stop_server(server_pid) end

    case WebSocket.start_link(ws_url) do
      {:ok, ws_pid} ->
        case Acquire.fresh_ws(ws_pid, extra_driver_state, on_close) do
          {:ok, acquired} ->
            with {:ok, session} <- SessionBringUp.start_session_from(acquired, template, opts) do
              post_start(session, opts)
            end

          err ->
            # Failed mid-bring-up: kill the spawned binary (if any) so
            # we don't leak a Lightpanda process per failed session.
            if is_pid(server_pid), do: stop_server(server_pid)
            err
        end

      err ->
        if is_pid(server_pid), do: stop_server(server_pid)
        err
    end
  end

  # ----- Shared across all three entry points -----

  defp build_template(opts) do
    %SurfBoard.Session{
      id: "lightpanda-#{System.unique_integer([:positive])}",
      url: "about:blank",
      session_url: "about:blank",
      spec_module: __MODULE__,
      spec: spec(),
      live_view_aware?: Keyword.get(opts, :live_view_aware, false),
      driver_state: %SurfBoard.Transport.DriverState{
        flat_session_id?: true,
        # Lightpanda's JS engine doesn't ship a real document.evaluate
        # — CDPClient.visit injects wgxpath after each page load.
        needs_xpath_polyfill?: true
      }
    }
  end

  defp post_start(session, opts) do
    metadata = Keyword.get(opts, :metadata)

    if Keyword.has_key?(opts, :user_agent), do: warn_user_agent_unsupported()

    if metadata do
      _ =
        CDPClient.cdp_send(session, "Network.setUserAgentOverride", %{
          userAgent: Metadata.append(@base_user_agent, metadata)
        })
    end

    if window_size = Keyword.get(opts, :window_size) do
      _ = CDPClient.set_window_size(session, window_size[:width], window_size[:height])
    end

    # `:base_url`/`:max_wait_time` govern later calls rather than
    # session startup, so they ride on the session — that way an
    # application's own session isn't governed by whatever a test
    # suite configured globally.
    session_opts = Keyword.take(opts, [:base_url, :max_wait_time])
    {:ok, %{session | session_opts: session_opts}}
  end

  # Lightpanda accepts `Network.setUserAgentOverride` and returns
  # `{:ok, %{}}`, but the UA it actually sends is unchanged — so a caller
  # passing `:user_agent` would otherwise be silently ignored. Its UA is a
  # process-level setting instead (see `user_agent_args/0`). Warn once per
  # VM (this driver is one module now, regardless of connection mode, so
  # one persistent_term key genuinely means once per VM) rather than per
  # session, so a crawl doesn't flood the log.
  @warned_ua_key {__MODULE__, :warned_user_agent_unsupported}

  defp warn_user_agent_unsupported do
    unless :persistent_term.get(@warned_ua_key, false) do
      :persistent_term.put(@warned_ua_key, true)

      require Logger

      Logger.warning("""
      [surf_board] the :user_agent session option has no effect on the \
      Lightpanda driver — it ignores Network.setUserAgentOverride and will \
      keep reporting #{@base_user_agent}.

      Lightpanda sets its User-Agent per process, not per session, so set it \
      for the whole browser instead — this works on every driver:

          config :surf_board, user_agent: "MyScraper/1.0 (+https://…)"

          # or append to Lightpanda/X.Y rather than replacing it:
          config :surf_board, lightpanda_user_agent_suffix: "MyScraper/1.0"

      A per-session User-Agent (two different UAs at once) needs Chrome:

          SurfBoard.Driver.ChromeCDP.start_session(user_agent: "...")
      """)
    end

    :ok
  end
end
