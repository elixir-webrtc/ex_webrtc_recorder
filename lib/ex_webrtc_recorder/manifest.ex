defmodule ExWebRTC.Recorder.Manifest do
  @moduledoc """
  Lists the tracks recorded by a specific Recorder instance.
  """

  alias ExWebRTC.MediaStreamTrack

  @typedoc """
  Location of a manifest entry.

  Can be one of the following:
  * Local path, e.g. `"foo/bar/recording.webm"`
  * URL with the `file://` scheme, e.g. `"file:///baz/qux/recording.webm"`
  * URL with the `s3://` scheme, e.g. `"s3://my-bucket-name/abc/recording.webm"`
  """
  @type location :: String.t()

  @type track_manifest :: %{
          start_time: DateTime.t(),
          kind: :video | :audio,
          streams: [MediaStreamTrack.stream_id()],
          rid_map: %{MediaStreamTrack.rid() => integer()},
          codec: ExWebRTC.RTPCodecParameters.t() | nil,
          location: location()
        }

  @type t :: %{MediaStreamTrack.id() => track_manifest()}

  @doc false
  @spec to_map(t()) :: map()
  def to_map(manifest) do
    Map.new(manifest, fn {id, entry} ->
      {
        id,
        %{
          "start_time" => DateTime.to_iso8601(entry.start_time),
          "kind" => Atom.to_string(entry.kind),
          "streams" => entry.streams,
          "rid_map" => encode_rid_map(entry.rid_map),
          "codec" => encode_codec(entry.codec),
          "location" => entry.location
        }
      }
    end)
  end

  defp encode_rid_map(rid_map) do
    Map.new(rid_map, fn
      {nil, v} -> {"nil", v}
      {layer, v} -> {layer, v}
    end)
  end

  defp encode_codec(nil), do: nil

  defp encode_codec(%ExWebRTC.RTPCodecParameters{} = codec) do
    %{
      "payload_type" => codec.payload_type,
      "mime_type" => codec.mime_type,
      "clock_rate" => codec.clock_rate,
      "channels" => codec.channels,
      "sdp_fmtp_line" => fmtp_to_string(codec.sdp_fmtp_line),
      "rtcp_fbs" => rtcp_fbs_to_strings(codec.rtcp_fbs)
    }
  end

  defp fmtp_to_string([]), do: nil
  defp fmtp_to_string(nil), do: nil
  defp fmtp_to_string(fmtp), do: fmtp |> to_string() |> String.replace_prefix("fmtp:", "")

  defp rtcp_fbs_to_strings(nil), do: nil
  defp rtcp_fbs_to_strings([]), do: nil

  defp rtcp_fbs_to_strings(list) when is_list(list) do
    list
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.replace_prefix(&1, "rtcp-fb:", ""))
  end

  @doc false
  @spec from_json!(map()) :: t()
  def from_json!(json_manifest) do
    Map.new(json_manifest, fn {id, entry} ->
      {id, parse_entry(entry)}
    end)
  end

  defp parse_entry(%{
         "start_time" => start_time,
         "kind" => kind,
         "streams" => streams,
         "rid_map" => rid_map,
         "codec" => codec,
         "location" => location
       }) do
    %{
      streams: streams,
      location: location,
      start_time: parse_start_time(start_time),
      rid_map: parse_rid_map(rid_map),
      kind: parse_kind(kind),
      codec: parse_codec(codec)
    }
  end

  defp parse_start_time(start_time) do
    {:ok, start_time, _offset} = DateTime.from_iso8601(start_time)
    start_time
  end

  defp parse_rid_map(rid_map) do
    Map.new(rid_map, fn
      {"nil", v} -> {nil, v}
      {layer, v} -> {layer, v}
    end)
  end

  defp parse_kind("video"), do: :video
  defp parse_kind("audio"), do: :audio

  defp parse_codec(%{
         "payload_type" => payload_type,
         "mime_type" => mime_type,
         "clock_rate" => clock_rate,
         "channels" => channels,
         "sdp_fmtp_line" => sdp_fmtp_line,
         "rtcp_fbs" => rtcp_fbs
       }) do
    %ExWebRTC.RTPCodecParameters{
      payload_type: payload_type,
      mime_type: mime_type,
      clock_rate: clock_rate,
      channels: channels,
      sdp_fmtp_line: parse_sdp_fmtp_line(sdp_fmtp_line),
      rtcp_fbs: parse_rtcp_fbs(rtcp_fbs)
    }
  end

  defp parse_codec(nil), do: nil

  defp parse_sdp_fmtp_line(sdp_fmtp_line) when is_binary(sdp_fmtp_line) do
    {:ok, fmtp} = ExSDP.Attribute.FMTP.parse(sdp_fmtp_line)
    fmtp
  end

  defp parse_sdp_fmtp_line(nil), do: []

  defp parse_rtcp_fbs(rtcp_fbs) when is_list(rtcp_fbs) do
    Enum.map(rtcp_fbs, fn fb ->
      {:ok, rtcp_fb} = ExSDP.Attribute.RTCPFeedback.parse(fb)
      rtcp_fb
    end)
  end

  defp parse_rtcp_fbs(nil), do: []
end
