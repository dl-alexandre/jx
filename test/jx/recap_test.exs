defmodule JX.RecapTest do
  use ExUnit.Case, async: false

  alias JX.CallHandoffs.CallHandoff
  alias JX.Directives.Directive
  alias JX.Hosts.Host
  alias JX.OperationalEvents.Event, as: OperationalEvent
  alias JX.Projects.Project
  alias JX.Recap
  alias JX.Repo
  alias JX.ResourceOwnerships.Resource
  alias JX.SessionProfiles.SessionProfile
  alias JX.Tasks.Task
  alias JX.Workspace

  setup do
    Repo.delete_all(OperationalEvent)
    Repo.delete_all(CallHandoff)
    Repo.delete_all(SessionProfile)
    Repo.delete_all(Directive)
    Repo.delete_all(Resource)
    Repo.delete_all(Task)
    Repo.delete_all(Project)
    Repo.delete_all(Host)

    {:ok, _host} =
      Workspace.add_host(%{
        name: "build-1",
        ssh_target: "developer@example.test",
        workspace_path: "/srv/agent"
      })

    {:ok, _project} =
      Workspace.add_project(%{
        name: "saysure",
        host_name: "build-1",
        repo_path: "/srv/repos/saysure"
      })

    :ok
  end

  test "recap blends tasks directives resources handoffs profiles and events" do
    {:ok, task} = Workspace.assign_task("saysure", "recap this week", agent_name: "codex")
    {:ok, _directive} = Workspace.send(task.task_id, "continue")

    {:ok, _handoff} =
      Workspace.create_call_handoff(
        %{
          summary: "operator blocked on shell noise",
          project: "saysure",
          ref: "saysure",
          title: "blocked observation"
        },
        brief: false
      )

    {:ok, _event} =
      Workspace.record_agent_report(%{
        session_id: task.task_id,
        task_id: task.task_id,
        agent_id: "codex-1",
        kind: "progress",
        text: "rebased branch"
      })

    {:ok, _profile} =
      Workspace.set_session_profile("saysure", %{
        prompt_status: "blocked",
        notes: "needs rebuild"
      })

    report = Recap.run(days: 7, limit: 5)

    assert report.tasks.total == 1
    assert report.tasks.by_status["running"] == 1
    assert report.tasks.by_agent["codex"] == 1
    assert report.tasks.by_project["saysure"] == 1
    assert report.tasks.by_host["build-1"] == 1

    assert report.directives.total == 1
    assert report.resources.by_type["tmux_session"] == 1
    assert report.handoffs.total == 1
    assert report.session_profiles.by_prompt_status["blocked"] == 1
    assert report.operational_events.by_kind["agent.report.progress"] == 1
  end
end
