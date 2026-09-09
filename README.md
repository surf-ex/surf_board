# SurfBoard

Concurrent browser automation for Elixir — drive Chrome, Chromium, or Lightpanda via CDP/BiDi.

SurfBoard is the browser-driving layer extracted from [Wallabidi](https://github.com/u2i/wallabidi):
navigation, element finding, JS execution, screenshots, cookies, and window/frame/dialog handling,
with no dependency on ExUnit or Phoenix. Use it to script a browser from a plain script, a Mix task,
or a GenServer — screen scraping, PDF rendering, automating a third-party site, or anything else
that needs a real (or Lightpanda) browser without a testing framework attached.

```elixir
{:ok, session} = SurfBoard.start_session(driver: :chrome_cdp)

session
|> SurfBoard.Browser.visit("https://example.com")
|> SurfBoard.Browser.find(SurfBoard.Query.css("h1"))
|> SurfBoard.Element.text()
#=> "Example Domain"

SurfBoard.end_session(session)
```

## Drivers

- **Chrome CDP** — real Chrome/Chromium via the DevTools Protocol.
- **Chrome BiDi** — real Chrome via WebDriver BiDi (chromium-bidi).
- **Lightpanda** — a lightweight headless browser, faster to start and run than Chrome.

## LiveView awareness

SurfBoard has no opinion on Phoenix LiveView by default — clicks and navigation behave the
same on any page. Pass `live_view_aware: true` to `start_session/1` for sessions that need to
wait on LiveView's `phx-*` patch lifecycle (e.g. testing a LiveView app):

```elixir
{:ok, session} = SurfBoard.start_session(driver: :chrome_cdp, live_view_aware: true)
```

## Installation

```elixir
def deps do
  [{:surf_board, "~> 0.1"}]
end
```

```bash
mix surf_board.install
```

## Status

This is a fresh extraction (v0.1.0) — the driving code itself has real production mileage as
part of Wallabidi, but this package boundary and its own test suite are new.

## Credits

SurfBoard is built on the foundation of [Wallabidi](https://github.com/u2i/wallabidi), which is
itself built on the foundation of [Wallaby](https://github.com/elixir-wallaby/wallaby), the work
of its original author and [many contributors](https://github.com/elixir-wallaby/wallaby/graphs/contributors)
over the years, and currently maintained by [Mitchell Hanberg](https://github.com/mhanberg). The
Browser, Query, and Element APIs, and the CDP/BiDi transport this package extracts, trace back
through both. SurfBoard's own contribution is separating that driving layer out from Wallabidi's
ExUnit/Phoenix testing-framework integration, so it can be used on its own.

Licensed under MIT, same as Wallaby and Wallabidi. See [LICENSE.md](LICENSE.md) and
[NOTICE.md](NOTICE.md).
