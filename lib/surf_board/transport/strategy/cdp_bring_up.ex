defmodule SurfBoard.Transport.Strategy.CDPBringUp do
  @moduledoc false

  # CDP-only session bring-up, shared by the two CDP connection
  # strategies: `Strategy.SharedWS` (Chrome — one WebSocket per BEAM,
  # a fresh BrowserContext + Target + sessionId per session) and
  # `Strategy.IsolatedProcess` (one browser process AND one WebSocket
  # per session — slower but isolated; used as a fallback / for
  # browsers that can't share a connection).
  #
  # This is NOT a generic "any protocol" bring-up module, despite once
  # living at the top level as `SurfBoard.Transport` — every function
  # here (`attach_to_target/2`, `dispose_browser_context/2`,
  # `start_session_from/3`'s own bootstrap/page-lifecycle/frame-tracking
  # sequence) is a raw CDP wire call or CDP-specific bring-up step.
  # `Strategy.PerSession` (Lightpanda) and `Strategy.BiDi` don't call
  # anything in this module — each does its own bring-up entirely
  # inline, because their bring-up genuinely doesn't share this shape.
  # The one truly protocol-agnostic thing here is the `Strategy`
  # behaviour contract itself (`SurfBoard.Transport.Strategy`) that all
  # four strategies implement — that lives in its own file, unchanged.

  alias SurfBoard.Transport.Actor
  alias SurfBoard.Clients.CDP.Wire
  alias SurfBoard.Transport.WebSocket

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
    * `:driver_state` — becomes the session's `driver_state`
  """
  @type acquired :: %{
          ws_pid: pid,
          target_id: String.t() | nil,
          session_id: String.t() | nil,
          browser_context_id: String.t() | nil,
          teardown_fun: (SurfBoard.Session.t() -> any),
          driver_state: SurfBoard.Transport.DriverState.t()
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

  `template.capabilities` (user-supplied) is left untouched.
  `template.driver_state` is treated as the driver's fixed, vendor-level
  defaults (e.g. Lightpanda's `needs_xpath_polyfill?`); `acquired.driver_state`
  is merged on top, winning on conflicts — this per-session acquisition
  step's own findings (target id, flat-session routing, …).

  Returns `{:ok, %SurfBoard.Session{}}` ready for callers to use.
  """
  @spec start_session_from(acquired, SurfBoard.Session.t(), keyword) ::
          {:ok, SurfBoard.Session.t()} | {:error, term}
  def start_session_from(%{ws_pid: ws_pid, teardown_fun: teardown} = acquired, template, opts) do
    caller = Keyword.get(opts, :owner, self())

    session_struct = %{
      template
      | ws_pid: ws_pid,
        browsing_context: acquired.session_id,
        driver_state: Map.merge(template.driver_state, acquired.driver_state)
    }

    config = %Actor.Config{
      socket: {:remote, WebSocket, ws_pid},
      load: :buffer,
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
