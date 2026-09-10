defmodule SurfBoard.Transport do
  @moduledoc false

  # Strategy for the "where does a session get its WebSocket" question.
  #
  # The stack already has a shape for talking to a CDP-speaking
  # browser: a `WebSocket` pid + a routing key (the CDP `sessionId`,
  # used for flat-session multiplexing). The thing that varies across
  # browsers is *how a session acquires that pid* at start_session time
  # — each way of doing that lives under `Transport.Strategy.*`, and
  # implements the `SurfBoard.Transport.Strategy` behaviour: one
  # `start_session(opts) :: {:ok, Session.t()} | {:error, term}`
  # callback, driver-agnostic — the caller supplies a `:session_struct`
  # template (id/driver/driver_spec/live_view_aware?/base capabilities
  # already filled in) and the strategy returns it with `bidi_pid`,
  # `browsing_context`, and `capabilities` populated and the session
  # GenServer already up.
  #
  # Four concrete strategies today:
  #
  #   * `Strategy.SharedWS`        — Chrome CDP. One WebSocket per BEAM,
  #                         held in an Agent. Each session gets a fresh
  #                         BrowserContext + Target + sessionId on the
  #                         shared WS. Feeds `Transport.Actor` a
  #                         `{:shared, ws_pid}` config.
  #
  #   * `Strategy.PerSession`      — Lightpanda. One shared browser
  #                         process per BEAM, but one WebSocket per
  #                         session (Lightpanda accepts many WS to one
  #                         binary). Feeds `Transport.Actor` a
  #                         `{:fused, ws_url}` config — the actor owns
  #                         its own WireSocket directly, no separate
  #                         socket process.
  #
  #   * `Strategy.IsolatedProcess` — One browser process AND one
  #                         WebSocket per session. Slower but isolated.
  #                         Used as a fallback / for browsers we can't
  #                         share. Also feeds `Transport.Actor` a
  #                         `{:shared, ws_pid}` config (the WS just
  #                         isn't actually shared with any other
  #                         session in practice).
  #
  #   * `Strategy.BiDi`            — chromium-bidi. One POST /session +
  #                         one WS per session. Feeds `Transport.Actor`
  #                         a `{:shared, ws_pid}` config with
  #                         `send: :spawn_link` (BiDi's
  #                         WebSocketClient.send_command/4 blocks
  #                         synchronously, unlike CDP's
  #                         WireSocket/WebSocket, so a slow call can't
  #                         be allowed to stall the actor's mailbox —
  #                         see `Transport.Actor`'s moduledoc).
  #
  # Each impl returns the same shape so the surrounding driver code
  # (install_bootstrap, await_page_load, click_aware, …) is unchanged.
  # A driver picks its strategy by module name once, at author time
  # (ChromeCDP always calls Strategy.SharedWS.start_session/1); the one
  # exception is Lightpanda's isolated/external fallback, which calls
  # `transport_mod.start_session/1` polymorphically because it can
  # resolve to either Strategy.IsolatedProcess or (in principle) any
  # other module honoring the same behaviour.

  alias SurfBoard.Transport.Actor
  alias SurfBoard.Clients.CDP.Wire
  alias SurfBoard.WebSocket

  @typedoc """
  What a `Strategy.SharedWS`/`Strategy.IsolatedProcess` connection
  acquisition step returns internally, before being folded into the
  caller's `:session_struct` template by `start_session_from/3`.

    * `:ws_pid`       — the WebSocket the session sends through
    * `:target_id`    — Chrome target id (CDP) for window-handle
                        bookkeeping; nil if N/A
    * `:session_id`   — the CDP flat-session sessionId (routing key);
                        nil if the transport doesn't multiplex
    * `:browser_context_id` — for SharedWS only; teardown
                        disposes this rather than closing the WS
    * `:teardown_fun` — 1-arity called from Session.terminate/2;
                        receives the session struct
    * `:capabilities` — opaque map merged into the session capabilities
  """
  @type acquired :: %{
          ws_pid: pid,
          target_id: String.t() | nil,
          session_id: String.t() | nil,
          browser_context_id: String.t() | nil,
          teardown_fun: (SurfBoard.Session.t() -> any),
          capabilities: map
        }

  # ----- Default implementations of common teardown shapes -----
  # Drivers can use these directly or build their own.

  @doc """
  Teardown that closes the WebSocket. Use when the session OWNS
  its WS (Strategy.PerSession, Strategy.IsolatedProcess).
  """
  @spec close_ws(pid) :: :ok
  def close_ws(ws_pid) when is_pid(ws_pid) do
    try do
      WebSocket.close(ws_pid)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  @doc """
  Teardown that disposes a Chrome BrowserContext on the shared WS.
  Use with `Strategy.SharedWS`.
  """
  @spec dispose_browser_context(pid, String.t()) :: :ok
  def dispose_browser_context(ws_pid, ctx_id)
      when is_pid(ws_pid) and is_binary(ctx_id) do
    try do
      WebSocket.send_sync(ws_pid, "Target.disposeBrowserContext", %{
        browserContextId: ctx_id
      })
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  @doc """
  Convenience that calls `attachToTarget(targetId, flatten: true)` on
  `ws_pid` and returns `{:ok, sessionId}`. Used by Strategy.SharedWS and
  Strategy.PerSession impls.
  """
  @spec attach_to_target(pid, String.t()) :: {:ok, String.t()} | {:error, term}
  def attach_to_target(ws_pid, target_id) do
    case WebSocket.send_sync(ws_pid, "Target.attachToTarget", %{
           targetId: target_id,
           flatten: true
         }) do
      {:ok, %{"sessionId" => sid}} -> {:ok, sid}
      err -> err
    end
  end

  # ----- Shared session bring-up -----

  @doc """
  Shared second half of `Strategy.SharedWS.start_session/1` and
  `Strategy.IsolatedProcess.start_session/1`: folds an `acquired` map
  (from their own connection-acquisition step) into the caller's
  `:session_struct` template, brings up the actor, and runs the
  standard CDP init sequence (page lifecycle, bootstrap, frame
  tracking).

  `template.capabilities` is treated as the driver's base capabilities
  (e.g. user-supplied ones); `acquired.capabilities` is merged on top,
  winning on conflicts — mirroring what each of those strategies needs
  from its own acquisition step (target id, flat-session routing, …).

  Returns `{:ok, %SurfBoard.Session{}}` ready for callers to use.
  """
  @spec start_session_from(acquired, SurfBoard.Session.t(), keyword) ::
          {:ok, SurfBoard.Session.t()} | {:error, term}
  def start_session_from(%{ws_pid: ws_pid, teardown_fun: teardown} = acquired, template, opts) do
    caller = Keyword.get(opts, :owner, self())

    session_struct = %{
      template
      | bidi_pid: ws_pid,
        browsing_context: acquired.session_id,
        capabilities: Map.merge(template.capabilities || %{}, acquired.capabilities)
    }

    config = %Actor.Config{
      socket: {:shared, ws_pid},
      send: :inline,
      load: :buffer,
      subscribe: :passive,
      wire: Wire
    }

    case Actor.start_link(
           config: config,
           init_fun: fn -> {:ok, session_struct} end,
           teardown_fun: teardown,
           owner: caller
         ) do
      {:ok, session} ->
        :ok = SurfBoard.Clients.CDP.Client.enable_page_lifecycle_events(session)
        :ok = SurfBoard.Clients.CDP.Client.install_bootstrap(session)
        :ok = SurfBoard.Clients.CDP.Client.enable_frame_tracking(session)
        {:ok, session}

      err ->
        # Already-attempted teardown so the WebSocket / context isn't
        # leaked when the Session GenServer fails to come up.
        try do
          teardown.(session_struct)
        catch
          _, _ -> :ok
        end

        err
    end
  end
end
