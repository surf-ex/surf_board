defmodule SurfBoard.Browser.Dialogs do
  @moduledoc false

  # accept_alert/2, accept_confirm/2, dismiss_confirm/2,
  # accept_prompt/2,3, dismiss_prompt/2. Depends only on
  # Browser.Internal (spec/1).

  alias SurfBoard.Browser.Internal
  alias SurfBoard.Session

  def accept_alert(%Session{} = session, fun) do
    Internal.spec(session).dialogs.accept_alert(session, fun)
  end

  def accept_confirm(%Session{} = session, fun) do
    Internal.spec(session).dialogs.accept_confirm(session, fun)
  end

  def dismiss_confirm(%Session{} = session, fun) do
    Internal.spec(session).dialogs.dismiss_confirm(session, fun)
  end

  def accept_prompt(%Session{} = session, fun) do
    do_accept_prompt(session, nil, fun)
  end

  def accept_prompt(%Session{} = session, [with: input_value], fun) when is_binary(input_value) do
    do_accept_prompt(session, input_value, fun)
  end

  defp do_accept_prompt(%Session{} = session, input_value, fun) do
    Internal.spec(session).dialogs.accept_prompt(session, input_value, fun)
  end

  def dismiss_prompt(%Session{} = session, fun) do
    Internal.spec(session).dialogs.dismiss_prompt(session, fun)
  end
end
