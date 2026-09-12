defmodule SurfBoard.Browser.LiveViewPatch do
  @moduledoc false

  # click/2,3's real implementation, plus the LiveView patch-await
  # machinery it (and Browser.Form's fill_in/3, clear/2,3, send_keys/2)
  # shares: await_patch/2, with_patch_await/4,5, classify_interaction/3
  # and friends. This is one module, not two, because click's own
  # implementation is inseparable from the patch-await machinery — see
  # click_auto/2 → click_with_page_await/2 and click_deferred/2 →
  # do_click_deferred/2 below. Depends on Browser.Internal and
  # Browser.Query (find/find_lazy).

  alias SurfBoard.Browser.Internal
  alias SurfBoard.Browser.Query
  alias SurfBoard.Element
  alias SurfBoard.Session

  @type parent :: Element.t() | Session.t()

  @doc """
  Clicks the mouse on the element returned by the query, dispatching
  through LiveView patch-await handling when applicable. `button/1`
  (cursor-position clicks) and everything not phx-bound/LiveView-aware
  is handled by the plain `find/click` fallback.
  """
  @spec click(parent, SurfBoard.Query.t(), keyword) :: parent
  def click(parent, query, opts) when is_list(opts) do
    case Keyword.get(opts, :await, :auto) do
      :defer -> click_deferred(parent, query)
      _ -> click_auto(parent, query)
    end
  end

  defp click_auto(parent, query) do
    session = Internal.get_session(parent)

    # Lightpanda: route through CDPClient.click_aware which captures
    # pre_page_id, classifies, clicks, awaits page_ready — same shape
    # as do_post_click but in one native call. Avoids the post-click
    # `find` polling fallback that cost LP ~3s per submit-form click.
    #
    # Chrome CDP / BiDi: Element.click's own classify + patch-await +
    # navigation/page-ready logic already handles this.
    # No outer with_patch_await needed — wrapping it would double-wait.
    if session && session.spec_module == SurfBoard.SpecModule.LightpandaCDP &&
         not Internal.in_frame?(session) && not Internal.in_switched_window?(session) do
      click_with_page_await(parent, query)
    else
      parent |> Query.find(query, &Element.click/1)
    end
  end

  # Deferred click: fire the click via the Orchestrator's
  # `click_deferred/2` which returns immediately after dispatching
  # without awaiting `page_ready`. Stash the captured pre-click
  # `pageId` on the session so `SurfBoard.LiveView.await_patch/2`
  # can drain the wait later.
  #
  # In-process LV driver: defer is a no-op (renders synchronously),
  # so just delegate to auto.
  defp click_deferred(parent, query) do
    session = Internal.get_session(parent)

    # No spec (LV driver, or unusual session shape) → fall through to the
    # normal click; there's no awaiting machinery to skip.
    if is_nil(session) or is_nil(session.spec) do
      click_auto(parent, query)
    else
      case Query.find_lazy(parent, query) do
        %Element{} = element ->
          case do_click_deferred(session, element) do
            {:ok, pre_page_id} ->
              %{session | pending_await: {:page_ready_after, pre_page_id}}

            {:error, _} ->
              # Click dispatch failed (e.g. transport issue). Don't stash a
              # half-baked await — fall back to whatever surface error
              # handling the assertion does.
              session
          end

        other ->
          other
      end
    end
  end

  # Fires the click and returns immediately after dispatching, without
  # awaiting the bootstrap's page_ready signal. Returns {:ok,
  # pre_page_id} so the caller can stash it on the session and drain
  # the wait later via SurfBoard.LiveView.await_patch/2. Falls back to
  # a plain click (no classify, no wait) when the session isn't
  # live_view_aware? — there's no awaiting machinery to skip, so
  # :defer collapses to the normal path.
  defp do_click_deferred(%Session{} = session, %Element{} = element) do
    wire = Internal.spec(session).wire_protocol

    if session.live_view_aware? do
      # Stash pre_page_id via a closure-capture sink — the underlying
      # call returns {:ok, classification, :deferred}, and we want the
      # pre_page_id back. A 1-arity sink keeps the call signature
      # explicit without leaking a tuple shape change.
      ref = make_ref()
      parent_pid = self()

      sink = fn pre_page_id ->
        send(parent_pid, {ref, :pre_page_id, pre_page_id})
      end

      result =
        wire.click_aware_with_classification(session, element,
          await: false,
          pre_page_id_sink: sink
        )

      pre_page_id =
        receive do
          {^ref, :pre_page_id, id} -> id
        after
          0 -> nil
        end

      case result do
        {:ok, _classification, :deferred} -> {:ok, pre_page_id}
        {:ok, _classification, :ready} -> {:ok, pre_page_id}
        {:error, _} = err -> err
      end
    else
      case wire.click(session, element) do
        {:ok, _} -> {:ok, nil}
        err -> err
      end
    end
  end

  # click path: find the element, then route the click through
  # CDPClient.click_aware which:
  #   1. captures pre_page_id from the bootstrap
  #   2. classifies the click (patch / navigate / full_page / none)
  #   3. dispatches the click via JS
  #   4. for non-"none" classifications, awaits the bootstrap's
  #      page_ready notification on the new document (push-based, no
  #      polling)
  defp click_with_page_await(parent, query) do
    # Use find_lazy: click_aware does two element ops on the result and
    # discards it. Lazy saves the ref-fetch round-trip at find time
    # (the V8 ref isn't needed — each subsequent op re-resolves via the
    # spliced query+target ops in W.run).
    case Query.find_lazy(parent, query) do
      %Element{} = element ->
        case click_aware_client(element.parent).click_aware(element.parent, element) do
          {:ok, _classification} ->
            parent

          {:error, :timeout} ->
            # Page-ready timeout: the click ran but no page_ready
            # arrived. Fall through; subsequent assertions will retry
            # via their own polling.
            parent

          {:error, _} ->
            Query.find_lazy(parent, query, &Element.click/1)
            parent
        end

      _ ->
        parent |> Query.find_lazy(query, &Element.click/1)
    end
  end

  # Pick the client module that owns a given session's transport.
  # CDP and BiDi expose the same `click_aware/2` shape, so callers
  # can invoke `mod.click_aware(...)` uniformly.
  defp click_aware_client(%Session{spec_module: SurfBoard.SpecModule.ChromeBiDi}),
    do: SurfBoard.Clients.BiDi.Client

  defp click_aware_client(_), do: SurfBoard.Clients.CDP.Client

  @doc """
  Waits for the next LiveView DOM patch.
  """
  @spec await_patch(Session.t(), keyword()) :: Session.t()
  def await_patch(%Session{} = session, opts \\ []) do
    SurfBoard.LiveView.await_patch(session, opts)
  end

  # Wraps an interaction with prepare_patch/await_patch.
  # Sets up the promise before the action, awaits after.
  # Skips if: no live_view_aware? opt-in, or the element is a JS-only
  # click (phx-click without a push command, e.g. JS.toggle).
  @doc false
  def with_patch_await(session_or_parent, query, interaction, fun, opts \\ [])

  def with_patch_await(%Session{} = session, query, interaction, fun, opts) do
    # Classification runs a JS round-trip and only makes sense for a
    # session that opted in via `live_view_aware: true` — a plain
    # scraping/automation session skips this entirely, same as
    # Orchestrator.click_strategy_for/1.
    if session.live_view_aware? and Internal.remote_session?(session) do
      mode = Keyword.get(opts, :await, :auto)

      case classify_interaction(session, query, interaction) do
        :patch when mode == :defer ->
          # Arm a patch promise, run the action, return the session
          # with :armed stashed. Caller drains via
          # `SurfBoard.LiveView.await_patch/2`.
          armed = SurfBoard.LiveView.arm_next_patch(session)
          _ = fun.()
          armed

        :patch ->
          do_patch_await(session, fun)

        :navigate ->
          do_navigate_await(session, fun)

        :full_page ->
          result = fun.()
          SurfBoard.Transport.Protocol.await_next_page_load(session)
          SurfBoard.LiveViewAware.await_liveview_connected(session)
          result

        :none ->
          fun.()
      end
    else
      fun.()
    end
  end

  def with_patch_await(_parent, _query, _interaction, fun, _opts), do: fun.()

  # Classify the interaction: :patch, :navigate, :full_page, or :none.
  defp do_patch_await(session, fun) do
    case SurfBoard.LiveViewAware.prepare_patch(session) do
      :prepared ->
        result = fun.()

        case SurfBoard.LiveViewAware.await_patch(session) do
          :ok ->
            result

          :timeout ->
            # We classified this interaction as :patch (a server-driven
            # patch was expected) but the patch never fired within the
            # budget — the event-driven path fell back to its timeout.
            result

          :page_navigated ->
            SurfBoard.Transport.Protocol.await_next_page_load(session)
            SurfBoard.LiveViewAware.await_liveview_connected(session)
            result
        end

      :no_liveview ->
        fun.()
    end
  end

  defp do_navigate_await(session, fun) do
    # We already know this is a navigation (push_navigate / redirect), not
    # a patch. Don't await_patch — its fixed 5s timeout fires before the
    # slow navigation completes under load, adding pure dead time. Instead
    # go straight to waiting for the new LiveView to connect (which waits
    # for the URL to change first via the pre_url check).
    {:ok, pre_url} = SurfBoard.Protocol.current_url(session)
    result = fun.()
    SurfBoard.LiveViewAware.await_liveview_connected(session, pre_url: pre_url)
    result
  end

  # :patch     — phx-click, phx-submit, phx-change, <.link patch=...>
  # :navigate  — <.link navigate=...> (data-phx-link="redirect")
  # :full_page — plain <a href="..."> (full HTTP navigation)
  # :none      — no LiveView binding, no link
  #
  # Public (not just used by with_patch_await/5 internally) — Browser.Form's
  # fill_in/3 also needs to ask "would this be a :patch?" up front to decide
  # its drain_idle_ms, without going through the full with_patch_await wait.
  @doc false
  def classify_interaction(session, query, interaction) do
    with {:ok, validated} <- SurfBoard.Query.validate(query),
         compiled <- SurfBoard.Query.compile(validated) do
      case compiled do
        {:css, selector} ->
          check_phx_binding(session, selector, interaction)

        {:xpath, xpath} ->
          check_phx_binding_xpath(session, xpath, interaction)
      end
    else
      _ -> :none
    end
  end

  # Both check_phx_binding/* delegate to W.run via a [query, classify_first]
  # opcode pipeline. The single source of truth for the classifier is
  # `W.classify` in priv/surf_board.js — the page-side interpreter
  # exposes it via the `classify_first` accumulator op.
  defp check_phx_binding(session, selector, interaction),
    do: classify_via_query(session, "css", selector, interaction)

  defp check_phx_binding_xpath(session, xpath, interaction),
    do: classify_via_query(session, "xpath", xpath, interaction)

  defp classify_via_query(session, query_type, selector, interaction) do
    ops_json =
      Jason.encode!([
        ["query", query_type, selector],
        ["classify_first", to_string(interaction)]
      ])

    js = "window.__w.run(#{ops_json}, null).meta.classification"

    case SurfBoard.Protocol.eval(session, js) do
      {:ok, result} -> parse_classification(result)
      _ -> :none
    end
  rescue
    _ -> :none
  end

  defp parse_classification("navigate"), do: :navigate
  defp parse_classification("full_page"), do: :full_page
  defp parse_classification("patch"), do: :patch
  defp parse_classification("none"), do: :none
  # If classification JS failed or returned something unexpected, don't
  # default to :patch — that adds a 5s await_patch timeout for no reason.
  # Safer to skip the wait and let the normal retry loop handle it.
  defp parse_classification(_), do: :none
end
