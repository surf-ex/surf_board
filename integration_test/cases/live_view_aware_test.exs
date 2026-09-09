defmodule SurfBoard.Integration.LiveViewAwareTest do
  @moduledoc """
  Verifies the `live_view_aware` opt-in surgery end-to-end (see commit
  completing the JS-side gating of installLvHook/onPatchEnd). Doesn't
  require a real Phoenix/LiveView backend — the fixture page is just
  shaped like a LiveView page ([data-phx-session] present, plus a
  minimal window.liveSocket stand-in with domCallbacks for
  installLvHook to wrap). This checks the bootstrap's own
  detection/hook-install logic, not a real LiveView round-trip.

  window.__w.lvHooked (surf_board.js's W.lvHooked) is the ground truth:
  true once installLvHook() has run, false if detectReady() took the
  non-LV path instead.
  """
  use SurfBoard.Integration.SessionCase, async: false

  @moduletag :chrome_cdp
  @moduletag skip_test_session: true

  test "live_view_aware: false (default) never installs the onPatchEnd hook, even on a LiveView-shaped page" do
    {:ok, session} = start_test_session(driver: :chrome_cdp)

    visit(session, "/fake_liveview.html")
    # Give detectReady()'s DOMContentLoaded/requestAnimationFrame loop a
    # moment to settle.
    Process.sleep(300)

    execute_script(session, "return window.__w && window.__w.lvHooked;", fn hooked ->
      assert hooked == false
    end)

    SurfBoard.end_session(session)
  end

  test "live_view_aware: true installs the onPatchEnd hook on a LiveView-shaped page" do
    {:ok, session} = start_test_session(driver: :chrome_cdp, live_view_aware: true)

    visit(session, "/fake_liveview.html")
    Process.sleep(300)

    execute_script(session, "return window.__w && window.__w.lvHooked;", fn hooked ->
      assert hooked == true
    end)

    SurfBoard.end_session(session)
  end

  test "live_view_aware: true on a PLAIN (non-LiveView-shaped) page never installs the hook" do
    {:ok, session} = start_test_session(driver: :chrome_cdp, live_view_aware: true)

    visit(session, "/index.html")
    Process.sleep(300)

    execute_script(session, "return window.__w && window.__w.lvHooked;", fn hooked ->
      assert hooked == false
    end)

    SurfBoard.end_session(session)
  end
end
