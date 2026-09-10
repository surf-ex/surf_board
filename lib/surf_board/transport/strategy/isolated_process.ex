defmodule SurfBoard.Transport.Strategy.IsolatedProcess do
  @moduledoc false

  # Transport: a fresh browser process AND a fresh WebSocket per
  # session. The slowest model — every session pays a binary-startup
  # cost — but cleanest isolation: each session gets a private
  # browser, no contention with peers.
  #
  # Suitable when the browser doesn't multiplex CDP sessions well over
  # one connection (or has bugs that surface under concurrent load).
  # Currently the default Lightpanda transport.

  @behaviour SurfBoard.Transport.Strategy

  alias SurfBoard.Transport
  alias SurfBoard.WebSocket

  defmodule Config do
    @moduledoc false
    # Either `ws_url` (connect to an already-running browser — the
    # "external" case) or `spawn_fun`+`url_fun` (spawn a fresh private
    # browser process, then derive its ws_url from the returned pid —
    # the "isolated" case). Exactly one of the two shapes, never both.
    defstruct [:ws_url, :spawn_fun, :url_fun]
  end

  @impl true
  @spec start_session(keyword) :: {:ok, SurfBoard.Session.t()} | {:error, term}
  def start_session(opts) do
    template = Keyword.fetch!(opts, :session_struct)
    config = Keyword.fetch!(opts, :config)
    {:ok, ws_url, server_pid} = ensure_server(config)

    with {:ok, ws_pid} <- WebSocket.start_link(ws_url),
         {:ok, %{"targetId" => target_id}} <-
           WebSocket.send_sync(ws_pid, "Target.createTarget", %{url: "about:blank"}),
         {:ok, session_id} <- Transport.attach_to_target(ws_pid, target_id) do
      teardown = fn _session ->
        Transport.close_ws(ws_pid)
        if is_pid(server_pid), do: stop_server(server_pid)
        :ok
      end

      acquired = %{
        ws_pid: ws_pid,
        target_id: target_id,
        session_id: session_id,
        browser_context_id: nil,
        teardown_fun: teardown,
        capabilities: %{
          target_id: target_id,
          flat_session_id: true,
          server_pid: server_pid
        }
      }

      Transport.start_session_from(acquired, template, opts)
    else
      err ->
        # Failed mid-bring-up: kill the spawned binary so we don't leak
        # a Lightpanda process per failed session.
        if is_pid(server_pid), do: stop_server(server_pid)
        err
    end
  end

  defp ensure_server(%Config{ws_url: url}) when is_binary(url) do
    {:ok, url, nil}
  end

  defp ensure_server(%Config{spawn_fun: spawn_fun, url_fun: url_fun})
       when is_function(spawn_fun, 0) and is_function(url_fun, 1) do
    {:ok, server} = spawn_fun.()
    ws_url = url_fun.(server)
    {:ok, ws_url, server}
  end

  defp stop_server(pid) do
    try do
      GenServer.stop(pid, :normal, 5_000)
    catch
      _, _ -> :ok
    end

    :ok
  end
end
