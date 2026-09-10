defmodule SurfBoard.LauncherTest do
  use ExUnit.Case, async: true

  alias SurfBoard.Launcher

  defmodule FakeConfig do
    defstruct [:tag]
  end

  test "start_link/1 wraps strategy + config, readable via info/1" do
    {:ok, launcher} = Launcher.start_link(strategy: :fake_strategy, config: %FakeConfig{tag: :x})

    assert %Launcher{strategy: :fake_strategy, config: %FakeConfig{tag: :x}} =
             Launcher.info(launcher)
  end

  test "start_link/1 with :name is addressable by that name" do
    name = :"launcher_test_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Launcher.start_link(name: name, strategy: :fake_strategy, config: %FakeConfig{})

    assert %Launcher{strategy: :fake_strategy} = Launcher.info(name)
  end

  test "two independently-started launchers never share state" do
    {:ok, a} = Launcher.start_link(strategy: :fake_strategy, config: %FakeConfig{tag: :a})
    {:ok, b} = Launcher.start_link(strategy: :fake_strategy, config: %FakeConfig{tag: :b})

    Launcher.get_or_compute(a, fn -> :value_a end)
    Launcher.get_or_compute(b, fn -> :value_b end)

    assert Launcher.info(a).cached == :value_a
    assert Launcher.info(b).cached == :value_b
  end

  test "get_or_compute/3 computes once and caches" do
    {:ok, launcher} = Launcher.start_link(strategy: :fake_strategy, config: %FakeConfig{})
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    compute = fn -> Agent.get_and_update(counter, &{&1 + 1, &1 + 1}) end

    assert Launcher.get_or_compute(launcher, compute) == 1
    assert Launcher.get_or_compute(launcher, compute) == 1
    assert Agent.get(counter, & &1) == 1
  end

  test "get_or_compute/3 recomputes when the cached value fails is_alive_fun" do
    {:ok, launcher} = Launcher.start_link(strategy: :fake_strategy, config: %FakeConfig{})
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    compute = fn -> Agent.get_and_update(counter, &{&1 + 1, &1 + 1}) end
    is_alive = fn value -> value != 1 end

    assert Launcher.get_or_compute(launcher, compute, is_alive) == 1
    assert Launcher.get_or_compute(launcher, compute, is_alive) == 2
    assert Launcher.get_or_compute(launcher, compute, is_alive) == 2
  end

  test "get_or_compute/3 serializes concurrent first-callers to one compute" do
    {:ok, launcher} = Launcher.start_link(strategy: :fake_strategy, config: %FakeConfig{})
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    compute = fn ->
      Process.sleep(20)
      Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
    end

    results =
      1..20
      |> Task.async_stream(fn _ -> Launcher.get_or_compute(launcher, compute) end,
        max_concurrency: 20,
        ordered: false
      )
      |> Enum.map(fn {:ok, v} -> v end)

    assert Enum.all?(results, &(&1 == 1))
    assert Agent.get(counter, & &1) == 1
  end
end
