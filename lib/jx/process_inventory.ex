defmodule JX.ProcessInventory do
  @moduledoc """
  Read-only local process inventory for live agent and SSH sessions.
  """

  alias JX.Command
  alias JX.Redaction

  @known_kinds ~w(codex claude opencode ssh sshd tmux)
  @default_timeout_ms 5_000

  def known_kinds, do: @known_kinds
  def ps_script, do: "ps -axo pid,ppid,stat,tty,command"

  def list(opts \\ []) do
    kinds = Keyword.get(opts, :kinds, @known_kinds)
    all? = Keyword.get(opts, :all, false)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    case Command.run("ps", ["-axo", "pid,ppid,stat,tty,command"],
           stderr_to_stdout: true,
           timeout_ms: timeout_ms
         ) do
      {:ok, {output, 0}} ->
        {:ok, output |> parse_ps_output() |> filter(kinds: kinds, all: all?)}

      {:ok, {output, status}} ->
        {:error, {:process_inventory_failed, status, output}}

      {:error, {:command_timeout, _command, _args, timeout_ms}} ->
        {:error, {:process_inventory_timeout, timeout_ms}}
    end
  end

  def filter(processes, opts \\ []) do
    kinds = Keyword.get(opts, :kinds, @known_kinds)
    all? = Keyword.get(opts, :all, false)

    processes
    |> Enum.filter(&(all? || &1.tty != "??" || Map.get(&1, :resume_available, false)))
    |> Enum.filter(&(&1.kind in kinds))
  end

  def parse_ps_output(output) do
    rows = parse_ps_rows(output)
    rows_by_pid = Map.new(rows, &{&1.pid, &1})

    rows
    |> Enum.filter(& &1.kind)
    |> Enum.map(&public_process(&1, rows_by_pid))
  end

  def resume_id_from_ps(output, pid) do
    output
    |> parse_ps_rows()
    |> Enum.find(&(&1.pid == pid))
    |> case do
      nil -> {:error, :process_not_found}
      row -> resume_id(row.raw_command)
    end
  end

  defp parse_ps_rows(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.flat_map(&parse_ps_row/1)
  end

  defp parse_ps_row(line) do
    case Regex.run(~r/^\s*(\d+)\s+(\d+)\s+(\S+)\s+(\S+)\s+(.*)$/, line) do
      [_line, pid, ppid, stat, tty, command] ->
        [
          %{
            kind: classify(command),
            pid: parse_integer(pid),
            ppid: parse_integer(ppid),
            stat: stat,
            tty: tty,
            raw_command: command,
            zed_workspace: zed_workspace(command)
          }
        ]

      _no_match ->
        []
    end
  end

  defp public_process(row, rows_by_pid) do
    kind = row.kind
    resume_id = resume_id(row.raw_command)

    %{
      kind: kind,
      role: role(row.raw_command, kind),
      resume_available: match?({:ok, _id}, resume_id),
      resume_ref: resume_ref(resume_id),
      zed_workspace: inherited_zed_workspace(row, rows_by_pid),
      pid: row.pid,
      ppid: row.ppid,
      stat: row.stat,
      tty: row.tty,
      command: Redaction.redact_command(row.raw_command)
    }
  end

  def role(command, kind) do
    command = String.trim(command)
    downcased = String.downcase(command)
    executable = command |> String.split(~r/\s+/, parts: 2) |> hd()
    basename = executable |> Path.basename() |> String.downcase()

    cond do
      desktop_root?(command) -> "desktop"
      agent_acp?(downcased) -> "acp"
      agent_mcp?(downcased) -> "mcp"
      agent_remote_bridge?(downcased) -> "remote-bridge"
      agent_language_server?(downcased) -> "language-server"
      agent_helper?(downcased) -> "helper"
      agent_server?(basename, downcased) -> "server"
      agent_cli?(basename, downcased, kind) -> "cli"
      kind in ["codex", "claude", "opencode"] -> "cli"
      true -> "process"
    end
  end

  defp classify(command) do
    command = String.trim(command)
    downcased = String.downcase(command)
    executable = command |> String.split(~r/\s+/, parts: 2) |> hd()
    basename = Path.basename(executable)
    downcased_basename = String.downcase(basename)
    downcased_executable = String.downcase(executable)

    cond do
      codex_command?(downcased_executable, downcased) -> "codex"
      claude_command?(downcased_executable, downcased) -> "claude"
      opencode_command?(downcased_executable, downcased) -> "opencode"
      String.starts_with?(downcased_basename, "sshd") -> "sshd"
      downcased_basename in ["ssh", "sshs"] -> "ssh"
      downcased_basename == "tmux" -> "tmux"
      true -> nil
    end
  end

  defp desktop_root?(command) do
    Regex.match?(
      ~r{^/Applications/(Codex|Claude)\.app/Contents/MacOS/(Codex|Claude)(\s|$)},
      command
    )
  end

  defp agent_cli?(basename, command, kind) do
    kind in ["codex", "claude", "opencode"] and
      (basename in ["codex", "claude", "opencode", "opencode-cli"] or
         String.contains?(command, "/bin/#{kind}"))
  end

  defp agent_server?(basename, command) do
    (basename == "opencode-cli" and String.contains?(command, " web ")) or
      String.contains?(command, "/codex app-server")
  end

  defp agent_acp?(command) do
    String.contains?(command, "agentclientprotocol") or
      String.contains?(command, "claude-agent-acp") or
      String.contains?(command, "codex-acp") or
      (String.contains?(command, "/zed/") and
         String.contains?(command, "--input-format stream-json"))
  end

  defp agent_mcp?(command) do
    String.contains?(command, " mcp") or String.contains?(command, "mcp-server")
  end

  defp agent_remote_bridge?(command) do
    String.contains?(command, "/.claude/remote/server")
  end

  defp agent_language_server?(command) do
    String.contains?(command, "language-server") or
      String.contains?(command, "elixir-ls") or
      String.contains?(command, "yaml-language-server")
  end

  defp agent_helper?(command) do
    String.contains?(command, "chrome_crashpad_handler") or
      String.contains?(command, "/frameworks/") or
      String.contains?(command, " helper") or
      String.contains?(command, "--type=renderer") or
      String.contains?(command, "--type=gpu-process") or
      String.contains?(command, "--utility-sub-type")
  end

  defp codex_command?(executable, command) do
    String.contains?(executable, "codex") ||
      String.contains?(command, "/bin/codex") ||
      String.contains?(command, "@openai/codex") ||
      String.contains?(command, "/applications/codex.app") ||
      String.contains?(command, "com.openai.codex")
  end

  defp claude_command?(executable, command) do
    String.contains?(executable, "claude") ||
      String.contains?(command, "/bin/claude") ||
      String.contains?(command, "/.local/bin/claude") ||
      String.contains?(command, "/applications/claude.app") ||
      String.contains?(command, "claudefordesktop")
  end

  defp opencode_command?(executable, command) do
    String.contains?(executable, "opencode") ||
      String.contains?(command, "/opencode")
  end

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> nil
    end
  end

  defp resume_id(command) do
    case Regex.run(~r/(?:^|\s)--resume\s+([^\s]+)/, command) do
      [_match, resume_id] -> {:ok, resume_id}
      _no_match -> {:error, :resume_not_found}
    end
  end

  defp resume_ref({:ok, resume_id}), do: "resume-" <> short_hash(resume_id)
  defp resume_ref({:error, _reason}), do: ""

  defp zed_workspace(command) do
    case Regex.run(~r/(workspace[-_][A-Za-z0-9._-]+)/, command) do
      [_match, workspace] -> workspace
      _no_match -> ""
    end
  end

  defp inherited_zed_workspace(row, rows_by_pid) do
    inherited_zed_workspace(row, rows_by_pid, MapSet.new())
  end

  defp inherited_zed_workspace(%{zed_workspace: workspace}, _rows_by_pid, _seen)
       when workspace not in [nil, ""] do
    workspace
  end

  defp inherited_zed_workspace(%{ppid: ppid}, rows_by_pid, seen) when is_integer(ppid) do
    if MapSet.member?(seen, ppid) do
      ""
    else
      case Map.get(rows_by_pid, ppid) do
        nil -> ""
        parent -> inherited_zed_workspace(parent, rows_by_pid, MapSet.put(seen, ppid))
      end
    end
  end

  defp inherited_zed_workspace(_row, _rows_by_pid, _seen), do: ""

  defp short_hash(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 10)
  end
end
