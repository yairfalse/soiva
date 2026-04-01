defmodule SoivaTest do
  use ExUnit.Case

  alias Soiva.{Parser, Event, Playability, Time}

  describe "Parser" do
    test "parses note atoms to MIDI" do
      events = Parser.parse([:c4, :eb4, :g4, :bb4])
      pitches = Enum.map(events, & &1.pitch)
      assert pitches == [60, 63, 67, 70]
    end

    test "parses MIDI integers" do
      events = Parser.parse([60, 63, 67, 70])
      pitches = Enum.map(events, & &1.pitch)
      assert pitches == [60, 63, 67, 70]
    end

    test "parses string notation" do
      events = Parser.parse("c4:1 eb4:0.5 g4:0.5 rest:2")
      assert length(events) == 4
      assert Enum.at(events, 0).pitch == 60
      assert Enum.at(events, 0).dur == 1.0
      assert Enum.at(events, 1).dur == 0.5
      assert Enum.at(events, 3).rest == true
      assert Enum.at(events, 3).dur == 2.0
    end

    test "parses tuple notation" do
      events = Parser.parse([{:c4, 1.0}, {:eb4, 0.5}, {:rest, 2.0}])
      assert Enum.at(events, 0).pitch == 60
      assert Enum.at(events, 0).dur == 1.0
      assert Enum.at(events, 2).rest == true
    end

    test "parses chords as nested lists" do
      events = Parser.parse([[:c4, :eb4, :g4], :rest])
      chord = Enum.at(events, 0)
      assert is_list(chord)
      assert length(chord) == 3
      assert Enum.map(chord, & &1.pitch) == [60, 63, 67]
    end

    test "assigns beats sequentially" do
      events = Parser.parse([{:c4, 1.0}, {:e4, 0.5}, {:g4, 0.5}])
      beats = Enum.map(events, & &1.beat)
      assert beats == [0, 1.0, 1.5]
    end

    test "parses rests" do
      events = Parser.parse([:c4, :rest, :e4])
      assert Enum.at(events, 1).rest == true
      assert Enum.at(events, 1).pitch == nil
    end
  end

  describe "Time" do
    test "linear advances sequentially" do
      assert Time.linear(0, 4) == 0
      assert Time.linear(1, 4) == 1
      assert Time.linear(4, 4) == 0
    end

    test "reverse plays backwards" do
      assert Time.reverse(0, 4) == 3
      assert Time.reverse(1, 4) == 2
      assert Time.reverse(3, 4) == 0
    end

    test "resolve returns functions" do
      f = Time.resolve(:linear)
      assert is_function(f, 2)
      assert f.(0, 4) == 0
    end
  end

  describe "Playability" do
    test "humanize varies amp/offset/dur" do
      event = %Event{pitch: 60, amp: 0.8, offset: 0.0, dur: 1.0}
      # Run many times — at least one should differ
      results = for _ <- 1..20, do: Playability.humanize(event, 0.5)
      amps = Enum.map(results, & &1.amp) |> Enum.uniq()
      assert length(amps) > 1
    end

    test "humanize skips rests" do
      event = %Event{rest: true, dur: 1.0}
      assert Playability.humanize(event, 1.0) == event
    end

    test "reverse reverses events" do
      events = Parser.parse([:c4, :e4, :g4])
      reversed = Playability.reverse(events)
      pitches = Enum.map(reversed, & &1.pitch)
      assert pitches == [67, 64, 60]
    end

    test "stretch doubles durations" do
      events = Parser.parse([:c4, :e4])
      stretched = Playability.stretch(events, 2)
      durs = Enum.map(stretched, & &1.dur)
      assert durs == [2.0, 2.0]
    end

    test "shift rotates pattern" do
      events = Parser.parse([:c4, :e4, :g4])
      shifted = Playability.shift(events, 1)
      pitches = Enum.map(shifted, & &1.pitch)
      assert pitches == [64, 67, 60]
    end
  end
end
