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

TODO add necessary steps

ExWebRTC Recorder comes with optional support for uploading the recordings to S3-compatible storage,
but it must be explicitely turned on by adding the following optional dependencies:
* `:ex_aws_s3`
* `:ex_aws`
* `:sweet_xml`
* an HTTP client (e.g. `:req`)

```elixir
def deps do
  [
    {:ex_webrtc_recorder, "~> 0.1.0"},
    {:ex_aws_s3, "~> 2.5"},
    {:ex_aws, "~> 2.5"},
    {:sweet_xml, "~> 0.7"},
    {:req, "~> 0.5"}
  ]
end
```
