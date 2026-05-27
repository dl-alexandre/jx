defmodule JX.ReflectionTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias JX.Hosts
  alias JX.Projects.Project
  alias JX.Reflection
  alias JX.Repo
  alias JX.SessionObservations.SessionObservation
  alias JX.Tasks.Task, as: TaskRow

  # Shared real SQLite DB, no sandbox: clear (in FK order) the tables this
  # suite reasons over, then build a host + project for the task rows.
  setup do
    Repo.delete_all(SessionObservation)
    Repo.delete_all(TaskRow)
    Repo.delete_all(Project)
    Repo.delete_all(Hosts.Host)

    {:ok, host} =
      Hosts.upsert_host(%{name: "h1", transport: "local", workspace_path: "/tmp/jx-test-h1"})

    project =
      %Project{}
      |> Project.changeset(%{name: "proj", host_id: host.id, repo_path: "/tmp/jx-test-proj"})
      |> Repo.insert!()

    {:ok, host: host, project: project}
  end

  @now ~U[2026-05-26 12:00:00.000000Z]

  defp insert_task!(ctx, attrs) do
    task =
      Repo.insert!(
        struct(TaskRow, %{
          task_id: attrs[:task_id],
          prompt_hash: "h-#{attrs[:task_id]}",
          prompt: "p",
          agent_name: attrs[:agent_name],
          agent_transport: "native",
          branch: "jx/task-#{attrs[:task_id]}",
          worktree_path: "/wt/#{attrs[:task_id]}",
          task_dir: "/td/#{attrs[:task_id]}",
          log_path: "/log/#{attrs[:task_id]}",
          session_name: "s",
          tmux_server: "jx",
          status: attrs[:status],
          project_id: ctx.project.id,
          host_id: ctx.host.id
        })
      )

    # Force timestamps deterministically (insert autogenerates "now").
    Repo.update_all(
      from(t in TaskRow, where: t.id == ^task.id),
      set: [inserted_at: attrs[:at], updated_at: attrs[:updated_at] || attrs[:at]]
    )

    task
  end

  defp insert_obs!(attrs) do
    obs =
      Repo.insert!(
        struct(SessionObservation, %{
          ref: attrs[:ref],
          host: attrs[:host] || "h1",
          transport: "ssh",
          type: "agent",
          state: "active",
          kind: "shell",
          work_state: "idle",
          capture_status: "ok",
          agent_name: attrs[:agent_name] || "",
          session_name: attrs[:session_name] || "",
          snapshot: attrs[:snapshot] || "{}"
        })
      )

    Repo.update_all(
      from(o in SessionObservation, where: o.id == ^obs.id),
      set: [inserted_at: attrs[:at]]
    )

    obs
  end

  test "clusters tasks into runs by launch-time gap and flags blind runs", ctx do
    # Run A: two tasks a minute apart, with observations in-window.
    insert_task!(ctx, %{task_id: "a1", agent_name: "codex", status: "running", at: shift(-180)})
    insert_task!(ctx, %{task_id: "a2", agent_name: "claude", status: "running", at: shift(-179)})
    insert_obs!(%{ref: "o1", agent_name: "codex", at: shift(-179)})

    # Run B: a single task hours later, no observations -> blind.
    insert_task!(ctx, %{task_id: "b1", agent_name: "opencode", status: "running", at: shift(-10)})

    report = Reflection.reflect(now: @now, run_gap_seconds: 1800)

    assert report.task_count == 3
    assert length(report.runs) == 2

    [run_a, run_b] = report.runs
    assert run_a.task_count == 2
    assert run_a.agents == %{"codex" => 1, "claude" => 1}
    refute run_a.blind?
    assert run_a.observation_count >= 1

    assert run_b.task_count == 1
    assert run_b.blind?
    assert run_b.observation_count == 0
  end

  test "flags running tasks with no recent update as stale", ctx do
    insert_task!(ctx, %{
      task_id: "stuck",
      agent_name: "codex",
      status: "running",
      at: shift(-300),
      updated_at: shift(-300)
    })

    insert_task!(ctx, %{
      task_id: "fresh",
      agent_name: "codex",
      status: "running",
      at: shift(-5),
      updated_at: shift(-5)
    })

    report = Reflection.reflect(now: @now, stale_running_seconds: 3600)

    assert report.lifecycle.stale_running_count == 1
    assert [%{task_id: "stuck"}] = report.lifecycle.stale_running
  end

  test "recovers agent attribution from jx session name when agent_name is blank", _ctx do
    insert_obs!(%{
      ref: "miss",
      agent_name: "",
      session_name: "jx_onebackend_v3_task_1f4d1c4b0163_claude",
      at: shift(-60)
    })

    # Bare shell: not a jx session, must not be counted as recoverable.
    insert_obs!(%{ref: "shell", agent_name: "", session_name: "Work", at: shift(-60)})

    report = Reflection.reflect(now: @now)

    assert report.attribution.recoverable_count == 1
    assert [%{agent_name: "claude", count: 1}] = report.attribution.by_agent
  end

  defp shift(minutes), do: DateTime.add(@now, minutes * 60, :second)
end
