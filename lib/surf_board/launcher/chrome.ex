defmodule SurfBoard.Launcher.Chrome do
  @moduledoc false

  # Convenience constructors for a `Strategy.SharedWS`-backed `Launcher`
  # talking to Chrome — build a real, working Chrome session without
  # hand-assembling a `SharedWS.Config{resolve_ws_url: fn -> ... end}`
  # closure yourself.
  #
  # Two entry points, matched to how different the two cases actually
  # are underneath — not one function with a mode flag hiding that
  # difference:
  #
  #   * `start_link/1` — launches and owns a local Chrome process. This
  #     is a Supervisor (not the launcher itself): it owns a
  #     `Drivers.ChromeCDP.Server` and a `Launcher` as its two
  #     children, giving the spawned Chrome the same crash-restart
  #     guarantee `SpecModule.ChromeCDP`'s own default launcher gets. The
  #     launcher child is registered under the `:name` you asked for —
  #     that name (not this Supervisor's pid) is what you use afterward:
  #
  #       {:ok, _sup} = Launcher.Chrome.start_link(name: MyApp.TestChrome)
  #       {:ok, session} = Launcher.start_session(MyApp.TestChrome)
  #
  #   * `connect/1` — connects to a Chrome you don't manage, via `:url`
  #     (a literal ws(s):// URL, or a bare host:port DevTools endpoint
  #     discovered via /json/version). Nothing to spawn, nothing to
  #     supervise — it's a plain `Launcher.start_link/1` call under the
  #     hood, returning `{:ok, launcher_pid}` directly (or registering
  #     it under `:name` if given). No Supervisor process wrapping a
  #     single child for no reason.
  #
  # Both build a real, working Chrome session on their own — this is
  # the one place a %SurfBoard.Session{} template for
  # SpecModule.ChromeCDP gets built (`build_template/1`) and finished
  # (`post_start/2`: UA override, window size, console/exception log
  # subscription). `SpecModule.ChromeCDP` itself is built on top of this
  # module, not the other way around: its `default_launcher_spec/0`
  # just decides which of `start_link/1`/`connect/1` to use for its own
  # default launcher, the same choice this module's caller makes for
  # any other one. Pass your own `:build_template`/`:post_start` to
  # override these defaults entirely.

  alias SurfBoard.{DependencyError, Metadata, UserAgent}
  alias SurfBoard.Clients.CDP.Client, as: CDPClient
  alias SurfBoard.SpecModule.ChromeCDP
  alias SurfBoard.Drivers.ChromeCDP.Server, as: ChromeServer
  alias SurfBoard.Launcher
  alias SurfBoard.Transport.Strategy.SharedWS

  @base_user_agent "Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 " <>
                     "(KHTML, like Gecko) Chrome/41.0.2228.0 Safari/537.36"

  defmodule Supervised do
    @moduledoc false
    # The actual Supervisor behind `Launcher.Chrome.start_link/1` —
    # split into its own module so `Launcher.Chrome` itself stays a
    # plain module of functions, matching `connect/1`'s shape, rather
    # than `use Supervisor` making the whole module implicitly one.
    use Supervisor

    alias SurfBoard.Launcher.Chrome

    def start_link({name, opts}) do
      Supervisor.start_link(__MODULE__, {name, opts}, name: Chrome.supervisor_name(name))
    end

    @impl Supervisor
    def init({name, opts}) do
      server_name = Chrome.server_name(name)

      launcher_opts = [
        name: name,
        strategy: SharedWS,
        build_template: Keyword.get(opts, :build_template, &Chrome.build_template/1),
        post_start: Keyword.get(opts, :post_start, &Chrome.post_start/2),
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
  Checks whether `start_link/1` can actually succeed — Chrome is
  installed — without starting anything. Returns
  `:ok | {:error, %SurfBoard.DependencyError{}}`, same contract as
  `SurfBoard.SpecModule.validate/0`.
  """
  @spec validate() :: :ok | {:error, DependencyError.t()}
  def validate do
    if match?({:ok, _}, SurfBoard.BrowserPaths.chrome_path()) do
      :ok
    else
      {:error,
       DependencyError.exception(
         "Chrome not found. Run `mix surf_board.install` or set SURF_BOARD_CHROME_URL."
       )}
    end
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
  anything — for a caller (like `SpecModule.ChromeCDP.default_launcher_spec/0`)
  that needs to fold a "connect to this url" launcher into a child spec
  rather than start it immediately.
  """
  @spec connect_config(String.t()) :: %SharedWS.Config{}
  def connect_config(url) do
    %SharedWS.Config{resolve_ws_url: fn -> resolve_remote_ws_url(url) end}
  end

  @doc false
  def supervisor_name(name), do: Module.concat(name, Supervisor)
  @doc false
  def server_name(name), do: Module.concat(name, Server)

  @doc false
  def build_template(opts) do
    %SurfBoard.Session{
      id: "chrome-#{System.unique_integer([:positive])}",
      url: "about:blank",
      session_url: "about:blank",
      spec_module: ChromeCDP,
      spec: ChromeCDP.spec(),
      live_view_aware?: Keyword.get(opts, :live_view_aware, false),
      capabilities: Keyword.get(opts, :capabilities, %{})
    }
  end

  @doc false
  def post_start(session, opts) do
    caller = Keyword.get(opts, :owner, self())

    # Forward console + exception events to the test caller's mailbox
    # so LogChecker.check_logs! can drain them after each operation.
    _ =
      SurfBoard.WebSocket.subscribe(
        session.bidi_pid,
        "Runtime.consoleAPICalled",
        session.browsing_context,
        caller
      )

    _ =
      SurfBoard.WebSocket.subscribe(
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

  # `url` is either a literal ws(s):// DevTools URL, or a bare HTTP
  # endpoint (host:port) that needs /json/version discovery to find
  # the actual webSocketDebuggerUrl. Mirrors
  # SpecModule.ChromeCDP.remote_url/0's own callers — kept as a separate copy
  # (not a shared helper) since it's small and each side's error
  # messages reference a different caller.
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
