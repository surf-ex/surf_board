defmodule SurfBoard.Transport.Strategy.SharedWS do
  @moduledoc false

  # Transport: ONE WebSocket per BEAM, shared across all sessions
  # via CDP's flat-session protocol. Each `start_session/1`:
  #
  #   1. Fetches the shared ws_pid from a connection-holder Agent
  #      (typically `SurfBoard.Drivers.ChromeCDP.SharedConnection`).
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

  alias SurfBoard.Transport
  alias SurfBoard.WebSocket

  @impl true
  @spec start_session(keyword) :: {:ok, SurfBoard.Session.t()} | {:error, term}
  def start_session(opts) do
    connection = Keyword.fetch!(opts, :connection)
    driver_mod = Keyword.fetch!(opts, :driver)
    template = Keyword.fetch!(opts, :session_struct)

    ws_pid = connection.get(driver_mod)

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
