defmodule SurfBoard.DriverForTest do
  # Not async: mutates the global :surf_board driver config.
  use ExUnit.Case, async: false

  setup do
    original = Application.fetch_env(:surf_board, :driver)

    on_exit(fn ->
      case original do
        {:ok, v} -> Application.put_env(:surf_board, :driver, v)
        :error -> Application.delete_env(:surf_board, :driver)
      end
    end)

    Application.delete_env(:surf_board, :driver)
    :ok
  end

  describe "resolve_driver/1" do
    test "defaults to :chrome_cdp with no config and no opt" do
      assert SurfBoard.resolve_driver() == :chrome_cdp
    end

    test "follows config :driver when no opt is given" do
      Application.put_env(:surf_board, :driver, :lightpanda)
      assert SurfBoard.resolve_driver() == :lightpanda
    end

    test "explicit opts[:driver] wins over config and the default" do
      Application.put_env(:surf_board, :driver, :chrome_cdp)
      assert SurfBoard.resolve_driver(driver: :lightpanda) == :lightpanda
    end
  end

  describe "driver_module_for/1" do
    test "maps known driver atoms to their module" do
      assert SurfBoard.driver_module_for(:chrome_cdp) == SurfBoard.SpecModule.ChromeCDP
      assert SurfBoard.driver_module_for(:lightpanda) == SurfBoard.SpecModule.LightpandaCDP
      assert SurfBoard.driver_module_for(:chrome) == SurfBoard.SpecModule.ChromeBiDi
    end

    test "falls back to ChromeCDP for an unknown driver" do
      assert SurfBoard.driver_module_for(:nope) == SurfBoard.SpecModule.ChromeCDP
    end
  end
end
