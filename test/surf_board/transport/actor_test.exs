defmodule SurfBoard.Transport.ActorTest do
  use ExUnit.Case, async: true

  alias SurfBoard.Transport.Actor

  describe "module shape" do
    test "exports the expected functions" do
      funs = Actor.__info__(:functions)
      assert {:start_link, 1} in funs
    end

    test "has expected default state fields" do
      state = %Actor{}
      assert state.pending_calls == %{}
      assert state.session == nil
      assert state.config == nil
      assert state.wire_socket == nil
    end
  end

  describe "find_timeout handler" do
    # When the resolve event and the timer fire in close succession,
    # the timer handler must NOT drop the resolved payload — the
    # awaiter still needs to harvest it.
    test "preserves an already-resolved waiter when timer fires" do
      payload = %{"ok" => true, "elements" => []}

      state = %Actor{
        find_waiters: %{"q1" => {:resolved, payload}}
      }

      assert {:noreply, new_state} = Actor.handle_info({:find_timeout, "q1"}, state)

      assert Map.get(new_state.find_waiters, "q1") == {:resolved, payload}
    end

    test "drops an unknown waiter" do
      state = %Actor{find_waiters: %{}}
      assert {:noreply, new_state} = Actor.handle_info({:find_timeout, "q1"}, state)
      assert new_state.find_waiters == %{}
    end

    test "drops a pending unblocked waiter" do
      state = %Actor{find_waiters: %{"q1" => {:pending, make_ref(), nil}}}
      assert {:noreply, new_state} = Actor.handle_info({:find_timeout, "q1"}, state)
      assert new_state.find_waiters == %{}
    end
  end

  describe "page-ready waiters" do
    alias SurfBoard.Transport.Common

    test "every waiter is woken by the next page_ready" do
      {state, [a, b]} = add_waiters(%Actor{last_page_id: "p1"}, 2, "p1")

      state = Common.update_last_page_id(state, "p2")

      assert_receive {^a, :ok}
      assert_receive {^b, :ok}
      assert state.page_ready_waiters == []
    end

    test "a timeout answers only its own waiter" do
      {state, [a, b]} = add_waiters(%Actor{last_page_id: "p1"}, 2, "p1")

      state = Common.handle_page_ready_timeout(state, {self(), a})

      assert_receive {^a, :timeout}
      refute_received {^b, _}
      assert [{{_, ^b}, _, _}] = state.page_ready_waiters
    end

    defp add_waiters(state, n, pre_page_id) do
      Enum.map_reduce(1..n, state, fn _, state ->
        tag = make_ref()

        {:noreply, state} =
          Common.await_page_ready_after(state, pre_page_id, 60_000, {self(), tag})

        {tag, state}
      end)
      |> then(fn {tags, state} -> {state, tags} end)
    end
  end

  # A fused actor owns its socket, so socket traffic and its own
  # messages share one mailbox — the socket clause must not eat these.
  describe "fused-mode non-socket messages" do
    setup do
      config = %Actor.Config{socket: {:fused, "ws://unused"}, load: :buffer, wire: nil}
      {:ok, state: %Actor{config: config}}
    end

    test "owner :DOWN stops the actor", %{state: state} do
      ref = make_ref()
      state = %{state | owner_ref: ref}

      assert {:stop, :normal, _} =
               Actor.handle_info({:DOWN, ref, :process, self(), :killed}, state)
    end

    test "find timeout is handled", %{state: state} do
      state = %{state | find_waiters: %{"q1" => {:pending, make_ref(), nil}}}
      assert {:noreply, new_state} = Actor.handle_info({:find_timeout, "q1"}, state)
      assert new_state.find_waiters == %{}
    end
  end
end
