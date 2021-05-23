defmodule MeshxRpc.MixProject do
  use Mix.Project

  @source_url "https://github.com/andrzej-mag/meshx_rpc"
  @version "0.1.0"

  def project do
    [
      app: :meshx_rpc,
      version: @version,
      elixir: "~> 1.11",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      name: "MeshxRpc",
      description: "RPC client and server"
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:ex_doc, "~> 0.24.2", only: :dev, runtime: false},
      {:nimble_options, "~> 0.3.5"},
      {:poolboy, "~> 1.5", [optional: true]},
      {:ranch, "~> 2.0", [optional: true]},
      {:telemetry, "~> 0.4.2"}
    ]
  end

  defp package do
    [
      files: ~w(lib docs .formatter.exs mix.exs),
      maintainers: ["Andrzej Magdziarz"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "MeshxRpc",
      assets: "docs/assets",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: ["docs/protocol.md"],
      deps: [
        meshx: "https://hexdocs.pm/meshx",
        meshx_consul: "https://hexdocs.pm/meshx_consul",
        meshx_node: "https://hexdocs.pm/meshx_node"
      ]
    ]
  end
end
