# Surfboard

Concurrent browser automation for Elixir — drive Chrome, Chromium, or Lightpanda via CDP/BiDi.

Surfboard is the browser-driving layer extracted from [Wallabidi](https://github.com/u2i/wallabidi):
navigation, element finding, JS execution, screenshots, cookies, and window/frame/dialog handling,
with no dependency on ExUnit or Phoenix. Use it to script a browser from a plain script, a Mix task,
or a GenServer — screen scraping, PDF rendering, automating a third-party site, or anything else
that needs a real (or Lightpanda) browser without a testing framework attached.

```elixir
{:ok, session} = Surfboard.start_session(driver: :chrome_cdp)

session
|> Surfboard.Browser.visit("https://example.com")
|> Surfboard.Browser.find(Surfboard.Query.css("h1"))
|> Surfboard.Element.text()
#=> "Example Domain"

Surfboard.end_session(session)
```

## Drivers

- **Chrome CDP** — real Chrome/Chromium via the DevTools Protocol.
- **Chrome BiDi** — real Chrome via WebDriver BiDi (chromium-bidi).
- **Lightpanda** — a lightweight headless browser, faster to start and run than Chrome.

## LiveView awareness

Surfboard has no opinion on Phoenix LiveView by default — clicks and navigation behave the
same on any page. Pass `live_view_aware: true` to `start_session/1` for sessions that need to
wait on LiveView's `phx-*` patch lifecycle (e.g. testing a LiveView app):

```elixir
{:ok, session} = Surfboard.start_session(driver: :chrome_cdp, live_view_aware: true)
```

## Installation

```elixir
def deps do
  [{:surfboard, "~> 0.1"}]
end
```

```bash
mix surfboard.install
```

## Status

This is a fresh extraction (v0.1.0) — the driving code itself has real production mileage as
part of Wallabidi, but this package boundary and its own test suite are new.
