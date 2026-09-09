defmodule Surfboard.Integration.FixtureServer do
  @moduledoc false

  # Plain static-file server for the integration smoke suite — serves
  # integration_test/support/fixtures/ over HTTP. No Phoenix, no
  # LiveView backend; just enough for visit/click/find smoke tests
  # against real pages.

  @port 4321
  @fixtures_path Path.expand("fixtures", __DIR__)

  defmodule Router do
    use Plug.Router

    plug(Plug.Static, at: "/", from: Path.expand("fixtures", __DIR__))
    plug(:match)
    plug(:dispatch)

    match(_, do: send_resp(conn, 404, "not found"))
  end

  def start_link do
    Plug.Cowboy.http(__MODULE__.Router, [], port: @port)
  end

  def base_url, do: "http://localhost:#{@port}"

  def fixtures_path, do: @fixtures_path
end
