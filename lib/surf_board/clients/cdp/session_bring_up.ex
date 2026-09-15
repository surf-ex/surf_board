defmodule SurfBoard.Clients.CDP.SessionBringUp do
  @moduledoc false

  # Shared second half of CDP session bring-up — genuinely reused by
  # both ChromeCDP's SharedWS-backed connection and Lightpanda's
  # IsolatedProcess-backed connection, not a per-driver copy: both
  # call start_session_from/3 once their own connection-acquisition
  # step (spawning/finding a target, attaching, getting a sessionId)
  # has produced an `acquired` map.
  #
  # NOT a generic "any protocol" bring-up module — every step here
  # (folding the acquired connection into a session template, the
  # bootstrap/page-lifecycle/frame-tracking init sequence) is CDP-
  # specific. BiDi does its own bring-up entirely inline, because its
  # bring-up genuinely doesn't share this shape.

  alias SurfBoard.Transport.Actor
  alias SurfBoard.Clients.CDP.Wire

  @typedoc """
  What a connection-acquisition step returns internally, before being
  folded into the caller's `:session_struct` template by
  `start_session_from/3`.

    * `:ws_pid`       — the WebSocket the session sends through
    * `:target_id`    — Chrome target id (CDP) for window-handle
                        bookkeeping; nil if N/A
    * `:session_id`   — the CDP flat-session sessionId (routing key);
                        nil if the transport doesn't multiplex
    * `:browser_context_id` — for a shared connection only; teardown
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

  @doc """
  Folds an `acquired` map (from a driver's own connection-acquisition
  step) into the caller's `:session_struct` template, brings up the
  actor, and runs the standard CDP init sequence (page lifecycle,
  bootstrap, frame tracking).

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
      socket: {:remote, SurfBoard.Transport.WebSocket, ws_pid},
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
