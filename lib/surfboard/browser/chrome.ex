defmodule Surfboard.Browser.Chrome do
  @moduledoc false

  # One of the dimension modules on a driver Spec (`spec.browser`) —
  # currently just a marker distinguishing "this session drives real
  # Chrome/Chromium" from Lightpanda for anything that needs to branch
  # on vendor rather than protocol (CDP vs BiDi) later.
end
