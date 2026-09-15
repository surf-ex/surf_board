defmodule SurfBoard.Driver.ChromeBiDi do
  @moduledoc false

  # Chrome over WebDriver-BiDi, against a chromium-bidi Node sidecar:
  # one POST /session -> one WS -> one Chrome. No cached connection
  # state (unlike ChromeCDP's shared ws_pid) — each session does its
  # own `POST /session`, so there's no "own a persistent process, many
  # sessions reuse it" shape to give a `start_link/1` for, and no
  # worker needed beyond the sidecar itself. `start_session/2` is
  # inlined directly from the old `Strategy.BiDi` (genuinely only ever
  # used by this driver, unlike the CDP bring-up shared with
  # Lightpanda — see `SurfBoard.Clients.CDP.SessionBringUp`).
  #
  #   {:ok, session} = Driver.ChromeBiDi.start_session(base_url: "http://localhost:12345")
  #
  # `Supervised` owns the chromium-bidi Node sidecar (`BiDi.Server`) —
  # this driver's default instance, started once, lazily, under
  # whichever supervisor the application chooses (see
  # `default_child_spec/0`). The sidecar just needs somewhere to live
  # so it survives across sessions instead of respawning per call.

  alias SurfBoard.Launcher.Metadata
  alias SurfBoard.Launcher.UserAgent
  alias SurfBoard.Clients.BiDi.Client, as: BiDiClient
  alias SurfBoard.Driver.BiDi.Server, as: BidiServer
  alias SurfBoard.Driver.Spec
  alias SurfBoard.Transport.Strategy.BiDi.Handshake
  alias SurfBoard.Transport.Actor
  alias SurfBoard.Transport.Protocol
  alias SurfBoard.Clients.BiDi.Wire
  alias SurfBoard.Transport.WebSocketClient

  @base_user_agent "Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 " <>
                     "(KHTML, like Gecko) Chrome/41.0.2228.0 Safari/537.36"

  # Full support for everything BiDi offers here — no overrides needed
  # on top of BiDiClient.default_strategies/0 (which already has
  # grant_permissions: nil — no real BiDi permissions implementation
  # exists yet). Computed at runtime, not in a module attribute — see
  # Driver.ChromeCDP.spec/0's comment for why.
  def spec do
    struct!(
      Spec,
      Map.merge(BiDiClient.default_strategies(), %{
        wire_protocol: BiDiClient,
        touch_scroll: &__MODULE__.touch_scroll_impl/3,
        log_check_interactions?: true
      })
    )
  end

  defmodule Supervised do
    @moduledoc false
    # Owns the chromium-bidi Node sidecar (`BiDi.Server`) as its one
    # child — no worker child here: session start caches nothing (see
    # the moduledoc), so there's nothing for a second child to hold.
    use Supervisor

    alias SurfBoard.Driver.ChromeBiDi

    def start_link({name, _opts} = arg) do
      Supervisor.start_link(__MODULE__, arg, name: ChromeBiDi.supervisor_name(name))
    end

    @impl Supervisor
    def init({name, _opts}) do
      Supervisor.init(
        [{BidiServer, [name: ChromeBiDi.bidi_server_name(name)]}],
        strategy: :one_for_one
      )
    end
  end

  @doc false
  def supervisor_name(name), do: Module.concat(name, Supervisor)
  @doc false
  def bidi_server_name(name), do: Module.concat(name, BidiServer)
  @doc false
  def default_name, do: __MODULE__.Default

  @doc """
  A child spec for this driver's default instance (the chromium-bidi
  sidecar), meant to be started once, under whatever supervisor the
  application chooses.
  """
  def default_child_spec do
    name = default_name()

    %{
      id: name,
      start: {Supervised, :start_link, [{name, []}]},
      type: :supervisor
    }
  end

  @doc """
  Checks whether this driver can actually work — Chrome is installed
  (the sidecar drives a real Chrome under the hood). Returns
  `:ok | {:error, %SurfBoard.DependencyError{}}`.
  """
  @spec validate() :: :ok | {:error, SurfBoard.DependencyError.t()}
  def validate do
    if match?({:ok, _}, SurfBoard.Launcher.BrowserPaths.chrome_path()) do
      :ok
    else
      {:error,
       SurfBoard.DependencyError.exception(
         "Chrome not found. Run `mix surf_board.install` or set SURF_BOARD_CHROME_URL."
       )}
    end
  end

  @doc """
  Default capabilities passed when starting a Chrome session via BiDi.
  """
  def default_capabilities do
    %{
      browserName: "chrome",
      unhandledPromptBehavior: "ignore"
    }
  end

  # ----- Session lifecycle -----

  @doc """
  Starts a new BiDi session. `:base_url` (the chromium-bidi server's
  HTTP base URL) is resolved via `resolve_base_url/1` if not given
  directly — a caller-supplied one wins; otherwise this driver's own
  default sidecar (must already be started — see
  `default_child_spec/0`).
  """
  @spec start_session(keyword) :: {:ok, SurfBoard.Session.t()} | {:error, term}
  def start_session(opts \\ []) do
    base_url = resolve_base_url(opts)
    caps = Keyword.get(opts, :capabilities)
    handshake_opts = if caps, do: [capabilities: caps], else: []
    template = build_template(opts)
    teardown_fun = Keyword.get(opts, :teardown_fun, fn _ -> :ok end)
    owner = Keyword.get(opts, :owner, self())

    # chromium-bidi's session.subscribe can transiently time out on
    # slow runners. Retry the WHOLE handshake -> Actor.start_link ->
    # initial-context block on `{:error, {:subscribe_failed, _}}` so
    # tests aren't held responsible for protocol-level flakes.
    with {:ok, session} <-
           start_with_retry(base_url, handshake_opts, template, teardown_fun, owner, 4) do
      post_start(session, opts)
    end
  end

  @doc """
  Resolves the `base_url` a session should connect to: a caller-given
  one wins; otherwise the sidecar's own WS URL (`:launcher_name`,
  defaulting to the default instance), converted to its HTTP
  equivalent (they share host/port; chromium-bidi serves both).
  """
  @spec resolve_base_url(keyword) :: String.t()
  def resolve_base_url(opts) do
    case Keyword.get(opts, :base_url) do
      url when is_binary(url) ->
        url

      _ ->
        name = Keyword.get(opts, :launcher_name, default_name())
        ws_url = bidi_ws_url_with_retry(name, 5)

        ws_url
        |> URI.parse()
        |> Map.put(:scheme, "http")
        |> Map.put(:path, nil)
        |> URI.to_string()
    end
  end

  # The supervised BidiServer process can crash mid-suite (chromium-bidi
  # Node process exits non-zero; OOM on CI runners is the most common
  # cause). The one_for_one Supervisor restarts it, but there's a short
  # window where GenServer.call(bidi_server_name(name), _) exits with
  # :noproc before the new pid registers under the name. Retry with a
  # small backoff to ride out the gap.
  defp bidi_ws_url_with_retry(name, 0) do
    BidiServer.ws_url(bidi_server_name(name))
  end

  defp bidi_ws_url_with_retry(name, retries_left) do
    BidiServer.ws_url(bidi_server_name(name))
  catch
    :exit, _ ->
      Process.sleep(500)
      bidi_ws_url_with_retry(name, retries_left - 1)
  end

  defp start_with_retry(base_url, handshake_opts, session_struct, teardown_fun, owner, retries) do
    with {:ok, ws_url} <- Handshake.post_session(base_url, handshake_opts),
         {:ok, socket_pid} <- WebSocketClient.start_link(ws_url),
         {:ok, session} <- start_actor(socket_pid, session_struct, teardown_fun, owner),
         :ok <- subscribe_load_events(socket_pid, session.pid),
         {:ok, context_id} <- find_or_create_initial_context(session),
         :ok <- install_bootstrap(session) do
      session = %{session | browsing_context: context_id, ws_pid: socket_pid}

      # Mirror the actor's session-struct view so subsequent reads via
      # :get_session also see the populated browsing_context — ctx/1
      # depends on this being correct.
      :ok = GenServer.call(session.pid, {:update_browsing_context, context_id, nil})

      {:ok, session}
    else
      {:error, {:subscribe_failed, _}} when retries > 0 ->
        Process.sleep(250)

        start_with_retry(
          base_url,
          handshake_opts,
          session_struct,
          teardown_fun,
          owner,
          retries - 1
        )

      {:error, {:timeout, {GenServer, :call, _}}} when retries > 0 ->
        Process.sleep(250)

        start_with_retry(
          base_url,
          handshake_opts,
          session_struct,
          teardown_fun,
          owner,
          retries - 1
        )

      other ->
        other
    end
  end

  defp start_actor(socket_pid, session_struct, teardown_fun, owner) do
    config = %Actor.Config{
      socket: {:remote, WebSocketClient, socket_pid},
      load: :wake_once,
      wire: Wire
    }

    case Actor.start_link(
           config: config,
           init_fun: fn -> {:ok, session_struct} end,
           teardown_fun: teardown_fun,
           owner: owner
         ) do
      {:ok, session} ->
        {:ok, session}

      {:error, reason} ->
        # The actor never came up to own socket_pid's lifecycle —
        # nothing else will close it, so do it here rather than leak
        # a WebSocketClient/chromium-bidi connection per failed retry.
        try do
          WebSocketClient.close(socket_pid)
        catch
          :exit, _ -> :ok
        end

        {:error, reason}
    end
  end

  # Subscribe load milestones + bootstrap channel + log entries in a
  # single server-side session.subscribe call. WSC-side forward-to-
  # this-pid is set up for the events the actor needs to consume
  # (loads + script.message); log.entryAdded is forwarded to other
  # subscribers (e.g. the test process for LogChecker).
  defp subscribe_load_events(socket_pid, actor_pid) do
    events = [
      "browsingContext.load",
      "browsingContext.domContentLoaded",
      "script.message",
      "log.entryAdded",
      # Supplies the document's HTTP status for `Browser.status/1`.
      "network.responseCompleted",
      # Lets Wire.handle_event/3 fail every pending call immediately
      # if this session's context disappears, instead of each one
      # timing out on its own — see Clients.BiDi.Wire's moduledoc.
      "browsingContext.contextDestroyed"
    ]

    Enum.each(events, fn ev ->
      WebSocketClient.subscribe(socket_pid, ev, :global, actor_pid)
    end)

    # The first session.subscribe after browser launch can take a
    # while on slow runners (GHA Linux) because chromium-bidi's Mapper
    # is still settling. 12s lets us retry up to 4× (start_with_retry)
    # and still fit inside ExUnit's default 60s test timeout.
    # Subsequent subscribes are fast (<200ms) so the actual cap rarely
    # fires.
    timeout = Application.get_env(:surf_board, :bidi_subscribe_timeout_ms, 12_000)

    case WebSocketClient.send_command(
           socket_pid,
           "session.subscribe",
           %{"events" => events},
           timeout
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:subscribe_failed, reason}}
    end
  end

  # Chrome launches with a default about:blank tab. Reuse it instead
  # of creating a sibling — otherwise window_handles sees TWO tabs at
  # session start (the leftover plus our newly-created one), which
  # confuses tests that check tab counts.
  defp find_or_create_initial_context(session) do
    case Protocol.cdp_send(session, "browsingContext.getTree", %{}, []) do
      {:ok, %{"contexts" => [%{"context" => existing} | _]}} when is_binary(existing) ->
        {:ok, existing}

      _ ->
        case Protocol.cdp_send(session, "browsingContext.create", %{"type" => "tab"}, []) do
          {:ok, %{"context" => context_id}} -> {:ok, context_id}
          err -> err
        end
    end
  end

  # Install the shared SurfBoard.Clients.Bootstrap as a BiDi preload script.
  # The script receives `__surfboard` as a channel callback parameter;
  # any payload it sends comes back as a `script.message` event that
  # the SessionActor decodes into find / page_ready dispatches.
  defp install_bootstrap(session) do
    fn_decl = SurfBoard.Clients.Bootstrap.bidi_preload(session.live_view_aware?)
    channel_arg = [%{"type" => "channel", "value" => %{"channel" => "__surfboard"}}]

    case Protocol.cdp_send(
           session,
           "script.addPreloadScript",
           %{"functionDeclaration" => fn_decl, "arguments" => channel_arg},
           []
         ) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  defp build_template(opts) do
    %SurfBoard.Session{
      id: "bidi-#{System.unique_integer([:positive])}",
      url: "about:blank",
      session_url: "about:blank",
      spec_module: __MODULE__,
      spec: spec(),
      live_view_aware?: Keyword.get(opts, :live_view_aware, false),
      browsing_context: nil,
      capabilities: Keyword.get(opts, :capabilities, %{}) |> Map.new()
    }
  end

  defp post_start(session, opts) do
    caller = Keyword.get(opts, :owner, self())
    _ = WebSocketClient.subscribe(session.ws_pid, "log.entryAdded", :global, caller)

    if UserAgent.override?(opts) do
      ua =
        opts
        |> UserAgent.resolve(@base_user_agent)
        |> Metadata.append(Keyword.get(opts, :metadata))

      _ =
        Protocol.cdp_send(
          session,
          "emulation.setUserAgentOverride",
          %{"userAgent" => ua, "contexts" => [session.browsing_context]},
          []
        )
    end

    if window_size = Keyword.get(opts, :window_size) do
      _ = BiDiClient.set_viewport(session, window_size[:width], window_size[:height])
    end

    # `:base_url`/`:max_wait_time` govern later calls rather than
    # session startup, so they ride on the session — that way an
    # application's own session isn't governed by whatever a test
    # suite configured globally.
    session_opts = Keyword.take(opts, [:base_url, :max_wait_time])
    {:ok, %{session | session_opts: session_opts}}
  end

  # ----- Per-spec overrides -----

  # touch_scroll uses BiDi's JS scrollBy workaround (touch pointer
  # actions don't reliably trigger scroll in headless Chrome).
  @doc false
  def touch_scroll_impl(%SurfBoard.Element{} = element, x_offset, y_offset) do
    case BiDiClient.call_on_element(
           SurfBoard.Element.root_session(element),
           element,
           "function(dx, dy) { this.scrollIntoView(); window.scrollBy(dx, dy); return null; }",
           [x_offset, y_offset]
         ) do
      {:ok, _} -> {:ok, nil}
      err -> err
    end
  end
end
