{:ok, _} = SurfBoard.Integration.FixtureServer.start_link()

Application.put_env(:surf_board, :base_url, SurfBoard.Integration.FixtureServer.base_url())

{:ok, _} = SurfBoard.Integration.DriverSupervisor.start_link()

# Every driver's default *shared/spawned* instance — the connect/spawn
# entry points (Driver.ChromeCDP.connect/1, Driver.Lightpanda.spawn_session/1,
# Driver.Lightpanda.connect_session/2) need no persistent instance and
# are exercised directly by connection_modes_test.exs instead, dialing
# these same shared instances rather than needing SURF_BOARD_CHROME_URL
# configured for a truly separate remote Chrome.
for driver <- [
      SurfBoard.Driver.ChromeCDP,
      SurfBoard.Driver.ChromeBiDi,
      SurfBoard.Driver.Lightpanda
    ] do
  :ok = SurfBoard.Integration.DriverSupervisor.start_default(driver)
end

ExUnit.start(exclude: [:pending])
