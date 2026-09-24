defmodule SurfBoard.Integration.ResourceLeaksTest do
  @moduledoc """
  State that must not grow with the number of queries or sessions.
  """
  use SurfBoard.Integration.SessionCase, async: false

  @moduletag :chrome_cdp
  @moduletag :lightpanda
  @moduletag skip_test_session: true

  for driver <- [:chrome_cdp, :chrome, :lightpanda] do
    test "#{driver}: finds leave no page-side query entries" do
      {:ok, session} = start_test_session(unquote(driver))

      try do
        visit(session, "/index.html")

        # eager find, lazy find, and a find that never matches
        find(session, Query.css("#header"))
        assert text(session, Query.css("#result")) == "not clicked"
        refute has?(session, Query.css("#missing", wait: 50))

        assert eventually(fn -> pending_queries(session) == 0 end)
      after
        SurfBoard.end_session(session)
      end
    end
  end

  test "chrome_cdp: ended sessions leave nothing in the shared socket's subscriber table" do
    ws_pid = GenServer.call(SurfBoard.Driver.ChromeCDP.default_name(), :get_ws_pid)

    # Warm up once, so one-time global subscriptions are already in.
    {:ok, s} = start_test_session(:chrome_cdp)
    SurfBoard.end_session(s)
    before = subscriber_rows(ws_pid)

    for _ <- 1..3 do
      {:ok, s} = start_test_session(:chrome_cdp)
      SurfBoard.end_session(s)
    end

    assert eventually(fn -> subscriber_rows(ws_pid) <= before end)
  end

  defp pending_queries(session) do
    execute_script(session, "return Object.keys((window.__w && window.__w.queries) || {}).length;", fn n ->
      send(self(), {:pending, n})
    end)

    assert_receive {:pending, n}
    n
  end

  defp subscriber_rows(ws_pid), do: :ets.info(:sys.get_state(ws_pid).subscribers_table, :size)

  defp eventually(fun, tries \\ 20) do
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
