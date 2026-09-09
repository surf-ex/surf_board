defmodule SurfBoard.MetadataTest do
  use ExUnit.Case, async: true

  alias SurfBoard.Metadata

  test "append/2 with nil metadata returns the user agent unchanged" do
    assert Metadata.append("MyAgent/1.0", nil) == "MyAgent/1.0"
  end

  test "append/2 with a binary appends it directly" do
    assert Metadata.append("MyAgent/1.0", "extra") == "MyAgent/1.0/extra"
  end

  test "format/1 then extract/1 round-trips a map" do
    metadata = %{session_id: "abc123", pid: "<0.123.0>"}
    ua = Metadata.append("MyAgent/1.0", metadata)

    assert Metadata.extract(ua) == metadata
  end

  test "format/1 then extract/1 round-trips a list" do
    metadata = [foo: 1, bar: "baz"]
    ua = Metadata.append("MyAgent/1.0", metadata)

    assert Metadata.extract(ua) == metadata
  end

  test "extract/1 returns an empty map when no metadata is present" do
    assert Metadata.extract("MyAgent/1.0") == %{}
  end

  test "parse/1 raises BadMetadataError when decoded content isn't the expected {:v1, _} tuple" do
    # Valid base64, but the decoded term isn't a {:v1, metadata} tuple —
    # exercises the `_ -> raise` branch specifically, as opposed to a
    # malformed base64 string (which fails earlier, in Base.url_decode64!).
    encoded = :erlang.term_to_binary(:not_a_v1_tuple) |> Base.url_encode64()

    assert_raise SurfBoard.BadMetadataError, fn ->
      Metadata.parse(encoded)
    end
  end
end
