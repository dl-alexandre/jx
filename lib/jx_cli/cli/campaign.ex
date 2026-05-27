defmodule JX.CLI.Campaign do
  @moduledoc false

  alias JX.Campaigns

  import JX.CLI.Support,
    only: [expect_no_args: 2, print_json: 1, print_table: 2, validate_options: 1]

  @init_usage "jx campaign init <name> --issues <range-or-list> [--parallelism <n>] [--agent-mix <agents>] [--direction asc|desc] [--root <dir>] [--json]"
  @seed_usage "jx campaign seed <name> --from-existing-worktrees [--issues <range-or-list>] [--branch-prefix <prefix>] [--repo-root <dir>] [--root <dir>] [--host-id <id>] [--json]"
  @tick_usage "jx campaign tick <name> [--dry-run|--apply] [--repo <owner/repo>] [--repo-root <dir>] [--root <dir>] [--host-id <id>] [--json]"
  @status_usage "jx campaign status <name> [--root <dir>] [--json]"
  @events_usage "jx campaign events <name> [--root <dir>] [--json]"
  @confirm_usage "jx campaign confirm <name> --message <text> [--slot <n>] [--status <status>] [--root <dir>] [--json]"

  def usage,
    do:
      "#{@init_usage} | #{@seed_usage} | #{@tick_usage} | #{@status_usage} | #{@events_usage} | #{@confirm_usage}"

  def usage_lines,
    do: [@init_usage, @seed_usage, @tick_usage, @status_usage, @events_usage, @confirm_usage]

  def run(["init", name | args], _opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          issues: :string,
          parallelism: :integer,
          agent_mix: :string,
          direction: :string,
          root: :string,
          json: :boolean
        ]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @init_usage),
         :ok <- validate_direction(parsed[:direction]),
         {:ok, state} <-
           Campaigns.init(name,
             issues: parsed[:issues],
             parallelism: parsed[:parallelism],
             agent_mix: parsed[:agent_mix],
             direction: parsed[:direction] || "desc",
             root: parsed[:root]
           ) do
      print_state(state, json: parsed[:json] || false, root: parsed[:root])
      :ok
    end
  end

  def run(["seed", name | args], _opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          from_existing_worktrees: :boolean,
          issues: :string,
          branch_prefix: :string,
          repo_root: :string,
          root: :string,
          host_id: :string,
          json: :boolean
        ]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @seed_usage),
         :ok <- require_flag(parsed[:from_existing_worktrees], @seed_usage),
         {:ok, state} <-
           Campaigns.seed_from_existing_worktrees(name,
             issues: parsed[:issues],
             branch_prefix: parsed[:branch_prefix],
             repo_root: parsed[:repo_root] || File.cwd!(),
             root: parsed[:root],
             host_id: parsed[:host_id]
           ) do
      print_state(state, json: parsed[:json] || false, root: parsed[:root])
      :ok
    end
  end

  def run(["tick", name | args], _opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          dry_run: :boolean,
          apply: :boolean,
          repo: :string,
          repo_root: :string,
          root: :string,
          host_id: :string,
          json: :boolean
        ]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @tick_usage),
         :ok <- validate_tick_mode(parsed),
         {:ok, result} <-
           Campaigns.tick(name,
             apply: parsed[:apply] || false,
             github_repo: parsed[:repo],
             repo_root: parsed[:repo_root] || File.cwd!(),
             root: parsed[:root],
             host_id: parsed[:host_id]
           ) do
      print_tick(result, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["status", name | args], _opts) do
    {parsed, rest, invalid} = OptionParser.parse(args, strict: [root: :string, json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @status_usage),
         {:ok, state} <- Campaigns.status(name, root: parsed[:root]) do
      print_state(state, json: parsed[:json] || false, root: parsed[:root])
      :ok
    end
  end

  def run(["events", name | args], _opts) do
    {parsed, rest, invalid} = OptionParser.parse(args, strict: [root: :string, json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @events_usage),
         {:ok, events} <- Campaigns.events(name, root: parsed[:root]) do
      print_events(events, json: parsed[:json] || false)
      :ok
    end
  end

  def run(["confirm", name | args], _opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [message: :string, slot: :integer, status: :string, root: :string, json: :boolean]
      )

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @confirm_usage),
         {:ok, message} <- require_message(parsed[:message]),
         {:ok, state} <-
           Campaigns.confirm(
             name,
             %{"message" => message, "slot_index" => parsed[:slot], "status" => parsed[:status]},
             root: parsed[:root]
           ) do
      print_state(state, json: parsed[:json] || false, root: parsed[:root])
      :ok
    end
  end

  def run(_args, _opts), do: {:error, "usage: #{usage()}"}

  defp validate_direction(nil), do: :ok
  defp validate_direction(direction) when direction in ["asc", "desc"], do: :ok
  defp validate_direction(_direction), do: {:error, "direction must be asc or desc"}

  defp require_flag(true, _usage), do: :ok
  defp require_flag(_value, usage), do: {:error, "usage: #{usage}"}

  defp validate_tick_mode(opts) do
    if opts[:dry_run] && opts[:apply] do
      {:error, "choose either --dry-run or --apply"}
    else
      :ok
    end
  end

  defp require_message(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: {:error, "missing required --message"}, else: {:ok, value}
  end

  defp require_message(_value), do: {:error, "missing required --message"}

  defp print_state(state, json: true, root: _root), do: print_json(state)

  defp print_state(state, json: false, root: root) do
    IO.puts("campaign: #{state["name"]}")
    IO.puts("state: #{Campaigns.state_path(state["name"], root: root)}")
    IO.puts("issues: #{length(state["issues"] || [])}")
    IO.puts("summary: #{summary_line(state["summary"] || %{})}")
    IO.puts("confirmations: #{length(state["confirmations"] || [])}")

    rows =
      state
      |> Map.get("slots", [])
      |> Enum.map(fn slot ->
        [
          to_string(slot["slot_index"]),
          to_string(slot["issue_number"]),
          slot["agent_kind"] || "",
          slot["status"] || "",
          slot["branch"] || "",
          slot["pr_url"] || "",
          slot["worktree_path"] || ""
        ]
      end)

    if rows == [] do
      IO.puts("slots: none")
    else
      print_table(["slot", "issue", "agent", "status", "branch", "pr", "worktree"], rows)
    end

    print_next_actions(state["next_actions"] || [])
  end

  defp print_tick(result, json: true), do: print_json(result)

  defp print_tick(result, json: false) do
    IO.puts("campaign: #{result["campaign"]}")
    IO.puts("mode: #{result["mode"]}")
    IO.puts("detections: #{length(result["detections"])}")

    Enum.each(
      result["detections"],
      &IO.puts("  PR detected: slot #{&1["slot_index"]} #{&1["branch"]} #{&1["pr_url"]}")
    )

    IO.puts("actions: #{length(result["actions"])}")

    Enum.each(
      result["actions"],
      &IO.puts("  #{&1["action"]}: #{&1["branch"]} #{&1["worktree_path"]}")
    )
  end

  defp print_events(events, json: true), do: print_json(%{"events" => events})

  defp print_events(events, json: false) do
    rows =
      Enum.map(events, fn event ->
        [event["at"] || "", event["type"] || "", Jason.encode!(event["data"] || %{})]
      end)

    if rows == [], do: IO.puts("events: none"), else: print_table(["at", "type", "data"], rows)
  end

  defp print_next_actions([]), do: :ok

  defp print_next_actions(actions) do
    IO.puts("")
    IO.puts("next actions")

    Enum.each(actions, fn action ->
      detail = action["command"] || action["worktree_path"] || action["evidence"] || ""
      IO.puts("  - slot #{action["slot_index"]}: #{action["action"]} #{detail}")
    end)
  end

  defp summary_line(summary) do
    [
      "slots=#{summary["slots_total"] || 0}",
      "prs=#{summary["prs"] || 0}",
      "blocked=#{summary["blocked"] || 0}",
      "ready=#{summary["ready"] || 0}"
    ]
    |> Enum.join(" ")
  end
end
