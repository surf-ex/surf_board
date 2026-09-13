defmodule SurfBoard.Transport.Strategy do
  @moduledoc false

  # The behaviour every Transport.Strategy.* module implements: the
  # "where does a session get its WebSocket" question. Four concrete
  # strategies today:
  #
  #   * `Strategy.SharedWS`        — Chrome CDP. One WebSocket per BEAM,
  #                         held in an Agent. Each session gets a fresh
  #                         BrowserContext + Target + sessionId on the
  #                         shared WS. Feeds `Transport.Actor` a
  #                         `{:shared, ws_pid}` config. Bring-up shared
  #                         with `Strategy.IsolatedProcess` via
  #                         `Strategy.CDPBringUp`.
  #
  #   * `Strategy.PerSession`      — Lightpanda. One shared browser
  #                         process per BEAM, but one WebSocket per
  #                         session (Lightpanda accepts many WS to one
  #                         binary). Feeds `Transport.Actor` a
  #                         `{:fused, ws_url}` config — the actor owns
  #                         its own WireSocket directly, no separate
  #                         socket process. Own bring-up, entirely
  #                         inline — doesn't use `Strategy.CDPBringUp`.
  #
  #   * `Strategy.IsolatedProcess` — One browser process AND one
  #                         WebSocket per session. Slower but isolated.
  #                         Used as a fallback / for browsers we can't
  #                         share. Also feeds `Transport.Actor` a
  #                         `{:shared, ws_pid}` config (the WS just
  #                         isn't actually shared with any other
  #                         session in practice).
  #
  #   * `Strategy.BiDi`            — chromium-bidi. One POST /session +
  #                         one WS per session. Feeds `Transport.Actor`
  #                         a `{:shared, ws_pid}` config with
  #                         `send: :spawn_link` (BiDi's
  #                         WebSocketClient.send_command/4 blocks
  #                         synchronously, unlike CDP's
  #                         WireSocket/WebSocket, so a slow call can't
  #                         be allowed to stall the actor's mailbox —
  #                         see `Transport.Actor`'s moduledoc). Own
  #                         bring-up, entirely inline.
  #
  # Each impl returns the same shape so the surrounding driver code
  # (install_bootstrap, await_page_load, click_aware, …) is unchanged.
  # A driver picks its strategy by module name once, at author time
  # (ChromeCDP always calls Strategy.SharedWS.start_session/1); the one
  # exception is Lightpanda's isolated/external fallback, which calls
  # `transport_mod.start_session/1` polymorphically because it can
  # resolve to either Strategy.IsolatedProcess or (in principle) any
  # other module honoring the same behaviour.
  #
  # `opts` carries exactly three keys, none of them strategy-specific:
  #
  #   * `:session_struct` — the spec's `%SurfBoard.Session{}` template
  #     (id/spec_module/spec/live_view_aware?/base capabilities filled
  #     in; ws_pid/browsing_context left for the strategy to set).
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
