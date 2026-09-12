defmodule SurfBoard.Clients.BiDi.Frames do
  @moduledoc false

  # IFrame focus for Chrome over BiDi. Pushes/pops browsing-context id
  # strings onto the transport actor's `frame_stack` — the same
  # mechanism `Clients.CDP.Frames` uses (there it holds
  # executionContextId integers instead), not per-process state.
  # `Clients.BiDi.Client.ctx/1` reads the top of this stack (via
  # `Protocol.current_context_id/1`), falling back to the session's own
  # `browsing_context` (the currently *focused window*, managed
  # separately by `Clients.BiDi.Windows`) when the stack is empty, to
  # decide which context every BiDi wire op targets.

  @behaviour SurfBoard.Frames

  alias SurfBoard.{Element, Session}
  alias SurfBoard.Clients.BiDi.Client, as: BiDiClient
  alias SurfBoard.Transport.Protocol

  @impl true
  def focus_frame(%Session{} = session, %Element{} = iframe) do
    case BiDiClient.child_context_for_iframe(session, iframe) do
      {:ok, child_ctx} ->
        :ok = Protocol.push_frame(session, child_ctx)
        {:ok, nil}

      _ ->
        {:ok, nil}
    end
  end

  # Browser.focus_default_frame/1 calls driver.focus_frame(session, nil)
  # to escape all the way out — clear the frame stack entirely, same
  # as Clients.CDP.Frames does.
  def focus_frame(%Session{pid: pid}, nil) when is_pid(pid) do
    GenServer.call(pid, :reset_frame_stack)
    {:ok, nil}
  end

  def focus_frame(_, _), do: {:ok, nil}

  @impl true
  def focus_parent_frame(%Session{} = session) do
    :ok = Protocol.pop_frame(session)
    {:ok, nil}
  end

  def focus_parent_frame(_), do: {:ok, nil}
end
