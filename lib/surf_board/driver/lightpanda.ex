defmodule SurfBoard.Driver.Lightpanda do
  @moduledoc false

  # Lightpanda over CDP. Three connection modes, each with its own
  # process-model shape — inlined directly here rather than behind a
  # shared `Strategy` module, since none of the three is genuinely
  # reused outside this driver:
  #
  #   * `:shared`   — reuse the already-running shared Lightpanda
  #                   binary (`start_link/1`'s `Supervised` tree,
  #                   started once, lazily, iff the `lightpanda`
  #                   package is loaded). Fresh WS per session, fused
  #                   actor (no extra hop) — see `shared_connection/1`.
  #                   No cached connection state needed: the shared
  #                   binary's `ws_url` is looked up fresh from
  #                   `Lightpanda.Server` on every call, since
  #                   Lightpanda accepts many WS to one binary.
  #   * `:isolated` — spawn a brand-new private Lightpanda binary for
  #                   just this session (`isolated_connection/1`). Uses
  #                   `SurfBoard.Clients.CDP.SessionBringUp` — the one
  #                   piece of CDP session bring-up genuinely shared
  #                   with `Driver.ChromeCDP`'s own connection logic
  #                   (see that module's `start_session/2`).
  #   * `:external` — connect to a Lightpanda instance this driver
  #                   never launches at all, via a caller-supplied
  #                   `:ws_url` (`external_connection/1`). Same
  #                   bring-up as `:isolated`, no process to spawn.
  #
  # `start_link/1` launches and owns a local Lightpanda process,
  # wrapped in a Supervisor (`Supervised`) — this driver's default,
  # started lazily under whichever supervisor the application chooses
  # (see `default_child_spec/0`).

  alias SurfBoard.DependencyError
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

  defmodule Supervised do
    @moduledoc false
    # Owns the shared Lightpanda binary (`Lightpanda.Server`) as its
    # one child — session start doesn't need a Launcher-equivalent
    # worker of its own here, unlike ChromeCDP: `:shared` mode caches
    # no connection state (each session opens its own WS fresh, see
    # `shared_connection/1`), so there's nothing for a second child to
    # hold.
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

  @doc """
  Launches and owns a local Lightpanda process that every `:shared`
  session multiplexes over. Requires `:name` — the name sessions look
  this instance up by (see `shared_connection/1`). The returned pid is
  this construct's Supervisor, useful only for putting it under your
  own supervision tree.
  """
  @spec start_link(keyword) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Supervised.start_link({name, opts})
  end

  def child_spec(opts) do
    %{
      id: Keyword.fetch!(opts, :name),
      start: {__MODULE__, :start_link, [opts]},
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
  # shared binary shares it. (The Chrome drivers read the same config key
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

  # ----- Default instance -----
  #
  # Starts a single shared Lightpanda binary if the package is on the
  # load path (via `start_link/1`). Sessions multiplex over this binary
  # by opening their own WebSocket against its URL (`:shared` mode).
  # Falls back to per-session binary spawn (`:isolated` mode) if no
  # shared server is running.

  @default_name __MODULE__.Default

  @doc """
  A child spec for this driver's default instance, meant to be started
  once, under whatever supervisor the application chooses. Returns
  `nil` if the optional `lightpanda` package isn't on the load path —
  there's nothing to start, and `:shared`/auto-detected sessions fall
  back to `:isolated` on their own (see `auto_detect_connection/1`).
  """
  def default_child_spec do
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
  @spec validate() :: :ok | {:error, DependencyError.t()}
  def validate do
    if Code.ensure_loaded?(@lightpanda_server) do
      :ok
    else
      {:error,
       DependencyError.exception(
         "Lightpanda not found. Add the `lightpanda` package as a dependency."
       )}
    end
  end

  # ----- Session lifecycle -----

  # `:connection` picks which of the three ways a session gets its
  # Lightpanda transport — see the moduledoc for what each mode does.
  #
  # Omitted (the default): auto-detect, in priority order — an
  # explicit `:ws_url` wins (implies `:external`); else reuse the
  # shared server if one is running (`:shared`); else spawn a private
  # one if the package is available (`:isolated`); else raise, since
  # there is no way to get a Lightpanda connection at all.
  @spec start_session(keyword) :: {:ok, SurfBoard.Session.t()} | {:error, term}
  def start_session(opts \\ []) do
    case Keyword.get(opts, :connection) do
      nil -> auto_detect_connection(opts)
      :shared -> shared_connection(opts)
      :isolated -> isolated_connection(opts)
      :external -> external_connection(opts)
    end
  end

  defp auto_detect_connection(opts) do
    cond do
      Keyword.has_key?(opts, :ws_url) ->
        external_connection(opts)

      Process.whereis(server_name(@default_name)) ->
        shared_connection(opts)

      Code.ensure_loaded?(@lightpanda_server) ->
        isolated_connection(opts)

      true ->
        raise "Driver.Lightpanda requires either a :ws_url opt or the `lightpanda` package on the path"
    end
  end

  # The default instance's Supervised tree only ever registers its
  # Lightpanda.Server child by name (server_name/1) — there's no
  # second, cached-state worker to also register under the bare
  # `name` (unlike ChromeCDP's default instance, which IS that
  # worker). Check for the server directly, not a name nothing
  # actually registers.
  defp shared_connection(opts) do
    server_name = server_name(@default_name)

    case Process.whereis(server_name) do
      nil ->
        {:error, :shared_server_not_running}

      _pid ->
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        ws_url = apply(@lightpanda_server, :ws_url, [server_name])
        start_session_per_session(ws_url, opts)
    end
  end

  # `:shared` mode: one actor per session, owning its own raw WS
  # directly against the shared binary — no separate WebSocket
  # process, no caching (Lightpanda accepts many WS to one binary, so
  # every call resolves ws_url fresh). Inlined from the old
  # `Strategy.PerSession` — genuinely only ever used here.
  defp start_session_per_session(ws_url, opts) do
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

  defp isolated_connection(opts) do
    if Code.ensure_loaded?(@lightpanda_server) do
      spawn_fun = fn ->
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(@lightpanda_server, :start_link, [[name: nil, wrapper_script: wrapper_script()]])
      end

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      url_fun = fn server -> apply(@lightpanda_server, :ws_url, [server]) end

      {:ok, server_pid} = spawn_fun.()
      start_session_isolated(url_fun.(server_pid), server_pid, opts)
    else
      {:error, :lightpanda_package_not_loaded}
    end
  end

  defp external_connection(opts) do
    case Keyword.get(opts, :ws_url) do
      url when is_binary(url) -> start_session_isolated(url, nil, opts)
      _ -> {:error, :ws_url_required}
    end
  end

  # `:isolated`/`:external` mode: a fresh browser process (if any) AND
  # a fresh WebSocket per session — the slowest model, but cleanest
  # isolation. Inlined from the old `Strategy.IsolatedProcess`, using
  # `SessionBringUp` for the shared second half (also used by
  # `Driver.ChromeCDP`).
  defp start_session_isolated(ws_url, server_pid, opts) do
    template = build_template(opts)

    with {:ok, ws_pid} <- WebSocket.start_link(ws_url),
         {:ok, %{"targetId" => target_id}} <-
           WebSocket.send_sync(ws_pid, "Target.createTarget", %{url: "about:blank"}),
         {:ok, session_id} <- CDPClient.attach_to_target(ws_pid, target_id) do
      # Note: unlike ChromeCDP's shared connection (real Chrome), this
      # is Lightpanda-only, whose partial CDP implementation may not
      # support Target.setDiscoverTargets — not sent here, so
      # Target.detachedFromTarget won't fire for Lightpanda sessions.
      teardown = fn _session ->
        CDPClient.close_ws(ws_pid)
        if is_pid(server_pid), do: stop_server(server_pid)
        :ok
      end

      acquired = %{
        ws_pid: ws_pid,
        target_id: target_id,
        session_id: session_id,
        browser_context_id: nil,
        teardown_fun: teardown,
        driver_state: %SurfBoard.Transport.DriverState{
          target_id: target_id,
          flat_session_id?: true,
          server_pid: server_pid
        }
      }

      with {:ok, session} <- SessionBringUp.start_session_from(acquired, template, opts) do
        post_start(session, opts)
      end
    else
      err ->
        # Failed mid-bring-up: kill the spawned binary so we don't leak
        # a Lightpanda process per failed session.
        if is_pid(server_pid), do: stop_server(server_pid)
        err
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
  # VM rather than per session, so a crawl doesn't flood the log.
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

          SurfBoard.start_session(driver: :chrome_cdp, user_agent: "...")
      """)
    end

    :ok
  end
end
