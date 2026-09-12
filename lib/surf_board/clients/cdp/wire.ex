defmodule SurfBoard.Clients.CDP.Wire do
  @moduledoc false

  # CDP wire-level event decoder used by `SurfBoard.Transport.Actor` for
  # every CDP-protocol session (Chrome CDP's shared-WS mode and
  # Lightpanda's fused per-session mode both use it — same decoder,
  # different socket-ownership mode underneath).
  #
  # `handle_event/3` is a pure function over the actor's state map; the
  # actor wraps the return value in `{:noreply, state}`.

  alias SurfBoard.Transport.Common

  @doc """
  Decodes one CDP event for an actor's state. Returns the new state.

  Recognised events:

    * `Page.lifecycleEvent` — record `(loaderId, milestone)` so any
      matching load waiter wakes immediately (or the milestone buffers
      for a later caller).
    * `Runtime.bindingCalled` — bootstrap channel; routed to
      `Common.route_bootstrap_payload/2` when the binding name matches.
    * `Network.responseReceived` — record the main-frame HTTP status and
      headers, keyed by loaderId, for `SurfBoard.Browser.status/1`.
    * `Runtime.executionContextCreated` — record `frameId → contextId`.
    * `Runtime.executionContextDestroyed` — purge the destroyed context.
    * `Inspector.targetCrashed` / `Target.detachedFromTarget` — the
      renderer this session was attached to is gone (crash, OOM kill,
      or the target otherwise disappearing from under us). Sets
      `target_crashed?: true`; `Transport.Actor` checks this after
      every event dispatch and fails every pending call immediately
      instead of leaving them to time out one by one against a target
      that will never reply again.

  Unknown methods are a no-op.
  """
  @spec handle_event(map(), String.t(), map()) :: map()
  def handle_event(state, method, event)

  def handle_event(state, "Inspector.targetCrashed", _event) do
    %{state | target_crashed?: true}
  end

  def handle_event(state, "Target.detachedFromTarget", event) do
    params = Map.get(event, "params", %{})
    detached_session_id = params["sessionId"]
    our_session_id = state.session.browsing_context

    if is_binary(detached_session_id) and detached_session_id == our_session_id do
      %{state | target_crashed?: true}
    else
      state
    end
  end

  def handle_event(state, "Page.lifecycleEvent", event) do
    params = Map.get(event, "params", %{})
    loader_id = params["loaderId"]
    name = params["name"]

    if is_binary(loader_id) and name in ["load", "DOMContentLoaded"] do
      Common.record_load_milestone(state, loader_id, name)
    else
      state
    end
  end

  def handle_event(state, "Network.responseReceived", event) do
    params = Map.get(event, "params", %{})
    loader_id = params["loaderId"]
    response = params["response"]

    # For the document request CDP sets requestId == loaderId; subresources
    # (images, XHR, …) carry their own requestId. Keeping only the former
    # means `status/1` reports the page's own status, not whichever asset
    # happened to load last.
    main_frame? = is_binary(loader_id) and params["requestId"] == loader_id

    if main_frame? and is_map(response) do
      entry = %{
        status: response["status"],
        status_text: response["statusText"],
        url: response["url"],
        mime_type: response["mimeType"],
        headers: response["headers"] || %{}
      }

      %{
        state
        | responses: Map.put(state.responses, loader_id, entry),
          last_loader_id: loader_id
      }
    else
      state
    end
  end

  def handle_event(state, "Runtime.bindingCalled", event) do
    params = Map.get(event, "params", %{})

    if params["name"] == "__surfboard" and is_binary(params["payload"]) do
      Common.route_bootstrap_payload(state, params["payload"])
    else
      state
    end
  end

  def handle_event(state, "Runtime.executionContextCreated", event) do
    ctx = get_in(event, ["params", "context"]) || %{}
    aux = Map.get(ctx, "auxData", %{})
    context_id = ctx["id"]
    frame_id = aux["frameId"]

    if is_integer(context_id) and is_binary(frame_id) do
      %{state | frame_contexts: Map.put(state.frame_contexts, frame_id, context_id)}
    else
      state
    end
  end

  def handle_event(state, "Runtime.executionContextDestroyed", event) do
    destroyed = get_in(event, ["params", "executionContextId"])

    if is_integer(destroyed) do
      contexts =
        state.frame_contexts
        |> Enum.reject(fn {_frame_id, ctx_id} -> ctx_id == destroyed end)
        |> Map.new()

      %{state | frame_contexts: contexts}
    else
      state
    end
  end

  def handle_event(state, _method, _event), do: state
end
