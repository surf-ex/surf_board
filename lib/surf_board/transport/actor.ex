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
  # each driver's start_session/1), covering the three axes that
  # actually vary:
  #
  #   * `socket`    — `{:fused, wire_socket}` when this actor owns its
  #                   own `WireSocket` directly (no separate process,
  #                   no extra hop — Lightpanda's per-session model),
  #                   or `{:shared, pid}` when it routes commands
  #                   through an already-running socket-owner process
  #                   (`SurfBoard.WebSocket` for CDP's shared-WS and
  #                   isolated-process models, or
  #                   `SurfBoard.Drivers.ChromeBiDi.WebSocketClient`
  #                   for BiDi — see the moduledoc note below on why
  #                   BiDi stays "shared" despite being 1:1 with its
  #                   session).
  #   * `send`      — `:inline` registers into this actor's own
  #                   `pending_calls` and returns immediately (CDP,
  #                   both socket modes — `WireSocket`/`WebSocket`
  #                   reply asynchronously without blocking on the
  #                   wire round-trip). `:spawn_link` spawns a linked
  #                   helper process to make the blocking call and
  #                   `GenServer.reply/2` on this actor's behalf — BiDi
  #                   only, because `WebSocketClient.send_command/4` is
  #                   itself a blocking `GenServer.call`; without the
  #                   helper, one slow BiDi round-trip would stall this
  #                   actor's mailbox and delay every concurrent event
  #                   it needs to process (page-load milestones,
  #                   bootstrap payloads, ...) until the call returns.
  #   * `load`      — `:buffer` (CDP's `Page.lifecycleEvent`, which can
  #                   fire more than once and persists until consumed)
  #                   vs. `:wake_once` (BiDi's `browsingContext.load`,
  #                   one-shot per navigation) — see
  #                   `Transport.Common`'s `record_load_milestone/3`
  #                   vs. `record_load_or_wake_once/3` and
  #                   `await_page_load/6`'s `drop_on_consume?`.
  #   * `subscribe` — `:passive` (CDP) just tells the local socket
  #                   owner to forward matching frames to this actor's
  #                   mailbox. `:active` (BiDi) does that AND issues a
  #                   real `session.subscribe` wire call, because BiDi
  #                   requires the server to be told which events to
  #                   emit at all — CDP sessions get every event they've
  #                   enabled the right domain for, with no separate
  #                   subscribe step on the wire.
  #
  # Why BiDi's WebSocketClient stays a separate ("shared") process
  # rather than embedding its own WireSocket directly (which would make
  # it "fused" like Lightpanda, and let this module own the connection
  # itself): it's a smaller, lower-risk change to keep it as-is for
  # this pass. Folding it in later would mean deleting
  # Drivers.ChromeBiDi.WebSocketClient as a GenServer entirely — a
  # reasonable follow-up, not bundled with this one.

  use GenServer
  require Logger

  alias SurfBoard.Transport.{Common, WireSocket}
  alias SurfBoard.WebSocket
  alias SurfBoard.Drivers.ChromeBiDi.WebSocketClient

  defmodule Config do
    @moduledoc false

    @enforce_keys [:socket, :send, :load, :subscribe, :wire]
    defstruct [:socket, :send, :load, :subscribe, :wire]

    @type socket :: {:fused, ws_url :: String.t()} | {:shared, pid()}

    @type t :: %__MODULE__{
            socket: socket(),
            send: :inline | :spawn_link,
            load: :buffer | :wake_once,
            subscribe: :passive | :active,
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
    # owns directly. nil in `:shared` mode (commands route through
    # config.socket's pid instead).
    :wire_socket,
    # `{:shared, pid}` mode only — monitor ref on the socket-owner
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
    nav_pending: false
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

  def init({%Config{socket: {:shared, socket_pid}} = config, init_fun, teardown_fun, owner}) do
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

  def handle_call({:cdp_send, method, params, opts}, from, %{config: %{send: :inline}} = state) do
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
        {:cdp_send, method, params, _opts},
        from,
        %{config: %{send: :spawn_link}} = state
      ) do
    # Don't block this actor on a synchronous wire round-trip — spawn a
    # tiny linked waiter that makes the call and replies on our behalf,
    # so concurrent mailbox traffic (events on the same connection)
    # keeps flowing. See moduledoc.
    parent = self()
    %{socket: {:shared, socket_pid}} = state.config

    spawn_link(fn ->
      result = send_shared_blocking(socket_pid, method, params)
      GenServer.reply(from, result)
      send(parent, {:done_send, self()})
    end)

    {:noreply, state}
  end

  def handle_call(
        {:subscribe, event_method, routing_key},
        _from,
        %{config: %{subscribe: :passive, socket: {:shared, socket_pid}}} = state
      ) do
    key = routing_key || state.session.browsing_context || :global

    try do
      :ok = WebSocket.subscribe(socket_pid, event_method, key, self())
      {:reply, :ok, state}
    catch
      :exit, _ -> {:reply, {:error, :session_closed}, state}
    end
  end

  def handle_call(
        {:subscribe, _event_method, _routing_key},
        _from,
        %{config: %{subscribe: :passive, socket: {:fused, _}}} = state
      ) do
    # No-op: a fused actor owns its socket and already processes every
    # event that arrives on it directly.
    {:reply, :ok, state}
  end

  def handle_call(
        {:subscribe, event_method, _routing_key},
        _from,
        %{config: %{subscribe: :active}} = state
      ) do
    %{socket: {:shared, socket_pid}} = state.config

    WebSocketClient.subscribe(socket_pid, event_method, self(), :global)

    _ =
      WebSocketClient.send_command(
        socket_pid,
        "session.subscribe",
        %{"events" => [event_method]},
        10_000
      )

    {:reply, :ok, state}
  end

  def handle_call({:await_page_load, loader_id, name, timeout_ms}, from, state) do
    Common.await_page_load(state, loader_id, name, timeout_ms, from,
      drop_on_consume?: state.config.load == :wake_once
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
  def handle_cast({:cdp_cast, method, params, opts}, %{config: %{send: :inline}} = state) do
    opts = override_session_id(opts, state)

    case send_inline_cast(state, method, params, opts) do
      {:ok, state} -> {:noreply, state}
      {:error, state, _reason} -> {:noreply, state}
    end
  end

  def handle_cast({:cdp_cast, method, params, _opts}, %{config: %{send: :spawn_link}} = state) do
    %{socket: {:shared, socket_pid}} = state.config
    WebSocketClient.cast_command(socket_pid, method, normalize_params(params))
    {:noreply, state}
  end

  # ----- Inbound: socket messages + timer messages -----

  @impl true
  def handle_info(message, %{config: %{socket: {:fused, _}}} = state) do
    case WireSocket.handle_message(state.wire_socket, message, state, wire_callbacks(state)) do
      {:ok, state, wire_socket} ->
        {:noreply, %{state | wire_socket: wire_socket}}

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
        %{config: %{socket: {:shared, _}, send: :inline}} = state
      ) do
    {:noreply, deliver_response(wire_id, result, state)}
  end

  def handle_info(
        {:v2_event, method, event},
        %{config: %{socket: {:shared, _}, wire: wire_mod}} = state
      ) do
    {:noreply, wire_mod.handle_event(state, method, event)}
  end

  def handle_info(
        {:bidi_event, method, event},
        %{config: %{socket: {:shared, _}, wire: wire_mod}} = state
      ) do
    {:noreply, wire_mod.handle_event(state, method, event)}
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

  def handle_info({:done_send, _pid}, state), do: {:noreply, state}

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{socket_ref: ref, config: %{socket: {:shared, _}}} = state
      ) do
    {:stop, {:socket_down, reason}, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, pid, reason}, %{config: %{socket: {:shared, pid}}} = state) do
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

  defp send_inline(%{config: %{socket: {:shared, socket_pid}}} = state, method, params, opts) do
    try do
      wire_id = WebSocket.cast_send(socket_pid, self(), method, params, opts)
      {:ok, wire_id, state}
    catch
      :exit, _ -> {:error, state, :session_closed}
    end
  end

  defp send_inline_cast(%{config: %{socket: {:fused, _}}} = state, method, params, opts) do
    {_wire_id, wire_socket} = WireSocket.send(state.wire_socket, method, params, opts)
    {:ok, %{state | wire_socket: wire_socket}}
  end

  defp send_inline_cast(%{config: %{socket: {:shared, socket_pid}}} = state, method, params, opts) do
    try do
      _ = WebSocket.cast_send(socket_pid, self(), method, params, opts)
      {:ok, state}
    catch
      :exit, _ -> {:error, state, :session_closed}
    end
  end

  defp send_shared_blocking(socket_pid, method, params) do
    WebSocketClient.send_command(socket_pid, method, normalize_params(params), 30_000)
  end

  # WebSocketClient (BiDi) expects string-keyed params; CDPClient often
  # passes atom-keyed maps. Normalize either way. No-op for the :inline
  # send strategy, which passes params straight to WireSocket.
  defp normalize_params(params) when is_map(params) do
    Map.new(params, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp normalize_params(other), do: other

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
