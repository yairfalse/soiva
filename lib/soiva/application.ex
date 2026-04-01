defmodule Soiva.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Soiva.PatternRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Soiva.PatternSupervisor},
      Soiva.OSC,
      Soiva.Clock
    ]

    opts = [strategy: :one_for_one, name: Soiva.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Boot sequence — check scsynth connection
    Task.start(fn ->
      Process.sleep(500)
      boot()
    end)

    result
  end

  defp boot do
    IO.puts("")
    IO.puts("  ╔═══════════════════════════╗")
    IO.puts("  ║      s o i v a            ║")
    IO.puts("  ║   live coding music       ║")
    IO.puts("  ╚═══════════════════════════╝")
    IO.puts("")

    case Soiva.OSC.ping() do
      true ->
        IO.puts("  [soiva] scsynth connected on 127.0.0.1:57110")
        Soiva.Synths.load_default()
        IO.puts("  [soiva] ready — type `use Soiva` to begin")

      false ->
        IO.puts("  [soiva] scsynth not detected on 127.0.0.1:57110")
        IO.puts("  [soiva] start it with: scsynth -u 57110")
        IO.puts("  [soiva] DSL is available — sounds will play once scsynth is running")
    end

    IO.puts("")
  end
end
