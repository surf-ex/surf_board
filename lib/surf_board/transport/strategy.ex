defmodule SurfBoard.Transport.Strategy do
  @moduledoc false

  # The behaviour every Transport.Strategy.* module implements — see
  # SurfBoard.Transport's moduledoc for the full picture of what
  # varies across strategies and why.
  #
  # `opts` carries exactly three keys, none of them strategy-specific:
  #
  #   * `:session_struct` — the driver's `%SurfBoard.Session{}` template
  #     (id/driver/driver_spec/live_view_aware?/base capabilities filled
  #     in; bidi_pid/browsing_context left for the strategy to set).
  #   * `:config` — the strategy's own opaque config struct (e.g.
  #     `%Strategy.SharedWS.Config{}`), built by the driver and never
  #     inspected by anything else. This is what actually hides whether
  #     a strategy is single- or multi-process: a driver author swapping
  #     strategies only needs to know which Config to build, not how
  #     start_session/1 uses it internally.
  #   * `:owner` — process to monitor; defaults to `self()`.
  #
  # No connection details (a shared-connection module, a ws_url, a
  # spawn_fun, …) travel as bare opts keys — they live inside `:config`,
  # namespaced to the one strategy that understands them.

  @doc """
  Brings up a session: acquires whatever connection this strategy
  needs (per its own `:config`), builds `%SurfBoard.Session{}` from
  the caller's `:session_struct` template, and returns it ready for
  use — GenServer up, page-lifecycle/bootstrap/frame tracking (or
  BiDi's equivalents) already installed.
  """
  @callback start_session(opts :: keyword) ::
              {:ok, SurfBoard.Session.t()} | {:error, term}
end
