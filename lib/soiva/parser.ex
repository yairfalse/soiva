defmodule Soiva.Parser do
  @moduledoc """
  Notation parser — resolves all notation styles to `%Soiva.Event{}` structs.

  Supports: note names (:c4), MIDI integers (60), string notation ("c4:1 eb4:0.5"),
  tuple notation ({:c4, 1.0}), chords ([:c4, :eb4, :g4]), scale degrees, and mixed lists.
  """

  alias Soiva.Event

  @note_names %{
    c: 0, cs: 1, db: 1, d: 2, ds: 3, eb: 3, e: 4, f: 5,
    fs: 6, gb: 6, g: 7, gs: 8, ab: 8, a: 9, as: 10, bb: 10, b: 11
  }

  @doc "Parse a pattern into a list of events (or lists of events for chords)."
  def parse(pattern, opts \\ []) do
    pattern
    |> normalize(opts)
    |> assign_beats()
  end

  defp normalize(pattern, _opts) when is_binary(pattern) do
    pattern
    |> String.split()
    |> Enum.map(&parse_string_token/1)
    |> Enum.map(&to_event/1)
  end

  defp normalize(pattern, opts) when is_list(pattern) do
    Enum.map(pattern, fn
      items when is_list(items) ->
        # chord — simultaneous events
        Enum.map(items, fn item -> to_event(normalize_single(item, opts)) end)

      item ->
        to_event(normalize_single(item, opts))
    end)
  end

  defp normalize(pattern, opts), do: [to_event(normalize_single(pattern, opts))]

  defp normalize_single(:rest, _opts), do: %{rest: true, dur: 1.0}

  defp normalize_single({:rest, dur}, _opts) when is_number(dur), do: %{rest: true, dur: dur}

  defp normalize_single({note, dur}, opts) when is_number(dur) do
    base = normalize_single(note, opts)
    Map.put(base, :dur, dur)
  end

  defp normalize_single(note, _opts) when is_atom(note) do
    case parse_note_atom(note) do
      {:ok, midi} -> %{pitch: midi}
      :error -> %{pitch: 60}
    end
  end

  defp normalize_single(midi, _opts) when is_integer(midi) and midi >= 0 and midi <= 127 do
    %{pitch: midi}
  end

  defp normalize_single(degree, opts) when is_integer(degree) do
    root = Keyword.get(opts, :root, :c)
    scale = Keyword.get(opts, :scale, :minor)
    octave = Keyword.get(opts, :octave, 4)
    midi = degree_to_midi(degree, root, scale, octave)
    %{pitch: midi}
  end

  defp normalize_single(_, _opts), do: %{pitch: 60}

  defp parse_string_token(token) do
    case String.split(token, ":") do
      ["rest"] -> %{rest: true, dur: 1.0}
      ["rest", dur_str] -> %{rest: true, dur: parse_float(dur_str)}
      [note_str] -> %{pitch: parse_note_string(note_str)}
      [note_str, dur_str] -> %{pitch: parse_note_string(note_str), dur: parse_float(dur_str)}
    end
  end

  defp parse_note_string(s) do
    case parse_note_atom(String.to_atom(s)) do
      {:ok, midi} -> midi
      :error -> 60
    end
  end

  defp parse_float(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error ->
        case Integer.parse(s) do
          {i, _} -> i * 1.0
          :error -> 1.0
        end
    end
  end

  @doc "Parse a note atom like :c4, :eb4, :fs3 into a MIDI number."
  def parse_note_atom(atom) do
    s = Atom.to_string(atom)

    cond do
      Regex.match?(~r/^[a-g][sb]?\d$/, s) ->
        {name_part, <<octave_char>>} = String.split_at(s, -1)
        octave = octave_char - ?0
        base = Map.get(@note_names, String.to_atom(name_part), 0)
        {:ok, (octave + 1) * 12 + base}

      true ->
        :error
    end
  end

  defp to_event(map) when is_map(map) do
    if Map.get(map, :rest, false) do
      %Event{rest: true, dur: Map.get(map, :dur, 1.0), pitch: nil}
    else
      %Event{
        pitch: Map.get(map, :pitch, 60),
        dur: Map.get(map, :dur, 1.0)
      }
    end
  end

  defp assign_beats(events) do
    {events, _} =
      Enum.map_reduce(events, 0, fn
        events, beat when is_list(events) ->
          # chord — all events at same beat
          updated = Enum.map(events, &%{&1 | beat: beat})
          dur = (List.first(updated) || %Event{}).dur
          {updated, beat + dur}

        event, beat ->
          {%{event | beat: beat}, beat + event.dur}
      end)

    events
  end

  # Scale degree resolution

  @scales %{
    major: [0, 2, 4, 5, 7, 9, 11],
    minor: [0, 2, 3, 5, 7, 8, 10],
    dorian: [0, 2, 3, 5, 7, 9, 10],
    mixolydian: [0, 2, 4, 5, 7, 9, 10],
    pentatonic: [0, 2, 4, 7, 9],
    blues: [0, 3, 5, 6, 7, 10],
    chromatic: Enum.to_list(0..11),
    whole_tone: [0, 2, 4, 6, 8, 10],
    phrygian: [0, 1, 3, 5, 7, 8, 10],
    lydian: [0, 2, 4, 6, 7, 9, 11],
    locrian: [0, 1, 3, 5, 6, 8, 10],
    harmonic_minor: [0, 2, 3, 5, 7, 8, 11],
    melodic_minor: [0, 2, 3, 5, 7, 9, 11]
  }

  def degree_to_midi(degree, root, scale_name, base_octave \\ 4) do
    intervals = Map.get(@scales, scale_name, @scales.minor)
    len = length(intervals)
    octave_offset = div(degree, len)
    index = rem(degree, len)
    index = if index < 0, do: index + len, else: index

    root_midi =
      case parse_note_atom(:"#{root}0") do
        {:ok, midi} -> midi
        :error -> 0
      end

    root_midi + (base_octave + 1) * 12 - 12 + octave_offset * 12 + Enum.at(intervals, index)
  end

  def scales, do: @scales
end
