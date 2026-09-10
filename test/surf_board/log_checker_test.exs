defmodule SurfBoard.LogCheckerTest do
  use ExUnit.Case, async: false

  alias SurfBoard.LogChecker

  # async: false — parse_log reads app config (:js_errors, :js_logger)
  # directly, same as before this test moved from asserting on a fake
  # driver's parse_log/1 to asserting on the real one now inlined here.

  defp make_session, do: %{session_url: "test://session/1"}

  setup do
    prev_errors = Application.get_env(:surf_board, :js_errors)
    prev_logger = Application.get_env(:surf_board, :js_logger)

    on_exit(fn ->
      if prev_errors == nil,
        do: Application.delete_env(:surf_board, :js_errors),
        else: Application.put_env(:surf_board, :js_errors, prev_errors)

      if prev_logger == nil,
        do: Application.delete_env(:surf_board, :js_logger),
        else: Application.put_env(:surf_board, :js_logger, prev_logger)
    end)

    {:ok, io} = StringIO.open("")
    Application.put_env(:surf_board, :js_logger, io)
    Application.put_env(:surf_board, :js_errors, true)

    {:ok, io: io}
  end

  defp printed(io) do
    {_input, output} = StringIO.contents(io)
    output
  end

  describe "check_logs!/2" do
    test "returns the value from the function" do
      session = make_session()
      result = LogChecker.check_logs!(session, fn -> {:ok, 42} end)
      assert result == {:ok, 42}
    end

    test "drains log events from mailbox", %{io: io} do
      session = make_session()

      send(
        self(),
        {:bidi_event, "log.entryAdded",
         %{
           "params" => %{
             "level" => "info",
             "type" => "console",
             "text" => "hello world",
             "source" => %{"url" => "http://localhost/page.js"},
             "lineNumber" => 10,
             "columnNumber" => 5
           }
         }}
      )

      LogChecker.check_logs!(session, fn -> :ok end)

      assert printed(io) =~ "hello world"
    end

    test "translates error level to SEVERE and raises JSError" do
      session = make_session()

      send(
        self(),
        {:bidi_event, "log.entryAdded",
         %{
           "params" => %{
             "level" => "error",
             "type" => "javascript",
             "text" => "ReferenceError: x is not defined",
             "source" => %{"url" => "http://localhost/app.js"},
             "lineNumber" => 1,
             "columnNumber" => 0
           }
         }}
      )

      assert_raise SurfBoard.JSError,
                   ~r/http:\/\/localhost\/app\.js 1:0 ReferenceError: x is not defined/,
                   fn ->
                     LogChecker.check_logs!(session, fn -> :ok end)
                   end
    end

    test "does not raise when :js_errors is disabled" do
      Application.put_env(:surf_board, :js_errors, false)
      session = make_session()

      send(
        self(),
        {:bidi_event, "log.entryAdded",
         %{
           "params" => %{
             "level" => "error",
             "type" => "javascript",
             "text" => "ReferenceError: x is not defined",
             "source" => %{"url" => "http://localhost/app.js"}
           }
         }}
      )

      assert LogChecker.check_logs!(session, fn -> :ok end) == :ok
    end

    test "filters out chromium-bidi mapper noise", %{io: io} do
      session = make_session()

      send(
        self(),
        {:bidi_event, "log.entryAdded",
         %{
           "params" => %{
             "level" => "info",
             "type" => "console",
             "text" => "Launching Mapper instance with selfTargetId: ABC123",
             "source" => %{}
           }
         }}
      )

      LogChecker.check_logs!(session, fn -> :ok end)

      assert printed(io) == ""
    end

    test "processes multiple events in order", %{io: io} do
      session = make_session()

      for i <- 1..3 do
        send(
          self(),
          {:bidi_event, "log.entryAdded",
           %{
             "params" => %{
               "level" => "info",
               "type" => "console",
               "text" => "msg #{i}",
               "source" => %{"url" => "http://localhost/test.js"},
               "lineNumber" => i,
               "columnNumber" => 0
             }
           }}
        )
      end

      LogChecker.check_logs!(session, fn -> :ok end)

      output = printed(io)
      assert output =~ "msg 1"
      assert output =~ "msg 2"
      assert output =~ "msg 3"
    end

    test "handles events with no URL", %{io: io} do
      session = make_session()

      send(
        self(),
        {:bidi_event, "log.entryAdded",
         %{
           "params" => %{
             "level" => "info",
             "type" => "console",
             "text" => "inline log",
             "source" => %{}
           }
         }}
      )

      LogChecker.check_logs!(session, fn -> :ok end)

      assert printed(io) =~ "inline log"
    end

    test "does nothing when no events are buffered", %{io: io} do
      session = make_session()
      result = LogChecker.check_logs!(session, fn -> :done end)
      assert result == :done
      assert printed(io) == ""
    end
  end
end
