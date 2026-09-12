defmodule SurfBoard.Clients.BiDi.Windows do
  @moduledoc false

  # Window/tab management for Chrome over BiDi. Uses
  # `BiDiClient.window_handles/1` to enumerate, and stores "which
  # window is focused" as the session's own `browsing_context` on the
  # transport actor — the same mechanism `Clients.CDP.Windows` uses,
  # not per-process state. Any process holding this session sees the
  # same focused window.

  @behaviour SurfBoard.Windows

  alias SurfBoard.{Element, Session}
  alias SurfBoard.Clients.BiDi.Client, as: BiDiClient
  alias SurfBoard.Transport.Protocol

  @impl true
  def window_handle(%Session{pid: pid} = session) when is_pid(pid) do
    # The caller's struct may be stale (focus_window/2 mutates the
    # live actor state) — re-fetch, mirroring Clients.CDP.Windows.
    case GenServer.call(pid, :get_session) do
      %Session{browsing_context: handle} -> {:ok, handle}
      _ -> {:ok, session.browsing_context}
    end
  catch
    :exit, _ -> {:ok, session.browsing_context}
  end

  def window_handle(%Session{} = session), do: {:ok, session.browsing_context}

  def window_handle(%Element{} = element), do: window_handle(Element.root_session(element))

  @impl true
  def window_handles(parent) do
    BiDiClient.window_handles(Element.root_session(parent))
  end

  @impl true
  def focus_window(parent, handle) when is_binary(handle) do
    session = Element.root_session(parent)

    if session.pid do
      :ok = Protocol.focus_window(session, handle, nil)
      # Switching windows invalidates any iframe focus from the
      # previous window — same reset Clients.CDP.Frames does for
      # focus_default_frame.
      GenServer.call(session.pid, :reset_frame_stack)
    end

    {:ok, nil}
  end

  @impl true
  def close_window(parent) do
    session = Element.root_session(parent)
    handle = with({:ok, h} <- window_handle(session), do: h)

    # Mark this exact context as an intentional close before asking
    # Chrome to close it — browsingContext.contextDestroyed for it is
    # about to fire, and would otherwise look identical to that
    # context crashing (see Clients.BiDi.Wire).
    if session.pid && is_binary(handle) do
      :ok = Protocol.closing_window(session, handle)
    end

    case BiDiClient.close_window(session, handle) do
      :ok -> {:ok, nil}
      err -> err
    end
  end
end
