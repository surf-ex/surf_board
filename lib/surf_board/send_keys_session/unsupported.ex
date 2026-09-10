defmodule SurfBoard.SendKeysSession.Unsupported do
  @moduledoc false

  # Stub used by drivers whose underlying browser/protocol client
  # doesn't reliably support session-scoped key dispatch (currently
  # Lightpanda). Returns {:error, :not_implemented} rather than
  # attempting the real wire call and getting an unreliable result.

  @behaviour SurfBoard.SendKeysSession

  @impl true
  def send_keys_to_session(%SurfBoard.Session{}, _keys), do: {:error, :not_implemented}
end
