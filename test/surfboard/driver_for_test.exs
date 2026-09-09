defmodule Surfboard.DriverForTest do
  # Not async: mutates the global :surfboard driver config.
  use ExUnit.Case, async: false

  setup do
    original = Application.fetch_env(:surfboard, :driver)

    on_exit(fn ->
      case original do
        {:ok, v} -> Application.put_env(:surfboard, :driver, v)
        :error -> Application.delete_env(:surfboard, :driver)
      end
    end)

    Application.delete_env(:surfboard, :driver)
    :ok
  end

  describe "resolve_driver/1" do
    test "defaults to :chrome_cdp with no config and no opt" do
      assert Surfboard.resolve_driver() == :chrome_cdp
    end

    test "follows config :driver when no opt is given" do
      Application.put_env(:surfboard, :driver, :lightpanda)
      assert Surfboard.resolve_driver() == :lightpanda
    end

    test "explicit opts[:driver] wins over config and the default" do
      Application.put_env(:surfboard, :driver, :chrome_cdp)
      assert Surfboard.resolve_driver(driver: :lightpanda) == :lightpanda
    end
  end

  describe "driver_module_for/1" do
    test "maps known driver atoms to their module" do
      assert Surfboard.driver_module_for(:chrome_cdp) == Surfboard.Drivers.ChromeCDP
      assert Surfboard.driver_module_for(:lightpanda) == Surfboard.Drivers.LightpandaCDP
      assert Surfboard.driver_module_for(:chrome) == Surfboard.Drivers.ChromeBiDi
    end

    test "falls back to ChromeCDP for an unknown driver" do
      assert Surfboard.driver_module_for(:nope) == Surfboard.Drivers.ChromeCDP
    end
  end
end
