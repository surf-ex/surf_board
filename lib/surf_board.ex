defmodule SurfBoard do
  @moduledoc """
  A concurrent browser automation library — feature testing, and scraping
  or automating pages outside ExUnit.

  ## Configuration

  SurfBoard supports the following options:

  * `:screenshot_dir` - The directory to store screenshots.
  * `:screenshot_on_failure` - if SurfBoard should take screenshots on test failures (defaults to `false`).
  * `:max_wait_time` - The amount of time that SurfBoard should wait to find an element on the page. (defaults to `3_000`)
  * `:js_errors` - if SurfBoard should re-throw JavaScript errors in elixir (defaults to true).
  * `:js_logger` - IO device where JavaScript console logs are written to. Defaults to :stdio. This option can also be set to a file or any other io device. You can disable JavaScript console logging by setting this to `nil`.

  ## Starting a session

  There's no central dispatcher — call the driver module you want directly:

  ```
  {:ok, session} = SurfBoard.Driver.ChromeCDP.start_session()
  ```

  Each driver is a self-contained OTP module: `SurfBoard.Driver.ChromeCDP`,
  `SurfBoard.Driver.ChromeBiDi`, `SurfBoard.Driver.Lightpanda`. Calling
  `start_session/1` against a driver that hasn't started its own default
  instance yet starts one lazily on first use (for `ChromeCDP`/`Lightpanda`)
  — nothing about loading this library depends on Chrome/Lightpanda being
  installed, only on actually calling `start_session/1`.

  `ChromeBiDi` is the one exception: it needs its sidecar process
  (`Driver.ChromeBiDi.default_child_spec/0`) started under your own
  supervision tree first, since there's no implicit "start on first call"
  hook for it — see that module's docs.

  To own your own instance instead of using a driver's shared default
  (e.g. a test suite launching and owning a second, independent Chrome):

  ```
  {:ok, _sup} = SurfBoard.Driver.ChromeCDP.start_link(name: MyApp.TestChrome)
  {:ok, session} = SurfBoard.Driver.ChromeCDP.start_session(MyApp.TestChrome, [])
  ```

  Or connect to a browser you don't manage:

  ```
  {:ok, launcher} = SurfBoard.Driver.ChromeCDP.connect(url: "ws://localhost:9222/...")
  {:ok, session} = SurfBoard.Driver.ChromeCDP.start_session(launcher, [])
  ```

  ## Session options

  Every driver's `start_session/1` (or `/2` for the ones that take an
  explicit instance) accepts:

    * `:user_agent` — replace this session's User-Agent. Chrome only; see
      below.
    * `:window_size` — `[width: w, height: h]`.
    * `:live_view_aware` — opt in to LiveView `phx-*` patch-classification
      on click/fill_in and connect-awaiting on visit. Off by default for
      every driver. See the moduledoc's "LiveView awareness" note.
    * `:metadata` — BEAM sandbox metadata, appended to the User-Agent so
      DB-backed tests can find the sandbox owner. Composes with a custom
      User-Agent, which becomes the base.

  `Driver.Lightpanda.start_session/1` additionally accepts `:connection`
  (`:shared`/`:isolated`/`:external`) — see that module's docs.

  ## Setting the User-Agent

  For most cases set it once, in config — this works on **every** driver:

  ```
  config :surf_board, user_agent: "MyScraper/1.0 (+https://example.com/bot)"
  ```

  Pass `:user_agent` to `start_session/1` only when sessions need
  *different* User-Agents at the same time (mobile vs desktop, say):

  ```
  {:ok, mobile} = SurfBoard.Driver.ChromeCDP.start_session(user_agent: "…iPhone…")
  {:ok, desktop} = SurfBoard.Driver.ChromeCDP.start_session()
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
    {:ok, user1} = SurfBoard.Driver.ChromeCDP.start_session()
    user1
    |> visit("/page.html")
    |> fill_in(@message_field, with: "Hello there!")
    |> click(@share_button)

    {:ok, user2} = SurfBoard.Driver.ChromeCDP.start_session()
    user2
    |> visit("/page.html")
    |> fill_in(@message_field, with: "Hello yourself")
    |> click(@share_button)

    assert user1 |> find(@message_list) |> List.last |> text == "Hello yourself"
    assert user2 |> find(@message_list) |> List.first |> text == "Hello there"
  end
  ```
  """

  use Application

  alias SurfBoard.Session
  alias SurfBoard.Transport.Protocol

  @doc false
  def start(_type, _args) do
    SurfBoard.Transport.Timing.setup()

    children = [
      {SurfBoard.Transport.SessionStore, [name: SurfBoard.Transport.SessionStore]}
    ]

    opts = [strategy: :one_for_one, name: SurfBoard.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc """
  Ends a browser session.
  """
  @spec end_session(Session.t()) :: :ok | {:error, any}
  def end_session(%Session{} = session) do
    # Every driver's end_session/1 was identical (Protocol.stop/1, no
    # driver-specific teardown) — call it directly so ending a session
    # never needs to know which driver started it.
    result = Protocol.stop(session)

    # Drain any in-flight WebSocket events that arrived after session
    # teardown. Without this, :v2_event messages linger in the test
    # process mailbox and can interfere with the next session.
    drain_v2_events()
    result
  end

  defp drain_v2_events do
    receive do
      {:v2_event, _, _} -> drain_v2_events()
    after
      0 -> :ok
    end
  end

  @doc false
  def stop(_state) do
    :ok
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
