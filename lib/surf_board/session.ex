defmodule SurfBoard.Session do
  @moduledoc """
  Struct containing details about the webdriver session.
  """

  @typedoc """
  Deferred patch-await state, stashed when an interaction is invoked
  with `await: :defer`. Consumed by `SurfBoard.LiveView.await_patch/2`.

    * `{:page_ready_after, pre_page_id}` — the click captured a
      pre-click page id; await the next `page_ready` notification.
    * `:armed` — `prepare_patch` was called, but no pre-click id
      exists (e.g. `fill_in` deferred); resolve via the existing
      `__surfboard_patch_promise` machinery.
  """
  @type pending_await :: nil | {:page_ready_after, String.t() | nil} | :armed

  @type t :: %__MODULE__{
          id: String.t(),
          pid: pid() | nil,
          session_url: String.t(),
          url: String.t(),
          server: pid | :none | module,
          screenshots: list,
          spec_module: module,
          driver_spec: struct() | nil,
          capabilities: map(),
          bidi_pid: pid() | nil,
          browsing_context: String.t() | nil,
          metadata: map() | nil,
          pending_await: pending_await,
          live_view_aware?: boolean()
        }

  defstruct [
    :id,
    :pid,
    :url,
    :session_url,
    :spec_module,
    :driver_spec,
    :capabilities,
    :bidi_pid,
    :browsing_context,
    :metadata,
    server: :none,
    screenshots: [],
    pending_await: nil,
    # Settings passed to `start_session/1` that govern later calls rather
    # than session startup (`:base_url`, `:max_wait_time`). Kept on the
    # session so they beat config without a global read.
    session_opts: [],
    # Session-level opt-in for LiveView `phx-*` patch-classification on
    # click/fill_in and connect-awaiting on visit. Off by default for
    # every driver — a plain scraping/automation session pays no cost
    # for a Phoenix concept it doesn't use. Pass
    # `live_view_aware: true` to `start_session/1` to enable it for
    # sessions that DO need it (e.g. testing a Phoenix LiveView app).
    live_view_aware?: false
  ]
end
