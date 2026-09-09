defmodule SurfBoard.DSL do
  @moduledoc """
  Sets up the SurfBoard DSL in a module.

  All functions in `SurfBoard.Browser` are now accessible without a module name
  and `SurfBoard.Browser`, `SurfBoard.Element` and `SurfBoard.Query` are all aliased.

  ## Example

  ```elixir
  defmodule MyPage do
    use SurfBoard.DSL

    @name_field Query.text_field("Name")
    @email_field Query.text_field("email")
    @save_button Query.button("Save")

    def register(session) do
      session
      |> visit("/registration.html")
      |> fill_in(@name_field, with: "Chris")
      |> fill_in(@email_field, with: "c@keathly.io")
      |> click(@save_button)
    end
  end
  ```
  """

  defmacro __using__([]) do
    quote do
      alias SurfBoard.Browser
      alias SurfBoard.Element
      alias SurfBoard.Query

      # Kernel.tap/2 was introduced in 1.12 and conflicts with Browser.tap/2
      import Kernel, except: [tap: 2]
      import SurfBoard.Browser
    end
  end
end
