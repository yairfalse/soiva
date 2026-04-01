defmodule Soiva.Clock do
  @moduledoc """
  Global clock GenServer. Runs at a configurable BPM and notifies
  subscribed patterns on each tick.
  """

  use GenServer

  defstruct bpm: 120, swing: 0.5, tick: 0, subscribers: %{}, timer_ref: nil, running: false

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def set_tempo(bpm, opts \\ []) do
    GenServer.call(__MODULE__, {:set_tempo, bpm, opts})
  end

  def get_tempo, do: GenServer.call(__MODULE__, :get_tempo)

  def subscribe(name, pid) do
    GenServer.call(__MODULE__, {:subscribe, name, pid})
  end

  def unsubscribe(name) do
    GenServer.call(__MODULE__, {:unsubscribe, name})
  end

  def start_clock do
    GenServer.call(__MODULE__, :start_clock)
  end

  def stop_clock do
    GenServer.call(__MODULE__, :stop_clock)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    bpm = Keyword.get(opts, :bpm, 120)
    state = %__MODULE__{bpm: bpm}
    {:ok, state}
  end

  @impl true
  def handle_call({:set_tempo, bpm, opts}, _from, state) do
    swing = Keyword.get(opts, :swing, state.swing)
    state = %{state | bpm: bpm, swing: swing}

    state =
      if state.running do
        cancel_timer(state)
        schedule_tick(state)
      else
        state
      end

    {:reply, :ok, state}
  end

  def handle_call(:get_tempo, _from, state) do
    {:reply, {state.bpm, state.swing}, state}
  end

  def handle_call({:subscribe, name, pid}, _from, state) do
    state = %{state | subscribers: Map.put(state.subscribers, name, pid)}

    state =
      if not state.running and map_size(state.subscribers) > 0 do
        schedule_tick(%{state | running: true})
      else
        state
      end

    {:reply, :ok, state}
  end

  def handle_call({:unsubscribe, name}, _from, state) do
    state = %{state | subscribers: Map.delete(state.subscribers, name)}

    state =
      if state.running and map_size(state.subscribers) == 0 do
        cancel_timer(state)
        %{state | running: false}
      else
        state
      end

    {:reply, :ok, state}
  end

  def handle_call(:start_clock, _from, state) do
    if state.running do
      {:reply, :ok, state}
    else
      {:reply, :ok, schedule_tick(%{state | running: true})}
    end
  end

  def handle_call(:stop_clock, _from, state) do
    state = cancel_timer(state)
    {:reply, :ok, %{state | running: false, tick: 0}}
  end

  @impl true
  def handle_info(:tick, state) do
    # Notify all subscribers
    for {_name, pid} <- state.subscribers do
      send(pid, {:tick, state.tick, state.swing})
    end

    state = %{state | tick: state.tick + 1}
    state = schedule_tick(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Internal

  defp tick_interval_ms(bpm) do
    # Tick at 16th-note resolution: 4 ticks per beat
    round(60_000 / bpm / 4)
  end

  defp schedule_tick(state) do
    interval = tick_interval_ms(state.bpm)
    ref = Process.send_after(self(), :tick, interval)
    %{state | timer_ref: ref}
  end

  defp cancel_timer(%{timer_ref: nil} = state), do: state
  defp cancel_timer(%{timer_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer_ref: nil}
  end
end
