defmodule Surfboard.CDP.ClientTest do
  use ExUnit.Case, async: true

  alias Surfboard.CDP.Client, as: CDPClient
  alias Surfboard.Session

  describe "grant_permissions/2" do
    test "raises ArgumentError for an unknown permission before touching the transport" do
      assert_raise ArgumentError, ~r/unknown permission :geolocation/, fn ->
        CDPClient.grant_permissions(%Session{}, [:geolocation])
      end
    end
  end
end
