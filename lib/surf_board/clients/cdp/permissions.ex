defmodule SurfBoard.Clients.CDP.Permissions do
  @moduledoc false

  # CDP media (camera/microphone) permission granting. A thin wrapper
  # over Browser.grantPermissions; the actual wire send goes through
  # Clients.CDP.Client (aliased as CDPClient below), the same as
  # Clients.CDP.Dialogs does.

  @behaviour SurfBoard.Permissions

  alias SurfBoard.Clients.CDP.Client, as: CDPClient
  alias SurfBoard.Session

  @permission_types %{camera: "videoCapture", microphone: "audioCapture"}

  @doc """
  Grants media permissions (`:camera`, `:microphone`) for the session's
  browser context, so `getUserMedia`/`getDisplayMedia` calls in the page
  succeed without a real permission prompt — headless Chrome has no UI
  surface to show or auto-accept one.

  Applies to every origin in the session's browser context (CDP's
  `Browser.grantPermissions` with no `origin` given), since a session
  navigating between origins — or joining a call on a domain not known in
  advance — is the common case here, not a single already-known origin.

  Pairs with launching Chrome with a fake camera/mic (`--use-fake-device-for-media-stream`,
  optionally with `--use-file-for-fake-video-capture=`/`--use-file-for-fake-audio-capture=`)
  — this call satisfies the permission prompt; the launch flags are what
  give `getUserMedia` an actual (synthetic) device to open. SurfBoard
  doesn't manage Chrome's launch flags; see the
  [Recording guide](recording.html) for a Chrome image built for this.
  """
  @impl true
  @spec grant_permissions(Session.t(), [:camera | :microphone]) :: :ok | {:error, term}
  def grant_permissions(%Session{} = session, permissions) when is_list(permissions) do
    cdp_permissions =
      Enum.map(permissions, fn permission ->
        Map.get(@permission_types, permission) ||
          raise ArgumentError,
                "unknown permission #{inspect(permission)} — expected one of #{inspect(Map.keys(@permission_types))}"
      end)

    browser_context_id = get_in(session.capabilities, [:browser_context_id])

    params =
      if browser_context_id do
        %{permissions: cdp_permissions, browserContextId: browser_context_id}
      else
        %{permissions: cdp_permissions}
      end

    case CDPClient.cdp_send(session, "Browser.grantPermissions", params) do
      {:ok, _} -> :ok
      error -> error
    end
  end
end
