defmodule SurfBoard.Drivers.ChromeBiDi.WebSocketClient do
  @moduledoc false
  # GenServer managing a single WebSocket connection per session.
  #
  # The Mint connect/upgrade/encode/decode plumbing lives in
  # `SurfBoard.Transport.WireSocket`, shared with `SurfBoard.WebSocket`
  # (Chrome CDP's shared-socket owner). This module speaks the exact
  # same owner protocol `SurfBoard.WebSocket` does — `cast_send/5`
  # returns a wire id immediately and delivers the reply later via
  # `{:v2_response, wire_id, result}` sent to the given owner pid;
  # events broadcast as `{:v2_event, method, event}` to subscribers —
  # so `Transport.Actor` can treat this exactly like a `:remote`
  # socket owner, with no BiDi-specific dispatch of its own. Only the
  # cardinality differs (one session per WebSocketClient, vs. many
  # sessions sharing one `SurfBoard.WebSocket`), which `Actor` doesn't
  # need to know about.
  #
  # `send_command`/`send_command_flat` stay as a synchronous
  # convenience (mirrors `SurfBoard.WebSocket.send_sync/4`) for callers
  # without a Session actor of their own to correlate through — e.g.
  # `Clients.BiDi.Dialogs`, session-bootstrap handshake code.

  use GenServer
  require Logger

  alias SurfBoard.Transport.WireSocket

  @default_timeout 10_000

  defstruct [
    :wire,
    :subscribers_table,
    pending: %{}
  ]

  # Public API

  def start_link(ws_url) do
    GenServer.start_link(__MODULE__, ws_url)
  end

  @doc """
  Asynchronously send a BiDi command. The response (or transport
  failure) will be delivered to `owner_pid` as
  `{:v2_response, wire_id, result}`.

  Returns the wire id assigned to this call so the caller can stash
  it in its own pending-calls map. Same contract as
  `SurfBoard.WebSocket.cast_send/5`.
  """
  @spec cast_send(pid, pid, String.t(), map, keyword) :: non_neg_integer()
  def cast_send(pid, owner_pid, method, params, opts \\ []) do
    GenServer.call(pid, {:assign_id_and_send, owner_pid, method, params, opts})
  end

  @doc """
  Synchronous convenience around `cast_send/5` for callers without a
  Session actor to correlate through (e.g. dialog handling, handshake
  code). Consumes the next `:v2_response` matching this call's wire id
  from the calling process's mailbox — don't use it from a process
  that has other in-flight calls.
  """
  def send_command(pid, method, params, timeout \\ @default_timeout) do
    wire_id = cast_send(pid, self(), method, params)

    receive do
      {:v2_response, ^wire_id, result} -> result
    after
      timeout -> {:error, :timeout}
    end
  catch
    :exit, {:noproc, _} -> {:error, :session_closed}
    :exit, {:normal, _} -> {:error, :session_closed}
    :exit, {:shutdown, _} -> {:error, :session_closed}
    :exit, :shutdown -> {:error, :session_closed}
  end

  @doc """
  Like send_command but places sessionId at the top level of the JSON-RPC
  message (required by Chrome's CDP). The sessionId is NOT included in params.
  """
  def send_command_flat(pid, method, params, session_id, timeout \\ @default_timeout) do
    wire_id =
      cast_send(pid, self(), method, params, flat_session_id: true, session_id: session_id)

    receive do
      {:v2_response, ^wire_id, result} -> result
    after
      timeout -> {:error, :timeout}
    end
  catch
    :exit, {:noproc, _} -> {:error, :session_closed}
    :exit, {:normal, _} -> {:error, :session_closed}
    :exit, {:shutdown, _} -> {:error, :session_closed}
    :exit, :shutdown -> {:error, :session_closed}
  end

  @doc """
  Subscribe `subscriber` (default: caller) to events matching `event_method`.

  Same argument order as `SurfBoard.WebSocket.subscribe/4` — `routing_key`
  before `subscriber` — so `Transport.Actor` can call either socket
  owner identically. Pass `routing_key` to scope delivery: only events
  whose context/session id matches will be forwarded. Omit it (or pass
  `:global`) to receive events regardless of session.
  """
  def subscribe(pid, event_method, routing_key \\ :global, subscriber \\ nil) do
    GenServer.call(pid, {:subscribe, event_method, subscriber, routing_key})
  catch
    :exit, _ -> :ok
  end

  @doc "Remove a subscriber registered via `subscribe/4`."
  def unsubscribe(pid, event_method, routing_key, subscriber) do
    GenServer.call(pid, {:unsubscribe, event_method, subscriber, routing_key})
  catch
    :exit, _ -> :ok
  end

  @doc """
  Remove every subscription whose key has the given session_id (any method).
  Cheap O(N) sweep — used at session-end to keep the dispatch table small
  when many ephemeral sessions share one connection.
  """
  def unsubscribe_session(pid, session_id) do
    GenServer.call(pid, {:unsubscribe_session, session_id})
  catch
    :exit, _ -> :ok
  end

  def close(pid) do
    GenServer.call(pid, :close)
  catch
    :exit, _ -> :ok
  end

  # GenServer callbacks

  @impl true
  def init(ws_url) do
    # Subscribers live in a public ETS table so the receive loop can
    # dispatch events with a single :ets.lookup + send/2, no GenServer
    # round-trip. Each WebSocketClient owns its own table; when the
    # process dies, the table dies with it.
    table =
      :ets.new(:surf_board_bidi_subscribers, [
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    case WireSocket.connect(ws_url) do
      {:ok, wire} -> {:ok, %__MODULE__{wire: wire, subscribers_table: table}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:assign_id_and_send, owner_pid, method, params, opts}, _from, state) do
    if System.get_env("SURF_BOARD_TRACE_QUEUE") == "1" do
      {:message_queue_len, qlen} = Process.info(self(), :message_queue_len)

      if qlen > 5,
        do: IO.puts(">>> SEND #{method} qlen=#{qlen} pending=#{map_size(state.pending)}")
    end

    {wire_id, wire} = WireSocket.send(state.wire, method, params, opts)
    pending = Map.put(state.pending, wire_id, owner_pid)
    {:reply, wire_id, %{state | wire: wire, pending: pending}}
  end

  def handle_call({:subscribe, event_method, subscriber, session_id}, {caller, _}, state) do
    target = subscriber || caller
    key = {event_method, session_id}
    existing = lookup_subs(state.subscribers_table, key)
    :ets.insert(state.subscribers_table, {key, [target | List.delete(existing, target)]})
    {:reply, :ok, state}
  end

  def handle_call({:unsubscribe, event_method, subscriber, session_id}, _from, state) do
    key = {event_method, session_id}
    existing = lookup_subs(state.subscribers_table, key)

    case List.delete(existing, subscriber) do
      [] -> :ets.delete(state.subscribers_table, key)
      list -> :ets.insert(state.subscribers_table, {key, list})
    end

    {:reply, :ok, state}
  end

  def handle_call({:unsubscribe_session, session_id}, _from, state) do
    :ets.match_delete(state.subscribers_table, {{:_, session_id}, :_})
    {:reply, :ok, state}
  end

  def handle_call(:close, _from, state) do
    WireSocket.close(state.wire)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info(message, state) do
    case WireSocket.handle_message(state.wire, message, state, callbacks()) do
      {:ok, state, wire} ->
        {:noreply, %{state | wire: wire}}

      {:error, reason, state, wire} ->
        Logger.debug("BiDi WebSocket error: #{inspect(reason)}")
        state = reply_all_pending(state, {:error, :session_closed})
        {:stop, {:transport_error, reason}, %{state | wire: wire}}

      :unknown ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    WireSocket.close(state.wire)
  end

  # ----- WireSocket callbacks -----

  defp callbacks do
    %{
      on_reply: &handle_command_response/3,
      on_event: &broadcast_event/3
    }
  end

  defp handle_command_response(id, result, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        state

      {owner_pid, pending} ->
        send(owner_pid, {:v2_response, id, result})
        %{state | pending: pending}
    end
  end

  defp broadcast_event(method, event, state) do
    # Session-scoped subscribers receive only events for their session.
    # Global subscribers (:global) receive all events regardless of session.
    #
    # CDP carries a flat sessionId at the top level. BiDi events vary —
    # most browsing-context-scoped events carry their context id under
    # `params.context` (or `params.source.context` for log entries). We
    # accept any of those as a session key.
    keys =
      [
        event["sessionId"],
        get_in(event, ["params", "context"]),
        get_in(event, ["params", "source", "context"])
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    table = state.subscribers_table

    session_pids =
      keys
      |> Enum.flat_map(fn k -> lookup_subs(table, {method, k}) end)

    global_pids = lookup_subs(table, {method, :global})

    Enum.each(session_pids ++ global_pids, fn pid ->
      send(pid, {:v2_event, method, event})
    end)

    state
  end

  defp lookup_subs(table, key) do
    case :ets.lookup(table, key) do
      [{^key, list}] -> list
      [] -> []
    end
  end

  defp reply_all_pending(state, reply) do
    Enum.each(state.pending, fn {id, owner_pid} ->
      send(owner_pid, {:v2_response, id, reply})
    end)

    state
  end
end
