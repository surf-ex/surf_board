defmodule SurfBoard.Driver.PermissionsDispatchTest do
  use ExUnit.Case, async: true

  # Regression coverage for the same class of bug caught while building
  # open_stream/1: Chrome CDP and Lightpanda share the exact same
  # `wire_protocol` module (`SurfBoard.Clients.CDP.Client`), so a CDP-only
  # capability can't be gated by keying off `spec.wire_protocol` — it can't
  # tell the two drivers apart. grant_permissions has its own %Spec{}
  # dimension (spec.grant_permissions) specifically so Browser.ex CAN tell
  # them apart — LightpandaCDP/ChromeBiDi point it at Permissions.Unsupported,
  # ChromeCDP points it at the real Clients.CDP.Client implementation.

  alias SurfBoard.Browser
  alias SurfBoard.Drivers.{ChromeBiDi, LightpandaCDP}
  alias SurfBoard.Session

  describe "LightpandaCDP" do
    test "grant_permissions/2 raises SurfBoard.DriverError without touching the transport" do
      session = %Session{driver: LightpandaCDP, driver_spec: LightpandaCDP.driver_spec()}

      assert_raise SurfBoard.DriverError, ~r/grant_permissions\/2 is not supported/, fn ->
        Browser.grant_permissions(session, [:camera])
      end
    end
  end

  describe "ChromeBiDi" do
    test "grant_permissions/2 raises SurfBoard.DriverError without touching the transport" do
      session = %Session{driver: ChromeBiDi, driver_spec: ChromeBiDi.driver_spec()}

      assert_raise SurfBoard.DriverError, ~r/grant_permissions\/2 is not supported/, fn ->
        Browser.grant_permissions(session, [:camera])
      end
    end
  end
end
