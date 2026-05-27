defmodule Mix.Tasks.Jx.Build do
  @moduledoc """
  Builds the local `./jx` launcher and verifies the supported entrypoints.
  """

  use Mix.Task

  @shortdoc "Builds ./jx and runs smoke checks"

  @impl true
  def run(_args) do
    Mix.Task.run("loadpaths")

    root = File.cwd!()
    Mix.shell().info("building ./jx through bin/jx-build")

    case run_command("bin/jx-build", [], root, [], :infinity) do
      {:ok, _output} -> :ok
      {:error, message} -> Mix.raise(message)
    end
  end

  def run_command(command, args, cwd, env, timeout_ms) do
    task =
      Task.async(fn ->
        System.cmd(command, args,
          cd: cwd,
          env: env,
          stderr_to_stdout: true
        )
      end)

    case await_command(task, timeout_ms) do
      {:ok, {output, 0}} ->
        {:ok, output}

      {:ok, {output, status}} ->
        {:error, "#{command} #{Enum.join(args, " ")} exited #{status}\n#{output}"}

      :timeout ->
        {:error, "#{command} #{Enum.join(args, " ")} timed out after #{timeout_ms}ms"}
    end
  end

  defp await_command(task, :infinity), do: {:ok, Task.await(task, :infinity)}

  defp await_command(task, timeout_ms) do
    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      nil -> :timeout
    end
  end
end
