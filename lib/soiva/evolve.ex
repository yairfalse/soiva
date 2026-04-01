defmodule Soiva.Evolve do
  @moduledoc """
  Self-evolving texture engine. Spawns a pattern and a companion process
  that periodically mutates the pattern using its own current state as input.
  Each transformation feeds back on itself — the pattern is always becoming
  something new that remembers where it came from.
  """

  use GenServer

  alias Soiva.{Pattern, Playability, Parser, Event}

  defstruct [
    :name,
    :seed,
    rate: 4_000,
    depth: 0.5,
    generation: 0,
    history: [],
    mutations: []
  ]

  # Client

  def start(name, opts) do
    GenServer.start(__MODULE__, [{:name, name} | opts], name: via(name))
  end

  def stop(name) do
    case Registry.lookup(Soiva.PatternRegistry, :"_evolve_#{name}") do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> :ok
    end

    Pattern.stop_pattern(name)
    Pattern.stop_pattern(:"#{name}_shadow")
    Pattern.stop_pattern(:"#{name}_ghost")
  end

  defp via(name), do: {:via, Registry, {Soiva.PatternRegistry, :"_evolve_#{name}"}}

  # Server

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    seed = Keyword.get(opts, :seed, default_seed())
    rate = Keyword.get(opts, :rate, 4_000)
    depth = Keyword.get(opts, :depth, 0.5)
    synth = Keyword.get(opts, :synth, :default)
    root = Keyword.get(opts, :root, :c)
    scale = Keyword.get(opts, :scale, :minor)

    events = Parser.parse(seed, root: root, scale: scale)

    # Start the main pattern with drunk time — already wandering
    Soiva.DSL.play(name, pattern: seed, synth: synth, time: :drunk, human: 0.3)

    state = %__MODULE__{
      name: name,
      seed: events,
      rate: rate,
      depth: depth,
      generation: 0,
      history: [events],
      mutations: build_mutations(depth)
    }

    schedule_next(rate)
    IO.puts("[soiva] evolve :#{name} — generation 0, depth #{depth}")
    {:ok, state}
  end

  @impl true
  def handle_info(:mutate, state) do
    events = Pattern.get_events(state.name)

    # Pick a mutation strategy based on generation and randomness
    {events, description} = apply_mutation(events, state)

    # Feed the mutated events back into the pattern
    Pattern.morph(state.name, pattern_events: events)

    # Every few generations, spawn or kill shadow layers
    state = maybe_shadow(state, events)

    # Every few generations, shift the time perception
    state = maybe_shift_time(state)

    gen = state.generation + 1
    IO.puts("[soiva] evolve :#{state.name} gen #{gen} — #{description}")

    history = Enum.take([events | state.history], 8)

    schedule_next(jitter_rate(state.rate))
    {:noreply, %{state | generation: gen, history: history}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Pattern.stop_pattern(:"#{state.name}_shadow")
    Pattern.stop_pattern(:"#{state.name}_ghost")
    :ok
  end

  # Mutation engine

  defp apply_mutation(events, state) when is_list(events) and length(events) > 0 do
    gen = state.generation
    r = :rand.uniform()

    cond do
      # Fold: take a past generation and interleave with current
      r < 0.12 and length(state.history) > 1 ->
        past = Enum.random(state.history)
        merged = interleave(events, past)
        {merged, "fold — merged with ancestor"}

      # Scatter: punch holes, let silence breathe
      r < 0.25 ->
        prob = 0.15 + :rand.uniform() * state.depth * 0.3
        {Playability.scatter(events, prob), "scatter #{Float.round(prob, 2)}"}

      # Shift perspective: rotate the pattern
      r < 0.38 ->
        n = :rand.uniform(max(length(events) - 1, 1))
        {Playability.shift(events, n), "shift #{n}"}

      # Mirror: the pattern contemplates itself
      r < 0.48 and length(events) < 24 ->
        {Playability.mirror(events), "mirror — self-reflection"}

      # Pitch drift: nudge notes up or down
      r < 0.62 ->
        drift = Enum.random([-2, -1, 1, 2, 5, 7])
        drifted = pitch_shift(events, drift)
        {drifted, "drift #{if drift > 0, do: "+"}#{drift} semitones"}

      # Tense/release cycle based on generation
      r < 0.72 ->
        if rem(gen, 2) == 0 do
          {Playability.tense(events), "tension"}
        else
          {Playability.release_feel(events), "release"}
        end

      # Fractal split: take a fragment and repeat it at different scales
      r < 0.82 ->
        fragment_len = max(div(length(events), 3), 2)
        start = :rand.uniform(max(length(events) - fragment_len, 1)) - 1
        fragment = Enum.slice(events, start, fragment_len)
        stretched = Playability.stretch(fragment, 0.5)
        result = (events ++ stretched) |> Enum.take(16)
        {reindex(result), "fractal — fragment at half speed"}

      # Reverse: time flows backward
      r < 0.90 ->
        {Playability.reverse(events), "reverse time"}

      # Rebirth: generate entirely new material from the scale, but keep the rhythm
      true ->
        rhythms = Enum.map(events, fn
          e when is_list(e) -> (List.first(e) || %Event{}).dur
          e -> e.dur
        end)
        new = Playability.rand_pattern(len: length(events))
        reborn = Enum.zip(new, rhythms) |> Enum.map(fn {e, dur} -> %{e | dur: dur} end)
        {reindex(reborn), "rebirth — new pitches, old rhythm"}
    end
  end

  defp apply_mutation(events, _state), do: {events, "waiting"}

  # Shadow layers — ghostly echoes of the pattern

  defp maybe_shadow(state, events) do
    gen = state.generation
    name = state.name

    cond do
      # Every 5th generation, spawn a shadow (pitch-shifted, quieter)
      rem(gen, 5) == 4 and gen > 0 ->
        shadow_events = events
          |> pitch_shift(Enum.random([7, 12, -12, 5]))
          |> Enum.map(fn
            e when is_list(e) -> Enum.map(e, &%{&1 | amp: &1.amp * 0.3, release: &1.release * 2})
            e -> %{e | amp: e.amp * 0.3, release: e.release * 2}
          end)

        shadow_name = :"#{name}_shadow"
        Pattern.stop_pattern(shadow_name)
        Process.sleep(50)
        try do
          DynamicSupervisor.start_child(
            Soiva.PatternSupervisor,
            {Soiva.Pattern, name: shadow_name, events: shadow_events, synth: :default, time: :drunk, human: 0.5}
          )
          IO.puts("[soiva] evolve :#{name} — shadow layer born")
        rescue
          _ -> :ok
        end
        state

      # Every 8th generation, kill the shadow
      rem(gen, 8) == 7 ->
        Pattern.stop_pattern(:"#{name}_shadow")
        IO.puts("[soiva] evolve :#{name} — shadow layer dissolved")
        state

      true -> state
    end
  end

  # Time perception shifts

  defp maybe_shift_time(state) do
    if rem(state.generation, 4) == 3 do
      time = Enum.random([:drunk, :linear, :reverse,
        {:prob, [advance: 0.5, repeat: 0.3, skip: 0.2]},
        {:curve, :sine, [period: Enum.random([4, 6, 8, 12])]}
      ])
      Pattern.morph(state.name, time: time)
      state
    else
      state
    end
  end

  # Helpers

  defp interleave(a, b) do
    max_len = min(length(a) + length(b), 16)
    Enum.zip(Stream.cycle(a), Stream.cycle(b))
    |> Enum.take(max_len)
    |> Enum.flat_map(fn {x, y} ->
      if :rand.uniform() < 0.5, do: [x], else: [y]
    end)
    |> reindex()
  end

  defp pitch_shift(events, semitones) do
    Enum.map(events, fn
      e when is_list(e) ->
        Enum.map(e, fn ev ->
          if ev.rest, do: ev, else: %{ev | pitch: clamp_pitch(ev.pitch + semitones)}
        end)
      e ->
        if e.rest, do: e, else: %{e | pitch: clamp_pitch(e.pitch + semitones)}
    end)
  end

  defp clamp_pitch(p), do: max(24, min(108, p))

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

  defp default_seed do
    [:c4, :eb4, :g4, :bb4, :c5, :g4, :eb4, :d4]
  end

  defp build_mutations(depth) do
    base = [:scatter, :shift, :reverse, :drift, :tense_release]
    if depth > 0.5, do: base ++ [:mirror, :fractal, :fold, :rebirth], else: base
  end

  defp schedule_next(ms) do
    Process.send_after(self(), :mutate, ms)
  end

  defp jitter_rate(rate) do
    # +-30% jitter so mutations don't feel mechanical
    jitter = rate * 0.3
    round(rate + (:rand.uniform() - 0.5) * 2 * jitter)
  end
end
