defmodule Mix.Tasks.Surfboard.Minify do
  @moduledoc """
  Regenerates `priv/surfboard.min.js` from `priv/surfboard.js` using esbuild.

  Run after editing `priv/surfboard.js`. The minified file is committed
  to the repo so consumers don't need esbuild to compile surfboard.

      mix surfboard.minify
  """
  use Mix.Task

  @shortdoc "Regenerate priv/surfboard.min.js from priv/surfboard.js"

  @src "priv/surfboard.js"
  @dst "priv/surfboard.min.js"

  def run(_args) do
    unless File.exists?(@src) do
      Mix.raise("source file #{@src} not found")
    end

    unless System.find_executable("esbuild") do
      Mix.raise(
        "esbuild not found in PATH — install via `brew install esbuild` or your package manager"
      )
    end

    case System.cmd("esbuild", ["--minify", "--target=es2020", @src], stderr_to_stdout: true) do
      {output, 0} ->
        File.write!(@dst, output)
        before_size = File.stat!(@src).size
        after_size = File.stat!(@dst).size
        ratio = Float.round(after_size / before_size * 100, 1)

        Mix.shell().info(
          "#{@src}: #{before_size} bytes -> #{@dst}: #{after_size} bytes (#{ratio}%)"
        )

      {output, code} ->
        Mix.raise("esbuild failed (exit #{code}):\n#{output}")
    end
  end
end
