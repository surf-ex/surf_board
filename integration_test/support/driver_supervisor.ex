defmodule SurfBoard.Integration.DriverSupervisor do
  @moduledoc false

  # Starts each driver's default instance once, lazily, the first time
  # the integration suite needs it — this used to be `SurfBoard`'s own
  # job (the app-level `DriverSupervisor` + `ensure_driver_started/1`),
  # but drivers no longer start anything on their own: an application
  # (or, here, a test suite) owns that decision explicitly now. See
  # `start_default/1`, called from `SessionCase.inject_test_session/1`.

  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, [], Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl DynamicSupervisor
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc """
  Idempotently starts `child_spec` (e.g. `Driver.ChromeCDP.child_spec([])`,
  or `Driver.Lightpanda.maybe_default_child_spec()` for a driver whose
  default instance might not have anything to start — pass `nil` and
  this is a no-op, matching that function's own `nil`-if-unavailable
  contract) under this supervisor. Entry points with no persistent
  instance at all, like `Driver.Lightpanda.spawn_session/1`/
  `connect_session/2`, have no child spec to pass here at all.
  """
  def start_default(nil), do: :ok

  def start_default(child_spec) do
    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      # A driver whose default instance starts a fixed-named child
      # (e.g. ChromeBiDi's chromium-bidi sidecar) reports a second
      # concurrent start attempt this way rather than as a flat
      # :already_started — see SurfBoard's old ensure_driver_started/1
      # for the same handling this mirrors.
      {:error, {:shutdown, {:failed_to_start_child, _child, {:already_started, _pid}}}} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
