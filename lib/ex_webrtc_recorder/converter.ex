defmodule ExWebRTC.Recorder.Converter do
  @moduledoc """
  Processes RTP packet files saved by `ExWebRTC.Recorder`.

  Requires the `ffmpeg` binary with the relevant libraries present in `PATH`.

  At the moment, `ExWebRTC.Recorder.Converter` works only with VP8 video and Opus audio.

  Can optionally download/upload the source/result files from/to S3-compatible storage.
  See `ExWebRTC.Recorder.S3` and `t:options/0` for more info.
  """

  alias ExWebRTC.RTP.JitterBuffer.PacketStore
  alias ExWebRTC.RTP.Depayloader

  alias ExWebRTC.Recorder.S3
  alias ExWebRTC.{Recorder, RTPCodecParameters}

  alias __MODULE__.{FFmpeg, Pipeline}

  require Logger

  # TODO: Support codecs other than VP8/Opus
  @video_codec_params %RTPCodecParameters{
    payload_type: 96,
    mime_type: "video/VP8",
    clock_rate: 90_000
  }

  @audio_codec_params %RTPCodecParameters{
    payload_type: 111,
    mime_type: "audio/opus",
    clock_rate: 48_000,
    channels: 2
  }

  #
  ## DEFAULT PARAMS

  @default_output_path "./converter/output"
  @default_download_path "./converter/download"
  @default_reorder_buffer_size 100
  @default_reencode_bitrate "1.5M"
  @default_reencode_crf 10
  @default_reencode_gop_size 125
  @default_reencode_cues_to_front true

  #
  ## PUBLIC TYPES

  @typedoc """
  Resolution of reencoded video and generated thumbnails.

  Make sure to provide at least one of the dimensions.
  Setting the other dimension to `-1` will fit the image to the aspect ratio.
  """
  @type resolution :: %{
          optional(:width) => pos_integer() | -1,
          optional(:height) => pos_integer() | -1
        }

  @typedoc """
  Context for the thumbnail generation.

  * `:resolution` (required) - Thumbnail size. See `t:resolution/0` for more info.
  """
  @type thumbnails_ctx :: %{
          :resolution => resolution()
        }

  @typedoc """
  Context for the video reencoding. See `man ffmpeg` for more details.

  * `:threads` - How many threads to use. Unlimited by default.
  * `:bitrate` - Video bitrate the VP8 encoder shall strive for. `#{@default_reencode_bitrate}` by default.
  * `:crf` - Output video quality (lower is better). `#{@default_reencode_crf}` by default.
  * `:gop_size` - Keyframe interval. `#{@default_reencode_gop_size}` by default.
  * `:resolution` - Output video resolution. Inferred from the first video frame by default.
    See `t:resolution/0` for more info.
  * `:cues_to_front` - Whether the muxer should put MKV Cues element at the front of the file,
    to aid with seeking e.g. when streaming the result file. `#{@default_reencode_cues_to_front}` by default.
  """
  @type reencode_ctx :: %{
          optional(:threads) => pos_integer(),
          optional(:bitrate) => String.t(),
          optional(:crf) => 4..63,
          optional(:gop_size) => pos_integer(),
          optional(:resolution) => resolution(),
          optional(:cues_to_front) => boolean()
        }

  @typedoc """
  Options that can be passed to `convert!/2`.

  * `:output_path` - Directory where Converter will save its artifacts. `#{@default_output_path}` by default.
  * `:s3_upload_config` - If passed, processed recordings will be uploaded to S3-compatible storage.
    See `t:ExWebRTC.Recorder.S3.upload_config/0` for more info.
  * `:download_path` - Directory where Converter will save files fetched from S3. `#{@default_download_path}` by default.
  * `:s3_download_config` - Optional S3 config overrides used when fetching files.
    See `t:ExWebRTC.Recorder.S3.override_config/0` for more info.
  * `:thumbnails_ctx` - If passed, Converter will generate thumbnails for the output files.
    See `t:thumbnails_ctx/0` for more info.
  * `:only_rids` - By default, when processing a video track with multiple layers (i.e. simulcast),
    Converter generates multiple output files, one per layer. If passed, Converter will only process
    the layers with RIDs present in this list. E.g. if you want to receive a single video file
    from the layer `"h"`, pass `["h"]`. For single-layer tracks RID is set to `nil`,
    so if you want to handle both simulcast and regular tracks, pass `["h", nil]`.
  * `:reorder_buffer_size` - Size of the buffer used for reordering late packets. `#{@default_reorder_buffer_size}` by default.
    Increasing this value may help with "Decoded late RTP packet" warnings,
    but keep in mind that larger values slow the conversion process considerably.
  * `:reencode_ctx` - If passed, Converter will reencode the video using FFmpeg.
    The keyframe interval of video tracks sent over WebRTC may vary, so this is helpful when
    you want to generate additional ones, to facilitate accurate seeking in the result file during playback.
    Keep in mind that reenncoding is slow and resource-intensive.
    See `t:reencode_ctx/0` for more info.
  """
  @type option ::
          {:output_path, Path.t()}
          | {:s3_upload_config, keyword()}
          | {:download_path, Path.t()}
          | {:s3_download_config, keyword()}
          | {:thumbnails_ctx, thumbnails_ctx()}
          | {:only_rids, [ExWebRTC.MediaStreamTrack.rid() | nil]}
          | {:reorder_buffer_size, pos_integer()}
          | {:reencode_ctx, reencode_ctx()}

  @type options :: [option()]

  #
  ## PUBLIC FUNCTIONS

  @doc """
  Converts the saved dumps of tracks in the manifest to WEBM files.

  If passed a path as the first argument, loads the recording manifest from file.
  """
  @spec convert!(Path.t() | Recorder.Manifest.t(), options()) ::
          __MODULE__.Manifest.t() | no_return()
  def convert!(recorder_manifest_or_path, options \\ [])

  def convert!(recorder_manifest_path, options) when is_binary(recorder_manifest_path) do
    recorder_manifest_path =
      recorder_manifest_path
      |> Path.expand()
      |> then(
        &if(File.dir?(&1),
          do: Path.join(&1, "manifest.json"),
          else: &1
        )
      )

    recorder_manifest =
      recorder_manifest_path
      |> File.read!()
      |> Jason.decode!()
      |> Recorder.Manifest.from_json!()

    convert!(recorder_manifest, options)
  end

  def convert!(recorder_manifest, options) when map_size(recorder_manifest) > 0 do
    thumbnails_ctx = get_thumbnails_ctx(options)
    reencode_ctx = get_reencode_ctx(options)

    rid_allowed? =
      case Keyword.get(options, :only_rids) do
        nil ->
          fn _rid -> true end

        allowed_rids ->
          fn rid -> Enum.member?(allowed_rids, rid) end
      end

    reorder_buffer_size = Keyword.get(options, :reorder_buffer_size, @default_reorder_buffer_size)

    output_path = Keyword.get(options, :output_path, @default_output_path) |> Path.expand()
    download_path = Keyword.get(options, :download_path, @default_download_path) |> Path.expand()
    File.mkdir_p!(output_path)
    File.mkdir_p!(download_path)

    download_config = Keyword.get(options, :s3_download_config, [])

    upload_handler =
      if options[:s3_upload_config] do
        Logger.info("Converted recordings will be uploaded to S3")
        S3.UploadHandler.new(options[:s3_upload_config])
      end

    recorder_manifest
    |> fetch_remote_files!(download_path, download_config)
    |> do_convert_manifest!(
      output_path,
      thumbnails_ctx,
      rid_allowed?,
      reorder_buffer_size,
      reencode_ctx
    )
    |> maybe_upload_result!(upload_handler)
  end

  def convert!(_empty_manifest, _options), do: %{}

  #
  ## PRIVATE FUNCTIONS
  # Option parsing

  defp get_thumbnails_ctx(options) do
    case Keyword.get(options, :thumbnails_ctx) do
      nil ->
        nil

      ctx ->
        %{
          resolution: fill_resolution_dimensions(ctx.resolution)
        }
    end
  end

  defp get_reencode_ctx(options) do
    case Keyword.get(options, :reencode_ctx) do
      nil ->
        nil

      ctx ->
        %{
          threads: ctx[:threads],
          bitrate: ctx[:bitrate] || @default_reencode_bitrate,
          crf: ctx[:crf] || @default_reencode_crf,
          gop_size: ctx[:gop_size] || @default_reencode_gop_size,
          resolution: fill_resolution_dimensions(ctx[:resolution]),
          cues_to_front: ctx[:cues_to_front] || @default_reencode_cues_to_front
        }
    end
  end

  defp fill_resolution_dimensions(nil), do: nil

  defp fill_resolution_dimensions(resolution) do
    %{
      width: resolution[:width] || -1,
      height: resolution[:height] || -1
    }
  end

  #
  # Downloading input files

  defp fetch_remote_files!(manifest, dl_path, dl_config) do
    Map.new(manifest, fn {track_id, %{location: location} = track_data} ->
      scheme = URI.parse(location).scheme || "file"

      {:ok, local_path} =
        case scheme do
          "file" -> {:ok, String.replace_prefix(location, "file://", "")}
          "s3" -> fetch_from_s3(location, dl_path, dl_config)
        end

      {track_id, %{track_data | location: Path.expand(local_path)}}
    end)
  end

  defp fetch_from_s3(url, dl_path, dl_config) do
    Logger.info("Fetching file #{url}")

    with {:ok, bucket_name, s3_path} <- S3.Utils.parse_url(url),
         out_path <- Path.join(dl_path, Path.basename(s3_path)),
         {:ok, _result} <- S3.Utils.fetch_file(bucket_name, s3_path, out_path, dl_config) do
      {:ok, out_path}
    else
      # FIXME: Add descriptive errors
      _other -> :error
    end
  end

  #
  # Conversion

  defp do_convert_manifest!(
         manifest,
         output_path,
         thumbnails_ctx,
         rid_allowed?,
         reorder_buffer_size,
         reencode_ctx
       ) do
    # What's happening here:
    # 1. Read tracks
    # 2. Convert tracks to WEBM files
    # 3. Mux WEBM files into a single file
    stream_map =
      Enum.reduce(manifest, %{}, fn {_id, track}, stream_map ->
        %{
          location: path,
          kind: kind,
          streams: streams,
          rid_map: rid_map
        } = track

        file =
          with {:ok, %File.Stat{size: s}} <- File.stat(path),
               true <- s > 0,
               {:ok, file} <- File.open(path) do
            file
          else
            false ->
              raise "File #{path} is empty!"

            {:error, reason} ->
              raise "Unable to open #{path}: #{inspect(reason)}"
          end

        packets =
          read_packets(
            file,
            Map.new(rid_map, fn {_rid, rid_idx} ->
              {rid_idx, %{store: %PacketStore{}, acc: [], packets_in_store: 0}}
            end),
            reorder_buffer_size
          )

        track_contexts =
          case kind do
            :video ->
              rid_map = filter_rids(rid_map, rid_allowed?)
              get_video_track_contexts(rid_map, packets)

            :audio ->
              get_audio_track_context(packets)
          end

        stream_id = List.first(streams)

        stream_map
        |> Map.put_new(stream_id, %{video: %{}, audio: %{}})
        |> Map.update!(stream_id, &Map.put(&1, kind, track_contexts))
      end)

    Enum.flat_map(stream_map, fn {stream_id, %{video: v, audio: a}} ->
      cond do
        map_size(v) == 0 and map_size(a) == 0 ->
          raise "Stream #{stream_id} contains no tracks!"

        map_size(v) == 0 ->
          %{nil => audio_ctx} = a
          output_file = Path.join(output_path, "#{stream_id}.webm")
          output_file |> Path.dirname() |> File.mkdir_p!()
          [{stream_id, process!(nil, audio_ctx, output_file, nil, nil)}]

        true ->
          for {rid, video_ctx} <- v do
            output_id = if rid == nil, do: stream_id, else: "#{stream_id}_#{rid}"
            output_file = Path.join(output_path, "#{output_id}.webm")
            output_file |> Path.dirname() |> File.mkdir_p!()
            {output_id, process!(video_ctx, a[nil], output_file, thumbnails_ctx, reencode_ctx)}
          end
      end
    end)
    |> Map.new()
  end

  defp process!(video_ctx, audio_ctx, output_file, thumbnails_ctx, reencode_ctx) do
    video_stream = if video_ctx, do: make_stream(self(), :video)
    audio_stream = if audio_ctx, do: make_stream(self(), :audio)

    # FIXME: Possible RC here: when the pipeline playback starts, the `Stream`s will start sending
    #        `{:demand, kind, self()}` messages to this process.
    #        There's no guarantee we'll start listening for these messages (in `emit_packets/3`) soon enough,
    #        so we may reach a deadlock.
    #        For now, it seems to work just fine, though.
    {:ok, _sup, pid} = Pipeline.start_link(video_stream, audio_stream, output_file)
    Process.monitor(pid)

    emit_packets(pid, video_ctx[:packets] || [], audio_ctx[:packets] || [])

    cond do
      video_ctx != nil and audio_ctx != nil ->
        FFmpeg.combine_audio_video!(
          output_file <> "_video.webm",
          video_ctx.start_time,
          output_file <> "_audio.webm",
          audio_ctx.start_time,
          output_file,
          reencode_ctx
        )

        File.rm!(output_file <> "_video.webm")
        File.rm!(output_file <> "_audio.webm")

      video_ctx != nil ->
        if reencode_ctx,
          do: FFmpeg.reencode_video!(output_file <> "_video.webm", output_file, reencode_ctx),
          else: File.cp!(output_file <> "_video.webm", output_file)

        File.rm!(output_file <> "_video.webm")

      true ->
        File.cp!(output_file <> "_audio.webm", output_file)
        File.rm!(output_file <> "_audio.webm")
    end

    stream_manifest = %{
      location: output_file,
      duration_seconds: FFmpeg.get_duration_in_seconds!(output_file)
    }

    stream_manifest =
      if thumbnails_ctx do
        thumbnail_file = FFmpeg.generate_thumbnail!(output_file, thumbnails_ctx)
        Map.put(stream_manifest, :thumbnail_location, thumbnail_file)
      else
        stream_manifest
      end

    stream_manifest
  end

  #
  # Reading and reordering captured packets

  defp read_packets(file, state, reorder_buffer_size) do
    case read_packet(file) do
      {:ok, rid_idx, recv_time, packet} ->
        packet =
          ExRTP.Packet.add_extension(packet, %ExRTP.Packet.Extension{
            id: 1,
            data: <<recv_time::64>>
          })

        state =
          if state[rid_idx][:packets_in_store] == reorder_buffer_size do
            Map.update!(state, rid_idx, &flush_packet_from_store(&1))
          else
            state
          end

        state = Map.update!(state, rid_idx, &insert_packet_to_store(&1, packet))
        read_packets(file, state, reorder_buffer_size)

      {:error, reason} ->
        Logger.warning("Error decoding RTP packet: #{inspect(reason)}")
        read_packets(file, state, reorder_buffer_size)

      :eof ->
        Map.new(state, fn {rid_idx, %{store: store, acc: acc}} ->
          recent_packets = PacketStore.dump(store)

          packets =
            acc |> Enum.reverse() |> Stream.concat(recent_packets) |> Enum.reject(&is_nil/1)

          {rid_idx, packets}
        end)
    end
  end

  defp read_packet(file) do
    with {:ok, <<rid_idx::8, recv_time::64, packet_size::32>>} <- read_exactly_n_bytes(file, 13),
         {:ok, packet_data} <- read_exactly_n_bytes(file, packet_size),
         {:ok, packet} <- ExRTP.Packet.decode(packet_data) do
      {:ok, rid_idx, recv_time, packet}
    end
  end

  defp read_exactly_n_bytes(file, byte_cnt) do
    with data when is_binary(data) <- IO.binread(file, byte_cnt),
         true <- byte_cnt == byte_size(data) do
      {:ok, data}
    else
      :eof -> :eof
      false -> {:error, :not_enough_data}
      {:error, _reason} = error -> error
    end
  end

  defp insert_packet_to_store(%{store: store, packets_in_store: n} = layer_state, packet) do
    case PacketStore.insert(store, packet) do
      {:ok, store} ->
        %{layer_state | store: store, packets_in_store: n + 1}

      {:error, :late_packet} ->
        Logger.warning("Decoded late RTP packet")
        layer_state
    end
  end

  defp flush_packet_from_store(%{store: store, packets_in_store: n, acc: acc} = layer_state) do
    {entry, store} = PacketStore.flush_one(store)
    packet = if is_nil(entry), do: nil, else: entry.packet

    %{layer_state | store: store, packets_in_store: n - 1, acc: [packet | acc]}
  end

  #
  # Extracting track metadata

  defp get_video_track_contexts(rid_map, packets) do
    for {rid, rid_idx} <- rid_map, into: %{} do
      {:ok, depayloader} = Depayloader.new(@video_codec_params)

      start_time = get_start_time(packets[rid_idx], depayloader)

      video_ctx = %{
        packets: packets[rid_idx],
        start_time: start_time
      }

      {rid, video_ctx}
    end
  end

  defp get_audio_track_context(%{0 => packets}) do
    {:ok, depayloader} = Depayloader.new(@audio_codec_params)

    start_time = get_start_time(packets, depayloader)

    %{nil: %{packets: packets, start_time: start_time}}
  end

  # Returns the timestamp (in milliseconds) at which the first frame was received
  defp get_start_time([packet | rest], depayloader) do
    case Depayloader.depayload(depayloader, packet) do
      {nil, depayloader} ->
        get_start_time(rest, depayloader)

      {_frame, _depayloader} ->
        {:ok, %ExRTP.Packet.Extension{id: 1, data: <<recv_time::64>>}} =
          ExRTP.Packet.fetch_extension(packet, 1)

        recv_time
    end
  end

  #
  # Passing packets to the `Pipeline` process

  defp make_stream(pid, kind) do
    Stream.resource(
      fn -> pid end,
      fn pid ->
        send(pid, {:demand, kind, self()})

        receive do
          {^kind, nil} ->
            {:halt, pid}

          {^kind, packet} ->
            {[packet], pid}
        end
      end,
      fn _pid -> :ok end
    )
  end

  defp emit_packets(pipeline_pid, video_packets, audio_packets) do
    receive do
      {:demand, :video, pid} ->
        {p, video_packets} = List.pop_at(video_packets, 0)
        send(pid, {:video, p})
        emit_packets(pipeline_pid, video_packets, audio_packets)

      {:demand, :audio, pid} ->
        {p, audio_packets} = List.pop_at(audio_packets, 0)
        send(pid, {:audio, p})
        emit_packets(pipeline_pid, video_packets, audio_packets)

      {:DOWN, _monitor, :process, ^pipeline_pid, _reason} ->
        :ok
    end
  end

  #
  # Uploading output files

  defp maybe_upload_result!(output_manifest, nil) do
    output_manifest
  end

  defp maybe_upload_result!(output_manifest, upload_handler) do
    {ref, upload_handler} =
      output_manifest
      |> __MODULE__.Manifest.to_upload_handler_manifest()
      |> then(&S3.UploadHandler.spawn_task(upload_handler, &1))

    # FIXME: Add descriptive errors
    {:ok, upload_handler_result_manifest, _handler} =
      receive do
        {^ref, _res} = task_result ->
          S3.UploadHandler.process_result(upload_handler, task_result)
      end

    # UploadHandler spawns a task that gets auto-monitored
    # We don't want to propagate this message
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    end

    upload_handler_result_manifest
    |> __MODULE__.Manifest.from_upload_handler_manifest(output_manifest)
  end

  #
  # Helpers

  defp filter_rids(rid_map, rid_allowed?) do
    Map.filter(rid_map, fn {rid, _rid_idx} -> rid_allowed?.(rid) end)
  end
end
