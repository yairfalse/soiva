defmodule Soiva.Playability do
  @moduledoc """
  Playability layer — sits between event building and the time engine.
  Applies humanization, swing, pattern algebra, emotion shortcuts, and randomization.
  """

  alias Soiva.Event

  # Humanization

  @doc "Apply humanization to an event. Level 0.0 = robotic, 1.0 = very loose."
  def humanize(%Event{rest: true} = event, _level), do: event

  def humanize(%Event{} = event, level) when is_number(level) and level > 0 do
    %{event |
      amp: jitter(event.amp, level * 0.1, 0.0, 1.0),
      offset: jitter(event.offset, level * 0.02, -0.1, 0.1),
      dur: jitter(event.dur, level * 0.05, 0.1, 10.0)
    }
  end

  def humanize(event, _level), do: event

  defp jitter(value, range, min_val, max_val) do
    delta = (:rand.uniform() - 0.5) * 2 * range
    (value + delta) |> max(min_val) |> min(max_val)
  end

  # Swing

  @doc "Apply swing to an event based on its beat position. 0.5 = straight, 1.0 = full swing."
  def apply_swing(%Event{rest: true} = event, _swing), do: event

  def apply_swing(%Event{beat: beat} = event, swing) when is_number(swing) do
    if rem(trunc(beat * 2), 2) == 1 do
      # off-beat — push forward
      shift = (swing - 0.5) * 0.5
      %{event | offset: event.offset + shift}
    else
      event
    end
  end

  def apply_swing(event, _), do: event

  # Pattern algebra

  @doc "Reverse a list of events."
  def reverse(events), do: Enum.reverse(events) |> reindex()

  @doc "Stretch durations by a factor."
  def stretch(events, factor) do
    Enum.map(events, fn
      e when is_list(e) -> Enum.map(e, &%{&1 | dur: &1.dur * factor})
      e -> %{e | dur: e.dur * factor}
    end)
    |> reindex()
  end

  @doc "Rotate pattern left by n steps."
  def shift(events, n) do
    len = length(events)
    n = rem(n, len)
    {left, right} = Enum.split(events, n)
    (right ++ left) |> reindex()
  end

  @doc "Play forward then backward."
  def mirror(events) do
    (events ++ Enum.reverse(events)) |> reindex()
  end

  @doc "Randomly replace events with rests at given probability."
  def scatter(events, prob) do
    Enum.map(events, fn
      e when is_list(e) ->
        if :rand.uniform() < prob,
          do: %Event{rest: true, dur: (List.first(e) || %Event{}).dur},
          else: e

      e ->
        if :rand.uniform() < prob,
          do: %Event{rest: true, dur: e.dur},
          else: e
    end)
  end

  # Emotion shortcuts

  @doc "Tense: shorter release, tighter dynamics."
  def tense(events) do
    Enum.map(events, fn
      e when is_list(e) -> Enum.map(e, &do_tense/1)
      e -> do_tense(e)
    end)
  end

  defp do_tense(%Event{rest: true} = e), do: e
  defp do_tense(%Event{} = e) do
    %{e |
      release: max(e.release * 0.5, 0.01),
      amp: min(e.amp * 1.15, 1.0),
      attack: max(e.attack * 0.7, 0.001)
    }
  end

  @doc "Release: longer release, softer dynamics."
  def release_feel(events) do
    Enum.map(events, fn
      e when is_list(e) -> Enum.map(e, &do_release/1)
      e -> do_release(e)
    end)
  end

  defp do_release(%Event{rest: true} = e), do: e
  defp do_release(%Event{} = e) do
    %{e |
      release: e.release * 2.0,
      amp: e.amp * 0.8,
      attack: e.attack * 1.5
    }
  end

  # Randomization

  @doc "Generate a random pattern from a scale."
  def rand_pattern(opts \\ []) do
    alias Soiva.Parser

    scale = Keyword.get(opts, :scale, :minor)
    root = Keyword.get(opts, :root, :c)
    len = Keyword.get(opts, :len, 8)
    octave = Keyword.get(opts, :octave, 4)

    intervals = Map.get(Parser.scales(), scale, [0, 2, 3, 5, 7, 8, 10])
    scale_len = length(intervals)

    for _ <- 1..len do
      degree = :rand.uniform(scale_len * 2) - 1
      midi = Parser.degree_to_midi(degree, root, scale, octave)
      %Event{pitch: midi, dur: Enum.random([0.5, 1.0, 1.0, 2.0])}
    end
    |> reindex()
  end

  # Helpers

  defp reindex(events) do
    {events, _} =
      Enum.map_reduce(events, 0, fn e, beat ->
        case e do
          e when is_list(e) ->
            dur = (List.first(e) || %Event{}).dur
            updated = Enum.map(e, &%{&1 | beat: beat})
            {updated, beat + dur}

          e ->
            {%{e | beat: beat}, beat + e.dur}
        end
      end)

    events
  end
end
