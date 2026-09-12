defmodule SurfBoard.Transport.Protocol do
  @moduledoc false

  # Documents the message protocol every transport-actor honors, and
  # provides thin client helpers that wrap the corresponding
  # `GenServer.call`/`GenServer.cast`. Callers (today: CDPClient,
  # Browser through dispatch) go through this module instead of
  # talking to Session directly — that lets us swap the actor
  # underneath each session for a different transport implementation
  #
  # ## Why a "protocol" and not a `@behaviour`
  #
  # A behaviour would force every transport to expose a module with
  # the same function arity, even though the only place we'd dispatch
  # to "the behaviour" is inside this client helper. A documented
  # message protocol is the same contract with one less indirection.
  #
  # ## Messages
  #
  # The session struct's `pid` is the transport actor. Every
  # transport actor must respond to:
  #
  # ### Synchronous (`GenServer.call`)
  #
  #   * `:get_session` → returns the `%SurfBoard.Session{}`.
  #   * `{:cdp_send, method, params, opts}` → runs a CDP RPC,
  #     returns `{:ok, term}` or `{:error, term}`.
  #   * `{:subscribe, event_method, routing_key}` → wires the actor
  #     to receive events of `event_method` matching `routing_key`.
  #     Returns `:ok`.
  #   * `{:await_page_load, loader_id, name, timeout_ms}` → blocks
  #     until `Page.lifecycleEvent` fires for that loader+milestone.
  #   * `{:await_next_page_load, name, timeout_ms}` → blocks until
  #     ANY lifecycle event of the given milestone fires.
  #   * `{:await_page_ready_after, pre_page_id, timeout_ms}` → blocks
  #     until the bootstrap reports a different `pageId`.
  #   * `{:await_find_result, query_id}` → blocks until the bootstrap
  #     fires `__surfboard(...)` for that query id.
  #   * `{:register_find, query_id, timeout_ms}` → reserves a
  #     find-waiter slot before the JS that fires the binding runs.
  #   * `:current_context_id` → returns the focused frame's
  #     executionContextId (or nil for root).
  #   * `{:push_frame, context_id}` / `:pop_frame` /
  #     `:reset_frame_stack` → manage the frame focus stack.
  #   * `{:record_frame_context, frame_id, context_id}` /
  #     `{:lookup_frame_context, frame_id}` — frame_id ↔ context_id
  #     bookkeeping.
  #   * `:sync_barrier` → no-op call used as a mailbox barrier when
  #     the caller wants to ensure prior in-flight messages have
  #     drained.
  #   * `{:update_browsing_context, session_id, target_id}` →
  #     mutates the actor's session struct. Sent during ordinary
  #     session bring-up (PerSession/BiDi strategies assign the
  #     session's initial context this way) — does NOT set
  #     `switched_window?`.
  #   * `{:focus_window, session_id, target_id}` → same struct
  #     mutation as `:update_browsing_context`, but also sets
  #     `switched_window?: true`. Sent only by
  #     `Clients.{CDP,BiDi}.Windows.focus_window/2` — the user-facing
  #     "switch to a different window/tab" operation. `target_id` is
  #     `nil` for drivers with no separate target-id concept (BiDi —
  #     only browsing-context ids exist there).
  #   * `:switched_window?` → `true` once `:focus_window` has fired at
  #     least once for this session.
  #   * `{:closing_window, context_id}` → records that this session
  #     itself is about to close `context_id`, so the crash-detection
  #     event it produces isn't mistaken for a real crash. Sent only by
  #     `Clients.{CDP,BiDi}.Windows.close_window/1`.
  #
  # ### Asynchronous (`GenServer.cast`)
  #
  #   * `{:cdp_cast, method, params, opts}` → fire-and-forget CDP
  #     RPC. Response is dropped.
  #
  # ### Inbound (sent by the transport's connection layer)
  #
  #   * `{:v2_response, wire_id, result}` → response to a previously
  #     issued `cdp_send`/`cdp_cast`.
  #   * `{:v2_event, method, event_map}` → wire-level event the
  #     actor previously subscribed to.
  #
  # Lifecycle:
  #
  #   * The actor is started by whichever `SurfBoard.Transport.Strategy`
  #     the driver picked — `Transport.Strategy.SharedWS.start_session/1`,
  #     `Transport.Strategy.IsolatedProcess.start_session/1`,
  #     `Transport.Strategy.PerSession.start_session/1`, or
  #     `Transport.Strategy.BiDi.start_session/1` — depending on which
  #     driver is starting the session. Each ends with an actor pid
  #     honoring this contract.
  #   * The actor monitors its owner; if the owner dies, it stops
  #     itself and runs its teardown_fun.
  #   * `stop/1` triggers an orderly shutdown.

  alias SurfBoard.Session

  @default_timeout 30_000

  # ----- Synchronous CDP RPC -----

  @spec cdp_send(Session.t(), String.t(), map, keyword) :: {:ok, term} | {:error, term}
  def cdp_send(%Session{pid: pid}, method, params, opts \\ []) when is_pid(pid) do
    GenServer.call(pid, {:cdp_send, method, params, opts}, @default_timeout)
  catch
    :exit, {:noproc, _} -> {:error, :session_closed}
    :exit, {:normal, _} -> {:error, :session_closed}
  end

  @spec cdp_cast(Session.t(), String.t(), map, keyword) :: :ok
  def cdp_cast(%Session{pid: pid}, method, params, opts \\ []) when is_pid(pid) do
    GenServer.cast(pid, {:cdp_cast, method, params, opts})
  end

  # ----- Subscription -----

  @spec subscribe(Session.t(), String.t(), :global | nil) :: :ok
  def subscribe(%Session{pid: pid}, event_method, routing_key \\ nil)
      when is_binary(event_method) do
    GenServer.call(pid, {:subscribe, event_method, routing_key})
  end

  # ----- HTTP response metadata -----

  @doc """
  The main-frame HTTP response recorded for the most recent navigation, or
  `nil` if none has been captured (e.g. the driver's wire protocol doesn't
  report it, or nothing has been visited yet).
  """
  @spec last_response(Session.t()) :: map() | nil
  def last_response(%Session{pid: pid}) when is_pid(pid) do
    GenServer.call(pid, :last_response)
  catch
    :exit, _ -> nil
  end

  # ----- Page-load & page-ready awaits -----

  @doc """
  `frame_id`, when given, lets the actor transparently follow a
  same-frame redirect: if the frame's loader_id changes before the
  awaited milestone fires (a redirect swaps in a new loader_id for the
  same navigation), the wait is re-keyed to the new loader_id instead
  of expiring against one that will never complete. See
  `Transport.Common.record_load_milestone/4`.
  """
  @spec await_page_load(Session.t(), String.t(), String.t(), timeout, String.t() | nil) ::
          :ok | :timeout
  def await_page_load(%Session{pid: pid}, loader_id, name, timeout_ms \\ 10_000, frame_id \\ nil)
      when is_binary(loader_id) and is_binary(name) do
    GenServer.call(
      pid,
      {:await_page_load, loader_id, name, timeout_ms, frame_id},
      timeout_ms + 2_000
    )
  catch
    :exit, _ -> :timeout
  end

  @spec await_next_page_load(Session.t(), String.t(), timeout) :: :ok | :timeout
  def await_next_page_load(%Session{pid: pid}, name \\ "load", timeout_ms \\ 10_000)
      when is_binary(name) do
    GenServer.call(pid, {:await_next_page_load, name, timeout_ms}, timeout_ms + 2_000)
  catch
    :exit, _ -> :timeout
  end

  @spec await_page_ready_after(Session.t(), String.t() | nil, timeout) :: :ok | :timeout
  def await_page_ready_after(%Session{pid: pid}, pre_page_id, timeout_ms \\ 5_000) do
    # The server may extend the inner timer if a `nav_pending` arrives
    # (LV transition in flight, dest mount slow). Allow up to 12s of
    # slack on top of the caller's budget so the GenServer.call doesn't
    # cap the extension. The server's own timer is still the source of
    # truth for the actual deadline.
    GenServer.call(pid, {:await_page_ready_after, pre_page_id, timeout_ms}, timeout_ms + 12_000)
  catch
    :exit, _ -> :timeout
  end

  # ----- Find waiters -----

  @spec register_find(Session.t(), String.t(), timeout) :: :ok
  def register_find(%Session{pid: pid}, query_id, timeout_ms) when is_binary(query_id) do
    GenServer.call(pid, {:register_find, query_id, timeout_ms})
  end

  @spec await_find_result(Session.t(), String.t(), timeout) ::
          {:ok, non_neg_integer, map}
          | {:error, :invalid_selector}
          | {:timeout, non_neg_integer}
  def await_find_result(%Session{pid: pid}, query_id, timeout_ms)
      when is_binary(query_id) do
    GenServer.call(pid, {:await_find_result, query_id}, timeout_ms + 2_000)
  catch
    :exit, _ -> {:timeout, 0}
  end

  # ----- Frame stack -----

  @spec current_context_id(Session.t()) :: integer | String.t() | nil
  def current_context_id(%Session{pid: pid}) when is_pid(pid) do
    GenServer.call(pid, :current_context_id)
  catch
    :exit, _ -> nil
  end

  @spec get_page_id(Session.t()) :: String.t() | nil
  def get_page_id(%Session{pid: pid}) when is_pid(pid) do
    GenServer.call(pid, :get_page_id)
  catch
    :exit, _ -> nil
  end

  @spec push_frame(Session.t(), integer | String.t()) :: :ok
  def push_frame(%Session{pid: pid}, context_id)
      when is_integer(context_id) or is_binary(context_id) do
    GenServer.call(pid, {:push_frame, context_id})
  catch
    :exit, _ -> :ok
  end

  @spec pop_frame(Session.t()) :: :ok
  def pop_frame(%Session{pid: pid}) when is_pid(pid) do
    GenServer.call(pid, :pop_frame)
  catch
    :exit, _ -> :ok
  end

  @spec record_frame_context(Session.t(), String.t(), integer) :: :ok
  def record_frame_context(%Session{pid: pid}, frame_id, context_id)
      when is_binary(frame_id) and is_integer(context_id) do
    GenServer.call(pid, {:record_frame_context, frame_id, context_id})
  end

  @spec lookup_frame_context(Session.t(), String.t()) :: integer | nil
  def lookup_frame_context(%Session{pid: pid}, frame_id) when is_binary(frame_id) do
    GenServer.call(pid, {:lookup_frame_context, frame_id})
  catch
    :exit, _ -> nil
  end

  # ----- Window focus -----

  @doc """
  Mutates the actor's session struct's context/target-id. Used during
  ordinary session bring-up to assign the session's initial context —
  does NOT mark this session as having switched windows. For the
  user-facing "focus a different window" operation, use
  `focus_window/3` instead.
  """
  @spec update_browsing_context(Session.t(), String.t(), String.t() | nil) :: :ok
  def update_browsing_context(%Session{pid: pid}, session_id, target_id)
      when is_pid(pid) and is_binary(session_id) do
    GenServer.call(pid, {:update_browsing_context, session_id, target_id})
  catch
    :exit, _ -> :ok
  end

  @doc """
  Same struct mutation as `update_browsing_context/3`, but also marks
  this session as having switched windows (see `switched_window?/1`).
  `target_id` is `nil` for drivers with no separate target-id concept
  (BiDi — the browsing-context id in `session_id` is the only handle).
  """
  @spec focus_window(Session.t(), String.t(), String.t() | nil) :: :ok
  def focus_window(%Session{pid: pid}, session_id, target_id)
      when is_pid(pid) and is_binary(session_id) do
    GenServer.call(pid, {:focus_window, session_id, target_id})
  catch
    :exit, _ -> :ok
  end

  @doc "Has this session's window focus ever moved off its starting target?"
  @spec switched_window?(Session.t()) :: boolean
  def switched_window?(%Session{pid: pid}) when is_pid(pid) do
    GenServer.call(pid, :switched_window?)
  catch
    :exit, _ -> false
  end

  @doc """
  Call right before asking the browser to close `context_id` (the CDP
  sessionId or BiDi context id being closed). An intentional close
  produces the exact same wire event as that target genuinely
  crashing — `wire_mod.handle_event/3` checks this so it doesn't set
  `target_crashed?` for a close this session itself requested.
  """
  @spec closing_window(Session.t(), String.t()) :: :ok
  def closing_window(%Session{pid: pid}, context_id)
      when is_pid(pid) and is_binary(context_id) do
    GenServer.call(pid, {:closing_window, context_id})
  catch
    :exit, _ -> :ok
  end

  # ----- Misc -----

  @spec sync_barrier(Session.t()) :: :ok
  def sync_barrier(%Session{pid: pid}) when is_pid(pid) do
    GenServer.call(pid, :sync_barrier)
  catch
    :exit, _ -> :ok
  end

  def sync_barrier(_), do: :ok

  @spec stop(Session.t()) :: :ok
  def stop(%Session{pid: pid}) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  def stop(_), do: :ok
end
