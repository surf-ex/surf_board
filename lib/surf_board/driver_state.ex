defmodule SurfBoard.DriverState do
  @moduledoc """
  Driver-internal bring-up state stashed on `SurfBoard.Session.driver_state`.

  Distinct from `Session.capabilities` (user-supplied WebDriver/BiDi
  capabilities passed as a `start_session/1` opt): every field here is
  written by a driver's own connection-acquisition step
  (`Transport.start_session_from/3`, `Transport.Strategy.PerSession`,
  `Transport.Actor`'s window-focus handling) and read back by that same
  driver's client/windows/permissions modules — never by a caller.

  Not every driver sets every field; a `nil` means "not applicable to
  this driver/strategy" rather than "not yet known."
  """

  @type t :: %__MODULE__{
          target_id: String.t() | nil,
          browser_context_id: String.t() | nil,
          flat_session_id?: boolean(),
          needs_xpath_polyfill?: boolean(),
          server_pid: pid() | nil,
          shared_connection?: boolean()
        }

  defstruct target_id: nil,
            browser_context_id: nil,
            flat_session_id?: false,
            needs_xpath_polyfill?: false,
            server_pid: nil,
            shared_connection?: false
end
