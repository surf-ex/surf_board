defmodule SurfBoard.Browser.Windows do
  @moduledoc false

  # Window/tab and frame management: window_handle, window_handles,
  # focus_window, close_window, window_size, resize_window,
  # maximize_window, window_position, move_window, focus_frame,
  # focus_parent_frame, focus_default_frame. Depends only on
  # Browser.Internal (spec/1) and Browser.Query (find/3, for
  # focus_frame/2).

  alias SurfBoard.Browser.Internal
  alias SurfBoard.Browser.Query
  alias SurfBoard.Session

  @spec window_handle(Session.t()) :: String.t()
  def window_handle(%Session{} = session) do
    {:ok, handle} = Internal.spec(session).windows.window_handle(session)

    handle
  end

  @spec window_handles(Session.t()) :: [String.t()]
  def window_handles(%Session{} = session) do
    {:ok, handles} = Internal.spec(session).windows.window_handles(session)

    handles
  end

  @spec focus_window(Session.t(), String.t()) :: Session.t()
  def focus_window(%Session{} = session, window_handle) do
    {:ok, _} = Internal.spec(session).windows.focus_window(session, window_handle)

    session
  end

  @spec close_window(Session.t()) :: Session.t()
  def close_window(%Session{} = session) do
    {:ok, _} = Internal.spec(session).windows.close_window(session)

    session
  end

  @spec window_size(Session.t()) :: %{String.t() => pos_integer, String.t() => pos_integer}
  def window_size(%Session{} = session) do
    case Internal.spec(session).wire_protocol.get_window_size(session) do
      {:ok, %{width: w, height: h}} -> %{"width" => w, "height" => h}
    end
  end

  @spec resize_window(Session.t(), pos_integer(), pos_integer()) :: Session.t()
  def resize_window(%Session{} = session, width, height) do
    {:ok, _} = Internal.spec(session).wire_protocol.set_window_size(session, width, height)

    session
  end

  @spec maximize_window(Session.t()) :: Session.t()
  def maximize_window(%Session{} = session), do: session

  @spec window_position(Session.t()) :: %{String.t() => pos_integer, String.t() => pos_integer}
  def window_position(%Session{}), do: %{"x" => 0, "y" => 0}

  @spec move_window(Session.t(), pos_integer(), pos_integer()) :: Session.t()
  def move_window(%Session{} = session, _x, _y), do: session

  @spec focus_frame(Query.parent(), SurfBoard.Query.t()) :: Query.parent()
  def focus_frame(%Session{} = session, %SurfBoard.Query{} = query) do
    session
    |> Query.find(query, &Internal.spec(session).frames.focus_frame(session, &1))
  end

  @spec focus_parent_frame(Query.parent()) :: Query.parent()
  def focus_parent_frame(%Session{} = session) do
    {:ok, _} = Internal.spec(session).frames.focus_parent_frame(session)
    session
  end

  @spec focus_default_frame(Query.parent()) :: Query.parent()
  def focus_default_frame(%Session{} = session) do
    {:ok, _} = Internal.spec(session).frames.focus_frame(session, nil)
    session
  end
end
