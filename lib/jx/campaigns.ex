defmodule JX.Campaigns do
  @moduledoc """
  File-backed campaign orchestration for PR-gated worktree lanes.
  """

  alias JX.Command

  @slot_active_statuses ~w(planned worktree_created agent_working)
  @campaign_version 1
  @default_command_timeout_ms 30_000

  def init(name, opts \\ []) when is_binary(name) do
    state =
      %{
        "version" => @campaign_version,
        "name" => name,
        "created_at" => timestamp(),
        "updated_at" => timestamp(),
        "issues" =>
          issue_sequence(Keyword.get(opts, :issues), Keyword.get(opts, :direction, "desc")),
        "direction" => Keyword.get(opts, :direction, "desc"),
        "parallelism" => Keyword.get(opts, :parallelism),
        "agent_mix" => agent_mix(Keyword.get(opts, :agent_mix)),
        "slots" => [],
        "events" => [],
        "confirmations" => []
      }
      |> enrich_state()

    write_state(state, opts)
    {:ok, state}
  end

  def seed_from_existing_worktrees(name, opts \\ []) when is_binary(name) do
    with {:ok, state} <- load_or_new(name, opts),
         {:ok, worktrees} <- list_worktrees(Keyword.get(opts, :repo_root, File.cwd!())) do
      seeded =
        worktrees
        |> Enum.filter(&campaign_branch?(&1["branch"], state, opts))
        |> Enum.sort_by(fn worktree -> worktree["branch"] end)
        |> Enum.with_index()
        |> Enum.reduce(state, fn {worktree, index}, acc ->
          upsert_seed_slot(acc, worktree, index, opts)
        end)
        |> touch()
        |> add_event("seeded", %{"source" => "existing_worktrees"})
        |> enrich_state()

      write_state(seeded, opts)
      {:ok, seeded}
    end
  end

  def status(name, opts \\ []) when is_binary(name) do
    with {:ok, state} <- load_or_new(name, opts) do
      {:ok, enrich_state(state)}
    end
  end

  def events(name, opts \\ []) when is_binary(name) do
    with {:ok, state} <- load_or_new(name, opts) do
      {:ok, Map.get(state, "events", [])}
    end
  end

  def confirm(name, attrs, opts \\ []) when is_binary(name) and is_map(attrs) do
    with {:ok, state} <- load_or_new(name, opts) do
      confirmation =
        attrs
        |> normalize_confirmation_attrs()
        |> Map.put("at", timestamp())

      state =
        state
        |> Map.update("confirmations", [confirmation], &(&1 ++ [confirmation]))
        |> add_event("confirmed", confirmation)
        |> touch()
        |> enrich_state()

      write_state(state, opts)
      {:ok, state}
    end
  end

  def tick(name, opts \\ []) when is_binary(name) do
    apply? = Keyword.get(opts, :apply, false)

    with {:ok, state} <- load_or_new(name, opts) do
      {detected_state, detections} = detect_slot_prs(state, opts)
      {advanced_state, actions} = advance_detected_slots(detected_state, apply?, opts)
      result_state = touch(advanced_state)

      if apply? do
        write_state(enrich_state(result_state), opts)
      end

      {:ok,
       %{
         "campaign" => name,
         "mode" => if(apply?, do: "apply", else: "dry_run"),
         "detections" => detections,
         "actions" => actions,
         "state" => enrich_state(result_state)
       }}
    end
  end

  def state_path(name, opts \\ []) do
    opts
    |> Keyword.get(:root, File.cwd!())
    |> Path.expand()
    |> then(&Path.join([&1, ".jx", "campaigns", "#{name}.json"]))
  end

  def parse_issues(nil), do: []
  def parse_issues(""), do: []

  def parse_issues(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.flat_map(&parse_issue_part/1)
    |> Enum.uniq()
  end

  def parse_issues(values) when is_list(values),
    do: values |> Enum.map(&to_int/1) |> Enum.reject(&is_nil/1)

  defp load_or_new(name, opts) do
    path = state_path(name, opts)

    cond do
      File.exists?(path) ->
        with {:ok, body} <- File.read(path),
             {:ok, state} <- Jason.decode(body) do
          {:ok, state}
        else
          {:error, reason} -> {:error, {:invalid_campaign_state, path, inspect(reason)}}
        end

      true ->
        {:ok,
         %{
           "version" => @campaign_version,
           "name" => name,
           "created_at" => timestamp(),
           "updated_at" => timestamp(),
           "issues" =>
             issue_sequence(Keyword.get(opts, :issues), Keyword.get(opts, :direction, "desc")),
           "direction" => Keyword.get(opts, :direction, "desc"),
           "slots" => [],
           "events" => [],
           "confirmations" => []
         }}
    end
  end

  defp write_state(state, opts) do
    path = state_path(state["name"], opts)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(enrich_state(state), pretty: true) <> "\n")
    :ok
  end

  defp issue_sequence(issues, "asc"), do: parse_issues(issues) |> Enum.sort()
  defp issue_sequence(issues, _direction), do: parse_issues(issues) |> Enum.sort(:desc)

  defp parse_issue_part(part) do
    case String.split(part, "..", parts: 2) do
      [first, last] ->
        with start when not is_nil(start) <- to_int(first),
             finish when not is_nil(finish) <- to_int(last) do
          if start <= finish,
            do: Enum.to_list(start..finish),
            else: Enum.to_list(start..finish//-1)
        else
          _ -> []
        end

      [one] ->
        case to_int(one) do
          nil -> []
          issue -> [issue]
        end
    end
  end

  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp to_int(_value), do: nil

  defp agent_mix(nil), do: []
  defp agent_mix(value), do: String.split(value, ",", trim: true)

  defp list_worktrees(repo_root) do
    case Command.run("git", ["-C", repo_root, "worktree", "list", "--porcelain"],
           stderr_to_stdout: true,
           timeout_ms: @default_command_timeout_ms
         ) do
      {:ok, {output, 0}} ->
        {:ok, parse_worktrees(output)}

      {:ok, {output, status}} ->
        {:error, {:git_worktree_list_failed, status, String.trim(output)}}

      {:error, {:command_timeout, _command, _args, timeout_ms}} ->
        {:error, {:git_timeout, timeout_ms}}
    end
  end

  defp parse_worktrees(output) do
    output
    |> String.split("\n\n", trim: true)
    |> Enum.map(fn block ->
      block
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, " ", parts: 2) do
          ["worktree", value] -> Map.put(acc, "path", value)
          ["branch", "refs/heads/" <> value] -> Map.put(acc, "branch", value)
          ["branch", value] -> Map.put(acc, "branch", value)
          _ -> acc
        end
      end)
    end)
    |> Enum.filter(&Map.has_key?(&1, "branch"))
  end

  defp campaign_branch?(branch, state, opts) when is_binary(branch) do
    prefix = Keyword.get(opts, :branch_prefix)
    branch_issue = branch_issue(branch)
    issue_set = MapSet.new(Map.get(state, "issues", []))

    prefix_match? = is_nil(prefix) or String.starts_with?(branch, prefix)
    issue_match? = MapSet.size(issue_set) == 0 or MapSet.member?(issue_set, branch_issue)

    prefix_match? and not is_nil(branch_issue) and issue_match?
  end

  defp campaign_branch?(_branch, _state, _opts), do: false

  defp upsert_seed_slot(state, worktree, index, opts) do
    branch = worktree["branch"]
    issue = branch_issue(branch)
    existing = Enum.find(Map.get(state, "slots", []), &(&1["branch"] == branch))
    slot_index = if existing, do: existing["slot_index"], else: next_slot_index(state, index)

    slot =
      Map.merge(existing || %{}, %{
        "slot_index" => slot_index,
        "issue_number" => issue,
        "branch" => branch,
        "worktree_path" => worktree["path"],
        "host_id" => Keyword.get(opts, :host_id) || hostname(),
        "agent_kind" => branch_agent(branch),
        "status" => Map.get(existing || %{}, "status", "agent_working"),
        "seeded_at" => Map.get(existing || %{}, "seeded_at", timestamp())
      })

    Map.update(state, "slots", [slot], fn slots ->
      slots
      |> Enum.reject(&(&1["branch"] == branch or &1["slot_index"] == slot_index))
      |> Kernel.++([slot])
      |> Enum.sort_by(& &1["slot_index"])
    end)
  end

  defp next_slot_index(state, fallback) do
    used =
      state
      |> Map.get("slots", [])
      |> Enum.map(& &1["slot_index"])
      |> Enum.reject(&is_nil/1)

    Stream.iterate(fallback, &(&1 + 1))
    |> Enum.find(&(&1 not in used))
  end

  defp detect_slot_prs(state, opts) do
    state
    |> Map.get("slots", [])
    |> Enum.reduce({state, []}, fn slot, {acc, detections} ->
      if tick_slot?(slot, opts) do
        case detect_pr(slot, opts) do
          {:ok, nil} ->
            {acc, detections}

          {:ok, pr} ->
            updated_slot =
              slot
              |> Map.put("status", "pr_detected")
              |> Map.put("pr_number", pr["number"])
              |> Map.put("pr_url", pr["url"])
              |> Map.put("pr_detected_at", timestamp())

            detection = %{
              "slot_index" => slot["slot_index"],
              "branch" => slot["branch"],
              "pr_number" => pr["number"],
              "pr_url" => pr["url"]
            }

            acc =
              acc
              |> replace_slot(updated_slot)
              |> add_event("pr_detected", detection)

            {acc, [detection | detections]}

          {:error, reason} ->
            blocked =
              slot
              |> Map.put("status", "blocked")
              |> Map.put("blocked_reason", inspect(reason))
              |> Map.put("blocked_at", timestamp())

            {replace_slot(acc, blocked), detections}
        end
      else
        {acc, detections}
      end
    end)
    |> then(fn {state, detections} -> {state, Enum.reverse(detections)} end)
  end

  defp detect_pr(slot, opts) do
    repo = Keyword.get(opts, :github_repo)
    branch = slot["branch"]

    args = [
      "pr",
      "list",
      "--head",
      branch,
      "--state",
      "open",
      "--json",
      "number,url,headRefName,state"
    ]

    args = if repo, do: args ++ ["--repo", repo], else: args

    case Command.run("gh", args, stderr_to_stdout: true, timeout_ms: @default_command_timeout_ms) do
      {:ok, {output, 0}} ->
        output
        |> Jason.decode()
        |> case do
          {:ok, [pr | _]} -> {:ok, normalize_pr(pr)}
          {:ok, []} -> {:ok, nil}
          {:error, error} -> {:error, {:gh_json_decode_failed, Exception.message(error)}}
        end

      {:ok, {output, status}} ->
        {:error, {:gh_pr_list_failed, status, String.trim(output)}}

      {:error, {:command_timeout, _command, _args, timeout_ms}} ->
        {:error, {:gh_timeout, timeout_ms}}
    end
  end

  defp tick_slot?(slot, opts) do
    host_id = Keyword.get(opts, :host_id)

    slot["status"] in @slot_active_statuses and
      (is_nil(host_id) or slot["host_id"] == host_id)
  end

  defp advance_slot?(slot, opts) do
    host_id = Keyword.get(opts, :host_id)

    slot["status"] == "pr_detected" and
      (is_nil(host_id) or slot["host_id"] == host_id)
  end

  defp normalize_pr(pr) do
    %{
      "number" => pr["number"],
      "url" => pr["url"],
      "headRefName" => pr["headRefName"],
      "state" => pr["state"]
    }
  end

  defp advance_detected_slots(state, apply?, opts) do
    state
    |> Map.get("slots", [])
    |> Enum.filter(&advance_slot?(&1, opts))
    |> Enum.reduce({state, []}, fn slot, {acc, actions} ->
      case next_unassigned_issue(acc) do
        nil ->
          advanced = Map.put(slot, "status", "advanced")
          action = %{"slot_index" => slot["slot_index"], "action" => "no_unassigned_issues"}
          {replace_slot(acc, advanced) |> add_event("slot_advanced", action), [action | actions]}

        issue ->
          replacement = replacement_slot(slot, issue)
          action = create_or_plan_worktree(replacement, apply?, opts)

          updated_replacement =
            replacement
            |> Map.put("status", replacement_status(action, apply?))
            |> Map.put("created_at", timestamp())
            |> maybe_put_blocked_reason(action)

          completed = Map.put(slot, "status", "advanced")

          acc =
            acc
            |> replace_slot(completed)
            |> replace_slot(updated_replacement)
            |> add_event(if(apply?, do: "worktree_created", else: "worktree_planned"), action)

          {acc, [action | actions]}
      end
    end)
    |> then(fn {state, actions} -> {state, Enum.reverse(actions)} end)
  end

  defp next_unassigned_issue(state) do
    assigned =
      state
      |> Map.get("slots", [])
      |> Enum.map(& &1["issue_number"])
      |> MapSet.new()

    state
    |> Map.get("issues", [])
    |> Enum.find(&(&1 not in assigned))
  end

  defp replacement_slot(slot, issue) do
    %{
      "slot_index" => slot["slot_index"],
      "issue_number" => issue,
      "branch" => replacement_branch(slot["branch"], issue),
      "worktree_path" =>
        replacement_worktree_path(
          slot["worktree_path"],
          replacement_branch(slot["branch"], issue)
        ),
      "host_id" => slot["host_id"],
      "agent_kind" => slot["agent_kind"]
    }
  end

  defp create_or_plan_worktree(slot, false, _opts) do
    %{
      "slot_index" => slot["slot_index"],
      "action" => "create_worktree",
      "dry_run" => true,
      "branch" => slot["branch"],
      "worktree_path" => slot["worktree_path"],
      "issue_number" => slot["issue_number"]
    }
  end

  defp create_or_plan_worktree(slot, true, opts) do
    repo_root = Keyword.get(opts, :repo_root, File.cwd!())
    worktree_path = slot["worktree_path"]

    cond do
      File.exists?(Path.join(worktree_path, ".git")) or File.exists?(worktree_path) ->
        %{
          "slot_index" => slot["slot_index"],
          "action" => "reuse_existing_worktree",
          "branch" => slot["branch"],
          "worktree_path" => worktree_path,
          "issue_number" => slot["issue_number"]
        }

      true ->
        File.mkdir_p!(Path.dirname(worktree_path))

        case Command.run(
               "git",
               ["-C", repo_root, "worktree", "add", "-B", slot["branch"], worktree_path, "HEAD"],
               stderr_to_stdout: true,
               timeout_ms: @default_command_timeout_ms
             ) do
          {:ok, {_output, 0}} ->
            %{
              "slot_index" => slot["slot_index"],
              "action" => "created_worktree",
              "branch" => slot["branch"],
              "worktree_path" => worktree_path,
              "issue_number" => slot["issue_number"]
            }

          {:ok, {output, status}} ->
            %{
              "slot_index" => slot["slot_index"],
              "action" => "blocked",
              "branch" => slot["branch"],
              "worktree_path" => worktree_path,
              "issue_number" => slot["issue_number"],
              "reason" => "git worktree add failed with #{status}: #{String.trim(output)}"
            }

          {:error, {:command_timeout, _command, _args, timeout_ms}} ->
            %{
              "slot_index" => slot["slot_index"],
              "action" => "blocked",
              "branch" => slot["branch"],
              "worktree_path" => worktree_path,
              "issue_number" => slot["issue_number"],
              "reason" => "git worktree add timed out after #{timeout_ms}ms"
            }
        end
    end
  end

  defp replacement_status(%{"action" => "blocked"}, _apply?), do: "blocked"
  defp replacement_status(_action, true), do: "worktree_created"
  defp replacement_status(_action, false), do: "planned"

  defp maybe_put_blocked_reason(slot, %{"reason" => reason}),
    do: Map.put(slot, "blocked_reason", reason)

  defp maybe_put_blocked_reason(slot, _action), do: slot

  defp replacement_branch(branch, issue) do
    Regex.replace(~r/-\d+$/, branch, "-#{issue}")
  end

  defp replacement_worktree_path(nil, branch), do: Path.expand(branch)
  defp replacement_worktree_path(path, branch), do: Path.join(Path.dirname(path), branch)

  defp branch_issue(branch) do
    case Regex.run(~r/-(\d+)$/, branch) do
      [_, issue] -> to_int(issue)
      _ -> nil
    end
  end

  defp branch_agent(branch) do
    branch
    |> String.replace(~r/-\d+$/, "")
    |> String.split("-")
    |> List.last()
  end

  defp replace_slot(state, slot) do
    Map.update(state, "slots", [slot], fn slots ->
      slots
      |> Enum.reject(
        &(&1["slot_index"] == slot["slot_index"] and &1["issue_number"] == slot["issue_number"])
      )
      |> Kernel.++([slot])
      |> Enum.sort_by(fn slot -> {slot["slot_index"], slot["issue_number"] || 0} end)
    end)
  end

  defp add_event(state, type, data) do
    event = %{"type" => type, "at" => timestamp(), "data" => data}
    Map.update(state, "events", [event], &(&1 ++ [event]))
  end

  defp enrich_state(state) do
    state
    |> Map.put_new("confirmations", [])
    |> Map.put("summary", campaign_summary(state))
    |> Map.put("next_actions", campaign_next_actions(state))
  end

  defp campaign_summary(state) do
    slots = Map.get(state, "slots", [])

    %{
      "slots_total" => length(slots),
      "by_status" => slots |> Enum.map(&(&1["status"] || "")) |> Enum.frequencies(),
      "by_host" => slots |> Enum.map(&(&1["host_id"] || "")) |> Enum.frequencies(),
      "prs" => Enum.count(slots, &present?(&1["pr_url"])),
      "blocked" => Enum.count(slots, &(&1["status"] == "blocked")),
      "ready" => Enum.count(slots, &(&1["status"] in ["pr_detected", "advanced"]))
    }
  end

  defp campaign_next_actions(state) do
    campaign_name = state["name"] || "<name>"

    state
    |> Map.get("slots", [])
    |> Enum.flat_map(&slot_next_actions(&1, campaign_name))
  end

  defp slot_next_actions(%{"status" => "blocked"} = slot, _campaign_name) do
    [
      %{
        "slot_index" => slot["slot_index"],
        "branch" => slot["branch"],
        "action" => "resolve_blocker",
        "evidence" => slot["blocked_reason"] || ""
      }
    ]
  end

  defp slot_next_actions(%{"status" => "pr_detected"} = slot, campaign_name) do
    [
      %{
        "slot_index" => slot["slot_index"],
        "branch" => slot["branch"],
        "action" => "advance_slot",
        "command" => "jx campaign tick #{campaign_name} --apply"
      }
    ]
  end

  defp slot_next_actions(%{"status" => status} = slot, _campaign_name)
       when status in ["planned", "worktree_created"] do
    [
      %{
        "slot_index" => slot["slot_index"],
        "branch" => slot["branch"],
        "action" => "start_or_confirm_agent_work",
        "worktree_path" => slot["worktree_path"] || ""
      }
    ]
  end

  defp slot_next_actions(_slot, _campaign_name), do: []

  defp normalize_confirmation_attrs(attrs) do
    %{
      "slot_index" => Map.get(attrs, "slot_index", Map.get(attrs, :slot_index)),
      "status" => Map.get(attrs, "status", Map.get(attrs, :status, "confirmed")),
      "message" => Map.get(attrs, "message", Map.get(attrs, :message, ""))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp touch(state), do: Map.put(state, "updated_at", timestamp())

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> List.to_string(name)
      _ -> "local"
    end
  end
end
