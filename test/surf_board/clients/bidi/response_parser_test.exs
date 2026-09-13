defmodule SurfBoard.Clients.BiDi.ResponseParserTest do
  use ExUnit.Case, async: true

  alias SurfBoard.Clients.BiDi.ResponseParser

  describe "extract_value/1" do
    test "extracts string" do
      assert {:ok, "hello"} =
               ResponseParser.extract_value(%{"type" => "string", "value" => "hello"})
    end

    test "extracts number" do
      assert {:ok, 42} = ResponseParser.extract_value(%{"type" => "number", "value" => 42})
    end

    test "extracts boolean" do
      assert {:ok, true} = ResponseParser.extract_value(%{"type" => "boolean", "value" => true})
      assert {:ok, false} = ResponseParser.extract_value(%{"type" => "boolean", "value" => false})
    end

    test "extracts null" do
      assert {:ok, nil} = ResponseParser.extract_value(%{"type" => "null"})
    end

    test "extracts undefined as nil" do
      assert {:ok, nil} = ResponseParser.extract_value(%{"type" => "undefined"})
    end

    test "extracts array" do
      assert {:ok, ["a", "b"]} =
               ResponseParser.extract_value(%{
                 "type" => "array",
                 "value" => [
                   %{"type" => "string", "value" => "a"},
                   %{"type" => "string", "value" => "b"}
                 ]
               })
    end

    test "extracts nested result wrapper" do
      assert {:ok, "inner"} =
               ResponseParser.extract_value(%{
                 "result" => %{"type" => "string", "value" => "inner"}
               })
    end

    test "extracts node with shared ID" do
      node = %{"type" => "node", "sharedId" => "node-abc", "value" => %{}}

      assert {:ok, {:node, "node-abc", ^node}} = ResponseParser.extract_value(node)
    end

    test "returns error for unexpected values" do
      assert {:error, {:unexpected_value, _}} =
               ResponseParser.extract_value(%{"something" => "unknown"})
    end
  end

  describe "extract_screenshot/1" do
    test "decodes base64 screenshot data" do
      encoded = Base.encode64("fake-png-data")
      assert {:ok, "fake-png-data"} = ResponseParser.extract_screenshot(%{"data" => encoded})
    end
  end

  describe "extract_cookies/1" do
    test "normalizes cookie format" do
      response = %{
        "cookies" => [
          %{
            "name" => "token",
            "value" => %{"value" => "abc123"},
            "domain" => "localhost",
            "path" => "/",
            "secure" => false,
            "httpOnly" => false,
            "expiry" => nil
          }
        ]
      }

      assert {:ok, [cookie]} = ResponseParser.extract_cookies(response)
      assert cookie["name"] == "token"
      assert cookie["value"] == "abc123"
    end
  end

  describe "check_error/1" do
    test "maps stale element reference" do
      assert {:error, :stale_reference} =
               ResponseParser.check_error({:error, {"stale element reference", "msg"}})
    end

    test "maps invalid selector" do
      assert {:error, :invalid_selector} =
               ResponseParser.check_error({:error, {"invalid selector", "msg"}})
    end

    test "maps element click intercepted to obscured" do
      assert {:error, :obscured} =
               ResponseParser.check_error({:error, {"element click intercepted", "msg"}})
    end

    test "passes through ok values" do
      assert {:ok, "data"} = ResponseParser.check_error({:ok, "data"})
    end

    test "passes through unknown errors" do
      assert {:error, {"unknown", "msg"}} =
               ResponseParser.check_error({:error, {"unknown", "msg"}})
    end
  end
end
