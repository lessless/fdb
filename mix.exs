defmodule FDB.MixProject do
  use Mix.Project

  @version "7.3.69-0"

  def project do
    [
      app: :fdb,
      make_clean: ["clean"],
      compilers: [:elixir_make] ++ Mix.compilers(),
      version: @version,
      elixir: "~> 1.3",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "FoundationDB client",
      package: package(),
      docs: docs(),
      dialyzer: [
        plt_add_deps: :transitive,
        ignore_warnings: ".dialyzer_ignore",
        flags: [:unmatched_returns, :race_conditions, :error_handling]
      ],
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp deps do
    [
      {:elixir_make, "~> 0.4", runtime: false},
      {:sweet_xml, "~> 0.7", runtime: false},
      {:stream_data, "~> 1.2", only: [:test, :dev]},
      {:timex, "~>  3.7", only: :test},
      {:ex_doc, "~> 0.18", only: :dev},
      {:dialyxir, "~> 1.0.0-rc.2", only: [:dev], runtime: false},
      {:benchee, "~>  1.4.0", only: :dev},
      {:exprof, "~> 0.2.3", only: :dev},
      {:jason, "~> 1.0", only: [:dev, :test]},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end

  defp package do
    %{
      licenses: ["MIT"],
      links: %{"Github" => "https://github.com/ananthakumaran/fdb"},
      maintainers: ["ananthakumaran@gmail.com"],
      files: [
        "lib",
        "priv/fdb.options",
        "mix.exs",
        "README*",
        "LICENSE*",
        "Makefile",
        "Makefile.win",
        "c_src"
      ]
    }
  end

  defp docs do
    [
      source_url: "https://github.com/ananthakumaran/fdb",
      source_ref: "v#{@version}",
      main: FDB,
      extras: ["README.md"]
    ]
  end
end
