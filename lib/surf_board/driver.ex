defmodule SurfBoard.Driver do
  @moduledoc false

  # A driver is one (vendor, protocol, process-model) combination —
  # ChromeCDP, ChromeBiDi, Lightpanda — as data (its capability-dispatch
  # `Spec`) plus everything needed to actually get a session running
  # against it: building/connecting to a browser process, building the
  # `%SurfBoard.Session{}` template, and finishing it off after the
  # transport strategy hands back a live session (UA override, window
  # size, log-event subscription, ...).
  #
  # This used to be two modules per vendor (`SpecModule.<Vendor>` +
  # `Launcher.<Vendor>`) that referenced each other in both directions —
  # the launcher hardcoded which spec module's capability table to stamp
  # onto a session, and the spec module reached into the launcher to
  # build its own default child spec. Nothing else in the codebase ever
  # paired a `Launcher.<Vendor>` with a different `SpecModule.<Vendor>`,
  # or vice versa, so the split bought no real reuse — see
  # `SurfBoard.Launcher`/`SurfBoard.Transport.Strategy.*`/`SurfBoard.Clients.*`
  # for the axes (process model, protocol) that *do* vary independently
  # and stay factored out. `SurfBoard.Driver.<Vendor>` is a sink: nothing
  # below it (`Launcher`, `Strategy.*`, `Clients.*`) references it by name.
  #
  # Every browser capability (visit, click, cookies, dialogs, window/frame
  # management, ...) is dispatched by Browser.ex/Element.ex calling
  # session.spec's dimension modules directly — a driver owns no session
  # lifecycle of its own beyond getting one started. Ending a session
  # needs no driver-specific teardown either (every driver's old
  # end_session/1 was identical) — SurfBoard.end_session/1 calls
  # Transport.Protocol.stop/1 directly.

  alias SurfBoard.{DependencyError, Session}
  alias SurfBoard.Driver.Spec

  @type reason :: :not_implemented | :not_supported | any
  @type on_start_session :: {:ok, Session.t()} | {:error, reason}

  @doc "This driver's capability-dispatch table."
  @callback spec() :: Spec.t()

  @doc """
  A child spec for this driver's default launcher (or whatever process
  it needs, if any — every current implementation needs at least a bare
  `Launcher` process) — started once, lazily, under
  `SurfBoard.DriverSupervisor` on first use. See
  `SurfBoard.ensure_driver_started/1`.
  """
  @callback default_launcher_spec() :: Supervisor.child_spec() | {module, keyword}

  @doc """
  Invoked to start a browser session.
  """
  @callback start_session(Keyword.t()) :: on_start_session

  @doc """
  Pre-flight dependency check, run once before `default_launcher_spec/0`
  is started (see `SurfBoard.ensure_driver_started/1`) — return
  `{:error, %DependencyError{}}` with a clear message when a required
  binary/config is missing, rather than letting a missing dependency
  surface as a confusing crash deep inside session startup.
  """
  @callback validate() :: :ok | {:error, DependencyError.t()}

  @doc """
  Invoked once, right after this driver's default launcher first
  starts. Most implementations no-op.
  """
  @callback cleanup_stale_sessions() :: :ok
end
