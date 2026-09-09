defmodule SurfBoard.Config do
  @moduledoc """
  Reads application-level SurfBoard settings — `config :surf_board, ...`.
  """

  @doc """
  Fetch `key` from `config :surf_board, ...`.
  """
  @spec get(atom, term) :: term
  def get(key, default \\ nil) do
    Application.get_env(:surf_board, key, default)
  end
end
