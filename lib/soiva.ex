defmodule Soiva do
  @moduledoc """
  Soiva — a BEAM-native live coding environment for music.

  Usage in iex:

      use Soiva

      tempo 120
      play :melody, pattern: [:c4, :e4, :g4, :e4], synth: :default
      stop :melody
  """

  defmacro __using__(_opts) do
    quote do
      import Soiva.DSL
      IO.puts("[soiva] DSL loaded — you're ready to play")
    end
  end
end
