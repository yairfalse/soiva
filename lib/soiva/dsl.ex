defmodule Soiva.DSL do
  @moduledoc """
  Top-level DSL functions for live coding in iex.
  Import with `use Soiva` to bring all functions into scope.
  """

  alias Soiva.{Clock, Evolve, Parser, Pattern, Playability}

  # State for root/scale context
  @default_root :c
  @default_scale :minor

  # Setup

  def tempo(bpm) when is_number(bpm) do
    Clock.set_tempo(bpm)
    IO.puts("[soiva] tempo #{bpm} bpm")
    :ok
  end

  def tempo(bpm, opts) when is_number(bpm) and is_list(opts) do
    Clock.set_tempo(bpm, opts)
    swing = Keyword.get(opts, :swing, 0.5)
    IO.puts("[soiva] tempo #{bpm} bpm, swing #{swing}")
    :ok
  end

  def root(note, opts \\ []) do
    scale = Keyword.get(opts, :scale, @default_scale)
    :persistent_term.put(:soiva_root, note)
    :persistent_term.put(:soiva_scale, scale)
    IO.puts("[soiva] root #{note}, scale #{scale}")
    :ok
  end

  defp current_root, do: safe_get(:soiva_root, @default_root)
  defp current_scale, do: safe_get(:soiva_scale, @default_scale)

  defp safe_get(key, default) do
    :persistent_term.get(key, default)
  rescue
    ArgumentError -> default
  end

  # Play

  def play(name, opts \\ []) when is_atom(name) do
    pattern_input = Keyword.get(opts, :pattern, [])
    synth = Keyword.get(opts, :synth, :default)
    time = Keyword.get(opts, :time, :linear)
    human = Keyword.get(opts, :human, 0.0)

    parse_opts = [root: current_root(), scale: current_scale()]
    events = Parser.parse(pattern_input, parse_opts)

    # Stop existing pattern with this name if any
    Pattern.stop_pattern(name)

    case DynamicSupervisor.start_child(
           Soiva.PatternSupervisor,
           {Pattern, name: name, events: events, synth: synth, time: time, human: human}
         ) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        # Race: supervisor hasn't finished cleanup yet — terminate and retry
        Pattern.stop_pattern(name)
        Process.sleep(50)

        {:ok, _pid} =
          DynamicSupervisor.start_child(
            Soiva.PatternSupervisor,
            {Pattern, name: name, events: events, synth: synth, time: time, human: human}
          )
    end

    IO.puts("[soiva] playing :#{name}")
    :ok
  end

  # High-level texture macros

  def drone(note, opts \\ []) do
    synth = Keyword.get(opts, :synth, :default)
    name = Keyword.get(opts, :name, :drone)

    play(name,
      pattern: [{note, 4.0}],
      synth: synth,
      time: :linear
    )
  end

  def burst(note, opts \\ []) do
    density = Keyword.get(opts, :density, 0.7)
    scatter_prob = Keyword.get(opts, :scatter, 0.4)
    name = Keyword.get(opts, :name, :burst)
    synth = Keyword.get(opts, :synth, :default)

    count = round(density * 16)
    parse_opts = [root: current_root(), scale: current_scale()]

    events =
      List.duplicate(note, count)
      |> Parser.parse(parse_opts)
      |> Enum.map(&%{&1 | dur: 0.25})
      |> Playability.scatter(scatter_prob)

    Pattern.stop_pattern(name)
    Process.sleep(50)

    {:ok, _} =
      DynamicSupervisor.start_child(
        Soiva.PatternSupervisor,
        {Pattern, name: name, events: events, synth: synth, time: :linear, human: 0.3}
      )

    IO.puts("[soiva] burst :#{name}")
    :ok
  end

  def shimmer(notes, opts \\ []) when is_list(notes) do
    rate = Keyword.get(opts, :rate, 0.5)
    name = Keyword.get(opts, :name, :shimmer)
    synth = Keyword.get(opts, :synth, :default)

    parse_opts = [root: current_root(), scale: current_scale()]

    events =
      notes
      |> Enum.map(&{&1, rate})
      |> Parser.parse(parse_opts)

    Pattern.stop_pattern(name)
    Process.sleep(50)

    {:ok, _} =
      DynamicSupervisor.start_child(
        Soiva.PatternSupervisor,
        {Pattern, name: name, events: events, synth: synth, time: :linear, human: 0.2}
      )

    IO.puts("[soiva] shimmer :#{name}")
    :ok
  end

  # Pattern control

  def stop(:all) do
    # Stop all evolve processes first (they're registered in PatternRegistry as _evolve_*)
    Registry.select(Soiva.PatternRegistry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {name, _pid} -> String.starts_with?(Atom.to_string(name), "_evolve_") end)
    |> Enum.each(fn {_name, pid} ->
      try do
        GenServer.stop(pid, :normal)
      catch
        :exit, _ -> :ok
      end
    end)

    DynamicSupervisor.which_children(Soiva.PatternSupervisor)
    |> Enum.each(fn {_, pid, _, _} ->
      DynamicSupervisor.terminate_child(Soiva.PatternSupervisor, pid)
    end)

    IO.puts("[soiva] stopped all patterns")
    :ok
  end

  def stop(name) when is_atom(name) do
    for n <- resolve_group(name) do
      Pattern.stop_pattern(n)
      IO.puts("[soiva] stopped :#{n}")
    end
    :ok
  end

  def pause(name) when is_atom(name) do
    Pattern.pause(name)
    IO.puts("[soiva] paused :#{name}")
    :ok
  end

  def resume(name) when is_atom(name) do
    Pattern.resume(name)
    IO.puts("[soiva] resumed :#{name}")
    :ok
  end

  # Live mutation

  def morph(name, changes) when is_atom(name) and is_list(changes) do
    Pattern.morph(name, changes)
    IO.puts("[soiva] morphed :#{name}")
    :ok
  end

  # Pattern algebra

  def rev(name) when is_atom(name) do
    apply_algebra(name, &Playability.reverse/1, "reversed")
  end

  def stretch(name, factor) when is_atom(name) do
    apply_algebra(name, &Playability.stretch(&1, factor), "stretched x#{factor}")
  end

  def shift(name, n) when is_atom(name) do
    apply_algebra(name, &Playability.shift(&1, n), "shifted by #{n}")
  end

  def mirror(name) when is_atom(name) do
    apply_algebra(name, &Playability.mirror/1, "mirrored")
  end

  def scatter(name, opts \\ []) when is_atom(name) do
    prob = Keyword.get(opts, :prob, 0.3)
    apply_algebra(name, &Playability.scatter(&1, prob), "scattered #{prob}")
  end

  def tense(name) when is_atom(name) do
    apply_algebra(name, &Playability.tense/1, "tensed")
  end

  def release(name) when is_atom(name) do
    apply_algebra(name, &Playability.release_feel/1, "released")
  end

  defp apply_algebra(name, transform_fn, label) do
    case Pattern.get_events(name) do
      {:error, :not_found} ->
        IO.puts("[soiva] pattern :#{name} not found")
        :error

      events ->
        new_events = transform_fn.(events)
        Pattern.morph(name, [{:pattern_events, new_events}])
        IO.puts("[soiva] :#{name} #{label}")
        :ok
    end
  end

  # Groups

  def group(group_name, pattern_names) when is_atom(group_name) and is_list(pattern_names) do
    :persistent_term.put({:soiva_group, group_name}, pattern_names)
    IO.puts("[soiva] group :#{group_name} = #{inspect(pattern_names)}")
    :ok
  end

  defp resolve_group(name) do
    case safe_get({:soiva_group, name}, nil) do
      nil -> [name]
      names -> names
    end
  end

  # Sync

  def sync(name, opts) when is_atom(name) do
    target = Keyword.fetch!(opts, :to)
    Pattern.morph(name, sync_to: target)
    IO.puts("[soiva] :#{name} synced to :#{target}")
    :ok
  end

  def follow(name, target) when is_atom(name) and is_atom(target) do
    Pattern.morph(name, follow: target)
    IO.puts("[soiva] :#{name} follows :#{target}")
    :ok
  end

  # Randomization

  def rand(opts \\ []) do
    Playability.rand_pattern(opts)
  end

  # Evolving textures

  def evolve(name, opts \\ []) when is_atom(name) do
    Evolve.stop(name)
    Process.sleep(50)

    opts = Keyword.merge([
      root: current_root(),
      scale: current_scale()
    ], opts)

    Evolve.start(name, opts)
    :ok
  end

  # Time helpers re-exported for DSL use
  defdelegate curve(shape, opts \\ []), to: Soiva.Time
  defdelegate prob(opts), to: Soiva.Time
  defdelegate skew(direction), to: Soiva.Time
end
