defmodule SurfBoard.Transport.Strategy.PerSession do
  @moduledoc false

  # Transport: ONE actor per session. The actor owns its own raw Mint
  # WebSocket directly — no separate WebSocket process, no
  # Session in front. Compared to the old PerSessionWS
  # (WebSocket + Session linked together) this halves the
  # per-cdp-call hop count.
  #
  # All inbound WS frames AND all outbound caller calls land in ONE
  # mailbox. Causal ordering between events and responses is preserved
  # without any barrier.
  #
  # Used by LightpandaCDP when a shared Lightpanda server is running: each
  # session opens its own WS to the same binary, runs Target.create-
  # Target + attachToTarget on that WS, and the resulting actor
  # handles everything for that session.

  @behaviour SurfBoard.Transport.Strategy

  alias SurfBoard.Clients.CDP.Client, as: CDPClient
  alias SurfBoard.Clients.CDP.Wire
  alias SurfBoard.Transport.Actor
  alias SurfBoard.{Launcher, Session}

  defmodule Config do
    @moduledoc false
    # `resolve_ws_url` — zero-arg function returning the shared
    # browser's WebSocket URL (Lightpanda accepts many WS to one
    # binary, so every session calls this fresh — nothing is cached).
    # Deferred rather than a literal `ws_url` because when the shared
    # binary is launched by the same construct that builds this Config
    # (see `Launcher.Lightpanda.start_link/1`), the URL isn't known
    # until the launched process reports it — resolving it eagerly at
    # Config-build time would mean blocking before the process has
    # even started.
    @enforce_keys [:resolve_ws_url]
    defstruct [:resolve_ws_url]
  end

  @doc """
  Bring up a new session.

  Required opts:
    * `:launcher` — a started `SurfBoard.Launcher` wrapping `%Config{resolve_ws_url: ...}`
    * `:session_struct` — `%SurfBoard.Session{}` to back the session
      with (driver fills in id/url/capabilities/etc.)

  Optional:
    * `:owner`        — process to monitor; defaults to `self()`
    * `:teardown_fun` — 1-arity called from `terminate/2` after the
      session ends. Defaults to a no-op.
  """
  @impl true
  @spec start_session(keyword) :: {:ok, Session.t()} | {:error, term}
  def start_session(opts) do
    launcher = Keyword.fetch!(opts, :launcher)
    %Config{resolve_ws_url: resolve_ws_url} = Launcher.info(launcher).config
    ws_url = resolve_ws_url.()
    session_struct = Keyword.fetch!(opts, :session_struct)
    teardown_fun = Keyword.get(opts, :teardown_fun, fn _ -> :ok end)
    owner = Keyword.get(opts, :owner, self())

    actor_config = %Actor.Config{
      socket: {:fused, ws_url},
      load: :buffer,
      wire: Wire
    }

    with {:ok, session} <-
           Actor.start_link(
             config: actor_config,
             init_fun: fn -> {:ok, session_struct} end,
             teardown_fun: teardown_fun,
             owner: owner
           ),
         # Open a CDP target on this brand-new WS. attachToTarget
         # produces the flat sessionId we'll use for routing.
         {:ok, %{"targetId" => target_id}} <-
           CDPClient.cdp_send(session, "Target.createTarget", %{url: "about:blank"}),
         {:ok, %{"sessionId" => session_id}} <-
           CDPClient.cdp_send(session, "Target.attachToTarget", %{
             targetId: target_id,
             flatten: true
           }) do
      # Update the session struct so subsequent CDP calls carry the
      # right flat_session_id + target_id.
      session = update_session_for_target(session, session_id, target_id)

      :ok = CDPClient.enable_page_lifecycle_events(session)
      :ok = CDPClient.install_bootstrap(session)
      :ok = CDPClient.enable_frame_tracking(session)

      {:ok, session}
    end
  end

  defp update_session_for_target(%Session{} = session, session_id, target_id) do
    GenServer.call(session.pid, {:update_browsing_context, session_id, target_id})

    %{
      session
      | browsing_context: session_id,
        capabilities: Map.put(session.capabilities, :target_id, target_id)
    }
  end
end
