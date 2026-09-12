defmodule SurfBoard.Browser do
  @moduledoc """
  The Browser module is the entrypoint for interacting with a real browser.

  By default, action only work with elements that are visible to a real user.

  ## Actions

  Actions are used to interact with form elements. All actions work with the
  query interface:

  ```html
  <label for="first_name">
    First Name
  </label>
  <input id="user_first_name" type="text" name="first_name">
  ```

  ```
  fill_in(page, Query.text_field("First Name"), with: "Grace")
  fill_in(page, Query.text_field("first_name"), with: "Grace")
  fill_in(page, Query.text_field("user_first_name"), with: "Grace")
  ```

  These queries work with any of the available actions.

  ```
  fill_in(page, Query.text_field("First Name"), with: "Chris")
  clear(page, Query.text_field("user_email"))
  click(page, Query.radio_button("Radio Button 1"))
  click(page, Query.checkbox("Checkbox"))
  click(page, Query.checkbox("Checkbox"))
  click(page, Query.option("Option 1"))
  click(page, Query.button("Some Button"))
  attach_file(page, Query.file_field("Avatar"), path: "test/fixtures/avatar.jpg")
  ```

  Actions return their parent element so that they can be chained together:

  ```
  page
  |> find(Query.css(".signup-form"), fn(form) ->
    form
    |> fill_in(Query.text_field("Name"), with: "Grace Hopper")
    |> fill_in(Query.text_field("Email"), with: "grace@hopper.com")
    |> click(Query.button("Submit"))
  end)
  ```

  ## Scoping

  Finders provide scoping like so:

  ```
  session
  |> visit("/page.html")
  |> find(Query.css(".users"))
  |> find(Query.css(".user", count: 3))
  |> List.first
  |> find(Query.css(".user-name"))
  ```

  If a callback is passed to find then the scoping will only apply to the callback
  and the parent will be passed to the next action in the chain:

  ```
  page
  |> find(Query.css(".todo-form"), fn(form) ->
    form
    |> fill_in(Query.text_field("What needs doing?"), with: "Write SurfBoard Documentation")
    |> click(Query.button("Save"))
  end)
  |> find(Query.css(".success-notification"), fn(notification) ->
    assert notification
    |> has_text?("Todo created successfully!")
  end)
  ```

  This allows you to create a test that is logically grouped together in a single pipeline.
  It also means that its easy to create re-usable helper functions without having to worry about
  chaining. You could re-write the above example like this:

  ```
  def create_todo(page, todo) do
    find(Query.css(".todo-form"), & fill_in_and_save_todo(&1, todo))
  end

  def fill_in_and_save_todo(form, todo) do
    form
    |> fill_in(Query.text_field("What needs doing?"), with: todo)
    |> click(Query.button("Save"))
  end

  def todo_was_created?(page) do
    find Query.css(page, ".success-notification"), fn(notification) ->
      assert notification
      |> has_text?("Todo created successfully!")
    end
  end

  assert page
  |> create_todo("Write SurfBoard Documentation")
  |> todo_was_created?
  ```
  """

  alias SurfBoard.Browser.Cookies
  alias SurfBoard.Browser.Dialogs
  alias SurfBoard.Browser.Form
  alias SurfBoard.Browser.Internal
  alias SurfBoard.Browser.LiveViewPatch
  alias SurfBoard.Browser.Mouse
  alias SurfBoard.Browser.Navigation
  alias SurfBoard.Browser.Query, as: BrowserQuery
  alias SurfBoard.Browser.Screenshot
  alias SurfBoard.Browser.Windows
  alias SurfBoard.Element
  alias SurfBoard.Query
  alias SurfBoard.Session

  @type t :: any()

  @typep session :: Session.t()
  @typep element :: Element.t()
  @opaque queryable ::
            Query.t()
            | Element.t()

  @type parent ::
          element
          | session
  @type opts :: Query.opts()

  @doc """
  Attempts to synchronize with the browser. This is most often used to
  execute queries repeatedly until it either exceeds the time limit or
  returns a success.

  ## Note

  It is possible that this function never halts. Whenever we experience a stale
  reference error we retry the query without checking to see if we've run over
  our time. In practice we should eventually be able to query the DOM in a stable
  state. However, if this error does continue to occur it will cause surf_board to
  loop forever (or until the test is killed by exunit).
  """
  @type sync_result :: {:ok, any()} | {:error, any()}
  @spec retry((-> sync_result), non_neg_integer()) :: sync_result()
  def retry(f, start_time \\ Internal.current_time()), do: Internal.retry(f, start_time)

  @doc """
  Fills in an element identified by `query` with `value`.

  All inputs previously present in the input field will be overridden.

  ### Examples

      page
      |> fill_in(Query.text_field("name"), with: "Chris")
      |> fill_in(Query.css("#password_field"), with: "secret42")

  ### Note

  Currently, Chrome only supports [BMP Unicode](http://www.unicode.org/roadmaps/bmp/) characters via the WebDriver `send_keys` action. Emojis are [SMP](https://www.unicode.org/roadmaps/smp/) characters and will be ignored.

  Using JavaScript is a known workaround for filling in fields with Emojis and other non-BMP characters.
  """
  @spec fill_in(parent, Query.t(), with: String.t()) :: parent
  @spec fill_in(parent, Query.t(), [{:with, String.t()} | {:await, atom}]) :: parent
  def fill_in(parent, query, opts) when is_list(opts), do: Form.fill_in(parent, query, opts)

  @spec clear(parent, Query.t()) :: parent
  @spec clear(parent, Query.t(), keyword) :: parent
  def clear(parent, query), do: Form.clear(parent, query)
  def clear(parent, query, opts) when is_list(opts), do: Form.clear(parent, query, opts)

  @doc """
  Attaches a file to a file input. Input elements are looked up by id, label text,
  or name.
  """
  @spec attach_file(parent, Query.t(), path: String.t()) :: parent
  def attach_file(parent, query, path: path), do: Form.attach_file(parent, query, path: path)

  @doc """
  Takes a screenshot of the current window.
  Screenshots are saved to a "screenshots" directory in the same directory the
  tests are run in.

  Pass `[{:name, "some_name"}]` to specify the file name. Defaults to a timestamp.
  Pass `[{:log, true}]` to log the location of the screenshot to stdout. Defaults to false.
  """
  @type take_screenshot_opt :: {:name, String.t()} | {:log, boolean}
  @spec take_screenshot(parent, [take_screenshot_opt]) :: parent
  def take_screenshot(screenshotable, opts \\ []),
    do: Screenshot.take_screenshot(screenshotable, opts)

  @doc """
  Grants media permissions (`:camera`, `:microphone`) for `session`, so a
  page's `getUserMedia`/`getDisplayMedia` calls succeed without a real
  permission prompt — useful for driving a headless session into a
  WebRTC call. Applies to every origin in the session's browser context.

  Pair with launching Chrome with a fake camera/mic
  (`--use-fake-device-for-media-stream`) — this grants the permission;
  the launch flags give `getUserMedia` an actual device to open. See the
  [Recording guide](recording.html) for a Chrome image built for this.

  CDP-only (`driver: :chrome_cdp`); other spec modules raise
  `SurfBoard.DriverError`.

  ```elixir
  :ok = SurfBoard.Browser.grant_permissions(session, [:camera, :microphone])
  ```
  """
  @spec grant_permissions(session, [:camera | :microphone]) :: :ok | {:error, term}
  def grant_permissions(%Session{} = session, permissions) when is_list(permissions),
    do: Form.grant_permissions(session, permissions)

  @doc """
  Gets the window handle of the current window.

  The window is either an instance of a browser tab or another operating system window.
  Getting the current window handle makes it easy to return to the window in case you
  need to switch between them.

  ## Usage

  ```elixir
  feature "can open a new tab and switch back to the original tab", %{session: session} do
    handle =
      session
      |> visit("/home")
      |> window_handle()

    path =
      session
      # click a link that takes you to a new tab
      |> click(Query.link("External Page"))
      |> focus_window(handle)
      |> current_path()

    assert "/home" == path
  end
  ```
  """
  @spec window_handle(session :: Session.t()) :: String.t()
  def window_handle(%Session{} = session), do: Windows.window_handle(session)

  @doc """
  Gets the window handles of all available windows.

  The window is either an instance of a browser tab or another operating system window.

  ## Usage

  ```elixir
  feature "can open new tabs for external links", %{session: session} do
    handles =
      session
      |> visit("/home")
      |> click(Query.link("External Page"))
      |> click(Query.link("Another External Page"))
      |> window_handles()

    assert 3 == length(path)
  end
  ```
  """
  @spec window_handles(session :: Session.t()) :: [String.t()]
  def window_handles(%Session{} = session), do: Windows.window_handles(session)

  @doc """
  Focuses the window identified by the given handle.

  The window is either an instance of a browser tab or another operating system window.

  ## Usage

  ```elixir
  feature "can switch between different tabs", %{session: session} do
    handle =
      session
      |> visit("/home")
      |> window_handle()

    path =
      session
      # click a link that takes you to a new tab
      |> click(Query.link("External Page"))
      |> focus_window(handle)
      |> current_path()

    assert "/home" == path
  end
  ```
  """
  @spec focus_window(session :: Session.t(), window_handle :: String.t()) :: parent
  def focus_window(%Session{} = session, window_handle),
    do: Windows.focus_window(session, window_handle)

  @doc """
  Closes the current window.

  The window is either an instance of a browser tab or another operating system window.

  ## Usage

  ```elixir
  feature "closing a window focuses the previously focused window", %{session: session} do
    original_handle =
      session
      |> visit("/home")
      |> window_handle()

    new_handle =
      session
      # click a link that takes you to a new tab
      |> click(Query.link("External Page"))
      |> close_window()
      |> window_handle()

    assert original_handle == new_handle
  end
  ```
  """
  @spec close_window(session :: Session.t()) :: Session.t()
  def close_window(%Session{} = session), do: Windows.close_window(session)

  @doc """
  Gets the size of the current window.

  The window is either an instance of a browser tab or another operating system window.

  This is useful for debugging responsive designs where the layout changes as the window size changes. The default window size is 1280x800.

  ## Usage

  ```elixir
  feature "gets the size of the current window", %{session: session} do
    %{"width" => width, "height" => height} =
      session
      |> visit("/home")
      |> window_size()

    assert width == 1280
    assert height == 800
  end
  ```
  """
  @spec window_size(session :: Session.t()) :: %{
          String.t() => pos_integer,
          String.t() => pos_integer
        }
  def window_size(%Session{} = session), do: Windows.window_size(session)

  @doc """
  Sets the size of the current window.

  The window is either an instance of a browser tab or another operating system window.

  ## Usage

  ```elixir
  feature "sets the size of the window to mobile dimensions", %{session: session} do
    %{"width" => width, "height" => height} =
      session
      |> visit("/home")
      |> resize_window(375, 667)
      |> window_size()

    assert width == 375
    assert height == 667
  end
  ```
  """
  @spec resize_window(session :: Session.t(), width :: pos_integer(), height :: pos_integer()) ::
          Session.t()
  def resize_window(%Session{} = session, width, height),
    do: Windows.resize_window(session, width, height)

  @doc """
  Maximizes the current window.

  The window is either an instance of a browser tab or another operating system window.

  For most browsers, this requires a graphical window manager to be running.

  ## Usage

  ```elixir
  feature "maximizes the window to the full size of the display", %{session: session} do
    %{"width" => width, "height" => height} =
      session
      |> visit("/home")
      |> maximize_window()
      |> window_size()

    assert width == 1920
    assert height == 1080
  end
  ```
  """
  @spec maximize_window(session :: Session.t()) :: Session.t()
  def maximize_window(%Session{} = session), do: Windows.maximize_window(session)

  @doc """
  Gets the position of the current window.

  The window is either an instance of a browser tab or another operating system window.

  ## Usage

  ```elixir
  feature "gets the current display position of the window", %{session: session} do
    %{"x" => x, "y" => y} =
      session
      |> visit("/home")
      |> window_position()

    assert x == 200
    assert y == 200
  end
  ```
  """
  @spec window_position(session :: Session.t()) :: %{
          String.t() => pos_integer,
          String.t() => pos_integer
        }
  def window_position(%Session{} = session), do: Windows.window_position(session)

  @doc """
  Sets the position of the current window.

  The window is either an instance of a browser tab or another operating system window.

  ## Usage

  ```elixir
  feature "gets the current display position of the window", %{session: session} do
    %{"x" => x, "y" => y} =
      session
      |> visit("/home")
      |> move_window(500, 500)
      |> window_position()

    assert x == 500
    assert y == 500
  end
  ```
  """
  @spec move_window(session :: Session.t(), x :: pos_integer(), y :: pos_integer()) :: Session.t()
  def move_window(%Session{} = session, x, y), do: Windows.move_window(session, x, y)

  @doc """
  Changes the driver focus to the frame found by query.
  """
  @spec focus_frame(parent, Query.t()) :: parent
  def focus_frame(%Session{} = session, %Query{} = query), do: Windows.focus_frame(session, query)

  @doc """
  Changes the driver focus to the parent frame.
  """
  @spec focus_parent_frame(parent) :: parent
  def focus_parent_frame(%Session{} = session), do: Windows.focus_parent_frame(session)

  @doc """
  Changes the driver focus to the default (top level) frame.
  """
  @spec focus_default_frame(parent) :: parent
  def focus_default_frame(%Session{} = session), do: Windows.focus_default_frame(session)

  @doc """
  Gets the current url of the session
  """
  @spec current_url(parent) :: String.t()
  def current_url(%Session{} = session), do: Navigation.current_url(session)

  @doc """
  Gets the current path of the session
  """
  @spec current_path(parent) :: String.t()
  def current_path(%Session{} = session), do: Navigation.current_path(session)

  @doc """
  Gets the title for the current page
  """
  @spec page_title(parent) :: String.t()
  def page_title(%Session{} = session), do: Navigation.page_title(session)

  @doc """
  Executes JavaScript synchronously, taking as arguments the script to execute,
  an optional list of arguments available in the script via `arguments`, and an
  optional callback function with the result of script execution as a parameter.
  """
  @spec execute_script(parent, String.t()) :: parent
  @spec execute_script(parent, String.t(), list) :: parent
  @spec execute_script(parent, String.t(), (binary() -> any())) :: parent
  @spec execute_script(parent, String.t(), list, (binary() -> any())) :: parent
  def execute_script(session, script),
    do: SurfBoard.Browser.Script.execute_script(session, script)

  def execute_script(session, script, arguments_or_callback),
    do: SurfBoard.Browser.Script.execute_script(session, script, arguments_or_callback)

  def execute_script(session, script, arguments, callback),
    do: SurfBoard.Browser.Script.execute_script(session, script, arguments, callback)

  @doc """
  Executes asynchronous JavaScript, taking as arguments the script to execute,
  an optional list of arguments available in the script via `arguments`, and an
  optional callback function with the result of script execution as a parameter.
  """
  @spec execute_script_async(parent, String.t()) :: parent
  @spec execute_script_async(parent, String.t(), list) :: parent
  @spec execute_script_async(parent, String.t(), (binary() -> any())) :: parent
  @spec execute_script_async(parent, String.t(), list, (binary() -> any())) :: parent
  def execute_script_async(session, script),
    do: SurfBoard.Browser.Script.execute_script_async(session, script)

  def execute_script_async(session, script, arguments_or_callback),
    do: SurfBoard.Browser.Script.execute_script_async(session, script, arguments_or_callback)

  def execute_script_async(session, script, arguments, callback),
    do: SurfBoard.Browser.Script.execute_script_async(session, script, arguments, callback)

  @doc """
  Sends a list of key strokes to active element. If strings are included
  then they are sent as individual keys. Special keys should be provided as a
  list of atoms, which are automatically converted into the corresponding key
  codes.

  For a list of available key codes see `SurfBoard.KeyCodes`.

  ## Example

      iex> SurfBoard.Browser.send_keys(session, ["Example Text", :enter])
      iex> SurfBoard.Browser.send_keys(session, [:enter])
      iex> SurfBoard.Browser.send_keys(session, [:shift, :enter])

  ### Note

  Currently, Chrome only supports [BMP Unicode](http://www.unicode.org/roadmaps/bmp/) characters via the WebDriver `send_keys` action. Emojis are [SMP](https://www.unicode.org/roadmaps/smp/) characters and will be ignored.

  Using JavaScript is a known workaround for filling in fields with Emojis and other non-BMP characters.
  """
  @spec send_keys(parent, Query.t(), Element.keys_to_send()) :: parent
  @spec send_keys(parent, Element.keys_to_send()) :: parent
  def send_keys(parent, query, list), do: Form.send_keys(parent, query, list)
  def send_keys(parent, keys), do: Form.send_keys(parent, keys)

  @doc """
  Retrieves the source of the current page.
  """
  @spec page_source(parent) :: String.t()
  def page_source(%Session{} = session), do: Navigation.page_source(session)

  @doc """
  The HTTP status code of the most recently visited page.

  Supported on every driver (Chrome CDP, Chrome BiDi, Lightpanda).
  Returns `nil` before anything has been visited.

  Note `visit/2` does not raise on an error status: a 404 or 500 loads
  like any other page, so check this when the status matters.

      visit(session, "https://example.com/missing")
      status(session)
      #=> 404

  """
  @spec status(session) :: non_neg_integer() | nil
  def status(%Session{} = session), do: Navigation.status(session)

  @doc """
  Response headers of the most recently visited page, as a map with
  lowercase string keys. Returns `nil` when unavailable (see `status/1`).

      visit(session, "https://example.com")
      response_headers(session)["content-type"]
      #=> "text/html; charset=UTF-8"

  """
  @spec response_headers(session) :: %{String.t() => String.t()} | nil
  def response_headers(%Session{} = session), do: Navigation.response_headers(session)

  @doc """
  Sets the value of an element. The allowed type for the value depends on the
  type of the element. The value may be:
  * a string of characters for a text element
  * :selected for a radio button, checkbox or select list option
  * :unselected for a checkbox
  """
  @spec set_value(parent, Query.t(), Element.value()) :: parent
  def set_value(parent, query, value), do: Form.set_value(parent, query, value)

  @doc """
  Clicks the mouse on the element returned by the query or at the
  current mouse cursor position.

  ## Options

  * `:await` — controls the LiveView patch-await behaviour for clicks
    on phx-bound elements.

    * `:auto` (default) — wait for the resulting patch / page-ready
      signal before returning. This is what you want for ordinary
      tests.
    * `:defer` — fire the click, stash a pre-click `pageId`, and
      return immediately. Pair with `SurfBoard.LiveView.await_patch/2`
      to consume the deferred wait. Use this when you need to assert
      on the optimistic-UI DOM between the click and the server reply.
      Outside a `SurfBoard.LiveView.with_latency/3` block, the optimistic
      window is usually too short to observe reliably.

  Non-LiveView clicks ignore `:await` — there's nothing to wait for.
  """
  @spec click(parent, :left | :middle | :right) :: parent
  @spec click(parent, Query.t()) :: parent
  @spec click(parent, Query.t(), keyword) :: parent
  def click(parent, button_or_query), do: Mouse.click(parent, button_or_query)
  def click(parent, query, opts) when is_list(opts), do: Mouse.click(parent, query, opts)

  @doc """
  Double-clicks left mouse button at the current mouse coordinates.
  """
  @spec double_click(parent) :: parent
  def double_click(parent), do: Mouse.double_click(parent)

  @doc """
   Clicks and holds the given mouse button at the current mouse coordinates.
  """
  @spec button_down(parent, atom) :: parent
  def button_down(parent, button \\ :left), do: Mouse.button_down(parent, button)

  @doc """
   Releases given previously held mouse button.
  """
  @spec button_up(parent, atom) :: parent
  def button_up(parent, button \\ :left), do: Mouse.button_up(parent, button)

  @doc """
  Hovers over an element.
  """
  @spec hover(parent, Query.t()) :: parent
  def hover(parent, query), do: Mouse.hover(parent, query)

  @doc """
  Moves mouse by an offset relative to current cursor position.
  """
  @spec move_mouse_by(parent, integer, integer) :: parent
  def move_mouse_by(parent, x_offset, y_offset),
    do: Mouse.move_mouse_by(parent, x_offset, y_offset)

  @doc """
  Touches the screen at the given position.
  """
  @spec touch_down(parent, integer, integer) :: session
  def touch_down(parent, x, y) when is_integer(x) and is_integer(y),
    do: Mouse.touch_down(parent, x, y)

  @doc """
  Touches and holds the element on its top-left corner plus an optional offset.
  """
  @spec touch_down(parent, Query.t(), integer, integer) :: session
  def touch_down(parent, query, x_offset \\ 0, y_offset \\ 0),
    do: Mouse.touch_down(parent, query, x_offset, y_offset)

  @doc """
  Stops touching the screen.
  """
  @spec touch_up(parent) :: parent
  def touch_up(parent), do: Mouse.touch_up(parent)

  @doc """
  Taps the element.
  """
  @spec tap(parent, Query.t()) :: session
  def tap(parent, query), do: Mouse.tap(parent, query)

  @doc """
  Moves the touch pointer (finger, stylus etc.) on the screen to the point determined by the given coordinates.
  """
  @spec touch_move(parent, non_neg_integer, non_neg_integer) :: parent
  def touch_move(parent, x, y), do: Mouse.touch_move(parent, x, y)

  @doc """
  Scroll on the screen from the given element by the given offset using touch events.
  """
  @spec touch_scroll(parent, Query.t(), integer, integer) :: parent
  def touch_scroll(parent, query, x, y), do: Mouse.touch_scroll(parent, query, x, y)

  @doc """
  Gets the Element's text value.

  If the element is not visible, the return value will be `""`.
  """
  @spec text(parent) :: String.t()
  @spec text(parent, Query.t()) :: String.t()
  def text(parent), do: BrowserQuery.text(parent)
  def text(parent, query), do: BrowserQuery.text(parent, query)

  @doc """
  Gets the value of the elements attribute.
  """
  @spec attr(parent, Query.t(), String.t()) :: String.t() | nil
  def attr(parent, query, name), do: BrowserQuery.attr(parent, query, name)

  @doc """
  Checks if the element has been selected. Alias for checked?(element)
  """
  @spec selected?(parent, Query.t()) :: boolean()
  def selected?(parent, query), do: BrowserQuery.selected?(parent, query)

  @doc """
  Checks if the element is visible on the page
  """
  @spec visible?(parent, Query.t()) :: boolean()
  def visible?(parent, query), do: BrowserQuery.visible?(parent, query)

  @doc """
  Finds and returns one or more DOM element(s) on the page based on the given query.

  The query is scoped by the first argument, which is either the `%Session{}` or an
  `%Element{}`.

  ## Example

  ```elixir
  session
  |> find(Query.css("#login-button"))
  |> Element.text()
  #=> "Login"

  buttons =
    session
    |> find(Query.css(".login-button", count: 2, text: "Login"))
  ```

  ## Notes

  - Blocks until it finds the element(s) or the max time is reached.
  - By default only 1 element is expected to match the query. If more elements are present then a count can be
    specified. Use `count: :any` to allow any number of elements to be present.
  - By default only elements that would be visible to a real user on the page are returned.
  """
  @spec find(parent, Query.t()) :: Element.t() | [Element.t()]
  def find(parent, %Query{} = query), do: BrowserQuery.find(parent, query)

  @doc """
  Same as `find/2`, but takes a callback to enact side effects on the found element(s).

  ## Example

  ```elixir
  session
  |> find(Query.css("#login-button"), fn button ->
    Element.text(button) == "Login"
  end)

  session
  |> find(Query.css(".login-button", count: 2, text: "Login"), fn buttons ->
    assert 2 == length(buttons)
  end)

  ```

  ## Notes

  - Returns the first argument to make the function pipe-able.
  """
  @spec find(parent, Query.t(), (Element.t() -> any())) :: parent
  def find(parent, %Query{} = query, callback) when is_function(callback),
    do: BrowserQuery.find(parent, query, callback)

  @doc """
  Finds all of the DOM elements that match the CSS selector. If no elements are
  found then an empty list is immediately returned. This is equivalent to calling
  `find(session, css("element", count: nil, minimum: 0))`.
  """
  @spec all(parent, Query.t()) :: [Element.t()]
  def all(parent, %Query{} = query), do: BrowserQuery.all(parent, query)

  @doc """
  Validates that the query returns a result. This can be used to define other
  types of matchers.
  """
  @spec has?(parent, Query.t()) :: boolean()
  def has?(parent, query), do: BrowserQuery.has?(parent, query)

  @doc """
  Matches the Element's value with the provided value.
  """
  @spec has_value?(parent, Query.t(), any()) :: boolean()
  @spec has_value?(Element.t(), any()) :: boolean()
  def has_value?(parent, query, value), do: BrowserQuery.has_value?(parent, query, value)
  def has_value?(%Element{} = element, value), do: BrowserQuery.has_value?(element, value)

  @doc """
  Matches the parent's content with the provided text.

  Returns a boolean that indicates if the text was found.

  ## Examples

  ```
  session
  |> visit("/")
  |> has_text?("Login")
  ```

  Example providing query:

  ```
  session
  |> visit("/")
  |> has_text?(Query.css(".login-button"), "Login")
  ```
  """
  @spec has_text?(parent, String.t()) :: boolean()
  @spec has_text?(parent, Query.t(), String.t()) :: boolean()
  def has_text?(parent, query, text), do: BrowserQuery.has_text?(parent, query, text)

  def has_text?(%Session{} = session, text) when is_binary(text),
    do: BrowserQuery.has_text?(session, text)

  def has_text?(%Element{} = element, text) when is_binary(text),
    do: BrowserQuery.has_text?(element, text)

  @doc """
  Searches for CSS on the page.
  """
  @spec has_css?(parent, Query.t(), String.t()) :: boolean()
  @spec has_css?(parent, String.t()) :: boolean()
  def has_css?(parent, query, css) when is_binary(css),
    do: BrowserQuery.has_css?(parent, query, css)

  def has_css?(parent, css) when is_binary(css), do: BrowserQuery.has_css?(parent, css)

  @doc """
  Searches for CSS that should not be on the page
  """
  @spec has_no_css?(parent, Query.t(), String.t()) :: boolean()
  @spec has_no_css?(parent, String.t()) :: boolean()
  def has_no_css?(parent, query, css) when is_binary(css),
    do: BrowserQuery.has_no_css?(parent, query, css)

  def has_no_css?(parent, css) when is_binary(css), do: BrowserQuery.has_no_css?(parent, css)

  @doc """
  Changes the current page to the provided route.
  Relative paths are appended to the provided base_url.
  Absolute paths do not use the base_url.

  Raises `SurfBoard.NavigationError` if the navigation itself fails (DNS
  failure, connection refused, TLS error). Without that the browser would
  stay on the previously loaded page while this returned normally, so every
  subsequent read would silently yield stale content from the prior page.

  An HTTP error status is *not* a navigation failure: a 404 or 500 loads
  successfully and raises nothing.
  """
  @spec visit(session, String.t()) :: session
  def visit(%Session{} = session, path), do: Navigation.visit(session, path)

  @doc false
  def cookies(%Session{} = session), do: Cookies.cookies(session)

  @doc false
  def set_cookie(%Session{} = session, key, value, attributes \\ []),
    do: Cookies.set_cookie(session, key, value, attributes)

  @doc """
  Accepts one alert dialog, which must be triggered within the specified `fun`.
  Returns the message that was presented to the user. For example:

  ```
  message = accept_alert session, fn(s) ->
    click(s, Query.link("Trigger alert"))
  end
  ```
  """
  def accept_alert(%Session{} = session, fun), do: Dialogs.accept_alert(session, fun)

  @doc """
  Accepts one confirmation dialog, which must be triggered within the specified
  `fun`. Returns the message that was presented to the user. For example:

  ```
  message = accept_confirm session, fn(s) ->
    click(s, Query.link("Trigger confirm"))
  end
  ```
  """
  def accept_confirm(%Session{} = session, fun), do: Dialogs.accept_confirm(session, fun)

  @doc """
  Dismisses one confirmation dialog, which must be triggered within the
  specified `fun`. Returns the message that was presented to the user. For
  example:

  ```
  message = dismiss_confirm session, fn(s) ->
    click(s, Query.link("Trigger confirm"))
  end
  ```
  """
  def dismiss_confirm(%Session{} = session, fun), do: Dialogs.dismiss_confirm(session, fun)

  @doc """
  Accepts one prompt, which must be triggered within the specified `fun`. The
  `[with: value]` option allows to simulate user input for the prompt. If no
  value is provided, the default value that was passed to `window.prompt` will
  be used instead. Returns the message that was presented to the user. For
  example:

  ```
  message = accept_prompt session, fn(s) ->
    click(s, Query.link("Trigger prompt"))
  end
  ```

  Example providing user input:

  ```
  message = accept_prompt session, [with: "User input"], fn(s) ->
    click(s, Query.link("Trigger prompt"))
  end
  ```
  """
  def accept_prompt(%Session{} = session, fun), do: Dialogs.accept_prompt(session, fun)

  def accept_prompt(%Session{} = session, [with: input_value], fun) when is_binary(input_value),
    do: Dialogs.accept_prompt(session, [with: input_value], fun)

  @doc """
  Dismisses one prompt, which must be triggered within the specified `fun`.
  Returns the message that was presented to the user. For example:

  ```
  message = dismiss_prompt session, fn(s) ->
    click(s, Query.link("Trigger prompt"))
  end
  ```
  """
  def dismiss_prompt(%Session{} = session, fun), do: Dialogs.dismiss_prompt(session, fun)

  @doc false
  def execute_query(parent, query, opts \\ []),
    do: BrowserQuery.execute_query(parent, query, opts)

  @doc """
  Waits for the next LiveView DOM patch.

  A *patch* is LiveView applying a server-rendered diff to the DOM of the
  currently-mounted view (its client's `onPatchEnd`). That covers **any**
  server-driven re-render — an `assign` re-render from a `phx-*` handler,
  `handle_info` (e.g. a PubSub broadcast), `assign_async` results, or
  `push_patch` (same view, URL changes). It is **not** limited to
  `push_patch`, and does **not** include `push_navigate`/`redirect` (those
  mount a new view / load a new page — different waits handle them) or
  client-only `Phoenix.LiveView.JS` commands (no server diff).

  Resolves on the **next single** patch. For an interaction that produces
  several (e.g. `phx-change` per keystroke) or "is the page idle," use
  `settle/2` instead.

  Installed automatically via JavaScript — no `app.js` changes needed.

  `click/2` and `fill_in/3` call this automatically. Use `await_patch`
  explicitly for patches triggered by something other than a direct
  interaction (e.g. PubSub broadcast, timer).

  ## Options

  * `:timeout` — max wait in ms (default: 5_000)

  ## Examples

      # Wait for a PubSub-triggered update
      Phoenix.PubSub.broadcast(MyApp.PubSub, "updates", :refresh)
      session
      |> await_patch()
      |> has?(Query.css(".updated"))
  """
  @spec await_patch(session, keyword()) :: session
  def await_patch(%Session{} = session, opts \\ []), do: LiveViewPatch.await_patch(session, opts)
end
