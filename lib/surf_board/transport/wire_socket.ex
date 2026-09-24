defmodule SurfBoard.Transport.WireSocket do
  @moduledoc false

  # Generic Mint-WebSocket connect/upgrade/encode/decode plumbing, shared
  # by `SurfBoard.Transport.WebSocket` (one socket, many sessions multiplexed by a
  # subscriber table — used by `SurfBoard.Transport.Actor`'s
  # `{:shared, pid}` mode) and `Transport.Actor`'s own `{:fused, ws_url}`
  # mode (one socket per session, owned directly by the actor's own
  # GenServer — no separate socket process).
  #
  # This is NOT a GenServer or a process of its own — both callers need
  # the connection state to live inside their OWN struct/mailbox (that's
  # the whole point of the `:fused` mode's single-mailbox design), so
  # this module is a plain state-threading helper: it owns a
  # `%__MODULE__{}` sub-struct embedded in the caller's state, and the
  # caller drives it from its own `init/1` and `handle_info/2`.
  #
  # Contract: the caller supplies two callbacks at connect time —
  #
  #   * `on_reply.(id, parsed_result, acc)` — a frame carrying `"id"` (a
  #     command reply) arrived. `parsed_result` is already
  #     `{:ok, result} | {:error, reason}` (see `parse_response/1`).
  #   * `on_event.(method, raw_event_map, acc)` — a frame carrying
  #     `"method"` (an unsolicited event) arrived.
  #
  # Both receive and return `acc` — the caller's own state — so the
  # caller can update its own bookkeeping (pending-calls map, waiter
  # lists, ETS subscriber tables, ...) without this module knowing
  # anything about that shape.

  require Logger

  defstruct [
    :conn,
    :ref,
    :websocket,
    next_id: 1,
    # Set when the peer sends a close frame; handle_message/4 then
    # reports the connection as gone.
    closed?: false
  ]

  @type t :: %__MODULE__{}

  @type callbacks :: %{
          on_reply: (non_neg_integer(), {:ok, term()} | {:error, term()}, term() -> term()),
          on_event: (String.t(), map(), term() -> term())
        }

  @upgrade_timeout 10_000

  @doc """
  Connects to `ws_url` and completes the WebSocket upgrade before
  returning, so a rejected upgrade fails here rather than as later
  timeouts. The connection is switched to active mode on success.
  """
  @spec connect(String.t()) :: {:ok, t()} | {:error, term()}
  def connect(ws_url) when is_binary(ws_url) do
    uri = URI.parse(ws_url)
    http_scheme = if uri.scheme in ["wss", "https"], do: :https, else: :http
    ws_scheme = if uri.scheme in ["wss", "https"], do: :wss, else: :ws
    port = uri.port || if(http_scheme == :https, do: 443, else: 80)
    path = (uri.path || "/") <> if(uri.query, do: "?#{uri.query}", else: "")

    # Chromium 148 tightened DevTools' host allowlist: the upgrade
    # request must carry `Host: localhost` (or an IP literal) or Chrome
    # replies 500 "Host header is specified and is not an IP address or
    # localhost." That bites docker-sibling topologies where the WS URL
    # targets a hostname like `chrome:9222`. /json/version discovery
    # already passes Host: localhost; mirror it here so both legs of
    # the handshake match.
    upgrade_headers = [{"host", "localhost"}]

    with {:ok, conn} <- Mint.HTTP.connect(http_scheme, uri.host, port, mode: :passive),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(ws_scheme, conn, path, upgrade_headers),
         {:ok, conn, websocket} <- await_upgrade(conn, ref, %{}),
         {:ok, conn} <- Mint.HTTP.set_mode(conn, :active) do
      {:ok, %__MODULE__{conn: conn, ref: ref, websocket: websocket}}
    else
      {:error, {:upgrade_rejected, _, _} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, {:connection_failed, reason}}

      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        {:error, {:upgrade_failed, reason}}
    end
  end

  defp await_upgrade(conn, ref, acc) do
    case Mint.WebSocket.recv(conn, 0, @upgrade_timeout) do
      {:ok, conn, responses} ->
        acc = Enum.reduce(responses, acc, &collect_upgrade_response(&1, &2, ref))

        cond do
          acc[:status] == 101 and Map.has_key?(acc, :headers) ->
            Mint.WebSocket.new(conn, ref, 101, acc.headers)

          is_integer(acc[:status]) and acc[:status] != 101 and acc[:done] ->
            Mint.HTTP.close(conn)
            {:error, {:upgrade_rejected, acc.status, Map.get(acc, :body, "")}}

          true ->
            await_upgrade(conn, ref, acc)
        end

      {:error, conn, reason, _responses} ->
        {:error, conn, reason}
    end
  end

  defp collect_upgrade_response({:status, ref, status}, acc, ref),
    do: Map.put(acc, :status, status)

  defp collect_upgrade_response({:headers, ref, h}, acc, ref), do: Map.put(acc, :headers, h)

  defp collect_upgrade_response({:data, ref, data}, acc, ref),
    do: Map.update(acc, :body, data, &(&1 <> data))

  defp collect_upgrade_response({:done, ref}, acc, ref), do: Map.put(acc, :done, true)
  defp collect_upgrade_response(_other, acc, _ref), do: acc

  @doc """
  Assigns a wire id and sends a CDP/BiDi command. On success the
  caller stashes the id to correlate the eventual `on_reply` callback;
  on error no reply will ever come, so the caller must fail the call.
  """
  @spec send(t(), String.t(), map(), keyword()) ::
          {:ok, non_neg_integer(), t()} | {:error, non_neg_integer(), term(), t()}
  def send(%__MODULE__{} = state, method, params, opts \\ []) do
    id = state.next_id
    state = %{state | next_id: id + 1}
    message = build_message(id, method, params, opts) |> Jason.encode!()

    case send_frame(state, {:text, message}) do
      {:ok, state} -> {:ok, id, state}
      {:error, state, reason} -> {:error, id, reason, state}
    end
  end

  @doc """
  Feeds one transport message (from the owning process's mailbox)
  through Mint. Returns `{:ok, acc, state}` after dispatching any
  decoded frames to `on_reply`/`on_event`, `{:error, reason, acc,
  state}` if the underlying transport failed (the caller should stop),
  or `:unknown` if `message` wasn't a Mint message for this connection
  at all (the caller should handle it as its own internal message).
  A close frame from the peer is reported as `{:error, :closed_by_peer,
  acc, state}`.
  """
  @spec handle_message(t(), term(), acc, callbacks()) ::
          {:ok, acc, t()} | {:error, term(), acc, t()} | :unknown
        when acc: var
  def handle_message(%__MODULE__{} = state, message, acc, callbacks) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn}
        {state, acc} = Enum.reduce(responses, {state, acc}, &process_response(&1, &2, callbacks))

        if state.closed?,
          do: {:error, :closed_by_peer, acc, state},
          else: {:ok, acc, state}

      {:error, conn, reason, _responses} ->
        {:error, reason, acc, %{state | conn: conn}}

      :unknown ->
        :unknown
    end
  end

  @doc """
  Sends a WebSocket close frame (best-effort — a socket that's still
  mid-upgrade or already broken has nothing to send it on) and closes
  the underlying Mint connection.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{conn: conn} = state) do
    case send_frame(state, :close) do
      {:ok, %{conn: conn}} -> Mint.HTTP.close(conn)
      {:error, %{conn: conn}, _reason} -> Mint.HTTP.close(conn)
    end

    :ok
  rescue
    _ -> if conn, do: Mint.HTTP.close(conn)
  end

  @doc """
  Parses a decoded JSON-RPC reply into `{:ok, result} | {:error, reason}`.
  Exposed so a caller handling its own transport-drop path (failing
  every outstanding pending id) can build the same error shape.
  """
  @spec parse_response(map()) :: {:ok, term()} | {:error, term()}
  def parse_response(%{"error" => error, "message" => message}) when is_binary(error),
    do: {:error, {error, message}}

  def parse_response(%{"error" => %{"message" => message} = error}),
    do: {:error, {Map.get(error, "code", "unknown"), message}}

  def parse_response(%{"result" => result}), do: {:ok, result}
  def parse_response(other), do: {:ok, other}

  # ----- Frame processing -----

  defp process_response({:data, ref, data}, {%{ref: ref} = state, acc}, callbacks) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        Enum.reduce(
          frames,
          {%{state | websocket: websocket}, acc},
          &process_frame(&1, &2, callbacks)
        )

      {:error, websocket, reason} ->
        Logger.error("WireSocket decode error: #{inspect(reason)}")
        {%{state | websocket: websocket}, acc}
    end
  end

  defp process_response(_response, acc_state, _callbacks), do: acc_state

  defp process_frame({:text, text}, {state, acc}, callbacks) do
    case Jason.decode(text) do
      {:ok, %{"id" => id} = response} ->
        acc = callbacks.on_reply.(id, parse_response(response), acc)
        {state, acc}

      {:ok, %{"method" => method} = event} ->
        acc = callbacks.on_event.(method, event, acc)
        {state, acc}

      {:error, _} ->
        Logger.warning("WireSocket received invalid JSON: #{inspect(String.slice(text, 0, 200))}")

        {state, acc}
    end
  end

  defp process_frame({:close, _code, _reason}, {state, acc}, _callbacks) do
    {%{state | closed?: true}, acc}
  end

  defp process_frame(_frame, acc_state, _callbacks), do: acc_state

  # ----- Send -----

  defp build_message(id, method, params, opts) do
    base = %{id: id, method: method, params: params}

    cond do
      Keyword.get(opts, :flat_session_id) ->
        Map.put(base, :sessionId, Keyword.fetch!(opts, :session_id))

      session_id = Keyword.get(opts, :session_id) ->
        %{base | params: Map.put(params, :sessionId, session_id)}

      true ->
        base
    end
  end

  defp send_frame(state, frame) do
    case Mint.WebSocket.encode(state.websocket, frame) do
      {:ok, websocket, data} ->
        case Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
          {:ok, conn} ->
            {:ok, %{state | conn: conn, websocket: websocket}}

          {:error, conn, reason} ->
            {:error, %{state | conn: conn, websocket: websocket}, reason}
        end

      {:error, websocket, reason} ->
        {:error, %{state | websocket: websocket}, reason}
    end
  end
end
