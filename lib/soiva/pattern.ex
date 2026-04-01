defmodule Soiva.Pattern do
  @moduledoc """
  Per-pattern GenServer. Each named pattern runs independently,
  subscribing to the global clock and advancing through its events
  using its configured time function.
  """

  use GenServer

  alias Soiva.{Event, OSC, Playability, Time}

  defstruct [
    :name,
    events: [],
    time_fn: &Time.linear/2,
    time_spec: :linear,
    synth: :default,
    human: 0.0,
    swing: 0.5,
    tick: 0,
    paused: false,
    sync_to: nil,
    follow: nil,
    node_ids: []
  ]

  # Client API

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via(name))
  end

  def stop_pattern(name) do
    case Registry.lookup(Soiva.PatternRegistry, name) do
      [{pid, _}] ->
        GenServer.stop(pid, :normal)
        Soiva.Clock.unsubscribe(name)
      [] -> :ok
    end
  end

  def pause(name), do: call(name, :pause)
  def resume(name), do: call(name, :resume)

  def morph(name, changes), do: call(name, {:morph, changes})

  def get_events(name), do: call(name, :get_events)

  def get_info(name), do: call(name, :get_info)

  defp call(name, msg) do
    case Registry.lookup(Soiva.PatternRegistry, name) do
      [{pid, _}] -> GenServer.call(pid, msg)
      [] -> {:error, :not_found}
    end
  end

  defp via(name), do: {:via, Registry, {Soiva.PatternRegistry, name}}

  # GenServer callbacks

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    events = Keyword.get(opts, :events, [])
    synth = Keyword.get(opts, :synth, :default)
    time_spec = Keyword.get(opts, :time, :linear)
    human = Keyword.get(opts, :human, 0.0)

    time_fn = Time.resolve(time_spec)

    state = %__MODULE__{
      name: name,
      events: events,
      time_fn: time_fn,
      time_spec: time_spec,
      synth: synth,
      human: human
    }

    Soiva.Clock.subscribe(name, self())
    {:ok, state}
  end

  @impl true
  def handle_call(:pause, _from, state), do: {:reply, :ok, %{state | paused: true}}
  def handle_call(:resume, _from, state), do: {:reply, :ok, %{state | paused: false}}

  def handle_call(:get_events, _from, state), do: {:reply, state.events, state}

  def handle_call(:get_info, _from, state) do
    info = %{
      name: state.name,
      synth: state.synth,
      time_spec: state.time_spec,
      paused: state.paused,
      tick: state.tick,
      event_count: length(state.events)
    }

    {:reply, info, state}
  end

  def handle_call({:morph, changes}, _from, state) do
    state =
      Enum.reduce(changes, state, fn
        {:pattern, events}, s ->
          parsed = Soiva.Parser.parse(events, [])
          %{s | events: parsed, tick: 0}

        {:pattern_events, events}, s ->
          %{s | events: events, tick: 0}

        {:time, time_spec}, s ->
          %{s | time_fn: Time.resolve(time_spec), time_spec: time_spec}

        {:synth, synth}, s ->
          %{s | synth: synth}

        {:human, level}, s ->
          %{s | human: level}

        {:amp, amp}, s ->
          events = Enum.map(s.events, fn
            e when is_list(e) -> Enum.map(e, &%{&1 | amp: amp})
            e -> %{e | amp: amp}
          end)
          %{s | events: events}

        {:sync_to, target}, s ->
          %{s | sync_to: target}

        {:follow, target}, s ->
          %{s | follow: target}

        _, s -> s
      end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:tick, clock_tick, clock_swing}, state) do
    if state.paused or length(state.events) == 0 do
      {:noreply, state}
    else
      # Only trigger on quarter-note boundaries (every 4 ticks at 16th resolution)
      if rem(clock_tick, 4) == 0 do
        len = length(state.events)
        step = state.time_fn.(state.tick, len)
        step = max(0, min(step, len - 1))
        event_or_chord = Enum.at(state.events, step)

        state = trigger(event_or_chord, state, clock_swing)
        {:noreply, %{state | tick: state.tick + 1}}
      else
        {:noreply, state}
      end
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Free all active nodes
    for node_id <- state.node_ids do
      OSC.n_free(node_id)
    end
    :ok
  end

  # Internal

  defp trigger(events, state, swing) when is_list(events) do
    # chord — trigger all simultaneously
    Enum.reduce(events, state, fn event, acc ->
      trigger_single(event, acc, swing)
    end)
  end

  defp trigger(event, state, swing) do
    trigger_single(event, state, swing)
  end

  defp trigger_single(%Event{rest: true}, state, _swing), do: state

  defp trigger_single(%Event{} = event, state, clock_swing) do
    event = %{event | synth: state.synth}
    event = Playability.apply_swing(event, clock_swing)
    event = Playability.humanize(event, state.human)

    node_id = OSC.next_node_id()

    params = [
      freq: midi_to_freq(event.pitch),
      amp: event.amp,
      pan: event.pan,
      attack: event.attack,
      release: event.release
    ] ++ Map.to_list(event.params)

    synth_name = Atom.to_string(event.synth)
    OSC.s_new(synth_name, node_id, 0, 1, params)

    %{state | node_ids: [node_id | Enum.take(state.node_ids, 49)]}
  end

  defp midi_to_freq(nil), do: 440.0
  defp midi_to_freq(midi), do: 440.0 * :math.pow(2, (midi - 69) / 12)
end
