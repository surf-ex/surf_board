defmodule SurfBoard.Driver do
  @moduledoc false

  # A driver module's only real job is starting a session:
  # start_session/1 builds a %SurfBoard.Session{} (stamping driver_spec
  # so the session is fully self-describing from then on). Every
  # browser capability (visit, click, cookies, dialogs, window/frame
  # management, ...) is dispatched by Browser.ex/Element.ex calling
  # session.driver_spec's dimension modules directly — there is no
  # per-driver module standing between them. Ending a session needs no
  # driver-specific teardown either (every driver's end_session/1 was
  # identical) — SurfBoard.end_session/1 calls Transport.Protocol.stop/1
  # directly, so this behaviour has exactly one callback.

  alias SurfBoard.Session

  @type reason :: :not_implemented | :not_supported | any
  @type on_start_session :: {:ok, Session.t()} | {:error, reason}

  @doc """
  Invoked to start a browser session.
  """
  @callback start_session(Keyword.t()) :: on_start_session
end
