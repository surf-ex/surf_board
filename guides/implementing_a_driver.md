# Implementing a Driver

A driver is what makes a specific browser drivable through the `SurfBoard.Browser`/
`SurfBoard.Element`/`SurfBoard.Query` API. This guide is for adding a new one —
a new vendor (e.g. Firefox), a new wire protocol, or a new connection strategy for
an existing vendor.

## The two dimensions

This code varies along exactly two independent axes, and the two top-level
namespaces are split along that line:

* **Protocol** (`lib/surf_board/clients/`) — the wire format and command
  surface: CDP or WebDriver BiDi today. Lives under `SurfBoard.Clients.CDP.*` /
  `SurfBoard.Clients.BiDi.*`. This is vendor-neutral protocol code — command
  building, response parsing, dialog/window/frame handling, event decoding —
  with no launcher, process, or connection-ownership logic in it (the BiDi
  namespace being Chrome-free today is somewhat aspirational still — see
  [Adding a new protocol](#adding-a-new-protocol-or-a-second-bidi-vendor)
  if you're bringing a second BiDi vendor and need to confirm it).
* **Driver** (`lib/surf_board/drivers/`) — one vendor's whole strategy for
  getting and holding a live connection: which browser process, how many
  sessions share one socket, whether the socket and the session's domain
  state live in the same process or two. This is *one* decision made once by
  the driver's author, not three independently pluggable things —
  `SurfBoard.Drivers.ChromeCDP`, `SurfBoard.Drivers.ChromeBiDi`, and
  `SurfBoard.Drivers.LightpandaCDP` each hardcode their own transport
  strategy rather than selecting one through a generic interface, because
  nothing actually needs to swap strategies under one driver at runtime. A
  driver module owns lifecycle (`start_session/1`/`end_session/1`) and
  whatever process supervision its connection strategy needs — e.g.
  `Drivers.ChromeBiDi.Server` (the chromium-bidi Node sidecar) and
  `Drivers.ChromeBiDi.WebSocketClient` (the per-session WS connection
  GenServer) — but never protocol semantics: method names, param shapes,
  response parsing all live in `Clients`, not here.

A driver picks one protocol client and supplies its own connection strategy.
That's the whole shape: `driver = client + strategy`.

Underneath both, `SurfBoard.Transport.WireSocket` is shared low-level Mint
WebSocket plumbing (connect, upgrade, encode/decode, frame dispatch) — it knows
neither the protocol nor the driver, and you generally don't need to touch it.

## Launchers: started instances of a strategy

`SurfBoard.Launcher` is the started, independently-addressable instance of
one `Transport.Strategy` + its `Config` — the thing a session actually
references (`start_session(launcher: ...)`), rather than a driver resolving
an implicit, hardcoded connection at compile time. A driver's own
`init/1` starts one **default** launcher the same way it always has (so
`SurfBoard.start_session(driver: :chrome_cdp)` with no other opts keeps
working exactly as before) — but a caller can also start their own
`Launcher` and pass it explicitly:

```elixir
# app boot — the default launcher is used implicitly, unchanged from before
SurfBoard.start_session(driver: :chrome_cdp)

# a test suite starts and owns a second, independent launcher alongside it
{:ok, _} = SurfBoard.Launcher.start_link(
  name: MyApp.TestChrome,
  strategy: SurfBoard.Transport.Strategy.SharedWS,
  config: %SurfBoard.Transport.Strategy.SharedWS.Config{
    resolve_ws_url: fn -> SurfBoard.Drivers.ChromeCDP.Server.ws_url(some_server) end
  }
)

SurfBoard.start_session(driver: :chrome_cdp, launcher: MyApp.TestChrome)
```

Both launchers are alive in the same BEAM at once, each with its own
independent state — e.g. an application connecting to a remote Chrome
over `ws://` in production, while its own test suite launches and owns a
second, local Chrome, without either interfering with the other. This is
what actually makes a strategy swappable without its callers caring
whether it's single- or multi-process: two `SharedWS` launchers never
share a connection just because they're the same strategy.

Every strategy gets wrapped this way, even ones with nothing to cache
(`IsolatedProcess`, `PerSession`, `BiDi` don't hold persistent connection
state — see their moduledocs) — only `SharedWS` needs the launcher's own
state today (the shared ws_pid, lazily connected and cached via
`Launcher.get_or_compute/3`, scoped to *that* launcher instance rather
than a global). Keeping the API uniform means a currently-stateless
strategy could grow real shared state later with no change to how
callers reference it. `LightpandaCDP`'s `:isolated`/`:external` opts (and
`ChromeBiDi`'s default path) build a transient, unnamed launcher per
`start_session/1` call instead of a driver-owned default one, precisely
because their strategies cache nothing — there's no state worth keeping
around past that one session's startup.

## What a driver module actually does

`SurfBoard.Driver` is a 2-callback behaviour: `start_session/1` and
`end_session/1`. That's the whole job — a driver module is lifecycle only.
Every browser capability (`visit/2`, `click/1`, `find_elements/2`, `cookies/1`,
`focus_frame/2`, ...) is dispatched by `SurfBoard.Browser`/`SurfBoard.Element`
calling `session.driver_spec` — your `%SurfBoard.DriverSpec{}` — directly.
There's no per-driver module standing between them and your Spec; `Browser`/
`Element` never call `session.driver.<capability>`. All you write is:

* `start_session/1` and `end_session/1` — vendor-specific connection setup and
  teardown.
* A `%SurfBoard.DriverSpec{}` naming which existing (or new) protocol/dialogs/
  windows/frames/grant_permissions/send_keys_session/touch_scroll
  implementations this driver uses. Each field is a module (or, for
  `touch_scroll`, a function) that `Browser`/`Element` call directly — see
  [Capability dimensions](#capability-dimensions) for when to reuse an
  existing one vs. write a new one.

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

     @behaviour SurfBoard.Driver

     alias SurfBoard.DriverSpec, as: Spec

     @driver_spec %Spec{
       browser: Browser.YourVendor,
       wire_protocol: SurfBoard.Clients.CDP.Client, # or Clients.BiDi.Client
       dialogs: SurfBoard.Clients.CDP.Dialogs,  # reuse, or write your own — see below
       windows: SurfBoard.Clients.CDP.Windows,  # reuse, or write your own
       frames: SurfBoard.Clients.CDP.Frames,    # reuse, or write your own
       grant_permissions: SurfBoard.Clients.CDP.Client, # reuse, or Permissions.Unsupported
       send_keys_session: SurfBoard.Clients.CDP.Client, # reuse, or SendKeysSession.Unsupported
       touch_scroll: &__MODULE__.touch_scroll_impl/3,
       log_check_interactions?: true
     }

     def driver_spec, do: @driver_spec

     @default_launcher_name __MODULE__.DefaultLauncher

     # ----- Supervisor: how your browser process / connection comes up -----
     def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, :ok, opts)

     @impl Supervisor
     def init(_) do
       # Start whatever process(es) your connection strategy needs, plus
       # one default SurfBoard.Launcher wrapping your strategy's Config —
       # nothing else if you connect directly with nothing to launch.
       # Mirror ChromeCDP/LightpandaCDP's `init/1` for the shape.
       children = [
         {SurfBoard.Launcher,
          name: @default_launcher_name,
          strategy: SurfBoard.Transport.Strategy.SharedWS,
          config: %SurfBoard.Transport.Strategy.SharedWS.Config{
            resolve_ws_url: fn -> :your_server.ws_url(:your_server_name) end
          }}
       ]

       Supervisor.init(children, strategy: :one_for_one)
     end

     # ----- Session lifecycle -----
     @impl SurfBoard.Driver
     def start_session(opts \\ []) do
       launcher = Keyword.get(opts, :launcher, @default_launcher_name)

       # Build a template %SurfBoard.Session{driver: __MODULE__, driver_spec:
       # @driver_spec, capabilities: ..., ...} — leave bidi_pid/browsing_context
       # unset, your chosen Transport.Strategy fills those in — and hand it
       # to your strategy's start_session/1 alongside the :launcher (the
       # default one above, or opts[:launcher] if the caller passed their
       # own independently-started one):
       #
       #   Transport.Strategy.SharedWS.start_session(
       #     launcher: launcher,
       #     session_struct: template,
       #     owner: Keyword.get(opts, :owner, self())
       #   )
       #
       # Every SurfBoard.Transport.Strategy implementation shares this
       # `start_session(opts) :: {:ok, Session.t()} | {:error, term}`
       # contract (see "Own your connection" below and
       # [Launchers](#launchers-started-instances-of-a-strategy)) — opts
       # only ever carries :session_struct, :launcher, and :owner, never
       # bare connection details, so reusing a strategy is just picking
       # the module and starting the right kind of launcher.
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

3. **If no existing `Transport.Strategy` fits, write a new one, owning your
   connection via `SurfBoard.Transport.Actor`.** (If one of the existing
   strategies fits — the common case — skip straight to step 4; you don't
   need anything in this step.) Every driver's session runs on the same
   actor — one generic GenServer speaking
   `SurfBoard.Transport.Protocol` (the message contract
   `SurfBoard.Clients.CDP.Client` / `SurfBoard.Clients.BiDi.Client`
   call into — `cdp_send`, `subscribe`, `await_page_load`, `register_find`,
   `push_frame`, ...; see `lib/surf_board/transport/protocol.ex` for the
   full message list). You don't write a new actor module; you build a
   `%SurfBoard.Transport.Actor.Config{}` describing your driver's connection
   strategy and pass it to `Transport.Actor.start_link/1`:

   ```elixir
   %Transport.Actor.Config{
     socket: {:fused, ws_url} | {:shared, socket_pid},
     send: :inline | :spawn_link,
     load: :buffer | :wake_once,
     subscribe: :passive | :active,
     wire: YourProtocolWireModule
   }
   ```

   * **`socket`** — `{:fused, ws_url}` if this session gets its own socket
     and you want the actor to own the `WireSocket` connection directly, no
     separate process, no extra hop (Lightpanda's model — see
     `Transport.Strategy.PerSession.start_session/1`). `{:shared, socket_pid}`
     if the socket is (or might be) shared with other sessions, or already
     started by something else — pass the pid of a `SurfBoard.WebSocket` or
     your protocol's equivalent (Chrome CDP's `Strategy.SharedWS`/
     `Strategy.IsolatedProcess` both use this; see
     `Transport.start_session_from/3`). `{:shared, _}` is the only option
     when a socket genuinely serves more than one session, since a fused
     actor's mailbox belongs to exactly one session.
   * **`send`** — `:inline` if your protocol client replies asynchronously
     without blocking on the wire round-trip (true of both `WireSocket` and
     `SurfBoard.WebSocket` — this is what CDP uses). `:spawn_link` if your
     client's send function is itself a blocking `GenServer.call` (BiDi's
     `WebSocketClient.send_command/4` is) — otherwise a slow call would
     stall the actor's mailbox and delay every concurrent event it needs to
     process. See `Transport.Strategy.BiDi.start_session/1` for the template.
   * **`load`** — `:buffer` if your protocol's load-milestone event can
     fire more than once and should persist until consumed (CDP's
     `Page.lifecycleEvent`); `:wake_once` if it fires exactly once per
     navigation and a buffered hit must be dropped after use (BiDi's
     `browsingContext.load`). This selects between
     `SurfBoard.Transport.Common`'s `record_load_milestone/3` and
     `record_load_or_wake_once/3` on the write side, and controls
     `await_page_load/6`'s `drop_on_consume?` on the read side.
   * **`subscribe`** — `:passive` if your protocol emits events for
     whatever domains/methods you've already enabled, with no separate
     wire-level subscribe step (CDP). `:active` if the server needs to be
     told which events to emit at all (BiDi's `session.subscribe`).
   * **`wire`** — your protocol's `Wire.handle_event/3`-shaped event
     decoder module (`SurfBoard.Clients.CDP.Wire` or
     `SurfBoard.Clients.BiDi.Wire` today).

   If your vendor speaks an existing protocol (CDP or BiDi) over a
   connection shape that matches one of the three existing configs exactly,
   you don't need to design a new config at all — reuse the matching one.
   `Transport.Common` (the shared find/load/page-ready/frame-stack state
   machine `Transport.Actor` runs on) needs no changes either way; it
   operates purely on the actor's state fields, not on your config.

4. **Reuse capability dimension modules where your vendor's behavior genuinely
   matches an existing one — see [Capability dimensions](#capability-dimensions).**

5. **Register the driver.** Add your driver to `driver_module_for/1` in
   `lib/surf_board.ex` so `SurfBoard.start_session(driver: :your_driver)`
   resolves to your module.

## Capability dimensions

Every `%Spec{}` field beyond `wire_protocol` exists because at least two
drivers need genuinely different behavior for that capability. When your
vendor's behavior matches an existing driver's exactly, point at the same
module — don't copy it. When it doesn't, write a new implementation and
point your Spec at that instead. There is no per-driver override mechanism
any more (there used to be — see below); every capability lives in exactly
one place: the module your Spec names.

* **`dialogs` / `windows` / `frames`** — each implements a small behaviour
  (`SurfBoard.Dialogs`, `SurfBoard.Windows`, `SurfBoard.Frames`) for one
  *protocol*, not one vendor: `SurfBoard.Clients.CDP.{Dialogs,Windows,Frames}`
  is CDP's dialog/window/frame handling, full stop — it lives under
  `Clients.CDP`, vendor-neutral, even though today only `ChromeCDP` points at
  it. Lightpanda also speaks CDP, but its engine doesn't implement the
  `Page.javascriptDialogOpening`/`Target.*`/frame-focus surface these
  modules use, so it points `dialogs`/`windows`/`frames` at the shared
  fallbacks instead (`SurfBoard.Dialogs.Unsupported`, `SurfBoard.Windows.Single`,
  `SurfBoard.Frames.Unsupported`) — that's a vendor's *coverage* of the
  protocol falling short, not a different protocol. If your driver speaks
  CDP and actually implements this part of it, point at
  `SurfBoard.Clients.CDP.{Dialogs,Windows,Frames}` directly rather than
  writing a new implementation; only write your own if your vendor's
  protocol genuinely differs here (e.g. a real BiDi vendor needs
  `Clients.BiDi.{Dialogs,Windows,Frames}`'s BiDi equivalents, not
  these CDP ones).
* **`grant_permissions`** — implements `SurfBoard.Permissions`. Point at your
  `wire_protocol` module directly if it has a real implementation (e.g.
  `SurfBoard.Clients.CDP.Client`, which both `ChromeCDP` and `LightpandaCDP`
  could point at — but only `ChromeCDP` does, because Lightpanda's browser
  engine doesn't actually support it). Otherwise point at
  `SurfBoard.Permissions.Unsupported`, which raises
  `SurfBoard.DriverError.not_supported/2` rather than silently no-opping — a
  caller granting camera/mic access needs to know it didn't happen.
* **`send_keys_session`** — implements `SurfBoard.SendKeysSession` (session-
  scoped key dispatch; element-scoped `send_keys` is a plain `wire_protocol`
  call and needs no separate dimension). Same reuse-or-`Unsupported` choice
  as `grant_permissions`.
* **`touch_scroll`** — there's no shared behaviour for this; it's a bare
  3-arity function on `%Spec{}` because the three existing implementations
  (CDP's `Input.synthesizeScrollGesture`, BiDi's JS `scrollBy` workaround,
  Lightpanda's `nil`/no-op) don't share enough to justify one. Write your
  own `touch_scroll_impl/3` unless an existing one's approach genuinely fits
  your vendor.

### Why `grant_permissions`/`send_keys_session` are separate dimensions,
### not just `wire_protocol` calls

`SurfBoard.Clients.CDP.Client` is the **same module**, not a copy, for both
`ChromeCDP` and `LightpandaCDP` — both point `wire_protocol:` at it, because
they're the same protocol. That sharing means a capability check keyed off
`spec.wire_protocol` (e.g. `function_exported?/3`, or just calling it
unconditionally) can't distinguish the two drivers — it's the same module
either way. `grant_permissions` and `send_keys_session` both hit this for
real: `Clients.CDP.Client` has working implementations of both, but
Lightpanda's browser engine doesn't actually support either one. The fix
isn't a per-driver override (that used to exist, via a `Driver.Generic`
dispatch layer that's since been removed) — it's giving the capability its
own `%Spec{}` field, so each driver's Spec states directly whether it
supports the capability, independent of which `wire_protocol` it shares.
If you add a new capability that might have this same shared-client problem,
give it its own Spec field from the start rather than dispatching through
`wire_protocol`.

## Adding a new protocol (or a second BiDi vendor)

If you're bringing a vendor that speaks BiDi natively — Firefox, for
instance — check first whether `SurfBoard.Clients.BiDi.{Client,Wire,
Commands,ResponseParser}` is actually protocol-generic already (BiDi is a
W3C spec; it lives under the vendor-neutral `Clients.BiDi` namespace on the
assumption that it is) versus whether `chromium-bidi` — the Node sidecar
`SurfBoard.Drivers.ChromeBiDi.Server` spawns to get Chrome speaking BiDi at
all — has leaked into the client code despite that. A vendor with *native*
BiDi support doesn't need that sidecar; it needs a `Server`-equivalent that
launches the vendor's browser directly and hands back its WebSocket URL. If
the protocol client turns out to have Chrome-specific assumptions baked in
after all, fix those in place — `Clients.BiDi` is meant to be shared by
`Drivers.ChromeBiDi` and your new driver, not duplicated per vendor.

Adding a genuinely new wire protocol (neither CDP nor BiDi) is a much bigger
undertaking — you'd be writing the `Clients.<Protocol>.*` analogue of
everything under `Clients.CDP.*`, including a new `SurfBoard.WireProtocol`
implementation (`lib/surf_board/wire_protocol.ex` documents the full
callback contract `Browser`/`Element` dispatch through directly) and
likely a new `Wire.<Protocol>` event decoder alongside the existing
`Clients.CDP.Wire`/`Clients.BiDi.Wire`. There's no shortcut for this
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
