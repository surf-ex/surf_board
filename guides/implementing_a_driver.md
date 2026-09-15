# Implementing a Driver

A **driver** is `SurfBoard.Driver.<Name>` — one (vendor, protocol,
connection mode) combination (`Driver.SharedChromeCDP`,
`Driver.ExternalChromeCDP`, `Driver.ChromeBiDi`,
`Driver.SharedLightpanda`, `Driver.IsolatedLightpanda`,
`Driver.ExternalLightpanda`): a self-contained OTP module owning
everything needed to get a session running against it — its own
supervision (if it needs any), its own connection-handling, its own
capability-dispatch `Spec`, and its own `start_session` function.
There's no shared behaviour to implement and no registration step: a
driver is called directly, by module name, everywhere.

**Connection mode is part of a driver's identity, not a runtime
option.** ChromeCDP and Lightpanda each support more than one way to
get connected (spawn-and-own vs. connect-to-existing; for Lightpanda,
also a fresh-process-per-session mode) — earlier versions of this
codebase modeled that as one driver module per vendor with a
`:connection` opt branching internally. That got split apart: nothing
downstream of "I have a connection" (`spec/0`, the session template,
post-connection setup) differs between modes, so those parts are
duplicated verbatim across the mode-specific modules rather than
shared — but everything *about* acquiring the connection (what fails,
what gets supervised, what config is needed) does differ enough that
folding modes into one module with a branch was hiding real
differences behind a shared name. If your new driver has more than one
real way to connect, give each its own module rather than a
`:connection`-style option — see
[One driver per connection mode](#one-driver-per-connection-mode)
before you start.

This guide is for adding a new driver — a new vendor (e.g. Firefox), a
new wire protocol, or a new connection mode for an existing vendor.

## The two layers underneath a driver

Only two things are genuinely shared across drivers — everything else
lives inside the driver module itself:

* **Protocol** (`lib/surf_board/clients/`) — the wire format and command
  surface: CDP or WebDriver BiDi today. Lives under `SurfBoard.Clients.CDP.*` /
  `SurfBoard.Clients.BiDi.*`. This is vendor-neutral protocol code — command
  building, response parsing, dialog/window/frame handling, event decoding.
  `Clients.CDP.Client` is the clearest proof this layer earns its keep: every
  CDP-speaking driver (`SharedChromeCDP`, `ExternalChromeCDP`,
  `SharedLightpanda`, `IsolatedLightpanda`, `ExternalLightpanda`) calls the
  exact same module, unmodified — real reuse, not just shared shape.
* **`SurfBoard.Transport.Actor`/`Protocol`/`Common`/`WireSocket`**
  (`lib/surf_board/transport/`) — the low-level actor/wire machinery a
  driver's own connection-handling code builds on: a generic GenServer
  speaking a fixed message contract (`cdp_send`, `subscribe`,
  `await_page_load`, `register_find`, `push_frame`, ...; see
  `lib/surf_board/transport/protocol.ex` for the full list), fed a
  `%Transport.Actor.Config{}` your driver constructs. Protocol-agnostic;
  it knows neither CDP nor BiDi nor any vendor.

Everything else — how a driver gets its connection (spawn a process?
connect to an existing one? one shared WebSocket or one per session?),
how it supervises what it owns, how it builds a session template, what
runs after the connection comes up — lives directly in that driver's own
module, duplicated across driver modules rather than shared when it
differs, even where the duplication is substantial. Earlier versions of
this codebase had a `Strategy.*` layer between drivers and
`Transport.Actor` (`Strategy.SharedWS`, `Strategy.PerSession`,
`Strategy.IsolatedProcess`, `Strategy.BiDi`), a generic `Launcher`
process wrapping "strategy + config + hooks", and — one layer up — a
single driver module per vendor with an internal `:connection` opt
picking between modes. All three were removed: nothing in this codebase
ever paired one driver's connection logic with another's (each strategy
had exactly one real caller), and folding several connection modes into
one module hid genuinely different failure modes and config behind a
shared name. A shared interface — or a shared module — with no second
real implementor isn't reuse, it's just an extra hop or a false
merge; read `lib/surf_board/driver/shared_chrome_cdp.ex`,
`external_chrome_cdp.ex`, `chrome_bidi.ex`, `shared_lightpanda.ex`,
`isolated_lightpanda.ex`, and `external_lightpanda.ex` directly to see
what each driver's connection-handling actually looks like now —
they're a genuinely useful reference for how different each one's real
needs are (`SharedChromeCDP` caches one shared WebSocket in its own
GenServer state; `SharedLightpanda` caches nothing at all and
re-resolves a URL per call; `ChromeBiDi` caches nothing either and does
one POST-then-WS per session; `IsolatedLightpanda`/`ExternalLightpanda`
spawn or dial fresh every single session).

Underneath both, `SurfBoard.Transport.WireSocket` is shared low-level Mint
WebSocket plumbing (connect, upgrade, encode/decode, frame dispatch) — it
knows neither the protocol nor the driver, and you generally don't need to
touch it.

## What a driver actually needs to expose

There's no behaviour to implement, so "needs to expose" here means
*conventions other code relies on by calling them directly* — get these
names right and your driver plugs into `Browser`/`Element` and the test
suite the same way the other three do.

* **`spec/0`** — returns a `%SurfBoard.Driver.Spec{}` naming which
  protocol/dialogs/windows/frames/grant_permissions/send_keys_session/touch_scroll
  implementations this driver uses. Every browser capability
  (`visit/2`, `click/1`, `find_elements/2`, `cookies/1`,
  `focus_frame/2`, ...) is dispatched by `SurfBoard.Browser`/
  `SurfBoard.Element` calling `session.spec` — your `Spec` — directly;
  there's no layer between them and it. See
  [Capability dimensions](#capability-dimensions) for when to reuse an
  existing implementation vs. write a new one. Compute it in a plain
  function, not a module attribute — see `Driver.SharedChromeCDP.spec/0`'s
  comment for why (a module attribute calling another module's
  function at compile time creates an unnecessary `mix xref graph`
  compile-time edge).
* **`start_session/1`** (or `/2`, if your driver supports more than one
  named instance — see below) — does everything: acquires a connection,
  builds a `%SurfBoard.Session{}`, brings up the `Transport.Actor`, runs
  any post-connection setup (UA override, window size, log-event
  subscription, ...), returns `{:ok, session} | {:error, term}`. This
  is genuinely one function per driver, not shared logic, because
  connection acquisition differs too much underneath — compare
  `Driver.SharedChromeCDP.start_session/2` (fetch a cached shared
  ws_pid, then per-session BrowserContext/Target/attach) with
  `Driver.ChromeBiDi.start_session/1` (POST /session, open a fresh WS,
  no caching at all). Also stash `:base_url`/`:max_wait_time` from opts
  onto `session.session_opts` before returning — every driver does this
  identically (see any driver's `post_start/2` for the exact two lines);
  it's small enough that duplicating it across drivers is the honest
  choice over inventing a shared helper for two lines of code.
* **`validate/0`** — a plain function (no callback contract to satisfy),
  checking whether this driver can actually work — a binary is
  installed, a config value is set — without starting anything. Return
  `:ok`, or `{:error, %SurfBoard.DependencyError{}}` with a clear message
  (e.g. `"Chrome not found. Run `mix surf_board.install`"`). Call it
  yourself, wherever it makes sense for your driver (a supervisor's
  `init/1`, or before spawning a process) — nothing calls it generically
  for you.
* **`default_child_spec/0`** — a child spec for this driver's default,
  shared instance, meant to be started once by whoever owns your
  supervision tree (an application, or a test suite's `test_helper.exs`
  — see `integration_test/support/driver_supervisor.ex` for the pattern
  this project's own test suite uses). Drivers no longer start anything
  lazily on their own; nothing about loading this library depends on
  Chrome/Lightpanda being installed until something actually starts a
  child spec. Return `nil` if there's genuinely nothing to start (see
  `Driver.SharedLightpanda.default_child_spec/0` — returns `nil` when
  the optional `lightpanda` package isn't loaded). Skip this function
  entirely if your driver has no persistent instance at all — see
  `Driver.IsolatedLightpanda`/`Driver.ExternalLightpanda`, which spawn
  or dial fresh every session and have nothing for a supervisor to
  hold ahead of time.

A driver doesn't own session teardown either — `SurfBoard.end_session/1`
calls `Transport.Protocol.stop/1` directly, the same for every driver, so
there's no `end_session` convention to implement.

## One driver per connection mode

If your vendor has more than one real way to get connected — spawn a
process vs. connect to one that's already running, cache a shared
connection vs. get a fresh one per session — that's more than one
driver, not one driver with a `:connection` opt. Two symptoms that
tell you the modes are different enough to split, both true for every
mode split in this codebase today:

* **They fail differently.** "Chrome isn't installed" (spawn mode)
  and "no remote_url configured" (connect mode) are different
  `validate/0` outcomes with different fixes — collapsing them into
  one `validate/0` with a `case` just relocates that difference
  instead of removing it.
* **They need different things supervised (or nothing at all).**
  `Driver.SharedChromeCDP` supervises a Chrome process and a worker
  holding a cached connection; `Driver.ExternalChromeCDP` supervises
  only the worker (nothing to spawn); `Driver.IsolatedLightpanda`
  supervises nothing persistent at all (every session spawns and owns
  its own binary). A `default_child_spec/0` that sometimes returns a
  two-child tree, sometimes one child, and sometimes `nil` depending
  on a runtime option is a sign the underlying thing being supervised
  isn't actually one shape.

What *is* shared across your modes (the capability `Spec`, the session
template, post-connection setup) still won't have a home to live in
once you split — duplicate it into each mode's module rather than
inventing a shared module for it (see the top of this guide for why:
nothing in this codebase has ever had a second real implementor for
that kind of shared connection-handling module, and a shared module
with one real caller is worse than duplication, not better).

## Adding a driver for a vendor that already has a protocol client

This is the common case: a new way to run/connect-to a browser that
already speaks CDP or BiDi (e.g. a different Chromium-based browser, or
a new connection mode for an existing vendor).

1. **Create `lib/surf_board/driver/<your_driver>.ex`** — one file per
   connection mode, not one file per vendor (see
   [One driver per connection mode](#one-driver-per-connection-mode)
   above). `Driver.SharedLightpanda` shows the "cache nothing, resolve
   a URL fresh against a persistent shared process" pattern.
   `Driver.SharedChromeCDP` shows the "cache one shared connection
   across sessions" pattern. `Driver.ChromeBiDi` shows the "cache
   nothing, one POST + one WS per session, nothing persistent to
   supervise beyond a sidecar" pattern. `Driver.IsolatedLightpanda`/
   `Driver.ExternalLightpanda` show the "nothing persistent at all,
   spawn or dial fresh every session" pattern. A minimal skeleton:

   ```elixir
   defmodule SurfBoard.Driver.YourDriver do
     alias SurfBoard.Driver.Spec
     alias SurfBoard.Clients.CDP.Client, as: CDPClient

     # Start from your wire_protocol client's own defaults and override
     # only the points where your vendor's engine genuinely diverges —
     # see CDPClient.default_strategies/0 (or Clients.BiDi.Client's) for
     # what "genuinely diverges" looks like in practice (Lightpanda
     # overrides every one of them; most new CDP-based drivers override
     # none, or just grant_permissions).
     def spec do
       struct!(
         Spec,
         Map.merge(CDPClient.default_strategies(), %{
           wire_protocol: CDPClient, # or Clients.BiDi.Client
           touch_scroll: &__MODULE__.touch_scroll_impl/3,
           log_check_interactions?: true
           # dialogs/windows/frames/grant_permissions/send_keys_session
           # only need to appear here if your vendor's engine can't do
           # what its wire protocol normally supports — set
           # grant_permissions/send_keys_session to nil, or
           # dialogs/windows/frames to a real "unsupported" module
           # (see Capability dimensions below for why those three
           # always need a real module rather than nil).
         })
       )
     end

     @doc """
     A child spec for this driver's default instance, meant to be
     started once, under whatever supervisor the application chooses.
     """
     def default_child_spec do
       # Whatever process(es) your connection needs — a Supervisor
       # wrapping them, or a bare {__MODULE__, opts} child spec if your
       # driver itself is the process (see Driver.SharedChromeCDP's own
       # `Supervised` submodule and `start_worker/3` for the
       # "I am a GenServer, here's my child spec" shape, or
       # Driver.ChromeBiDi's `Supervised` for the "I supervise a sidecar,
       # I hold no state myself" shape). Omit this function entirely if
       # your driver has nothing persistent to hold (see
       # Driver.IsolatedLightpanda/Driver.ExternalLightpanda).
       {__MODULE__, name: default_name()}
     end

     @doc false
     def default_name, do: __MODULE__.Default

     @doc """
     Checks whether this driver can actually work, without starting
     anything.
     """
     def validate do
       if your_dependency_available?() do
         :ok
       else
         {:error, SurfBoard.DependencyError.exception("YourVendor not found. ...")}
       end
     end

     # ----- Session lifecycle -----

     def start_session(opts \\ []) do
       # Acquire a connection (however your driver does that), build a
       # %SurfBoard.Session{} template, bring up Transport.Actor (see
       # step 3 below if no existing pattern fits), run post-connection
       # setup, stash session_opts, return {:ok, session}.
       template = build_template(opts)

       # ... acquire connection, call Transport.Actor.start_link/1 ...

       post_start(session, opts)
     end

     defp build_template(opts) do
       %SurfBoard.Session{
         spec_module: __MODULE__,
         spec: spec(),
         live_view_aware?: Keyword.get(opts, :live_view_aware, false),
         capabilities: Keyword.get(opts, :capabilities, %{})
         # ws_pid/browsing_context stay unset — your connection-handling
         # code fills those in as it comes up.
       }
     end

     defp post_start(session, opts) do
       # Whatever has to run after the connection comes up — UA
       # override, window size, log subscriptions, ...

       session_opts = Keyword.take(opts, [:base_url, :max_wait_time])
       {:ok, %{session | session_opts: session_opts}}
     end

     # No end_session/1 to write — every driver's was identical, so
     # SurfBoard.end_session/1 calls Transport.Protocol.stop/1 directly.
   end
   ```

2. **Add a vendor marker** in `lib/surf_board/browser/your_vendor.ex` — an empty
   module (see `browser/chrome.ex`, `browser/lightpanda.ex`). It's a tag, not a
   behaviour; nothing dispatches on it today, but it's how a session records
   which vendor it's driving.

3. **Bring up your connection via `SurfBoard.Transport.Actor`.** Every
   driver's session runs on the same actor — one generic GenServer
   speaking `SurfBoard.Transport.Protocol` (the message contract
   `SurfBoard.Clients.CDP.Client` / `SurfBoard.Clients.BiDi.Client`
   call into — `cdp_send`, `subscribe`, `await_page_load`,
   `register_find`, `push_frame`, ...; see
   `lib/surf_board/transport/protocol.ex` for the full message list).
   You don't write a new actor module; you build a
   `%SurfBoard.Transport.Actor.Config{}` describing your connection and
   pass it to `Transport.Actor.start_link/1`:

   ```elixir
   %Transport.Actor.Config{
     socket: {:fused, ws_url} | {:remote, module, pid},
     load: :buffer | :wake_once,
     wire: YourProtocolWireModule
   }
   ```

   * **`socket`** — `{:fused, ws_url}` if this session gets its own
     socket and you want the actor to own the `WireSocket` connection
     directly, no separate process, no extra hop (see
     `Driver.SharedLightpanda`'s `start_session_from_ws/2`).
     `{:remote, module, pid}` if the socket is (or might be) shared with
     other sessions, or already started by something else — pass the
     module and pid of a `SurfBoard.Transport.WebSocket` or your
     protocol's equivalent (`Driver.SharedChromeCDP`'s connection path,
     and `Clients.CDP.SessionBringUp.start_session_from/3`, both use
     this shape).
   * **`load`** — `:buffer` if your protocol's load-milestone event can
     fire more than once and should persist until consumed (CDP's
     `Page.lifecycleEvent`); `:wake_once` if it fires exactly once per
     navigation and a buffered hit must be dropped after use (BiDi's
     `browsingContext.load`). This selects between
     `SurfBoard.Transport.Common`'s `record_load_milestone/3` and
     `record_load_or_wake_once/3` on the write side, and controls
     `await_page_load/6`'s `drop_on_consume?` on the read side.
   * **`wire`** — your protocol's `Wire.handle_event/3`-shaped event
     decoder module (`SurfBoard.Clients.CDP.Wire` or
     `SurfBoard.Clients.BiDi.Wire` today).

   If your vendor speaks CDP over a connection shape that matches
   `Driver.SharedChromeCDP`'s or `Driver.IsolatedLightpanda`'s, use
   `SurfBoard.Clients.CDP.SessionBringUp.start_session_from/3` directly
   rather than writing your own bring-up sequence — it's the one piece
   of CDP session bring-up genuinely shared between those drivers
   today (folds an "acquired connection" map into a session template,
   brings up the actor, and runs the standard page-lifecycle/bootstrap/
   frame-tracking init sequence). `Transport.Common` (the shared
   find/load/page-ready/frame-stack state machine `Transport.Actor` runs
   on) needs no changes regardless; it operates purely on the actor's
   state fields, not on your config.

4. **Reuse capability dimension modules where your vendor's behavior genuinely
   matches an existing one — see [Capability dimensions](#capability-dimensions).**

5. **Nothing to register.** There's no dispatch table to add your driver
   to — callers reference `SurfBoard.Driver.YourDriver` by module name
   directly. If your application (or test suite) wants config-driven
   driver selection (e.g. picking a driver from an env var), that
   atom-to-module mapping is yours to own, local to wherever you need
   it — see `integration_test/support/session_case.ex`'s own small
   `@drivers` map for the pattern this project's test suite uses.

## Capability dimensions

Every `%Spec{}` field beyond `wire_protocol` exists because at least two
drivers need genuinely different behavior for that capability. When your
vendor's behavior matches an existing driver's exactly, point at the same
module — don't copy it. When it doesn't, write a new implementation and
point your Spec at that instead. Every capability lives in exactly one
place: the module your Spec names.

* **`dialogs` / `windows` / `frames`** — each implements a small behaviour
  (`SurfBoard.Clients.Dialogs`, `SurfBoard.Clients.Windows`, `SurfBoard.Clients.Frames`) for one
  *protocol*, not one vendor: `SurfBoard.Clients.CDP.{Dialogs,Windows,Frames}`
  is CDP's dialog/window/frame handling, full stop — it lives under
  `Clients.CDP`, vendor-neutral, even though today only `ChromeCDP` points at
  it. Lightpanda also speaks CDP, but its engine doesn't implement the
  `Page.javascriptDialogOpening`/`Target.*`/frame-focus surface these
  modules use, so it points `dialogs`/`windows`/`frames` at the shared
  fallbacks instead (`SurfBoard.Clients.Dialogs.Unsupported`, `SurfBoard.Clients.Windows.Single`,
  `SurfBoard.Clients.Frames.Unsupported`) — that's a vendor's *coverage* of the
  protocol falling short, not a different protocol. If your driver speaks
  CDP and actually implements this part of it, point at
  `SurfBoard.Clients.CDP.{Dialogs,Windows,Frames}` directly rather than
  writing a new implementation; only write your own if your vendor's
  protocol genuinely differs here (e.g. a real BiDi vendor needs
  `Clients.BiDi.{Dialogs,Windows,Frames}`'s BiDi equivalents, not
  these CDP ones).
* **`grant_permissions`** — implements `SurfBoard.Clients.Permissions`, in its own
  `Clients.<protocol>.Permissions` module (e.g. `SurfBoard.Clients.CDP.Permissions`,
  which both `ChromeCDP` and `Lightpanda` could point at — but only
  `ChromeCDP` does, because Lightpanda's browser engine doesn't actually
  support it). Otherwise leave it `nil` — `Browser.Form.grant_permissions/2`
  itself raises `SurfBoard.DriverError.not_supported/2` on `nil` rather than
  silently no-opping (or calling through a dedicated stub module) — a
  caller granting camera/mic access needs to know it didn't happen.
* **`send_keys_session`** — implements `SurfBoard.Clients.SendKeysSession` (session-
  scoped key dispatch; element-scoped `send_keys` is a plain `wire_protocol`
  call and needs no separate dimension), in its own
  `Clients.<protocol>.SendKeysSession` module. Same reuse-or-`nil`
  choice as `grant_permissions`.
* **`touch_scroll`** — there's no shared behaviour for this; it's a bare
  3-arity function on `%Spec{}` because the three existing implementations
  (CDP's `Input.synthesizeScrollGesture`, BiDi's JS `scrollBy` workaround,
  Lightpanda's `nil`/no-op) don't share enough to justify one. Write your
  own `touch_scroll_impl/3` unless an existing one's approach genuinely fits
  your vendor.
* **`native_click_await?`** — a boolean picking between two click
  pipelines: `false` (Chrome CDP/BiDi) lets `Element.click`'s own
  classify + patch-await + navigation/page-ready logic handle it via the
  generic `find` + retry loop; `true` (Lightpanda) routes through
  `wire_protocol.click_aware/2` instead, a single native round trip that
  captures pre_page_id, classifies, clicks, and awaits page_ready in one
  call — Lightpanda's post-click re-find polling is slow enough that the
  generic pipeline costs real time per click. Set `true` only if your
  vendor has the same one-round-trip capability and the same reason to
  prefer it.

### Why `grant_permissions`/`send_keys_session` are separate dimensions,
### not just `wire_protocol` calls

`SurfBoard.Clients.CDP.Client` is the **same module**, not a copy, for both
`ChromeCDP` and `Lightpanda` — both point `wire_protocol:` at it, because
they're the same protocol. That sharing means a capability check keyed off
`spec.wire_protocol` (e.g. `function_exported?/3`, or just calling it
unconditionally) can't distinguish the two drivers — it's the same module
either way. `grant_permissions` and `send_keys_session` both hit this for
real: CDP has a working implementation of both, but Lightpanda's browser
engine doesn't actually support either one. The fix isn't a per-driver
override — it's giving the capability its own `%Spec{}` field, so each
driver's Spec states directly whether it supports the capability,
independent of which `wire_protocol` it shares.

Each of `grant_permissions`/`send_keys_session` also gets its own dedicated
module (`Clients.CDP.Permissions`, `Clients.CDP.SendKeysSession`,
`Clients.BiDi.SendKeysSession`, ...) rather than living as extra functions
on the already-large `Clients.<protocol>.Client` — same reasoning as
`dialogs`/`windows`/`frames` each getting their own file: it makes the
`%Spec{}` table read as a direct map from capability name to the module that
implements it, and keeps `Client` itself scoped to `WireProtocol`. If you add
a new capability that might have this same shared-client problem, give it
its own Spec field *and* its own file from the start, rather than
dispatching through `wire_protocol` or bolting it onto `Client`.

## Adding a new protocol (or a second BiDi vendor)

If you're bringing a vendor that speaks BiDi natively — Firefox, for
instance — check first whether `SurfBoard.Clients.BiDi.{Client,Wire,
Commands,ResponseParser}` is actually protocol-generic already (BiDi is a
W3C spec; it lives under the vendor-neutral `Clients.BiDi` namespace on the
assumption that it is) versus whether `chromium-bidi` — the Node sidecar
`SurfBoard.Driver.ChromeBiDi.Supervised` spawns to get Chrome speaking BiDi at
all — has leaked into the client code despite that. A vendor with *native*
BiDi support doesn't need that sidecar; it needs a `Server`-equivalent that
launches the vendor's browser directly and hands back its WebSocket URL. If
the protocol client turns out to have Chrome-specific assumptions baked in
after all, fix those in place — `Clients.BiDi` is meant to be shared by
`Driver.ChromeBiDi` and your new driver, not duplicated per vendor.

Adding a genuinely new wire protocol (neither CDP nor BiDi) is a much bigger
undertaking — you'd be writing the `Clients.<Protocol>.*` analogue of
everything under `Clients.CDP.*`, including a new `SurfBoard.Clients.WireProtocol`
implementation (`lib/surf_board/clients/wire_protocol.ex` documents the full
callback contract `Browser`/`Element` dispatch through directly) and
likely a new `Wire.<Protocol>` event decoder alongside the existing
`Clients.CDP.Wire`/`Clients.BiDi.Wire`. There's no shortcut for this
one — read both existing protocol implementations in full before starting.

## Verifying a new driver

There's no substitute for the real integration suite here — a driver that
compiles cleanly can still hang or silently misbehave against a real
browser (this project's history includes more than one bug that was
invisible to `mix compile` and only surfaced under `SURF_BOARD_INTEGRATION=1
mix test` — including, once, a driver whose "reuse the shared instance"
lookup silently fell through to a slower fallback path every time because
it checked the wrong process name; the unit and integration suites both
stayed green throughout since the fallback also worked correctly, it just
defeated the whole point of having a shared instance — watch your driver's
actual runtime logs, not just test pass/fail, when adding a mode meant to
reuse a resource). At minimum, run your driver through:

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
