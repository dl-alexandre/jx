defmodule Mix.Tasks.Jx.Smoke do
  @moduledoc """
  Verifies the local launcher and live-source wrapper both start.
  """

  use Mix.Task

  alias Mix.Tasks.Jx.Build

  @shortdoc "Runs jx CLI smoke checks"
  @timeout_ms 30_000

  @checks [
    {"./jx --version", "./jx", ["--version"], []},
    {"./jx help", "./jx", ["help"], []},
    {"JX_USE_MIX=1 bin/jx help", "bin/jx", ["help"], [{"JX_USE_MIX", "1"}]}
  ]

  @impl true
  def run(_args) do
    root = File.cwd!()

    Enum.each(@checks, fn {label, command, args, env} ->
      Mix.shell().info("smoke: #{label}")

      case Build.run_command(command, args, root, env, @timeout_ms) do
        {:ok, output} ->
          validate_output!(label, output)

        {:error, message} ->
          Mix.raise(message)
      end
    end)
  end

  defp validate_output!("./jx --version", output) do
    unless String.contains?(output, "jx ") do
      Mix.raise("./jx --version did not print a jx version\n#{output}")
    end
  end

  defp validate_output!(_label, output) do
    unless String.contains?(output, "jx orchestrates durable SSH/tmux worktree sessions.") do
      Mix.raise("jx help smoke check did not print top-level help\n#{output}")
    end
  end
end
