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
          {code, key_val, vk} = key_mapping(key)
          key_event_pair(code, key_val, vk)

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

  # A key whose `key` value is a single printable character (Space,
  # Semicolon, a numpad digit, ...) needs `text` on the keyDown event
  # too — CDP only actually inserts a character when `text` is
  # present; `key`/`code`/`windowsVirtualKeyCode` alone just fire the
  # DOM event without typing anything. Matches Puppeteer's
  # CdpKeyboard.down/up: `type: "keyDown"` + `text` for printable keys,
  # `type: "rawKeyDown"` + no `text` for non-printable ones (Tab,
  # Enter, arrows, ...), both followed by a plain `keyUp`.
  defp key_event_pair(code, key_val, vk) when byte_size(key_val) == 1 do
    [
      {"Input.dispatchKeyEvent",
       %{
         type: "keyDown",
         key: key_val,
         code: code,
         windowsVirtualKeyCode: vk,
         text: key_val
       }},
      {"Input.dispatchKeyEvent",
       %{
         type: "keyUp",
         key: key_val,
         code: code,
         windowsVirtualKeyCode: vk
       }}
    ]
  end

  defp key_event_pair(code, key_val, vk) do
    [
      {"Input.dispatchKeyEvent",
       %{
         type: "rawKeyDown",
         key: key_val,
         code: code,
         windowsVirtualKeyCode: vk
       }},
      {"Input.dispatchKeyEvent",
       %{
         type: "keyUp",
         key: key_val,
         code: code,
         windowsVirtualKeyCode: vk
       }}
    ]
  end

  # Canonical WebDriver key vocabulary (matches SurfBoard.KeyCodes and
  # Clients.BiDi.Commands's key_code/1) mapped to CDP's DOM `code` +
  # `key` values and legacy `windowsVirtualKeyCode`. Every atom here is
  # accepted by both CDP and BiDi send_keys — see SurfBoard.KeyCodes
  # for the full canonical list. Keyed off the atom (not the derived
  # `code` string) since two different keys can share one `code`
  # (`:clear` and `:num5` both physically sit on Numpad5, but need
  # different VK codes).
  defp key_mapping(:cancel), do: {"Abort", "Cancel", 3}
  defp key_mapping(:help), do: {"Help", "Help", 47}
  defp key_mapping(:backspace), do: {"Backspace", "Backspace", 8}
  defp key_mapping(:tab), do: {"Tab", "Tab", 9}
  defp key_mapping(:clear), do: {"Numpad5", "Clear", 12}
  defp key_mapping(:return), do: {"Enter", "Enter", 13}
  defp key_mapping(:enter), do: {"Enter", "Enter", 13}
  defp key_mapping(:shift), do: {"ShiftLeft", "Shift", 16}
  defp key_mapping(:control), do: {"ControlLeft", "Control", 17}
  defp key_mapping(:alt), do: {"AltLeft", "Alt", 18}
  defp key_mapping(:pause), do: {"Pause", "Pause", 19}
  defp key_mapping(:escape), do: {"Escape", "Escape", 27}
  defp key_mapping(:space), do: {"Space", " ", 32}
  defp key_mapping(:pageup), do: {"PageUp", "PageUp", 33}
  defp key_mapping(:pagedown), do: {"PageDown", "PageDown", 34}
  defp key_mapping(:end), do: {"End", "End", 35}
  defp key_mapping(:home), do: {"Home", "Home", 36}
  defp key_mapping(:left_arrow), do: {"ArrowLeft", "ArrowLeft", 37}
  defp key_mapping(:up_arrow), do: {"ArrowUp", "ArrowUp", 38}
  defp key_mapping(:right_arrow), do: {"ArrowRight", "ArrowRight", 39}
  defp key_mapping(:down_arrow), do: {"ArrowDown", "ArrowDown", 40}
  defp key_mapping(:insert), do: {"Insert", "Insert", 45}
  defp key_mapping(:delete), do: {"Delete", "Delete", 46}
  defp key_mapping(:semicolon), do: {"Semicolon", ";", 186}
  defp key_mapping(:equals), do: {"Equal", "=", 187}
  defp key_mapping(:num0), do: {"Numpad0", "0", 96}
  defp key_mapping(:num1), do: {"Numpad1", "1", 97}
  defp key_mapping(:num2), do: {"Numpad2", "2", 98}
  defp key_mapping(:num3), do: {"Numpad3", "3", 99}
  defp key_mapping(:num4), do: {"Numpad4", "4", 100}
  defp key_mapping(:num5), do: {"Numpad5", "5", 101}
  defp key_mapping(:num6), do: {"Numpad6", "6", 102}
  defp key_mapping(:num7), do: {"Numpad7", "7", 103}
  defp key_mapping(:num8), do: {"Numpad8", "8", 104}
  defp key_mapping(:num9), do: {"Numpad9", "9", 105}
  defp key_mapping(:multiply), do: {"NumpadMultiply", "*", 106}
  defp key_mapping(:add), do: {"NumpadAdd", "+", 107}
  defp key_mapping(:separator), do: {"NumpadComma", ",", 108}
  defp key_mapping(:subtract), do: {"NumpadSubtract", "-", 109}
  defp key_mapping(:decimal), do: {"NumpadDecimal", ".", 110}
  defp key_mapping(:divide), do: {"NumpadDivide", "/", 111}
  defp key_mapping(:command), do: {"MetaLeft", "Meta", 91}
  # Legacy CDP-only aliases predating the vocabulary above — kept so
  # existing callers using these names don't break.
  defp key_mapping(:arrow_up), do: key_mapping(:up_arrow)
  defp key_mapping(:arrow_down), do: key_mapping(:down_arrow)
  defp key_mapping(:arrow_left), do: key_mapping(:left_arrow)
  defp key_mapping(:arrow_right), do: key_mapping(:right_arrow)
  defp key_mapping(:end_key), do: key_mapping(:end)
  defp key_mapping(other), do: {to_string(other), to_string(other), 0}
end
