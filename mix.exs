defmodule McFun.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      preferred_cli_env: [precommit: :test]
    ]
  end

  defp deps do
    []
  end

  defp aliases do
    [
      setup: ["deps.get", "cmd mix setup"],
      "assets.setup": ["cmd --app mc_fun_web mix assets.setup"],
      "assets.build": ["cmd --app mc_fun_web mix assets.build"],
      "assets.deploy": ["cmd --app mc_fun_web mix assets.deploy"],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "test"
      ]
    ]
  end
end
