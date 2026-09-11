defmodule SurfBoard.Permissions.Unsupported do
  @moduledoc false

  # Stub used by specs whose underlying browser/protocol client has no
  # permission-granting support wired up (currently ChromeBiDi and
  # Lightpanda). Raises rather than silently no-opping — unlike dialog
  # handling, where a no-op is a safe stand-in, a caller granting
  # camera/microphone access needs to know it didn't actually happen
  # rather than have code that assumes it did.

  @behaviour SurfBoard.Permissions

  @impl true
  def grant_permissions(%SurfBoard.Session{spec_module: spec_module}, _permissions) do
    raise SurfBoard.DriverError.not_supported("grant_permissions/2", spec_module)
  end
end
