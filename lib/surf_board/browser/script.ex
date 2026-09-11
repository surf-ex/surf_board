defmodule SurfBoard.Browser.Script do
  @moduledoc false

  # execute_script/2,3,4, execute_script_async/2,3,4. Depends only on
  # Browser.Internal (spec/1). execute_script/4 additionally calls
  # maybe_snapshot_page_id/1 — a LiveView-patch-await concern kept
  # inline here (a single, self-contained private helper) rather than
  # justifying a dependency on Browser.LiveViewPatch for one call.

  alias SurfBoard.Browser.Internal
  alias SurfBoard.Session

  def execute_script(session, script) do
    execute_script(session, script, [])
  end

  def execute_script(session, script, arguments) when is_list(arguments) do
    execute_script(session, script, arguments, fn _ -> nil end)
  end

  def execute_script(session, script, callback) when is_function(callback) do
    execute_script(session, script, [], callback)
  end

  def execute_script(%Session{} = parent, script, arguments, callback)
      when is_list(arguments) and is_function(callback) do
    parent = maybe_snapshot_page_id(parent)
    {:ok, value} = Internal.spec(parent).wire_protocol.evaluate(parent, script, arguments)
    callback.(value)
    parent
  end

  def execute_script_async(session, script) do
    execute_script_async(session, script, [])
  end

  def execute_script_async(session, script, arguments) when is_list(arguments) do
    execute_script_async(session, script, arguments, fn _ -> nil end)
  end

  def execute_script_async(session, script, callback) when is_function(callback) do
    execute_script_async(session, script, [], callback)
  end

  def execute_script_async(%Session{} = parent, script, arguments, callback)
      when is_list(arguments) and is_function(callback) do
    {:ok, value} = Internal.spec(parent).wire_protocol.evaluate_async(parent, script, arguments)
    callback.(value)
    parent
  end

  defp maybe_snapshot_page_id(%Session{pending_await: nil} = session) when is_struct(session) do
    if session.live_view_aware? and Internal.remote_session?(session) do
      SurfBoard.LiveView.defer_next_patch(session)
    else
      session
    end
  end

  defp maybe_snapshot_page_id(parent), do: parent
end
