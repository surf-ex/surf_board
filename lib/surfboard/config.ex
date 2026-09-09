defmodule Surfboard.Config do
  @moduledoc """
  Reads application-level Surfboard settings — `config :surfboard, ...`.
  """

  @doc """
  Fetch `key` from `config :surfboard, ...`.
  """
  @spec get(atom, term) :: term
  def get(key, default \\ nil) do
    Application.get_env(:surfboard, key, default)
  end
end
