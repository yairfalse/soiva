defmodule Mix.Tasks.Tui do
  @shortdoc "Start Soiva with the terminal UI"
  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")
    Soiva.TUI.start()
  end
end
