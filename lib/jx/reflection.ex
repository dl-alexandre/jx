defmodule JX.Reflection do
  @moduledoc """
  Retrospective analysis of the durable orchestration record.

  Where `JX.Workspace.portfolio_summary/1` is a *live* snapshot of what is
  running right now, reflection looks *backward* over the persisted tasks and
  session observations and reports what can be learned from past runs:

    * **Runs** — tasks clustered into runs by launch-time proximity, with the
      agents, hosts, and status breakdown of each run.
    * **Lifecycle health** — tasks stuck in `running` with no recent update,
      i.e. work that was launched but whose terminal state never came back
      ("launched into the dark").
    * **Observation coverage** — how many session observations exist for each
      run's time window, flagging *blind runs* that recorded no observations.
    * **Attribution gaps** — observations whose `agent_name` is blank even
      though their tmux `session_name` encodes the agent
      (`jx_..._<agent>`), which is recoverable.

  Consumers (CLI, daemon, Jido actions) reach this through
  `JX.Workspace.reflect/1`; this module is the storage-facing query layer.
  Returns plain maps so callers can render tables or JSON.
  """

  import Ecto.Query

  alias JX.Repo
  alias JX.Tasks
  alias JX.SessionObservations.SessionObservation

  # A gap larger than this between consecutive task launches starts a new run.
  @default_run_gap_seconds 1800
  # A `running` task not updated within this window is treated as stale/stuck.
  @default_stale_running_seconds 3600
  @terminal_statuses ~w(completed stopped failed)

  @doc """
  Build a reflection report over all persisted tasks and observations.

  Options:

    * `:run_gap_seconds` — launch-time gap that splits runs (default 1800)
    * `:stale_running_seconds` — age past which a `running` task is stale
      (default 3600)
    * `:now` — reference time for staleness (default `DateTime.utc_now/0`)
  """
  def reflect(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    gap = Keyword.get(opts, :run_gap_seconds, @default_run_gap_seconds)
    stale_after = Keyword.get(opts, :stale_running_seconds, @default_stale_running_seconds)

    tasks = Tasks.list_tasks()

    runs =
      tasks
      |> cluster_runs(gap)
      |> Enum.map(&annotate_run/1)

    %{
      generated_at: now,
      task_count: length(tasks),
      runs: runs,
      lifecycle: lifecycle_summary(tasks, now, stale_after),
      observations: observation_summary(),
      attribution: attribution_gaps()
    }
  end

  # --- runs -----------------------------------------------------------------

  defp cluster_runs([], _gap), do: []

  defp cluster_runs(tasks, gap) do
    tasks
    |> Enum.sort_by(& &1.inserted_at, DateTime)
    |> Enum.chunk_while(
      nil,
      fn task, acc ->
        case acc do
          nil ->
            {:cont, {[task], task.inserted_at}}

          {run, last_at} ->
            if DateTime.diff(task.inserted_at, last_at) > gap do
              {:cont, Enum.reverse(run), {[task], task.inserted_at}}
            else
              {:cont, {[task | run], task.inserted_at}}
            end
        end
      end,
      fn
        nil -> {:cont, nil}
        {run, _last} -> {:cont, Enum.reverse(run), nil}
      end
    )
  end

  defp annotate_run(tasks) do
    started = tasks |> Enum.map(& &1.inserted_at) |> Enum.min(DateTime)
    ended = tasks |> Enum.map(& &1.updated_at) |> Enum.max(DateTime)
    obs_count = observation_count_between(started, ended)

    %{
      started_at: started,
      ended_at: ended,
      task_count: length(tasks),
      agents: tally(tasks, & &1.agent_name),
      hosts: tally(tasks, &(&1.host_id || :local)),
      statuses: tally(tasks, & &1.status),
      observation_count: obs_count,
      blind?: obs_count == 0
    }
  end

  # --- lifecycle ------------------------------------------------------------

  defp lifecycle_summary(tasks, now, stale_after) do
    by_status = tally(tasks, & &1.status)

    stale_running =
      Enum.filter(tasks, fn task ->
        task.status == "running" and
          DateTime.diff(now, task.updated_at) > stale_after
      end)

    %{
      by_status: by_status,
      terminal: Enum.reduce(@terminal_statuses, 0, &(&2 + Map.get(by_status, &1, 0))),
      stale_running_count: length(stale_running),
      stale_running:
        stale_running
        |> Enum.sort_by(& &1.updated_at, DateTime)
        |> Enum.map(fn task ->
          %{
            task_id: task.task_id,
            agent_name: task.agent_name,
            branch: task.branch,
            updated_at: task.updated_at,
            age_seconds: DateTime.diff(now, task.updated_at)
          }
        end)
    }
  end

  # --- observations ---------------------------------------------------------

  defp observation_summary do
    rows =
      Repo.all(
        from(o in SessionObservation,
          group_by: o.agent_name,
          select: %{
            agent_name: o.agent_name,
            count: count(o.id),
            hosts: count(o.host, :distinct),
            first_at: min(o.inserted_at),
            last_at: max(o.inserted_at)
          }
        )
      )

    %{
      total: Enum.reduce(rows, 0, &(&1.count + &2)),
      by_agent:
        rows
        |> Enum.map(&Map.update!(&1, :agent_name, fn name -> blank_to_nil(name) end))
        |> Enum.sort_by(& &1.count, :desc)
    }
  end

  defp observation_count_between(start_at, end_at) do
    Repo.one(
      from(o in SessionObservation,
        where: o.inserted_at >= ^start_at and o.inserted_at <= ^end_at,
        select: count(o.id)
      )
    ) || 0
  end

  # --- attribution ----------------------------------------------------------

  # Observations with no agent tag whose tmux session name still encodes the
  # agent as a trailing `_<agent>` segment (e.g. jx_<project>_task_<hash>_claude).
  # These are a recoverable capture defect; bare shells (non-jx names) are not.
  defp attribution_gaps do
    recoverable =
      Repo.all(
        from(o in SessionObservation,
          where:
            (is_nil(o.agent_name) or o.agent_name == "") and
              not is_nil(o.session_name) and
              fragment("substr(?, 1, 3) = ?", o.session_name, "jx_"),
          select: %{session_name: o.session_name, host: o.host}
        )
      )

    by_agent =
      recoverable
      |> Enum.map(fn row -> {recover_agent(row.session_name), row} end)
      |> Enum.reject(fn {agent, _} -> is_nil(agent) end)
      |> Enum.group_by(fn {agent, _} -> agent end, fn {_, row} -> row end)
      |> Enum.map(fn {agent, rows} ->
        %{
          agent_name: agent,
          count: length(rows),
          sessions: rows |> Enum.map(& &1.session_name) |> Enum.uniq()
        }
      end)
      |> Enum.sort_by(& &1.count, :desc)

    %{
      recoverable_count: Enum.reduce(by_agent, 0, &(&1.count + &2)),
      by_agent: by_agent
    }
  end

  # The agent is the trailing underscore-delimited segment of a jx session name;
  # task hashes are hex and contain no underscores, so the last segment is safe.
  defp recover_agent(session_name) do
    case session_name |> String.split("_") |> List.last() do
      nil -> nil
      "" -> nil
      agent -> agent
    end
  end

  # --- helpers --------------------------------------------------------------

  defp tally(items, fun) do
    items
    |> Enum.map(fun)
    |> Enum.map(&blank_to_nil/1)
    |> Enum.frequencies()
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(other), do: other
end
