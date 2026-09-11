defmodule SurfBoard.Launcher do
  @moduledoc false

  # A started, independently-addressable instance of one
  # `SurfBoard.Transport.Strategy` + its `Config` — the thing you
  # actually navigate from (`Launcher.start_session/2`) instead of a
  # driver resolving an implicit, module-keyed global singleton.
  #
  # Named for what it always does regardless of strategy: every call to
  # `start_session/2` launches a genuinely new session (a fresh
  # BrowserContext/Target/actor), even when the underlying connection is
  # reused (SharedWS's cached ws_pid) rather than freshly launched itself.
  #
  # Replaces the old `Drivers.ChromeCDP.SharedConnection` pattern (a
  # `:persistent_term`-keyed Agent, exactly one per BEAM, ever) with
  # something you can start as many independent instances of as you
  # like — e.g. a production app connecting to a remote Chrome over
  # `ws://`, while its own test suite launches and owns a second,
  # local Chrome, both alive in the same BEAM.
  #
  # Every strategy gets one of these, even ones with no real state to
  # cache (IsolatedProcess, PerSession, BiDi) — those just never call
  # `get_or_compute/2`. Only SharedWS needs actual cached state today
  # (the shared ws_pid), but keeping the API uniform means a currently
  # stateless strategy can grow real shared state later with no change
  # to how callers reference it.
  #
  # `build_template` and `post_start` are the two vendor-supplied hooks
  # that make `start_session/2` a complete, standalone entry point —
  # everything a spec module's own `start_session/1` used to do around
  # the strategy call, now attached to the launcher itself instead of
  # living only in the spec module:
  #
  #   * `build_template.(opts)` — builds the `%SurfBoard.Session{}`
  #     template (id/spec_module/spec/live_view_aware?/base
  #     capabilities) `start_session/2` hands to the strategy.
  #   * `post_start.(session, opts)` — vendor-specific work that has to
  #     run *after* the strategy returns a live session (UA override,
  #     window size, log-event subscription, …); returns
  #     `{:ok, session} | {:error, term}`.
  #
  # A launcher with no hooks set (e.g. one built in a test directly
  # against a strategy) just skips them — see `start_session/2`.

  use Agent

  defstruct [:strategy, :config, :build_template, :post_start, cached: nil]

  @type t :: %__MODULE__{
          strategy: module,
          config: struct,
          build_template: (keyword -> SurfBoard.Session.t()) | nil,
          post_start:
            (SurfBoard.Session.t(), keyword ->
               {:ok, SurfBoard.Session.t()} | {:error, term})
            | nil,
          cached: term
        }
  @type ref :: pid | atom

  @doc """
  Starts a launcher wrapping `strategy` + `config`. Pass `:name` to
  make it addressable by that name instead of only by the returned pid.
  Optionally pass `:build_template`/`:post_start` — see the moduledoc.
  """
  @spec start_link(keyword) :: Agent.on_start()
  def start_link(opts) do
    strategy = Keyword.fetch!(opts, :strategy)
    config = Keyword.fetch!(opts, :config)
    build_template = Keyword.get(opts, :build_template)
    post_start = Keyword.get(opts, :post_start)
    start_opts = Keyword.take(opts, [:name])

    Agent.start_link(
      fn ->
        %__MODULE__{
          strategy: strategy,
          config: config,
          build_template: build_template,
          post_start: post_start
        }
      end,
      start_opts
    )
  end

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "The strategy module + config (+ hooks) this launcher wraps."
  @spec info(ref) :: t
  def info(launcher), do: Agent.get(launcher, & &1)

  @doc """
  Launches a new session from this launcher: builds the session
  template (via the launcher's `:build_template` hook, defaulting to a
  bare `%SurfBoard.Session{}` if none was set), calls the launcher's
  strategy, then runs the launcher's `:post_start` hook (if any) on the
  resulting session.

  This is what makes a launcher a complete, standalone entry point —
  `SurfBoard.start_session(driver: ..., launcher: ...)` is sugar around
  resolving a launcher and calling this.
  """
  @spec start_session(ref, keyword) :: {:ok, SurfBoard.Session.t()} | {:error, term}
  def start_session(launcher, opts \\ []) do
    %__MODULE__{strategy: strategy, build_template: build_template, post_start: post_start} =
      info(launcher)

    template =
      if build_template, do: build_template.(opts), else: %SurfBoard.Session{}

    owner = Keyword.get(opts, :owner, self())

    with {:ok, session} <-
           strategy.start_session(launcher: launcher, session_struct: template, owner: owner) do
      if post_start, do: post_start.(session, opts), else: {:ok, session}
    end
  end

  @doc """
  Lazily computes and caches one value in the launcher's own state,
  serialized across concurrent first-callers — a live cached value is
  returned as-is; a dead one (per `is_alive_fun`, when given) triggers
  a fresh compute. Used by strategies that need a persistent connection
  (SharedWS's ws_pid); strategies with nothing to cache never call this.
  """
  @spec get_or_compute(ref, (-> term), (term -> boolean) | nil) :: term
  def get_or_compute(launcher, compute_fun, is_alive_fun \\ nil) do
    Agent.get_and_update(launcher, fn state ->
      if state.cached != nil and (is_nil(is_alive_fun) or is_alive_fun.(state.cached)) do
        {state.cached, state}
      else
        value = compute_fun.()
        {value, %{state | cached: value}}
      end
    end)
  end
end
