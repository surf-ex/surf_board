defmodule SurfBoard.NoopSupervisor do
  @moduledoc false

  # A zero-child Supervisor — what a spec module's `default_launcher_spec/0`
  # returns when its vendor dependency isn't available (e.g. the
  # `lightpanda` package not on the load path). `ensure_spec_started/1`
  # always starts *something* under `SurfBoard.DriverSupervisor` so it
  # has a consistent, trackable child to check `:already_started`
  # against, even when there's nothing real to launch yet.

  use Supervisor

  def child_spec(opts) do
    %{
      id: Keyword.fetch!(opts, :id),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, :ok, Keyword.take(opts, [:name]))
  end

  @impl Supervisor
  def init(:ok) do
    Supervisor.init([], strategy: :one_for_one)
  end
end
