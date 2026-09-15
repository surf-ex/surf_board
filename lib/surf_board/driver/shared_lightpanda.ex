defmodule SurfBoard.Driver.SharedLightpanda do
  @moduledoc false

  # Lightpanda over CDP, reusing an already-running shared Lightpanda
  # binary (`start_link/1`'s `Supervised` tree). Fresh WS per session,
  # fused actor (no extra hop) — see `start_session/2`. No cached
  # connection state needed: the shared binary's `ws_url` is looked up
  # fresh from `Lightpanda.Server` on every call, since Lightpanda
  # accepts many WS to one binary.
  #
  # Fully self-contained on purpose — no shared module with
  # `Driver.IsolatedLightpanda`/`Driver.ExternalLightpanda` beyond
  # `SurfBoard.Clients.CDP.Client` (genuinely shared protocol code,
  # used by other drivers too). Reusing a persistent shared process is
  # a different enough job (nothing to spawn per session, no
  # bring-up-from-scratch sequence) that it's a fully separate driver,
  # not a branch inside one Lightpanda module.
  #
  #   {:ok, _sup} = Driver.SharedLightpanda.start_link(name: MyApp.TestLightpanda)
  #   {:ok, session} = Driver.SharedLightpanda.start_session(MyApp.TestLightpanda, [])

  alias SurfBoard.DependencyError
  alias SurfBoard.Clients.CDP.Client, as: CDPClient
  alias SurfBoard.Clients.Dialogs
  alias SurfBoard.Driver.Spec
  alias SurfBoard.Clients.Frames
  alias SurfBoard.Launcher.{Metadata, UserAgent}
  alias SurfBoard.Clients.Windows

  @base_user_agent "Lightpanda/1.0"

  @lightpanda_server Module.concat([Lightpanda, Server])

  # Lightpanda's engine doesn't support any of CDP's optional
  # capabilities reliably enough to trust — overrides every one of
  # CDPClient.default_strategies/0's picks. Computed at runtime, not in
  # a module attribute — see Driver.SharedChromeCDP.spec/0's comment
  # for why.
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
    # one child — session start needs no worker of its own here: this
    # driver caches no connection state (each session opens its own WS
    # fresh, see `start_session/2`), so there's nothing for a second
    # child to hold.
    use Supervisor

    alias SurfBoard.Driver.SharedLightpanda

    def start_link({name, _opts}) do
      Supervisor.start_link(__MODULE__, name, name: SharedLightpanda.supervisor_name(name))
    end

    @impl Supervisor
    def init(name) do
      SharedLightpanda.resolve_binary_path()
      server_name = SharedLightpanda.server_name(name)

      server_opts = [
        name: server_name,
        extra_args: SharedLightpanda.server_args(),
        wrapper_script: SharedLightpanda.wrapper_script()
      ]

      Supervisor.init([{SharedLightpanda.server_module(), server_opts}], strategy: :one_for_one)
    end
  end

  @doc """
  Launches and owns a local Lightpanda process that every session
  multiplexes over. Requires `:name` — the name sessions look this
  instance up by (see `start_session/2`). The returned pid is this
  construct's Supervisor, useful only for putting it under your own
  supervision tree.
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

  @default_name __MODULE__.Default

  @doc """
  A child spec for this driver's default instance, meant to be added
  to a supervision tree the normal way. Returns `nil` if the optional
  `lightpanda` package isn't on the load path — there's nothing to
  start.
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
  def start_session(server, opts) when server != nil and is_list(opts) do
    server_name = server_name(server)

    case Process.whereis(server_name) do
      nil ->
        {:error, :shared_server_not_running}

      _pid ->
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        ws_url = apply(@lightpanda_server, :ws_url, [server_name])
        start_session_from_ws(ws_url, opts)
    end
  end

  @doc """
  Starts a session against this driver's default instance (see
  `default_child_spec/0`).
  """
  @spec start_session(keyword) :: {:ok, SurfBoard.Session.t()} | {:error, term}
  def start_session(opts) when is_list(opts) do
    start_session(@default_name, opts)
  end

  defp start_session_from_ws(ws_url, opts) do
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

          SurfBoard.Driver.SharedChromeCDP.start_session(user_agent: "...")
      """)
    end

    :ok
  end
end
