defmodule SurfBoard.Launcher.BiDi do
  @moduledoc false

  # Convenience constructor for a `Strategy.BiDi`-backed `Launcher`
  # talking to Chrome over WebDriver BiDi — build a real, working BiDi
  # session without hand-assembling a `BiDi.Config{base_url: ...}`
  # yourself.
  #
  # One entry point, unlike `Launcher.Chrome`/`Launcher.Lightpanda`'s
  # two: `Strategy.BiDi` caches no connection state on its launcher
  # (each session does its own `POST /session` — see `Strategy.BiDi`'s
  # moduledoc), so there's no "own a persistent process, many sessions
  # reuse it" shape to give a `start_link/1` for. Every BiDi launcher is
  # the `connect/1` shape — dial a `base_url` — whether that url points
  # at a chromium-bidi sidecar you launched yourself or the one this
  # library manages.
  #
  #   {:ok, launcher} = Launcher.BiDi.connect(base_url: "http://localhost:12345")
  #   {:ok, session} = Launcher.start_session(launcher)
  #
  # `Supervised` owns the chromium-bidi Node sidecar
  # (`Drivers.ChromeBiDi.Server`) — `Specs.ChromeBiDi`'s default
  # launcher spec, started once, lazily, under `SurfBoard.DriverSupervisor`.
  # Every session still connects via the plain `connect/1` shape above
  # (transient, no state to keep); the sidecar just needs somewhere to
  # live so it survives across sessions instead of respawning per call.
  #
  # `connect/1` builds a real, working Chrome session on its own — this
  # is the one place a %SurfBoard.Session{} template for
  # Specs.ChromeBiDi gets built (`build_template/1`) and finished
  # (`post_start/2`: UA override, window size, log.entryAdded
  # subscription). `Specs.ChromeBiDi` itself is built on top of this
  # module, not the other way around. Pass your own
  # `:build_template`/`:post_start` to override these defaults entirely.

  alias SurfBoard.{Metadata, UserAgent}
  alias SurfBoard.Clients.BiDi.Client, as: BiDiClient
  alias SurfBoard.Drivers.ChromeBiDi.Server, as: BidiServer
  alias SurfBoard.Drivers.ChromeBiDi.WebSocketClient
  alias SurfBoard.Launcher
  alias SurfBoard.Specs.ChromeBiDi
  alias SurfBoard.Transport.Protocol
  alias SurfBoard.Transport.Strategy.BiDi, as: BiDiStrategy

  @base_user_agent "Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 " <>
                     "(KHTML, like Gecko) Chrome/41.0.2228.0 Safari/537.36"

  defmodule Supervised do
    @moduledoc false
    # Owns the chromium-bidi Node sidecar (`Drivers.ChromeBiDi.Server`)
    # as its one child — same pattern as `Launcher.Chrome.Supervised`,
    # except there's no `Launcher` child here: `Strategy.BiDi` caches
    # no connection state, so every session dials the sidecar fresh via
    # `Launcher.BiDi.connect/1` rather than reusing a persistent one.
    use Supervisor

    alias SurfBoard.Launcher.BiDi

    def start_link({name, _opts}) do
      Supervisor.start_link(__MODULE__, :ok, name: BiDi.supervisor_name(name))
    end

    @impl Supervisor
    def init(:ok) do
      Supervisor.init([{BidiServer, [name: BiDi.bidi_server_name()]}], strategy: :one_for_one)
    end
  end

  @doc false
  def supervisor_name(name), do: Module.concat(name, Supervisor)
  @doc false
  def bidi_server_name, do: __MODULE__.BidiServer

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
  one wins; otherwise the default sidecar's own WS URL, converted to
  its HTTP equivalent (they share host/port; chromium-bidi serves
  both).
  """
  @spec resolve_base_url(keyword) :: String.t()
  def resolve_base_url(opts) do
    case Keyword.get(opts, :base_url) do
      url when is_binary(url) ->
        url

      _ ->
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
  # window where GenServer.call(bidi_server_name(), _) exits with
  # :noproc before the new pid registers under the name. Retry with a
  # small backoff to ride out the gap.
  defp bidi_ws_url_with_retry(0) do
    BidiServer.ws_url(bidi_server_name())
  end

  defp bidi_ws_url_with_retry(retries_left) do
    BidiServer.ws_url(bidi_server_name())
  catch
    :exit, _ ->
      Process.sleep(500)
      bidi_ws_url_with_retry(retries_left - 1)
  end

  @doc false
  def build_template(opts) do
    %SurfBoard.Session{
      id: "v2bidi-#{System.unique_integer([:positive])}",
      url: "about:blank",
      session_url: "about:blank",
      spec_module: ChromeBiDi,
      driver_spec: ChromeBiDi.spec(),
      live_view_aware?: Keyword.get(opts, :live_view_aware, false),
      browsing_context: nil,
      capabilities: Keyword.get(opts, :capabilities, %{}) |> Map.new()
    }
  end

  @doc false
  def post_start(session, opts) do
    caller = Keyword.get(opts, :owner, self())
    _ = WebSocketClient.subscribe(session.bidi_pid, "log.entryAdded", caller, :global)

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
end
