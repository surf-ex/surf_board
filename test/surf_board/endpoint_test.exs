defmodule SurfBoard.EndpointTest do
  use ExUnit.Case, async: true

  alias SurfBoard.Endpoint

  defmodule FakeConfig do
    defstruct [:tag]
  end

  test "start_link/1 wraps strategy + config, readable via info/1" do
    {:ok, endpoint} = Endpoint.start_link(strategy: :fake_strategy, config: %FakeConfig{tag: :x})

    assert %Endpoint{strategy: :fake_strategy, config: %FakeConfig{tag: :x}} =
             Endpoint.info(endpoint)
  end

  test "start_link/1 with :name is addressable by that name" do
    name = :"endpoint_test_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Endpoint.start_link(name: name, strategy: :fake_strategy, config: %FakeConfig{})

    assert %Endpoint{strategy: :fake_strategy} = Endpoint.info(name)
  end

  test "two independently-started endpoints never share state" do
    {:ok, a} = Endpoint.start_link(strategy: :fake_strategy, config: %FakeConfig{tag: :a})
    {:ok, b} = Endpoint.start_link(strategy: :fake_strategy, config: %FakeConfig{tag: :b})

    Endpoint.get_or_compute(a, fn -> :value_a end)
    Endpoint.get_or_compute(b, fn -> :value_b end)

    assert Endpoint.info(a).cached == :value_a
    assert Endpoint.info(b).cached == :value_b
  end

  test "get_or_compute/3 computes once and caches" do
    {:ok, endpoint} = Endpoint.start_link(strategy: :fake_strategy, config: %FakeConfig{})
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    compute = fn -> Agent.get_and_update(counter, &{&1 + 1, &1 + 1}) end

    assert Endpoint.get_or_compute(endpoint, compute) == 1
    assert Endpoint.get_or_compute(endpoint, compute) == 1
    assert Agent.get(counter, & &1) == 1
  end

  test "get_or_compute/3 recomputes when the cached value fails is_alive_fun" do
    {:ok, endpoint} = Endpoint.start_link(strategy: :fake_strategy, config: %FakeConfig{})
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    compute = fn -> Agent.get_and_update(counter, &{&1 + 1, &1 + 1}) end
    is_alive = fn value -> value != 1 end

    assert Endpoint.get_or_compute(endpoint, compute, is_alive) == 1
    assert Endpoint.get_or_compute(endpoint, compute, is_alive) == 2
    assert Endpoint.get_or_compute(endpoint, compute, is_alive) == 2
  end

  test "get_or_compute/3 serializes concurrent first-callers to one compute" do
    {:ok, endpoint} = Endpoint.start_link(strategy: :fake_strategy, config: %FakeConfig{})
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    compute = fn ->
      Process.sleep(20)
      Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
    end

    results =
      1..20
      |> Task.async_stream(fn _ -> Endpoint.get_or_compute(endpoint, compute) end,
        max_concurrency: 20,
        ordered: false
      )
      |> Enum.map(fn {:ok, v} -> v end)

    assert Enum.all?(results, &(&1 == 1))
    assert Agent.get(counter, & &1) == 1
  end
end
