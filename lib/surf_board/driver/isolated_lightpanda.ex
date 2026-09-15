defmodule SurfBoard.Driver.IsolatedLightpanda do
  @moduledoc false

  # Lightpanda over CDP, spawning a brand-new private Lightpanda binary
  # for every session. The slowest model — every session pays a
  # binary-startup cost — but cleanest isolation: each session gets a
  # private browser, no contention with peers. Uses
  # `SurfBoard.Clients.CDP.SessionBringUp` — the one piece of CDP
  # session bring-up genuinely shared with `Driver.SharedChromeCDP`'s
  # own connection logic.
  #
  # Fully self-contained otherwise — no shared module with
  # `Driver.SharedLightpanda`/`Driver.ExternalLightpanda` beyond that
  # and `SurfBoard.Clients.CDP.Client`. Spawning a fresh private binary
  # per session is a different enough job (owns a process, kills it on
  # teardown) that it's a fully separate driver, not a branch inside
  # one Lightpanda module.
  #
  #   {:ok, session} = Driver.IsolatedLightpanda.start_session([])

  alias SurfBoard.DependencyError
  alias SurfBoard.Clients.CDP.Client, as: CDPClient
  alias SurfBoard.Clients.CDP.SessionBringUp
  alias SurfBoard.Clients.Dialogs
  alias SurfBoard.Driver.Spec
  alias SurfBoard.Clients.Frames
  alias SurfBoard.Launcher.Metadata
  alias SurfBoard.Transport.WebSocket
  alias SurfBoard.Clients.Windows

  @base_user_agent "Lightpanda/1.0"

  @lightpanda_server Module.concat([Lightpanda, Server])

  # Lightpanda's engine doesn't support any of CDP's optional
  # capabilities reliably enough to trust — overrides every one of
  # CDPClient.default_strategies/0's picks. Computed at runtime, not in
  # a module attribute — see Driver.SharedChromeCDP.spec/0's comment
  # for why.
  def spec do
    struct!(
      Spec,
      Map.merge(CDPClient.default_strategies(), %{
        wire_protocol: CDPClient,
        dialogs: Dialogs.Unsupported,
        windows: Windows.Single,
        frames: Frames.Unsupported,
        grant_permissions: nil,
        send_keys_session: nil,
        touch_scroll: nil,
        log_check_interactions?: false,
        native_click_await?: true
      })
    )
  end

  # No default_child_spec/0 — there's nothing to start ahead of time;
  # every session spawns and owns its own private binary, so there's
  # no persistent instance for a supervisor to hold.

  @doc """
  Checks whether this driver can actually work — the `lightpanda`
  package is loaded — without starting anything. Returns
  `:ok | {:error, %SurfBoard.DependencyError{}}`.
  """
  @spec validate() :: :ok | {:error, DependencyError.t()}
  def validate do
    if Code.ensure_loaded?(@lightpanda_server) do
      :ok
    else
      {:error,
       DependencyError.exception(
         "Lightpanda not found. Add the `lightpanda` package as a dependency."
       )}
    end
  end

  # ----- Session lifecycle -----

  @doc """
  Spawns a fresh, private Lightpanda binary and starts a session
  against it. Fails with `{:error, :lightpanda_package_not_loaded}` if
  the `lightpanda` package isn't on the load path.
  """
  @spec start_session(keyword) :: {:ok, SurfBoard.Session.t()} | {:error, term}
  def start_session(opts \\ []) do
    if Code.ensure_loaded?(@lightpanda_server) do
      start_link_args = [[name: nil, wrapper_script: wrapper_script()]]
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      {:ok, server_pid} = apply(@lightpanda_server, :start_link, start_link_args)

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      ws_url = apply(@lightpanda_server, :ws_url, [server_pid])
      start_session_isolated(ws_url, server_pid, opts)
    else
      {:error, :lightpanda_package_not_loaded}
    end
  end

  defp wrapper_script do
    Path.absname("priv/run_command.sh", Application.app_dir(:surf_board))
  end

  # A fresh browser process AND a fresh WebSocket per session.
  # Inlined from the old `Strategy.IsolatedProcess`, using
  # `SessionBringUp` for the shared second half (also used by
  # `Driver.SharedChromeCDP`).
  defp start_session_isolated(ws_url, server_pid, opts) do
    template = build_template(opts)

    with {:ok, ws_pid} <- WebSocket.start_link(ws_url),
         {:ok, %{"targetId" => target_id}} <-
           WebSocket.send_sync(ws_pid, "Target.createTarget", %{url: "about:blank"}),
         {:ok, session_id} <- CDPClient.attach_to_target(ws_pid, target_id) do
      # Note: unlike Chrome, this is Lightpanda-only, whose partial CDP
      # implementation may not support Target.setDiscoverTargets — not
      # sent here, so Target.detachedFromTarget won't fire for
      # Lightpanda sessions.
      teardown = fn _session ->
        CDPClient.close_ws(ws_pid)
        stop_server(server_pid)
        :ok
      end

      acquired = %{
        ws_pid: ws_pid,
        target_id: target_id,
        session_id: session_id,
        browser_context_id: nil,
        teardown_fun: teardown,
        driver_state: %SurfBoard.Transport.DriverState{
          target_id: target_id,
          flat_session_id?: true,
          server_pid: server_pid
        }
      }

      with {:ok, session} <- SessionBringUp.start_session_from(acquired, template, opts) do
        post_start(session, opts)
      end
    else
      err ->
        # Failed mid-bring-up: kill the spawned binary so we don't leak
        # a Lightpanda process per failed session.
        stop_server(server_pid)
        err
    end
  end

  defp stop_server(pid) do
    try do
      GenServer.stop(pid, :normal, 5_000)
    catch
      _, _ -> :ok
    end

    :ok
  end

  defp build_template(opts) do
    %SurfBoard.Session{
      id: "lightpanda-#{System.unique_integer([:positive])}",
      url: "about:blank",
      session_url: "about:blank",
      spec_module: __MODULE__,
      spec: spec(),
      live_view_aware?: Keyword.get(opts, :live_view_aware, false),
      driver_state: %SurfBoard.Transport.DriverState{
        flat_session_id?: true,
        # Lightpanda's JS engine doesn't ship a real document.evaluate
        # — CDPClient.visit injects wgxpath after each page load.
        needs_xpath_polyfill?: true
      }
    }
  end

  defp post_start(session, opts) do
    metadata = Keyword.get(opts, :metadata)

    if Keyword.has_key?(opts, :user_agent), do: warn_user_agent_unsupported()

    if metadata do
      _ =
        CDPClient.cdp_send(session, "Network.setUserAgentOverride", %{
          userAgent: Metadata.append(@base_user_agent, metadata)
        })
    end

    if window_size = Keyword.get(opts, :window_size) do
      _ = CDPClient.set_window_size(session, window_size[:width], window_size[:height])
    end

    # `:base_url`/`:max_wait_time` govern later calls rather than
    # session startup, so they ride on the session — that way an
    # application's own session isn't governed by whatever a test
    # suite configured globally.
    session_opts = Keyword.take(opts, [:base_url, :max_wait_time])
    {:ok, %{session | session_opts: session_opts}}
  end

  # Lightpanda accepts `Network.setUserAgentOverride` and returns
  # `{:ok, %{}}`, but the UA it actually sends is unchanged — so a caller
  # passing `:user_agent` would otherwise be silently ignored. Its UA is a
  # process-level setting instead. Warn once per VM rather than per
  # session, so a crawl doesn't flood the log.
  @warned_ua_key {__MODULE__, :warned_user_agent_unsupported}

  defp warn_user_agent_unsupported do
    unless :persistent_term.get(@warned_ua_key, false) do
      :persistent_term.put(@warned_ua_key, true)

      require Logger

      Logger.warning("""
      [surf_board] the :user_agent session option has no effect on the \
      Lightpanda driver — it ignores Network.setUserAgentOverride and will \
      keep reporting #{@base_user_agent}.

      Lightpanda sets its User-Agent per process, not per session, so set it \
      for the whole browser instead — this works on every driver:

          config :surf_board, user_agent: "MyScraper/1.0 (+https://…)"

          # or append to Lightpanda/X.Y rather than replacing it:
          config :surf_board, lightpanda_user_agent_suffix: "MyScraper/1.0"

      A per-session User-Agent (two different UAs at once) needs Chrome:

          SurfBoard.Driver.SharedChromeCDP.start_session(user_agent: "...")
      """)
    end

    :ok
  end
end
