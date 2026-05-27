defmodule JX.Command do
  @moduledoc """
  Bounded wrapper around `System.cmd/3` for noninteractive external commands.
  """

  @default_timeout_ms 30_000

  def run(command, args, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    cmd_opts = Keyword.delete(opts, :timeout_ms)

    task = Task.async(fn -> System.cmd(command, args, cmd_opts) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        {:ok, result}

      nil ->
        {:error, {:command_timeout, command, args, timeout_ms}}
    end
  end
end
