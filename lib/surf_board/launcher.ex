defmodule SurfBoard.Launcher do
  @moduledoc false

  # A started, independently-addressable instance of one
  # `SurfBoard.Transport.Strategy` + its `Config` — the thing sessions
  # actually reference (`start_session(launcher: ...)`) instead of a
  # driver resolving an implicit, module-keyed global singleton.
  #
  # Named for what it always does regardless of strategy: every call to
  # `start_session/1` launches a genuinely new session (a fresh
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

  use Agent

  defstruct [:strategy, :config, cached: nil]

  @type t :: %__MODULE__{strategy: module, config: struct, cached: term}
  @type ref :: pid | atom

  @doc """
  Starts a launcher wrapping `strategy` + `config`. Pass `:name` to
  make it addressable by that name instead of only by the returned pid.
  """
  @spec start_link(keyword) :: Agent.on_start()
  def start_link(opts) do
    strategy = Keyword.fetch!(opts, :strategy)
    config = Keyword.fetch!(opts, :config)
    start_opts = Keyword.take(opts, [:name])

    Agent.start_link(fn -> %__MODULE__{strategy: strategy, config: config} end, start_opts)
  end

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "The strategy module + config this launcher wraps."
  @spec info(ref) :: t
  def info(launcher), do: Agent.get(launcher, & &1)

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
