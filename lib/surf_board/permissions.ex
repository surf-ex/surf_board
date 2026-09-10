defmodule SurfBoard.Permissions do
  @moduledoc false

  # Media (camera/microphone) permission granting. One of the
  # vendor-specific dimensions of a driver Spec.
  #
  #   * `Clients.CDP.Client` — CDP `Browser.grantPermissions`. Shared
  #                            by ChromeCDP directly (it's also the
  #                            wire_protocol client — no separate
  #                            Permissions.ChromeCDP module needed).
  #   * `Unsupported`        — ChromeBiDi (no BiDi permissions API
  #                            wired up yet) and Lightpanda (no
  #                            camera/mic or getUserMedia support at
  #                            all).
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
