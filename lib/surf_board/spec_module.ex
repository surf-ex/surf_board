defmodule SurfBoard.SpecModule do
  @moduledoc false

  # A spec module describes one protocol variant (Chrome via CDP,
  # Chrome via BiDi, Lightpanda, ...) as data plus the small amount of
  # vendor-specific glue needed to actually start a session against
  # it. It owns no session lifecycle itself — no Supervisor, no
  # process — every browser capability (visit, click, cookies,
  # dialogs, window/frame management, ...) is dispatched by
  # Browser.ex/Element.ex calling session.spec's dimension
  # modules directly, and process ownership (spawning/supervising a
  # browser, holding a connection) belongs to the vendor's
  # `Launcher.<Vendor>` module, not here. Ending a session needs no
  # spec-specific teardown either (every spec's old end_session/1 was
  # identical) — SurfBoard.end_session/1 calls Transport.Protocol.stop/1
  # directly.
  #
  # `start_session/1` still lives here, per spec module, rather than
  # being hoisted into shared code: most spec modules' implementation
  # is the generic one-liner `Launcher.start_session(default_launcher, opts)`,
  # but that's not universal — SpecModule.ChromeBiDi's strategy caches no
  # connection state, so it builds a fresh, transient launcher per
  # call instead. One uniform callback, vendor-specific bodies — this
  # is what lets a common pattern (SpecModule) support different
  # process models underneath, rather than special-casing any one
  # vendor in shared dispatch code.

  alias SurfBoard.{DependencyError, Session, Spec}

  @type reason :: :not_implemented | :not_supported | any
  @type on_start_session :: {:ok, Session.t()} | {:error, reason}

  @doc "This variant's capability-dispatch table."
  @callback spec() :: Spec.t()

  @doc """
  A child spec for this variant's default `Launcher.<Vendor>` (or
  whatever process it needs, if any — every current implementation
  needs at least a bare `Launcher` process) — started once, lazily,
  under `SurfBoard.DriverSupervisor` on first use. See
  `SurfBoard.ensure_spec_started/1`.
  """
  @callback default_launcher_spec() :: Supervisor.child_spec() | {module, keyword}

  @doc """
  Invoked to start a browser session.
  """
  @callback start_session(Keyword.t()) :: on_start_session

  @doc """
  Pre-flight dependency check, run once before `default_launcher_spec/0`
  is started (see `SurfBoard.ensure_spec_started/1`) — return
  `{:error, %DependencyError{}}` with a clear message when a required
  binary/config is missing, rather than letting a missing dependency
  surface as a confusing crash deep inside session startup.
  """
  @callback validate() :: :ok | {:error, DependencyError.t()}

  @doc """
  Invoked once, right after this variant's default launcher first
  starts. Most implementations no-op.
  """
  @callback cleanup_stale_sessions() :: :ok
end
