defmodule SurfBoard.Specs.ChromeCDP do
  @moduledoc false

  # Chrome protocol-variant spec over the transport stack — a
  # `Strategy.SharedWS` launcher (one shared WebSocket for every
  # session started against it), per-session BrowserContext + Target +
  # sessionId for routing.
  #
  # Only owns its capability-dispatch table (`spec/0`) and a couple of
  # one-off vendor behaviors (`touch_scroll_impl/3`). Every capability
  # is dispatched by Browser.ex/Element.ex calling session.spec's
  # dimension modules directly.
  #
  # `Launcher.Chrome` — not this module — owns everything about
  # actually building a working Chrome session (the session template,
  # UA override, window size, log-event subscription) and building the
  # launcher itself (spawn a local Chrome, or connect to a configured
  # remote_url). This spec module's `default_launcher_spec/0` just
  # decides which of `Launcher.Chrome.start_link/1`/`connect/1` its own
  # default launcher uses — the same decision a caller building any
  # other launcher makes directly. Pass `launcher:` to `start_session/1`
  # (or call `Launcher.start_session/2` on it directly) to use a
  # different one instead (e.g. an application connecting to a remote
  # Chrome while its own test suite launches and owns a second, local
  # one via `Launcher.Chrome.start_link/1`, both alive in the same BEAM).

  @behaviour SurfBoard.SpecModule

  alias SurfBoard.Launcher
  alias SurfBoard.Browser
  alias SurfBoard.Clients.CDP.Client, as: CDPClient
  alias SurfBoard.Clients.CDP.{Dialogs, Frames, Windows}
  alias SurfBoard.Spec
  alias SurfBoard.Launcher.Chrome, as: LauncherChrome
  alias SurfBoard.Transport.Strategy.SharedWS

  @spec_data %Spec{
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

  @impl SurfBoard.SpecModule
  def spec, do: @spec_data

  @default_launcher_name __MODULE__.DefaultLauncher

  # `connection` picks which of the two ways this spec's default
  # launcher gets connected — unlike LightpandaCDP's `:connection` opt
  # (re-resolved on every `start_session/1` call), this is decided once,
  # the first time `default_launcher_spec/0`'s child actually starts
  # (lazily, under `SurfBoard.DriverSupervisor`) and is never restarted
  # per call, so by the time a second call could pass a different opt,
  # this choice is already fixed. It's app config, not a session opt. A
  # caller wanting a *different* configuration entirely should build
  # their own `Launcher.Chrome` and pass it via
  # `start_session(launcher: ...)`.
  #
  #   * `:shared`   — spawn and own a local Chrome process, via
  #                   `Launcher.Chrome.start_link/1`.
  #   * `:external` — never spawn anything; connect the default launcher
  #                   to a Chrome instance this spec doesn't manage,
  #                   via `remote_url/0` (`Launcher.Chrome.connect_config/1`).
  #
  # Omitted (the default): auto-detect — `:external` if `remote_url/0`
  # resolves to something, else `:shared`.
  @impl SurfBoard.SpecModule
  def default_launcher_spec do
    launcher_opts = [
      name: @default_launcher_name,
      build_template: &LauncherChrome.build_template/1,
      post_start: &LauncherChrome.post_start/2
    ]

    case resolve_connection() do
      :external ->
        config = LauncherChrome.connect_config(remote_url())
        {Launcher, launcher_opts ++ [strategy: SharedWS, config: config]}

      :shared ->
        {LauncherChrome, launcher_opts}
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

  @impl SurfBoard.SpecModule
  def validate do
    case resolve_connection() do
      :external ->
        if remote_url() do
          :ok
        else
          {:error,
           SurfBoard.DependencyError.exception(
             "connection: :external configured, but no remote_url is set. " <>
               "Set SURF_BOARD_CHROME_URL or config :surf_board, :chrome_cdp, remote_url: \"...\"."
           )}
        end

      :shared ->
        LauncherChrome.validate()
    end
  end

  @impl SurfBoard.SpecModule
  def cleanup_stale_sessions, do: :ok

  # ----- Session lifecycle -----

  @impl SurfBoard.SpecModule
  def start_session(opts \\ []) do
    launcher = Keyword.get(opts, :launcher, @default_launcher_name)
    Launcher.start_session(launcher, opts)
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
    SurfBoard.BrowserPaths.chrome_url() ||
      Application.get_env(:surf_board, :chrome_cdp, []) |> Keyword.get(:remote_url)
  end
end
