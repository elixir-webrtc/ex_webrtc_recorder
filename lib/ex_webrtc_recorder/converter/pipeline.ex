defmodule ExWebRTC.Recorder.Converter.Pipeline do
  # This pipeline:
  # - takes the sorted RTP packets from Converter,
  # - depayloads the VP8/Opus media within,
  # - and dumps them into two separate WEBM files.
  #
  # The result file is then generated using FFmpeg.
  # We have to do it this way, because at the moment `Membrane.Matroska.Muxer` ignores the difference in PTS
  # of the audio and video tracks, which means we're unable to synchronize them using only Membrane.

  defmodule Source do
    @moduledoc false
    use Membrane.Source

    def_options stream: [
                  spec: Enumerable.t()
                ]

    def_output_pad(:output, accepted_format: Membrane.RTP, flow_control: :manual)

    @impl true
    def handle_init(_ctx, %__MODULE__{stream: stream}) do
      {[], %{stream: stream}}
    end

    @impl true
    def handle_playing(_ctx, state) do
      {[stream_format: {:output, %Membrane.RTP{}}], state}
    end

    @impl true
    def handle_demand(:output, size, :buffers, _ctx, state) do
      {actions, state} =
        case Enum.take(state.stream, size) do
          [] ->
            {[end_of_stream: :output], state}

          packets ->
            {[buffer: {:output, Enum.map(packets, &to_membrane_buffer/1)}, redemand: :output],
             state}
        end

      {actions, state}
    end

    defp to_membrane_buffer(packet) do
      %Membrane.Buffer{payload: packet.payload, metadata: %{rtp: %{packet | payload: <<>>}}}
    end
  end

  @moduledoc false
  use Membrane.Pipeline

  def start_link(video_stream, audio_stream, output_path) do
    Membrane.Pipeline.start_link(__MODULE__, %{
      video_stream: video_stream,
      audio_stream: audio_stream,
      output_path: output_path
    })
  end

  @impl true
  def handle_init(_ctx, opts) do
    # TODO: Support codecs other than VP8/Opus
    # TODO: Use a single muxer + sink once `Membrane.Matroska.Muxer` supports synchronizing AV
    spec = [
      child(:video_source, %Source{stream: opts.video_stream})
      |> child(:video_depayloader, %Membrane.RTP.DepayloaderBin{
        clock_rate: 90_000,
        depayloader: Membrane.RTP.VP8.Depayloader
      })
      |> child(:video_muxer, Membrane.Matroska.Muxer)
      |> child(:video_sink, %Membrane.File.Sink{location: opts.output_path <> "_video.webm"}),
      child(:audio_source, %Source{stream: opts.audio_stream})
      |> child(:audio_depayloader, %Membrane.RTP.DepayloaderBin{
        clock_rate: 48_000,
        depayloader: Membrane.RTP.Opus.Depayloader
      })
      |> child(:opus_parser, Membrane.Opus.Parser)
      |> child(:audio_muxer, Membrane.Matroska.Muxer)
      |> child(:audio_sink, %Membrane.File.Sink{location: opts.output_path <> "_audio.webm"})
    ]

    {[spec: spec], %{}}
  end

  @impl true
  def handle_element_end_of_stream(sink, _pad, _ctx, state)
      when sink in [:video_sink, :audio_sink] do
    state = Map.update(state, :sinks_done, 1, &(&1 + 1))

    if state.sinks_done == 2 do
      {[terminate: :normal], state}
    else
      {[], state}
    end
  end

  @impl true
  def handle_element_end_of_stream(_element, _pad, _ctx, state) do
    {[], state}
  end
end
