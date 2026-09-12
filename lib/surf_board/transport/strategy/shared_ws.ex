defmodule SurfBoard.Transport.Strategy.SharedWS do
  @moduledoc false

  # Transport: ONE WebSocket per launcher, shared across all sessions
  # started against it via CDP's flat-session protocol. Each
  # `start_session/1`:
  #
  #   1. Fetches the shared ws_pid from the launcher (lazily connecting
  #      on first use — see `Launcher.get_or_compute/3` — and caching
  #      it in that launcher's own state, so two independently-started
  #      launchers never share a connection).
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

  alias SurfBoard.{Launcher, Transport}
  alias SurfBoard.Transport.WebSocket

  defmodule Config do
    @moduledoc false
    # `resolve_ws_url` — zero-arg function returning the shared
    # browser's DevTools WebSocket URL. Deferred rather than a literal
    # `ws_url` because for a locally-launched Chrome, the URL isn't
    # known until the launched process emits it (which can take
    # seconds) — the launcher calls this lazily, on first use, and
    # caches the resulting connection, not the URL itself.
    @enforce_keys [:resolve_ws_url]
    defstruct [:resolve_ws_url]
  end

  @impl true
  @spec start_session(keyword) :: {:ok, SurfBoard.Session.t()} | {:error, term}
  def start_session(opts) do
    launcher = Keyword.fetch!(opts, :launcher)
    template = Keyword.fetch!(opts, :session_struct)
    %Config{resolve_ws_url: resolve_ws_url} = Launcher.info(launcher).config

    ws_pid =
      Launcher.get_or_compute(
        launcher,
        fn ->
          # WebSocket.start_link would link to the *current caller* (the
          # session-starting process), so the shared WS would die when
          # each session's owner exits. Use `start/1` for an unlinked
          # process whose lifetime is tied to the launcher instead.
          {:ok, pid} = WebSocket.start(resolve_ws_url.())

          # Target.detachedFromTarget only reaches a connection that
          # has target discovery enabled on the BROWSER session (no
          # sessionId) — done once here, covering every session
          # subsequently attached over this shared connection.
          {:ok, _} = WebSocket.send_sync(pid, "Target.setDiscoverTargets", %{discover: true})

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
        driver_state: %SurfBoard.DriverState{
          target_id: target_id,
          browser_context_id: ctx_id,
          flat_session_id?: true,
          shared_connection?: true
        }
      }

      Transport.start_session_from(acquired, template, opts)
    end
  end
end
