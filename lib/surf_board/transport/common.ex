defmodule SurfBoard.Transport.Common do
  @moduledoc false

  # Shared per-session state-machine helpers used by all three Transport
  # actors:
  #
  #   * `SurfBoard.Transport.Session` (Chrome CDP, shared WS)
  #   * `SurfBoard.Transport.PerSession.Actor` (Lightpanda, per-session WS)
  #   * `SurfBoard.Transport.BiDi.SessionActor` (Chrome BiDi, per-session WS)
  #
  # Each actor owns its own wire protocol (CDP/BiDi) and connection model
  # (shared vs per-session WS), but they all maintain the same waiter
  # state machine for find / page-load / page-ready / frame tracking.
  # Centralising that here keeps the three implementations from drifting.

  # ----- Find waiters -----

  @doc """
  Registers a find query with an in-flight timeout. The caller will
  subsequently call `await_find_result/1` and either get the resolved
  result or a `:timeout` once the timer fires.
  """
  @spec register_find(map(), term(), non_neg_integer()) :: map()
  def register_find(state, query_id, timeout_ms) do
    timer_ref = Process.send_after(self(), {:find_timeout, query_id}, timeout_ms)
    %{state | find_waiters: Map.put(state.find_waiters, query_id, {:pending, timer_ref, nil})}
  end

  @doc """
  Looks up a registered find result, suspending the caller if not yet
  resolved. Returns `{:reply, ...}` / `{:noreply, ...}` shapes ready to
  return from `handle_call/3`.
  """
  @spec await_find_result(map(), term(), GenServer.from()) ::
          {:reply, term(), map()} | {:noreply, map()}
  def await_find_result(state, query_id, from) do
    case Map.get(state.find_waiters, query_id) do
      {:resolved, result} ->
        {:reply, result, %{state | find_waiters: Map.delete(state.find_waiters, query_id)}}

      {:pending, timer_ref, nil} ->
        waiters = Map.put(state.find_waiters, query_id, {:pending, timer_ref, from})
        {:noreply, %{state | find_waiters: waiters}}

      nil ->
        {:reply, {:timeout, 0}, state}
    end
  end

  @doc """
  Resolves a registered find with a result. If a caller is already
  awaiting, replies immediately and drops the entry; otherwise stashes
  the result for an arriving caller and cancels the pending timer.
  """
  @spec resolve_find(map(), term(), term()) :: map()
  def resolve_find(state, query_id, result) do
    case Map.get(state.find_waiters, query_id) do
      nil ->
        state

      {:resolved, _} ->
        state

      {:pending, timer_ref, nil} ->
        Process.cancel_timer(timer_ref)
        %{state | find_waiters: Map.put(state.find_waiters, query_id, {:resolved, result})}

      {:pending, timer_ref, from} ->
        Process.cancel_timer(timer_ref)
        GenServer.reply(from, result)
        %{state | find_waiters: Map.delete(state.find_waiters, query_id)}
    end
  end

  @doc """
  Handles a `{:find_timeout, query_id}` message — drops the pending entry
  and replies `:timeout` to any awaiter. Resolved entries are kept (the
  awaiter will pop them via `await_find_result/3`).
  """
  @spec handle_find_timeout(map(), term()) :: map()
  def handle_find_timeout(state, query_id) do
    case Map.get(state.find_waiters, query_id) do
      nil ->
        state

      {:resolved, _} ->
        state

      {:pending, _ref, nil} ->
        %{state | find_waiters: Map.delete(state.find_waiters, query_id)}

      {:pending, _ref, from} ->
        GenServer.reply(from, {:timeout, 0})
        %{state | find_waiters: Map.delete(state.find_waiters, query_id)}
    end
  end

  # ----- Page-ready waiter -----

  @doc """
  Suspends or replies based on whether a new pageId has already arrived
  relative to `pre_page_id`. Returns a handle_call-shaped tuple.
  """
  @spec await_page_ready_after(map(), term() | nil, non_neg_integer(), GenServer.from()) ::
          {:reply, :ok, map()} | {:noreply, map()}
  # When bootstrap reported a `nav_pending` (LV `live_redirect`/`redirect`
  # in a phx_reply), extend the timeout — the destination's mount may
  # take longer than the caller's default budget. The bootstrap fires
  # page_ready once the new pageId is established, so we still wake
  # event-driven; the longer timeout is just a safer upper bound. 10s
  # matches Browser's :max_wait_time default for find/has? retries.
  @nav_pending_timeout 10_000

  def await_page_ready_after(state, pre_page_id, timeout_ms, from) do
    if pre_page_id != nil and state.last_page_id != nil and
         state.last_page_id != pre_page_id do
      {:reply, :ok, state}
    else
      effective_timeout =
        if state.nav_pending, do: max(timeout_ms, @nav_pending_timeout), else: timeout_ms

      timer_ref = Process.send_after(self(), {:page_ready_timeout, from}, effective_timeout)

      {:noreply, %{state | page_ready_waiter: {from, pre_page_id, timer_ref}, nav_pending: false}}
    end
  end

  @doc """
  Records the most recent pageId and wakes any waiter whose `pre_page_id`
  differs (i.e. a transition has occurred).
  """
  @spec update_last_page_id(map(), term()) :: map()
  def update_last_page_id(state, page_id) do
    state = %{state | last_page_id: page_id}

    case state.page_ready_waiter do
      {from, pre_page_id, timer_ref} when pre_page_id != page_id ->
        Process.cancel_timer(timer_ref)
        GenServer.reply(from, :ok)
        %{state | page_ready_waiter: nil}

      _ ->
        state
    end
  end

  @doc """
  Handles a `{:page_ready_timeout, from}` message. Replies `:timeout` only
  if the waiter is still the one named in the message.
  """
  @spec handle_page_ready_timeout(map(), GenServer.from()) :: map()
  def handle_page_ready_timeout(state, from) do
    case state.page_ready_waiter do
      {^from, _pre, _ref} ->
        GenServer.reply(from, :timeout)
        %{state | page_ready_waiter: nil}

      _ ->
        state
    end
  end

  # ----- Frame stack -----

  @doc "Pushes a context_id (or browsing-context-id) onto the frame stack."
  @spec push_frame(map(), term()) :: map()
  def push_frame(state, context_id) do
    %{state | frame_stack: [context_id | state.frame_stack]}
  end

  @doc "Pops the top entry off the frame stack, leaving an empty stack alone."
  @spec pop_frame(map()) :: map()
  def pop_frame(state) do
    case state.frame_stack do
      [] -> state
      [_ | rest] -> %{state | frame_stack: rest}
    end
  end

  @doc "Returns the current frame's context id (top of stack) or nil."
  @spec current_context_id(map()) :: term() | nil
  def current_context_id(state), do: List.first(state.frame_stack)

  @doc "Stores a `frame_id => context_id` mapping."
  @spec record_frame_context(map(), term(), term()) :: map()
  def record_frame_context(state, frame_id, context_id) do
    %{state | frame_contexts: Map.put(state.frame_contexts, frame_id, context_id)}
  end

  @doc "Looks up a previously-recorded context id for a frame."
  @spec lookup_frame_context(map(), term()) :: term() | nil
  def lookup_frame_context(state, frame_id) do
    Map.get(state.frame_contexts, frame_id)
  end

  # ----- Load waiters (CDP Page.lifecycleEvent / BiDi browsingContext.load) -----

  @doc """
  Buffers a navigation milestone in `state.loads` AND wakes any matching
  load waiter — the CDP buffer-and-wake semantics where milestones persist
  for the lifetime of the loader_id.

  Used by `Drivers.CDP.Wire` for `Page.lifecycleEvent`. BiDi has different
  semantics (`record_load_or_wake_once/3`).
  """
  @spec record_load_milestone(map(), term(), String.t()) :: map()
  def record_load_milestone(state, loader_id, name) do
    loads = Map.update(state.loads, loader_id, %{name => true}, &Map.put(&1, name, true))
    state = %{state | loads: loads}

    {ready, pending} =
      Enum.split_with(state.load_waiters, fn
        {_from, ^loader_id, ^name, _ref} -> true
        {_from, :any, ^name, _ref} -> true
        _ -> false
      end)

    Enum.each(ready, fn {from, _l, _n, ref} ->
      Process.cancel_timer(ref)
      GenServer.reply(from, :ok)
    end)

    %{state | load_waiters: pending}
  end

  @doc """
  BiDi load-event semantics: if a matching waiter exists, wake it; otherwise
  buffer the milestone for a later `await_page_load` (which then consumes
  and drops it). Distinct from `record_load_milestone/3` — see comment there.
  """
  @spec record_load_or_wake_once(map(), term(), String.t()) :: map()
  def record_load_or_wake_once(state, loader_id, name) do
    {matching, rest} =
      Enum.split_with(state.load_waiters, fn {_from, lid, n, _ref} ->
        (lid == loader_id or lid == :any) and n == name
      end)

    case matching do
      [] ->
        inner = Map.put(Map.get(state.loads, loader_id, %{}), name, true)
        %{state | loads: Map.put(state.loads, loader_id, inner)}

      _ ->
        Enum.each(matching, fn {from, _, _, ref} ->
          Process.cancel_timer(ref)
          GenServer.reply(from, :ok)
        end)

        %{state | load_waiters: rest}
    end
  end

  # A single internal timer-message tag for both CDP and BiDi actors —
  # there's no reason for callers to distinguish "which protocol's load
  # timer fired," only that a load wait timed out. Exposed as the return
  # value from `await_page_load/6`/`await_next_page_load/5` so callers
  # arm `Process.send_after/3` with a name only `Common` needs to know.
  @load_timeout_tag :common_load_timeout

  @doc "Message tag `await_page_load/6`/`await_next_page_load/5` arm their timers with."
  @spec load_timeout_tag() :: atom()
  def load_timeout_tag, do: @load_timeout_tag

  @doc """
  `handle_call({:await_page_load, loader_id, name, timeout_ms}, from, state)`
  body, shared by all three transport actors.

  `drop_on_consume?` selects which write-side semantics this actor's
  wire decoder uses: `true` for BiDi's one-shot `record_load_or_wake_once/3`
  (a buffered hit must be dropped so it can't be consumed twice — BiDi
  only fires each milestone once per navigation); `false` (default) for
  CDP's persist-until-loader-changes `record_load_milestone/3` (a
  buffered hit stays buffered — CDP's `Page.lifecycleEvent` can fire
  more than once and a later caller for the same loader_id/name should
  still see it).
  """
  @spec await_page_load(map(), term(), String.t(), timeout(), GenServer.from(), keyword()) ::
          {:reply, :ok, map()} | {:noreply, map()}
  def await_page_load(state, loader_id, name, timeout_ms, from, opts \\ []) do
    drop_on_consume? = Keyword.get(opts, :drop_on_consume?, false)

    case get_in(state.loads, [loader_id, name]) do
      true when drop_on_consume? ->
        {:reply, :ok, drop_load(state, loader_id, name)}

      true ->
        {:reply, :ok, state}

      _ ->
        timer_ref = Process.send_after(self(), {@load_timeout_tag, from}, timeout_ms)
        waiter = {from, loader_id, name, timer_ref}
        {:noreply, %{state | load_waiters: [waiter | state.load_waiters]}}
    end
  end

  @doc """
  `handle_call({:await_next_page_load, name, timeout_ms}, from, state)`
  body, shared by all three transport actors. Wakes on the first
  matching milestone regardless of which navigation produced it
  (`:any` wildcard loader_id) — consumes any already-buffered loads
  first, same as `await_page_load/6` but without pinning a loader_id.
  """
  @spec await_next_page_load(map(), String.t(), timeout(), GenServer.from(), keyword()) ::
          {:reply, :ok, map()} | {:noreply, map()}
  def await_next_page_load(state, name, timeout_ms, from, _opts \\ []) do
    already_loaded =
      Enum.any?(state.loads, fn {_loader_id, milestones} -> Map.get(milestones, name, false) end)

    if already_loaded do
      {:reply, :ok, %{state | loads: %{}}}
    else
      timer_ref = Process.send_after(self(), {@load_timeout_tag, from}, timeout_ms)
      waiter = {from, :any, name, timer_ref}
      {:noreply, %{state | loads: %{}, load_waiters: [waiter | state.load_waiters]}}
    end
  end

  @doc """
  `handle_info({load_timeout_tag(), from}, state)` body, shared by all
  three transport actors. No-ops if the waiter already resolved (the
  timeout raced a reply).
  """
  @spec handle_load_timeout(map(), GenServer.from()) :: map()
  def handle_load_timeout(state, from) do
    case Enum.split_with(state.load_waiters, fn {f, _, _, _} -> f == from end) do
      {[], _} ->
        state

      {[{^from, _l, _n, _ref} | _], rest} ->
        GenServer.reply(from, :timeout)
        %{state | load_waiters: rest}
    end
  end

  # After consuming a buffered (loader_id, milestone) under BiDi's
  # one-shot semantics, drop it so a future caller for the same pair
  # has to wait for a fresh event rather than replaying a stale hit.
  defp drop_load(state, loader_id, name) do
    case Map.get(state.loads, loader_id) do
      nil ->
        state

      inner ->
        case Map.delete(inner, name) do
          empty when map_size(empty) == 0 ->
            %{state | loads: Map.delete(state.loads, loader_id)}

          remaining ->
            %{state | loads: Map.put(state.loads, loader_id, remaining)}
        end
    end
  end

  # ----- Bootstrap channel payload routing -----

  @doc """
  Routes a JSON payload from the bootstrap channel (`__surfboard(...)` in
  CDP, `script.message` in BiDi) to the appropriate state-machine update.
  Recognises find results and page_ready signals. Unknown payloads return
  the state unchanged.
  """
  @spec route_bootstrap_payload(map(), binary()) :: map()
  def route_bootstrap_payload(state, payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, %{"id" => query_id, "error" => err}} when is_binary(err) ->
        resolve_find(state, query_id, {:error, :invalid_selector})

      {:ok, %{"id" => query_id, "count" => count} = msg} ->
        resolve_find(state, query_id, {:ok, count, msg["meta"]})

      {:ok, %{"type" => "page_ready", "pageId" => page_id}} ->
        update_last_page_id(state, page_id)

      {:ok, %{"type" => "nav_pending"}} ->
        case state.page_ready_waiter do
          {from, pre, old_ref} ->
            Process.cancel_timer(old_ref)

            new_ref =
              Process.send_after(self(), {:page_ready_timeout, from}, @nav_pending_timeout)

            %{state | page_ready_waiter: {from, pre, new_ref}, nav_pending: false}

          nil ->
            %{state | nav_pending: true}
        end

      _ ->
        state
    end
  end

  def route_bootstrap_payload(state, _), do: state
end
