defmodule SurfBoard.Integration.ChromeCDPSmokeTest do
  @moduledoc """
  Smoke test for the Chrome CDP driver against the surf_board public API
  (SurfBoard.DSL / SurfBoard.Browser), driven by a real Chrome instance.
  Not exhaustive — just enough to trust the extraction stands on its own.
  """
  use SurfBoard.Integration.SessionCase, async: false

  @moduletag driver: :chrome_cdp
  @moduletag :chrome_cdp

  test "visit + current_url + page_title", %{session: session} do
    visit(session, "/index.html")

    assert current_url(session) =~ "/index.html"
    assert page_title(session) == "SurfBoard Fixture"
  end

  test "find + text + attribute", %{session: session} do
    visit(session, "/index.html")

    header = find(session, Query.css("#header"))
    assert SurfBoard.Element.text(header) == "SurfBoard Fixture"

    link = find(session, Query.css("#the-link"))
    assert SurfBoard.Element.attr(link, "href") =~ "/other.html"
  end

  test "click", %{session: session} do
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

  test "take_screenshot writes a PNG file and records it on the session", %{session: session} do
    visit(session, "/index.html")

    result = take_screenshot(session)
    [path] = result.screenshots

    assert File.exists?(path)
    assert {:ok, <<0x89, "PNG", _rest::binary>>} = File.read(path)

    File.rm(path)
  end

  test "cookies: set_cookie then cookies/1 includes it", %{session: session} do
    visit(session, "/index.html")

    session = set_cookie(session, "smoke_test", "1")
    cookies = cookies(session)

    assert Enum.any?(cookies, &(&1["name"] == "smoke_test" && &1["value"] == "1"))
  end
end
