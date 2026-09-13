defmodule SurfBoard.Driver.Lightpanda do
  @moduledoc false

  # Lightpanda over CDP.
  #
  # Two named constructors, mirroring ChromeCDP's shape:
  #
  #   * `start_link/1` — launches and owns a local Lightpanda process,
  #     multiplexing every session over it (`Strategy.PerSession` — one
  #     shared binary, one fresh WebSocket per session). This is a
  #     Supervisor (not the launcher itself): it owns a
  #     `Lightpanda.Server` and a `Launcher` as its two children, same
  #     crash-restart guarantee this driver's own default launcher gets.
  #     The launcher child is registered under the `:name` you asked
  #     for — that name (not this Supervisor's pid) is what you use
  #     afterward:
  #
  #       {:ok, _sup} = Driver.Lightpanda.start_link(name: MyApp.TestLightpanda)
  #       {:ok, session} = Launcher.start_session(MyApp.TestLightpanda)
  #
  #   * `connect/1` — connects to a Lightpanda instance you don't
  #     manage, via `:url` (a literal ws(s):// URL — no /json/version
  #     discovery; Lightpanda doesn't expose that endpoint). Nothing to
  #     spawn, nothing to supervise.
  #
  # `Strategy.IsolatedProcess` (a fresh private Lightpanda process per
  # session, no persistent process to own) doesn't fit either shape —
  # it's neither "launch and own one process" nor "dial an existing
  # url" — so it has no dedicated constructor here; `start_via_isolated/2`
  # builds it directly.
  #
  # Both `start_link/1` and `connect/1` build a real, working
  # Lightpanda session on their own — this is the one place a
  # %SurfBoard.Session{} template for this driver gets built
  # (`build_template/1`) and finished (`post_start/2`: the BEAM sandbox
  # metadata UA, window size, :user_agent-unsupported warning).
  # Pass your own `:build_template`/`:post_start` to either constructor
  # to override these defaults entirely.

  @behaviour SurfBoard.Driver

  alias SurfBoard.DependencyError
  alias SurfBoard.Clients.CDP.Client, as: CDPClient
  alias SurfBoard.Clients.Dialogs
  alias SurfBoard.Driver.Spec
  alias SurfBoard.Clients.Frames
  alias SurfBoard.Launcher.{Metadata, UserAgent}
  alias SurfBoard.Launcher
  alias SurfBoard.Transport.Strategy.{IsolatedProcess, PerSession}
  alias SurfBoard.Clients.Windows

  @base_user_agent "Lightpanda/1.0"

  @lightpanda_server Module.concat([Lightpanda, Server])

  # Lightpanda's engine doesn't support any of CDP's optional
  # capabilities reliably enough to trust — overrides every one of
  # CDPClient.default_strategies/0's picks. Computed at runtime, not in
  # a module attribute — see Driver.ChromeCDP.spec/0's comment for why.
  @impl SurfBoard.Driver
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
    # The actual Supervisor behind `start_link/1` — split into its own
    # module for the same reason as `ChromeCDP.Supervised`: keeps this
    # module itself a plain module of functions, matching `connect/1`'s
    # shape.
    use Supervisor

    alias SurfBoard.Driver.Lightpanda

    def start_link({name, opts}) do
      Supervisor.start_link(__MODULE__, {name, opts}, name: Lightpanda.supervisor_name(name))
    end

    @impl Supervisor
    def init({name, opts}) do
      Lightpanda.resolve_binary_path()
      server_name = Lightpanda.server_name(name)

      launcher_opts = [
        name: name,
        strategy: PerSession,
        build_template: Keyword.get(opts, :build_template, &Lightpanda.build_template/1),
        post_start: Keyword.get(opts, :post_start, &Lightpanda.post_start/2),
        config: %PerSession.Config{
          # credo:disable-for-next-line Credo.Check.Refactor.Apply
          resolve_ws_url: fn -> apply(Lightpanda.server_module(), :ws_url, [server_name]) end
        }
      ]

      server_opts = [
        name: server_name,
        extra_args: Lightpanda.server_args(),
        wrapper_script: Lightpanda.wrapper_script()
      ]

      children = [
        {Lightpanda.server_module(), server_opts},
        {Launcher, launcher_opts}
      ]

      Supervisor.init(children, strategy: :one_for_one)
    end
  end

  @doc """
  Launches and owns a local Lightpanda process, wrapped in a `Launcher`
  that multiplexes every session over it. Requires `:name` — the
  registered name of the `Launcher` child, and what you pass to
  `Launcher.start_session/2` (or `SurfBoard.start_session(launcher: ...)`)
  afterward. The returned pid is this construct's Supervisor, useful
  only for putting it under your own supervision tree.
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

  @doc """
  Connects to a Lightpanda instance this doesn't manage, wrapped in a
  `Launcher` — no process to spawn, no Supervisor. `:url` is required:
  a literal ws(s):// URL. Pass `:name` to register the launcher;
  omitted, you get an anonymous pid back.
  """
  @spec connect(keyword) :: Agent.on_start()
  def connect(opts) do
    launcher_opts =
      [
        strategy: IsolatedProcess,
        config: %IsolatedProcess.Config{ws_url: Keyword.fetch!(opts, :url)},
        build_template: Keyword.get(opts, :build_template, &build_template/1),
        post_start: Keyword.get(opts, :post_start, &post_start/2)
      ] ++ Keyword.take(opts, [:name])

    Launcher.start_link(launcher_opts)
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

  # ----- Default launcher -----
  #
  # Starts a single shared Lightpanda binary if the package is on the
  # load path (via `start_link/1`). Sessions multiplex over this binary
  # by opening their own WebSocket against its URL
  # (Transport.Strategy.PerSession). Falls back to per-session binary
  # spawn (Transport.Strategy.IsolatedProcess) if no shared server is
  # running.

  @default_launcher_name __MODULE__.DefaultLauncher

  @impl SurfBoard.Driver
  def default_launcher_spec do
    if Code.ensure_loaded?(@lightpanda_server) do
      {__MODULE__, name: @default_launcher_name}
    else
      SurfBoard.Launcher.Noop.child_spec(id: __MODULE__)
    end
  end

  @impl SurfBoard.Driver
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

  @impl SurfBoard.Driver
  def cleanup_stale_sessions, do: :ok

  # ----- Session lifecycle -----

  # `:connection` picks which of the three ways a session gets its
  # Lightpanda transport — the (launch, socket, process-model)
  # combination underneath this driver:
  #
  #   * `:shared`   — reuse the already-running shared Lightpanda
  #                   binary (started once, lazily, iff the `lightpanda`
  #                   package is loaded, via `start_link/1` — see
  #                   `default_launcher_spec/0`). Fresh WS per session,
  #                   fused actor (no extra hop). Fails with
  #                   `{:error, :shared_server_not_running}` if
  #                   explicitly requested but nothing is up.
  #   * `:isolated` — spawn a brand-new private Lightpanda binary for
  #                   just this session. Slower (pays binary startup
  #                   every call) but fully isolated. Requires the
  #                   `lightpanda` package; fails with
  #                   `{:error, :lightpanda_package_not_loaded}` if it
  #                   isn't on the load path.
  #   * `:external` — connect to a Lightpanda instance this driver never
  #                   launches at all, via a caller-supplied `:ws_url`
  #                   (`connect/1`). Requires `:ws_url` in opts; fails
  #                   with `{:error, :ws_url_required}` otherwise.
  #
  # Omitted (the default): auto-detect, in priority order — an
  # explicit `:ws_url` wins (implies `:external`); else reuse the
  # shared server if one is running (`:shared`); else spawn a private
  # one if the package is available (`:isolated`); else raise, since
  # there is no way to get a Lightpanda connection at all.
  @impl SurfBoard.Driver
  def start_session(opts \\ []) do
    case resolve_connection(opts) do
      {:ok, fun} -> fun.(opts)
      {:error, _reason} = err -> err
    end
  end

  defp resolve_connection(opts) do
    case Keyword.get(opts, :connection) do
      nil -> {:ok, auto_detect_connection(opts)}
      :shared -> shared_connection(opts)
      :isolated -> isolated_connection(opts)
      :external -> external_connection(opts)
    end
  end

  defp auto_detect_connection(opts) do
    cond do
      Keyword.has_key?(opts, :ws_url) ->
        {:ok, fun} = external_connection(opts)
        fun

      Process.whereis(@default_launcher_name) ->
        {:ok, fun} = shared_connection(opts)
        fun

      Code.ensure_loaded?(@lightpanda_server) ->
        {:ok, fun} = isolated_connection(opts)
        fun

      true ->
        raise "Driver.Lightpanda requires either a :ws_url opt or the `lightpanda` package on the path"
    end
  end

  defp shared_connection(_opts) do
    case Process.whereis(@default_launcher_name) do
      nil -> {:error, :shared_server_not_running}
      _pid -> {:ok, &Launcher.start_session(@default_launcher_name, &1)}
    end
  end

  defp isolated_connection(_opts) do
    if Code.ensure_loaded?(@lightpanda_server) do
      config = %IsolatedProcess.Config{
        spawn_fun: fn ->
          # credo:disable-for-next-line Credo.Check.Refactor.Apply
          apply(@lightpanda_server, :start_link, [
            [name: nil, wrapper_script: wrapper_script()]
          ])
        end,
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        url_fun: fn server -> apply(@lightpanda_server, :ws_url, [server]) end
      }

      {:ok, &start_via_isolated(&1, config)}
    else
      {:error, :lightpanda_package_not_loaded}
    end
  end

  defp external_connection(opts) do
    case Keyword.get(opts, :ws_url) do
      url when is_binary(url) ->
        {:ok,
         fn opts ->
           {:ok, launcher} = connect(url: url)
           result = Launcher.start_session(launcher, opts)
           Agent.stop(launcher)
           result
         end}

      _ ->
        {:error, :ws_url_required}
    end
  end

  # `:isolated` has no dedicated named constructor (see the moduledoc) —
  # build the raw `Launcher` wrapping `IsolatedProcess.Config` directly,
  # same shape `start_link/1`/`connect/1` themselves use internally,
  # with the same build_template/post_start defaults so a caller holding
  # this launcher (via opts[:launcher] on a future call) gets the same
  # standalone `Launcher.start_session/2` capability. Nothing is lost by
  # not keeping the launcher around past this one session's start —
  # IsolatedProcess caches no connection state on it.
  defp start_via_isolated(opts, config) do
    {:ok, launcher} =
      Launcher.start_link(
        strategy: IsolatedProcess,
        config: config,
        build_template: &build_template/1,
        post_start: &post_start/2
      )

    result = Launcher.start_session(launcher, opts)
    Agent.stop(launcher)
    result
  end

  @doc false
  def build_template(opts) do
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

  @doc false
  def post_start(session, opts) do
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

    {:ok, session}
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
