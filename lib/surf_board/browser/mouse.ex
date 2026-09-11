defmodule SurfBoard.Browser.Mouse do
  @moduledoc false

  # click/2,3 (public wrapper — the actual click logic lives in
  # Browser.LiveViewPatch, since it's inseparable from the patch-await
  # machinery), double_click/1, button_down/1,2, button_up/1,2,
  # hover/2, move_mouse_by/3, touch_down/3,4, touch_up/1, tap/2,
  # touch_move/3, touch_scroll/4. Depends on Browser.Internal,
  # Browser.Query (find/2), and Browser.LiveViewPatch (click/3).

  alias SurfBoard.Browser.Internal
  alias SurfBoard.Browser.LiveViewPatch
  alias SurfBoard.Browser.Query
  alias SurfBoard.Element

  @type parent :: Element.t() | SurfBoard.Session.t()

  @spec click(parent, :left | :middle | :right) :: parent
  @spec click(parent, SurfBoard.Query.t()) :: parent
  @spec click(parent, SurfBoard.Query.t(), keyword) :: parent
  def click(parent, button) when button in [:left, :middle, :right] do
    case Internal.spec(parent).wire_protocol.click_at_cursor(parent, button) do
      {:ok, _} ->
        parent
    end
  end

  def click(parent, query) do
    click(parent, query, [])
  end

  def click(parent, query, opts) when is_list(opts) do
    LiveViewPatch.click(parent, query, opts)
  end

  @spec double_click(parent) :: parent
  def double_click(parent) do
    case Internal.spec(parent).wire_protocol.double_click(parent) do
      {:ok, _} ->
        parent
    end
  end

  @spec button_down(parent, atom) :: parent
  def button_down(parent, button \\ :left) when button in [:left, :middle, :right] do
    case Internal.spec(parent).wire_protocol.button_down(parent, button) do
      {:ok, _} ->
        parent
    end
  end

  @spec button_up(parent, atom) :: parent
  def button_up(parent, button \\ :left) when button in [:left, :middle, :right] do
    case Internal.spec(parent).wire_protocol.button_up(parent, button) do
      {:ok, _} ->
        parent
    end
  end

  @spec hover(parent, SurfBoard.Query.t()) :: parent
  def hover(parent, query) do
    parent
    |> Query.find(query, &Element.hover/1)
  end

  @spec move_mouse_by(parent, integer, integer) :: parent
  def move_mouse_by(parent, x_offset, y_offset) do
    case Internal.spec(parent).wire_protocol.move_mouse_by(parent, x_offset, y_offset) do
      {:ok, _} ->
        parent
    end
  end

  @spec touch_down(parent, integer, integer) :: SurfBoard.Session.t()
  def touch_down(parent, x, y) when is_integer(x) and is_integer(y) do
    case Internal.spec(parent).wire_protocol.touch_down(Element.root_session(parent), nil, x, y) do
      {:ok, _} ->
        parent
    end
  end

  @spec touch_down(parent, SurfBoard.Query.t(), integer, integer) :: SurfBoard.Session.t()
  def touch_down(parent, query, x_offset \\ 0, y_offset \\ 0) do
    parent
    |> Query.find(query, &Element.touch_down(&1, x_offset, y_offset))
  end

  @spec touch_up(parent) :: parent
  def touch_up(parent) do
    case Internal.spec(parent).wire_protocol.touch_up(parent) do
      {:ok, _} ->
        parent
    end
  end

  @spec tap(parent, SurfBoard.Query.t()) :: SurfBoard.Session.t()
  def tap(parent, query) do
    parent
    |> Query.find(query, &Element.tap/1)
  end

  @spec touch_move(parent, non_neg_integer, non_neg_integer) :: parent
  def touch_move(parent, x, y) do
    case Internal.spec(parent).wire_protocol.touch_move(parent, x, y) do
      {:ok, _} ->
        parent
    end
  end

  @spec touch_scroll(parent, SurfBoard.Query.t(), integer, integer) :: parent
  def touch_scroll(parent, query, x, y) do
    parent
    |> Query.find(query, &Element.touch_scroll(&1, x, y))
  end
end
