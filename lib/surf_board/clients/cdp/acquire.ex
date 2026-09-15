defmodule SurfBoard.Clients.CDP.Acquire do
  @moduledoc false

  # Connection-acquisition shapes genuinely shared across CDP-speaking
  # drivers — the wire sequence that turns "I have an open (or
  # about-to-open) WebSocket" into the `acquired` map
  # `SurfBoard.Clients.CDP.SessionBringUp.start_session_from/3`
  # expects, plus the matching teardown closure. Two shapes exist
  # because two drivers genuinely need different ones:
  #
  #   * `shared_ws/1` — the connection is a long-lived WebSocket shared
  #     across many sessions (Driver.ChromeCDP). Needs its own fresh
  #     BrowserContext first, so sessions started on the same shared
  #     connection don't see each other's state; teardown disposes
  #     that context (which kills its targets) but leaves the shared
  #     WS itself alone.
  #   * `fresh_ws/2` — the connection is this session's own WebSocket,
  #     already open, nothing else using it (Driver.Lightpanda's
  #     `spawn_session/1`/`connect_session/2`). No BrowserContext step
  #     — the whole connection is already scoped to one session;
  #     teardown just closes the WS (and, if `on_close` is given, runs
  #     it too — e.g. killing a spawned binary).
  #
  # Both return `{:ok, acquired} | {:error, term}` where `acquired` is
  # exactly the map `SessionBringUp.start_session_from/3` takes —
  # callers merge their own driver-specific `driver_state` fields
  # (`shared_connection?: true` for ChromeCDP, `server_pid: pid` for
  # Lightpanda's spawn mode) via `extra_driver_state`.
  #
  # `Driver.ChromeBiDi` doesn't use either shape — its bring-up
  # (session.subscribe, the preload-script bootstrap) is BiDi-specific
  # enough that sharing would cost more than it'd save; see that
  # module directly.

  alias SurfBoard.Clients.CDP.Client, as: CDPClient
  alias SurfBoard.Transport.DriverState
  alias SurfBoard.Transport.WebSocket

  @type acquired :: %{
          ws_pid: pid,
          target_id: String.t(),
          session_id: String.t(),
          browser_context_id: String.t() | nil,
          teardown_fun: (SurfBoard.Session.t() -> any),
          driver_state: DriverState.t()
        }

  @doc """
  Acquires a session on a shared, long-lived WebSocket: creates a
  fresh BrowserContext, creates a Target inside it, attaches (flat
  session). Teardown disposes the BrowserContext, leaving `ws_pid`
  itself alone.
  """
  @spec shared_ws(pid, DriverState.t()) :: {:ok, acquired} | {:error, term}
  def shared_ws(ws_pid, extra_driver_state \\ %DriverState{}) do
    with {:ok, %{"browserContextId" => ctx_id}} <-
           WebSocket.send_sync(ws_pid, "Target.createBrowserContext", %{}),
         {:ok, %{"targetId" => target_id}} <-
           WebSocket.send_sync(ws_pid, "Target.createTarget", %{
             url: "about:blank",
             browserContextId: ctx_id
           }),
         {:ok, session_id} <- CDPClient.attach_to_target(ws_pid, target_id) do
      teardown = fn _session -> CDPClient.dispose_browser_context(ws_pid, ctx_id) end

      {:ok,
       %{
         ws_pid: ws_pid,
         target_id: target_id,
         session_id: session_id,
         browser_context_id: ctx_id,
         teardown_fun: teardown,
         driver_state: %{
           extra_driver_state
           | target_id: target_id,
             browser_context_id: ctx_id,
             flat_session_id?: true
         }
       }}
    end
  end

  @doc """
  Acquires a session on a WebSocket that's already open and scoped to
  just this session: creates a Target, attaches (flat session). No
  BrowserContext step. Teardown closes `ws_pid`, then calls `on_close`
  (if given) — e.g. to kill a process this WS came from.
  """
  @spec fresh_ws(pid, DriverState.t(), (-> any) | nil) :: {:ok, acquired} | {:error, term}
  def fresh_ws(ws_pid, extra_driver_state \\ %DriverState{}, on_close \\ nil) do
    with {:ok, %{"targetId" => target_id}} <-
           WebSocket.send_sync(ws_pid, "Target.createTarget", %{url: "about:blank"}),
         {:ok, session_id} <- CDPClient.attach_to_target(ws_pid, target_id) do
      teardown = fn _session ->
        CDPClient.close_ws(ws_pid)
        if on_close, do: on_close.()
        :ok
      end

      {:ok,
       %{
         ws_pid: ws_pid,
         target_id: target_id,
         session_id: session_id,
         browser_context_id: nil,
         teardown_fun: teardown,
         driver_state: %{extra_driver_state | target_id: target_id, flat_session_id?: true}
       }}
    end
  end
end
