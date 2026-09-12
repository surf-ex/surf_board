defmodule SurfBoard.Transport.Strategy.BiDi do
  @moduledoc false

  # transport for chromium-bidi: one POST → one WS → one Chrome.
  #
  # The chromium-bidi server (priv/bidi-server/run.mjs) exposes a
  # WebDriver-style HTTP `POST /session` that pre-binds a fresh
  # browser session to the WebSocket upgrade. Each test session does
  # its own POST, opens the returned WS, and runs BiDi commands
  # directly — no userContext multiplexing, no shared connection.
  #
  # ## Phase A scope
  #
  # Brings up the session via:
  #   1. POST /session → webSocketUrl
  #   2. open WS via SessionActor (which wraps BiDi.WebSocketClient)
  #   3. browsingContext.create → context id
  #
  # Phase B will install lifecycle subscriptions; phase C the
  # bootstrap preload script + script.message routing.

  @behaviour SurfBoard.Transport.Strategy

  alias SurfBoard.Transport.Strategy.BiDi.Handshake
  alias SurfBoard.Transport.Actor
  alias SurfBoard.Transport.Protocol
  alias SurfBoard.Clients.BiDi.Wire
  alias SurfBoard.Drivers.ChromeBiDi.WebSocketClient
  alias SurfBoard.{Launcher, Session}

  defmodule Config do
    @moduledoc false
    # `base_url` — the chromium-bidi server's HTTP base URL (e.g.
    # `http://localhost:12345`).
    # `capabilities` — WebDriver session-creation capabilities for the
    # POST /session body (distinct from `session_struct.capabilities`,
    # which is SurfBoard's own session bookkeeping) — nil uses
    # Handshake's default.
    @enforce_keys [:base_url]
    defstruct [:base_url, :capabilities]
  end

  @doc """
  Bring up a new BiDi session.

  Required opts:
    * `:launcher`       — a started `SurfBoard.Launcher` wrapping `%Config{base_url: ...}`
    * `:session_struct` — `%SurfBoard.Session{}` template; this
                          function fills in `pid`, `bidi_pid` and
                          `browsing_context`.

  Optional:
    * `:owner`        — process to monitor (defaults to caller)
    * `:teardown_fun` — 1-arity, called from terminate/2
  """
  @impl true
  @spec start_session(keyword) :: {:ok, Session.t()} | {:error, term}
  def start_session(opts) do
    launcher = Keyword.fetch!(opts, :launcher)
    %Config{base_url: base_url, capabilities: caps} = Launcher.info(launcher).config
    session_struct = Keyword.fetch!(opts, :session_struct)
    teardown_fun = Keyword.get(opts, :teardown_fun, fn _ -> :ok end)
    owner = Keyword.get(opts, :owner, self())

    handshake_opts = if caps, do: [capabilities: caps], else: []

    # chromium-bidi's session.subscribe can transiently time out on
    # slow runners. Retry the WHOLE handshake → SessionActor.start_link →
    # initial-context block on `{:error, {:subscribe_failed, _}}` so
    # tests aren't held responsible for protocol-level flakes.
    start_with_retry(base_url, handshake_opts, session_struct, teardown_fun, owner, 4)
  end

  defp start_with_retry(base_url, handshake_opts, session_struct, teardown_fun, owner, retries) do
    with {:ok, ws_url} <- Handshake.post_session(base_url, handshake_opts),
         {:ok, socket_pid} <- WebSocketClient.start_link(ws_url),
         {:ok, session} <- start_actor(socket_pid, session_struct, teardown_fun, owner),
         :ok <- subscribe_load_events(socket_pid, session.pid),
         {:ok, context_id} <- find_or_create_initial_context(session),
         :ok <- install_bootstrap(session) do
      session = %{session | browsing_context: context_id, bidi_pid: socket_pid}

      # Mirror the actor's session-struct view so subsequent reads
      # via :get_session also see the populated browsing_context —
      # ctx/1 now depends on this being correct (previously nothing
      # read the actor's copy, only the struct returned below, so this
      # call's argument order went unnoticed: session_id is the
      # context id, BiDi has no separate target_id concept).
      :ok = GenServer.call(session.pid, {:update_browsing_context, context_id, nil})

      {:ok, session}
    else
      {:error, {:subscribe_failed, _}} when retries > 0 ->
        Process.sleep(250)

        start_with_retry(
          base_url,
          handshake_opts,
          session_struct,
          teardown_fun,
          owner,
          retries - 1
        )

      {:error, {:timeout, {GenServer, :call, _}}} when retries > 0 ->
        Process.sleep(250)

        start_with_retry(
          base_url,
          handshake_opts,
          session_struct,
          teardown_fun,
          owner,
          retries - 1
        )

      other ->
        other
    end
  end

  defp start_actor(socket_pid, session_struct, teardown_fun, owner) do
    config = %Actor.Config{
      socket: {:remote, WebSocketClient, socket_pid},
      load: :wake_once,
      wire: Wire
    }

    case Actor.start_link(
           config: config,
           init_fun: fn -> {:ok, session_struct} end,
           teardown_fun: teardown_fun,
           owner: owner
         ) do
      {:ok, session} ->
        {:ok, session}

      {:error, reason} ->
        # The actor never came up to own socket_pid's lifecycle —
        # nothing else will close it, so do it here rather than leak
        # a WebSocketClient/chromium-bidi connection per failed retry.
        try do
          WebSocketClient.close(socket_pid)
        catch
          :exit, _ -> :ok
        end

        {:error, reason}
    end
  end

  # Subscribe load milestones + bootstrap channel + log entries in a
  # single server-side session.subscribe call. WSC-side forward-to-
  # this-pid is set up for the events the actor needs to consume
  # (loads + script.message); log.entryAdded is forwarded to other
  # subscribers (e.g. the test process for LogChecker).
  defp subscribe_load_events(socket_pid, actor_pid) do
    events = [
      "browsingContext.load",
      "browsingContext.domContentLoaded",
      "script.message",
      "log.entryAdded",
      # Supplies the document's HTTP status for `Browser.status/1`.
      "network.responseCompleted",
      # Lets Wire.handle_event/3 fail every pending call immediately
      # if this session's context disappears, instead of each one
      # timing out on its own — see Clients.BiDi.Wire's moduledoc.
      "browsingContext.contextDestroyed"
    ]

    Enum.each(events, fn ev ->
      WebSocketClient.subscribe(socket_pid, ev, :global, actor_pid)
    end)

    # The first session.subscribe after browser launch can take a
    # while on slow runners (GHA Linux) because chromium-bidi's Mapper
    # is still settling. 12s lets us retry up to 4× (start_with_retry)
    # and still fit inside ExUnit's default 60s test timeout.
    # Subsequent subscribes are fast (<200ms) so the actual cap rarely
    # fires.
    timeout = Application.get_env(:surf_board, :bidi_subscribe_timeout_ms, 12_000)

    case WebSocketClient.send_command(
           socket_pid,
           "session.subscribe",
           %{"events" => events},
           timeout
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:subscribe_failed, reason}}
    end
  end

  # Chrome launches with a default about:blank tab. Reuse it instead
  # of creating a sibling — otherwise window_handles sees TWO tabs at
  # session start (the leftover plus our newly-created one), which
  # confuses tests that check tab counts.
  defp find_or_create_initial_context(session) do
    case Protocol.cdp_send(session, "browsingContext.getTree", %{}, []) do
      {:ok, %{"contexts" => [%{"context" => existing} | _]}} when is_binary(existing) ->
        {:ok, existing}

      _ ->
        case Protocol.cdp_send(session, "browsingContext.create", %{"type" => "tab"}, []) do
          {:ok, %{"context" => context_id}} -> {:ok, context_id}
          err -> err
        end
    end
  end

  # Install the shared SurfBoard.Bootstrap as a BiDi preload script.
  # The script receives `__surfboard` as a channel callback parameter;
  # any payload it sends comes back as a `script.message` event that
  # the SessionActor decodes into find / page_ready dispatches.
  defp install_bootstrap(session) do
    fn_decl = SurfBoard.Bootstrap.bidi_preload(session.live_view_aware?)
    channel_arg = [%{"type" => "channel", "value" => %{"channel" => "__surfboard"}}]

    case Protocol.cdp_send(
           session,
           "script.addPreloadScript",
           %{"functionDeclaration" => fn_decl, "arguments" => channel_arg},
           []
         ) do
      {:ok, _} -> :ok
      err -> err
    end
  end
end
