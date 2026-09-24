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
