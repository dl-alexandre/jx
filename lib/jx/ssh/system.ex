defmodule JX.SSH.System do
  @moduledoc """
  SSH adapter backed by the local `ssh` executable.
  """

  @behaviour JX.SSH

  alias JX.Hosts.Host
  alias JX.Command
  alias JX.Shell
  alias JX.Tmux

  @ssh_options ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
  @default_timeout_ms 30_000

  @impl true
  def run(%Host{} = host, script, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    case Command.run("ssh", ssh_args(host, remote_sh(script)),
           stderr_to_stdout: true,
           timeout_ms: timeout_ms
         ) do
      {:ok, {output, 0}} ->
        {:ok, output}

      {:ok, {output, status}} ->
        {:error, {:ssh_failed, status, output}}

      {:error, {:command_timeout, _command, _args, timeout_ms}} ->
        {:error, {:ssh_timeout, timeout_ms}}
    end
  end

  @impl true
  def attach(%Host{} = host, session_name, opts \\ []) do
    server = Keyword.get(opts, :tmux_server, Tmux.managed_server())

    case System.cmd(
           "ssh",
           ["-tt"] ++
             ssh_args(host, Tmux.attach_command(session_name, server)),
           into: IO.stream(:stdio, :line),
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {_output, status} -> {:error, {:attach_failed, status}}
    end
  end

  @impl true
  def stream_log(%Host{} = host, log_path, opts \\ []) do
    lines = Keyword.get(opts, :lines, 200)
    follow? = Keyword.get(opts, :follow, false)
    flag = if follow?, do: "-f -n", else: "-n"

    script =
      "test -f #{Shell.quote(log_path)} && tail #{flag} #{lines} #{Shell.quote(log_path)} || true"

    case System.cmd(
           "ssh",
           ssh_args(host, remote_sh(script)),
           into: IO.stream(:stdio, :line),
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {_output, status} -> {:error, {:logs_failed, status}}
    end
  end

  defp ssh_args(%Host{} = host, remote_command) do
    @ssh_options ++ ["--", host.ssh_target, remote_command]
  end

  defp remote_sh(script), do: "sh -lc #{Shell.quote(script)}"
end
