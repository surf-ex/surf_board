defmodule SurfBoard.Browser.Screenshot do
  @moduledoc false

  # take_screenshot/2 and its private helpers. Depends only on
  # Browser.Internal (get_session/1, spec/1).

  alias SurfBoard.Browser.Internal
  alias SurfBoard.Session

  @type take_screenshot_opt :: {:name, String.t()} | {:log, boolean}

  @spec take_screenshot(term, [take_screenshot_opt]) :: term
  def take_screenshot(screenshotable, opts \\ []) do
    image_data = raw_screenshot(Internal.get_session(screenshotable), screenshotable)

    name =
      opts
      |> Keyword.get(:name, :erlang.system_time())
      |> to_string
      |> remove_illegal_characters

    path = path_for_screenshot(name)

    try do
      write_screenshot!(path, image_data)

      if opts[:log] do
        IO.puts("Screenshot taken, find it at #{build_file_url(path)}")
      end

      Map.update(screenshotable, :screenshots, [], &(&1 ++ [path]))
    rescue
      _ ->
        IO.puts("\nFailed to make a screenshot")

        screenshotable
    end
  end

  defp remove_illegal_characters(string), do: String.replace(string, ~r{<>:"/\\\?\*}, "")

  # Take a full-page screenshot. Returns the raw binary (the Spec
  # contract callers expect), "" on error rather than raising.
  defp raw_screenshot(%Session{} = session, %Session{}) do
    case Internal.spec(session).wire_protocol.take_screenshot(session) do
      {:ok, binary} -> binary
      _ -> ""
    end
  end

  defp raw_screenshot(%Session{} = session, %SurfBoard.Element{}),
    do: raw_screenshot(session, session)

  defp path_for_screenshot(name) do
    "#{screenshot_dir()}/#{name}.png"
  end

  defp write_screenshot!(path, image_data) do
    expanded_path = Path.expand(path)
    :ok = expanded_path |> Path.dirname() |> File.mkdir_p!()

    :ok = File.write!(expanded_path, image_data)

    :ok
  end

  defp screenshot_dir do
    Application.get_env(:surf_board, :screenshot_dir, "#{File.cwd!()}/screenshots")
  end

  defp build_file_url(path) do
    "file://" <> (path |> Path.expand() |> URI.encode())
  end
end
