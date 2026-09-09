defmodule Surfboard.MixProject do
  use Mix.Project

  @source_url "https://github.com/u2i/surfboard"
  @version "0.1.0"
  @maintainers ["Tom Clarke"]

  def project do
    [
      app: :surfboard,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      package: package(),
      description:
        "Concurrent browser automation for Elixir — drive Chrome, Chromium, or Lightpanda " <>
          "via CDP/BiDi. Extracted from Wallabidi's driving layer.",
      deps: deps(),
      docs: docs(),
      dialyzer: dialyzer()
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {Surfboard, []}]
  end

  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.1"},
      {:mint, "~> 1.6"},
      {:mint_web_socket, "~> 1.0"},
      {:lazy_html, "~> 0.1"},
      {:lightpanda, "~> 0.3.6"},
      {:dialyxir, "~> 1.0", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.28", only: :dev}
    ]
  end

  defp package do
    [
      # Don't ship priv/bidi-server/node_modules — consumers run `npm install`
      # via `mix surfboard.install` after pulling the package. Including
      # node_modules pushes the tarball past Hex's 8 MB limit.
      files: [
        "lib",
        "mix.exs",
        "README.md",
        "LICENSE.md",
        "priv/cdp",
        "priv/run_command.sh",
        # Bootstrap reads this at compile time via @external_resource
        # — it must be in the tarball so the consumer's compile sees it.
        # priv/surfboard.min.js is a build artifact (`mix surfboard.minify`)
        # not yet generated for this extraction — ship the readable source
        # only until that's run.
        "priv/surfboard.js",
        "priv/bidi-server/package.json",
        "priv/bidi-server/package-lock.json",
        "priv/bidi-server/run.mjs"
      ],
      maintainers: @maintainers,
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      }
    ]
  end

  defp docs do
    [
      extras: [
        "README.md": [title: "Introduction"]
      ],
      source_ref: "v#{@version}",
      source_url: @source_url,
      main: "readme"
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:inets],
      list_unused_filters: false
    ]
  end
end
