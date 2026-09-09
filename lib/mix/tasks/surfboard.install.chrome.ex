defmodule Mix.Tasks.Surfboard.Install.Chrome do
  @moduledoc """
  Installs Chrome for Testing and the chromium-bidi server's Node deps
  into `.browsers/`, recording the binary path in `.browsers/PATHS`.

  Leaves any existing `LIGHTPANDA=` entry in PATHS untouched.

  ## Usage

      mix surfboard.install.chrome              # latest stable
      mix surfboard.install.chrome 147.0.7727   # specific version

  ## Requirements

  Requires `npx` and `npm` (Node.js).
  """
  use Mix.Task

  @shortdoc "Install Chrome for Testing + chromium-bidi Node deps"

  @impl true
  def run(args) do
    version = List.first(args) || "stable"
    Surfboard.Installer.install_chrome(version)
  end
end
