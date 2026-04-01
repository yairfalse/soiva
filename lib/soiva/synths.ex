defmodule Soiva.Synths do
  @moduledoc """
  SynthDef management — loads SynthDefs into scsynth on boot.
  """

  @doc "Load the default SynthDef into scsynth by executing sclang."
  def load_default do
    scd_path = Path.join(:code.priv_dir(:soiva), "synthdefs/default.scd")

    if File.exists?(scd_path) do
      case find_sclang() do
        {:ok, sclang} ->
          Task.start(fn ->
            System.cmd(sclang, [scd_path], stderr_to_stdout: true)
          end)
          :ok

        :error ->
          IO.puts("[soiva] sclang not found — load SynthDefs manually")
          IO.puts("[soiva] Run in SuperCollider IDE: #{scd_path}")
          :ok
      end
    else
      IO.puts("[soiva] default.scd not found at #{scd_path}")
      :error
    end
  end

  defp find_sclang do
    paths = [
      "/Applications/SuperCollider.app/Contents/MacOS/sclang",
      "/usr/bin/sclang",
      "/usr/local/bin/sclang"
    ]

    case Enum.find(paths, &File.exists?/1) do
      nil ->
        case System.find_executable("sclang") do
          nil -> :error
          path -> {:ok, path}
        end

      path ->
        {:ok, path}
    end
  end
end
