defmodule JX.AgentRunner do
  @moduledoc """
  Resolves and launches configured agent CLIs inside durable tmux sessions.
  """

  alias JX.Shell
  alias JX.Tasks.Task
  alias JX.Tmux

  @agent_names ~w(claude opencode codex grok)
  @agent_transports ~w(native acpx)
  @default_agent_transport "native"

  @default_binaries %{
    "claude" => "claude",
    "opencode" => "opencode",
    "codex" => "codex",
    "grok" => "scripts/grok"
  }

  @default_templates %{
    "claude" => "{{agent_bin}} -p --dangerously-skip-permissions < {{prompt_path}}",
    "opencode" =>
      "{{agent_bin}} run --dir {{worktree_path}} --dangerously-skip-permissions \"Read the attached prompt file and complete the task.\" --file {{prompt_path}}",
    "codex" =>
      "{{agent_bin}} exec --dangerously-bypass-approvals-and-sandbox -C {{worktree_path}} - < {{prompt_path}}",
    "grok" =>
      "{{agent_bin}} --dir {{worktree_path}} --dangerously-skip-permissions --prompt-file {{prompt_path}}"
  }

  @default_codex_goal_template "{{agent_bin}} --enable goals --dangerously-bypass-approvals-and-sandbox --no-alt-screen -C {{worktree_path}}"
  @default_acpx_template "{{acpx_bin}} --cwd {{worktree_path}} --approve-all --format json --suppress-reads {{agent_name}} exec --file {{prompt_path}}"

  def agent_names, do: @agent_names
  def agent_transports, do: @agent_transports
  def default_agent_transport, do: @default_agent_transport

  def command(%Task{} = task), do: command(Map.from_struct(task))

  def command(task) when is_map(task) do
    agent_name = task |> fetch!(:agent_name) |> normalize_agent_name()
    agent_transport = task |> agent_transport() |> normalize_agent_transport()

    task
    |> command_template(agent_name, agent_transport)
    |> render_template(context(task, agent_name, agent_transport))
  end

  def resume_command(%Task{} = task, resume_id),
    do: resume_command(Map.from_struct(task), resume_id)

  def resume_command(task, resume_id) when is_map(task) do
    agent_name = task |> fetch!(:agent_name) |> normalize_agent_name()
    agent_transport = task |> agent_transport() |> normalize_agent_transport()

    case resume_template(agent_name, agent_transport, resume_id) do
      nil -> command(task)
      template -> render_template(template, context(task, agent_name, agent_transport))
    end
  end

  def binary(agent_name) do
    agent_name = normalize_agent_name(agent_name)

    agent_env(agent_name, "BIN") ||
      configured_binary(agent_name) ||
      Map.fetch!(@default_binaries, agent_name)
  end

  def acpx_binary do
    acpx_env("BIN") ||
      Application.get_env(:jx, :acpx_binary) ||
      "acpx"
  end

  def binary_check_script(agent_name) do
    agent_name = normalize_agent_name(agent_name)
    bin = binary(agent_name)
    quoted_bin = Shell.quote(bin)

    """
    bin=#{quoted_bin}
    if command -v "$bin" >/dev/null 2>&1; then
      command -v "$bin"
    elif [ -x "$bin" ]; then
      printf %s "$bin"
    else
      echo "#{agent_name} binary not found: $bin" >&2
      exit 1
    fi
    """
  end

  def acpx_binary_check_script do
    bin = acpx_binary()
    quoted_bin = Shell.quote(bin)

    """
    bin=#{quoted_bin}
    if command -v "$bin" >/dev/null 2>&1; then
      command -v "$bin"
    elif [ -x "$bin" ]; then
      printf %s "$bin"
    else
      echo "acpx binary not found: $bin" >&2
      exit 1
    fi
    """
  end

  def launch_script(%Task{} = task), do: launch_script(Map.from_struct(task))

  def launch_script(task) when is_map(task) do
    launch_command = task |> fetch!(:launch_command) |> empty_to_command(task)
    task_dir = task |> fetch!(:task_dir) |> Shell.quote()
    launch_script = task |> fetch!(:task_dir) |> Path.join("launch.sh") |> Shell.quote()
    launch_marker = task |> fetch!(:task_dir) |> Path.join("launched_at") |> Shell.quote()
    launch_run = task |> fetch!(:task_dir) |> Path.join("launch.run") |> Shell.quote()
    exit_status = task |> fetch!(:task_dir) |> Path.join("exit_status") |> Shell.quote()
    goal_exit_update = goal_exit_update_script(task)

    sent_command =
      "sh #{launch_script}; status=$?; printf %s \"$status\" > #{exit_status}; #{goal_exit_update}; printf '\\n[jx] agent exited %s\\n' \"$status\""

    """
    task_dir=#{task_dir}
    launch_script=#{launch_script}
    launch_marker=#{launch_marker}
    launch_run=#{launch_run}
    target_pane="$session_id:0.0"

    mkdir -p "$task_dir"
    cat > "$launch_script" <<'JX_LAUNCH'
    #!/bin/sh
    set -eu
    cd #{Shell.quote(fetch!(task, :worktree_path))}
    #{launch_command}
    JX_LAUNCH
    chmod +x "$launch_script"

    if [ ! -f "$launch_marker" ]; then
      printf %s #{Shell.quote(launch_command)} > "$launch_run"
      #{Tmux.command()} send-keys -t "$target_pane" #{Shell.quote(sent_command)} C-m
      #{goal_setup_script(task, agent_name(task), agent_transport(task))}
      date -u +%Y-%m-%dT%H:%M:%SZ > "$launch_marker"
    fi
    """
  end

  def goal_status_script(%Task{} = task), do: goal_status_script(Map.from_struct(task))

  def goal_status_script(task) when is_map(task) do
    status_path = task |> fetch!(:task_dir) |> Path.join("goal_status.json") |> Shell.quote()

    """
    if [ -f #{status_path} ]; then
      cat #{status_path}
    else
      printf '{}'
    fi
    """
  end

  defp command_template(task, "codex", "native") do
    if goal_task?(task) do
      agent_env("codex", "GOAL_CMD") ||
        configured_goal_template("codex") ||
        @default_codex_goal_template
    else
      template("native", "codex")
    end
  end

  defp command_template(_task, agent_name, agent_transport),
    do: template(agent_transport, agent_name)

  defp template("native", agent_name) do
    agent_env(agent_name, "CMD") ||
      configured_template(agent_name) ||
      Map.fetch!(@default_templates, agent_name)
  end

  defp template("acpx", _agent_name) do
    acpx_env("CMD") ||
      configured_acpx_template() ||
      @default_acpx_template
  end

  defp resume_template("claude", "native", resume_id) do
    "cd {{resume_cwd}} && {{agent_bin}} --resume #{Shell.quote(resume_id)} -p --dangerously-skip-permissions < {{prompt_path}}"
  end

  defp resume_template(_agent_name, _agent_transport, _resume_id), do: nil

  defp acpx_env(suffix) do
    System.get_env("JX_ACPX_#{suffix}")
  end

  defp agent_env(agent_name, suffix) do
    upcased_agent = String.upcase(agent_name)

    System.get_env("JX_#{upcased_agent}_#{suffix}")
  end

  defp configured_template(agent_name) do
    :jx
    |> Application.get_env(:agent_commands, %{})
    |> Map.get(agent_name)
  end

  defp configured_goal_template(agent_name) do
    :jx
    |> Application.get_env(:agent_goal_commands, %{})
    |> Map.get(agent_name)
  end

  defp configured_binary(agent_name) do
    :jx
    |> Application.get_env(:agent_binaries, %{})
    |> Map.get(agent_name)
  end

  defp configured_acpx_template do
    Application.get_env(:jx, :acpx_command)
  end

  defp context(task, agent_name, agent_transport) do
    %{
      "acpx_bin" => acpx_binary(),
      "agent_bin" =>
        Map.get(task, :agent_bin) || Map.get(task, "agent_bin") || binary(agent_name),
      "agent_name" => agent_name,
      "agent_transport" => agent_transport,
      "task_id" => fetch!(task, :task_id),
      "goal_path" => Path.join(fetch!(task, :task_dir), "goal.md"),
      "prompt_path" => Path.join(fetch!(task, :task_dir), "prompt.md"),
      "worktree_path" => fetch!(task, :worktree_path),
      "resume_cwd" => resume_cwd(task),
      "task_dir" => fetch!(task, :task_dir),
      "log_path" => fetch!(task, :log_path)
    }
  end

  defp resume_cwd(task) do
    case Map.get(task, :resume_cwd) || Map.get(task, "resume_cwd") do
      value when is_binary(value) and value != "" -> value
      _other -> fetch!(task, :worktree_path)
    end
  end

  defp render_template(template, context) do
    Enum.reduce(context, template, fn {key, value}, rendered ->
      String.replace(rendered, "{{#{key}}}", Shell.quote(value))
    end)
  end

  defp empty_to_command("", task), do: command(task)
  defp empty_to_command(nil, task), do: command(task)
  defp empty_to_command(command, _task), do: command

  defp goal_setup_script(task, "codex", "native") do
    if goal_task?(task) do
      goal_path = Path.join(fetch!(task, :task_dir), "goal.md")
      goal_command = "/goal follow the instructions in #{goal_path}"
      goal_status_path = Path.join(fetch!(task, :task_dir), "goal_status.json")
      goal_command_path = Path.join(fetch!(task, :task_dir), "goal_command.txt")

      goal_creation_evidence_path =
        Path.join(fetch!(task, :task_dir), "goal_creation_evidence.txt")

      requested_status =
        Jason.encode!(%{
          status: "requested",
          requested_at: "__JX_GOAL_REQUESTED_AT__",
          objective: Map.get(task, :goal_objective) || Map.get(task, "goal_objective") || "",
          command: goal_command,
          evidence_path: goal_creation_evidence_path
        })

      """
        sleep 1
        goal_requested_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf %s #{Shell.quote(goal_command)} > #{Shell.quote(goal_command_path)}
        printf %s #{Shell.quote(requested_status)} | sed "s/__JX_GOAL_REQUESTED_AT__/$goal_requested_at/" > #{Shell.quote(goal_status_path)}
        #{Tmux.command()} send-keys -t "$target_pane" -l -- #{Shell.quote(goal_command)}
        #{Tmux.command()} send-keys -t "$target_pane" Enter
        sleep 1
        #{Tmux.command()} capture-pane -p -S -80 -t "$target_pane" > #{Shell.quote(goal_creation_evidence_path)} 2>/dev/null || true
      """
    else
      ""
    end
  end

  defp goal_setup_script(_task, _agent_name, _agent_transport), do: ""

  defp goal_exit_update_script(task) do
    if goal_task?(task) do
      status_path = task |> fetch!(:task_dir) |> Path.join("goal_status.json") |> Shell.quote()

      completion_path =
        task |> fetch!(:task_dir) |> Path.join("goal_completion.json") |> Shell.quote()

      """
      if [ -f #{status_path} ]; then
        goal_completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        if [ "$status" -eq 0 ]; then goal_state=completed; else goal_state=failed; fi
        printf '{"status":"%s","completed_at":"%s","exit_status":%s}\\n' "$goal_state" "$goal_completed_at" "$status" > #{completion_path}
        cat #{completion_path} > #{status_path}
      fi
      """
      |> String.replace("\n", " ")
    else
      ""
    end
  end

  defp goal_task?(task) do
    case Map.get(task, :goal_objective) || Map.get(task, "goal_objective") do
      value when is_binary(value) -> String.trim(value) != ""
      _other -> false
    end
  end

  defp normalize_agent_name(agent_name) do
    agent_name = to_string(agent_name)

    if agent_name in @agent_names do
      agent_name
    else
      raise ArgumentError, "unsupported agent #{inspect(agent_name)}"
    end
  end

  defp normalize_agent_transport(nil), do: @default_agent_transport
  defp normalize_agent_transport(""), do: @default_agent_transport

  defp normalize_agent_transport(agent_transport) do
    agent_transport =
      agent_transport
      |> to_string()
      |> String.trim()

    if agent_transport in @agent_transports do
      agent_transport
    else
      raise ArgumentError, "unsupported agent transport #{inspect(agent_transport)}"
    end
  end

  defp agent_transport(task) do
    Map.get(task, :agent_transport) || Map.get(task, "agent_transport") ||
      @default_agent_transport
  end

  defp agent_name(task) do
    task
    |> fetch!(:agent_name)
    |> normalize_agent_name()
  end

  defp fetch!(task, key) do
    Map.get(task, key) || Map.fetch!(task, to_string(key))
  end
end
