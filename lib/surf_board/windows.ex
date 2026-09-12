defmodule SurfBoard.Windows do
  @moduledoc false

  # Multi-window / tab management. One of the vendor-specific dimensions
  # of a driver Spec.
  #
  #   * `ChromeCDP`     — uses CDP `Target.*` against the shared WS to
  #                       enumerate / attach / close tabs in this session's
  #                       browser context; the focused target is the
  #                       session's own `browsing_context`/`target_id`,
  #                       mutated on the transport actor.
  #   * `ChromeBiDi`    — uses BiDi `browsingContext.*`; the focused
  #                       window is likewise the session's own
  #                       `browsing_context`, mutated on the transport
  #                       actor via the same `:update_browsing_context`
  #                       message CDP uses — not per-process state, so
  #                       any process holding the session sees the
  #                       current focus.
  #   * `SingleWindow`  — Lightpanda / no-window-management backends.
  #                       Returns "main" as the single handle.

  alias SurfBoard.{Element, Session}

  @callback window_handle(Session.t() | Element.t()) :: {:ok, String.t() | nil}
  @callback window_handles(Session.t() | Element.t()) :: {:ok, list(String.t())}
  @callback focus_window(Session.t() | Element.t(), String.t()) :: {:ok, nil} | {:error, term}
  @callback close_window(Session.t() | Element.t()) :: {:ok, nil} | {:error, term}
end
