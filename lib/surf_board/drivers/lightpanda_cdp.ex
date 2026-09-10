defmodule SurfBoard.Drivers.LightpandaCDP do
  @moduledoc false

  # Lightpanda driver speaking CDP over the surf_board transport stack.
  # Only owns lifecycle (start/end_session, the Supervisor surface) and
  # its @driver_spec. Every capability is dispatched by Browser.ex/
  # Element.ex calling session.driver_spec's dimension modules directly.

  use Supervisor

  @behaviour SurfBoard.Driver

  alias SurfBoard.{Metadata, Session, UserAgent}
  alias SurfBoard.Browser
  alias SurfBoard.Clients.CDP.Client, as: CDPClient
  alias SurfBoard.Dialogs
  alias SurfBoard.DriverSpec, as: Spec
  alias SurfBoard.Frames
  alias SurfBoard.Permissions
  alias SurfBoard.SendKeysSession
  alias SurfBoard.Transport
  alias SurfBoard.Transport.Protocol
  alias SurfBoard.Windows

  @driver_spec %Spec{
    browser: Browser.Lightpanda,
    wire_protocol: CDPClient,
    dialogs: Dialogs.Unsupported,
    windows: Windows.Single,
    frames: Frames.Unsupported,
    grant_permissions: Permissions.Unsupported,
    send_keys_session: SendKeysSession.Unsupported,
    touch_scroll: nil,
    log_check_interactions?: false
  }

  # Lightpanda reports `Lightpanda/1.0` and, as of the official 0.3.6
  # binary, ignores `Network.setUserAgentOverride` — the call returns
  # `{:ok, %{}}` but the UA on the wire is unchanged. The override is still
  # issued for the BEAM sandbox metadata (harmless if dropped, and it works
  # on the older fork builds); a caller-supplied `:user_agent` warns rather
  # than silently doing nothing. See `warn_user_agent_unsupported/0`.
  @base_user_agent "Lightpanda/1.0"

  @doc false
  def driver_spec, do: @driver_spec

  # ----- Driver supervisor -----
  #
  # Starts a single shared Lightpanda binary if the package is on the
  # load path. Sessions multiplex over this binary by opening their
  # own WebSocket against its URL (Transport.Strategy.PerSession). Falls
  # back to per-session binary spawn (Transport.Strategy.IsolatedProcess)
  # if no shared server is running.

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, :ok, opts)
  end

  @lightpanda_server Module.concat([Lightpanda, Server])
  @lightpanda_server_name __MODULE__.LightpandaServer

  # Lightpanda's --cdp-max-connections defaults to 16, which gets hit
  # at mc=16 plus a few session-isolation tests creating extra sessions.
  @cdp_max_connections 24

  @impl Supervisor
  def init(_) do
    resolve_binary_path()

    children =
      if Code.ensure_loaded?(@lightpanda_server) do
        opts = [
          name: @lightpanda_server_name,
          extra_args:
            [
              "--cdp-max-connections",
              Integer.to_string(@cdp_max_connections)
            ] ++ user_agent_args(),
          wrapper_script: wrapper_script()
        ]

        [{@lightpanda_server, opts}]
      else
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  # `config :surf_board, user_agent: "..."` is the cross-driver setting; it
  # arrives here as a `--user-agent` flag because Lightpanda's UA is a
  # property of the *process*, not of a CDP session — every session on the
  # shared binary shares it. (The Chrome drivers read the same config key
  # per session.)
  #
  # `:lightpanda_user_agent_suffix` has no Chrome equivalent, so it stays
  # driver-specific: it appends to `Lightpanda/X.Y` rather than replacing
  # it, which keeps the browser identifiable while naming your crawler.
  # Lightpanda documents `--user-agent` as refusing to impersonate other
  # browsers (values containing "Mozilla"), though 0.3.6 doesn't enforce it.
  defp user_agent_args do
    ua = UserAgent.configured()
    suffix = Application.get_env(:surf_board, :lightpanda_user_agent_suffix)

    cond do
      ua && suffix ->
        raise ArgumentError, """
        :user_agent and :lightpanda_user_agent_suffix are mutually exclusive \
        — Lightpanda rejects --user-agent together with --user-agent-suffix. \
        Set one or the other.
        """

      ua ->
        ["--user-agent", ua]

      suffix ->
        ["--user-agent-suffix", suffix]

      true ->
        []
    end
  end

  # Make `SurfBoard.BrowserPaths` authoritative for Lightpanda's binary
  # location, mirroring how the Chrome drivers resolve through it. We
  # translate the resolved path into `config :lightpanda, :path`, which
  # `Lightpanda.bin_path/0` honors at the top of its precedence.
  #
  # An explicitly-configured `:path` (the dev sibling checkout) wins —
  # we never overwrite it. When BrowserPaths resolves nothing (no env
  # override, no `LIGHTPANDA=` line), we leave config untouched so the
  # package's own resolution (`:install_dir` → `.browsers/`, else
  # `_build/`) applies.
  defp resolve_binary_path do
    if is_nil(Application.get_env(:lightpanda, :path)) do
      case SurfBoard.BrowserPaths.lightpanda_path() do
        {:ok, path} -> Application.put_env(:lightpanda, :path, path)
        :error -> :ok
      end
    end
  end

  @doc false
  def validate, do: :ok

  @doc false
  def cleanup_stale_sessions, do: :ok

  # ----- Session lifecycle -----

  # `:connection` picks which of the three ways a session gets its
  # Lightpanda transport — the (launch, socket, process-model)
  # combination underneath this one (protocol, vendor) driver:
  #
  #   * `:shared`   — reuse the already-running shared Lightpanda
  #                   binary (this driver's Supervisor started it once,
  #                   at boot, iff the `lightpanda` package is loaded).
  #                   Fresh WS per session, fused actor (no extra hop).
  #                   Fails with `{:error, :shared_server_not_running}`
  #                   if explicitly requested but nothing is up.
  #   * `:isolated` — spawn a brand-new private Lightpanda binary for
  #                   just this session. Slower (pays binary startup
  #                   every call) but fully isolated. Requires the
  #                   `lightpanda` package; fails with
  #                   `{:error, :lightpanda_package_not_loaded}` if it
  #                   isn't on the load path.
  #   * `:external` — connect to a Lightpanda instance this driver
  #                   never launches at all, via a caller-supplied
  #                   `:ws_url`. Requires `:ws_url` in opts; fails with
  #                   `{:error, :ws_url_required}` otherwise.
  #
  # Omitted (the default): auto-detect, in priority order — an
  # explicit `:ws_url` wins (implies `:external`); else reuse the
  # shared server if one is running (`:shared`); else spawn a private
  # one if the package is available (`:isolated`); else raise, since
  # there is no way to get a Lightpanda connection at all.
  @impl SurfBoard.Driver
  def start_session(opts \\ []) do
    case resolve_connection(opts) do
      {:ok, fun} -> fun.(opts)
      {:error, _reason} = err -> err
    end
  end

  defp resolve_connection(opts) do
    case Keyword.get(opts, :connection) do
      nil -> {:ok, auto_detect_connection(opts)}
      :shared -> shared_connection(opts)
      :isolated -> isolated_connection(opts)
      :external -> external_connection(opts)
    end
  end

  defp auto_detect_connection(opts) do
    cond do
      Keyword.has_key?(opts, :ws_url) ->
        {:ok, fun} = external_connection(opts)
        fun

      Process.whereis(@lightpanda_server_name) ->
        {:ok, fun} = shared_connection(opts)
        fun

      Code.ensure_loaded?(@lightpanda_server) ->
        {:ok, fun} = isolated_connection(opts)
        fun

      true ->
        raise "V2Driver requires either a :ws_url opt or the `lightpanda` package on the path"
    end
  end

  defp shared_connection(_opts) do
    case Process.whereis(@lightpanda_server_name) do
      nil ->
        {:error, :shared_server_not_running}

      _pid ->
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        ws_url = apply(@lightpanda_server, :ws_url, [@lightpanda_server_name])
        {:ok, &start_per_session(&1, ws_url)}
    end
  end

  defp isolated_connection(_opts) do
    if Code.ensure_loaded?(@lightpanda_server) do
      base_caps = %{needs_xpath_polyfill: true}

      transport_opts = [
        spawn_fun: fn ->
          # credo:disable-for-next-line Credo.Check.Refactor.Apply
          apply(@lightpanda_server, :start_link, [[name: nil, wrapper_script: wrapper_script()]])
        end,
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        url_fun: fn server -> apply(@lightpanda_server, :ws_url, [server]) end,
        extra_capabilities: base_caps
      ]

      {:ok, &start_via_acquire(&1, Transport.Strategy.IsolatedProcess, transport_opts)}
    else
      {:error, :lightpanda_package_not_loaded}
    end
  end

  defp external_connection(opts) do
    case Keyword.get(opts, :ws_url) do
      url when is_binary(url) ->
        base_caps = %{needs_xpath_polyfill: true}
        transport_opts = [ws_url: url, extra_capabilities: base_caps]
        {:ok, &start_via_acquire(&1, Transport.Strategy.IsolatedProcess, transport_opts)}

      _ ->
        {:error, :ws_url_required}
    end
  end

  defp start_per_session(opts, ws_url) do
    session_struct = %Session{
      id: "v2drv-#{System.unique_integer([:positive])}",
      url: "about:blank",
      session_url: "about:blank",
      driver: __MODULE__,
      driver_spec: @driver_spec,
      live_view_aware?: Keyword.get(opts, :live_view_aware, false),
      browsing_context: nil,
      capabilities: %{
        flat_session_id: true,
        # Lightpanda's JS engine doesn't ship a real document.evaluate
        # — CDPClient.visit injects wgxpath after each page load.
        needs_xpath_polyfill: true
      }
    }

    with {:ok, session} <-
           Transport.Strategy.PerSession.start_session(
             ws_url: ws_url,
             session_struct: session_struct,
             owner: Keyword.get(opts, :owner, self())
           ) do
      apply_session_opts(session, opts)
      {:ok, session}
    end
  end

  defp start_via_acquire(opts, transport_mod, transport_opts) do
    with {:ok, acquired} <- transport_mod.acquire(transport_opts) do
      session_struct = %Session{
        id: "v2drv-#{System.unique_integer([:positive])}",
        url: "about:blank",
        session_url: "about:blank",
        driver: __MODULE__,
        driver_spec: @driver_spec,
        live_view_aware?: Keyword.get(opts, :live_view_aware, false),
        bidi_pid: acquired.ws_pid,
        browsing_context: acquired.session_id,
        capabilities: acquired.capabilities
      }

      with {:ok, session} <- Transport.start_session_from(acquired, session_struct, opts) do
        apply_session_opts(session, opts)
        {:ok, session}
      end
    end
  end

  # Apply post-start session options shared by both transports: the BEAM
  # sandbox metadata user-agent, and the optional window size.
  #
  # A caller-supplied `:user_agent` can't be honoured per session here —
  # Lightpanda's UA is set on the process (see `user_agent_args/0`) — so it
  # warns rather than appearing to work. `config :surf_board, user_agent:`
  # is already applied as a CLI flag by then, so it isn't re-sent.
  defp apply_session_opts(session, opts) do
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

    :ok
  end

  # Lightpanda accepts `Network.setUserAgentOverride` and returns
  # `{:ok, %{}}`, but the UA it actually sends is unchanged — so a caller
  # passing `:user_agent` would otherwise be silently ignored. Its UA is a
  # process-level setting instead (see `user_agent_args/0`). Warn once per
  # VM rather than per session, so a crawl doesn't flood the log.
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

          SurfBoard.start_session(driver: :chrome_cdp, user_agent: "...")
      """)
    end

    :ok
  end

  @impl SurfBoard.Driver
  def end_session(%Session{} = session) do
    Protocol.stop(session)
    :ok
  end

  # ----- Helpers -----

  defp wrapper_script do
    Path.absname("priv/run_command.sh", Application.app_dir(:surf_board))
  end
end
