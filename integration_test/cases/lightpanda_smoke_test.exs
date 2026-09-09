defmodule Surfboard.Integration.LightpandaSmokeTest do
  @moduledoc """
  Smoke test for the Lightpanda driver against the surfboard public API.
  Not exhaustive — just enough to trust the extraction stands on its
  own. Screenshots are skipped: Page.captureScreenshot isn't
  implemented on Lightpanda (see the Scraping guide's driver-capability
  table in the original wallabidi docs).
  """
  use Surfboard.Integration.SessionCase, async: false

  @moduletag driver: :lightpanda
  @moduletag :lightpanda

  test "visit + current_url + page_title", %{session: session} do
    visit(session, "/index.html")

    assert current_url(session) =~ "/index.html"
    assert page_title(session) == "Surfboard Fixture"
  end

  test "find + text + attribute", %{session: session} do
    visit(session, "/index.html")

    header = find(session, Query.css("#header"))
    assert Surfboard.Element.text(header) == "Surfboard Fixture"

    link = find(session, Query.css("#the-link"))
    assert Surfboard.Element.attr(link, "href") =~ "/other.html"
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

  test "cookies: set_cookie then cookies/1 includes it", %{session: session} do
    visit(session, "/index.html")

    session = set_cookie(session, "smoke_test", "1")
    cookies = cookies(session)

    assert Enum.any?(cookies, &(&1["name"] == "smoke_test" && &1["value"] == "1"))
  end
end
