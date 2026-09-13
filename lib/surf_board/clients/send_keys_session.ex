defmodule SurfBoard.Clients.SendKeysSession do
  @moduledoc false

  # Session-scoped send_keys (dispatch a key sequence to whatever
  # element currently has page focus, rather than a specific element).
  # One of the vendor-specific dimensions of a driver Spec.
  #
  #   * `Clients.CDP.SendKeysSession`  — CDP `Input.dispatchKeyEvent`.
  #   * `Clients.BiDi.SendKeysSession` — BiDi `input.performActions`.
  #   * Lightpanda leaves `spec.send_keys_session` as `nil` instead of
  #     naming a module — its CDP surface doesn't implement
  #     Input.dispatchKeyEvent reliably enough to trust.
  #     `Browser.Form.send_keys/2` raises `DriverError.not_supported/2`
  #     itself on `nil` rather than calling through a dedicated stub
  #     module.
  #
  # Exists as its own %Spec{} field, not dispatched via a
  # function_exported?/3 probe on spec.wire_protocol, for the same
  # reason grant_permissions does — Chrome CDP and Lightpanda CDP
  # share the exact same wire_protocol module, so a function_exported?
  # check can't tell the two drivers apart; it would route Lightpanda
  # through the same real Input.dispatchKeyEvent call as Chrome
  # instead of correctly failing.

  alias SurfBoard.Session

  @callback send_keys_to_session(Session.t(), [String.t() | atom]) ::
              {:ok, nil} | {:error, term}
end
