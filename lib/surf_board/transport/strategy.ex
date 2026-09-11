defmodule SurfBoard.Transport.Strategy do
  @moduledoc false

  # The behaviour every Transport.Strategy.* module implements — see
  # SurfBoard.Transport's moduledoc for the full picture of what
  # varies across strategies and why.
  #
  # `opts` carries exactly three keys, none of them strategy-specific:
  #
  #   * `:session_struct` — the spec's `%SurfBoard.Session{}` template
  #     (id/spec_module/spec/live_view_aware?/base capabilities filled
  #     in; bidi_pid/browsing_context left for the strategy to set).
  #   * `:launcher` — a `SurfBoard.Launcher.ref` — the started launcher
  #     instance this session connects through. Every strategy reads its
  #     own `Config` off `Launcher.info(launcher).config` rather than
  #     taking one as a bare opt; a strategy that needs to cache real
  #     connection state across many sessions (SharedWS) stores it in
  #     the launcher itself via `Launcher.get_or_compute/3`, keyed to
  #     *that* launcher instance, not a global. This is what actually
  #     hides whether a strategy is single- or multi-process: a driver
  #     author swapping strategies only needs to start the right kind of
  #     launcher, never touch how start_session/1 uses it internally —
  #     and two independently-started launchers of the same strategy
  #     never share state, so e.g. a production connection and a test
  #     connection can coexist in one running app.
  #   * `:owner` — process to monitor; defaults to `self()`.
  #
  # No connection details (a shared-connection module, a ws_url, a
  # spawn_fun, …) travel as bare opts keys — they live inside the
  # launcher's `Config`, namespaced to the one strategy that understands
  # them.

  @doc """
  Brings up a session: acquires whatever connection this strategy
  needs (per the `:launcher`'s own `Config`), builds `%SurfBoard.Session{}`
  from the caller's `:session_struct` template, and returns it ready
  for use — GenServer up, page-lifecycle/bootstrap/frame tracking (or
  BiDi's equivalents) already installed.
  """
  @callback start_session(opts :: keyword) ::
              {:ok, SurfBoard.Session.t()} | {:error, term}
end
