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

  # Every driver here always runs Chrome headless (`--headless`/
  # `--headless=new`, hardcoded — no non-headless launch path exists),
  # so there is never a real OS window to maximize, move, or report
  # the position of. Raise rather than silently no-op — like
  # `Permissions.Unsupported`, a caller that thinks it moved/maximized
  # the window needs to know it didn't, rather than have code that
  # assumes it did. `window_size`/`resize_window` are unaffected: they
  # operate on the viewport via `Emulation.setDeviceMetricsOverride`,
  # which works headless.
  @spec maximize_window(Session.t()) :: no_return
  def maximize_window(%Session{spec_module: spec_module}) do
    raise SurfBoard.DriverError.not_supported("maximize_window/1", spec_module)
  end

  @spec window_position(Session.t()) :: no_return
  def window_position(%Session{spec_module: spec_module}) do
    raise SurfBoard.DriverError.not_supported("window_position/1", spec_module)
  end

  @spec move_window(Session.t(), pos_integer(), pos_integer()) :: no_return
  def move_window(%Session{spec_module: spec_module}, _x, _y) do
    raise SurfBoard.DriverError.not_supported("move_window/3", spec_module)
  end

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
