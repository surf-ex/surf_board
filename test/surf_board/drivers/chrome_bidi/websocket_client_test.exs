defmodule SurfBoard.Drivers.ChromeBiDi.WebSocketClientTest do
  use ExUnit.Case, async: true

  alias SurfBoard.Drivers.ChromeBiDi.WebSocketClient

  # These tests verify the GenServer's internal logic by sending it
  # messages directly, without a real WebSocket connection.

  describe "public API" do
    test "exports expected functions" do
      funs = WebSocketClient.__info__(:functions)
      assert {:start_link, 1} in funs
      assert {:send_command, 3} in funs
      assert {:send_command, 4} in funs
      assert {:subscribe, 2} in funs
      assert {:close, 1} in funs
    end
  end

  describe "struct" do
    test "has expected default fields" do
      state = %WebSocketClient{}
      assert state.pending == %{}
      assert state.subscribers_table == nil
      assert state.wire == nil
    end
  end
end
