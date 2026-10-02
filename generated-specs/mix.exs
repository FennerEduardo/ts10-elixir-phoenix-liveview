defmodule TransactionalSystemElixirPhoenix.MixProject do
  use Mix.Project

  def project do
    [
      app: :transactional_system_elixir_phoenix,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [mod: {TransactionalSystemElixirPhoenix.Application, []}, extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.7.14"},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.5"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.1"},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end
end
