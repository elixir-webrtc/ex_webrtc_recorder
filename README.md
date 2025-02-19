# ExWebRTC Recorder

[![Hex.pm](https://img.shields.io/hexpm/v/ex_webrtc_recorder.svg)](https://hex.pm/packages/ex_webrtc_recorder)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/ex_webrtc_recorder)

Records and processes RTP packets sent and received using [ExWebRTC](https://github.com/elixir-webrtc/ex_webrtc).

## Installation

Add `:ex_webrtc_recorder` to your list of dependencies

```elixir
def deps do
  [
    {:ex_webrtc_recorder, "~> 0.1.0"}
  ]
end
```

If you want to use Converter to generate WEBM files from the recordings,
you need to have the `ffmpeg` binary with the relevant libraries present in `PATH`.

### S3

ExWebRTC Recorder comes with optional support for uploading the recordings to S3-compatible storage,
but it must be explicitly turned on by adding the following dependencies:

```elixir
def deps do
  [
    {:ex_webrtc_recorder, "~> 0.1.0"},
    {:ex_aws_s3, "~> 2.5"},
    {:ex_aws, "~> 2.5"},
    {:sweet_xml, "~> 0.7"},
    {:req, "~> 0.5"}         # or any other HTTP client supported by `ex_aws`
  ]
end
```

See `ExWebRTC.Recorder.S3` for more info.
