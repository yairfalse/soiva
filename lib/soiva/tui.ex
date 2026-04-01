defmodule Soiva.TUI do
  @moduledoc """
  Terminal UI dashboard for Soiva. Raw ANSI — no external dependencies.

  Shows active patterns, tempo, beat position, and accepts DSL commands.
  Start with `tui()` from the DSL or `mix tui` from the shell.
  Press Ctrl+D to quit and return.
  """

  use GenServer

  @render_interval 150

  defstruct command: "",
            cursor: 0,
            log: [],
            patterns: [],
            bpm: 120,
            swing: 0.5,
            beat: 0,
            history: [],
            history_idx: -1,
            cols: 80,
            rows: 24,
            esc_buf: [],
            stty_backup: nil

  # Public API

  def start do
    {backup, 0} = System.cmd("stty", ["-g"])
    System.cmd("stty", ["raw", "-echo"])
    IO.write("\e[?25l\e[2J\e[H")

    try do
      {:ok, pid} = GenServer.start_link(__MODULE__, %{stty: String.trim(backup)})
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, _, _, _} -> :ok
      end
    after
      System.cmd("stty", [String.trim(backup)])
      IO.write("\e[?25h\e[2J\e[H")
    end
  end

  # GenServer

  @impl true
  def init(%{stty: backup}) do
    {cols, rows} = terminal_size()

    state = %__MODULE__{
      stty_backup: backup,
      cols: cols,
      rows: rows
    }
    |> refresh_state()

    spawn_link(fn -> reader_loop(self()) end)
    :timer.send_interval(@render_interval, :render)
    send(self(), :render)

    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end

  # Keyboard input — bytes from reader process

  @impl true
  # Escape start
  def handle_info({:byte, 27}, state) do
    Process.send_after(self(), :esc_timeout, 80)
    {:noreply, %{state | esc_buf: [27]}}
  end

  # Escape sequence: ESC [
  def handle_info({:byte, ?[}, %{esc_buf: [27]} = state) do
    {:noreply, %{state | esc_buf: [27, ?[]}}
  end

  # Arrow keys
  def handle_info({:byte, ?A}, %{esc_buf: [27, ?[]} = state) do
    {:noreply, %{history_up(state) | esc_buf: []}}
  end

  def handle_info({:byte, ?B}, %{esc_buf: [27, ?[]} = state) do
    {:noreply, %{history_down(state) | esc_buf: []}}
  end

  # Unknown escape sequence — discard
  def handle_info({:byte, _}, %{esc_buf: [27 | _]} = state) do
    {:noreply, %{state | esc_buf: []}}
  end

  # Escape timeout — standalone ESC means quit? No, use Ctrl+D for quit.
  def handle_info(:esc_timeout, %{esc_buf: [27]} = state) do
    {:noreply, %{state | esc_buf: []}}
  end

  def handle_info(:esc_timeout, state), do: {:noreply, state}

  # Ctrl+D — quit
  def handle_info({:byte, 4}, state) do
    {:stop, :normal, state}
  end

  # Enter — execute command
  def handle_info({:byte, 13}, %{command: ""} = state), do: {:noreply, state}

  def handle_info({:byte, 13}, state) do
    {result, output} = eval_command(state.command)
    entries = build_log_entries(state.command, result, output)

    state = %{state |
      log: (entries ++ state.log) |> Enum.take(200),
      history: [state.command | state.history] |> Enum.take(50),
      history_idx: -1,
      command: "",
      cursor: 0
    }
    |> refresh_state()

    {:noreply, state}
  end

  # Backspace
  def handle_info({:byte, byte}, state) when byte in [127, 8] do
    if state.command == "" do
      {:noreply, state}
    else
      cmd = String.slice(state.command, 0..-2//1)
      {:noreply, %{state | command: cmd, cursor: String.length(cmd)}}
    end
  end

  # Printable character
  def handle_info({:byte, byte}, state) when byte >= 32 and byte < 127 do
    cmd = state.command <> <<byte>>
    {:noreply, %{state | command: cmd, cursor: String.length(cmd), history_idx: -1}}
  end

  # Render tick
  def handle_info(:render, state) do
    state = refresh_state(state)
    render(state)
    {:noreply, state}
  end

  # Ignore everything else
  def handle_info(_, state), do: {:noreply, state}

  # Keyboard reader — reads from /dev/tty byte by byte

  defp reader_loop(pid) do
    {:ok, tty} = :file.open(~c"/dev/tty", [:read, :binary, :raw])
    do_read(pid, tty)
  end

  defp do_read(pid, tty) do
    case :file.read(tty, 1) do
      {:ok, <<byte>>} ->
        send(pid, {:byte, byte})
        do_read(pid, tty)

      _ ->
        :file.close(tty)
    end
  end

  # State refresh

  defp refresh_state(state) do
    patterns = get_active_patterns()
    {bpm, swing} = safe_get_tempo()
    beat = beat_position(patterns)

    %{state | patterns: patterns, bpm: bpm, swing: swing, beat: beat}
  end

  defp safe_get_tempo do
    Soiva.Clock.get_tempo()
  catch
    _, _ -> {120, 0.5}
  end

  defp get_active_patterns do
    Registry.select(Soiva.PatternRegistry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.reject(fn {name, _} -> String.starts_with?(Atom.to_string(name), "_evolve_") end)
    |> Enum.map(fn {_name, pid} ->
      try do
        GenServer.call(pid, :get_info, 100)
      catch
        _, _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.name)
  end

  defp beat_position(patterns) do
    case patterns do
      [%{tick: tick} | _] -> rem(tick, 4)
      _ -> 0
    end
  end

  defp get_root do
    :persistent_term.get(:soiva_root, :c)
  rescue
    ArgumentError -> :c
  end

  defp get_scale do
    :persistent_term.get(:soiva_scale, :minor)
  rescue
    ArgumentError -> :minor
  end

  # Rendering

  defp render(state) do
    w = state.cols
    buf = IO.iodata_to_binary([
      "\e[H",  # cursor home
      render_header(state, w),
      render_patterns(state, w),
      render_log(state, w),
      render_input(state, w),
      # Clear any leftover lines below
      "\e[J"
    ])

    IO.write(buf)
  end

  defp render_header(state, w) do
    beat_ind = Enum.map_join(0..3, " ", fn i ->
      if i == state.beat, do: "●", else: "○"
    end)

    title = " soiva "
    inner = "  \e[1;36m♩ #{state.bpm} bpm\e[0m  │  \e[35m#{get_root()} #{get_scale()}\e[0m  │  \e[33m#{beat_ind}\e[0m"

    [
      box_top(title, w),
      box_row(inner, w),
      box_mid(" patterns ", w)
    ]
  end

  defp render_patterns(state, w) do
    if state.patterns == [] do
      [box_row("  \e[90mno patterns playing\e[0m", w)]
    else
      Enum.map(state.patterns, fn p ->
        status = if p.paused, do: "\e[33m‖\e[0m", else: "\e[32m▶\e[0m"
        time_label = format_time_spec(p.time_spec)
        count = p.event_count
        step = if count > 0, do: "#{rem(p.tick, count) + 1}/#{count}", else: "-"

        box_row(
          "  #{status} \e[1m:#{p.name}\e[0m  #{p.synth}  #{time_label}  \e[36mstep #{step}\e[0m",
          w
        )
      end)
    end
  end

  defp render_log(state, w) do
    # Calculate available rows for log
    pattern_rows = max(length(state.patterns), 1)
    # header(3) + patterns + pattern_bottom(1) + log_header(1) + input(3) + bottom(1)
    overhead = 3 + pattern_rows + 1 + 1 + 3
    log_rows = max(state.rows - overhead, 3)

    entries = state.log |> Enum.take(log_rows) |> Enum.reverse()

    [
      box_mid(" log ", w),
      Enum.map(entries, fn entry -> box_row(format_log_entry(entry), w) end),
      # Pad empty rows
      List.duplicate(box_row("", w), max(0, log_rows - length(entries))),
      box_mid("", w)
    ]
  end

  defp render_input(state, w) do
    prompt = "  \e[1;36m>\e[0m #{state.command}\e[36m█\e[0m"

    [
      box_row(prompt, w),
      box_bottom(w)
    ]
  end

  # Box drawing

  defp box_top(title, w) do
    title_len = String.length(title)
    pad = max(w - 2 - title_len, 0)
    "╭#{title}#{String.duplicate("─", pad)}╮\r\n"
  end

  defp box_mid(title, w) do
    title_len = String.length(title)
    pad = max(w - 2 - title_len, 0)
    "├#{title}#{String.duplicate("─", pad)}┤\r\n"
  end

  defp box_bottom(w) do
    "╰#{String.duplicate("─", w - 2)}╯\r\n"
  end

  defp box_row(content, w) do
    # Strip ANSI codes to get visible length
    visible = String.replace(content, ~r/\e\[[0-9;]*m/, "")
    visible_len = String.length(visible)
    pad = max(w - 3 - visible_len, 0)
    "│ #{content}#{String.duplicate(" ", pad)}│\r\n"
  end

  # Log formatting

  defp format_log_entry({:command, text}), do: "\e[36m>\e[0m #{text}"
  defp format_log_entry({:output, text}), do: "\e[32m#{text}\e[0m"
  defp format_log_entry({:error, text}), do: "\e[31m#{text}\e[0m"
  defp format_log_entry({:result, text}), do: "\e[90m=> #{text}\e[0m"

  defp format_time_spec(:linear), do: "linear"
  defp format_time_spec(:reverse), do: "reverse"
  defp format_time_spec(:drunk), do: "drunk"
  defp format_time_spec({:curve, _, _}), do: "curve"
  defp format_time_spec({:prob, _}), do: "prob"
  defp format_time_spec({:skew, dir}), do: "skew:#{dir}"
  defp format_time_spec(other) when is_atom(other), do: Atom.to_string(other)
  defp format_time_spec(_), do: "custom"

  # Command evaluation

  defp eval_command(command) do
    ref = make_ref()
    parent = self()

    spawn(fn ->
      {:ok, io} = StringIO.open("")
      Process.group_leader(self(), io)

      result =
        try do
          {val, _} = Code.eval_string("import Soiva.DSL\n" <> command)
          {:ok, inspect(val)}
        rescue
          e -> {:error, Exception.message(e)}
        catch
          kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
        end

      {_, output} = StringIO.contents(io)
      StringIO.close(io)
      send(parent, {ref, result, String.trim(output)})
    end)

    receive do
      {^ref, result, output} -> {result, output}
    after
      5_000 -> {{:error, "command timed out"}, ""}
    end
  end

  defp build_log_entries(command, result, output) do
    entries = [{:command, command}]

    entries =
      if output != "" do
        output_lines = String.split(output, "\n") |> Enum.map(&{:output, &1})
        entries ++ output_lines
      else
        entries
      end

    case result do
      {:ok, ":ok"} -> entries
      {:ok, val} -> entries ++ [{:result, val}]
      {:error, msg} -> entries ++ [{:error, msg}]
    end
  end

  # History

  defp history_up(%{history: []} = state), do: state

  defp history_up(state) do
    idx = min(state.history_idx + 1, length(state.history) - 1)
    cmd = Enum.at(state.history, idx)
    %{state | command: cmd, cursor: String.length(cmd), history_idx: idx}
  end

  defp history_down(state) do
    if state.history_idx <= 0 do
      %{state | command: "", cursor: 0, history_idx: -1}
    else
      idx = state.history_idx - 1
      cmd = Enum.at(state.history, idx)
      %{state | command: cmd, cursor: String.length(cmd), history_idx: idx}
    end
  end

  # Helpers

  defp terminal_size do
    case System.cmd("stty", ["size"]) do
      {size_str, 0} ->
        [rows, cols] = size_str |> String.trim() |> String.split() |> Enum.map(&String.to_integer/1)
        {cols, rows}

      _ ->
        {80, 24}
    end
  end
end
