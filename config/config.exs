import Config

config :jx, ecto_repos: [JX.Repo]

config :jx, JX.Jido,
  max_tasks: 200,
  agent_pools: []

config :jx,
       :monitor_event_dispatch,
       {JX.Jido.SignalDispatch.Orchestrator, [delivery_mode: :async]}

notification_sinks =
  case System.get_env("JX_NOTIFICATION_FILE") do
    nil -> [JX.Notifications.ConsoleSink]
    "" -> [JX.Notifications.ConsoleSink]
    path -> [JX.Notifications.ConsoleSink, {JX.Notifications.FileSink, [path: path]}]
  end

config :jx, :notification_sinks, notification_sinks

# Continuation playbooks consulted by JX.OrchestratorPlanner. Each module
# must implement JX.OrchestratorPlanner.Playbook. The ExamplePlaybook playbook
# is a project-specific default kept for backwards compatibility; remove it
# (or replace it with your own modules) when adopting jx elsewhere.
config :jx, :planner_playbooks, [JX.OrchestratorPlanner.Playbooks.ExamplePlaybook]

config :jx, :monitor_sensor,
  enabled: false,
  interval_ms: 30_000,
  run_on_start: false,
  opts: []

config :jx, JX.Repo,
  database:
    System.get_env("JX_DB") ||
      Path.expand("~/.jx/jx.db"),
  pool_size: 1,
  log: false

config :jx,
  acpx_binary:
    System.get_env("JX_ACPX_BIN") ||
      "acpx",
  acpx_command:
    System.get_env("JX_ACPX_CMD") ||
      "{{acpx_bin}} --cwd {{worktree_path}} --approve-all --format json --suppress-reads {{agent_name}} exec --file {{prompt_path}}",
  agent_binaries: %{
    "claude" =>
      System.get_env("JX_CLAUDE_BIN") ||
        "claude",
    "opencode" =>
      System.get_env("JX_OPENCODE_BIN") ||
        "opencode",
    "codex" =>
      System.get_env("JX_CODEX_BIN") ||
        "codex",
    "grok" =>
      System.get_env("JX_GROK_BIN") ||
        "scripts/grok"
  },
  agent_commands: %{
    "claude" =>
      System.get_env("JX_CLAUDE_CMD") ||
        "{{agent_bin}} -p --dangerously-skip-permissions < {{prompt_path}}",
    "opencode" =>
      System.get_env("JX_OPENCODE_CMD") ||
        "{{agent_bin}} run --dir {{worktree_path}} --dangerously-skip-permissions \"Read the attached prompt file and complete the task.\" --file {{prompt_path}}",
    "codex" =>
      System.get_env("JX_CODEX_CMD") ||
        "{{agent_bin}} exec --dangerously-bypass-approvals-and-sandbox -C {{worktree_path}} - < {{prompt_path}}",
    "grok" =>
      System.get_env("JX_GROK_CMD") ||
        "{{agent_bin}} --dir {{worktree_path}} --dangerously-skip-permissions --prompt-file {{prompt_path}}"
  }

config :logger, level: :warning

env_config = Path.expand("#{config_env()}.exs", __DIR__)

if File.exists?(env_config) do
  import_config "#{config_env()}.exs"
end
