defmodule Soiva.OSC do
  @moduledoc """
  OSC/UDP sender for communicating with scsynth.
  Implements the OSC binary protocol directly using `:gen_udp`.
  """

  use GenServer

  @scsynth_host ~c"127.0.0.1"
  @scsynth_port 57110

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Send /s_new to trigger a SynthDef on scsynth."
  def s_new(synth_name, node_id, add_action \\ 0, target \\ 1, params \\ []) do
    args = [synth_name, node_id, add_action, target] ++ flatten_params(params)
    send_msg("/s_new", args)
  end

  @doc "Send /n_set to update a running node's parameters."
  def n_set(node_id, params) do
    args = [node_id] ++ flatten_params(params)
    send_msg("/n_set", args)
  end

  @doc "Send /n_free to free a node."
  def n_free(node_id) do
    send_msg("/n_free", [node_id])
  end

  @doc "Send /d_recv to load a SynthDef binary."
  def d_recv(synthdef_data) do
    send_msg("/d_recv", [synthdef_data])
  end

  @doc "Send /notify to register for server notifications."
  def notify(on \\ 1) do
    send_msg("/notify", [on])
  end

  @doc "Send /status to check if scsynth is alive."
  def status do
    send_msg("/status", [])
  end

  @doc "Check if scsynth is reachable."
  def ping do
    GenServer.call(__MODULE__, :ping, 2000)
  catch
    :exit, _ -> false
  end

  def send_msg(address, args) do
    GenServer.cast(__MODULE__, {:send, address, args})
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: true])
    {:ok, %{socket: socket, node_id: 1000}}
  end

  @impl true
  def handle_cast({:send, address, args}, state) do
    packet = encode_message(address, args)
    :gen_udp.send(state.socket, @scsynth_host, @scsynth_port, packet)
    {:noreply, state}
  end

  @doc "Get a unique node ID for scsynth."
  def next_node_id do
    GenServer.call(__MODULE__, :next_node_id)
  end

  @impl true
  def handle_call(:ping, from, state) do
    packet = encode_message("/status", [])
    :gen_udp.send(state.socket, @scsynth_host, @scsynth_port, packet)
    {:noreply, Map.put(state, :ping_from, from), 1000}
  end

  def handle_call(:next_node_id, _from, state) do
    id = state.node_id
    {:reply, id, %{state | node_id: id + 1}}
  end

  @impl true
  def handle_info({:udp, _socket, _ip, _port, _data}, %{ping_from: from} = state) when not is_nil(from) do
    GenServer.reply(from, true)
    {:noreply, Map.delete(state, :ping_from)}
  end

  def handle_info({:udp, _socket, _ip, _port, _data}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:timeout, %{ping_from: from} = state) when not is_nil(from) do
    GenServer.reply(from, false)
    {:noreply, Map.delete(state, :ping_from)}
  end

  def handle_info(:timeout, state), do: {:noreply, state}

  # OSC binary encoding

  defp encode_message(address, args) do
    addr_bin = encode_string(address)
    {type_tag, args_bin} = encode_args(args)
    type_bin = encode_string("," <> type_tag)
    addr_bin <> type_bin <> args_bin
  end

  defp encode_args(args) do
    {tags, bins} =
      Enum.map(args, fn
        i when is_integer(i) -> {"i", <<i::signed-big-32>>}
        f when is_float(f) -> {"f", <<f::float-big-32>>}
        s when is_binary(s) and byte_size(s) > 256 -> {"b", encode_blob(s)}
        s when is_binary(s) -> {"s", encode_string(s)}
        a when is_atom(a) -> {"s", encode_string(Atom.to_string(a))}
      end)
      |> Enum.unzip()

    {Enum.join(tags), IO.iodata_to_binary(bins)}
  end

  defp encode_string(s) do
    bin = s <> <<0>>
    pad_len = pad_to_4(byte_size(bin))
    bin <> <<0::size(pad_len * 8)>>
  end

  defp encode_blob(data) do
    size = byte_size(data)
    pad_len = pad_to_4(size)
    <<size::big-32>> <> data <> <<0::size(pad_len * 8)>>
  end

  defp pad_to_4(len) do
    case rem(len, 4) do
      0 -> 0
      r -> 4 - r
    end
  end

  defp flatten_params(params) do
    Enum.flat_map(params, fn
      {k, v} when is_atom(k) -> [Atom.to_string(k), v]
      {k, v} when is_binary(k) -> [k, v]
    end)
  end
end
