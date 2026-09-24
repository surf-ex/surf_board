defmodule SurfBoard.Integration.OsProcessCleanupTest do
  @moduledoc """
  Browser processes and their files must not outlive the server that
  launched them.
  """
  use SurfBoard.Integration.SessionCase, async: false

  alias SurfBoard.Driver.BiDi.Server, as: BidiServer
  alias SurfBoard.Driver.Chrome.Server, as: ChromeServer

  @moduletag :chrome_cdp
  @moduletag skip_test_session: true

  test "a supervised Chrome server removes its process and profile on shutdown" do
    {:ok, sup} = Supervisor.start_link([ChromeServer], strategy: :one_for_one)
    [{_, server, _, _}] = Supervisor.which_children(sup)
    _ = ChromeServer.ws_url(server)
    %{os_pid: os_pid, user_data_dir: dir} = :sys.get_state(server)
    assert File.dir?(dir)

    Supervisor.stop(sup)

    refute File.exists?(dir)
    assert eventually(fn -> not os_alive?(os_pid) end)
  end

  test "stopping the BiDi sidecar takes down the Chrome it launched for open sessions" do
    {:ok, sup} = Supervisor.start_link([BidiServer], strategy: :one_for_one)
    [{_, server, _, _}] = Supervisor.which_children(sup)
    bidi_url = server |> BidiServer.ws_url() |> String.replace_suffix("/session", "") |> String.replace("ws:", "http:")

    {:ok, _session} = SurfBoard.Driver.ChromeBiDi.start_session(bidi_url: bidi_url)
    %{os_pid: node_pid} = :sys.get_state(server)
    launched = descendants(node_pid)
    assert launched != []

    Supervisor.stop(sup)

    assert eventually(fn -> not Enum.any?(launched, &os_alive?/1) end)
  end

  defp descendants(os_pid) do
    {out, 0} = System.cmd("ps", ["-A", "-o", "pid=,ppid="])

    children =
      out
      |> String.split("\n", trim: true)
      |> Enum.map(fn line -> line |> String.split() |> Enum.map(&String.to_integer/1) end)
      |> Enum.group_by(fn [_pid, ppid] -> ppid end, fn [pid, _ppid] -> pid end)

    collect(Map.get(children, os_pid, []), children)
  end

  defp collect(pids, children),
    do: Enum.flat_map(pids, &[&1 | collect(Map.get(children, &1, []), children)])

  defp os_alive?(os_pid) do
    {out, _} = System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(os_pid)])
    # a zombie is dead, just not yet reaped by its (re)parent
    out != "" and not String.starts_with?(out, "Z")
  end

  defp eventually(fun, tries \\ 40) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(50)
        eventually(fun, tries - 1)
    end
  end
end
