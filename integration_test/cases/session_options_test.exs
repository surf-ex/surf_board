defmodule SurfBoard.Integration.SessionOptionsTest do
  @moduledoc """
  Session options that must behave the same on every driver.
  """
  use SurfBoard.Integration.SessionCase, async: false

  alias SurfBoard.Integration.FixtureServer

  @moduletag :chrome_cdp
  @moduletag :lightpanda
  @moduletag skip_test_session: true

  setup do
    # Prove the per-session value is what's used, not global config.
    global = Application.fetch_env!(:surf_board, :base_url)
    Application.delete_env(:surf_board, :base_url)
    on_exit(fn -> Application.put_env(:surf_board, :base_url, global) end)
    :ok
  end

  for driver <- [:chrome_cdp, :chrome, :lightpanda] do
    test "#{driver}: :base_url resolves relative visit/2 paths" do
      {:ok, session} = start_test_session(unquote(driver), base_url: FixtureServer.base_url())

      try do
        visit(session, "/index.html")
        assert page_title(session) == "SurfBoard Fixture"
      after
        SurfBoard.end_session(session)
      end
    end
  end
end
