defmodule SurfBoard.Drivers.ChromeBiDi do
  @moduledoc false

  # Chrome driver speaking WebDriver-BiDi against a chromium-bidi
  # Node sidecar. Only owns lifecycle (start/end_session, the
  # Supervisor surface) and its @driver_spec. Every capability is
  # dispatched by Browser.ex/Element.ex calling session.driver_spec's
  # dimension modules directly.
  #
  # `Launcher.BiDi` — not this module — owns everything about actually
  # building a working BiDi session (the session template, UA
  # override, window size, log.entryAdded subscription) and building
  # the launcher itself (`connect/1`, dialing a base_url). This driver
  # is built *on top of* `Launcher.BiDi`: `start_session/1` resolves a
  # base_url (a caller-given one, or this driver's own BidiServer
  # sidecar) and calls `Launcher.BiDi.connect/1` with it, unless the
  # caller already passed a `:launcher`.

  use Supervisor

  @behaviour SurfBoard.Driver

  alias SurfBoard.Launcher
  alias SurfBoard.Launcher.BiDi, as: LauncherBiDi
  alias SurfBoard.Browser
  alias SurfBoard.Clients.BiDi.{Dialogs, Frames, Windows}
  alias SurfBoard.Clients.BiDi.Client, as: BiDiClient
  alias SurfBoard.DriverSpec, as: Spec
  alias SurfBoard.Permissions

  @driver_spec %Spec{
    browser: Browser.Chrome,
    wire_protocol: BiDiClient,
    dialogs: Dialogs,
    windows: Windows,
    frames: Frames,
    grant_permissions: Permissions.Unsupported,
    send_keys_session: BiDiClient,
    touch_scroll: &__MODULE__.touch_scroll_impl/3,
    log_check_interactions?: true
  }

  @doc false
  def driver_spec, do: @driver_spec

  # ----- Driver supervisor -----

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, :ok, opts)
  end

  @bidi_server_name __MODULE__.BidiServer

  @impl Supervisor
  def init(_) do
    children = [
      {SurfBoard.Drivers.ChromeBiDi.Server, [name: @bidi_server_name]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  def validate, do: :ok

  @doc false
  def cleanup_stale_sessions, do: :ok

  @doc """
  Default capabilities passed when starting a Chrome session via BiDi.
  """
  def default_capabilities do
    %{
      browserName: "chrome",
      unhandledPromptBehavior: "ignore"
    }
  end

  # ----- Session lifecycle -----

  @impl SurfBoard.Driver
  def start_session(opts \\ []) do
    {launcher, cleanup} = resolve_launcher(opts)
    result = Launcher.start_session(launcher, opts)
    cleanup.()
    result
  end

  # An explicit `:launcher` opt uses that started launcher as-is (no
  # cleanup — it's the caller's own, independently-started launcher; it
  # already carries whatever hooks it was started with). Otherwise
  # build a transient, unnamed one via `Launcher.BiDi.connect/1` from
  # opts[:base_url] (or this driver's own BidiServer sidecar), and tear
  # it down again once start_session/1 returns — `Strategy.BiDi` caches
  # no connection state on its launcher (each session does its own
  # POST /session), so nothing is lost by not keeping it around.
  defp resolve_launcher(opts) do
    case Keyword.get(opts, :launcher) do
      nil ->
        {:ok, launcher} = LauncherBiDi.connect(base_url: resolve_base_url(opts))
        {launcher, fn -> Agent.stop(launcher) end}

      launcher ->
        {launcher, fn -> :ok end}
    end
  end

  defp resolve_base_url(opts) do
    case Keyword.get(opts, :base_url) do
      url when is_binary(url) ->
        url

      _ ->
        # Convert the BidiServer's WS URL to its HTTP equivalent —
        # they share the host/port; chromium-bidi serves both.
        ws_url = bidi_ws_url_with_retry(5)

        ws_url
        |> URI.parse()
        |> Map.put(:scheme, "http")
        |> Map.put(:path, nil)
        |> URI.to_string()
    end
  end

  # The supervised BidiServer process can crash mid-suite (chromium-bidi
  # Node process exits non-zero; OOM on CI runners is the most common
  # cause). The one_for_one Supervisor restarts it, but there's a short
  # window where GenServer.call(@bidi_server_name, _) exits with
  # :noproc before the new pid registers under the name. Retry with a
  # small backoff to ride out the gap.
  defp bidi_ws_url_with_retry(0) do
    SurfBoard.Drivers.ChromeBiDi.Server.ws_url(@bidi_server_name)
  end

  defp bidi_ws_url_with_retry(retries_left) do
    SurfBoard.Drivers.ChromeBiDi.Server.ws_url(@bidi_server_name)
  catch
    :exit, _ ->
      Process.sleep(500)
      bidi_ws_url_with_retry(retries_left - 1)
  end

  # ----- Per-driver overrides -----

  # touch_scroll uses BiDi's JS scrollBy workaround (touch pointer
  # actions don't reliably trigger scroll in headless Chrome).
  @doc false
  def touch_scroll_impl(%SurfBoard.Element{} = element, x_offset, y_offset) do
    case BiDiClient.call_on_element(
           SurfBoard.Element.root_session(element),
           element,
           "function(dx, dy) { this.scrollIntoView(); window.scrollBy(dx, dy); return null; }",
           [x_offset, y_offset]
         ) do
      {:ok, _} -> {:ok, nil}
      err -> err
    end
  end
end
