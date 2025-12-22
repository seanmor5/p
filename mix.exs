defmodule P.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/seanmor5/p"

  def project do
    [
      app: :p,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "P",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:rustler, "~> 0.36.1", runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Low-level OS process management for Elixir. Spawn processes, send signals, wait for exit. Rust NIF using nix. Linux only."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib native .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "P",
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
