defmodule SurfBoard.PermissionsDispatchTest do
  use ExUnit.Case, async: true

  # Regression coverage for the same class of bug caught while building
  # open_stream/1: Chrome CDP and Lightpanda share the exact same
  # `wire_protocol` module (`SurfBoard.Clients.CDP.Client`), so a CDP-only
  # capability can't be gated by keying off `spec.wire_protocol` — it can't
  # tell the two drivers apart. grant_permissions has its own %Spec{}
  # dimension (spec.grant_permissions) specifically so Browser.ex CAN tell
  # them apart — Lightpanda/ChromeBiDi leave it `nil` (raises
  # DriverError.not_supported/2), ChromeCDP points it at the real
  # Clients.CDP.Permissions implementation.

  alias SurfBoard.Browser
  alias SurfBoard.Driver.{ChromeBiDi, Lightpanda}
  alias SurfBoard.Session

  describe "Lightpanda" do
    test "grant_permissions/2 raises SurfBoard.DriverError without touching the transport" do
      session = %Session{spec_module: Lightpanda, spec: Lightpanda.spec()}

      assert_raise SurfBoard.DriverError, ~r/grant_permissions\/2 is not supported/, fn ->
        Browser.grant_permissions(session, [:camera])
      end
    end
  end

  describe "ChromeBiDi" do
    test "grant_permissions/2 raises SurfBoard.DriverError without touching the transport" do
      session = %Session{spec_module: ChromeBiDi, spec: ChromeBiDi.spec()}

      assert_raise SurfBoard.DriverError, ~r/grant_permissions\/2 is not supported/, fn ->
        Browser.grant_permissions(session, [:camera])
      end
    end
  end
end
