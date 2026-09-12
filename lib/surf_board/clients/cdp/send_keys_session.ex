defmodule SurfBoard.Clients.CDP.SendKeysSession do
  @moduledoc false

  # Session-scoped send_keys for CDP: dispatches a key sequence to
  # whatever element currently has page focus via
  # Input.dispatchKeyEvent. The wire send goes through
  # Clients.CDP.Client (aliased as CDPClient below), the same as
  # Clients.CDP.Dialogs/Permissions do.

  @behaviour SurfBoard.SendKeysSession

  alias SurfBoard.Clients.CDP.Client, as: CDPClient
  alias SurfBoard.Session

  @doc """
  Send keys to whatever element currently has focus on the page.
  Atoms like `:tab`, `:enter` map to real key events via
  `Input.dispatchKeyEvent`.
  """
  @impl true
  @spec send_keys_to_session(Session.t(), [String.t() | atom]) :: {:ok, nil}
  def send_keys_to_session(%Session{} = session, keys) when is_list(keys) do
    # Build the full ordered list of CDP commands first, then send all
    # but the last as `cdp_cast` (fire-and-forget — pipelines on the
    # wire) and the last as `cdp_send` (awaits, ensures the keystrokes
    # have actually flushed before we return). For an N-char string
    # this collapses 2N round-trips to 1.
    cmds =
      Enum.flat_map(keys, fn
        key when is_atom(key) ->
          {code, key_val} = key_mapping(key)
          key_event_pair(code, key_val)

        text when is_binary(text) ->
          Enum.flat_map(String.graphemes(text), fn char ->
            [
              {"Input.dispatchKeyEvent", %{type: "keyDown", text: char}},
              {"Input.dispatchKeyEvent", %{type: "keyUp", text: char}}
            ]
          end)
      end)

    pipeline_cdp(session, cmds)
    {:ok, nil}
  end

  # Send a list of CDP commands with maximum pipelining: cast all but
  # the last, sync-send the last so the caller sees a settled state.
  defp pipeline_cdp(_session, []), do: {:ok, nil}

  defp pipeline_cdp(session, [{method, params}]) do
    CDPClient.cdp_send(session, method, params)
  end

  defp pipeline_cdp(session, [{method, params} | rest]) do
    CDPClient.cdp_cast(session, method, params)
    pipeline_cdp(session, rest)
  end

  # rawKeyDown + keyUp commands for a non-text key (Tab, Enter, etc.).
  defp key_event_pair(code, key_val) do
    [
      {"Input.dispatchKeyEvent",
       %{
         type: "rawKeyDown",
         key: key_val,
         code: code,
         windowsVirtualKeyCode: key_code(code)
       }},
      {"Input.dispatchKeyEvent",
       %{
         type: "keyUp",
         key: key_val,
         code: code,
         windowsVirtualKeyCode: key_code(code)
       }}
    ]
  end

  defp key_mapping(:enter), do: {"Enter", "Enter"}
  defp key_mapping(:tab), do: {"Tab", "Tab"}
  defp key_mapping(:escape), do: {"Escape", "Escape"}
  defp key_mapping(:backspace), do: {"Backspace", "Backspace"}
  defp key_mapping(:delete), do: {"Delete", "Delete"}
  defp key_mapping(:arrow_up), do: {"ArrowUp", "ArrowUp"}
  defp key_mapping(:arrow_down), do: {"ArrowDown", "ArrowDown"}
  defp key_mapping(:arrow_left), do: {"ArrowLeft", "ArrowLeft"}
  defp key_mapping(:arrow_right), do: {"ArrowRight", "ArrowRight"}
  defp key_mapping(:home), do: {"Home", "Home"}
  defp key_mapping(:end_key), do: {"End", "End"}
  defp key_mapping(:space), do: {"Space", " "}
  defp key_mapping(other), do: {to_string(other), to_string(other)}

  defp key_code("Enter"), do: 13
  defp key_code("Tab"), do: 9
  defp key_code("Escape"), do: 27
  defp key_code("Backspace"), do: 8
  defp key_code("Delete"), do: 46
  defp key_code("ArrowUp"), do: 38
  defp key_code("ArrowDown"), do: 40
  defp key_code("ArrowLeft"), do: 37
  defp key_code("ArrowRight"), do: 39
  defp key_code("Space"), do: 32
  defp key_code(_), do: 0
end
