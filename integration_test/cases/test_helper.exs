{:ok, _} = SurfBoard.Integration.FixtureServer.start_link()

Application.put_env(:surf_board, :base_url, SurfBoard.Integration.FixtureServer.base_url())

ExUnit.start(exclude: [:pending])
