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
  # at a chromium-bidi sidecar you launched yourself or one this
  # library manages (`Drivers.ChromeBiDi.Server`, the Node sidecar
  # `Drivers.ChromeBiDi` always runs regardless of which launcher a
  # given session uses — driver infrastructure, not something a
  # per-launcher constructor owns).
  #
  #   {:ok, launcher} = Launcher.BiDi.connect(base_url: "http://localhost:12345")
  #   {:ok, session} = Launcher.start_session(launcher)
  #
  # Builds a real, working Chrome session on its own — this is the one
  # place a %SurfBoard.Session{} template for Drivers.ChromeBiDi gets
  # built (`build_template/1`) and finished (`post_start/2`: UA
  # override, window size, log.entryAdded subscription).
  # `Drivers.ChromeBiDi` itself is built on top of this module, not the
  # other way around. Pass your own `:build_template`/`:post_start` to
  # override these defaults entirely.

  alias SurfBoard.{Metadata, UserAgent}
  alias SurfBoard.Clients.BiDi.Client, as: BiDiClient
  alias SurfBoard.Drivers.ChromeBiDi
  alias SurfBoard.Drivers.ChromeBiDi.WebSocketClient
  alias SurfBoard.Launcher
  alias SurfBoard.Transport.Protocol
  alias SurfBoard.Transport.Strategy.BiDi, as: BiDiStrategy

  @base_user_agent "Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 " <>
                     "(KHTML, like Gecko) Chrome/41.0.2228.0 Safari/537.36"

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

  @doc false
  def build_template(opts) do
    %SurfBoard.Session{
      id: "v2bidi-#{System.unique_integer([:positive])}",
      url: "about:blank",
      session_url: "about:blank",
      driver: ChromeBiDi,
      driver_spec: ChromeBiDi.driver_spec(),
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
