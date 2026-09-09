defmodule SurfBoard.MixProject do
  use Mix.Project

  @source_url "https://github.com/surf-ex/surf_board"
  @version "0.1.0"
  @maintainers ["Tom Clarke"]

  def project do
    [
      app: :surf_board,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      package: package(),
      description:
        "Concurrent browser automation for Elixir — drive Chrome, Chromium, or Lightpanda " <>
          "via CDP/BiDi. Extracted from Wallabidi's driving layer, itself a fork of Wallaby.",
      deps: deps(),
      docs: docs(),
      dialyzer: dialyzer(),
      test_paths: test_paths()
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {SurfBoard, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support", "integration_test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # SURF_BOARD_INTEGRATION=1 mix test switches the whole suite root to
  # integration_test/cases (real Chrome/Lightpanda/BiDi against a local
  # fixture server) instead of the default unit suite under test/. Kept
  # as an opt-in env var, not a separate Mix env, so `mix test` alone
  # (CI's default) never needs real browsers.
  defp test_paths do
    if System.get_env("SURF_BOARD_INTEGRATION") == "1" do
      ["integration_test/cases"]
    else
      ["test"]
    end
  end

  defp deps do
    [
      {:jason, "~> 1.1"},
      {:mint, "~> 1.6"},
      {:mint_web_socket, "~> 1.0"},
      {:lazy_html, "~> 0.1"},
      {:lightpanda, "~> 0.3.6"},
      # Test-only: a plain static-file server for the integration smoke
      # suite's fixture pages — not Phoenix, just Plug.Static + Cowboy.
      {:plug_cowboy, "~> 2.7", only: :test},
      {:dialyxir, "~> 1.0", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.28", only: :dev}
    ]
  end

  defp package do
    [
      # Don't ship priv/bidi-server/node_modules — consumers run `npm install`
      # via `mix surf_board.install` after pulling the package. Including
      # node_modules pushes the tarball past Hex's 8 MB limit.
      files: [
        "lib",
        "mix.exs",
        "README.md",
        "LICENSE.md",
        "NOTICE.md",
        "priv/cdp",
        "priv/run_command.sh",
        # Bootstrap reads this at compile time via @external_resource
        # — it must be in the tarball so the consumer's compile sees it.
        # priv/surf_board.min.js is a build artifact (`mix surf_board.minify`)
        # not yet generated for this extraction — ship the readable source
        # only until that's run.
        "priv/surf_board.js",
        "priv/bidi-server/package.json",
        "priv/bidi-server/package-lock.json",
        "priv/bidi-server/run.mjs"
      ],
      maintainers: @maintainers,
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Wallabidi (upstream)" => "https://github.com/u2i/wallabidi",
        "Wallaby (upstream of Wallabidi)" => "https://github.com/elixir-wallaby/wallaby"
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
