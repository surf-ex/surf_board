defmodule SurfBoard.Element do
  @moduledoc """
  Defines an Element Struct and interactions with Elements.

  Typically these functions are used in conjunction with a `find`:

  ```
  page
  |> find(Query.css(".some-element"), fn(element) -> Element.click(element) end)
  ```

  These functions can be used to create new actions specific to your application:

  ```
  def create_todo(todo_field, todo_text) do
    todo_field
    |> Element.click()
    |> Element.fill_in(with: todo_text)
    |> Element.send_keys([:enter])
  end
  ```

  ## Retrying

  Unlike `Browser` the actions in `Element` do not retry if the element becomes stale. Instead an exception will be raised.
  """

  alias SurfBoard.{Session, StaleReferenceError}

  defstruct [:url, :session_url, :parent, :id, :spec_module, :handle, screenshots: []]

  @type value ::
          String.t()
          | number()
          | :selected
          | :unselected
  @type attr :: String.t()
  @type keys_to_send :: String.t() | list(atom | String.t())

  # Handle shapes differ by driver:
  #   * CDP/BiDi drivers   — String.t() (CDP objectId or BiDi sharedId)
  #   * LiveView driver    — {:lv_element, css_selector, index, html}
  #   * Lazy element       — {:lazy, ops, idx, parent_id}, resolved on use
  #   * Unresolved         — nil
  @type handle ::
          String.t()
          | nil
          | {:lv_element, String.t(), non_neg_integer(), String.t()}
          | {:lazy, list(), non_neg_integer(), String.t() | nil}

  @type t :: %__MODULE__{
          session_url: String.t(),
          url: String.t(),
          id: String.t(),
          screenshots: list,
          spec_module: module,
          handle: handle()
        }

  @doc """
  Returns the root `Session` for an Element or Session.

  Element parent chains can nest (e.g. element → element → session);
  this walks up to the Session at the root.
  """
  @spec root_session(t() | Session.t()) :: Session.t()
  def root_session(%Session{} = s), do: s
  def root_session(%__MODULE__{parent: parent}), do: root_session(parent)

  @doc """
  Returns the BiDi/CDP WebSocket pid for an Element or Session, walking
  up the parent chain to find the root Session's `:ws_pid`.
  """
  @spec ws_pid(t() | Session.t()) :: pid() | nil
  def ws_pid(%Session{ws_pid: pid}), do: pid
  def ws_pid(%__MODULE__{parent: parent}), do: ws_pid(parent)

  @doc """
  Clears any value set in the element.
  """
  @spec clear(t) :: t

  def clear(%__MODULE__{} = element) do
    spec(element).wire_protocol.clear(root_session(element), element, [])
    |> handle_action_result(element)
  end

  @doc """
  Fills in the element with the specified value.
  """
  @spec fill_in(t, with: String.t() | number()) :: t

  def fill_in(element, with: value) when is_number(value) do
    fill_in(element, with: to_string(value))
  end

  def fill_in(%__MODULE__{} = element, with: value) when is_binary(value) do
    # Silent clear — don't dispatch events, so phx-change only fires
    # for the typed value, not for the intermediate empty state.
    case spec(element).wire_protocol.clear(root_session(element), element, silent: true) do
      {:ok, _} -> :ok
      {:error, _} = err -> throw(err)
    end

    set_value(element, value)
  end

  @doc """
  Clicks the element.
  """
  @spec click(t) :: t

  def click(%__MODULE__{} = element, retry_count \\ 0) do
    case do_click(element) do
      {:error, :obscured} ->
        if retry_count > 4 do
          raise SurfBoard.ElementNotInteractableError, """
          The element you tried to click is obscured by another element.
          """
        else
          click(element, retry_count + 1)
        end

      result ->
        handle_action_result(result, element)
    end
  end

  # Click flow: wraps in log-check when the driver opts in via
  # log_check_interactions?, and branches on the session's
  # live_view_aware? flag for classified-vs-simple dispatch. Mirrors
  # SurfBoard.Browser.visit/2's flow shape for the same reasons (see
  # that function's docs).
  defp do_click(element) do
    session = root_session(element)
    spec = spec(element)

    SurfBoard.Browser.LogChecker.maybe_check_logs(spec.log_check_interactions?, session, fn ->
      click_via_wire(spec, session, element)
    end)
  end

  defp click_via_wire(spec, session, element) do
    if session.live_view_aware? do
      case spec.wire_protocol.click_aware_with_classification(session, element) do
        {:ok, _classification, :ready} ->
          {:ok, nil}

        {:ok, classification, :timeout} when classification in ["navigate", "full_page"] ->
          raise_navigation_timeout(spec, session)

        {:ok, _classification, :timeout} ->
          {:ok, nil}

        err ->
          err
      end
    else
      spec.wire_protocol.click(session, element)
    end
  end

  defp raise_navigation_timeout(spec, session) do
    post =
      case spec.wire_protocol.current_url(session) do
        {:ok, url} -> url
        _ -> nil
      end

    raise SurfBoard.NavigationTimeoutError, %{
      from: nil,
      to: post,
      timeout_ms: 5_000,
      page_state: :unknown,
      page_state_history: []
    }
  end

  @doc """
  Hovers on the element.
  """
  @spec hover(t) :: t

  def hover(%__MODULE__{} = element) do
    spec(element).wire_protocol.hover(element)
    |> handle_action_result(element)
  end

  @doc """
  Touches and holds the element on its top-left corner plus an optional offset.
  """
  @spec touch_down(t, integer, integer) :: t

  def touch_down(%__MODULE__{} = element, x_offset \\ 0, y_offset \\ 0) do
    spec(element).wire_protocol.touch_down(root_session(element), element, x_offset, y_offset)
    |> handle_action_result(element)
  end

  @doc """
  Taps the element.
  """
  @spec tap(t) :: t

  def tap(%__MODULE__{} = element) do
    spec(element).wire_protocol.tap(element)
    |> handle_action_result(element)
  end

  @doc """
  Scroll on the screen from the given element by the given offset using touch events.
  """
  @spec touch_scroll(t, integer, integer) :: t

  def touch_scroll(%__MODULE__{} = element, x_offset, y_offset) do
    fun = spec(element).touch_scroll || fn _e, _x, _y -> {:ok, nil} end

    fun.(element, x_offset, y_offset)
    |> handle_action_result(element)
  end

  @doc """
  Gets the element's text value.

  If the element is not visible, the return value will be `""`.
  """
  @spec text(t) :: String.t()

  def text(%__MODULE__{} = element) do
    spec(element).wire_protocol.text(root_session(element), element)
    |> handle_value_result()
  end

  @doc """
  Gets the value of the element's attribute.
  """
  @spec attr(t, attr()) :: String.t() | nil

  def attr(%__MODULE__{} = element, name) do
    spec(element).wire_protocol.attribute(root_session(element), element, name)
    |> handle_value_result()
  end

  @doc """
  Returns a boolean based on whether or not the element is selected.

  ## Note
  This only really makes sense for options, checkboxes, and radio buttons.
  Everything else will simply return false because they have no notion of
  "selected".
  """
  @spec selected?(t) :: boolean()

  def selected?(%__MODULE__{} = element) do
    spec(element).wire_protocol.selected(root_session(element), element)
    |> handle_boolean_result()
  end

  @doc """
  Returns a boolean based on whether or not the element is visible.
  """
  @spec visible?(t) :: boolean()

  def visible?(%__MODULE__{} = element) do
    spec(element).wire_protocol.displayed(root_session(element), element)
    |> handle_boolean_result()
  end

  @doc """
  Sets the value of the element.
  """
  @spec set_value(t, value()) :: t

  def set_value(%__MODULE__{} = element, value) do
    spec(element).wire_protocol.set_value(root_session(element), element, value)
    |> handle_action_result(element)
  end

  @doc """
  Sends keys to the element.
  """
  @spec send_keys(t, keys_to_send) :: t

  def send_keys(element, text) when is_binary(text) do
    send_keys(element, [text])
  end

  def send_keys(%__MODULE__{} = element, keys) when is_list(keys) do
    spec(element).wire_protocol.send_keys(root_session(element), element, keys)
    |> handle_action_result(element)
  end

  @doc """
  Returns the Element's value.
  """
  @spec value(t) :: String.t()

  def value(element) do
    attr(element, "value")
  end

  @doc """
  Returns a tuple `{width, height}` with the size of the given element.
  """
  @spec size(t) :: {non_neg_integer, non_neg_integer}

  def size(%__MODULE__{} = element) do
    spec(element).wire_protocol.element_size(element)
    |> handle_value_result()
  end

  @doc """
  Returns a tuple `{x, y}` with the coordinates of the left-top corner of given element.
  """
  @spec location(t) :: {non_neg_integer, non_neg_integer}

  def location(%__MODULE__{} = element) do
    spec(element).wire_protocol.element_location(element)
    |> handle_value_result()
  end

  defp spec(%__MODULE__{} = element), do: root_session(element).spec

  defp handle_action_result(result, element) do
    case result do
      {:ok, _} -> element
      {:error, error} -> raise_error(error)
    end
  end

  defp handle_value_result(result) do
    case result do
      {:ok, value} -> value
      {:error, error} -> raise_error(error)
    end
  end

  defp handle_boolean_result(result) do
    case result do
      {:ok, true} -> true
      {:ok, false} -> false
      {:error, error} -> raise_error(error)
    end
  end

  defp raise_error(:stale_reference), do: raise(StaleReferenceError)
  defp raise_error(error), do: raise(RuntimeError, inspect(error))
end

defimpl Inspect, for: SurfBoard.Element do
  def inspect(element, _opts) do
    outer_html =
      try do
        SurfBoard.Element.attr(element, "outerHTML")
      rescue
        _ -> nil
      catch
        _, _ -> nil
      end

    suffix =
      if outer_html do
        "\n" <>
          IO.ANSI.cyan() <>
          "outerHTML:" <>
          IO.ANSI.reset() <>
          IO.ANSI.yellow() <> outer_html <> IO.ANSI.reset()
      else
        ""
      end

    Inspect.Algebra.string(
      "%SurfBoard.Element{" <>
        "id: #{Kernel.inspect(element.id)}, " <>
        "spec_module: #{Kernel.inspect(element.spec_module)}" <>
        "}" <> suffix
    )
  end
end
