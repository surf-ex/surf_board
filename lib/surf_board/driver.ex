defmodule SurfBoard.Driver do
  @moduledoc false

  # A driver module's only real job is lifecycle: start_session/1
  # builds a %SurfBoard.Session{} (stamping driver_spec so the session
  # is fully self-describing from then on) and end_session/1 tears it
  # down. Every browser capability (visit, click, cookies, dialogs,
  # window/frame management, ...) is dispatched by Browser.ex/Element.ex
  # calling session.driver_spec's dimension modules directly — there is
  # no per-driver module standing between them.

  alias SurfBoard.Session

  @type reason :: :not_implemented | :not_supported | any
  @type on_start_session :: {:ok, Session.t()} | {:error, reason}

  @doc """
  Invoked to start a browser session.
  """
  @callback start_session(Keyword.t()) :: on_start_session

  @doc """
  Invoked to stop a browser session.
  """
  @callback end_session(Session.t()) :: :ok | {:error, reason}
end
