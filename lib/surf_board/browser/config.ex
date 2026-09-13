defmodule SurfBoard.Browser.Config do
  @moduledoc false

  # Reads application-level SurfBoard settings (`config :surf_board,
  # ...`) — only ever called from Browser.Internal, which resolves
  # `:base_url`/`:max_wait_time` this way so a session's own
  # `session_opts` can override without a global read. Not a
  # consumer-facing module — a caller sets `config :surf_board, key:
  # val` in their own config.exs and never calls this directly.

  @spec get(atom, term) :: term
  def get(key, default \\ nil) do
    Application.get_env(:surf_board, key, default)
  end
end
