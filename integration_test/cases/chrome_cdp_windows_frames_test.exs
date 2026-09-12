defmodule SurfBoard.Integration.ChromeCdpWindowsFramesTest do
  @moduledoc """
  Window and frame focus switching for Chrome over CDP. First test
  coverage for this functionality in the project (see
  chrome_bidi_windows_frames_test.exs for the BiDi counterpart) — the
  process-dictionary-to-actor-state migration this covers had zero
  prior regression coverage on either driver.
  """
  use SurfBoard.Integration.SessionCase, async: false

  @moduletag driver: :chrome_cdp
  @moduletag :chrome_cdp

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
end
