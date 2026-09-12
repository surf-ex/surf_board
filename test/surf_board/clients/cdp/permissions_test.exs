defmodule SurfBoard.Clients.CDP.PermissionsTest do
  use ExUnit.Case, async: true

  alias SurfBoard.Clients.CDP.Permissions
  alias SurfBoard.Session

  describe "grant_permissions/2" do
    test "raises ArgumentError for an unknown permission before touching the transport" do
      assert_raise ArgumentError, ~r/unknown permission :geolocation/, fn ->
        Permissions.grant_permissions(%Session{}, [:geolocation])
      end
    end
  end
end
