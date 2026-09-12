defmodule SurfBoard.Integration.ChromeBiDiSmokeTest do
  @moduledoc """
  Smoke test for the Chrome BiDi spec against the surf_board public
  API. Not exhaustive — just enough to trust the extraction stands on
  its own. BiDi runs through a local chromium-bidi Node sidecar (see
  priv/bidi-server), which needs `npm install` in that directory.

  `SurfBoard.start_session(driver: :chrome)` starts the sidecar lazily,
  the first time it's called (`SpecModule.ChromeBiDi.default_launcher_spec/0`,
  under `SurfBoard.DriverSupervisor`) — no manual setup needed here,
  same as chrome_cdp/lightpanda's SessionCase-driven tests.
  """
  use SurfBoard.Integration.SessionCase, async: false

  @moduletag driver: :chrome
  @moduletag :chrome

  test "visit + current_url + page_title", %{session: session} do
    visit(session, "/index.html")

    assert current_url(session) =~ "/index.html"
    assert page_title(session) == "SurfBoard Fixture"
  end

  test "find + click", %{session: session} do
    visit(session, "/index.html")

    assert text(session, Query.css("#result")) == "not clicked"
    click(session, Query.css("#the-button"))
    assert text(session, Query.css("#result")) == "clicked"
  end

  test "execute_script", %{session: session} do
    visit(session, "/index.html")

    execute_script(session, "return 1 + 1;", fn result ->
      assert result == 2
    end)
  end
end
