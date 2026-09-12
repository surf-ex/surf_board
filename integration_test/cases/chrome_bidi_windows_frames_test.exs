defmodule SurfBoard.Integration.ChromeBiDiWindowsFramesTest do
  @moduledoc """
  Window and frame focus switching for Chrome over BiDi. This is the
  actual regression coverage for the process-dictionary-to-actor-state
  migration: BiDi's `Clients.BiDi.Windows`/`Frames` used to store focus
  in the calling process's dictionary (invisible to any other process
  holding the same session, and silently wrong if used across
  processes). See chrome_cdp_windows_frames_test.exs for the CDP
  counterpart, which already used actor state and didn't have this bug.
  """
  use SurfBoard.Integration.SessionCase, async: false

  @moduletag driver: :chrome
  @moduletag :chrome

  test "focus_window switches which tab subsequent ops target", %{session: session} do
    visit(session, "/index.html")
    original = window_handle(session)

    execute_script(session, "window.open('/other.html', '_blank'); return null;")

    handles = window_handles(session)
    assert length(handles) == 2
    new_handle = Enum.find(handles, &(&1 != original))

    session = focus_window(session, new_handle)
    assert window_handle(session) == new_handle
    assert current_url(session) =~ "/other.html"

    session = focus_window(session, original)
    assert window_handle(session) == original
    assert current_url(session) =~ "/index.html"

    # Focus is back on `original` at this point, so closing it should
    # leave the other tab as the sole survivor.
    session = close_window(session)
    assert window_handles(session) == [new_handle]
  end

  # The actual regression test: under the old Process.put
  # implementation, this would fail — the focus written by the test
  # process is invisible to a different process reading it back.
  test "focus_window is visible from a different process holding the same session", %{
    session: session
  } do
    visit(session, "/index.html")
    original = window_handle(session)

    execute_script(session, "window.open('/other.html', '_blank'); return null;")
    new_handle = Enum.find(window_handles(session), &(&1 != original))

    focus_window(session, new_handle)

    task = Task.async(fn -> window_handle(session) end)
    assert Task.await(task) == new_handle
  end

  test "focus_frame/focus_parent_frame/focus_default_frame scope finds to an iframe", %{
    session: session
  } do
    visit(session, "/with_iframe.html")

    session = focus_frame(session, Query.css("#the-iframe"))

    assert text(session, Query.css("#inner")) == "inner content"
    refute has_css?(session, "#header")

    session = focus_parent_frame(session)
    assert text(session, Query.css("#header")) == "SurfBoard Fixture"

    session = focus_frame(session, Query.css("#the-iframe"))
    session = focus_default_frame(session)
    assert text(session, Query.css("#header")) == "SurfBoard Fixture"
  end

  # The actual regression test for frame focus: under the old
  # Process.put implementation, a different process reading ctx/1
  # (indirectly, via any find/click/evaluate) would never see the
  # focused iframe.
  test "focus_frame is visible from a different process holding the same session", %{
    session: session
  } do
    visit(session, "/with_iframe.html")
    focus_frame(session, Query.css("#the-iframe"))

    task = Task.async(fn -> text(session, Query.css("#inner")) end)
    assert Task.await(task) == "inner content"
  end
end
