defmodule Surfboard.ConfigTest do
  use ExUnit.Case, async: false

  alias Surfboard.Config

  setup do
    original = Application.get_env(:surfboard, :some_setting)
    on_exit(fn -> restore(:some_setting, original) end)
    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:surfboard, key)
  defp restore(key, value), do: Application.put_env(:surfboard, key, value)

  test "get/2 reads a configured value" do
    Application.put_env(:surfboard, :some_setting, :configured)
    assert Config.get(:some_setting) == :configured
  end

  test "get/2 returns the default when unset" do
    assert Config.get(:some_setting, :the_default) == :the_default
  end

  test "get/2 returns nil by default when unset and no default given" do
    assert Config.get(:some_setting) == nil
  end
end
