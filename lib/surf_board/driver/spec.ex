defmodule SurfBoard.Driver.Spec do
  @moduledoc false

  # A driver as data: dimension modules plus per-driver cross-cutting
  # flags. `Browser`/`Element` read from this struct directly to
  # dispatch each capability to the right client module — there's no
  # intermediary module between them and this Spec.
  #
  # Stamped onto `Session.spec` at start_session time; from then
  # on, the session is fully described by its Spec.
  #
  # `dialogs`/`windows`/`frames` are always a real module — dispatched
  # polymorphically (`spec.dialogs.accept_alert(...)`), so even the
  # "unsupported" case needs a real module whose own body defines what
  # "unsupported" safely means for that capability (no-op, simulate a
  # single window, ...) — see `Clients.Dialogs.Unsupported`,
  # `Clients.Windows.Single`, `Clients.Frames.Unsupported`.
  #
  # `grant_permissions`/`send_keys_session` are `module | nil` instead:
  # the caller (`Browser.Form`) checks support and raises itself rather
  # than calling through a stub module, so there's nothing for a
  # dedicated "unsupported" module to do — `nil` says the same thing
  # with no module needed.
  #
  # Each protocol client owns its own default pick for these five
  # (`Clients.CDP.Client.default_strategies/0`,
  # `Clients.BiDi.Client.default_strategies/0`); a driver starts
  # from its client's defaults and overrides only where its vendor's
  # engine genuinely diverges — see `Driver.SharedLightpanda`, which
  # overrides every one of them.

  defstruct [
    :wire_protocol,
    :dialogs,
    :windows,
    :frames,
    :grant_permissions,
    :send_keys_session,
    # Per-driver one-off: touch_scroll has three distinct implementations
    # (CDP synthesizeScrollGesture / BiDi JS scrollBy / Lightpanda no-op)
    # that don't justify their own behaviour. Function of (element, dx, dy).
    :touch_scroll,
    # Wrap visit/click in check_logs! to drain console + exception events
    # into JSError raises. Both Chrome drivers set true; Lightpanda false.
    log_check_interactions?: false,
    # A click pipeline choice: eager find + retry loop + log-check +
    # Element.click (false — Chrome's own classify+patch-await handles
    # this) vs. lazy find + one native click_aware round trip (true —
    # Lightpanda, where post-click re-find polling is slow). See
    # Browser.LiveViewPatch.click_auto/2.
    native_click_await?: false
  ]

  @type t :: %__MODULE__{
          wire_protocol: module,
          dialogs: module,
          windows: module,
          frames: module,
          grant_permissions: module | nil,
          send_keys_session: module | nil,
          touch_scroll:
            (SurfBoard.Element.t(), number, number -> {:ok, nil} | {:error, term}) | nil,
          log_check_interactions?: boolean,
          native_click_await?: boolean
        }
end
