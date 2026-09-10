defmodule SurfBoard.SendKeysSession do
  @moduledoc false

  # Session-scoped send_keys (dispatch a key sequence to whatever
  # element currently has page focus, rather than a specific element).
  # One of the vendor-specific dimensions of a driver Spec.
  #
  #   * `Clients.CDP.Client`       — CDP `Input.dispatchKeyEvent`.
  #                                  Shared by ChromeCDP directly (it's
  #                                  also the wire_protocol client — no
  #                                  separate SendKeysSession.ChromeCDP
  #                                  module needed).
  #   * `Clients.BiDi.Client`      — BiDi `input.performActions`.
  #                                  Same story for ChromeBiDi.
  #   * `Unsupported`              — Lightpanda. Its CDP surface
  #                                  doesn't implement
  #                                  Input.dispatchKeyEvent reliably
  #                                  enough to trust.
  #
  # Exists as its own %Spec{} field, not dispatched via a
  # function_exported?/3 probe on spec.wire_protocol, for the same
  # reason grant_permissions does — Chrome CDP and Lightpanda CDP
  # share the exact same wire_protocol module (both implement
  # send_keys_to_session/2), so a function_exported? check can't tell
  # the two drivers apart; it would route Lightpanda through the same
  # real Input.dispatchKeyEvent call as Chrome instead of correctly
  # failing.

  alias SurfBoard.Session

  @callback send_keys_to_session(Session.t(), [String.t() | atom]) ::
              {:ok, nil} | {:error, term}
end
