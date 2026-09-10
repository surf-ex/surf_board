defmodule SurfBoard.Transport.PerSession.Actor do
  @moduledoc false

  # Single GenServer per session. Owns:
  #
  #   * the raw Mint WebSocket, via `SurfBoard.Transport.WireSocket`
  #     (shared plumbing with `SurfBoard.WebSocket` — see that module's
  #     moduledoc for why this actor doesn't just delegate to it)
  #   * per-session state (pending_calls, find_waiters, load_waiters,
  #     page_ready_waiter, frame_stack, frame_contexts, last_page_id)
  #
  # All inbound WS frames AND all outbound caller calls land in ONE
  # mailbox in arrival order. Causal ordering between events and
  # responses is preserved without a barrier.
  #
  # Compared to today's WebSocket + Session pair, this actor
  # eliminates the inter-process hop on every cdp_send: caller →
  # actor.cdp_send is one GenServer.call instead of two.
  #
  # Implements the SurfBoard.Transport.Protocol message contract
  # so CDPClient can drive it the same way it drives Session.

  use GenServer
  require Logger

  alias SurfBoard.Transport.Common
  alias SurfBoard.Transport.WireSocket
  alias SurfBoard.Drivers.CDP.Wire

  defstruct [
    :wire,
    # ----- Per-session state (was Session) -----
    :session,
    :owner_ref,
    :teardown_fun,
    :page_ready_waiter,
    :last_page_id,
    pending_calls: %{},
    loads: %{},
    load_waiters: [],
    # Main-frame HTTP responses keyed by loaderId — see the same field on
    # Transport.Session; both actors share Drivers.CDP.Wire.handle_event/3.
    responses: %{},
    last_loader_id: nil,
    find_waiters: %{},
    frame_stack: [],
    frame_contexts: %{},
    # Bootstrap-reported "transition in flight" flag — extends the
    # page_ready timeout while LV finishes the destination mount.
    nav_pending: false
  ]

  # ----- Lifecycle -----

  @doc """
  Starts the actor. The session struct will have its `pid` field
  filled in to point at this process — that's how the rest of the
  system finds the transport actor.

  Opts:
    * `:ws_url` (required) — websocket URL to connect to
    * `:init_fun` — 0-arity returning `{:ok, %SurfBoard.Session{}}`
    * `:teardown_fun` — 1-arity called from `terminate/2`
    * `:owner` — process to monitor; when it dies we self-stop
  """
  @spec start_link(keyword) :: {:ok, SurfBoard.Session.t()} | {:error, term}
  def start_link(opts) do
    ws_url = Keyword.fetch!(opts, :ws_url)
    init_fun = Keyword.fetch!(opts, :init_fun)
    teardown_fun = Keyword.fetch!(opts, :teardown_fun)
    owner = Keyword.get(opts, :owner, self())

    case GenServer.start(__MODULE__, {ws_url, init_fun, teardown_fun, owner}) do
      {:ok, pid} ->
        try do
          session = GenServer.call(pid, :get_session)
          {:ok, %{session | pid: pid}}
        catch
          :exit, reason -> {:error, {:transport_error, reason}}
        end

      {:error, {:init_failed, reason}} ->
        {:error, reason}

      other ->
        other
    end
  end

  # ----- GenServer init -----

  @impl true
  def init({ws_url, init_fun, teardown_fun, owner}) do
    Process.flag(:trap_exit, true)
    ref = Process.monitor(owner)

    with {:ok, wire} <- WireSocket.connect(ws_url),
         {:ok, %SurfBoard.Session{} = session} <- init_fun.() do
      session = %{session | pid: self()}

      try do
        SurfBoard.SessionStore.register(session, owner)
      catch
        :exit, _ -> :ok
      end

      state = %__MODULE__{
        wire: wire,
        session: session,
        owner_ref: ref,
        teardown_fun: teardown_fun
      }

      {:ok, state}
    else
      {:error, reason} -> {:stop, {:init_failed, reason}}
    end
  end

  # ----- Outbound: the Protocol message contract -----

  @impl true
  def handle_call(:get_session, _from, state) do
    {:reply, state.session, state}
  end

  def handle_call(:last_response, _from, state) do
    {:reply, Map.get(state.responses, state.last_loader_id), state}
  end

  def handle_call({:update_browsing_context, session_id, target_id}, _from, state) do
    new_session = %{
      state.session
      | browsing_context: session_id,
        capabilities: Map.put(state.session.capabilities, :target_id, target_id)
    }

    {:reply, :ok, %{state | session: new_session}}
  end

  def handle_call(:reset_frame_stack, _from, state) do
    {:reply, :ok, %{state | frame_stack: []}}
  end

  def handle_call({:cdp_send, method, params, opts}, from, state) do
    # Override session_id with our LIVE browsing_context (caller's
    # struct may be stale after focus_window/2).
    opts = override_session_id(opts, state)

    t0 = SurfBoard.Bench.Timing.mark_now()
    {wire_id, wire} = WireSocket.send(state.wire, method, params, opts)
    pending = Map.put(state.pending_calls, wire_id, {from, t0, method})
    {:noreply, %{state | wire: wire, pending_calls: pending}}
  end

  def handle_call({:subscribe, _event_method, _routing_key}, _from, state) do
    # No-op: this actor owns the WS and processes every event itself.
    # The "subscribe" concept exists to feed the Multiplexed transport's
    # routing table; PerSession doesn't need it.
    {:reply, :ok, state}
  end

  def handle_call({:await_page_load, loader_id, name, timeout_ms}, from, state) do
    Common.await_page_load(state, loader_id, name, timeout_ms, from)
  end

  def handle_call({:await_next_page_load, name, timeout_ms}, from, state) do
    Common.await_next_page_load(state, name, timeout_ms, from)
  end

  def handle_call(:sync_barrier, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call({:register_find, query_id, timeout_ms}, _from, state) do
    {:reply, :ok, Common.register_find(state, query_id, timeout_ms)}
  end

  def handle_call({:await_find_result, query_id}, from, state) do
    Common.await_find_result(state, query_id, from)
  end

  def handle_call({:await_page_ready_after, pre_page_id, timeout_ms}, from, state) do
    Common.await_page_ready_after(state, pre_page_id, timeout_ms, from)
  end

  def handle_call(:current_context_id, _from, state) do
    {:reply, Common.current_context_id(state), state}
  end

  def handle_call(:get_page_id, _from, state) do
    {:reply, state.last_page_id, state}
  end

  def handle_call({:push_frame, context_id}, _from, state) do
    {:reply, :ok, Common.push_frame(state, context_id)}
  end

  def handle_call(:pop_frame, _from, state) do
    {:reply, :ok, Common.pop_frame(state)}
  end

  def handle_call({:record_frame_context, frame_id, context_id}, _from, state) do
    {:reply, :ok, Common.record_frame_context(state, frame_id, context_id)}
  end

  def handle_call({:lookup_frame_context, frame_id}, _from, state) do
    {:reply, Common.lookup_frame_context(state, frame_id), state}
  end

  @impl true
  def handle_cast({:cdp_cast, method, params, opts}, state) do
    opts = override_session_id(opts, state)
    # No pending entry — response (via on_reply) will be dropped since
    # no id in pending_calls matches.
    {_wire_id, wire} = WireSocket.send(state.wire, method, params, opts)
    {:noreply, %{state | wire: wire}}
  end

  # ----- Inbound: WS frames + timer messages -----

  @impl true
  def handle_info(message, state) do
    case WireSocket.handle_message(state.wire, message, state, callbacks()) do
      {:ok, state, wire} ->
        {:noreply, %{state | wire: wire}}

      {:error, reason, state, wire} ->
        Logger.debug(
          "PerSession.Actor transport error pid=#{inspect(self())} reason=#{inspect(reason)}"
        )

        state = notify_all_pending(state, {:error, :session_closed})
        {:stop, {:transport_error, reason}, %{state | wire: wire}}

      :unknown ->
        # Not a Mint message — handle our own kinds.
        handle_internal_message(message, state)
    end
  end

  # ----- WireSocket callbacks -----

  defp callbacks do
    %{
      on_reply: &deliver_response/3,
      on_event: fn method, event, state -> Wire.handle_event(state, method, event) end
    }
  end

  # ----- Internal (non-Mint) messages -----

  defp handle_internal_message({:common_load_timeout, from}, state) do
    {:noreply, Common.handle_load_timeout(state, from)}
  end

  defp handle_internal_message({:page_ready_timeout, from}, state) do
    {:noreply, Common.handle_page_ready_timeout(state, from)}
  end

  defp handle_internal_message({:find_timeout, query_id}, state) do
    {:noreply, Common.handle_find_timeout(state, query_id)}
  end

  defp handle_internal_message({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {:stop, :normal, state}
  end

  defp handle_internal_message(_msg, state), do: {:noreply, state}

  # ----- Termination -----

  @impl true
  def terminate(_reason, %{teardown_fun: fun, session: session, wire: wire})
      when is_function(fun, 1) do
    try do
      SurfBoard.SessionStore.unregister(session)
    catch
      :exit, _ -> :ok
    end

    if wire, do: WireSocket.close(wire)

    try do
      fun.(session)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  def terminate(_reason, %{wire: wire}) do
    if wire, do: WireSocket.close(wire)
    :ok
  end

  # ----- Response delivery -----

  defp deliver_response(id, result, state) do
    case Map.pop(state.pending_calls, id) do
      {nil, _} ->
        # Fire-and-forget cast or stale id. Drop.
        state

      {{from, t0, method}, pending} ->
        SurfBoard.Bench.Timing.record(t0, method)
        GenServer.reply(from, result)
        %{state | pending_calls: pending}
    end
  end

  # ----- Helpers -----

  defp override_session_id(opts, state) do
    case Keyword.fetch(opts, :session_id) do
      {:ok, _} when is_binary(state.session.browsing_context) ->
        Keyword.put(opts, :session_id, state.session.browsing_context)

      _ ->
        opts
    end
  end

  defp notify_all_pending(state, reply) do
    Enum.each(state.pending_calls, fn {_id, {from, _t0, _method}} ->
      try do
        GenServer.reply(from, reply)
      catch
        _, _ -> :ok
      end
    end)

    state
  end
end
