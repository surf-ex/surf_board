defmodule SurfBoard.Browser.Query do
  @moduledoc false

  # The find/query pipeline: find/2,3, all/2, has?/2, has_value?/2,3,
  # has_text?/2,3, has_css?/2,3, has_no_css?/2,3, text/1,2, attr/3,
  # selected?/2, visible?/2, plus every private helper the pipeline
  # needs (execute_query, the ops-pipeline/legacy dispatch, HTML/
  # visibility/selected/count/text validation). The one module nearly
  # every other Browser.* submodule depends on.

  alias SurfBoard.Browser.Internal
  alias SurfBoard.Element
  alias SurfBoard.Query
  alias SurfBoard.Query.ErrorMessage
  alias SurfBoard.Session
  alias SurfBoard.StaleReferenceError

  @type parent :: Element.t() | Session.t()

  @doc """
  Finds and returns one or more DOM element(s) on the page based on the given query.
  """
  @spec find(parent, Query.t()) :: Element.t() | [Element.t()]
  def find(parent, %Query{} = query) do
    do_find(parent, query, Internal.current_time())
  end

  @doc """
  Same as `find/2`, but takes a callback to enact side effects on the found element(s).
  """
  @spec find(parent, Query.t(), (Element.t() -> any())) :: parent
  def find(parent, %Query{} = query, callback) when is_function(callback) do
    results = find(parent, query)
    callback.(results)

    parent
  end

  # Callback form of find_lazy/2: mirrors find/3 but elements are lazy.
  # Caller's callback runs against the lazy element and the parent is
  # returned for piping. The callback may invoke any Element op that
  # routes through call_on_element — pointer/touch ops and frame focus
  # need eager refs and should not be on the lazy path.
  @doc false
  def find_lazy(parent, %Query{} = query, callback) when is_function(callback) do
    results = find_lazy(parent, query)
    callback.(results)
    parent
  end

  # Internal find that returns lazy Elements (no V8 ref-fetch round
  # trip). Use only when the caller will discard the elements after
  # one or two ops — e.g. Browser.text/2, attr/3. Subsequent ops on
  # lazy elements re-resolve via [query, target N] inside W.run.
  #
  # Falls back to eager find inside a frame or a non-default window,
  # since the lazy path's [query, target N] re-resolution isn't taught
  # about frame/window scoping yet (every current spec's wire_protocol
  # supports the pipeline itself — see remote_session?/1).
  @doc false
  def find_lazy(parent, %Query{} = query) do
    session = Internal.get_session(parent)

    if Internal.remote_session?(session) && not Internal.in_frame?(session) &&
         not Internal.in_switched_window?(session) do
      do_find_lazy(parent, query, Internal.current_time())
    else
      do_find(parent, query, Internal.current_time())
    end
  end

  defp do_find_lazy(parent, query, start_time),
    do: do_find_with(parent, query, start_time, lazy: true)

  # The find path can return :stale_reference when a concurrent
  # navigation cleared `window.__w.queries` between the count
  # notification and the element fetch, OR when the find itself timed
  # out but the elements actually exist (sync recheck found > 0). In
  # both cases the right move is to re-run the whole query against the
  # current page — the query budget bounds the total wait.
  defp do_find(parent, query, start_time),
    do: do_find_with(parent, query, start_time, [])

  # Single retry loop shared by do_find and do_find_lazy. Differs only
  # in the `opts` passed to execute_query (lazy: true for the lazy
  # path).
  defp do_find_with(parent, query, start_time, opts) do
    case execute_query(parent, query, opts) do
      {:ok, query} ->
        Query.result(query)

      {:error, :stale_reference} ->
        # `wait: 0` means "the DOM as it is right now", so don't re-query
        # past a stale element either — that would be waiting.
        if Query.wait(query) == 0 or
             Internal.max_time_exceeded?(Internal.get_session(parent), start_time) do
          raise SurfBoard.QueryError, ErrorMessage.message(query, :not_found)
        else
          do_find_with(parent, query, start_time, opts)
        end

      {:error, {:not_found, result}} ->
        query = %{query | result: result}

        case validate_html(parent, query) do
          {:ok, _} ->
            raise SurfBoard.QueryError, ErrorMessage.message(query, :not_found)

          {:error, html_error} ->
            raise SurfBoard.QueryError, ErrorMessage.message(query, html_error)
        end

      {:error, e} ->
        raise SurfBoard.QueryError, ErrorMessage.message(query, e)
    end
  end

  @doc """
  Finds all of the DOM elements that match the CSS selector. If no elements are
  found then an empty list is immediately returned. This is equivalent to calling
  `find(session, css("element", count: nil, minimum: 0))`.
  """
  @spec all(parent, Query.t()) :: [Element.t()]
  def all(parent, %Query{} = query) do
    find(
      parent,
      %{query | conditions: Keyword.merge(query.conditions, count: nil, minimum: 0)}
    )
  end

  @doc """
  Validates that the query returns a result. This can be used to define other
  types of matchers.
  """
  @spec has?(parent, Query.t()) :: boolean()
  def has?(parent, query) do
    case execute_query(parent, query) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Checks if the element is visible on the page
  """
  @spec visible?(parent, Query.t()) :: boolean()
  def visible?(parent, query) do
    parent
    |> has?(query)
  end

  @doc """
  Gets the Element's text value.

  If the element is not visible, the return value will be `""`.
  """
  @spec text(parent) :: String.t()
  @spec text(parent, Query.t()) :: String.t()
  def text(parent, query) do
    parent
    |> find_lazy(query)
    |> Element.text()
  end

  def text(%Session{} = session) do
    session
    |> find_lazy(Query.css("body"))
    |> Element.text()
  end

  @doc """
  Gets the value of the elements attribute.
  """
  @spec attr(parent, Query.t(), String.t()) :: String.t() | nil
  def attr(parent, query, name) do
    parent
    |> find_lazy(query)
    |> Element.attr(name)
  end

  @doc """
  Checks if the element has been selected. Alias for checked?(element)
  """
  @spec selected?(parent, Query.t()) :: boolean()
  def selected?(parent, query) do
    parent
    |> find_lazy(query)
    |> Element.selected?()
  end

  @doc """
  Matches the Element's value with the provided value.
  """
  @spec has_value?(parent, Query.t(), any()) :: boolean()
  @spec has_value?(Element.t(), any()) :: boolean()
  def has_value?(parent, query, value) do
    parent
    |> find_lazy(query)
    |> has_value?(value)
  end

  def has_value?(%Element{} = element, value) do
    session = Element.root_session(element)

    if Internal.remote_session?(session) do
      case Internal.spec(session).wire_protocol.await_value(
             session,
             element,
             value,
             Internal.max_wait_time(session)
           ) do
        {:ok, true} -> true
        _ -> false
      end
    else
      Internal.retry_match(fn -> Element.value(element) == value end)
    end
  end

  @doc """
  Matches the parent's content with the provided text.

  Returns a boolean that indicates if the text was found.
  """
  @spec has_text?(parent, String.t()) :: boolean()
  @spec has_text?(parent, Query.t(), String.t()) :: boolean()
  def has_text?(parent, query, text) do
    parent
    |> find_lazy(query)
    |> has_text?(text)
  end

  def has_text?(%Session{} = session, text) when is_binary(text) do
    session
    |> find_lazy(Query.css("body"))
    |> has_text?(text)
  end

  def has_text?(%Element{} = element, text) when is_binary(text) do
    session = Element.root_session(element)

    if Internal.remote_session?(session) do
      # Single-RT await: V8 polls textContent with MutationObserver +
      # onPatchEnd until match or timeout. Replaces an Elixir-side
      # retry loop that polled Element.text every 25ms.
      case Internal.spec(session).wire_protocol.await_text(
             session,
             element,
             text,
             Internal.max_wait_time(session)
           ) do
        {:ok, true} -> true
        _ -> false
      end
    else
      Internal.retry_match(fn -> Element.text(element) =~ text end)
    end
  end

  @doc """
  Searches for CSS on the page.
  """
  @spec has_css?(parent, Query.t(), String.t()) :: boolean()
  @spec has_css?(parent, String.t()) :: boolean()
  def has_css?(parent, query, css) when is_binary(css) do
    parent
    |> find(query)
    |> has?(Query.css(css, count: :any))
  end

  def has_css?(parent, css) when is_binary(css) do
    parent
    |> has?(Query.css(css, count: :any))
  end

  @doc """
  Searches for CSS that should not be on the page
  """
  @spec has_no_css?(parent, Query.t(), String.t()) :: boolean()
  @spec has_no_css?(parent, String.t()) :: boolean()
  def has_no_css?(parent, query, css) when is_binary(css) do
    parent
    |> find(query)
    |> has?(Query.css(css, count: 0))
  end

  def has_no_css?(parent, css) when is_binary(css) do
    parent
    |> has?(Query.css(css, count: 0))
  end

  @doc false
  def execute_query(parent, query, opts \\ [])

  def execute_query(parent, query, opts) do
    session = Internal.get_session(parent)

    # CDP and BiDi both use the ops pipeline for find+filter in one
    # eval. Push-based: CDP uses Runtime.addBinding, BiDi uses
    # script.channel. The in-frame / switched-window cases keep the
    # legacy element-by-element path until the pipeline is taught
    # about frame scoping.
    if session && Internal.remote_session?(session) &&
         not Internal.in_frame?(session) && not Internal.in_switched_window?(session) do
      execute_query_pipeline(parent, query, opts)
    else
      execute_query_legacy(parent, query)
    end
  end

  # Ops pipeline: compile find + visibility/text/selected filters into one
  # JS evaluation. Both CDP and BiDi use push-based find (CDP:
  # Runtime.addBinding → Runtime.bindingCalled; BiDi: script.channel),
  # dispatched generically through whichever wire_protocol this
  # session's spec names — no spec-identity branching, since
  # every wire_protocol implements both find_elements/3 and
  # find_elements_lazy/3 (see OpsShared).
  defp execute_query_pipeline(parent, query, opts) do
    alias SurfBoard.Clients.CDP.Ops

    session = Internal.get_session(parent)
    lazy? = Keyword.get(opts, :lazy, false)
    wire_protocol = Internal.spec(session).wire_protocol

    with {:ok, _ops, validated} <- Ops.compile_query(parent, query) do
      timeout = query_timeout(session, validated)

      result =
        if lazy? do
          wire_protocol.find_elements_lazy(parent, validated, timeout: timeout)
        else
          wire_protocol.find_elements(parent, validated, timeout: timeout)
        end

      case result do
        {:ok, elements} ->
          with {:ok, elements} <- validate_count(validated, elements),
               {:ok, elements} <- do_at(validated, elements) do
            {:ok, %{validated | result: elements}}
          end

        error ->
          error
      end
    end
  end

  defp execute_query_legacy(parent, query) do
    Internal.retry(fn ->
      try do
        with {:ok, query} <- Query.validate(query),
             {:ok, elements} <-
               Internal.spec(parent).wire_protocol.find_elements(parent, query),
             {:ok, elements} <- validate_visibility(query, elements),
             {:ok, elements} <- validate_text(query, elements),
             {:ok, elements} <- validate_selected(query, elements),
             {:ok, elements} <- validate_count(query, elements),
             {:ok, elements} <- do_at(query, elements) do
          {:ok, %{query | result: elements}}
        end
      rescue
        StaleReferenceError ->
          {:error, :stale_reference}
      end
    end)
  end

  # `all/2` and similar snapshot queries set `minimum: 0`. They want the
  # current matches now, not "wait until something appears." Skip the
  # full max_wait_time budget for those — fall through to the inline
  # sync-count branch quickly.
  #
  # An explicit `wait:` on the query wins over both: `wait: 0` is the
  # "right now" form, and a positive value overrides `:max_wait_time` for
  # this query alone.
  defp query_timeout(session, %SurfBoard.Query{conditions: conditions} = query) do
    # Matched with `is_integer/1` rather than truthiness — `wait: 0` is a
    # meaningful value, not an absent one.
    case SurfBoard.Query.wait(query) do
      wait when is_integer(wait) ->
        wait

      nil ->
        if Keyword.get(conditions, :minimum) == 0,
          do: 50,
          else: Internal.max_wait_time(session)
    end
  end

  defp validate_html(parent, %{html_validation: :button_type} = query) do
    buttons = all(parent, Query.css("button", text: query.selector))

    if Enum.count(buttons) == 1 do
      {:error, :button_with_bad_type}
    else
      {:ok, query}
    end
  end

  defp validate_html(parent, %{html_validation: :bad_label} = query) do
    label_query = Query.css("label", text: query.selector)
    labels = all(parent, label_query)

    case labels do
      [label] ->
        for_attr = Element.attr(label, "for")

        error =
          if for_attr == nil do
            :label_with_no_for
          else
            id_query = Query.css("[id='#{for_attr}']", count: :any)
            matching_id_count = parent |> all(id_query) |> Enum.count()

            {:label_does_not_find_field, for_attr, matching_id_count}
          end

        {:error, error}

      _ ->
        {:ok, query}
    end
  end

  defp validate_html(_, query), do: {:ok, query}

  defp validate_visibility(query, elements) do
    case Query.visible?(query) do
      :any ->
        {:ok, elements}

      true ->
        {:ok, Enum.filter(elements, &Element.visible?(&1))}

      false ->
        {:ok, Enum.reject(elements, &Element.visible?(&1))}
    end
  end

  defp validate_selected(query, elements) do
    case Query.selected?(query) do
      :any ->
        {:ok, elements}

      true ->
        {:ok, Enum.filter(elements, &Element.selected?(&1))}

      false ->
        {:ok, Enum.reject(elements, &Element.selected?(&1))}
    end
  end

  defp validate_count(query, elements) do
    if Query.matches_count?(query, Enum.count(elements)) do
      {:ok, elements}
    else
      {:error, {:not_found, elements}}
    end
  end

  defp do_at(query, elements) do
    case {Query.at_number(query), length(elements)} do
      {:all, _} ->
        {:ok, elements}

      {n, count} when n < count ->
        {:ok, [Enum.at(elements, n)]}

      {_, _} ->
        {:error, {:not_found, elements}}
    end
  end

  defp validate_text(query, elements) do
    text = Query.inner_text(query)

    if text do
      {:ok, Enum.filter(elements, &matching_text?(&1, text))}
    else
      {:ok, elements}
    end
  end

  defp matching_text?(%Element{} = element, text) do
    case Internal.spec(element).wire_protocol.text(Element.root_session(element), element) do
      {:ok, element_text} ->
        element_text =~ ~r/#{Regex.escape(text)}/

      {:error, _} ->
        false
    end
  end
end
