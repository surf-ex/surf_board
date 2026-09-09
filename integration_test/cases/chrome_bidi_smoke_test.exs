defmodule SurfBoard.Integration.ChromeBiDiSmokeTest do
  @moduledoc """
  Smoke test for the Chrome BiDi driver against the surf_board public
  API. Not exhaustive — just enough to trust the extraction stands on
  its own. BiDi runs through a local chromium-bidi Node sidecar (see
  priv/bidi-server), which needs `npm install` in that directory.

  BiDi isn't part of the default driver ladder (config :surf_board,
  browser: :chrome opts a test run into it), so this test starts the
  ChromeBiDi supervisor itself rather than relying on
  SurfBoard.Integration.SessionCase's auto-injected session — same
  pattern as the unit-level bidi_client_test.exs.
  """
  use ExUnit.Case, async: false
  use SurfBoard.DSL

  setup do
    {:ok, _} = SurfBoard.Drivers.ChromeBiDi.start_link(name: SurfBoard.Drivers.ChromeBiDi)

    on_exit(fn ->
      try do
        Supervisor.stop(SurfBoard.Drivers.ChromeBiDi, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, session} = SurfBoard.start_session(driver: :chrome)
    on_exit(fn -> SurfBoard.end_session(session) end)

    {:ok, session: session}
  end

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
