defmodule SurfBoard.Transport.Strategy.SharedWS do
  @moduledoc false

  # Transport: ONE WebSocket per endpoint, shared across all sessions
  # started against it via CDP's flat-session protocol. Each
  # `start_session/1`:
  #
  #   1. Fetches the shared ws_pid from the endpoint (lazily connecting
  #      on first use — see `Endpoint.get_or_compute/3` — and caching
  #      it in that endpoint's own state, so two independently-started
  #      endpoints never share a connection).
  #   2. Creates a fresh BrowserContext on that shared WS.
  #   3. Creates a Target inside that BrowserContext (about:blank).
  #   4. Attaches to the target (flat session) → gets a sessionId
  #      that becomes the routing key for this session.
  #   5. Folds the above into the caller's `:session_struct` template
  #      via `Transport.start_session_from/3`.
  #
  # Teardown disposes the BrowserContext (which kills its targets)
  # but leaves the shared WS alone.

  @behaviour SurfBoard.Transport.Strategy

  alias SurfBoard.{Endpoint, Transport}
  alias SurfBoard.WebSocket

  defmodule Config do
    @moduledoc false
    # `resolve_ws_url` — zero-arg function returning the shared
    # browser's DevTools WebSocket URL. Deferred rather than a literal
    # `ws_url` because for a locally-launched Chrome, the URL isn't
    # known until the launched process emits it (which can take
    # seconds) — the endpoint calls this lazily, on first use, and
    # caches the resulting connection, not the URL itself.
    @enforce_keys [:resolve_ws_url]
    defstruct [:resolve_ws_url]
  end

  @impl true
  @spec start_session(keyword) :: {:ok, SurfBoard.Session.t()} | {:error, term}
  def start_session(opts) do
    endpoint = Keyword.fetch!(opts, :endpoint)
    template = Keyword.fetch!(opts, :session_struct)
    %Config{resolve_ws_url: resolve_ws_url} = Endpoint.info(endpoint).config

    ws_pid =
      Endpoint.get_or_compute(
        endpoint,
        fn ->
          # WebSocket.start_link would link to the *current caller* (the
          # session-starting process), so the shared WS would die when
          # each session's owner exits. Use `start/1` for an unlinked
          # process whose lifetime is tied to the endpoint instead.
          {:ok, pid} = WebSocket.start(resolve_ws_url.())
          pid
        end,
        &Process.alive?/1
      )

    with {:ok, %{"browserContextId" => ctx_id}} <-
           WebSocket.send_sync(ws_pid, "Target.createBrowserContext", %{}),
         {:ok, %{"targetId" => target_id}} <-
           WebSocket.send_sync(ws_pid, "Target.createTarget", %{
             url: "about:blank",
             browserContextId: ctx_id
           }),
         {:ok, session_id} <- Transport.attach_to_target(ws_pid, target_id) do
      teardown = fn _session -> Transport.dispose_browser_context(ws_pid, ctx_id) end

      acquired = %{
        ws_pid: ws_pid,
        target_id: target_id,
        session_id: session_id,
        browser_context_id: ctx_id,
        teardown_fun: teardown,
        capabilities: %{
          target_id: target_id,
          browser_context_id: ctx_id,
          flat_session_id: true,
          shared_connection: true
        }
      }

      Transport.start_session_from(acquired, template, opts)
    end
  end
end
