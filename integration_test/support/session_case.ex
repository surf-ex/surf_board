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

  # Test-suite-owned driver-atom → module resolution — the library
  # itself has no such table any more (each driver is called directly,
  # by module, everywhere except here, where a `@moduletag driver:
  # ...` on the test case still needs to pick one at runtime).
  @drivers %{
    chrome_cdp: SurfBoard.Driver.ChromeCDP,
    chrome: SurfBoard.Driver.ChromeBiDi,
    lightpanda: SurfBoard.Driver.Lightpanda
  }

  @doc """
  Starts a test session against `driver` (an atom — `:chrome_cdp`,
  `:chrome`, or `:lightpanda`) with the given opts.
  """
  def start_test_session(driver, opts \\ []) do
    mod = Map.fetch!(@drivers, driver)

    # A little retry room for BiDi's chromium-bidi singleton to settle
    # on a slow first boot — same shape as wallabidi's own integration
    # harness.
    retry(4, fn -> mod.start_session(opts) end)
  end

  @doc """
  Injects a test session into the test context, using the driver named
  by the test's own `@tag :driver` (module attribute via context), or
  `:chrome_cdp` by default.
  """
  def inject_test_session(%{skip_test_session: true}), do: :ok

  def inject_test_session(context) do
    driver = context[:driver] || :chrome_cdp
    {:ok, session} = start_test_session(driver, [])

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
