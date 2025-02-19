defmodule ExWebRTC.Recorder.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/elixir-webrtc/ex_webrtc_recorder"

  def project do
    [
      app: :ex_webrtc_recorder,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: "Records and processes RTP packets sent and received using ExWebRTC",
      package: package(),
      deps: deps(),

      # docs
      docs: docs(),
      source_url: @source_url,

      # dialyzer
      dialyzer: [
        plt_local_path: "_dialyzer",
        plt_core_path: "_dialyzer"
      ],

      # code coverage
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.json": :test
      ]
    ]
  end

  def application do
    [
      mod: {ExWebRTC.Recorder.App, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  def package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp deps do
    [
      {:ex_webrtc, github: "elixir-webrtc/ex_webrtc", branch: "sgfn/extract-recorder"},
      {:jason, "~> 1.4"},
      {:ex_aws_s3, "~> 2.5", optional: true},
      {:ex_aws, "~> 2.5", optional: true},
      {:sweet_xml, "~> 0.7", optional: true},
      {:req, "~> 0.5", optional: true},

      # dev/test
      {:excoveralls, "~> 0.18.0", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}",
      formatters: ["html"],
      nest_modules_by_prefix: [ExWebRTC.Recorder]
    ]
  end
end
