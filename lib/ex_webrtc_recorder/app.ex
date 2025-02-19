defmodule ExWebRTC.Recorder.App do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [{Task.Supervisor, name: ExWebRTC.Recorder.TaskSupervisor}]
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
