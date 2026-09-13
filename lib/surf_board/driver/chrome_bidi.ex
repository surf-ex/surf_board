defmodule SurfBoard.Driver.ChromeBiDi do
  @moduledoc false

  # Chrome over WebDriver-BiDi, against a chromium-bidi Node sidecar.
  #
  # One entry point to a connection, unlike ChromeCDP/Lightpanda's two:
  # `Strategy.BiDi` caches no connection state on its launcher (each
  # session does its own `POST /session` — see `Strategy.BiDi`'s
  # moduledoc), so there's no "own a persistent process, many sessions
  # reuse it" shape to give a `start_link/1` for. Every BiDi launcher is
  # the `connect/1` shape — dial a `base_url` — whether that url points
  # at a chromium-bidi sidecar you launched yourself or the one this
  # driver manages.
  #
  #   {:ok, launcher} = Driver.ChromeBiDi.connect(base_url: "http://localhost:12345")
  #   {:ok, session} = Launcher.start_session(launcher)
  #
  # `Supervised` owns the chromium-bidi Node sidecar (`BiDi.Server`) —
  # this driver's default launcher spec, started once, lazily, under
  # `SurfBoard.DriverSupervisor`. Every session still connects via the
  # plain `connect/1` shape above (transient, no state to keep); the
  # sidecar just needs somewhere to live so it survives across sessions
  # instead of respawning per call.

  @behaviour SurfBoard.Driver

  alias SurfBoard.Launcher.Metadata
  alias SurfBoard.Launcher.UserAgent
  alias SurfBoard.Clients.BiDi.Client, as: BiDiClient
  alias SurfBoard.Driver.BiDi.Server, as: BidiServer
  alias SurfBoard.Driver.Spec
  alias SurfBoard.Transport.WebSocketClient
  alias SurfBoard.Launcher
  alias SurfBoard.Transport.Protocol
  alias SurfBoard.Transport.Strategy.BiDi, as: BiDiStrategy

  @base_user_agent "Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 " <>
                     "(KHTML, like Gecko) Chrome/41.0.2228.0 Safari/537.36"

  # Full support for everything BiDi offers here — no overrides needed
  # on top of BiDiClient.default_strategies/0 (which already has
  # grant_permissions: nil — no real BiDi permissions implementation
  # exists yet). Computed at runtime, not in a module attribute — see
  # Driver.ChromeCDP.spec/0's comment for why.
  @impl SurfBoard.Driver
  def spec do
    struct!(
      Spec,
      Map.merge(BiDiClient.default_strategies(), %{
        wire_protocol: BiDiClient,
        touch_scroll: &__MODULE__.touch_scroll_impl/3,
        log_check_interactions?: true
      })
    )
  end

  defmodule Supervised do
    @moduledoc false
    # Owns the chromium-bidi Node sidecar (`BiDi.Server`) as its one
    # child — same pattern as `ChromeCDP.Supervised`, except there's no
    # `Launcher` child here: `Strategy.BiDi` caches no connection state,
    # so every session dials the sidecar fresh via `connect/1` rather
    # than reusing a persistent one.
    use Supervisor

    alias SurfBoard.Driver.ChromeBiDi

    def start_link({name, _opts} = arg) do
      Supervisor.start_link(__MODULE__, arg, name: ChromeBiDi.supervisor_name(name))
    end

    @impl Supervisor
    def init({name, _opts}) do
      Supervisor.init(
        [{BidiServer, [name: ChromeBiDi.bidi_server_name(name)]}],
        strategy: :one_for_one
      )
    end
  end

  @doc false
  def supervisor_name(name), do: Module.concat(name, Supervisor)
  @doc false
  def bidi_server_name(name), do: Module.concat(name, BidiServer)
  @doc false
  def default_name, do: __MODULE__.DefaultLauncher

  @doc """
  Connects to a chromium-bidi HTTP endpoint, wrapped in a `Launcher` —
  no process to spawn, no Supervisor (nothing to own; see the
  moduledoc). `:base_url` is required. Pass `:name` to register the
  launcher; omitted, you get an anonymous pid back.
  """
  @spec connect(keyword) :: Agent.on_start()
  def connect(opts) do
    launcher_opts =
      [
        strategy: BiDiStrategy,
        config: %BiDiStrategy.Config{base_url: Keyword.fetch!(opts, :base_url)},
        build_template: Keyword.get(opts, :build_template, &build_template/1),
        post_start: Keyword.get(opts, :post_start, &post_start/2)
      ] ++ Keyword.take(opts, [:name])

    Launcher.start_link(launcher_opts)
  end

  @doc """
  Resolves the `base_url` a session should connect to: a caller-given
  one wins; otherwise the sidecar's own WS URL (`:launcher_name`,
  defaulting to the default launcher), converted to its HTTP
  equivalent (they share host/port; chromium-bidi serves both).
  """
  @spec resolve_base_url(keyword) :: String.t()
  def resolve_base_url(opts) do
    case Keyword.get(opts, :base_url) do
      url when is_binary(url) ->
        url

      _ ->
        name = Keyword.get(opts, :launcher_name, default_name())
        ws_url = bidi_ws_url_with_retry(name, 5)

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
  # window where GenServer.call(bidi_server_name(name), _) exits with
  # :noproc before the new pid registers under the name. Retry with a
  # small backoff to ride out the gap.
  defp bidi_ws_url_with_retry(name, 0) do
    BidiServer.ws_url(bidi_server_name(name))
  end

  defp bidi_ws_url_with_retry(name, retries_left) do
    BidiServer.ws_url(bidi_server_name(name))
  catch
    :exit, _ ->
      Process.sleep(500)
      bidi_ws_url_with_retry(name, retries_left - 1)
  end

  @impl SurfBoard.Driver
  def default_launcher_spec do
    name = default_name()

    %{
      id: name,
      start: {Supervised, :start_link, [{name, []}]},
      type: :supervisor
    }
  end

  @impl SurfBoard.Driver
  def validate do
    if match?({:ok, _}, SurfBoard.Launcher.BrowserPaths.chrome_path()) do
      :ok
    else
      {:error,
       SurfBoard.DependencyError.exception(
         "Chrome not found. Run `mix surf_board.install` or set SURF_BOARD_CHROME_URL."
       )}
    end
  end

  @impl SurfBoard.Driver
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
  # build a transient, unnamed one via `connect/1` from
  # opts[:base_url] (or the default sidecar, started lazily under
  # `default_launcher_spec/0`), and tear it down again once
  # start_session/1 returns — `Strategy.BiDi` caches no connection
  # state on its launcher (each session does its own POST /session),
  # so nothing is lost by not keeping it around.
  defp resolve_launcher(opts) do
    case Keyword.get(opts, :launcher) do
      nil ->
        {:ok, launcher} = connect(base_url: resolve_base_url(opts))
        {launcher, fn -> Agent.stop(launcher) end}

      launcher ->
        {launcher, fn -> :ok end}
    end
  end

  @doc false
  def build_template(opts) do
    %SurfBoard.Session{
      id: "bidi-#{System.unique_integer([:positive])}",
      url: "about:blank",
      session_url: "about:blank",
      spec_module: __MODULE__,
      spec: spec(),
      live_view_aware?: Keyword.get(opts, :live_view_aware, false),
      browsing_context: nil,
      capabilities: Keyword.get(opts, :capabilities, %{}) |> Map.new()
    }
  end

  @doc false
  def post_start(session, opts) do
    caller = Keyword.get(opts, :owner, self())
    _ = WebSocketClient.subscribe(session.ws_pid, "log.entryAdded", :global, caller)

    if UserAgent.override?(opts) do
      ua =
        opts
        |> UserAgent.resolve(@base_user_agent)
        |> Metadata.append(Keyword.get(opts, :metadata))

      _ =
        Protocol.cdp_send(
          session,
          "emulation.setUserAgentOverride",
          %{"userAgent" => ua, "contexts" => [session.browsing_context]},
          []
        )
    end

    if window_size = Keyword.get(opts, :window_size) do
      _ = BiDiClient.set_viewport(session, window_size[:width], window_size[:height])
    end

    {:ok, session}
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
