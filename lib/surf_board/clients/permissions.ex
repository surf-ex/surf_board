defmodule SurfBoard.Clients.Permissions do
  @moduledoc false

  # Media (camera/microphone) permission granting. One of the
  # vendor-specific dimensions of a driver Spec.
  #
  #   * `Clients.CDP.Permissions` — CDP `Browser.grantPermissions`.
  #     ChromeBiDi (no BiDi permissions API wired up yet) and
  #     Lightpanda (no camera/mic or getUserMedia support at all)
  #     leave `spec.grant_permissions` as `nil` instead of naming a
  #     module — `Browser.Form.grant_permissions/2` raises
  #     `DriverError.not_supported/2` itself on `nil` rather than
  #     calling through a dedicated stub module.
  #
  # Exists as its own %Spec{} field, not dispatched via
  # spec.wire_protocol, because Chrome CDP and Lightpanda CDP share the
  # exact same wire_protocol module — a wire_protocol-keyed dispatch
  # can't tell the two drivers apart. This is the fix for that: the
  # capability that actually varies (does this vendor's browser support
  # permission granting) gets its own explicit dimension.

  alias SurfBoard.Session

  @callback grant_permissions(Session.t(), [:camera | :microphone]) ::
              :ok | {:error, term}
end
