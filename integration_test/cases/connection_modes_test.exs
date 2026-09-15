defmodule SurfBoard.Integration.ConnectionModesTest do
  @moduledoc """
  Coverage for the connection-mode entry points that don't have a
  persistent default instance in test_helper.exs, and so were
  previously exercised by nothing: `Driver.ChromeCDP.connect/1` and
  `Driver.Lightpanda.spawn_session/1`/`connect_session/2`.

  Each dials a real, already-running browser process rather than
  spawning a wholly separate one — `Driver.ChromeCDP.connect/1`
  against the default *spawned* Chrome instance's own DevTools port
  (no `SURF_BOARD_CHROME_URL` needed), and
  `Driver.Lightpanda.connect_session/2` against a Lightpanda binary
  spawned directly for this test.
  """
  use SurfBoard.Integration.SessionCase, async: false

  @moduletag :chrome_cdp
  @moduletag :lightpanda
  @moduletag skip_test_session: true

  describe "Driver.ChromeCDP.connect/1" do
    test "starts a session against an existing Chrome instance's own DevTools port" do
      chrome_server = SurfBoard.Driver.ChromeCDP.server_name(SurfBoard.Driver.ChromeCDP.default_name())
      ws_url = SurfBoard.Driver.Chrome.Server.ws_url(chrome_server)

      {:ok, pid} = SurfBoard.Driver.ChromeCDP.connect(url: ws_url)

      try do
        {:ok, session} = SurfBoard.Driver.ChromeCDP.start_session(pid, [])

        visit(session, "/index.html")
        assert current_url(session) =~ "/index.html"
        assert page_title(session) == "SurfBoard Fixture"

        SurfBoard.end_session(session)
      after
        GenServer.stop(pid)
      end
    end
  end

  describe "Driver.Lightpanda.spawn_session/1" do
    test "spawns a private binary and starts a session against it" do
      {:ok, session} = SurfBoard.Driver.Lightpanda.spawn_session([])

      visit(session, "/index.html")
      assert current_url(session) =~ "/index.html"
      assert page_title(session) == "SurfBoard Fixture"

      SurfBoard.end_session(session)
    end
  end

  describe "Driver.Lightpanda.connect_session/2" do
    test "connects to a Lightpanda instance this driver never launched" do
      lightpanda_server = Module.concat([Lightpanda, Server])

      {:ok, server_pid} =
        apply(lightpanda_server, :start_link, [
          [name: nil, wrapper_script: Path.absname("priv/run_command.sh", Application.app_dir(:surf_board))]
        ])

      try do
        ws_url = apply(lightpanda_server, :ws_url, [server_pid])

        {:ok, session} = SurfBoard.Driver.Lightpanda.connect_session(ws_url, [])

        visit(session, "/index.html")
        assert current_url(session) =~ "/index.html"
        assert page_title(session) == "SurfBoard Fixture"

        SurfBoard.end_session(session)
      after
        GenServer.stop(server_pid, :normal, 5_000)
      end
    end
  end
end
