defmodule SurfBoard.KeyCodes do
  @moduledoc """
  The canonical key-name vocabulary accepted by `SurfBoard.Browser.send_keys/2`
  (and `SurfBoard.Element.send_keys/2`), on every driver:

  - :null
  - :cancel
  - :help
  - :backspace
  - :tab
  - :clear
  - :return
  - :enter
  - :shift
  - :control
  - :alt
  - :pause
  - :escape
  - :space
  - :pageup
  - :pagedown
  - :end
  - :home
  - :left_arrow
  - :up_arrow
  - :right_arrow
  - :down_arrow
  - :insert
  - :delete
  - :semicolon
  - :equals
  - :num0
  - :num1
  - :num2
  - :num3
  - :num4
  - :num5
  - :num6
  - :num7
  - :num8
  - :num9
  - :multiply
  - :add
  - :separator
  - :subtract
  - :decimal
  - :divide
  - :command

  A driver-neutral reference only — the actual per-key wire encoding
  lives in `Clients.CDP.SendKeysSession.key_mapping/1` (DOM `key`/`code`
  + legacy `windowsVirtualKeyCode`, for `Input.dispatchKeyEvent`) and
  `Clients.BiDi.Commands.key_code/1` (WebDriver `\\uE0XX` Unicode PUA
  codepoints, for `input.performActions`) — this module has no
  functions of its own.
  """
end
