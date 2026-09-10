defmodule SurfBoard.Driver.Spec do
  @moduledoc false

  # A driver-as-data: dimension modules plus per-driver cross-cutting
  # flags. `Browser`/`Element` read from this struct directly to
  # dispatch each capability to the right client module — there's no
  # intermediary module between them and this Spec.
  #
  # Stamped onto `Session.driver_spec` at start_session time; from then
  # on, the session is fully described by its Spec.

  defstruct [
    # Dimension modules — each one is a behaviour impl that varies
    # per driver.
    :browser,
    :wire_protocol,
    :dialogs,
    :windows,
    :frames,
    # Not dispatched via wire_protocol — see SurfBoard.Permissions'
    # moduledoc for why grant_permissions needs its own dimension
    # rather than living on the shared wire_protocol client.
    :grant_permissions,
    # Same reason as grant_permissions — see SurfBoard.SendKeysSession's
    # moduledoc. Session-scoped send_keys, not element-scoped (which
    # stays a plain wire_protocol.send_keys/3 dispatch).
    :send_keys_session,
    # Per-driver one-off: touch_scroll has three distinct implementations
    # (CDP synthesizeScrollGesture / BiDi JS scrollBy / Lightpanda no-op)
    # that don't justify their own behaviour. Function of (element, dx, dy).
    :touch_scroll,
    # Wrap visit/click in check_logs! to drain console + exception events
    # into JSError raises. Both Chrome drivers set true; Lightpanda false.
    log_check_interactions?: false
  ]

  @type t :: %__MODULE__{
          browser: module,
          wire_protocol: module,
          dialogs: module,
          windows: module,
          frames: module,
          grant_permissions: module,
          send_keys_session: module,
          touch_scroll:
            (SurfBoard.Element.t(), number, number -> {:ok, nil} | {:error, term}) | nil,
          log_check_interactions?: boolean
        }
end
