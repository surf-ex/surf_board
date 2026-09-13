defmodule SurfBoard.Integration.ChromeBiDiSendKeysTest do
  @moduledoc """
  Verifies session-scoped `send_keys/2` accepts the canonical
  WebDriver key vocabulary (`SurfBoard.KeyCodes`) against real Chrome
  over BiDi — the same vocabulary `chrome_cdp_send_keys_test.exs`
  verifies over CDP. BiDi already spoke this vocabulary natively (its
  wire format is the WebDriver `\\uE0XX` codepoints); this also
  verifies the CDP-only legacy names now work here too, matching CDP.
  """
  use SurfBoard.Integration.SessionCase, async: false

  @moduletag driver: :chrome
  @moduletag :chrome

  test "canonical special keys are recognized by the page", %{session: session} do
    visit(session, "/index.html")
    click(session, Query.css("#the-key-log"))

    send_keys(session, [:enter, :tab, :escape, :left_arrow, :up_arrow])

    assert text(session, Query.css("#the-key-log")) ==
             "[Enter][Tab][Escape][ArrowLeft][ArrowUp]"
  end

  test "legacy CDP-only key names still work as aliases", %{session: session} do
    visit(session, "/index.html")
    click(session, Query.css("#the-key-log"))

    send_keys(session, [:arrow_up, :arrow_down, :arrow_left, :arrow_right, :end_key])

    assert text(session, Query.css("#the-key-log")) ==
             "[ArrowUp][ArrowDown][ArrowLeft][ArrowRight][End]"
  end

  test "mixed text and special keys", %{session: session} do
    visit(session, "/index.html")
    click(session, Query.css("#the-input"))

    send_keys(session, ["hi", :space, "there"])

    assert SurfBoard.Browser.attr(session, Query.css("#the-input"), "value") == "hi there"
  end
end
