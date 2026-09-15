{:ok, _} = SurfBoard.Integration.FixtureServer.start_link()

Application.put_env(:surf_board, :base_url, SurfBoard.Integration.FixtureServer.base_url())

{:ok, _} = SurfBoard.Integration.DriverSupervisor.start_link()

# Only the drivers this suite's own @moduletag driver: values resolve
# to (see session_case.ex's @drivers map) need a default instance
# started — Driver.ExternalChromeCDP/IsolatedLightpanda/ExternalLightpanda
# aren't exercised by any test file here, and the first of those three
# would fail to start without SURF_BOARD_CHROME_URL configured anyway.
for driver <- [
      SurfBoard.Driver.SharedChromeCDP,
      SurfBoard.Driver.ChromeBiDi,
      SurfBoard.Driver.SharedLightpanda
    ] do
  :ok = SurfBoard.Integration.DriverSupervisor.start_default(driver)
end

ExUnit.start(exclude: [:pending])
