defmodule SurfBoard.Clients.Frames.Unsupported do
  @moduledoc false

  # No-op iframe focus for drivers without iframe support (Lightpanda).

  @behaviour SurfBoard.Clients.Frames

  @impl true
  def focus_frame(_, _), do: {:ok, nil}

  @impl true
  def focus_parent_frame(_), do: {:ok, nil}
end
