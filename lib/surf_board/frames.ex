defmodule SurfBoard.Frames do
  @moduledoc false

  # IFrame focus management. One of the vendor-specific dimensions of
  # a driver Spec. Both real implementations push/pop onto the
  # transport actor's `frame_stack` (not per-process state) — CDP
  # holds executionContextId integers there, BiDi holds
  # browsing-context id strings.
  #
  #   * `ChromeCDP`     — CDP DOM.describeNode + focus_frame_by_id
  #                       (tracks frame executionContextIds on the actor)
  #   * `ChromeBiDi`    — BiDi child_context_for_iframe, pushes the
  #                       child browsing-context id onto the actor's
  #                       frame_stack
  #   * `Unsupported`   — Lightpanda (no iframe support)

  alias SurfBoard.{Element, Session}

  @callback focus_frame(Session.t(), Element.t() | nil) :: {:ok, nil} | {:error, term}
  @callback focus_parent_frame(Session.t()) :: {:ok, nil} | {:error, term}
end
