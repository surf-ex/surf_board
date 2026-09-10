# Implementing a Driver

A driver is what makes a specific browser drivable through the `SurfBoard.Browser`/
`SurfBoard.Element`/`SurfBoard.Query` API. This guide is for adding a new one —
a new vendor (e.g. Firefox), a new wire protocol, or a new connection strategy for
an existing vendor.

## The two dimensions

Everything in `lib/surf_board/drivers/` varies along exactly two independent axes:

* **Protocol** — the wire format and command surface: CDP or WebDriver BiDi today.
  Lives under `SurfBoard.Drivers.CDP.*` / `SurfBoard.Drivers.ChromeBiDi.*` (the
  BiDi namespace is Chrome-named today because chromium-bidi's Node sidecar is
  currently fused into it — see [Adding a new protocol](#adding-a-new-protocol-or-a-second-bidi-vendor)
  if you're bringing a second BiDi vendor).
* **Driver** — one vendor's whole strategy for getting and holding a live
  connection: which browser process, how many sessions share one socket, whether
  the socket and the session's domain state live in the same process or two. This
  is *one* decision made once by the driver's author, not three independently
  pluggable things — `SurfBoard.Drivers.ChromeCDP`, `SurfBoard.Drivers.ChromeBiDi`,
  and `SurfBoard.Drivers.LightpandaCDP` each hardcode their own transport strategy
  rather than selecting one through a generic interface, because nothing actually
  needs to swap strategies under one driver at runtime.

A driver picks one protocol and supplies its own connection strategy. That's the
whole shape: `driver = protocol + strategy`.

Underneath both, `SurfBoard.Transport.WireSocket` is shared low-level Mint
WebSocket plumbing (connect, upgrade, encode/decode, frame dispatch) — it knows
neither the protocol nor the driver, and you generally don't need to touch it.

## What you get for free: `Driver.Generic`

`SurfBoard.Driver` is a ~40-callback behaviour (`visit/2`, `click/1`, `find_elements/2`,
`cookies/1`, `focus_frame/2`, ...). You do not implement all of them. `use SurfBoard.Driver.Generic`
delegates every one of them to dispatch code that reads `session.driver_spec` — a
`%SurfBoard.Driver.Spec{}` struct — and calls the right dimension module. You
only write:

* `start_session/1` and `end_session/1` — the two lifecycle callbacks Generic
  doesn't provide, because they're exactly the vendor-specific part.
* A `%SurfBoard.Driver.Spec{}` naming which existing (or new) protocol/dialogs/
  windows/frames/touch_scroll implementations this driver uses.
* Any per-driver override where the generic delegate isn't right for your vendor
  (see [Per-driver overrides](#per-driver-overrides)).

## Adding a driver for a vendor that already has a protocol client

This is the common case: a new way to run/connect-to a browser that already
speaks CDP or BiDi (e.g. a different Chromium-based browser, or a new connection
strategy for an existing vendor).

1. **Create `lib/surf_board/drivers/<your_driver>.ex`.** Look at
   `lib/surf_board/drivers/lightpanda_cdp.ex` for the smaller of the two existing
   examples (`chrome_cdp.ex` is the shared-connection one; `chrome_bidi.ex` is
   the BiDi one). Your module:

   ```elixir
   defmodule SurfBoard.Drivers.YourDriver do
     use Supervisor
     use SurfBoard.Driver.Generic

     alias SurfBoard.Driver.Spec

     @driver_spec %Spec{
       browser: Browser.YourVendor,
       wire_protocol: SurfBoard.Drivers.CDP.Client, # or ChromeBiDi.Client
       dialogs: Dialogs.ChromeCDP,      # reuse, or write your own — see below
       windows: Windows.ChromeCDP,      # reuse, or write your own
       frames: Frames.ChromeCDP,        # reuse, or write your own
       touch_scroll: &__MODULE__.touch_scroll_impl/3,
       log_check_interactions?: true
     }

     def driver_spec, do: @driver_spec

     # ----- Supervisor: how your browser process / connection comes up -----
     def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, :ok, opts)

     @impl Supervisor
     def init(_) do
       # Start whatever process(es) your connection strategy needs —
       # a server GenServer, a shared-connection Agent, nothing at all if
       # you connect directly. Mirror ChromeCDP.Server / LightpandaCDP's
       # `init/1` for the shape.
     end

     # ----- Session lifecycle -----
     @impl SurfBoard.Driver
     def start_session(opts \\ []) do
       # Acquire your WebSocket / connection (see "Owning your connection"
       # below), build a %SurfBoard.Session{driver: __MODULE__, driver_spec:
       # @driver_spec, ...}, and return {:ok, session}.
     end

     @impl SurfBoard.Driver
     def end_session(%SurfBoard.Session{} = session) do
       SurfBoard.Transport.Protocol.stop(session)
       :ok
     end
   end
   ```

2. **Add a vendor marker** in `lib/surf_board/browser/your_vendor.ex` — an empty
   module (see `browser/chrome.ex`, `browser/lightpanda.ex`). It's a tag, not a
   behaviour; nothing dispatches on it today, but it's how a session records
   which vendor it's driving.

3. **Own your connection.** Every driver ends up with a process that owns a
   `SurfBoard.Transport.WireSocket` and speaks `SurfBoard.Transport.Protocol`
   (the message contract `SurfBoard.Drivers.CDP.Client` /
   `SurfBoard.Drivers.ChromeBiDi.Client` call into — `cdp_send`, `subscribe`,
   `await_page_load`, `register_find`, `push_frame`, ...; see
   `lib/surf_board/transport/protocol.ex` for the full message list). There
   are three existing shapes to copy from, and the deciding factor is purely
   how many sessions share one socket:

   * **One socket shared by many sessions** (Chrome CDP's model) — use
     `SurfBoard.WebSocket` + `SurfBoard.Transport.Session` +
     `SurfBoard.Transport.SharedWS.acquire/1` as the template. This is the
     only case where the socket-owner and the domain-state-owner *must* be
     separate processes.
   * **One socket per session, but you'd rather not pay a bespoke process**
     — use `SurfBoard.WebSocket` + `SurfBoard.Transport.Session` +
     `SurfBoard.Transport.IsolatedProcess.acquire/1` as the template
     (a fresh WS per session, still split across two processes).
   * **One socket per session, and you want to remove the extra hop** — use
     `SurfBoard.Transport.PerSession.Actor` as the template: one GenServer
     holds both the `WireSocket` and all the domain state (`loads`,
     `find_waiters`, `frame_stack`, ...) in one mailbox. Worth it only if
     your driver is latency-sensitive per-call; it costs you a bigger,
     less-reusable actor module.

   Whichever shape you pick, your domain-state struct needs the fields
   `SurfBoard.Transport.Common` operates on (`loads`, `load_waiters`,
   `find_waiters`, `frame_stack`, `frame_contexts`, `page_ready_waiter`,
   `last_page_id`, `nav_pending`, `responses`, `last_loader_id`) — `Common`
   is the shared state machine for load/find/page-ready/frame tracking, used
   by all three existing actors so they don't drift from each other.

4. **Reuse `Dialogs`/`Windows`/`Frames`/`touch_scroll` where your vendor's
   behavior genuinely matches an existing one.** These are `%Spec{}`
   dimension modules — each implements a small behaviour
   (`SurfBoard.Dialogs`, `SurfBoard.Windows`, `SurfBoard.Frames`) for one
   protocol. If your vendor speaks CDP the same way Chrome does, point at
   `SurfBoard.Drivers.ChromeCDP.{Dialogs,Windows,Frames}` directly — don't
   copy them. If your vendor can't support one of these (no iframe support,
   no window management), point at the shared fallbacks:
   `SurfBoard.Dialogs.Unsupported`, `SurfBoard.Windows.Single`,
   `SurfBoard.Frames.Unsupported`. Only write a new implementation when your
   vendor's actual protocol behavior differs from every existing one.

5. **Register the driver.** Add your driver to `driver_module_for/1` in
   `lib/surf_board.ex` so `SurfBoard.start_session(driver: :your_driver)`
   resolves to your module.

## Per-driver overrides

`Driver.Generic`'s delegation is a default, not a contract every driver must
accept as-is. Existing drivers override individual callbacks when the generic
dispatch through `Spec` isn't right:

* **Session-scoped `send_keys`** — `ChromeCDP`/`ChromeBiDi` both override
  `send_keys/2` for a `%Session{}` (real keystrokes via the wire protocol);
  the `%Element{}` clause still falls through to Generic. `LightpandaCDP`
  overrides it to return `{:error, :not_implemented}` since Lightpanda has
  no session-level input synthesis.
* **Unsupported capabilities** — when your vendor genuinely can't do
  something (`LightpandaCDP.grant_permissions/2`, `ChromeBiDi.grant_permissions/2`),
  override the callback to `raise(SurfBoard.DriverError.not_supported(name, __MODULE__))`
  rather than let a shared dispatch silently no-op. This matters most when
  your driver shares a `wire_protocol` module with another driver (see next
  point) — a shared module can't tell which driver is calling it, so an
  unsupported-capability check has to live in the driver, not the protocol
  client.
* **`touch_scroll`** — there's no shared `Windows`/`Frames`-style behaviour
  for this; it's a bare 3-arity function on `%Spec{}` because the three
  existing implementations (CDP's `Input.synthesizeScrollGesture`, BiDi's JS
  `scrollBy` workaround, Lightpanda's `nil`/no-op) don't share enough to
  justify one. Write your own `touch_scroll_impl/3` unless an existing one's
  approach genuinely fits your vendor.

## A note on sharing a protocol client across drivers

`SurfBoard.Drivers.CDP.Client` is the **same module**, not a copy, for both
`ChromeCDP` and `LightpandaCDP` — both point `wire_protocol:` at it. This is
correct and intentional: they're the same protocol, so there's one
implementation. The cost is that `function_exported?`/dispatch tricks keyed
off `spec.wire_protocol` can't distinguish the two drivers, because it's
the same module either way — this bit `grant_permissions/2` and (in an
earlier, since-reverted feature) `open_stream/1`. If you're reusing an
existing protocol client and your vendor can't support something the other
sharer(s) can, override it directly on your driver module (see
[Per-driver overrides](#per-driver-overrides)) rather than trying to gate it
inside the shared client.

## Adding a new protocol (or a second BiDi vendor)

If you're bringing a vendor that speaks BiDi natively — Firefox, for
instance — check first whether `SurfBoard.Drivers.ChromeBiDi.{Client,Wire,
Commands,ResponseParser}` is actually protocol-generic already (BiDi is a
W3C spec; Chrome's implementation shouldn't need special-casing in the
command/event layer) versus whether `chromium-bidi` — the Node sidecar
`SurfBoard.Drivers.ChromeBiDi.Server` spawns to get Chrome speaking BiDi at
all — has leaked into the client code. A vendor with *native* BiDi support
doesn't need that sidecar; it needs a `Server`-equivalent that launches the
vendor's browser directly and hands back its WebSocket URL. If the protocol
client itself turns out to be Chrome-clean, the right move is extracting it
to a vendor-neutral `Drivers.BiDi.*` namespace shared by both
`Drivers.ChromeBiDi` and your new driver, rather than duplicating it.

Adding a genuinely new wire protocol (neither CDP nor BiDi) is a much bigger
undertaking — you'd be writing the `Drivers.<Protocol>.*` analogue of
everything under `Drivers.CDP.*`, including a new `SurfBoard.WireProtocol`
implementation (`lib/surf_board/wire_protocol.ex` documents the full
callback contract `Browser`/`Element`/`Orchestrator` dispatch through) and
likely a new `Wire.<Protocol>` event decoder alongside the existing
`Drivers.CDP.Wire`/`Drivers.ChromeBiDi.Wire`. There's no shortcut for this
one — read both existing protocol implementations in full before starting.

## Verifying a new driver

There's no substitute for the real integration suite here — a driver that
compiles cleanly can still hang or silently misbehave against a real
browser (this project's history includes more than one bug that was
invisible to `mix compile` and only surfaced under `SURF_BOARD_INTEGRATION=1
mix test`). At minimum, run your driver through:

* `mix test --exclude integration` — the unit suite shouldn't need a
  browser at all; if your changes broke it, something leaked into a path
  that runs without one.
* `SURF_BOARD_INTEGRATION=1 mix test` — the full suite against real
  browsers. Run it more than once; a transport-layer bug is exactly the
  kind of thing that shows up as intermittent flakiness under load, not a
  clean failure.
* A LiveView smoke test if you're claiming `live_view_aware?` support —
  `await_patch/2` and the bootstrap channel (`__surfboard` binding / BiDi's
  `script.message` channel) are easy to get subtly wrong in a way unit
  tests won't catch.
