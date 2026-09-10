defmodule SurfBoard.Transport.Strategy do
  @moduledoc false

  # The behaviour every Transport.Strategy.* module implements — see
  # SurfBoard.Transport's moduledoc for the full picture of what
  # varies across strategies and why.

  @doc """
  Brings up a session: acquires whatever connection this strategy
  needs, builds `%SurfBoard.Session{}` from the caller's
  `:session_struct` template (passed via `opts`), and returns it
  ready for use — GenServer up, page-lifecycle/bootstrap/frame
  tracking (or BiDi's equivalents) already installed.
  """
  @callback start_session(opts :: keyword) ::
              {:ok, SurfBoard.Session.t()} | {:error, term}
end
