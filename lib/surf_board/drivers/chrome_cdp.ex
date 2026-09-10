defmodule SurfBoard.Drivers.ChromeCDP do
  @moduledoc false

  # Chrome driver over the transport stack — a `Strategy.SharedWS`
  # launcher (one shared WebSocket for every session started against
  # it), per-session BrowserContext + Target + sessionId for routing.
  #
  # Only owns lifecycle (start/end_session, the Supervisor surface),
  # its @driver_spec, and the two `Launcher` hooks (`build_template/1`,
  # `post_start/2`) that make its default launcher a complete entry
  # point on its own — `start_session/1` itself is just "resolve which
  # launcher, then call `Launcher.start_session/2`". Every capability is
  # dispatched by Browser.ex/Element.ex calling session.driver_spec's
  # dimension modules directly.
  #
  # Starts one default `SurfBoard.Launcher` under its own Supervisor,
  # lazily, same as always — pass `launcher:` to `start_session/1` (or
  # call `Launcher.start_session/2` on it directly) to use a different,
  # independently-started launcher instead (e.g. an application
  # connecting to a remote Chrome while its own test suite launches and
  # owns a second, local one, both alive in the same BEAM).

  use Supervisor

  @behaviour SurfBoard.Driver

  alias SurfBoard.{DependencyError, Launcher, Metadata, Session, UserAgent}
  alias SurfBoard.{Browser, WebSocket}
  alias SurfBoard.Clients.CDP.Client, as: CDPClient
  alias SurfBoard.Clients.CDP.{Dialogs, Frames, Windows}
  alias SurfBoard.Drivers.ChromeCDP.Server, as: ChromeServer
  alias SurfBoard.DriverSpec, as: Spec
  alias SurfBoard.Transport.Strategy.SharedWS

  @driver_spec %Spec{
    browser: Browser.Chrome,
    wire_protocol: CDPClient,
    dialogs: Dialogs,
    windows: Windows,
    frames: Frames,
    grant_permissions: CDPClient,
    send_keys_session: CDPClient,
    touch_scroll: &__MODULE__.touch_scroll_impl/3,
    log_check_interactions?: true
  }

  @doc false
  def driver_spec, do: @driver_spec

  @base_user_agent "Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 " <>
                     "(KHTML, like Gecko) Chrome/41.0.2228.0 Safari/537.36"

  # ----- Supervisor -----

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, :ok, opts)
  end

  @default_launcher_name __MODULE__.DefaultLauncher

  # `connection` picks which of the two ways this driver's default
  # `Launcher` gets connected — unlike LightpandaCDP's `:connection` opt
  # (re-resolved on every `start_session/1` call), this is decided once,
  # here, at Supervisor.init/1 time: the driver's supervisor starts
  # lazily on first `start_session/1` and is never restarted per call,
  # so by the time a second call could pass a different opt, this
  # choice is already fixed. It's app config, not a session opt. A
  # caller wanting a *different* configuration entirely should start
  # their own `SurfBoard.Launcher` and pass it via `start_session(launcher: ...)`.
  #
  #   * `:shared`   — spawn and own a local Chrome process
  #                   (`ChromeServer`), then multiplex every session
  #                   over its WebSocket.
  #   * `:external` — never spawn anything; connect the default launcher
  #                   to a Chrome instance this driver doesn't manage,
  #                   via `remote_url/0`.
  #
  # Omitted (the default): auto-detect — `:external` if `remote_url/0`
  # resolves to something, else `:shared`.
  @impl Supervisor
  def init(_) do
    launcher_opts = [
      name: @default_launcher_name,
      strategy: SharedWS,
      build_template: &build_template/1,
      post_start: &post_start/2
    ]

    children =
      case resolve_connection() do
        :external ->
          [{Launcher, launcher_opts ++ [config: external_config()]}]

        :shared ->
          [
            {ChromeServer, [name: __MODULE__.Server]},
            {Launcher, launcher_opts ++ [config: shared_config()]}
          ]
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp shared_config do
    %SharedWS.Config{resolve_ws_url: fn -> ChromeServer.ws_url(__MODULE__.Server) end}
  end

  defp external_config do
    %SharedWS.Config{resolve_ws_url: fn -> resolve_remote_ws_url(remote_url()) end}
  end

  defp resolve_connection do
    case configured_connection() do
      nil -> if remote_url(), do: :external, else: :shared
      :external -> :external
      :shared -> :shared
    end
  end

  defp configured_connection do
    Application.get_env(:surf_board, :chrome_cdp_v2, []) |> Keyword.get(:connection)
  end

  @doc false
  def validate do
    case resolve_connection() do
      :external ->
        if remote_url() do
          :ok
        else
          {:error,
           DependencyError.exception(
             "connection: :external configured, but no remote_url is set. " <>
               "Set SURF_BOARD_CHROME_URL or config :surf_board, :chrome_cdp_v2, remote_url: \"...\"."
           )}
        end

      :shared ->
        if chrome_available?() do
          :ok
        else
          {:error,
           DependencyError.exception(
             "Chrome not found. Run `mix surf_board.install` or set SURF_BOARD_CHROME_URL."
           )}
        end
    end
  end

  @doc false
  def cleanup_stale_sessions, do: :ok

  # ----- Session lifecycle -----

  @impl SurfBoard.Driver
  def start_session(opts \\ []) do
    launcher = Keyword.get(opts, :launcher, @default_launcher_name)
    Launcher.start_session(launcher, opts)
  end

  # ----- Launcher hooks (see Launcher's moduledoc) -----

  defp build_template(opts) do
    %Session{
      id: "v2-chrome-#{System.unique_integer([:positive])}",
      url: "about:blank",
      session_url: "about:blank",
      driver: __MODULE__,
      driver_spec: @driver_spec,
      live_view_aware?: Keyword.get(opts, :live_view_aware, false),
      capabilities: Keyword.get(opts, :capabilities, %{})
    }
  end

  defp post_start(session, opts) do
    caller = Keyword.get(opts, :owner, self())

    # Forward console + exception events to the test caller's mailbox
    # so LogChecker.check_logs! can drain them after each operation.
    _ =
      WebSocket.subscribe(
        session.bidi_pid,
        "Runtime.consoleAPICalled",
        session.browsing_context,
        caller
      )

    _ =
      WebSocket.subscribe(
        session.bidi_pid,
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

  # ----- Per-driver overrides -----

  # touch_scroll uses CDP's Input.synthesizeScrollGesture — referenced
  # via @driver_spec.touch_scroll.
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
    SurfBoard.BrowserPaths.chrome_url() ||
      Application.get_env(:surf_board, :chrome_cdp_v2, []) |> Keyword.get(:remote_url)
  end

  defp chrome_available? do
    match?({:ok, _}, SurfBoard.BrowserPaths.chrome_path())
  end

  # `remote_url` is either a literal ws(s):// DevTools URL, or a bare
  # HTTP endpoint (host:port) that needs /json/version discovery to
  # find the actual webSocketDebuggerUrl.
  defp resolve_remote_ws_url("ws://" <> _ = url), do: url
  defp resolve_remote_ws_url("wss://" <> _ = url), do: url

  defp resolve_remote_ws_url(endpoint) do
    # Run the discovery in a fresh Task so its receive loop doesn't
    # contend with the caller's own mailbox.
    task = Task.async(fn -> discover_ws_url(endpoint) end)
    Task.await(task, 10_000)
  end

  defp discover_ws_url(endpoint) do
    endpoint = String.trim_trailing(endpoint, "/")

    {:ok, conn} = Mint.HTTP.connect(:http, host(endpoint), port(endpoint))

    {:ok, conn, ref} =
      Mint.HTTP.request(
        conn,
        "GET",
        "/json/version",
        [{"host", "localhost"}],
        nil
      )

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
