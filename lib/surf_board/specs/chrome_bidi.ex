defmodule SurfBoard.Specs.ChromeBiDi do
  @moduledoc false

  # Chrome protocol-variant spec speaking WebDriver-BiDi against a
  # chromium-bidi Node sidecar. Only owns its capability-dispatch table
  # (`spec/0`) and a one-off vendor behavior (`touch_scroll_impl/3`).
  # Every capability is dispatched by Browser.ex/Element.ex calling
  # session.spec's dimension modules directly.
  #
  # `Launcher.BiDi` — not this module — owns everything about actually
  # building a working BiDi session (the session template, UA
  # override, window size, log.entryAdded subscription), dialing a
  # base_url (`connect/1`), and supervising the sidecar Node process
  # this spec's default launcher needs (`Launcher.BiDi.Supervised`).
  # This spec is built *on top of* `Launcher.BiDi`: `start_session/1`
  # resolves a base_url (a caller-given one, or the default sidecar)
  # and calls `Launcher.BiDi.connect/1` with it, unless the caller
  # already passed a `:launcher`.

  @behaviour SurfBoard.SpecModule

  alias SurfBoard.Launcher
  alias SurfBoard.Launcher.BiDi, as: LauncherBiDi
  alias SurfBoard.Browser
  alias SurfBoard.Clients.BiDi.{Dialogs, Frames, Windows}
  alias SurfBoard.Clients.BiDi.Client, as: BiDiClient
  alias SurfBoard.Spec
  alias SurfBoard.Permissions

  @spec_data %Spec{
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

  @impl SurfBoard.SpecModule
  def spec, do: @spec_data

  # ----- Default launcher -----

  @impl SurfBoard.SpecModule
  def default_launcher_spec do
    name = LauncherBiDi.default_name()

    %{
      id: name,
      start: {LauncherBiDi.Supervised, :start_link, [{name, []}]},
      type: :supervisor
    }
  end

  @impl SurfBoard.SpecModule
  def validate, do: :ok

  @impl SurfBoard.SpecModule
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

  @impl SurfBoard.SpecModule
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
  # opts[:base_url] (or the default sidecar, started lazily under
  # `default_launcher_spec/0`), and tear it down again once
  # start_session/1 returns — `Strategy.BiDi` caches no connection
  # state on its launcher (each session does its own POST /session),
  # so nothing is lost by not keeping it around.
  defp resolve_launcher(opts) do
    case Keyword.get(opts, :launcher) do
      nil ->
        {:ok, launcher} = LauncherBiDi.connect(base_url: LauncherBiDi.resolve_base_url(opts))
        {launcher, fn -> Agent.stop(launcher) end}

      launcher ->
        {launcher, fn -> :ok end}
    end
  end

  # ----- Per-spec overrides -----

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
