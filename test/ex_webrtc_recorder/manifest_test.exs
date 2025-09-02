defmodule ExWebRTC.Recorder.Manifest.Test do
  use ExUnit.Case, async: true

  alias ExWebRTC.Recorder.Manifest
  alias ExWebRTC.RTPCodecParameters
  alias ExSDP.Attribute.{FMTP, RTCPFeedback}

  describe "to_json!/1" do
    test "empty manifest" do
      manifest = %{}
      json = Manifest.to_json!(manifest)
      assert json == %{}
    end

    test "two entries(audio,video) manifest" do
      audio_id = 6_264_340_764_417_145_606_381_315_372
      video_id = 34_899_663_449_195_684_468_354_913_891
      base_dir = "/Users/bernardgawor/Projects/swm/broadcaster/recordings/20250902-163515"
      audio_path = Path.join(base_dir, "6264340764417145606381315372.rtpx")
      video_path = Path.join(base_dir, "34899663449195684468354913891.rtpx")
      streams = ["{13d54720-6d00-45a9-b234-11f0e969f4b7}"]
      start_time = ~U[2025-09-02 14:35:15.336022Z]

      manifest = %{
        audio_id => %{
          location: audio_path,
          kind: :audio,
          streams: streams,
          start_time: start_time,
          codec: audio_opus_codec(),
          rid_map: %{nil: 0}
        },
        video_id => %{
          location: video_path,
          kind: :video,
          streams: streams,
          start_time: start_time,
          codec: video_vp8_codec(),
          rid_map: %{nil: 0}
        }
      }

      json = Manifest.to_json!(manifest)

      assert json ==
               %{
                 audio_id => %{
                   "codec" => %{
                     "channels" => 2,
                     "clock_rate" => 48_000,
                     "mime_type" => "audio/opus",
                     "payload_type" => 109,
                     "rtcp_fbs" => nil,
                     "sdp_fmtp_line" => "109 maxplaybackrate=48000;stereo=1;useinbandfec=1"
                   },
                   "kind" => "audio",
                   "location" => audio_path,
                   "rid_map" => %{"nil" => 0},
                   "start_time" => "2025-09-02T14:35:15.336022Z",
                   "streams" => streams
                 },
                 video_id => %{
                   "codec" => %{
                     "channels" => nil,
                     "clock_rate" => 90_000,
                     "mime_type" => "video/VP8",
                     "payload_type" => 120,
                     "rtcp_fbs" => ["120 nack", "120 nack pli", "120 ccm fir", "120 transport-cc"],
                     "sdp_fmtp_line" => "120 max-fs=12288;max-fr=60"
                   },
                   "kind" => "video",
                   "location" => video_path,
                   "rid_map" => %{"nil" => 0},
                   "start_time" => "2025-09-02T14:35:15.336022Z",
                   "streams" => streams
                 }
               }
    end
  end

  describe "from_json!/1" do
    test "empty manifest" do
      json = %{}
      manifest = Manifest.from_json!(json)
      assert manifest == %{}
    end

    test "two entries(audio,video) manifest" do
      json =
        Jason.decode!("""
        {
          "6264340764417145606381315372": {
            "codec": {
              "channels": 2,
              "clock_rate": 48000,
              "mime_type": "audio/opus",
              "payload_type": 109,
              "rtcp_fbs": null,
              "sdp_fmtp_line": "109 maxplaybackrate=48000;stereo=1;useinbandfec=1"
            },
            "kind": "audio",
            "location": "/Users/bernardgawor/Projects/swm/broadcaster/recordings/20250902-163515/6264340764417145606381315372.rtpx",
            "rid_map": {
              "nil": 0
            },
            "start_time": "2025-09-02T14:35:15.336022Z",
            "streams": [
              "{13d54720-6d00-45a9-b234-11f0e969f4b7}"
            ]
          },
          "34899663449195684468354913891": {
            "codec": {
              "channels": null,
              "clock_rate": 90000,
              "mime_type": "video/VP8",
              "payload_type": 120,
              "rtcp_fbs": [
                "120 nack",
                "120 nack pli",
                "120 ccm fir",
                "120 transport-cc"
              ],
              "sdp_fmtp_line": "120 max-fs=12288;max-fr=60"
            },
            "kind": "video",
            "location": "/Users/bernardgawor/Projects/swm/broadcaster/recordings/20250902-163515/34899663449195684468354913891.rtpx",
            "rid_map": {
              "nil": 0
            },
            "start_time": "2025-09-02T14:35:15.336022Z",
            "streams": [
              "{13d54720-6d00-45a9-b234-11f0e969f4b7}"
            ]
          }
        }
        """)

      manifest = Manifest.from_json!(json)

      assert manifest ==
               %{
                 "34899663449195684468354913891" => %{
                   location:
                     "/Users/bernardgawor/Projects/swm/broadcaster/recordings/20250902-163515/34899663449195684468354913891.rtpx",
                   kind: :video,
                   streams: ["{13d54720-6d00-45a9-b234-11f0e969f4b7}"],
                   start_time: ~U[2025-09-02 14:35:15.336022Z],
                   codec: video_vp8_codec(),
                   rid_map: %{nil: 0}
                 },
                 "6264340764417145606381315372" => %{
                   location:
                     "/Users/bernardgawor/Projects/swm/broadcaster/recordings/20250902-163515/6264340764417145606381315372.rtpx",
                   kind: :audio,
                   streams: ["{13d54720-6d00-45a9-b234-11f0e969f4b7}"],
                   start_time: ~U[2025-09-02 14:35:15.336022Z],
                   codec: audio_opus_codec(),
                   rid_map: %{nil: 0}
                 }
               }
    end
  end

  # Helpers
  defp audio_opus_codec do
    %RTPCodecParameters{
      payload_type: 109,
      mime_type: "audio/opus",
      clock_rate: 48_000,
      channels: 2,
      sdp_fmtp_line: %FMTP{pt: 109, maxplaybackrate: 48_000, stereo: true, useinbandfec: true},
      rtcp_fbs: []
    }
  end

  defp video_vp8_codec do
    %RTPCodecParameters{
      payload_type: 120,
      mime_type: "video/VP8",
      clock_rate: 90_000,
      channels: nil,
      sdp_fmtp_line: %FMTP{pt: 120, max_fs: 12_288, max_fr: 60},
      rtcp_fbs: [
        %RTCPFeedback{pt: 120, feedback_type: :nack},
        %RTCPFeedback{pt: 120, feedback_type: :pli},
        %RTCPFeedback{pt: 120, feedback_type: :fir},
        %RTCPFeedback{pt: 120, feedback_type: :twcc}
      ]
    }
  end
end
