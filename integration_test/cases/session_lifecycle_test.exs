defmodule SurfBoard.Integration.SessionLifecycleTest do
  @moduledoc """
  Sessions must not outlive the process that owns them, whichever
  driver started them.
  """
  use SurfBoard.Integration.SessionCase, async: false

  @moduletag :chrome_cdp
  @moduletag :lightpanda
  @moduletag skip_test_session: true

  for driver <- [:chrome_cdp, :chrome, :lightpanda] do
    test "#{driver}: session stops when its owner process dies" do
      session = start_owned_session(unquote(driver))
      ref = Process.monitor(session.pid)

      Process.exit(session_owner(), :kill)

      assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
    end
  end

  # A BiDi session's WebSocket is its chromium-bidi session (and
  # browser); it must close with the session.
  test "chrome: end_session closes the session's socket" do
    {:ok, session} = start_test_session(:chrome)
    ref = Process.monitor(session.ws_pid)

    SurfBoard.end_session(session)

    assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
  end

  test "chrome: owner death closes the session's socket" do
    session = start_owned_session(:chrome)
    ref = Process.monitor(session.ws_pid)

    Process.exit(session_owner(), :kill)

    assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
  end

  # Starts a session from a throwaway process, so the test can kill
  # that owner without taking itself down.
  defp start_owned_session(driver) do
    test_pid = self()

    owner =
      spawn(fn ->
        {:ok, session} = start_test_session(driver)
        send(test_pid, {:session, session})
        Process.sleep(:infinity)
      end)

    Process.put(:session_owner, owner)
    assert_receive {:session, session}, 30_000
    session
  end

  defp session_owner, do: Process.get(:session_owner)
end
