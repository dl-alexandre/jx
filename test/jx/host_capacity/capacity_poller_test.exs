defmodule JX.HostCapacity.CapacityPollerTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias JX.Directives.Directive
  alias JX.HostCapacity.CapacityPoller
  alias JX.HostCapacity.Observation
  alias JX.Hosts
  alias JX.Projects.Project
  alias JX.Repo
  alias JX.Tasks.Task, as: TaskRow

  # No Ecto sandbox is in use: tests share one real SQLite DB and commit data.
  # Before deleting hosts we must clear every table that FK-references hosts
  # (projects, tasks, directives — all on_delete: :restrict), otherwise a
  # directive row left behind by another test blocks `delete_all(Hosts.Host)`
  # with a FOREIGN KEY constraint error. Repro before this fix: `--seed 1002`.
  setup do
    Repo.delete_all(Observation)
    Repo.delete_all(TaskRow)
    Repo.delete_all(Project)
    Repo.delete_all(Directive)
    Repo.delete_all(Hosts.Host)
    :ok
  end

  defp insert_host!(name) do
    {:ok, host} =
      Hosts.upsert_host(%{
        name: name,
        transport: "local",
        ssh_target: nil,
        workspace_path: "/tmp/jx-test-#{name}"
      })

    host
  end

  defp insert_project!(host, name) do
    %Project{}
    |> Project.changeset(%{name: name, host_id: host.id, repo_path: "/tmp/jx-test-#{name}"})
    |> Repo.insert!()
  end

  # Bypasses the Tasks changeset so the test fixture only has to supply
  # the columns the poller cares about — host_id and status. Other NOT
  # NULL columns get harmless placeholder values.
  defp insert_running_task!(host, project) do
    now = DateTime.utc_now()
    uid = System.unique_integer([:positive])

    {1, _} =
      Repo.insert_all(TaskRow, [
        %{
          task_id: "task-#{uid}",
          prompt_hash: "hash-#{uid}",
          prompt: "test",
          agent_name: "codex",
          agent_transport: "local",
          branch: "test/#{uid}",
          worktree_path: "/tmp/wt-#{uid}",
          task_dir: "/tmp/td-#{uid}",
          log_path: "/tmp/log-#{uid}",
          session_name: "session-#{uid}",
          tmux_server: "",
          window: 0,
          pane: 0,
          status: "running",
          last_error: "",
          project_id: project.id,
          host_id: host.id,
          inserted_at: now,
          updated_at: now
        }
      ])

    :ok
  end

  defp observations_for(host_name) do
    from(o in Observation, where: o.host_name == ^host_name, order_by: [asc: o.id])
    |> Repo.all()
  end

  describe "run_once/0" do
    test "no hosts with active sessions → no observations recorded" do
      _idle = insert_host!("idle-host")
      # No running tasks, no fanout — host has zero active.

      CapacityPoller.run_once()

      assert observations_for("idle-host") == []
    end

    test "one host with a running task → snapshot recorded" do
      host = insert_host!("active-host")
      project = insert_project!(host, "active-proj")
      insert_running_task!(host, project)

      CapacityPoller.run_once()

      assert [obs] = observations_for("active-host")
      assert obs.host_name == "active-host"
      # Fake SSH returns 8192 MB available RAM, 8 CPU cores by default.
      assert obs.ram_available_mb == 8_192
      assert obs.cpu_cores == 8
      # Active sessions count reflects the running task we inserted.
      assert obs.active_sessions == 1
    end

    test "multiple hosts → each gets its own observation (concurrent path)" do
      # Exercises the Task.Supervisor.async_stream fan-out added in #12.
      # Doesn't assert ordering — async_stream is configured ordered: false —
      # only that every active host gets its observation regardless of order.
      for n <- 1..3 do
        host = insert_host!("fleet-#{n}")
        project = insert_project!(host, "fleet-#{n}-proj")
        insert_running_task!(host, project)
      end

      CapacityPoller.run_once()

      for n <- 1..3 do
        assert [_obs] = observations_for("fleet-#{n}"),
               "expected one observation for fleet-#{n}"
      end
    end

    test "host with no active sessions is filtered out before snapshot" do
      # Two hosts, only one is "active" — only the active one should be
      # snapshotted. Confirms the pre-filter in poll_all_active_hosts/0
      # still applies under the async-stream rewrite.
      _quiet = insert_host!("quiet-host")
      busy = insert_host!("busy-host")
      busy_proj = insert_project!(busy, "busy-proj")
      insert_running_task!(busy, busy_proj)

      CapacityPoller.run_once()

      assert observations_for("quiet-host") == []
      assert [_] = observations_for("busy-host")
    end
  end
end
