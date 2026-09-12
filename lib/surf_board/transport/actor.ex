defmodule SurfBoard.Transport.Actor do
  @moduledoc false

  # One generic GenServer implementing the SurfBoard.Transport.Protocol
  # message contract for every driver. Replaces three near-identical
  # hand-written actors (Transport.Session, Transport.PerSession.Actor,
  # Transport.BiDi.SessionActor) — a prior pass to Transport.WireSocket
  # + Transport.Common already showed the bulk of their logic (find/
  # page-load/page-ready/frame-stack bookkeeping) was byte-for-byte
  # identical; this finishes the job by also parameterizing the small
  # remaining real differences instead of hand-copying three actors.
  #
  # Configured per-driver via `%Transport.Actor.Config{}` (built by
  # each driver's start_session/1), covering the two axes that
  # actually vary:
  #
  #   * `socket` — `{:fused, ws_url}` when this actor owns its own
  #                `WireSocket` directly (no separate process, no extra
  #                hop — Lightpanda's per-session model), or
  #                `{:remote, module, pid}` when it routes commands
  #                through an already-running socket-owner process
  #                elsewhere (`SurfBoard.WebSocket` for CDP's shared-WS
  #                and isolated-process models — genuinely serving many
  #                sessions; `SurfBoard.Drivers.ChromeBiDi.WebSocketClient`
  #                for BiDi — always 1:1 with its session, but still a
  #                separate process since chromium-bidi's session comes
  #                up via an HTTP handshake before any actor exists to
  #                embed a socket into). Both remote owners implement the
  #                identical `cast_send/5` contract (fire the send,
  #                return a wire id, deliver the reply later via
  #                `{:v2_response, wire_id, result}` sent to the given
  #                owner pid; events arrive as `{:v2_event, method,
  #                event}`) — `module` names which one this socket is, so
  #                this actor's own dispatch is otherwise identical
  #                either way. Cardinality (1:1 vs N:1) is a fact about
  #                the remote owner, invisible here.
  #   * `load`   — `:buffer` (CDP's `Page.lifecycleEvent`, which can
  #                fire more than once and persists until consumed) vs.
  #                `:wake_once` (BiDi's `browsingContext.load`, one-shot
  #                per navigation) — see `Transport.Common`'s
  #                `record_load_milestone/3` vs.
  #                `record_load_or_wake_once/3` and `await_page_load/6`'s
  #                `drop_on_consume?`. The one genuine protocol-level
  #                difference left, unrelated to socket wiring.
  #
  # There used to be a third axis (`send: :inline | :spawn_link`) whose
  # `:spawn_link` mode spawned a linked helper to make a blocking
  # `WebSocketClient.send_command/4` call on this actor's behalf. That
  # wasn't a genuine BiDi wire constraint — `WebSocketClient`'s own
  # `handle_call` never blocked its mailbox, same as `SurfBoard.WebSocket`;
  # the only thing blocking was this actor calling it via a synchronous
  # `GenServer.call` instead of the cast_send-and-correlate-later shape
  # `SurfBoard.WebSocket` already used. Giving `WebSocketClient` the
  # identical `cast_send/5` contract removed the need for the shim
  # entirely — every remote socket is sent to the same way.
  #
  # Similarly, `subscribe: :passive | :active` used to exist so BiDi
  # could issue a real `session.subscribe` wire call whenever
  # `Transport.Protocol.subscribe/3` was invoked — but nothing ever
  # called that for a BiDi session (BiDi subscribes everything it needs
  # once, upfront, during `Strategy.BiDi`'s own handshake). `:active`
  # was dead code; deleted along with the config key.

  use GenServer
  require Logger

  alias SurfBoard.Transport.{Common, WireSocket}

  defmodule Config do
    @moduledoc false

    @enforce_keys [:socket, :load, :wire]
    defstruct [:socket, :load, :wire]

    @type socket :: {:fused, ws_url :: String.t()} | {:remote, module(), pid()}

    @type t :: %__MODULE__{
            socket: socket(),
            load: :buffer | :wake_once,
            # The Wire.handle_event/3-shaped module for this actor's
            # protocol — SurfBoard.Clients.CDP.Wire or
            # SurfBoard.Clients.BiDi.Wire.
            wire: module()
          }
  end

  defstruct [
    :config,
    # ----- Socket state -----
    # `{:fused, wire_socket}` mode only — the WireSocket.t() this actor
    # owns directly. nil in `:remote` mode (commands route through
    # config.socket's pid instead).
    :wire_socket,
    # `{:remote, pid}` mode only — monitor ref on the socket-owner
    # process, so this actor stops cleanly if it dies.
    :socket_ref,
    # ----- Per-session state -----
    :session,
    :owner_ref,
    :teardown_fun,
    :page_ready_waiter,
    :last_page_id,
    pending_calls: %{},
    loads: %{},
    load_waiters: [],
    responses: %{},
    last_loader_id: nil,
    find_waiters: %{},
    frame_stack: [],
    frame_contexts: %{},
    nav_pending: false,
    # Set true the first time `{:focus_window, ...}` fires — i.e.
    # `Clients.{CDP,BiDi}.Windows.focus_window/2` moved focus off the
    # target this session started on. Distinct from
    # `{:update_browsing_context, ...}`, which strategies also send
    # during ordinary session bring-up (before any user action) to
    # assign the session's initial context. Read by
    # `Browser.Internal.in_switched_window?/1` to gate the fast-path
    # find/click/eval pipeline, which doesn't yet support cross-window
    # targeting.
    switched_window?: false,
    # Set by `Clients.{CDP,BiDi}.Windows.close_window/1` right before
    # it asks the browser to close a target/context, to the CDP
    # sessionId or BiDi context id being closed. A window closing
    # produces the exact same wire event (`Target.detachedFromTarget`
    # / `browsingContext.contextDestroyed`) as that same target
    # genuinely crashing — `wire_mod.handle_event/3` checks this
    # before setting `target_crashed?` so an intentional close
    # doesn't kill the whole session, only an unrequested one does.
    # Cleared as soon as it's matched (a stale value should never
    # suppress a LATER, genuine crash of a target that reused the id).
    closing_context: nil,
    # Set true by `wire_mod.handle_event/3` on a fatal, session-ending
    # event (CDP: `Inspector.targetCrashed`/`Target.detachedFromTarget`;
    # a future BiDi equivalent could set the same flag). Checked right
    # after every event dispatch so a dead target fails every pending
    # call immediately instead of leaving them to expire one by one —
    # see `maybe_handle_target_crash/1`.
    target_crashed?: false
  ]

  # ----- Lifecycle -----

  @doc """
  Starts the actor. The session struct will have its `pid` field
  filled in to point at this process.

  Opts:
    * `:config` (required) — a `%Config{}`
    * `:init_fun` — 0-arity returning `{:ok, %SurfBoard.Session{}}`
    * `:teardown_fun` — 1-arity called from `terminate/2`
    * `:owner` — process to monitor; when it dies we self-stop
  """
  @spec start_link(keyword) :: {:ok, SurfBoard.Session.t()} | {:error, term}
  def start_link(opts) do
    config = Keyword.fetch!(opts, :config)
    init_fun = Keyword.fetch!(opts, :init_fun)
    teardown_fun = Keyword.fetch!(opts, :teardown_fun)
    owner = Keyword.get(opts, :owner, self())

    case GenServer.start(__MODULE__, {config, init_fun, teardown_fun, owner}) do
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
  def init({%Config{socket: {:fused, ws_url}} = config, init_fun, teardown_fun, owner}) do
    Process.flag(:trap_exit, true)
    ref = Process.monitor(owner)

    with {:ok, wire_socket} <- WireSocket.connect(ws_url),
         {:ok, %SurfBoard.Session{} = session} <- init_fun.() do
      finish_init(config, wire_socket, nil, session, ref, owner, teardown_fun)
    else
      {:error, reason} -> {:stop, {:init_failed, reason}}
    end
  end

  def init({%Config{socket: {:remote, _mod, socket_pid}} = config, init_fun, teardown_fun, owner}) do
    Process.flag(:trap_exit, true)
    ref = Process.monitor(owner)
    socket_ref = Process.monitor(socket_pid)

    case init_fun.() do
      {:ok, %SurfBoard.Session{} = session} ->
        finish_init(config, nil, socket_ref, session, ref, owner, teardown_fun)

      {:error, reason} ->
        {:stop, {:init_failed, reason}}
    end
  end

  defp finish_init(config, wire_socket, socket_ref, session, owner_ref, owner, teardown_fun) do
    session = %{session | pid: self()}

    try do
      SurfBoard.SessionStore.register(session, owner)
    catch
      :exit, _ -> :ok
    end

    state = %__MODULE__{
      config: config,
      wire_socket: wire_socket,
      socket_ref: socket_ref,
      session: session,
      owner_ref: owner_ref,
      teardown_fun: teardown_fun
    }

    {:ok, state}
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
    {:reply, :ok, put_browsing_context(state, session_id, target_id)}
  end

  # Distinct from `:update_browsing_context`: that message is also used
  # during ordinary session bring-up (PerSession/BiDi strategies assign
  # the session's initial context this way, before any user action) —
  # reusing it to also flag "the user switched windows" would make
  # every freshly-started session look switched. `:focus_window` is
  # sent only by `Clients.{CDP,BiDi}.Windows.focus_window/2`, the
  # actual user-facing operation `in_switched_window?/1` cares about.
  def handle_call({:focus_window, session_id, target_id}, _from, state) do
    state = put_browsing_context(state, session_id, target_id)
    {:reply, :ok, %{state | switched_window?: true}}
  end

  def handle_call(:switched_window?, _from, state) do
    {:reply, state.switched_window?, state}
  end

  def handle_call({:closing_window, context_id}, _from, state) do
    {:reply, :ok, %{state | closing_context: context_id}}
  end

  def handle_call(:reset_frame_stack, _from, state) do
    {:reply, :ok, %{state | frame_stack: []}}
  end

  def handle_call({:cdp_send, method, params, opts}, from, state) do
    opts = override_session_id(opts, state)
    t0 = SurfBoard.Bench.Timing.mark_now()

    case send_inline(state, method, params, opts) do
      {:ok, wire_id, state} ->
        pending = Map.put(state.pending_calls, wire_id, {from, t0, method})
        {:noreply, %{state | pending_calls: pending}}

      {:error, state, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:subscribe, event_method, routing_key},
        _from,
        %{config: %{socket: {:remote, socket_mod, socket_pid}}} = state
      ) do
    key = routing_key || state.session.browsing_context || :global

    try do
      :ok = socket_mod.subscribe(socket_pid, event_method, key, self())
      {:reply, :ok, state}
    catch
      :exit, _ -> {:reply, {:error, :session_closed}, state}
    end
  end

  def handle_call(
        {:subscribe, _event_method, _routing_key},
        _from,
        %{config: %{socket: {:fused, _}}} = state
      ) do
    # No-op: a fused actor owns its socket and already processes every
    # event that arrives on it directly.
    {:reply, :ok, state}
  end

  def handle_call({:await_page_load, loader_id, name, timeout_ms, frame_id}, from, state) do
    Common.await_page_load(state, loader_id, name, timeout_ms, from,
      drop_on_consume?: state.config.load == :wake_once,
      frame_id: frame_id
    )
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

    case send_inline_cast(state, method, params, opts) do
      {:ok, state} -> {:noreply, state}
      {:error, state, _reason} -> {:noreply, state}
    end
  end

  # ----- Inbound: socket messages + timer messages -----

  @impl true
  def handle_info(message, %{config: %{socket: {:fused, _}}} = state) do
    case WireSocket.handle_message(state.wire_socket, message, state, wire_callbacks(state)) do
      {:ok, state, wire_socket} ->
        maybe_handle_target_crash(%{state | wire_socket: wire_socket})

      {:error, reason, state, wire_socket} ->
        Logger.debug(
          "Transport.Actor transport error pid=#{inspect(self())} reason=#{inspect(reason)}"
        )

        state = notify_all_pending(%{state | wire_socket: wire_socket}, {:error, :session_closed})
        {:stop, {:transport_error, reason}, state}

      :unknown ->
        handle_internal_message(message, state)
    end
  end

  def handle_info(
        {:v2_response, wire_id, result},
        %{config: %{socket: {:remote, _mod, _pid}}} = state
      ) do
    {:noreply, deliver_response(wire_id, result, state)}
  end

  def handle_info(
        {:v2_event, method, event},
        %{config: %{socket: {:remote, _mod, _pid}, wire: wire_mod}} = state
      ) do
    maybe_handle_target_crash(wire_mod.handle_event(state, method, event))
  end

  def handle_info({:common_load_timeout, from}, state) do
    {:noreply, Common.handle_load_timeout(state, from)}
  end

  def handle_info({:page_ready_timeout, from}, state) do
    {:noreply, Common.handle_page_ready_timeout(state, from)}
  end

  def handle_info({:find_timeout, query_id}, state) do
    {:noreply, Common.handle_find_timeout(state, query_id)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{socket_ref: ref, config: %{socket: {:remote, _mod, _socket_pid}}} = state
      ) do
    {:stop, {:socket_down, reason}, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(
        {:EXIT, pid, reason},
        %{config: %{socket: {:remote, _mod, pid}}} = state
      ) do
    {:stop, {:socket_exit, reason}, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_internal_message(_msg, state), do: {:noreply, state}

  # ----- WireSocket callbacks (:fused mode only) -----

  defp wire_callbacks(%{config: %{wire: wire_mod}}) do
    %{
      on_reply: &deliver_response/3,
      on_event: fn method, event, state -> wire_mod.handle_event(state, method, event) end
    }
  end

  defp deliver_response(id, result, state) do
    case Map.pop(state.pending_calls, id) do
      {nil, _} ->
        state

      {{from, t0, method}, pending} ->
        SurfBoard.Bench.Timing.record(t0, method)
        GenServer.reply(from, result)
        %{state | pending_calls: pending}
    end
  end

  # ----- Termination -----

  @impl true
  def terminate(_reason, %{config: %{socket: {:fused, _}}, wire_socket: wire_socket} = state)
      when not is_nil(wire_socket) do
    WireSocket.close(wire_socket)
    finish_terminate(state)
  end

  def terminate(_reason, state), do: finish_terminate(state)

  defp finish_terminate(state) do
    try do
      SurfBoard.SessionStore.unregister(state.session)
    catch
      :exit, _ -> :ok
    end

    if is_function(state.teardown_fun, 1) do
      try do
        state.teardown_fun.(state.session)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  # ----- Send helpers -----

  defp send_inline(%{config: %{socket: {:fused, _}}} = state, method, params, opts) do
    {wire_id, wire_socket} = WireSocket.send(state.wire_socket, method, params, opts)
    {:ok, wire_id, %{state | wire_socket: wire_socket}}
  end

  defp send_inline(
         %{config: %{socket: {:remote, socket_mod, socket_pid}}} = state,
         method,
         params,
         opts
       ) do
    try do
      wire_id = socket_mod.cast_send(socket_pid, self(), method, params, opts)
      {:ok, wire_id, state}
    catch
      :exit, _ -> {:error, state, :session_closed}
    end
  end

  defp send_inline_cast(%{config: %{socket: {:fused, _}}} = state, method, params, opts) do
    {_wire_id, wire_socket} = WireSocket.send(state.wire_socket, method, params, opts)
    {:ok, %{state | wire_socket: wire_socket}}
  end

  defp send_inline_cast(
         %{config: %{socket: {:remote, socket_mod, socket_pid}}} = state,
         method,
         params,
         opts
       ) do
    try do
      _ = socket_mod.cast_send(socket_pid, self(), method, params, opts)
      {:ok, state}
    catch
      :exit, _ -> {:error, state, :session_closed}
    end
  end

  defp put_browsing_context(state, session_id, target_id) do
    new_session = %{
      state.session
      | browsing_context: session_id,
        driver_state: %{state.session.driver_state | target_id: target_id}
    }

    %{state | session: new_session}
  end

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

  # `wire_mod.handle_event/3` sets `target_crashed?: true` on a fatal,
  # session-ending event (CDP: `Inspector.targetCrashed`,
  # `Target.detachedFromTarget`). Without this, a dead target leaves
  # every subsequent call silently pending forever — the wire byte
  # send always "succeeds" (nothing downstream knows the target is
  # gone), so nothing ever completes the pending_calls entry, and each
  # caller's own GenServer.call timeout is the only thing that ever
  # fires, one call at a time, looking like an ever-worsening hang
  # rather than one clean failure the moment the target actually died.
  defp maybe_handle_target_crash(%{target_crashed?: true} = state) do
    state = notify_all_pending(state, {:error, :target_crashed})
    {:stop, {:shutdown, :target_crashed}, state}
  end

  defp maybe_handle_target_crash(state), do: {:noreply, state}
end
