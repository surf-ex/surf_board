defmodule SurfBoard.Browser.Internal do
  @moduledoc false

  # Cross-cutting helpers every other Browser.* submodule depends on:
  # resolving a session/spec off a parent (Session or Element), the
  # retry loop, and wait-time bookkeeping. Depends on nothing else
  # under Browser.*.

  alias SurfBoard.Element
  alias SurfBoard.Session

  @default_max_wait_time 3_000

  @type sync_result :: {:ok, any()} | {:error, any()}

  @doc """
  Attempts to synchronize with the browser. This is most often used to
  execute queries repeatedly until it either exceeds the time limit or
  returns a success.

  ## Note

  It is possible that this function never halts. Whenever we experience a stale
  reference error we retry the query without checking to see if we've run over
  our time. In practice we should eventually be able to query the DOM in a stable
  state. However, if this error does continue to occur it will cause surf_board to
  loop forever (or until the test is killed by exunit).
  """
  @spec retry((-> sync_result), non_neg_integer()) :: sync_result()
  def retry(f, start_time \\ current_time()) do
    case f.() do
      {:ok, result} ->
        {:ok, result}

      {:error, :stale_reference} ->
        retry(f, start_time)

      {:error, :invalid_selector} ->
        {:error, :invalid_selector}

      {:error, e} ->
        if max_time_exceeded?(nil, start_time) do
          {:error, e}
        else
          retry(f, start_time)
        end
    end
  end

  @doc false
  def retry_match(predicate) do
    case retry(fn ->
           if predicate.(), do: {:ok, true}, else: {:error, false}
         end) do
      {:ok, true} -> true
      _ -> false
    end
  end

  @doc false
  def get_session(%Session{} = s), do: s
  def get_session(%Element{parent: p}), do: get_session(p)
  def get_session(_), do: nil

  @doc false
  def spec(%Session{spec: spec}), do: spec
  def spec(%Element{} = element), do: spec(Element.root_session(element))

  # A real session (as opposed to nil, e.g. from get_session/1 on a
  # detached element). Every current spec's wire_protocol ships
  # element ops through W.run, so this is a nil-guard, not a spec
  # capability check — if a future spec's wire_protocol genuinely
  # can't support the W.run pipeline, that's a Spec field to add
  # then, not something to guess at now.
  @doc false
  def remote_session?(%Session{}), do: true
  def remote_session?(_), do: false

  @doc false
  def in_frame?(%Session{} = session) do
    Process.get({:cdp_frame_stack, session.id}, []) != [] or
      Process.get({:surf_board_frame_context, session.id}) != nil
  end

  @doc false
  def in_switched_window?(%Session{} = session) do
    Process.get({:cdp_current_target, session.id}) != nil or
      Process.get({:surf_board_focused_context, session.id}) != nil
  end

  @doc false
  def current_time do
    :erlang.monotonic_time(:milli_seconds)
  end

  # `retry/2` is a public arity-2 function taking a closure, with no session
  # to hand — those retries fall back to the configured budget. The paths
  # that *do* have a session (find, await_text/value, query_timeout) pass it,
  # so a session-scoped `:max_wait_time` governs the waits that matter.
  @doc false
  def max_time_exceeded?(session, start_time) do
    current_time() - start_time > max_wait_time(session)
  end

  @doc false
  def max_wait_time(session) do
    Keyword.get(session_opts(session), :max_wait_time) ||
      SurfBoard.Config.get(:max_wait_time, @default_max_wait_time)
  end

  # Per-session overrides passed to start_session/1 win over config, so an
  # application's scraping session isn't governed by whatever the test
  # suite configured (or vice versa). See `SurfBoard.Config`.
  @doc false
  def session_opts(%Session{session_opts: opts}) when is_list(opts), do: opts
  def session_opts(_), do: []

  @doc false
  def request_url(session, path) do
    base_url = String.trim_trailing(base_url(session), "/")
    path = String.trim_leading(path, "/")

    "#{base_url}/#{path}"
  end

  @doc false
  def base_url(session) do
    Keyword.get(session_opts(session), :base_url) ||
      SurfBoard.Config.get(:base_url) || ""
  end
end
