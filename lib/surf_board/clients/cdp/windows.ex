defmodule SurfBoard.Clients.CDP.Windows do
  @moduledoc false

  # CDP window/tab management — uses Target.* commands against the
  # shared WS to enumerate / attach / close tabs in this session's
  # browser context. Currently only ChromeCDP points at this; Lightpanda
  # uses Windows.Single instead because its CDP support doesn't cover
  # Target.* multi-window handling, not because this logic is
  # Chrome-specific.

  @behaviour SurfBoard.Windows

  alias SurfBoard.{Element, Session}
  alias SurfBoard.Clients.CDP.Client, as: CDPClient
  alias SurfBoard.Transport.Protocol
  alias SurfBoard.WebSocket

  @impl true
  def window_handle(%Session{pid: pid} = session) when is_pid(pid) do
    # The session struct in the caller's hand may carry a stale
    # target_id (focus_window/2 mutates the live state in the
    # GenServer). Re-fetch the current state.
    case GenServer.call(pid, :get_session) do
      %Session{driver_state: driver_state} -> {:ok, driver_state.target_id}
      _ -> {:ok, session.driver_state.target_id}
    end
  catch
    :exit, _ -> {:ok, session.driver_state.target_id}
  end

  def window_handle(%Session{} = session) do
    {:ok, session.driver_state.target_id}
  end

  def window_handle(%Element{} = element) do
    window_handle(Element.root_session(element))
  end

  @impl true
  def window_handles(parent) do
    session = Element.root_session(parent)
    ws_pid = session.bidi_pid
    ctx_id = session.driver_state.browser_context_id

    case WebSocket.send_sync(ws_pid, "Target.getTargets", %{}) do
      {:ok, %{"targetInfos" => targets}} ->
        handles =
          targets
          |> Enum.filter(fn t ->
            t["type"] == "page" && t["browserContextId"] == ctx_id
          end)
          |> Enum.map(fn t -> t["targetId"] end)

        {:ok, handles}

      _ ->
        {:ok, [session.driver_state.target_id]}
    end
  end

  @impl true
  def focus_window(parent, target_id) when is_binary(target_id) do
    session = Element.root_session(parent)
    ws_pid = session.bidi_pid

    # Switch the Session's CDP target by re-attaching to the new
    # one (gets a new sessionId). Update session.browsing_context so
    # subsequent cdp_send opts route there.
    case WebSocket.send_sync(ws_pid, "Target.attachToTarget", %{
           targetId: target_id,
           flatten: true
         }) do
      {:ok, %{"sessionId" => session_id}} ->
        # Update session struct in the GenServer (the caller's struct
        # may be stale; window_handle/1 re-fetches via :get_session).
        # `:focus_window` (not `:update_browsing_context`) so this
        # marks the session as switched — see Protocol.focus_window/3.
        if session.pid do
          GenServer.call(session.pid, {:focus_window, session_id, target_id})
        end

        new_session = %{
          session
          | browsing_context: session_id,
            driver_state: %{session.driver_state | target_id: target_id}
        }

        # All four setup commands fire-and-forget so they pipeline on
        # the wire instead of round-tripping in series. CDPClient's
        # enable_page_lifecycle_events / install_bootstrap already use
        # cdp_cast internally; the inline IIFE was the last sync send,
        # so cast it too. Subsequent cdp_send calls (e.g. visit) will
        # naturally barrier until all four land.
        _ = CDPClient.enable_page_lifecycle_events(new_session)
        _ = CDPClient.install_bootstrap(new_session)

        # The new tab may have loaded its document BEFORE we attached.
        # Page.addScriptToEvaluateOnNewDocument (queued by
        # install_bootstrap) only fires for *future* documents, so the
        # bootstrap won't be present until the next nav. Run the IIFE
        # inline against the current document so subsequent finds
        # work without needing a reload.
        CDPClient.cdp_cast(new_session, "Runtime.evaluate", %{
          expression: SurfBoard.Bootstrap.cdp_iife(),
          returnByValue: true
        })

        {:ok, nil}

      err ->
        err
    end
  end

  @impl true
  def close_window(%Session{pid: pid} = session) when is_pid(pid) do
    # The caller's session struct may carry a stale target_id —
    # focus_window/2 mutates the live state in the GenServer. Re-fetch
    # so close_window closes the *currently focused* target, not the
    # one the caller's struct was first built with.
    current =
      try do
        GenServer.call(pid, :get_session)
      catch
        :exit, _ -> session
      end

    target_id = current.driver_state.target_id
    # Mark this exact flat sessionId as an intentional close before
    # asking Chrome to close it — Target.detachedFromTarget for it is
    # about to fire, and would otherwise look identical to that target
    # crashing (see Clients.CDP.Wire).
    :ok = Protocol.closing_window(current, current.browsing_context)
    ws_pid = session.bidi_pid
    _ = WebSocket.send_sync(ws_pid, "Target.closeTarget", %{targetId: target_id})
    {:ok, nil}
  end

  def close_window(%Session{} = session) do
    target_id = session.driver_state.target_id
    ws_pid = session.bidi_pid
    _ = WebSocket.send_sync(ws_pid, "Target.closeTarget", %{targetId: target_id})
    {:ok, nil}
  end

  def close_window(%Element{} = element), do: close_window(Element.root_session(element))
end
