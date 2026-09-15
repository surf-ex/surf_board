{:ok, _} = SurfBoard.Integration.FixtureServer.start_link()

Application.put_env(:surf_board, :base_url, SurfBoard.Integration.FixtureServer.base_url())

{:ok, _} = SurfBoard.Integration.DriverSupervisor.start_link()

for driver <- [SurfBoard.Driver.ChromeCDP, SurfBoard.Driver.ChromeBiDi, SurfBoard.Driver.Lightpanda] do
  :ok = SurfBoard.Integration.DriverSupervisor.start_default(driver)
end

ExUnit.start(exclude: [:pending])
