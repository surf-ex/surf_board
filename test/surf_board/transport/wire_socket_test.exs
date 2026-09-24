defmodule SurfBoard.Transport.WireSocketTest do
  use ExUnit.Case, async: true

  alias SurfBoard.Transport.{WebSocket, WireSocket}

  test "a rejected upgrade fails connect/1 with the status and body" do
    url =
      fake_server(fn socket ->
        body = "nope"
        :gen_tcp.send(socket, "HTTP/1.1 403 Forbidden\r\nContent-Length: 4\r\n\r\n" <> body)
      end)

    assert {:error, {:upgrade_rejected, 403, "nope"}} = WireSocket.connect(url)
  end

  test "a close frame from the peer fails in-flight calls and stops the socket" do
    url =
      fake_server(fn socket ->
        accept_upgrade(socket)
        # wait for the client's command, then close instead of replying
        {:ok, _frame} = :gen_tcp.recv(socket, 0, 2_000)
        :gen_tcp.send(socket, <<0x88, 0x02, 1000::16>>)
        Process.sleep(:infinity)
      end)

    {:ok, ws} = WebSocket.start(url)
    ref = Process.monitor(ws)

    assert {:error, :session_closed} =
             WebSocket.send_sync(ws, "Browser.getVersion", %{}, timeout: 2_000)

    assert_receive {:DOWN, ^ref, :process, ^ws, _}, 1_000
  end

  # ----- fake server -----

  defp fake_server(handler) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)
      handler.(socket)
    end)

    "ws://127.0.0.1:#{port}/devtools/browser/test"
  end

  defp accept_upgrade(socket) do
    {:ok, request} = :gen_tcp.recv(socket, 0, 2_000)
    [_, key] = Regex.run(~r/sec-websocket-key:\s*(\S+)/i, request)
    accept = :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()

    :gen_tcp.send(
      socket,
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" <>
        "Sec-WebSocket-Accept: #{accept}\r\n\r\n"
    )
  end
end
