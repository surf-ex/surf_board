{:ok, _} = Surfboard.Integration.FixtureServer.start_link()

Application.put_env(:surfboard, :base_url, Surfboard.Integration.FixtureServer.base_url())

ExUnit.start(exclude: [:pending])
