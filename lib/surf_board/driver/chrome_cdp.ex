defmodule SurfBoard.Driver.ChromeCDP do
  @moduledoc false

  # Chrome over CDP — a `Strategy.SharedWS`-backed launcher (one shared
  # WebSocket for every session started against it), per-session
  # BrowserContext + Target + sessionId for routing.
  #
  # Two ways to get a connection, matched to how different the two cases
  # actually are underneath — not one function with a mode flag hiding
  # that difference:
  #
  #   * `start_link/1` — launches and owns a local Chrome process. This
  #     is a Supervisor (not a launcher itself): it owns a
  #     `Chrome.Server` and a `Launcher` as its two children, giving the
  #     spawned Chrome the same crash-restart guarantee this module's
  #     own default launcher gets. The launcher child is registered
  #     under the `:name` you asked for — that name (not this
  #     Supervisor's pid) is what you use afterward:
  #
  #       {:ok, _sup} = Driver.ChromeCDP.start_link(name: MyApp.TestChrome)
  #       {:ok, session} = Launcher.start_session(MyApp.TestChrome)
  #
  #   * `connect/1` — connects to a Chrome you don't manage, via `:url`
  #     (a literal ws(s):// URL, or a bare host:port DevTools endpoint
  #     discovered via /json/version). Nothing to spawn, nothing to
  #     supervise — it's a plain `Launcher.start_link/1` call under the
  #     hood, returning `{:ok, launcher_pid}` directly (or registering
  #     it under `:name` if given).
  #
  # `default_launcher_spec/0` picks between the two for this driver's
  # own default launcher, started lazily under `SurfBoard.DriverSupervisor`
  # on first use — the same choice a caller building their own launcher
  # makes directly via `start_link/1`/`connect/1`. Pass your own
  # `:build_template`/`:post_start` to either constructor to override
  # this driver's defaults entirely; pass `launcher:` to `start_session/1`
  # (or call `Launcher.start_session/2` on it directly) to use a
  # different launcher instead (e.g. an application connecting to a
  # remote Chrome while its own test suite launches and owns a second,
  # local one via `start_link/1`, both alive in the same BEAM).

  @behaviour SurfBoard.Driver

  alias SurfBoard.DependencyError
  alias SurfBoard.Clients.CDP.Client, as: CDPClient
  alias SurfBoard.Driver.Spec
  alias SurfBoard.Driver.Chrome.Server, as: ChromeServer
  alias SurfBoard.Launcher.{Metadata, UserAgent}
  alias SurfBoard.Launcher
  alias SurfBoard.Transport.Strategy.SharedWS

  @base_user_agent "Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 " <>
                     "(KHTML, like Gecko) Chrome/41.0.2228.0 Safari/537.36"

  # Full support for everything CDP offers — no overrides needed on
  # top of CDPClient.default_strategies/0. Computed at runtime, not in a
  # module attribute — calling CDPClient.default_strategies/0 at compile
  # time would put a (compile) edge from this module to CDPClient in
  # `mix xref graph`, coupling this driver's compilation to CDP client
  # internals for no benefit (spec/0 isn't called often enough to need
  # attribute-time precomputation).
  @impl SurfBoard.Driver
  def spec do
    struct!(
      Spec,
      Map.merge(CDPClient.default_strategies(), %{
        wire_protocol: CDPClient,
        touch_scroll: &__MODULE__.touch_scroll_impl/3,
        log_check_interactions?: true
      })
    )
  end

  defmodule Supervised do
    @moduledoc false
    # The actual Supervisor behind `start_link/1` — split into its own
    # module so this module itself stays a plain module of functions,
    # matching `connect/1`'s shape, rather than `use Supervisor` making
    # the whole module implicitly one.
    use Supervisor

    alias SurfBoard.Driver.ChromeCDP

    def start_link({name, opts}) do
      Supervisor.start_link(__MODULE__, {name, opts}, name: ChromeCDP.supervisor_name(name))
    end

    @impl Supervisor
    def init({name, opts}) do
      server_name = ChromeCDP.server_name(name)

      launcher_opts = [
        name: name,
        strategy: SharedWS,
        build_template: Keyword.get(opts, :build_template, &ChromeCDP.build_template/1),
        post_start: Keyword.get(opts, :post_start, &ChromeCDP.post_start/2),
        config: %SharedWS.Config{resolve_ws_url: fn -> ChromeServer.ws_url(server_name) end}
      ]

      children = [
        {ChromeServer, [name: server_name]},
        {Launcher, launcher_opts}
      ]

      Supervisor.init(children, strategy: :one_for_one)
    end
  end

  @doc """
  Launches and owns a local Chrome process, wrapped in a `Launcher`.
  Requires `:name` — the registered name of the `Launcher` child, and
  what you pass to `Launcher.start_session/2` (or
  `SurfBoard.start_session(launcher: ...)`) afterward. The returned pid
  is this construct's Supervisor, useful only for putting it under your
  own supervision tree — not something you call `Launcher` functions on
  directly.
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
  Connects to a Chrome instance this doesn't manage, wrapped in a
  `Launcher` — no process to spawn, no Supervisor. `:url` is required:
  a literal ws(s):// DevTools URL, or a bare host:port DevTools
  endpoint (discovered via /json/version on first use). Pass `:name` to
  register the launcher; omitted, you get an anonymous pid back.
  """
  @spec connect(keyword) :: Agent.on_start()
  def connect(opts) do
    launcher_opts =
      [
        strategy: SharedWS,
        config: connect_config(Keyword.fetch!(opts, :url)),
        build_template: Keyword.get(opts, :build_template, &build_template/1),
        post_start: Keyword.get(opts, :post_start, &post_start/2)
      ] ++ Keyword.take(opts, [:name])

    Launcher.start_link(launcher_opts)
  end

  @doc """
  Builds the `%SharedWS.Config{}` `connect/1` uses, without starting
  anything — for `default_launcher_spec/0`, which needs to fold a
  "connect to this url" launcher into a child spec rather than start it
  immediately.
  """
  @spec connect_config(String.t()) :: %SharedWS.Config{}
  def connect_config(url) do
    %SharedWS.Config{resolve_ws_url: fn -> resolve_remote_ws_url(url) end}
  end

  @doc false
  def supervisor_name(name), do: Module.concat(name, Supervisor)
  @doc false
  def server_name(name), do: Module.concat(name, Server)

  @default_launcher_name __MODULE__.DefaultLauncher

  # `connection` picks which of the two ways this driver's default
  # launcher gets connected — unlike Lightpanda's `:connection` opt
  # (re-resolved on every `start_session/1` call), this is decided once,
  # the first time `default_launcher_spec/0`'s child actually starts
  # (lazily, under `SurfBoard.DriverSupervisor`) and is never restarted
  # per call, so by the time a second call could pass a different opt,
  # this choice is already fixed. It's app config, not a session opt. A
  # caller wanting a *different* configuration entirely should build
  # their own launcher via `start_link/1`/`connect/1` and pass it via
  # `start_session(launcher: ...)`.
  #
  #   * `:shared`   — spawn and own a local Chrome process, via
  #                   `start_link/1`.
  #   * `:external` — never spawn anything; connect the default launcher
  #                   to a Chrome instance this driver doesn't manage,
  #                   via `remote_url/0` (`connect_config/1`).
  #
  # Omitted (the default): auto-detect — `:external` if `remote_url/0`
  # resolves to something, else `:shared`.
  @impl SurfBoard.Driver
  def default_launcher_spec do
    launcher_opts = [
      name: @default_launcher_name,
      build_template: &build_template/1,
      post_start: &post_start/2
    ]

    case resolve_connection() do
      :external ->
        config = connect_config(remote_url())
        {Launcher, launcher_opts ++ [strategy: SharedWS, config: config]}

      :shared ->
        {__MODULE__, launcher_opts}
    end
  end

  defp resolve_connection do
    case configured_connection() do
      nil -> if remote_url(), do: :external, else: :shared
      :external -> :external
      :shared -> :shared
    end
  end

  defp configured_connection do
    Application.get_env(:surf_board, :chrome_cdp, []) |> Keyword.get(:connection)
  end

  @doc """
  Checks whether `start_link/1` can actually succeed — Chrome is
  installed — without starting anything. Returns
  `:ok | {:error, %SurfBoard.DependencyError{}}`.
  """
  @impl SurfBoard.Driver
  def validate do
    case resolve_connection() do
      :external ->
        if remote_url() do
          :ok
        else
          {:error,
           DependencyError.exception(
             "connection: :external configured, but no remote_url is set. " <>
               "Set SURF_BOARD_CHROME_URL or config :surf_board, :chrome_cdp, remote_url: \"...\"."
           )}
        end

      :shared ->
        if match?({:ok, _}, SurfBoard.Launcher.BrowserPaths.chrome_path()) do
          :ok
        else
          {:error,
           DependencyError.exception(
             "Chrome not found. Run `mix surf_board.install` or set SURF_BOARD_CHROME_URL."
           )}
        end
    end
  end

  @impl SurfBoard.Driver
  def cleanup_stale_sessions, do: :ok

  # ----- Session lifecycle -----

  @impl SurfBoard.Driver
  def start_session(opts \\ []) do
    launcher = Keyword.get(opts, :launcher, @default_launcher_name)
    Launcher.start_session(launcher, opts)
  end

  @doc false
  def build_template(opts) do
    %SurfBoard.Session{
      id: "chrome-#{System.unique_integer([:positive])}",
      url: "about:blank",
      session_url: "about:blank",
      spec_module: __MODULE__,
      spec: spec(),
      live_view_aware?: Keyword.get(opts, :live_view_aware, false),
      capabilities: Keyword.get(opts, :capabilities, %{})
    }
  end

  @doc false
  def post_start(session, opts) do
    caller = Keyword.get(opts, :owner, self())

    # Forward console + exception events to the test caller's mailbox
    # so Browser.LogChecker.check_logs! can drain them after each operation.
    _ =
      SurfBoard.Transport.WebSocket.subscribe(
        session.ws_pid,
        "Runtime.consoleAPICalled",
        session.browsing_context,
        caller
      )

    _ =
      SurfBoard.Transport.WebSocket.subscribe(
        session.ws_pid,
        "Runtime.exceptionThrown",
        session.browsing_context,
        caller
      )

    if UserAgent.override?(opts) do
      ua =
        opts
        |> UserAgent.resolve(@base_user_agent)
        |> Metadata.append(Keyword.get(opts, :metadata))

      _ = CDPClient.cdp_send(session, "Network.setUserAgentOverride", %{userAgent: ua})
    end

    if window_size = Keyword.get(opts, :window_size) do
      _ = CDPClient.set_window_size(session, window_size[:width], window_size[:height])
    end

    {:ok, session}
  end

  # ----- Per-spec overrides -----

  # touch_scroll uses CDP's Input.synthesizeScrollGesture — referenced
  # via spec().touch_scroll.
  @doc false
  def touch_scroll_impl(%SurfBoard.Element{} = element, x_offset, y_offset) do
    session = SurfBoard.Element.root_session(element)

    case CDPClient.element_location(element) do
      {:ok, _} ->
        CDPClient.cdp_send(session, "Input.synthesizeScrollGesture", %{
          x: 0,
          y: 0,
          xDistance: -x_offset,
          yDistance: -y_offset
        })

        {:ok, nil}

      err ->
        err
    end
  end

  # ----- Internal -----

  @doc false
  def remote_url do
    SurfBoard.Launcher.BrowserPaths.chrome_url() ||
      Application.get_env(:surf_board, :chrome_cdp, []) |> Keyword.get(:remote_url)
  end

  # `url` is either a literal ws(s):// DevTools URL, or a bare HTTP
  # endpoint (host:port) that needs /json/version discovery to find
  # the actual webSocketDebuggerUrl.
  defp resolve_remote_ws_url("ws://" <> _ = url), do: url
  defp resolve_remote_ws_url("wss://" <> _ = url), do: url

  defp resolve_remote_ws_url(endpoint) do
    Task.async(fn -> discover_ws_url(endpoint) end) |> Task.await(10_000)
  end

  defp discover_ws_url(endpoint) do
    endpoint = String.trim_trailing(endpoint, "/")

    {:ok, conn} = Mint.HTTP.connect(:http, host(endpoint), port(endpoint))

    {:ok, conn, ref} =
      Mint.HTTP.request(conn, "GET", "/json/version", [{"host", "localhost"}], nil)

    {body, conn} = receive_body!(conn, ref)
    _ = Mint.HTTP.close(conn)

    case Jason.decode(body) do
      {:ok, %{"webSocketDebuggerUrl" => ws_url}} ->
        rewrite_ws_host(ws_url, endpoint)

      {:ok, other} ->
        raise "Chrome /json/version did not include webSocketDebuggerUrl: #{inspect(other)}"

      {:error, _} ->
        raise "Chrome /json/version returned invalid JSON: #{body}"
    end
  end

  defp receive_body!(conn, ref, acc \\ "") do
    receive do
      message ->
        case Mint.HTTP.stream(conn, message) do
          {:ok, conn, responses} ->
            {conn, body} =
              Enum.reduce(responses, {conn, acc}, fn
                {:data, ^ref, data}, {c, a} -> {c, a <> data}
                {:done, ^ref}, {c, a} -> {c, a}
                _, {c, a} -> {c, a}
              end)

            if Enum.any?(responses, &match?({:done, ^ref}, &1)) do
              {body, conn}
            else
              receive_body!(conn, ref, body)
            end

          :unknown ->
            receive_body!(conn, ref, acc)

          {:error, _conn, reason, _} ->
            raise "Chrome /json/version request failed: #{inspect(reason)}"
        end
    after
      5_000 -> raise "Chrome /json/version timed out"
    end
  end

  defp host(endpoint) do
    case String.split(endpoint, ":") do
      [h | _] -> h
      _ -> endpoint
    end
  end

  defp port(endpoint) do
    case String.split(endpoint, ":") do
      [_, p] -> String.to_integer(p)
      _ -> 9222
    end
  end

  defp rewrite_ws_host(ws_url, endpoint) do
    uri = URI.parse(ws_url)
    URI.to_string(%{uri | host: host(endpoint), port: port(endpoint)})
  end
end
