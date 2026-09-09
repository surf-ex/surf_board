defmodule SurfBoard.Integration.SessionCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  using do
    quote do
      use SurfBoard.DSL
      import SurfBoard.Integration.SessionCase
    end
  end

  setup :inject_test_session

  @doc """
  Starts a test session with the default opts for the given driver.
  """
  def start_test_session(opts \\ []) do
    # A little retry room for BiDi's chromium-bidi singleton to settle
    # on a slow first boot — same shape as wallabidi's own integration
    # harness.
    retry(4, fn -> SurfBoard.start_session(opts) end)
  end

  @doc """
  Injects a test session into the test context, using the driver named
  by the test's own `@tag :driver` (module attribute via context), or
  `:chrome_cdp` by default.
  """
  def inject_test_session(%{skip_test_session: true}), do: :ok

  def inject_test_session(context) do
    opts = if driver = context[:driver], do: [driver: driver], else: []
    {:ok, session} = start_test_session(opts)

    on_exit(fn ->
      try do
        SurfBoard.end_session(session)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, %{session: session}}
  end

  defp retry(0, f), do: f.()

  defp retry(times, f) do
    case safe_call(fn -> f.() end) do
      {:ok, session} ->
        {:ok, session}

      _ ->
        Process.sleep(250)
        retry(times - 1, f)
    end
  end

  defp safe_call(fun) do
    try do
      fun.()
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end
  end
end
