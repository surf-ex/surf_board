defmodule SurfBoard.Driver.ExternalChromeCDP do
  @moduledoc false

  # Chrome over CDP, connecting to a Chrome instance this driver doesn't
  # manage: ONE WebSocket per running instance, shared across every
  # session started against it via CDP's flat-session protocol. This
  # module IS the launcher — a GenServer holding the connection config
  # plus a lazily-connected, cached ws_pid.
  #
  # Fully self-contained on purpose — no shared module with
  # `Driver.SharedChromeCDP` beyond `SurfBoard.Clients.CDP.Client`/
  # `SessionBringUp` (genuinely shared protocol/bring-up code, used by
  # other drivers too). Spawning and owning a local Chrome process is a
  # different enough job (a process to supervise, a different failure
  # mode — "Chrome not installed" vs. "no remote_url configured") that
  # it's a fully separate driver, not a branch inside this one.
  #
  #   {:ok, pid} = Driver.ExternalChromeCDP.connect(url: "ws://localhost:9222/...")
  #   {:ok, session} = Driver.ExternalChromeCDP.start_session(pid, [])
  #
  # Each `start_session/2`:
  #
  #   1. Fetches the shared ws_pid from this process's own state
  #      (lazily connecting on first use, caching it for every session
  #      that follows — see `handle_call/3`'s `:ws_pid` clause).
  #   2. Creates a fresh BrowserContext on that shared WS.
  #   3. Creates a Target inside that BrowserContext (about:blank).
  #   4. Attaches to the target (flat session) → gets a sessionId that
  #      becomes the routing key for this session.
  #   5. Folds the above into a session template via
  #      `SessionBringUp.start_session_from/3`.
  #
  # Teardown disposes the BrowserContext (which kills its targets) but
  # leaves the shared WS alone.

  use GenServer

  alias SurfBoard.DependencyError
  alias SurfBoard.Clients.CDP.Client, as: CDPClient
  alias SurfBoard.Clients.CDP.SessionBringUp
  alias SurfBoard.Driver.Spec
  alias SurfBoard.Launcher.{Metadata, UserAgent}

  @base_user_agent "Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 " <>
                     "(KHTML, like Gecko) Chrome/41.0.2228.0 Safari/537.36"

  # Full support for everything CDP offers — no overrides needed on
  # top of CDPClient.default_strategies/0. Computed at runtime, not in
  # a module attribute — calling CDPClient.default_strategies/0 at
  # compile time would put a (compile) edge from this module to
  # CDPClient in `mix xref graph`, coupling this driver's compilation
  # to CDP client internals for no benefit (spec/0 isn't called often
  # enough to need attribute-time precomputation).
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

  @doc """
  Connects to a Chrome instance this doesn't manage — no process to
  spawn, no Supervisor. `:url` is required: a literal ws(s):// DevTools
  URL, or a bare host:port DevTools endpoint (discovered via
  /json/version on first use). Pass `:name` to register the process;
  omitted, you get an anonymous pid back.
  """
  @spec connect(keyword) :: GenServer.on_start()
  def connect(opts) do
    url = Keyword.fetch!(opts, :url)
    config = %{resolve_ws_url: fn -> resolve_remote_ws_url(url) end}
    start_worker(Keyword.get(opts, :name), config, opts)
  end

  @default_name __MODULE__.Default

  @doc """
  A child spec for this driver's default instance, meant to be added
  to a supervision tree the normal way. Connects to `remote_url/0`
  (`SURF_BOARD_CHROME_URL`, or `config :surf_board, :chrome_cdp, remote_url: "..."`).
  This driver starts nothing on its own; adding this to a supervisor
  is what actually brings one up.
  """
  def default_child_spec do
    %{
      id: @default_name,
      start: {__MODULE__, :start_link_connect, [[name: @default_name, url: remote_url()]]}
    }
  end

  @doc false
  def start_link_connect(opts), do: connect(opts)

  @doc false
  def default_name, do: @default_name

  @doc false
  def remote_url do
    SurfBoard.Launcher.BrowserPaths.chrome_url() ||
      Application.get_env(:surf_board, :chrome_cdp, []) |> Keyword.get(:remote_url)
  end

  @doc """
  Checks whether this driver's default instance can actually connect —
  `remote_url/0` resolves to something — without starting anything.
  Returns `:ok | {:error, %SurfBoard.DependencyError{}}`.
  """
  @spec validate() :: :ok | {:error, DependencyError.t()}
  def validate do
    if remote_url() do
      :ok
    else
      {:error,
       DependencyError.exception(
         "connection: :external configured, but no remote_url is set. " <>
           "Set SURF_BOARD_CHROME_URL or config :surf_board, :chrome_cdp, remote_url: \"...\"."
       )}
    end
  end

  # ----- Session lifecycle -----

  @doc """
  Starts a new session against `server` (a pid, or the name a
  `connect/1` instance was registered under).

  Only the cached shared ws_pid lookup runs inside `server`'s own
  process (a brief `GenServer.call`, `:get_ws_pid`) — the actual
  session-start sequence (BrowserContext/Target/attach wire round
  trips, session bring-up) runs in the CALLING process. Serializing
  all of that through one GenServer would turn concurrent session
  starts into a queue behind a single mailbox; the shared ws_pid is
  the only thing that genuinely needs one owner.
  """
  @spec start_session(GenServer.server(), keyword) ::
          {:ok, SurfBoard.Session.t()} | {:error, term}
  def start_session(server, opts) when server != nil and is_list(opts) do
    ws_pid = GenServer.call(server, :get_ws_pid)
    template = build_template(opts)

    with {:ok, %{"browserContextId" => ctx_id}} <-
           SurfBoard.Transport.WebSocket.send_sync(ws_pid, "Target.createBrowserContext", %{}),
         {:ok, %{"targetId" => target_id}} <-
           SurfBoard.Transport.WebSocket.send_sync(ws_pid, "Target.createTarget", %{
             url: "about:blank",
             browserContextId: ctx_id
           }),
         {:ok, session_id} <- CDPClient.attach_to_target(ws_pid, target_id) do
      teardown = fn _session -> CDPClient.dispose_browser_context(ws_pid, ctx_id) end

      acquired = %{
        ws_pid: ws_pid,
        target_id: target_id,
        session_id: session_id,
        browser_context_id: ctx_id,
        teardown_fun: teardown,
        driver_state: %SurfBoard.Transport.DriverState{
          target_id: target_id,
          browser_context_id: ctx_id,
          flat_session_id?: true,
          shared_connection?: true
        }
      }

      with {:ok, session} <- SessionBringUp.start_session_from(acquired, template, opts) do
        post_start(session, opts)
      end
    end
  end

  @doc """
  Starts a session against this driver's default instance (see
  `default_child_spec/0`).
  """
  @spec start_session(keyword) :: {:ok, SurfBoard.Session.t()} | {:error, term}
  def start_session(opts) when is_list(opts) do
    start_session(@default_name, opts)
  end

  # ----- GenServer -----
  #
  # This process holds exactly one piece of state: the lazily-connected,
  # cached shared ws_pid. It does no session-start work itself — see
  # start_session/2's moduledoc above for why.

  @doc false
  def start_worker(name, config, opts) do
    start_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, config, start_opts ++ Keyword.take(opts, [:name]))
  end

  @impl GenServer
  def init(%{resolve_ws_url: resolve_ws_url}) do
    {:ok, %{resolve_ws_url: resolve_ws_url, ws_pid: nil}}
  end

  @impl GenServer
  def handle_call(:get_ws_pid, _from, state) do
    {ws_pid, state} = ensure_ws_pid(state)
    {:reply, ws_pid, state}
  end

  defp ensure_ws_pid(%{ws_pid: pid} = state) when is_pid(pid) do
    if Process.alive?(pid) do
      {pid, state}
    else
      connect_ws(state)
    end
  end

  defp ensure_ws_pid(state), do: connect_ws(state)

  defp connect_ws(%{resolve_ws_url: resolve_ws_url} = state) do
    # `WebSocket.start_link` would link to the *current caller* (this
    # GenServer, since connect_ws/1 runs inside handle_call/3), so the
    # shared WS would die if this process ever crashed anyway — but we
    # still use `start/1` for an unlinked process whose lifetime is
    # tied to this GenServer's explicit lifecycle, not to link
    # propagation. Cached here, in this process's own state, so two
    # independently-started instances never share a connection.
    {:ok, pid} = SurfBoard.Transport.WebSocket.start(resolve_ws_url.())

    # Target.detachedFromTarget only reaches a connection that has
    # target discovery enabled on the BROWSER session (no sessionId)
    # — done once here, covering every session subsequently attached
    # over this shared connection.
    {:ok, _} =
      SurfBoard.Transport.WebSocket.send_sync(pid, "Target.setDiscoverTargets", %{discover: true})

    {pid, %{state | ws_pid: pid}}
  end

  defp build_template(opts) do
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

  defp post_start(session, opts) do
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

    # `:base_url`/`:max_wait_time` govern later calls rather than
    # session startup, so they ride on the session — that way an
    # application's own session isn't governed by whatever a test
    # suite configured globally.
    session_opts = Keyword.take(opts, [:base_url, :max_wait_time])
    {:ok, %{session | session_opts: session_opts}}
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
