defmodule SurfBoard.Drivers.LightpandaCDP do
  @moduledoc false

  # Lightpanda driver speaking CDP over the surf_board transport stack.
  # Only owns lifecycle (start/end_session, the Supervisor surface) and
  # its @driver_spec. Every capability is dispatched by Browser.ex/
  # Element.ex calling session.driver_spec's dimension modules directly.
  #
  # `Launcher.Lightpanda` — not this module — owns everything about
  # actually building a working Lightpanda session (the session
  # template, UA-unsupported warning, window size) and building the
  # launcher itself (spawn+own a shared local Lightpanda, or connect to
  # a caller-given `:ws_url`). This driver is built *on top of*
  # `Launcher.Lightpanda` for two of its three `:connection` modes; the
  # third (`:isolated`) has no dedicated `Launcher.Lightpanda`
  # constructor — see that module's moduledoc for why — so it still
  # builds a raw `Launcher` wrapping `Strategy.IsolatedProcess.Config`
  # directly, same as before.

  use Supervisor

  @behaviour SurfBoard.Driver

  alias SurfBoard.Launcher
  alias SurfBoard.Browser
  alias SurfBoard.Clients.CDP.Client, as: CDPClient
  alias SurfBoard.Dialogs
  alias SurfBoard.DriverSpec, as: Spec
  alias SurfBoard.Frames
  alias SurfBoard.Launcher.Lightpanda, as: LauncherLightpanda
  alias SurfBoard.Permissions
  alias SurfBoard.SendKeysSession
  alias SurfBoard.Transport.Strategy.IsolatedProcess
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

  @doc false
  def driver_spec, do: @driver_spec

  # ----- Driver supervisor -----
  #
  # Starts a single shared Lightpanda binary if the package is on the
  # load path (via `Launcher.Lightpanda.start_link/1`). Sessions
  # multiplex over this binary by opening their own WebSocket against
  # its URL (Transport.Strategy.PerSession). Falls back to per-session
  # binary spawn (Transport.Strategy.IsolatedProcess) if no shared
  # server is running.

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
  @default_launcher_name __MODULE__.DefaultLauncher

  @impl Supervisor
  def init(_) do
    children =
      if Code.ensure_loaded?(@lightpanda_server) do
        [{LauncherLightpanda, name: @default_launcher_name}]
      else
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  def validate do
    if Code.ensure_loaded?(@lightpanda_server) do
      LauncherLightpanda.validate()
    else
      :ok
    end
  end

  @doc false
  def cleanup_stale_sessions, do: :ok

  # ----- Session lifecycle -----

  # `:connection` picks which of the three ways a session gets its
  # Lightpanda transport — the (launch, socket, process-model)
  # combination underneath this one (protocol, vendor) driver:
  #
  #   * `:shared`   — reuse the already-running shared Lightpanda
  #                   binary (this driver's Supervisor started it once,
  #                   at boot, iff the `lightpanda` package is loaded,
  #                   via `Launcher.Lightpanda.start_link/1`). Fresh WS
  #                   per session, fused actor (no extra hop). Fails
  #                   with `{:error, :shared_server_not_running}` if
  #                   explicitly requested but nothing is up.
  #   * `:isolated` — spawn a brand-new private Lightpanda binary for
  #                   just this session. Slower (pays binary startup
  #                   every call) but fully isolated. Requires the
  #                   `lightpanda` package; fails with
  #                   `{:error, :lightpanda_package_not_loaded}` if it
  #                   isn't on the load path.
  #   * `:external` — connect to a Lightpanda instance this driver
  #                   never launches at all, via a caller-supplied
  #                   `:ws_url` (`Launcher.Lightpanda.connect/1`).
  #                   Requires `:ws_url` in opts; fails with
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

      Process.whereis(@default_launcher_name) ->
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
    case Process.whereis(@default_launcher_name) do
      nil -> {:error, :shared_server_not_running}
      _pid -> {:ok, &Launcher.start_session(@default_launcher_name, &1)}
    end
  end

  defp isolated_connection(_opts) do
    if Code.ensure_loaded?(@lightpanda_server) do
      config = %IsolatedProcess.Config{
        spawn_fun: fn ->
          # credo:disable-for-next-line Credo.Check.Refactor.Apply
          apply(@lightpanda_server, :start_link, [
            [name: nil, wrapper_script: LauncherLightpanda.wrapper_script()]
          ])
        end,
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        url_fun: fn server -> apply(@lightpanda_server, :ws_url, [server]) end
      }

      {:ok, &start_via_isolated(&1, config)}
    else
      {:error, :lightpanda_package_not_loaded}
    end
  end

  defp external_connection(opts) do
    case Keyword.get(opts, :ws_url) do
      url when is_binary(url) ->
        {:ok,
         fn opts ->
           {:ok, launcher} = LauncherLightpanda.connect(url: url)
           result = Launcher.start_session(launcher, opts)
           Agent.stop(launcher)
           result
         end}

      _ ->
        {:error, :ws_url_required}
    end
  end

  # `:isolated` has no dedicated `Launcher.Lightpanda` constructor (see
  # its moduledoc) — build the raw `Launcher` wrapping
  # `IsolatedProcess.Config` directly, same shape `Launcher.Lightpanda`
  # itself would use internally, with the same build_template/post_start
  # defaults so a caller holding this launcher (via opts[:launcher] on a
  # future call) gets the same standalone `Launcher.start_session/2`
  # capability. Nothing is lost by not keeping the launcher around past
  # this one session's start — IsolatedProcess caches no connection
  # state on it.
  defp start_via_isolated(opts, config) do
    {:ok, launcher} =
      Launcher.start_link(
        strategy: IsolatedProcess,
        config: config,
        build_template: &LauncherLightpanda.build_template/1,
        post_start: &LauncherLightpanda.post_start/2
      )

    result = Launcher.start_session(launcher, opts)
    Agent.stop(launcher)
    result
  end
end
