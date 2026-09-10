defmodule SurfBoard.WebSocket do
  @moduledoc false

  # Transport layer (the "plexer/demuxer") for CDP and BiDi WebSocket
  # protocols. Replaces `SurfBoard.Drivers.ChromeBiDi.WebSocketClient`
  # by being deliberately dumber:
  #
  #   * outbound = encode JSON, write bytes, register correlation
  #   * inbound  = parse bytes, route to the right SessionProcess
  #
  # No find waiters, no page-ready logic, no per-session state — those
  # all live in `SurfBoard.Transport.Actor`. The split exists so the
  # request/response correlation flows through ONE actor (the owning
  # session) and async events arrive at that same actor's mailbox in
  # FIFO order, eliminating the cross-process ordering races that the
  # old design papered over with a sync barrier.
  #
  # Routing:
  #
  #   * Responses (frames carrying `"id"`) go back to the Transport.Actor
  #     that issued the call — looked up by wire id.
  #   * Events (frames carrying `"method"`) are routed by the routing
  #     key (`sessionId` for CDP, `params.context` /
  #     `params.source.context` for BiDi) to subscribed Transport.Actors.
  #
  # The actor that issued a call is identified by passing its `pid`
  # in `cast_send/5`. We stash `wire_id → owner_pid` and reply via
  # `send(owner_pid, {:v2_response, wire_id, result})`.
  #
  # The actual Mint-WebSocket connect/upgrade/encode/decode plumbing
  # lives in `SurfBoard.Transport.WireSocket`, shared with
  # `SurfBoard.Transport.Actor`'s `{:fused, ws_url}` mode — this module
  # supplies the "one socket, many sessions" policy on top of it: the
  # subscriber table and the owner-pid-keyed pending map, used by
  # `Transport.Actor`'s `{:shared, pid}` mode.

  use GenServer
  require Logger

  alias SurfBoard.Transport.WireSocket

  defstruct [
    :wire,
    :subscribers_table,
    pending: %{}
  ]

  @type routing_key :: String.t() | :global

  # ----- Public API -----

  @doc """
  Starts a WebSocket connection to `ws_url`. Returns `{:ok, pid}` on
  successful upgrade.
  """
  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(ws_url) when is_binary(ws_url) do
    GenServer.start_link(__MODULE__, ws_url)
  end

  @doc """
  Like `start_link/1` but starts the GenServer unlinked. Used by the
  shared-connection Agent so the WS isn't tied to the caller's
  lifetime.
  """
  @spec start(String.t()) :: GenServer.on_start()
  def start(ws_url) when is_binary(ws_url) do
    GenServer.start(__MODULE__, ws_url)
  end

  @doc """
  Asynchronously send a CDP/BiDi command. The response (or transport
  failure) will be delivered to `owner_pid` as
  `{:v2_response, wire_id, result}`.

  Returns the wire id assigned to this call so the caller can stash
  it in its pending-calls map.

  `opts`:
    * `:flat_session_id` (boolean) — if true, places `sessionId` at the
      JSON-RPC top level (CDP flat-session protocol). If false (default),
      `sessionId` rides inside `params` if present.
    * `:session_id` (string) — required when `:flat_session_id` is true.
  """
  @spec cast_send(pid, pid, String.t(), map, keyword) :: non_neg_integer()
  def cast_send(ws_pid, owner_pid, method, params, opts \\ []) do
    GenServer.call(ws_pid, {:assign_id_and_send, owner_pid, method, params, opts})
  end

  @doc """
  Synchronously send a CDP/BiDi command and wait for the response.

  Convenience wrapper around `cast_send/5` for callers without a
  Session GenServer (e.g. session bootstrap that runs before the
  Session exists). The caller's mailbox receives the `:v2_response`
  message; this function pulls it out and returns the result.

  Caveat: this consumes the next `:v2_response` matching `wire_id`
  from the calling process's mailbox. Don't use it from a process
  that has other in-flight calls.
  """
  @spec send_sync(pid, String.t(), map, keyword) :: {:ok, map} | {:error, term}
  def send_sync(ws_pid, method, params, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 15_000)
    wire_id = cast_send(ws_pid, self(), method, params, Keyword.delete(opts, :timeout))

    receive do
      {:v2_response, ^wire_id, result} -> result
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc """
  Subscribe `subscriber` to events matching `event_method`, scoped by
  `routing_key` (a session/context id) or `:global` for all sessions.
  """
  @spec subscribe(pid, String.t(), routing_key, pid | nil) :: :ok
  def subscribe(ws_pid, event_method, routing_key \\ :global, subscriber \\ nil)
      when is_binary(event_method) do
    GenServer.call(ws_pid, {:subscribe, event_method, routing_key, subscriber || self()})
  end

  @doc "Remove a subscription."
  @spec unsubscribe(pid, String.t(), routing_key, pid) :: :ok
  def unsubscribe(ws_pid, event_method, routing_key, subscriber)
      when is_binary(event_method) and is_pid(subscriber) do
    GenServer.call(ws_pid, {:unsubscribe, event_method, routing_key, subscriber})
  end

  @doc "Drop all subscriptions for a routing key. Used at session teardown."
  @spec unsubscribe_all(pid, routing_key) :: :ok
  def unsubscribe_all(ws_pid, routing_key) do
    GenServer.call(ws_pid, {:unsubscribe_all, routing_key})
  end

  @doc "Close the WebSocket and stop the GenServer."
  @spec close(pid) :: :ok
  def close(ws_pid) do
    GenServer.call(ws_pid, :close)
  end

  # ----- GenServer callbacks -----

  @impl true
  def init(ws_url) do
    table =
      :ets.new(:surf_board_v2_subscribers, [
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
  def handle_call(
        {:assign_id_and_send, owner_pid, method, params, opts},
        _from,
        state
      ) do
    t0 = SurfBoard.Bench.Timing.mark_now()
    {id, wire} = WireSocket.send(state.wire, method, params, opts)
    pending = Map.put(state.pending, id, {owner_pid, t0})
    {:reply, id, %{state | wire: wire, pending: pending}}
  end

  def handle_call({:subscribe, event_method, routing_key, subscriber}, _from, state) do
    key = {event_method, routing_key}
    existing = lookup_subs(state.subscribers_table, key)
    :ets.insert(state.subscribers_table, {key, [subscriber | List.delete(existing, subscriber)]})
    {:reply, :ok, state}
  end

  def handle_call({:unsubscribe, event_method, routing_key, subscriber}, _from, state) do
    key = {event_method, routing_key}
    existing = lookup_subs(state.subscribers_table, key)

    case List.delete(existing, subscriber) do
      [] -> :ets.delete(state.subscribers_table, key)
      list -> :ets.insert(state.subscribers_table, {key, list})
    end

    {:reply, :ok, state}
  end

  def handle_call({:unsubscribe_all, routing_key}, _from, state) do
    :ets.match_delete(state.subscribers_table, {{:_, routing_key}, :_})
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
        Logger.warning(
          "WebSocket transport error pid=#{inspect(self())} msg=#{inspect(message)} reason=#{inspect(reason)}"
        )

        state = notify_all_pending(state, {:error, :session_closed})
        {:stop, {:transport_error, reason}, %{state | wire: wire}}

      :unknown ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    WireSocket.close(state.wire)
    :ok
  end

  # ----- WireSocket callbacks -----

  defp callbacks do
    %{
      on_reply: &deliver_response/3,
      on_event: &broadcast_event/3
    }
  end

  defp deliver_response(id, result, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        # No registered owner — fire-and-forget cast or stale id. Ignore.
        state

      {{owner_pid, t0}, pending} ->
        SurfBoard.Bench.Timing.record(t0)
        send(owner_pid, {:v2_response, id, result})
        %{state | pending: pending}
    end
  end

  defp broadcast_event(method, event, state) do
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
      keys |> Enum.flat_map(fn k -> lookup_subs(table, {method, k}) end)

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

  defp notify_all_pending(state, reply) do
    Enum.each(state.pending, fn {id, {owner_pid, _t0}} ->
      send(owner_pid, {:v2_response, id, reply})
    end)

    state
  end
end
