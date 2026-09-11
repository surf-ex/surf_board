defmodule SurfBoard.Browser.Navigation do
  @moduledoc false

  # visit/2, current_url/1, current_path/1, page_title/1, page_source/1,
  # status/1, response_headers/1. Depends on Browser.Internal
  # (spec/1, remote_session?/1, request_url/2, base_url/1).

  alias SurfBoard.Browser.Internal
  alias SurfBoard.NoBaseUrlError
  alias SurfBoard.Session

  @spec visit(Session.t(), String.t()) :: Session.t()
  def visit(%Session{} = session, path) do
    uri = URI.parse(path)

    result =
      cond do
        uri.host == nil && String.length(Internal.base_url(session)) == 0 ->
          raise NoBaseUrlError, path

        uri.host ->
          do_visit(session, path)

        true ->
          do_visit(session, Internal.request_url(session, path))
      end

    case result do
      {:error, reason} ->
        raise SurfBoard.NavigationError, %{url: path, reason: reason}

      _ ->
        :ok
    end

    # Opt-in only (`live_view_aware: true`): wait for the LiveView client
    # to connect (near-instant once joined). A plain scraping/automation
    # session skips this entirely — it's a LiveView-specific concern, not
    # something every remote-spec visit should pay for. Best-effort:
    # the result is advisory, downstream actions still auto-wait.
    if session.live_view_aware? and Internal.remote_session?(session) do
      _ = SurfBoard.LiveViewAware.await_liveview_connected(session)
    end

    session
  end

  # Navigate + log-check wrap (spec.log_check_interactions?) +
  # LiveView-connect await when live_view_aware? — the same await as
  # visit/2's own outer one above (gated on live_view_aware? alone here
  # vs. live_view_aware? and remote_session? there). Both run; this
  # mirrors the pre-existing Orchestrator.visit/3 behavior exactly
  # rather than removing what looks like a redundant second await.
  defp do_visit(%Session{} = session, url) do
    spec = Internal.spec(session)

    flow = fn ->
      result = spec.wire_protocol.visit(session, url)

      if session.live_view_aware?,
        do: _ = SurfBoard.LiveViewAware.await_liveview_connected(session)

      result
    end

    SurfBoard.LogChecker.maybe_check_logs(spec.log_check_interactions?, session, flow)
  end

  @spec current_url(Session.t()) :: String.t()
  def current_url(%Session{} = session) do
    {:ok, url} = Internal.spec(session).wire_protocol.current_url(session)
    url
  end

  @spec current_path(Session.t()) :: String.t()
  def current_path(%Session{} = session) do
    {:ok, path} = Internal.spec(session).wire_protocol.current_path(session)
    path
  end

  @spec page_title(Session.t()) :: String.t()
  def page_title(%Session{} = session) do
    {:ok, title} = Internal.spec(session).wire_protocol.page_title(session)
    title
  end

  @spec page_source(Session.t()) :: String.t()
  def page_source(%Session{} = session) do
    {:ok, source} = Internal.spec(session).wire_protocol.page_source(session)
    source
  end

  @spec status(Session.t()) :: non_neg_integer() | nil
  def status(%Session{} = session) do
    case last_response(session) do
      %{status: status} -> status
      _ -> nil
    end
  end

  @spec response_headers(Session.t()) :: %{String.t() => String.t()} | nil
  def response_headers(%Session{} = session) do
    case last_response(session) do
      %{headers: headers} when is_map(headers) -> headers
      _ -> nil
    end
  end

  defp last_response(%Session{} = session) do
    if Internal.remote_session?(session) do
      SurfBoard.Transport.Protocol.last_response(session)
    end
  end
end
