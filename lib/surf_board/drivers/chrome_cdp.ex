defmodule SurfBoard.Drivers.ChromeCDP do
  @moduledoc false

  # Chrome driver over the transport stack — one shared WebSocket per BEAM
  # (held by `Chrome.SharedConnection`), per-session BrowserContext +
  # Target + sessionId for routing.
  #
  # All callback behaviour comes from `SurfBoard.Driver.Generic`,
  # which dispatches via `session.driver_spec` (stamped by start_session).
  # Only the lifecycle (start/end_session) and the Supervisor surface
  # live here.

  use Supervisor

  use SurfBoard.Driver.Generic

  alias SurfBoard.{DependencyError, Metadata, Session, UserAgent}
  alias SurfBoard.{Browser, Transport, WebSocket}
  alias SurfBoard.Drivers.CDP.Client, as: CDPClient
  alias SurfBoard.Drivers.ChromeCDP.Server, as: ChromeServer
  alias SurfBoard.Drivers.ChromeCDP.SharedConnection
  alias SurfBoard.Drivers.ChromeCDP.{Dialogs, Frames, Windows}
  alias SurfBoard.Driver.Spec
  alias SurfBoard.Transport.Protocol

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

  # `connection` picks which of the two ways this driver's ONE Chrome
  # instance for the life of the BEAM gets connected — unlike
  # LightpandaCDP's `:connection` opt (re-resolved on every
  # `start_session/1` call), this is decided once, here, at
  # Supervisor.init/1 time: the driver's supervisor starts lazily on
  # first `start_session/1` and is never restarted per call, so by the
  # time a second call could pass a different opt, this choice is
  # already fixed. It's app config, not a session opt.
  #
  #   * `:shared`   — spawn and own a local Chrome process
  #                   (`ChromeServer`), then multiplex every session
  #                   over one shared WebSocket (`SharedConnection`).
  #   * `:external` — never spawn anything; connect `SharedConnection`
  #                   to a Chrome instance this driver doesn't manage,
  #                   via `remote_url/0`.
  #
  # Omitted (the default): auto-detect — `:external` if `remote_url/0`
  # resolves to something, else `:shared`.
  @impl Supervisor
  def init(_) do
    children =
      case resolve_connection() do
        :external -> [SharedConnection]
        :shared -> [{ChromeServer, [name: __MODULE__.Server]}, SharedConnection]
      end

    Supervisor.init(children, strategy: :one_for_one)
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
    caller = Keyword.get(opts, :owner, self())

    with {:ok, acquired} <-
           Transport.SharedWS.acquire(connection: SharedConnection, driver: __MODULE__) do
      user_caps = Keyword.get(opts, :capabilities, %{})

      session_struct = %Session{
        id: "v2-chrome-#{System.unique_integer([:positive])}",
        url: "about:blank",
        session_url: "about:blank",
        driver: __MODULE__,
        driver_spec: @driver_spec,
        live_view_aware?: Keyword.get(opts, :live_view_aware, false),
        bidi_pid: acquired.ws_pid,
        browsing_context: acquired.session_id,
        capabilities: Map.merge(user_caps, acquired.capabilities)
      }

      with {:ok, session} <-
             Transport.start_session_from(acquired, session_struct, owner: caller) do
        # Forward console + exception events to the test caller's mailbox
        # so LogChecker.check_logs! can drain them after each operation.
        _ =
          WebSocket.subscribe(
            acquired.ws_pid,
            "Runtime.consoleAPICalled",
            acquired.session_id,
            caller
          )

        _ =
          WebSocket.subscribe(
            acquired.ws_pid,
            "Runtime.exceptionThrown",
            acquired.session_id,
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
    end
  end

  @impl SurfBoard.Driver
  def end_session(%Session{} = session) do
    Protocol.stop(session)
    :ok
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

  # parse_log: Chrome.Logger raises SurfBoard.JSError on SEVERE entries
  # and prints console output, which is exactly what JSErrorsTest checks
  # for. The Generic-injected parse_log/1 routes here via session.driver,
  # so we override the generic stub.
  defdelegate parse_log(log), to: SurfBoard.Drivers.ChromeCDP.Logger

  # ----- Internal -----

  @doc false
  def remote_url do
    SurfBoard.BrowserPaths.chrome_url() ||
      Application.get_env(:surf_board, :chrome_cdp_v2, []) |> Keyword.get(:remote_url)
  end

  defp chrome_available? do
    match?({:ok, _}, SurfBoard.BrowserPaths.chrome_path())
  end
end
