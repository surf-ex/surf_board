defmodule Surfboard.Frames.Unsupported do
  @moduledoc false

  # No-op iframe focus for drivers without iframe support (Lightpanda).

  @behaviour Surfboard.Frames

  @impl true
  def focus_frame(_, _), do: {:ok, nil}

  @impl true
  def focus_parent_frame(_), do: {:ok, nil}
end
