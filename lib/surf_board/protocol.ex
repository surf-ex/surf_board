defmodule SurfBoard.Protocol do
  @moduledoc false

  # Spec-agnostic dispatcher for JS evaluation and a few page-info
  # primitives. Routes to the CDP or BiDi client based on the session's
  # spec module. Shared feature code (e.g. LiveViewAware) calls through
  # here so it doesn't have to branch on it.

  alias SurfBoard.Session

  @type result :: {:ok, any} | {:error, any}

  @doc """
  Evaluates a JavaScript expression and returns its value (serialized
  to an Elixir term). Equivalent to BiDi `script.evaluate` or CDP
  `Runtime.evaluate` with `returnByValue: true`.
  """
  @spec eval(Session.t(), String.t()) :: result
  def eval(%Session{spec_module: spec_module} = session, js)
      when spec_module in [SurfBoard.Specs.LightpandaCDP, SurfBoard.Specs.ChromeCDP],
      do: SurfBoard.Clients.CDP.Client.evaluate(session, js)

  def eval(%Session{spec_module: SurfBoard.Specs.ChromeBiDi} = session, js),
    do: SurfBoard.Clients.BiDi.Client.evaluate(session, js)

  @doc """
  Evaluates a JS expression that returns a Promise, awaits it, and
  returns the resolved value.
  """
  @spec eval_async(Session.t(), String.t(), timeout()) :: result
  def eval_async(session, js, timeout \\ 10_000)

  def eval_async(%Session{spec_module: spec_module} = session, js, _timeout)
      when spec_module in [SurfBoard.Specs.LightpandaCDP, SurfBoard.Specs.ChromeCDP],
      do: SurfBoard.Clients.CDP.Client.evaluate_async(session, js)

  def eval_async(%Session{spec_module: SurfBoard.Specs.ChromeBiDi} = session, js, _timeout),
    do: SurfBoard.Clients.BiDi.Client.evaluate_async(session, js)

  @doc "Returns the current page URL as a string."
  @spec current_url(Session.t()) :: result
  def current_url(%Session{spec_module: spec_module} = session)
      when spec_module in [SurfBoard.Specs.LightpandaCDP, SurfBoard.Specs.ChromeCDP],
      do: SurfBoard.Clients.CDP.Client.current_url(session)

  def current_url(%Session{spec_module: SurfBoard.Specs.ChromeBiDi} = session),
    do: SurfBoard.Clients.BiDi.Client.current_url(session)
end
