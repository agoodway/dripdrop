defmodule DripDrop.MixProject do
  use Mix.Project

  @version "0.2.1"
  @source_url "https://github.com/agoodway/dripdrop"

  def project do
    [
      app: :dripdrop,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      description: description(),
      package: package(),
      dialyzer: dialyzer(),
      name: "DripDrop",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test, quality: :test]]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {DripDrop.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ecto, "~> 3.13"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, "~> 0.20"},
      {:pgflow, "~> 0.3.1"},
      # {:pgflow, path: "../pgflow"},
      {:ecto_evolver, "~> 0.1.0"},
      {:crontab, "~> 1.1"},
      {:cloak_ecto, "~> 1.3"},
      {:predicated, "~> 1.1"},
      {:nebulex, "~> 3.0"},
      {:nebulex_local, "~> 3.0"},
      {:req, "~> 0.7"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.17"},
      {:floki, "~> 0.37"},
      {:telemetry, "~> 1.3"},
      {:ex_phone_number, "~> 0.4"},
      {:ex_email, "~> 1.0"},

      # Optional channel/template dependencies
      {:swoosh, "~> 1.19", optional: true},
      {:finch, "~> 0.20", optional: true},
      {:liquex, "~> 0.15"},
      {:mjml, "~> 6.0", optional: true},
      {:phoenix_pubsub, "~> 2.1", optional: true},
      {:phoenix, "~> 1.7 or ~> 1.8", optional: true},
      {:phoenix_live_view, "~> 1.1", optional: true},
      {:oban, "~> 2.22", optional: true},
      {:ex_aws_sns, "~> 2.3", optional: true},
      {:ex_gram, "~> 0.69.0", optional: true},
      {:whatsapp_sdk, "~> 0.1.0", optional: true},

      # Development tooling
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:tidewave, "~> 0.5", only: :dev},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.3", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.22", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.2", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"],
      quality: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format --check-formatted",
        "sobelow --config",
        "ex_dna",
        "doctor",
        "credo --strict"
      ]
    ]
  end

  defp description do
    "Database-driven, multi-channel messaging sequence engine for Elixir."
  end

  defp package do
    [
      maintainers: ["Chase Pursley"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(
        lib priv config guides
        .formatter.exs .credo.exs .doctor.exs .sobelow-conf
        mix.exs README.md LICENSE
      )
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix, :ex_unit],
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
      ignore_warnings: ".dialyzer_ignore.exs",
      flags: [:error_handling, :unknown]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "guides/installation.md",
        "guides/sending_rules.md",
        "guides/lifecycle_email.md",
        "guides/quiet_hours.md",
        "guides/short_links.md",
        "guides/oauth_providers.md",
        "guides/cold_outbound.md",
        "guides/operations.md",
        "guides/extending.md"
      ],
      source_ref: "v#{@version}"
    ]
  end
end
