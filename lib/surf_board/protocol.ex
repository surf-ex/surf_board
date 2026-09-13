defmodule SurfBoard.Protocol do
  @moduledoc false

  # Driver-agnostic dispatcher for JS evaluation and a few page-info
  # primitives. Routes to the session's own wire_protocol client — the
  # same dispatch table Browser/Element already read from session.spec,
  # rather than a second, parallel way to pick CDP vs BiDi. Shared
  # feature code (e.g. LiveViewAware) calls through here so it doesn't
  # have to branch on it.

  alias SurfBoard.Session

  @type result :: {:ok, any} | {:error, any}

  @doc """
  Evaluates a JavaScript expression and returns its value (serialized
  to an Elixir term). Equivalent to BiDi `script.evaluate` or CDP
  `Runtime.evaluate` with `returnByValue: true`.
  """
  @spec eval(Session.t(), String.t()) :: result
  def eval(%Session{spec: spec} = session, js), do: spec.wire_protocol.evaluate(session, js)

  @doc """
  Evaluates a JS expression that returns a Promise, awaits it, and
  returns the resolved value. `timeout` bounds the underlying wire
  call directly — a caller relying on a JS-side timeout to resolve
  the promise on its own (e.g. `LiveView.Aware`) needs this to fail
  as `{:error, :timeout}` if the wire call itself stalls, rather than
  block indefinitely (or until the driver's own unrelated default
  timeout) past the caller's own deadline.
  """
  @spec eval_async(Session.t(), String.t(), timeout()) :: result
  def eval_async(session, js, timeout \\ 10_000)

  def eval_async(%Session{spec: spec} = session, js, timeout),
    do: spec.wire_protocol.evaluate_async_with_timeout(session, js, timeout)

  @doc "Returns the current page URL as a string."
  @spec current_url(Session.t()) :: result
  def current_url(%Session{spec: spec} = session), do: spec.wire_protocol.current_url(session)
end
