defmodule ExWebRTC.Recorder.Converter.FFmpeg do
  @moduledoc false

  alias ExWebRTC.Recorder.Converter

  # FIXME: When the VM exits, FFmpeg processes started by this module keep running
  #        See https://hexdocs.pm/elixir/1.18.4/Port.html#module-zombie-operating-system-processes
  #        for ideas on tackling this issue

  @spec reencode_video!(Path.t(), Path.t(), Converter.reencode_ctx()) :: Path.t() | no_return()
  def reencode_video!(video_file, output_file, reencode_ctx) do
    {_io, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-nostdin) ++
          input_flags(video_file) ++
          reencode_flags(reencode_ctx) ++
          [output_file],
        stderr_to_stdout: true
      )

    output_file
  end

  @spec combine_audio_video!(
          Path.t(),
          integer(),
          Path.t(),
          integer(),
          Path.t(),
          Converter.reencode_ctx() | nil
        ) :: Path.t() | no_return()
  def combine_audio_video!(
        video_file,
        video_start_timestamp_ms,
        audio_file,
        audio_start_timestamp_ms,
        output_file,
        reencode_ctx \\ nil
      ) do
    {video_start_time, audio_start_time} =
      calculate_start_times(video_start_timestamp_ms, audio_start_timestamp_ms)

    {_io, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-nostdin) ++
          input_flags(video_file, video_start_time) ++
          input_flags(audio_file, audio_start_time) ++
          reencode_flags(reencode_ctx) ++
          ~w(-c:a copy -shortest) ++
          [output_file],
        stderr_to_stdout: true
      )

    output_file
  end

  @spec generate_thumbnail!(Path.t(), Converter.thumbnails_ctx()) :: Path.t() | no_return()
  def generate_thumbnail!(file, thumbnails_ctx) do
    thumbnail_file = "#{file}_thumbnail.jpg"

    {_io, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-nostdin) ++
          input_flags(file) ++
          ~w(-vf thumbnail,#{scale_filter(thumbnails_ctx.resolution)} -frames:v 1) ++
          [thumbnail_file],
        stderr_to_stdout: true
      )

    thumbnail_file
  end

  @spec get_duration_in_seconds!(Path.t()) :: non_neg_integer() | no_return()
  def get_duration_in_seconds!(file) do
    {duration, 0} =
      System.cmd(
        "ffprobe",
        ~w(-v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1) ++
          [file]
      )

    {duration_seconds, _rest} = Float.parse(duration)
    round(duration_seconds)
  end

  defp reencode_flags(nil), do: ~w(-c:v copy)

  defp reencode_flags(%{
         threads: threads,
         crf: crf,
         bitrate: bitrate,
         gop_size: gop_size,
         resolution: resolution,
         cues_to_front: cues_to_front
       }) do
    if(threads == nil, do: ~w(), else: ~w(-threads #{threads})) ++
      ~w(-c:v vp8 -crf #{crf} -b:v #{bitrate} -g #{gop_size}) ++
      if(resolution, do: ~w(-vf #{scale_filter(resolution)}), else: ~w()) ++
      if cues_to_front, do: ~w(-cues_to_front 1), else: ~w()
  end

  defp input_flags(path, start_time \\ nil)
  defp input_flags(path, nil), do: ["-i", path]
  defp input_flags(path, start_time), do: ["-ss", start_time, "-i", path]

  defp scale_filter(%{width: width, height: height}), do: "scale=#{width}:#{height}"

  defp calculate_start_times(video_start_ms, audio_start_ms)
       when is_nil(video_start_ms) or is_nil(audio_start_ms) do
    {"00:00:00.000", "00:00:00.000"}
  end

  defp calculate_start_times(video_start_ms, audio_start_ms) do
    diff = abs(video_start_ms - audio_start_ms)
    millis = rem(diff, 1000)
    seconds = div(diff, 1000) |> rem(60)
    minutes = div(diff, 60_000)

    delayed_start_time =
      :io_lib.format("00:~2..0w:~2..0w.~3..0w", [minutes, seconds, millis]) |> to_string()

    if video_start_ms > audio_start_ms,
      do: {"00:00:00.000", delayed_start_time},
      else: {delayed_start_time, "00:00:00.000"}
  end
end
