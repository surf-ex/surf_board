defmodule SurfBoard do
  @moduledoc """
  A concurrent browser automation library — feature testing, and scraping
  or automating pages outside ExUnit.

  ## Configuration

  SurfBoard supports the following options:

  * `:driver` - Which driver `start_session/1` uses when no `:driver` opt
    is given. Defaults to `:chrome_cdp`.
  * `:screenshot_dir` - The directory to store screenshots.
  * `:screenshot_on_failure` - if SurfBoard should take screenshots on test failures (defaults to `false`).
  * `:max_wait_time` - The amount of time that SurfBoard should wait to find an element on the page. (defaults to `3_000`)
  * `:js_errors` - if SurfBoard should re-throw JavaScript errors in elixir (defaults to true).
  * `:js_logger` - IO device where JavaScript console logs are written to. Defaults to :stdio. This option can also be set to a file or any other io device. You can disable JavaScript console logging by setting this to `nil`.
  """

  use Application

  alias SurfBoard.Session

  @doc false
  def start(_type, _args) do
    SurfBoard.Bench.Timing.setup()

    # No driver is started here — a session's driver isn't known until
    # `start_session/1` is called, so its supervisor starts lazily then
    # (see `ensure_driver_started/1`). Nothing about booting the
    # application should depend on Chrome/Lightpanda being installed.
    children = [
      {DynamicSupervisor, name: SurfBoard.DriverSupervisor, strategy: :one_for_one},
      {SurfBoard.SessionStore, [name: SurfBoard.SessionStore]}
    ]

    opts = [strategy: :one_for_one, name: SurfBoard.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Starts `mod`'s supervisor under `SurfBoard.DriverSupervisor` on first
  # use, idempotently — a second call for an already-running driver is a
  # no-op. Runs `mod.cleanup_stale_sessions/0` once, right after a fresh
  # start.
  defp ensure_driver_started(mod) do
    case DynamicSupervisor.start_child(
           SurfBoard.DriverSupervisor,
           {mod, [name: Module.concat(mod, Supervisor)]}
         ) do
      {:ok, _pid} ->
        mod.cleanup_stale_sessions()
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      # A driver whose supervisor starts a fixed-named child (e.g.
      # ChromeBiDi's ChromiumBiDi.Server) reports a second concurrent
      # start attempt this way rather than as a flat :already_started —
      # the DynamicSupervisor call for the driver itself succeeds far
      # enough to spawn the child before the child's own name clash
      # unwinds the start. Treat it the same as :already_started: some
      # other call already has (or is bringing up) this driver.
      {:error, {:shutdown, {:failed_to_start_child, _child, {:already_started, _pid}}}} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @type reason :: any
  @type start_session_opts :: {atom, any}

  @doc """
  Starts a browser session.

  ## Options

    * `:driver` — which driver runs this session (`:lightpanda`,
      `:chrome_cdp`, `:chrome`). Defaults to the configured driver.
    * `:connection` — Lightpanda only: how this session gets its
      transport. `:shared` (reuse the already-running shared Lightpanda
      binary), `:isolated` (spawn a private binary for just this
      session), or `:external` (connect to a Lightpanda instance this
      driver doesn't manage — requires `:ws_url`). Omit to auto-detect
      (prefers `:external` if `:ws_url` is given, else `:shared` if a
      shared binary is already running, else `:isolated`). An explicit
      value that isn't actually available returns `{:error, reason}`
      rather than silently falling back — see
      `SurfBoard.Drivers.LightpandaCDP.start_session/1`. Chrome CDP has
      the analogous `:shared`/`:external` choice too, but it's fixed
      once for the life of the BEAM (the driver's own connection
      process starts lazily on first use and is never restarted per
      session) — set it via
      `config :surf_board, :chrome_cdp_v2, connection: :shared | :external`,
      not as a `start_session/1` opt. See
      `SurfBoard.Drivers.ChromeCDP.init/1`.
    * `:user_agent` — replace this session's User-Agent. Chrome only; see
      below.
    * `:window_size` — `[width: w, height: h]`.
    * `:live_view_aware` — opt in to LiveView `phx-*` patch-classification
      on click/fill_in and connect-awaiting on visit. Off by default for
      every driver. See the moduledoc's "LiveView awareness" note.
    * `:metadata` — BEAM sandbox metadata, appended to the User-Agent so
      DB-backed tests can find the sandbox owner. Composes with a custom
      User-Agent, which becomes the base.

  ## Setting the User-Agent

  For most cases set it once, in config — this works on **every** driver:

  ```
  config :surf_board, user_agent: "MyScraper/1.0 (+https://example.com/bot)"
  ```

  Pass `:user_agent` to `start_session/1` only when sessions need
  *different* User-Agents at the same time (mobile vs desktop, say):

  ```
  {:ok, mobile} = SurfBoard.start_session(driver: :chrome_cdp, user_agent: "…iPhone…")
  {:ok, desktop} = SurfBoard.start_session(driver: :chrome_cdp)
  ```

  That option is Chrome-only. Lightpanda sets its User-Agent per process
  rather than per session, so it can honour the config but not the option —
  passing it there logs a warning. Lightpanda also accepts
  `config :surf_board, lightpanda_user_agent_suffix: "MyScraper/1.0"`, which
  appends to `Lightpanda/X.Y` instead of replacing it.

  ## Multiple sessions

  Each session runs in its own browser so that each test runs in isolation.
  Because of this isolation multiple sessions can be created for a test:

  ```
  @message_field Query.text_field("Share Message")
  @share_button Query.button("Share")
  @message_list Query.css(".messages")

  test "That multiple sessions work" do
    {:ok, user1} = SurfBoard.start_session
    user1
    |> visit("/page.html")
    |> fill_in(@message_field, with: "Hello there!")
    |> click(@share_button)

    {:ok, user2} = SurfBoard.start_session
    user2
    |> visit("/page.html")
    |> fill_in(@message_field, with: "Hello yourself")
    |> click(@share_button)

    assert user1 |> find(@message_list) |> List.last |> text == "Hello yourself"
    assert user2 |> find(@message_list) |> List.first |> text == "Hello there"
  end
  ```
  """
  @spec start_session([start_session_opts]) :: {:ok, Session.t()} | {:error, reason}
  def start_session(opts \\ []) do
    # Each Transport actor monitors its owner and runs cleanup in
    # terminate/2 when the owner dies, so we don't need on_exit hooks
    # or SessionStore monitoring for crashed-test cleanup.
    opts = Keyword.delete(opts, :__test_api__)

    opts
    |> do_start_session()
    |> stash_session_opts(opts)
  end

  # `:base_url` and `:max_wait_time` govern later calls rather than session
  # startup, so they ride on the session — that way an application's own
  # session isn't governed by whatever the test suite configured globally.
  @session_scoped_opts [:base_url, :max_wait_time]

  defp stash_session_opts({:ok, session}, opts) do
    {:ok, %{session | session_opts: Keyword.take(opts, @session_scoped_opts)}}
  end

  defp stash_session_opts(other, _opts), do: other

  defp do_start_session(opts) do
    mod = opts |> resolve_driver() |> driver_module_for()

    with :ok <- ensure_driver_started(mod) do
      mod.start_session(opts)
    end
  end

  @doc """
  Ends a browser session.
  """
  @spec end_session(Session.t()) :: :ok | {:error, reason}
  def end_session(%Session{driver: driver} = session) do
    result = driver.end_session(session)

    # Drain any in-flight WebSocket events that arrived after session
    # teardown. Without this, :bidi_event messages linger in the test
    # process mailbox and can interfere with the next session.
    drain_bidi_events()
    result
  end

  defp drain_bidi_events do
    receive do
      {:bidi_event, _, _} -> drain_bidi_events()
    after
      0 -> :ok
    end
  end

  @doc false
  def stop(_state) do
    :ok
  end

  @doc false
  def driver_module_for(driver) do
    case driver do
      :lightpanda -> SurfBoard.Drivers.LightpandaCDP
      :chrome_cdp -> SurfBoard.Drivers.ChromeCDP
      :chrome -> SurfBoard.Drivers.ChromeBiDi
      _ -> SurfBoard.Drivers.ChromeCDP
    end
  end

  @doc """
  Resolves the driver for a session. Explicit `opts[:driver]` wins;
  otherwise `config :surf_board, driver: ...`, defaulting to `:chrome_cdp`.
  """
  def resolve_driver(opts \\ []) do
    Keyword.get_lazy(opts, :driver, fn ->
      Application.get_env(:surf_board, :driver, :chrome_cdp)
    end)
  end

  @doc false
  def screenshot_on_failure? do
    Application.get_env(:surf_board, :screenshot_on_failure)
  end

  @doc false
  def js_errors? do
    Application.get_env(:surf_board, :js_errors, true)
  end

  @doc false
  def js_logger do
    Application.get_env(:surf_board, :js_logger, :stdio)
  end
end
