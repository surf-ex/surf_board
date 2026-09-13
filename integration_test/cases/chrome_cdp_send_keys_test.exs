defmodule SurfBoard.Integration.ChromeCDPSendKeysTest do
  @moduledoc """
  Verifies session-scoped `send_keys/2` accepts the canonical
  WebDriver key vocabulary (`SurfBoard.KeyCodes`) against real Chrome
  over CDP — the same vocabulary `chrome_bidi_send_keys_test.exs`
  verifies over BiDi. Before this, CDP only accepted a small custom
  atom set (`:arrow_up`, `:end_key`, ...) different from BiDi's; both
  now accept the same names, with the old CDP-only names kept as
  aliases.
  """
  use SurfBoard.Integration.SessionCase, async: false

  @moduletag driver: :chrome_cdp
  @moduletag :chrome_cdp

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
