defmodule Soiva.Event do
  @moduledoc """
  Core data structure for all musical events in Soiva.
  Every notation style resolves to this struct before reaching the time engine.
  """

  defstruct [
    # core
    pitch: 60,
    dur: 1.0,
    amp: 0.8,
    rest: false,

    # synth
    synth: :default,
    pan: 0.0,
    attack: 0.01,
    release: 0.5,

    # time
    beat: 0,
    offset: 0.0,

    # open params
    params: %{}
  ]
end
