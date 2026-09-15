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
  Idempotently starts `driver`'s default instance under this
  supervisor, if it has one to start (`Driver.Lightpanda.default_child_spec/0`
  returns `nil` when the optional `lightpanda` package isn't loaded —
  nothing to do then; entry points with no persistent instance at all,
  like `Driver.Lightpanda.spawn_session/1`/`connect_session/2`, have no
  `default_child_spec/0` to call — this function is only for drivers
  that have one).
  """
  def start_default(driver) do
    case driver.default_child_spec() do
      nil ->
        :ok

      child_spec ->
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
end
