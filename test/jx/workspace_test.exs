defmodule JX.WorkspaceTest do
  use ExUnit.Case, async: false

  alias JX.Directives.Directive
  alias JX.CallHandoffs.CallHandoff
  alias JX.CiWatches.CiWatch
  alias JX.Delegations.Delegation
  alias JX.Hosts.Host
  alias JX.HostDoctor
  alias JX.MonitorEvents.Cursor
  alias JX.MonitorEvents.Event
  alias JX.OperationExecutions.OperationExecution
  alias JX.OrchestrationActions.OrchestrationAction
  alias JX.OrchestratorHeartbeats.Heartbeat
  alias JX.Projects.Project
  alias JX.Repo
  alias JX.RepoDoctor
  alias JX.RemoteSessions.RemoteSessionObservation
  alias JX.RemoteSessions
  alias JX.ResourceOwnerships.Resource
  alias JX.Notifications.Notification
  alias JX.SessionControls.SessionControl
  alias JX.SessionObservations.SessionObservation
  alias JX.SessionProfiles.OperatorProfile
  alias JX.SessionProfiles.SessionProfile
  alias JX.SessionWatches.SessionWatch
  alias JX.HostCapacity.Observation, as: CapacityObservation
  alias JX.Tasks.Task
  alias JX.WakeTriggers.WakeTrigger
  alias JX.Workspace

  defmodule FailingResourceOwnerships do
    def register_tmux_session(_attrs), do: {:error, :forced_registry_failure}
    def register_temp_path(_attrs), do: {:error, :forced_registry_failure}
  end

  setup do
    original_resource_ownerships = Application.get_env(:jx, :resource_ownerships)
    Application.delete_env(:jx, :resource_ownerships)

    on_exit(fn ->
      if original_resource_ownerships do
        Application.put_env(:jx, :resource_ownerships, original_resource_ownerships)
      else
        Application.delete_env(:jx, :resource_ownerships)
      end
    end)

    Repo.delete_all(WakeTrigger)
    Repo.delete_all(SessionObservation)
    Repo.delete_all(Cursor)
    Repo.delete_all(Event)
    Repo.delete_all(Notification)
    Repo.delete_all(CallHandoff)
    Repo.delete_all(Delegation)
    Repo.delete_all(Heartbeat)
    Repo.delete_all(OrchestrationAction)
    Repo.delete_all(OperationExecution)
    Repo.delete_all(CiWatch)
    Repo.delete_all(RemoteSessionObservation)
    Repo.delete_all(SessionProfile)
    Repo.delete_all(OperatorProfile)
    Repo.delete_all(SessionWatch)
    Repo.delete_all(SessionControl)
    Repo.delete_all(Directive)
    Repo.delete_all(Resource)
    Repo.delete_all(CapacityObservation)
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

  test "assign_task creates a durable task and reuses it for the same prompt" do
    {:ok, task1} = Workspace.assign_task("saysure", "refactor webhook ingestion boundary")
    {:ok, task2} = Workspace.assign_task("saysure", "refactor webhook ingestion boundary")

    assert task1.task_id == task2.task_id
    assert task1.branch == "jx/#{task1.task_id}"
    assert task1.session_name == "jx_saysure_#{String.replace(task1.task_id, "-", "_")}_claude"
    assert task1.worktree_path == "/srv/agent/projects/saysure/worktrees/#{task1.task_id}"

    assert task1.launch_command ==
             "'claude' -p --dangerously-skip-permissions < '/srv/agent/projects/saysure/.jx/tasks/#{task1.task_id}/prompt.md'"

    assert Repo.aggregate(Task, :count) == 1
    assert Repo.get_by(Resource, resource_type: "tmux_session", resource_name: task1.session_name)

    assert Repo.get_by(Resource,
             resource_type: "worktree_path",
             resource_path: task1.worktree_path
           )

    assert Repo.get_by(Resource, resource_type: "task_dir", resource_path: task1.task_dir)
    assert Repo.get_by(Resource, resource_type: "log_path", resource_path: task1.log_path)

    assert_received {:ssh_script, script}
    assert script =~ "git -C \"$repo\" worktree add -B \"$branch\" \"$worktree\" HEAD"
    assert script =~ "tmux -L 'jx' -f /dev/null new-session -d -s"
    assert script =~ "tmux -L 'jx' -f /dev/null pipe-pane -o -t \"$session_id:0.0\""
    assert script =~ "send-keys -t \"$target_pane\""
    assert script =~ "cat > \"$launch_script\""
    assert script =~ "exit_status"
  end

  test "assign_task marks task degraded and fails when resource registration fails" do
    Application.put_env(:jx, :resource_ownerships, FailingResourceOwnerships)

    assert_raise RuntimeError, ~r/resource ownership registration failed/, fn ->
      Workspace.assign_task("saysure", "resource registration failure")
    end

    assert %Task{status: "error", last_error: error} = Repo.one(Task)
    assert error =~ "resource ownership registration failed"
  end

  test "assign_task records supported agent names in deterministic session names" do
    {:ok, task} =
      Workspace.assign_task("saysure", "exercise codex session naming", agent_name: "codex")

    assert task.agent_name == "codex"
    assert task.session_name == "jx_saysure_#{String.replace(task.task_id, "-", "_")}_codex"
    assert task.launch_command =~ "'codex' exec"
    assert task.launch_command =~ " < "
  end

  test "assign_task can target a project instance by host" do
    {:ok, _host} =
      Workspace.add_host(%{
        name: "build-2",
        ssh_target: "developer@build-2.example.test",
        workspace_path: "/srv/agent-2"
      })

    {:ok, _project} =
      Workspace.add_project(%{
        name: "saysure",
        host_name: "build-2",
        repo_path: "/srv/repos/saysure-2"
      })

    {:ok, task} =
      Workspace.assign_task("saysure", "target build 2",
        host_name: "build-2",
        agent_name: "codex"
      )

    assert task.host.name == "build-2"
    assert task.project.name == "saysure"
    assert task.worktree_path == "/srv/agent-2/projects/saysure/worktrees/#{task.task_id}"
    assert task.launch_command =~ "-C '/srv/agent-2/projects/saysure/worktrees/#{task.task_id}'"

    assert_received {:ssh_script, script}
    assert script =~ "repo='/srv/repos/saysure-2'"
  end

  test "assign_task returns host-scoped project errors" do
    assert {:error, {:project_not_found, "saysure", "missing-host"}} =
             Workspace.assign_task("saysure", "target missing host", host_name: "missing-host")
  end

  test "assign_task can launch Codex through the goal operation" do
    {:ok, task} =
      Workspace.assign_task("saysure", "exercise codex goal sessions",
        agent_name: "codex",
        goal: true
      )

    assert task.agent_name == "codex"
    assert task.agent_transport == "native"
    assert task.goal_objective == "exercise codex goal sessions"
    assert task.launch_command =~ "'codex' --enable goals"
    assert task.launch_command =~ "--no-alt-screen"
    refute task.launch_command =~ "'codex' exec"

    assert_received {:ssh_script, script}
    assert script =~ "printf %s 'exercise codex goal sessions' > \"$task_dir/goal.md\""

    assert script =~
             "send-keys -t \"$target_pane\" -l -- '/goal follow the instructions in /srv/agent/projects/saysure/.jx/tasks/#{task.task_id}/goal.md'"

    assert script =~ "goal_status.json"
    assert script =~ "goal_command.txt"
    assert script =~ "goal_creation_evidence.txt"
    assert script =~ "goal_completion.json"
  end

  test "assign_task keeps Codex goal tasks distinct from normal Codex tasks" do
    {:ok, normal_task} =
      Workspace.assign_task("saysure", "same codex prompt", agent_name: "codex")

    {:ok, goal_task} =
      Workspace.assign_task("saysure", "same codex prompt", agent_name: "codex", goal: true)

    assert normal_task.task_id != goal_task.task_id
    assert normal_task.goal_objective == ""
    assert goal_task.goal_objective == "same codex prompt"
    assert Repo.aggregate(Task, :count) == 2
  end

  test "assign_task rejects Codex goals for unsupported agents and transports" do
    assert {:error, {:unsupported_goal_agent, "claude"}} =
             Workspace.assign_task("saysure", "goal me", goal: true)

    assert {:error, {:unsupported_goal_transport, "acpx"}} =
             Workspace.assign_task("saysure", "goal me",
               agent_name: "codex",
               agent_transport: "acpx",
               goal: true
             )

    assert Repo.aggregate(Task, :count) == 0
  end

  test "assign_task can launch through the experimental acpx transport" do
    {:ok, task} =
      Workspace.assign_task("saysure", "exercise acpx transport",
        agent_name: "codex",
        agent_transport: "acpx"
      )

    assert task.agent_name == "codex"
    assert task.agent_transport == "acpx"

    assert task.launch_command ==
             "'acpx' --cwd '/srv/agent/projects/saysure/worktrees/#{task.task_id}' --approve-all --format json --suppress-reads 'codex' exec --file '/srv/agent/projects/saysure/.jx/tasks/#{task.task_id}/prompt.md'"
  end

  test "assign_task builds an opencode command with a non-greedy file flag" do
    {:ok, task} =
      Workspace.assign_task("saysure", "exercise opencode prompt attachment",
        agent_name: "opencode"
      )

    assert task.agent_name == "opencode"
    assert task.launch_command =~ "'opencode' run"

    assert task.launch_command =~
             "\"Read the attached prompt file and complete the task.\" --file '/srv/agent/projects/saysure/.jx/tasks/"
  end

  test "assign_task separates the same prompt by agent name" do
    {:ok, claude_task} = Workspace.assign_task("saysure", "same prompt")
    {:ok, codex_task} = Workspace.assign_task("saysure", "same prompt", agent_name: "codex")

    assert claude_task.task_id != codex_task.task_id
    assert claude_task.agent_name == "claude"
    assert codex_task.agent_name == "codex"
    assert Repo.aggregate(Task, :count) == 2
  end

  test "assign_task separates the same prompt by agent transport" do
    {:ok, native_task} =
      Workspace.assign_task("saysure", "same transport prompt", agent_name: "codex")

    {:ok, acpx_task} =
      Workspace.assign_task("saysure", "same transport prompt",
        agent_name: "codex",
        agent_transport: "acpx"
      )

    assert native_task.task_id != acpx_task.task_id
    assert native_task.agent_transport == "native"
    assert acpx_task.agent_transport == "acpx"
    assert Repo.aggregate(Task, :count) == 2
  end

  test "local hosts can be registered without an ssh target" do
    {:ok, host} =
      Workspace.add_host(%{
        name: "local",
        transport: "local",
        workspace_path: "/tmp/jx"
      })

    assert host.transport == "local"
    assert host.ssh_target == ""
  end

  test "ssh hosts reject option-shaped or whitespace targets" do
    assert {:error, changeset} =
             Workspace.add_host(%{
               name: "bad-option",
               ssh_target: "-oProxyCommand=touch /tmp/owned",
               workspace_path: "/tmp/jx"
             })

    assert {"must not start with -", _} = changeset.errors[:ssh_target]

    assert {:error, changeset} =
             Workspace.add_host(%{
               name: "bad-space",
               ssh_target: "developer@example.test -p 2222",
               workspace_path: "/tmp/jx"
             })

    assert {"must not contain whitespace", _} = changeset.errors[:ssh_target]
  end

  test "list_projects returns registered projects with hosts" do
    assert [
             %Project{
               name: "saysure",
               slug: "saysure",
               repo_path: "/srv/repos/saysure",
               host: %Host{name: "build-1"}
             }
           ] = Workspace.list_projects()
  end

  test "project_audit reads all host-scoped instances for a logical project" do
    {:ok, _host} =
      Workspace.add_host(%{
        name: "build-2",
        ssh_target: "developer@build-2.test",
        workspace_path: "/home/developer"
      })

    {:ok, _project} =
      Workspace.add_project(%{
        name: "example-project",
        host_name: "build-1",
        repo_path: "/srv/example-project"
      })

    {:ok, _project} =
      Workspace.add_project(%{
        name: "example-project",
        host_name: "build-2",
        repo_path: "/home/developer/example-project"
      })

    Process.put(:fake_ssh_project_audits, %{
      "build-1" => """
      jx-project-audit\t1
      repo_path\t/srv/example-project
      status\tok
      branch\ttest/auth-api-security-coverage
      head\t5a353c969b0dd9eea3d106c3778e2864cbd32513
      upstream\torigin/test/auth-api-security-coverage
      ahead_behind\t0\t0
      status_short_start
      ## test/auth-api-security-coverage...origin/test/auth-api-security-coverage
       M test/one/api/auth_test.exs
      status_short_end
      worktree_start
      worktree /srv/example-project
      HEAD 5a353c969b0dd9eea3d106c3778e2864cbd32513
      branch refs/heads/test/auth-api-security-coverage
      worktree_end
      """,
      "build-2" => """
      jx-project-audit\t1
      repo_path\t/home/developer/example-project
      status\tok
      branch\ttest/reports-export-coverage
      head\t3a388836cadcdc8e6f9cc2a6dd414b35d281e5c1
      upstream\t
      ahead_behind\t
      status_short_start
      ## test/reports-export-coverage
      status_short_end
      worktree_start
      worktree /home/developer/example-project
      HEAD 3a388836cadcdc8e6f9cc2a6dd414b35d281e5c1
      branch refs/heads/test/reports-export-coverage
      worktree_end
      """
    })

    assert {:ok, audit} = Workspace.project_audit("example-project")

    assert audit.registered_instances == 2
    assert audit.summary == %{total: 2, ok: 2, errors: 0, dirty: 1, clean: 1, without_upstream: 1}

    assert [
             %{host: "build-1", dirty: true, ahead: 0, behind: 0},
             %{host: "build-2", dirty: false, upstream: "", ahead: nil, behind: nil}
           ] = audit.instances
  end

  test "doctor_host returns grouped preflight checks" do
    {:ok, report} = Workspace.doctor_host("build-1")

    assert HostDoctor.passed?(report)

    assert Enum.map(report.groups, & &1.name) ==
             ~w(execution workspace tools repositories agents tmux)

    repositories = Enum.find(report.groups, &(&1.name == "repositories"))
    assert Enum.any?(repositories.checks, &(&1.name == "saysure: repo path exists"))
    assert Enum.any?(repositories.checks, &(&1.name == "saysure: default remote reachable"))

    agents = Enum.find(report.groups, &(&1.name == "agents"))
    assert Enum.any?(agents.checks, &(&1.name == "codex: binary available"))

    assert_received {:ssh_script, script}
    assert script =~ "printf agent-doctor-ok"
  end

  test "doctor_hosts runs preflight checks across registered hosts" do
    {:ok, report} = Workspace.doctor_hosts(agents: ["codex"])

    assert [%{host: %Host{name: "build-1"}} = host_report] = report.reports
    assert HostDoctor.passed?(host_report)
  end

  test "repo_doctor returns promotion gate checks for registered project instances" do
    Process.put(:fake_ssh_repo_doctors, %{
      "build-1" => """
      jx-repo-doctor\t1
      repo_path\t/srv/repos/saysure
      status\tok
      branch\tdevelop
      head\tabc123
      upstream\torigin/develop
      remote\torigin
      remote_url\tgit@example.test:saysure.git
      remote_refs_start
      abc123\trefs/heads/develop
      def456\trefs/heads/master
      remote_refs_end
      remote_status\t0
      status_short_start
      ## develop...origin/develop
      status_short_end
      worktree_start
      worktree /srv/repos/saysure
      HEAD abc123
      branch refs/heads/develop
      worktree_end
      branches_start
      develop\torigin/develop\t\tabc123\tdevelop commit
      master\torigin/master\t\tdef456\tmaster commit
      branches_end
      """
    })

    assert {:ok, report} = Workspace.repo_doctor("saysure")

    assert RepoDoctor.passed?(report)

    assert report.summary == %{
             total: 1,
             ok: 1,
             failed: 0,
             reconciled: 1,
             trusted: 1,
             degraded: 0,
             untrusted: 0,
             high_confidence: 1,
             partial_confidence: 0,
             low_confidence: 0,
             unknown_confidence: 0
           }

    assert [
             %{
               checks: checks,
               reconciliation_status: "reconciled",
               trust_status: "trusted",
               confidence: "high",
               auth: %{fetch_allowed: "ok", api_allowed: "unknown"},
               evidence: %{canonical_ref: %{source: "remote", value: "abc123"}},
               repo_state: %{auth_status: "ok", drift: %{status: "none", present: false}}
             }
           ] = report.instances

    assert Enum.any?(checks, &(&1.name == "canonical remote is reachable"))
    assert Enum.any?(checks, &(&1.name == "no stale repo sessions"))
  end

  test "repo_doctor separates reconciled local state from degraded remote trust" do
    Process.put(:fake_ssh_repo_doctors, %{
      "build-1" => """
      jx-repo-doctor\t1
      repo_path\t/srv/repos/saysure
      status\tok
      branch\tdevelop
      head\tabc123
      upstream\torigin/develop
      remote\torigin
      remote_url\thttps://github.com/example/private.git
      remote_refs_start
      remote: Invalid username or token.
      fatal: Authentication failed
      remote_refs_end
      remote_status\t128
      tracking_refs_start
      abc123\trefs/remotes/origin/develop
      def456\trefs/remotes/origin/master
      tracking_refs_end
      status_short_start
      ## develop...origin/develop
      status_short_end
      worktree_start
      worktree /srv/repos/saysure
      HEAD abc123
      branch refs/heads/develop
      worktree_end
      branches_start
      develop\torigin/develop\t\tabc123\tdevelop commit
      master\torigin/master\t\tdef456\tmaster commit
      branches_end
      """
    })

    assert {:ok, report} = Workspace.repo_doctor("saysure")

    refute RepoDoctor.passed?(report)

    assert [
             %{
               status: "fail",
               canonical_ref: "abc123",
               canonical_source: "tracking",
               auth_status: "degraded",
               auth: %{auth_valid: "failed", fetch_allowed: "failed", api_allowed: "unknown"},
               reconciliation_status: "reconciled",
               trust_status: "degraded",
               confidence: "partial",
               drift: %{status: "none", types: []},
               evidence: %{
                 canonical_ref: %{source: "tracking", value: "abc123"},
                 remote_auth: %{auth_valid: "failed", fetch_allowed: "failed"}
               },
               repo_state: %{
                 local_ref: "abc123",
                 canonical_ref: "abc123",
                 auth_status: "degraded",
                 reconciliation_status: "reconciled",
                 trust_status: "degraded",
                 confidence: "partial"
               }
             }
           ] = report.instances

    assert report.summary.degraded == 1
    assert report.summary.partial_confidence == 1
  end

  test "doctor_host can narrow agent binary checks" do
    {:ok, report} = Workspace.doctor_host("build-1", agents: ["codex"])

    agents = Enum.find(report.groups, &(&1.name == "agents"))
    assert Enum.map(agents.checks, & &1.name) == ["codex: binary available"]
  end

  test "doctor_host checks acpx transport prerequisites" do
    {:ok, report} =
      Workspace.doctor_host("build-1",
        agents: ["codex"],
        agent_transport: "acpx"
      )

    agents = Enum.find(report.groups, &(&1.name == "agents"))

    assert Enum.map(agents.checks, & &1.name) == [
             "acpx: binary available",
             "acpx: config readable",
             "codex: binary available for acpx adapter"
           ]

    scripts =
      self()
      |> Process.info(:messages)
      |> elem(1)
      |> Enum.flat_map(fn
        {:ssh_script, script} -> [script]
        _message -> []
      end)

    assert Enum.any?(scripts, &String.contains?(&1, "acpx"))
    assert Enum.any?(scripts, &String.contains?(&1, "--cwd \"$cwd\" config show"))
  end

  test "status reconstructs live tmux state through the adapter" do
    {:ok, task} = Workspace.assign_task("saysure", "add status command")

    [status] = Workspace.list_statuses()

    assert status.task.task_id == task.task_id
    assert status.task.status == "running"
    assert status.session_status == "running"
    assert status.last_activity == ~U[2023-11-14 22:13:20Z]
  end

  test "status reports completed tasks when the agent exits zero" do
    Process.put(:fake_ssh_status_output, "running\n1700000000\n0\n")

    {:ok, task} = Workspace.assign_task("saysure", "complete status command")

    [status] = Workspace.list_statuses()

    assert status.task.task_id == task.task_id
    assert status.task.status == "completed"
    assert status.session_status == "running"
    assert status.exit_status == 0
  end

  test "list_tmux_sessions reconstructs raw host tmux sessions" do
    Process.put(
      :fake_ssh_tmux_sessions,
      "/Users/developer/.profile: line 15: zmodload: command not found\n" <>
        "jx_saysure_task_deadbeef_codex\t1700000000\t0\t1\t/srv/repos/saysure\n"
    )

    {:ok, [session]} = Workspace.list_tmux_sessions("build-1")

    assert session.server == "jx"
    assert session.name == "jx_saysure_task_deadbeef_codex"
    assert session.created_at == ~U[2023-11-14 22:13:20Z]
    assert session.attached == 0
    assert session.windows == 1
    assert session.current_path == "/srv/repos/saysure"
  end

  test "list_tmux_sessions preserves explicit tmux server names" do
    {:ok, [session]} = Workspace.list_tmux_sessions("build-1", tmux_server: "default")

    assert session.server == "default"
  end

  test "list_tmux_panes inventories panes with classified activity" do
    Process.put(
      :fake_ssh_tmux_panes,
      "/Users/developer/.profile: line 15: zmodload: command not found\n" <>
        "manual-session\t1\t2\t%7\t1\t/dev/pts/2\t2.1.118\t/srv/repos/saysure\tDebug failing CI tests\n" <>
        "manual-session\t1\t3\t%8\t0\t/dev/pts/3\tssh\t/srv/repos/saysure\tRemote shell\n"
    )

    {:ok, panes} = Workspace.list_tmux_panes("build-1", tmux_server: "default")

    assert Enum.map(panes, &{&1.server, &1.session, &1.window, &1.pane, &1.kind}) == [
             {"default", "manual-session", 1, 2, "claude"},
             {"default", "manual-session", 1, 3, "ssh"}
           ]
  end

  test "list_tmux_panes can scan all tmux servers on a host" do
    Process.put(
      :fake_ssh_tmux_pane_discovery,
      "jx\tmanaged\t0\t0\t%1\t1\t/dev/pts/1\tcodex\t/srv/agent\tCodex\n" <>
        "default\tmanual\t2\t1\t%4\t0\t/dev/pts/4\topencode\t/srv/repos/saysure\tOpenCode\n"
    )

    {:ok, panes} = Workspace.list_tmux_panes("build-1", all_tmux: true)

    assert Enum.map(panes, &{&1.server, &1.session, &1.kind}) == [
             {"jx", "managed", "codex"},
             {"default", "manual", "opencode"}
           ]
  end

  test "capture_tmux_pane returns visible pane output" do
    Process.put(:fake_ssh_tmux_capture, "line one\nline two\n")

    assert {:ok, "line one\nline two\n"} =
             Workspace.capture_tmux_pane("build-1", "manual-session",
               tmux_server: "default",
               window: 1,
               pane: 2,
               lines: 25
             )

    assert_received {:ssh_script, script}
    assert script =~ "capture-pane -p -S -25"
    assert script =~ "=manual-session:1.2"
  end

  test "send_tmux sends a directed message to one pane" do
    assert {:ok, directive} =
             Workspace.send_tmux("build-1", "manual-session", "please report current status",
               tmux_server: "default",
               window: 1,
               pane: 2,
               enter: false
             )

    assert directive.directive_id =~ "dir-"
    assert directive.status == "sent"
    assert directive.target_type == "tmux"
    assert directive.task_ref == ""
    assert directive.tmux_server == "default"
    assert directive.session_name == "manual-session"
    assert directive.window == 1
    assert directive.pane == 2
    assert directive.enter == false
    assert directive.message == "please report current status"

    assert_received {:ssh_script, script}
    assert script =~ "jx-send-keys"
    assert script =~ "pane_target='=manual-session:1.2'"
    assert script =~ "send-keys -t \"$pane_target\" -l -- 'please report current status'"
    assert script =~ "\ntrue\n"
    refute script =~ " Enter"
  end

  test "send targets the persisted task session" do
    {:ok, task} =
      Workspace.adopt_tmux_task("saysure",
        session_name: "manual-session",
        worktree_path: "/srv/manual-worktree",
        tmux_server: "default",
        window: 1,
        pane: 2,
        agent_name: "codex"
      )

    assert_received {:ssh_script, _inspect_script}
    assert_received {:ssh_script, _adopt_script}

    assert {:ok, directive} = Workspace.send(task.task_id, "continue with the next failing test")

    assert directive.status == "sent"
    assert directive.target_type == "task"
    assert directive.task_ref == task.task_id
    assert directive.tmux_server == "default"
    assert directive.session_name == "manual-session"
    assert directive.window == 1
    assert directive.pane == 2

    assert_received {:ssh_script, script}
    assert script =~ "jx-send-keys"
    assert script =~ "tmux -L default has-session -t \"$session_target\""
    assert script =~ "pane_target='=manual-session:1.2'"
    assert script =~ "tmux -L default send-keys -t \"$pane_target\" Enter"
  end

  test "adopt_activity_task infers worktree and persists pane target" do
    Process.put(
      :fake_ssh_tmux_panes,
      "manual-session\t1\t2\t%7\t1\t/dev/pts/2\tclaude\t/srv/manual-worktree\tClaude\n"
    )

    {:ok, task} =
      Workspace.adopt_activity_task("saysure",
        session_name: "manual-session",
        tmux_server: "default",
        window: 1,
        pane: 2,
        agent_name: "claude"
      )

    assert task.worktree_path == "/srv/manual-worktree"
    assert task.window == 1
    assert task.pane == 2

    assert_received {:ssh_script, list_panes_script}
    assert list_panes_script =~ "list-panes -a -F"

    assert_received {:ssh_script, inspect_script}
    assert inspect_script =~ "pane_target='=manual-session:1.2'"

    assert_received {:ssh_script, adopt_script}
    assert adopt_script =~ "$session_id:1.2"
  end

  test "list_directives returns audited sends in newest-first order" do
    {:ok, first} = Workspace.send_tmux("build-1", "first-session", "first")
    {:ok, second} = Workspace.send_tmux("build-1", "second-session", "second")

    [latest] = Workspace.list_directives(limit: 1)

    assert latest.directive_id == second.directive_id

    task_filtered =
      Workspace.list_directives(task_ref: first.task_ref, limit: 10)

    assert Enum.map(task_filtered, & &1.directive_id) == [
             second.directive_id,
             first.directive_id
           ]
  end

  test "list_activity joins tmux panes to owning processes by tty" do
    Process.put(
      :fake_ssh_tmux_pane_discovery,
      "default\tmanual-session\t0\t0\t%7\t1\t/dev/pts/1\tnode\t/srv/repos/saysure\tCodex\n"
    )

    Process.put(
      :fake_ssh_processes,
      """
        PID  PPID STAT TTY      COMMAND
        19      1 T    pts/1    ssh old-host
        20      1 S+   pts/1    node /usr/local/bin/codex
        21     20 S+   pts/1    /usr/local/lib/codex/codex
        22      1 S+   pts/2    ssh build-1-remote
        23      1 S    ??       /Applications/Codex.app/Contents/MacOS/Codex
      """
    )

    {:ok, report} = Workspace.list_activity(host_name: "build-1")

    assert report.errors == []

    assert Enum.map(
             report.activity,
             &{&1.session, &1.tty, &1.kind, &1.process_pid, &1.process_command}
           ) == [
             {"manual-session", "/dev/pts/1", "codex", 21, "/usr/local/lib/codex/codex"},
             {"", "pts/2", "ssh", 22, "ssh build-1-remote"}
           ]
  end

  test "list_activity can include background process helpers" do
    Process.put(:fake_ssh_tmux_pane_discovery, "")

    {:ok, report} = Workspace.list_activity(all_processes: true)

    assert Enum.any?(report.activity, &(&1.tty == "??" and &1.kind == "codex"))
  end

  test "list_activity keeps background process-only agents distinct by pid" do
    Process.put(:fake_ssh_tmux_pane_discovery, "")

    Process.put(
      :fake_ssh_processes,
      """
        PID  PPID STAT TTY      COMMAND
        31      1 S    ??       /usr/local/bin/codex exec
        32      1 S    ??       /usr/local/bin/claude
      """
    )

    {:ok, report} = Workspace.list_activity(host_name: "build-1", all_processes: true)

    assert Enum.map(report.activity, &{&1.kind, &1.process_pid, &1.tty}) == [
             {"codex", 31, "??"},
             {"claude", 32, "??"}
           ]
  end

  test "attach_tmux attaches to a raw host tmux session" do
    assert :ok = Workspace.attach_tmux("build-1", "manual-session")

    assert_received {:ssh_attach, "manual-session", [tmux_server: "jx"]}
  end

  test "attach_tmux and stop_tmux can target a non-managed tmux server" do
    assert :ok = Workspace.attach_tmux("build-1", "manual-session", tmux_server: "default")
    assert :ok = Workspace.stop_tmux("build-1", "manual-session", tmux_server: "default")

    assert_received {:ssh_attach, "manual-session", [tmux_server: "default"]}
    assert_received {:ssh_script, script}
    assert script =~ "tmux -L default has-session -t"
    assert script =~ "tmux -L default kill-session -t"
  end

  test "list_tmux_sessions can scan all tmux servers on a host" do
    Process.put(
      :fake_ssh_tmux_discovery,
      "jx\tmanaged-session\t1700000000\t0\t1\t/srv/agent\n" <>
        "default\tdefault-session\t1700000100\t1\t2\t/srv/repos/saysure\n"
    )

    {:ok, sessions} = Workspace.list_tmux_sessions("build-1", all_tmux: true)

    assert Enum.map(sessions, &{&1.server, &1.name}) == [
             {"jx", "managed-session"},
             {"default", "default-session"}
           ]
  end

  test "adopt_tmux_task registers an existing session without creating a worktree or launch" do
    {:ok, task} =
      Workspace.adopt_tmux_task("saysure",
        session_name: "manual-session",
        worktree_path: "/srv/manual-worktree",
        tmux_server: "default",
        agent_name: "codex"
      )

    assert task.agent_name == "codex"
    assert task.session_name == "manual-session"
    assert task.tmux_server == "default"
    assert task.worktree_path == "/srv/manual-worktree"
    assert task.window == 0
    assert task.pane == 0
    assert task.branch == "feature/adopt"
    assert task.launch_command == ""
    assert task.status == "running"

    assert_received {:ssh_script, inspect_script}
    assert inspect_script =~ "jx-adopt-inspect"

    assert_received {:ssh_script, adopt_script}
    assert adopt_script =~ "jx-adopt-session"
    assert adopt_script =~ "tmux -L default has-session -t"
    assert adopt_script =~ "$session_id:0.0"
    refute adopt_script =~ "worktree add"
    refute adopt_script =~ "send-keys"

    assert Repo.aggregate(Task, :count) == 1
  end

  test "discover_sessions inventories registered host tmux sessions and managed tasks" do
    {:ok, task} = Workspace.assign_task("saysure", "discover me", agent_name: "codex")

    Process.put(
      :fake_ssh_tmux_discovery,
      "jx\t#{task.session_name}\t1700000000\t0\t1\t#{task.worktree_path}\n" <>
        "default\t#{task.session_name}\t1700000050\t0\t1\t/srv/repos/saysure\n" <>
        "default\tmanual-session\t1700000100\t1\t1\t/srv/repos/saysure\n"
    )

    {:ok, report} = Workspace.discover_sessions()

    assert report.errors == []

    assert Enum.map(report.sessions, &{&1.server, &1.session}) == [
             {"jx", task.session_name},
             {"default", task.session_name},
             {"default", "manual-session"}
           ]

    managed =
      Enum.find(
        report.sessions,
        &(&1.server == "jx" and &1.session == task.session_name)
      )

    assert managed.state == "managed"
    assert managed.task_id == task.task_id
    assert managed.project == "saysure"
    assert managed.agent_name == "codex"

    unmanaged = Enum.find(report.sessions, &(&1.session == "manual-session"))
    assert unmanaged.state == "unmanaged"
    assert unmanaged.task_id == nil
    assert unmanaged.project == "saysure"
    assert unmanaged.worktree_path == "/srv/repos/saysure"

    default_same_name =
      Enum.find(report.sessions, &(&1.server == "default" and &1.session == task.session_name))

    assert default_same_name.state == "unmanaged"
    assert default_same_name.task_id == nil
  end

  test "snapshot_sessions can filter by captured work state" do
    Process.put(:fake_ssh_tmux_capture, "Would you like me to run the next command?")

    {:ok, waiting_report} =
      Workspace.snapshot_sessions(host_name: "build-1", type: "agent", work_state: "waiting")

    assert [%{capture: %{work_state: "waiting"}}] = waiting_report.sessions

    {:ok, running_report} =
      Workspace.snapshot_sessions(host_name: "build-1", type: "agent", work_state: "running")

    assert running_report.sessions == []
  end

  test "session observations can persist and query snapshot history" do
    Process.put(:fake_ssh_tmux_capture, "66.4K (25%) · $1.14 ctrl+p commands")

    {:ok, report} = Workspace.snapshot_sessions(host_name: "build-1", type: "agent")

    {:ok, [observation]} = Workspace.record_session_observations(report)

    assert observation.work_state == "idle"
    assert observation.capture_status == "ok"
    assert observation.summary =~ "ctrl+p commands"
    assert observation.snapshot =~ "\"ref\""

    assert [listed] = Workspace.list_session_observations(ref: observation.ref)
    assert listed.id == observation.id
  end

  test "observe_sessions snapshots, saves, and returns current changes" do
    Process.put(:fake_ssh_tmux_capture, "Would you like me to run the next command?")

    {:ok, report} = Workspace.observe_sessions(host_name: "build-1", type: "agent")

    assert report.saved == 1
    assert [%{work_state: "waiting"}] = report.observations
    assert [%{change: "new", work_state: "waiting", needs_attention: true}] = report.changes
  end

  test "session_summary combines current inventory and latest observations" do
    Process.put(:fake_ssh_tmux_capture, "Would you like me to run the next command?")

    {:ok, _report} = Workspace.observe_sessions(host_name: "build-1", type: "agent")

    {:ok, summary} = Workspace.session_summary(host_name: "build-1", type: "agent")

    assert summary.current.total == 1
    assert summary.current.by_type == %{"agent" => 1}
    assert summary.observation_refresh.observed == false
    assert summary.observation_refresh.saved == 0
    assert summary.observations.latest_total >= 1
    assert summary.observations.by_work_state["waiting"] == 1
    assert summary.observations.attention_total == 1
    assert [%{work_state: "waiting"}] = summary.attention
    assert summary.reconciliation.current_observed_total == 1
    assert summary.reconciliation.current_unobserved_total == 0
    assert summary.reconciliation.observed_missing_total == 0
    assert summary.workflow.clusters_total >= 1
    assert [%{total: 1, agents: 1}] = summary.workflow.clusters

    assert Enum.any?(summary.workflow.recommendations, fn recommendation ->
             match?(
               %{
                 id: "rec-" <> _,
                 safety: "safe",
                 priority: "high",
                 kind: "attention",
                 action: "capture-session",
                 reason: "waiting session needs a fresh read-only capture before direction"
               },
               recommendation
             )
           end)

    assert Enum.any?(summary.workflow.recommendations, fn recommendation ->
             match?(
               %{
                 id: "rec-" <> _,
                 safety: "gated",
                 priority: "high",
                 kind: "attention",
                 action: "send-session",
                 reason: "waiting session needs operator direction"
               },
               recommendation
             )
           end)

    assert is_list(summary.stale)
    assert is_map(summary.remote.by_probe_action)
  end

  test "operate returns machine-oriented recommendations and safety buckets" do
    Process.put(:fake_ssh_tmux_capture, "Would you like me to run the next command?")

    {:ok, operation} = Workspace.operate(host_name: "build-1", type: "agent")

    assert operation.mode == "observe"
    assert operation.observation_refresh.saved == 1
    assert operation.state.current.total == 1
    assert operation.state.workflow.clusters_total >= 1
    assert [%{work_state: "waiting"}] = operation.attention

    assert Enum.any?(operation.safe_actions, fn recommendation ->
             match?(
               %{
                 id: "rec-" <> _,
                 safety: "safe",
                 priority: "high",
                 kind: "attention",
                 action: "capture-session"
               },
               recommendation
             )
           end)

    assert Enum.any?(operation.gated_actions, fn recommendation ->
             match?(
               %{
                 id: "rec-" <> _,
                 safety: "gated",
                 priority: "high",
                 kind: "attention",
                 action: "send-session"
               },
               recommendation
             )
           end)

    assert Enum.all?(operation.gated_actions, &(&1.safety == "gated"))
    assert operation.execution.mode == "dry-run"
  end

  test "operate suppresses ignored sessions from recommendations" do
    Process.put(:fake_ssh_tmux_capture, "Would you like me to run the next command?")

    {:ok, snapshot} = Workspace.snapshot_sessions(host_name: "build-1", type: "agent")
    [%{ref: ref}] = snapshot.sessions
    assert {:ok, control} = Workspace.set_session_control(ref, "ignored", note: "leave it alone")
    assert control.mode == "ignored"

    {:ok, operation} = Workspace.operate(host_name: "build-1", type: "agent")

    refute Enum.any?(operation.recommendations, &(&1.ref == ref))

    assert operation.state.workflow.clusters
           |> hd()
           |> Map.fetch!(:refs)
           |> hd()
           |> Map.fetch!(:control_mode) == "ignored"
  end

  test "operate can execute safe capture recommendations" do
    Process.put(:fake_ssh_tmux_capture, "Would you like me to run the next command?")

    {:ok, operation} = Workspace.operate(host_name: "build-1", type: "agent", execute: "safe")

    assert operation.execution.mode == "execute"
    assert operation.execution.requested == "safe"

    assert [
             %{
               action: "capture-session",
               safety: "safe",
               status: "executed",
               capture: %{status: "ok", output: output, summary: summary}
             }
           ] = operation.execution.executed

    assert output =~ "Would you like me to run the next command?"
    assert summary =~ "Would you like me to run the next command?"
    assert operation.execution.skipped == []
    assert operation.execution.audit == %{saved: 1, errors: []}

    assert [
             %OperationExecution{
               requested: "safe",
               action: "capture-session",
               safety: "safe",
               status: "executed",
               result_summary: ^summary,
               result_snapshot: result_snapshot
             }
           ] = Workspace.list_operation_executions()

    assert {:ok, decoded_snapshot} = Jason.decode(result_snapshot)
    assert decoded_snapshot["capture"]["output_redacted"] == true
    assert is_integer(decoded_snapshot["capture"]["output_bytes"])
    refute Map.has_key?(decoded_snapshot["capture"], "output")
  end

  test "manage conservative executes only safe actions" do
    Process.put(:fake_ssh_tmux_capture, "Would you like me to run the next command?")

    {:ok, report} = Workspace.manage(type: "agent", iterations: 1)

    assert report.policy == "conservative"

    assert [%{iteration: 1, status: "ok", executed: 1, skipped: 0, audit: %{saved: 1}}] =
             report.runs
  end

  test "manage conservative records iteration errors without crashing" do
    {:ok, report} = Workspace.manage(host_name: "missing-host", iterations: 1)

    assert report.policy == "conservative"

    assert [
             %{
               iteration: 1,
               status: "error",
               mode: "error",
               observed: 0,
               executed: 0,
               error: "{:host_not_found, \"missing-host\"}"
             }
           ] = report.runs
  end

  test "work_board summarizes controllable sessions and required next action" do
    Process.put(:fake_ssh_tmux_capture, "Would you like me to run the next command?")

    {:ok, board} = Workspace.work_board(host_name: "build-1", type: "agent")

    assert board.observed == true
    assert board.total == 1

    assert [
             %{
               ref: ref,
               type: "agent",
               kind: "codex",
               control_mode: "uncontrolled",
               work_state: "waiting",
               capture_status: "ok",
               allowed_action: "mark-managed",
               can_direct: false,
               reason: "mark managed before directing",
               task: task
             }
           ] = board.items

    assert ref =~ "s-"
    assert task =~ "Would you like me to run the next command?"
  end

  test "work_board exposes process-only local agents as stream adoption candidates" do
    Process.put(:fake_ssh_tmux_pane_discovery, "")

    Process.put(
      :fake_ssh_processes,
      """
        PID  PPID STAT TTY      COMMAND
        42      1 S+   pts/7    /usr/local/bin/codex exec
      """
    )

    {:ok, board} = Workspace.work_board(host_name: "build-1", type: "agent")

    assert [
             %{
               type: "agent",
               kind: "codex",
               allowed_action: "stream-adopt",
               can_direct: false,
               reason: "process-only agent needs managed stream bridge",
               capture_status: "skipped",
               work_state: "unobservable"
             }
           ] = board.items

    {:ok, queue_report} = Workspace.session_queues(host_name: "build-1", type: "agent")

    assert %{
             action: "stream-adopt",
             total: 1,
             by_safety: %{"manual" => 1},
             by_process_role: %{"cli" => 1},
             items: [
               %{
                 host: "build-1",
                 process_role: "cli",
                 reason: "process-only agent needs managed stream bridge"
               }
             ]
           } = Enum.find(queue_report.queues, &(&1.action == "stream-adopt"))
  end

  test "stream_adopt_session plans a managed bridge for process-only agents" do
    Process.put(:fake_ssh_tmux_pane_discovery, "")

    Process.put(
      :fake_ssh_processes,
      """
        PID  PPID STAT TTY      COMMAND
        42      1 S+   pts/7    /usr/local/bin/codex exec
      """
    )

    {:ok, board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = board.items

    assert {:ok,
            %{
              status: "needs-managed-bridge",
              mode: "plan",
              ref: ^ref,
              can_hijack: false,
              can_relaunch: true,
              next_action: %{
                action: "relaunch-managed",
                safety: "manual",
                agent_name: "codex",
                command: command
              },
              session: %{kind: "codex", pid: 42, tty: "pts/7"}
            }} = Workspace.stream_adopt_session(ref, "saysure")

    assert command =~ "jx session stream-adopt #{ref} saysure --agent codex --relaunch"
    assert Repo.aggregate(Task, :count) == 0
  end

  test "stream_adopt_session can relaunch a process-only agent under managed tmux" do
    Process.put(:fake_ssh_tmux_pane_discovery, "")

    Process.put(
      :fake_ssh_processes,
      """
        PID  PPID STAT TTY      COMMAND
        42      1 S+   pts/7    /usr/local/bin/codex exec
      """
    )

    {:ok, board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = board.items

    assert {:ok,
            %{
              status: "relaunched",
              mode: "managed-relaunch",
              ref: ^ref,
              task: %{
                task_id: task_id,
                agent_name: "codex",
                status: "running",
                tmux_server: "jx",
                session_name: session_name,
                log_path: log_path
              },
              next_action: %{action: "send-session", safety: "gated"}
            }} = Workspace.stream_adopt_session(ref, "saysure", relaunch: true)

    assert task_id =~ "task-"
    assert session_name =~ "_codex"
    assert log_path =~ task_id

    task = JX.Tasks.get_task_by_id(task_id)
    assert task.prompt =~ "process-only codex agent"
    assert task.prompt =~ "ref: #{ref}"
    assert task.launch_command =~ "'codex' exec"

    scripts =
      self()
      |> Process.info(:messages)
      |> elem(1)
      |> Enum.flat_map(fn
        {:ssh_script, script} -> [script]
        _message -> []
      end)

    assert Enum.any?(scripts, &String.contains?(&1, "git -C \"$repo\" worktree add"))
    assert Enum.any?(scripts, &String.contains?(&1, "tmux -L 'jx' -f /dev/null pipe-pane"))
  end

  test "stream_adopt_session can plan and relaunch with acpx transport" do
    Process.put(:fake_ssh_tmux_pane_discovery, "")

    Process.put(
      :fake_ssh_processes,
      """
        PID  PPID STAT TTY      COMMAND
        42      1 S+   pts/7    /usr/local/bin/codex exec
      """
    )

    {:ok, board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = board.items

    assert {:ok, %{next_action: %{command: command}}} =
             Workspace.stream_adopt_session(ref, "saysure", agent_transport: "acpx")

    assert command =~
             "jx session stream-adopt #{ref} saysure --agent codex --transport acpx --relaunch"

    assert {:ok, %{status: "relaunched", task: %{task_id: task_id, agent_transport: "acpx"}}} =
             Workspace.stream_adopt_session(ref, "saysure",
               agent_transport: "acpx",
               relaunch: true
             )

    task = JX.Tasks.get_task_by_id(task_id)
    assert task.launch_command =~ "'acpx' --cwd"
    assert task.launch_command =~ "'codex' exec --file"
  end

  test "resume_adopt_session plans a managed relaunch for Zed ACP agents" do
    Process.put(:fake_ssh_tmux_pane_discovery, "")

    Process.put(
      :fake_ssh_processes,
      """
        PID  PPID STAT TTY      COMMAND
        200     1 S    ??       /home/user-a/.zed_server/zed run --pid-file /home/user-a/.local/share/zed/server_state/workspace-10/server.pid
        201   200 S    ??       /home/user-a/.local/share/zed/node/cache/_npx/pkg/node_modules/@anthropic-ai/claude-agent-sdk-linux-x64/claude --output-format stream-json --input-format stream-json --resume 00000000-0000-0000-0000-000000000000
      """
    )

    {:ok, board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = board.items

    assert [
             %{
               allowed_action: "resume-adopt",
               process_role: "acp",
               resume_available: true,
               resume_ref: resume_ref,
               zed_workspace: "workspace-10"
             }
           ] = board.items

    assert resume_ref =~ "resume-"

    assert {:ok,
            %{
              status: "resume-available",
              mode: "plan",
              ref: ^ref,
              can_hijack: false,
              can_resume: true,
              resume_ref: ^resume_ref,
              zed_workspace: "workspace-10",
              next_action: %{action: "resume-relaunch", command: command}
            }} = Workspace.resume_adopt_session(ref, "saysure")

    assert command =~ "jx session resume-adopt #{ref} saysure --agent claude --relaunch"
    assert Repo.aggregate(Task, :count) == 0
  end

  test "resume_adopt_session rejects projects registered on another host" do
    {:ok, _host} =
      Workspace.add_host(%{
        name: "other-1",
        ssh_target: "other@example.test",
        workspace_path: "/srv/other-agent"
      })

    {:ok, _project} =
      Workspace.add_project(%{
        name: "other-project",
        host_name: "other-1",
        repo_path: "/srv/other/repos/project"
      })

    Process.put(:fake_ssh_tmux_pane_discovery, "")

    Process.put(
      :fake_ssh_processes,
      """
        PID  PPID STAT TTY      COMMAND
        200     1 S    ??       /home/user-a/.zed_server/zed run --pid-file /home/user-a/.local/share/zed/server_state/workspace-10/server.pid
        201   200 S    ??       /home/user-a/.local/share/zed/node/cache/_npx/pkg/node_modules/@anthropic-ai/claude-agent-sdk-linux-x64/claude --output-format stream-json --input-format stream-json --resume 00000000-0000-0000-0000-000000000000
      """
    )

    {:ok, board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = board.items

    assert {:error, {:project_host_mismatch, "other-project", "other-1", "build-1"}} =
             Workspace.resume_adopt_session(ref, "other-project")
  end

  test "resume_adopt_session can relaunch a Zed ACP agent with resume context" do
    Process.put(:fake_ssh_tmux_pane_discovery, "")

    Process.put(
      :fake_ssh_processes,
      """
        PID  PPID STAT TTY      COMMAND
        200     1 S    ??       /home/user-a/.zed_server/zed run --pid-file /home/user-a/.local/share/zed/server_state/workspace-10/server.pid
        201   200 S    ??       /home/user-a/.local/share/zed/node/cache/_npx/pkg/node_modules/@anthropic-ai/claude-agent-sdk-linux-x64/claude --output-format stream-json --input-format stream-json --resume 00000000-0000-0000-0000-000000000000
      """
    )

    {:ok, board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = board.items

    assert {:ok,
            %{
              status: "relaunched",
              mode: "resume-relaunch",
              ref: ^ref,
              task: %{task_id: task_id, agent_name: "claude", status: "running"}
            }} = Workspace.resume_adopt_session(ref, "saysure", relaunch: true)

    task = JX.Tasks.get_task_by_id(task_id)
    assert task.prompt =~ "Resume work from a Zed/ACP-launched claude agent"
    assert task.prompt =~ "original cwd: /srv/repos/saysure"
    assert task.launch_command =~ "--resume '00000000-0000-0000-0000-000000000000'"
    assert task.launch_command =~ "cd '/srv/repos/saysure' &&"

    assert task.launch_command =~
             "'/home/user-a/.local/share/zed/node/cache/_npx/pkg/node_modules/@anthropic-ai/claude-agent-sdk-linux-x64/claude' --resume"
  end

  test "work_board marks managed fresh captures as directable" do
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    {:ok, initial_board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = initial_board.items
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed", project: "saysure")

    {:ok, board} =
      Workspace.work_board(host_name: "build-1", type: "agent", control_mode: "managed")

    assert [
             %{
               ref: ^ref,
               control_mode: "managed",
               project: "saysure",
               allowed_action: "send",
               can_direct: true,
               reason: "managed with fresh capture"
             }
           ] = board.items
  end

  test "work_board treats managed agent-like captures as directable" do
    Process.put(
      :fake_ssh_tmux_pane_discovery,
      "default\tremote-agent\t0\t0\t%7\t1\t/dev/pts/1\tssh\t/srv/repos/saysure\tremote shell\n"
    )

    Process.put(
      :fake_ssh_processes,
      """
        PID  PPID STAT TTY      COMMAND
        10      1 S+   pts/1    ssh build-box
      """
    )

    Process.put(:fake_ssh_tmux_capture, "Claude Code v2.1.108\n❯\n⏵⏵ bypass permissions on")

    {:ok, initial_board} = Workspace.work_board(host_name: "build-1")
    session = Enum.find(initial_board.items, &(&1.session_name == "remote-agent"))

    assert session.actions == "attach,capture,adopt"
    assert session.allowed_action == "mark-managed"

    assert {:ok, _control} =
             Workspace.set_session_control(session.ref, "managed", project: "saysure")

    {:ok, board} = Workspace.work_board(host_name: "build-1", control_mode: "managed")
    managed = Enum.find(board.items, &(&1.ref == session.ref))

    assert managed.allowed_action == "send"
    assert managed.can_direct
    assert managed.reason == "managed agent UI capture with fresh capture"
  end

  test "work_board marks ssh pane repo health as remote unverified" do
    repo = init_git_repo!()

    Process.put(
      :fake_ssh_tmux_pane_discovery,
      "default\tremote-agent\t0\t0\t%7\t1\t/dev/pts/1\tssh\t#{repo}\tremote shell\n"
    )

    Process.put(
      :fake_ssh_processes,
      """
        PID  PPID STAT TTY      COMMAND
        10      1 S+   pts/1    ssh build-box
      """
    )

    Process.put(:fake_ssh_tmux_capture, "Claude Code v2.1.108\n❯\n⏵⏵ bypass permissions on")

    {:ok, board} = Workspace.work_board(host_name: "build-1")
    session = Enum.find(board.items, &(&1.session_name == "remote-agent"))

    assert session.git.present == false
    assert session.git.remote_unverified == true
    assert session.git.root == ""

    {:ok, dossier_report} = Workspace.session_dossiers(host_name: "build-1")
    dossier = Enum.find(dossier_report.dossiers, &(&1.ref == session.ref))

    assert "remote-unverified" in dossier.repo.risks
    assert dossier.repo.blockers == []
  end

  test "work_board does not treat issue text mentioning agents as an agent UI" do
    Process.put(
      :fake_ssh_tmux_pane_discovery,
      "default\tgithub\t0\t0\t%7\t1\t/dev/pts/1\tgh\t/srv/repos\tGitHub dashboard\n"
    )

    Process.put(
      :fake_ssh_processes,
      """
        PID  PPID STAT TTY      COMMAND
        10      1 S+   pts/1    gh dash
      """
    )

    Process.put(
      :fake_ssh_tmux_capture,
      "[FEATURE]: SSH-based remote server connections to OpenCode Desktop"
    )

    {:ok, board} = Workspace.work_board(host_name: "build-1")
    session = Enum.find(board.items, &(&1.session_name == "github"))

    assert session.allowed_action == "adopt"
    refute session.can_direct
  end

  test "session_dossiers compact live work with changes and directives" do
    Process.put(:fake_ssh_tmux_capture, "Would you like me to run the next command?")

    {:ok, initial_board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = initial_board.items
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed", project: "saysure")
    assert {:ok, directive} = Workspace.send_session(ref, "report status and blockers")

    {:ok, report} = Workspace.session_dossiers(host_name: "build-1", type: "agent")

    assert report.observed == true
    assert report.observation_refresh.saved == 1

    assert [
             %{
               ref: ^ref,
               control_mode: "managed",
               project: "saysure",
               work_state: "waiting",
               directive_state: "observed-after-send",
               change: %{
                 change: "new",
                 needs_attention: true,
                 work_state: "waiting"
               },
               last_directive: %{
                 directive_id: directive_id,
                 message: "report status and blockers"
               },
               next_action: %{
                 action: "send-session",
                 priority: "high",
                 safety: "gated"
               },
               handoff: %{
                 cautions: cautions,
                 suggested_message: "Report current status, what changed, and the next safe step."
               }
             }
           ] = report.dossiers

    assert directive_id == directive.directive_id
    assert "session needs attention" in cautions

    {:ok, send_report} =
      Workspace.session_dossiers(
        host_name: "build-1",
        project: "saysure",
        type: "agent",
        next_action: "send-session"
      )

    assert [%{ref: ^ref}] = send_report.dossiers

    {:ok, other_project_report} =
      Workspace.session_dossiers(
        host_name: "build-1",
        project: "other-project",
        type: "agent",
        next_action: "send-session"
      )

    assert other_project_report.dossiers == []

    {:ok, queue_report} =
      Workspace.session_queues(
        host_name: "build-1",
        project: "saysure",
        type: "agent",
        queue_limit: 1
      )

    assert %{
             action: "send-session",
             total: 1,
             by_control: %{"managed" => 1},
             items: [%{ref: ^ref}]
           } = Enum.find(queue_report.queues, &(&1.action == "send-session"))

    {:ok, empty_queue_report} =
      Workspace.session_queues(
        host_name: "build-1",
        project: "other-project",
        type: "agent",
        queue_limit: 1
      )

    assert empty_queue_report.queues == []

    {:ok, blocker_report} =
      Workspace.session_dossiers(
        host_name: "build-1",
        type: "agent",
        next_action: "resolve-repo-blocker"
      )

    assert blocker_report.dossiers == []
  end

  test "session_dossiers project filter includes unlabeled sessions under registered repo path" do
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    assert {:ok, report} =
             Workspace.session_dossiers(host_name: "build-1", project: "saysure", type: "agent")

    assert [
             %{
               project: "",
               current_path: "/srv/repos/saysure"
             }
           ] = report.dossiers
  end

  test "session_profiles compare persisted intent with observed session actuals" do
    Process.put(:fake_ssh_tmux_capture, "Would you like me to run the next command?")

    {:ok, initial_board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = initial_board.items
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed", project: "saysure")

    assert {:ok, _profile} =
             Workspace.set_session_profile(ref, %{
               objective: "finish the no-op task",
               expected_completion: "after one status reply",
               next_prompt: "Report current status and next step.",
               prompt_status: "ready",
               summary: "waiting for operator direction"
             })

    assert {:ok, _operator} =
             Workspace.set_operator_profile(%{
               name: "owner",
               preferences: "agent should lead the orchestration"
             })

    {:ok, report} = Workspace.session_profiles(host_name: "build-1", type: "agent")

    assert report.operator.source == "stored"
    assert report.operator.name == "owner"
    assert report.total == 1

    assert [
             %{
               ref: ^ref,
               session: %{control_mode: "managed", can_direct: true},
               planned: %{
                 source: "stored",
                 objective: "finish the no-op task",
                 expected_completion: "after one status reply",
                 prompt_status: "ready"
               },
               actual: %{
                 work_state: "waiting",
                 next_action: %{action: "send-session"}
               },
               comparison: %{
                 state: "ready-to-send",
                 actual_work_state: "waiting"
               },
               next_prompt: %{
                 source: "profile",
                 status: "ready",
                 text: "Report current status and next step."
               },
               next_step: "send chambered prompt",
               coordination: %{
                 mode: "agent-review",
                 agent_can_continue: true,
                 operator_needed: false,
                 review_required: true,
                 next_agent_action: "send chambered prompt"
               }
             }
           ] = report.profiles

    {:ok, ready_report} =
      Workspace.session_profiles(
        host_name: "build-1",
        type: "agent",
        prompt_status: "ready"
      )

    assert [%{ref: ^ref}] = ready_report.profiles

    {:ok, project_report} =
      Workspace.session_profiles(host_name: "build-1", project: "saysure", type: "agent")

    assert [%{ref: ^ref}] = project_report.profiles

    {:ok, empty_project_report} =
      Workspace.session_profiles(host_name: "build-1", project: "other-project", type: "agent")

    assert empty_project_report.profiles == []

    assert {:ok, _profile} =
             Workspace.set_session_profile(ref, %{
               next_prompt: "",
               prompt_status: "blocked"
             })

    {:ok, blocked_profile_report} =
      Workspace.session_profiles(host_name: "build-1", type: "agent")

    assert [
             %{
               comparison: %{state: "blocked", gaps: blocked_gaps},
               next_step: "blocked: finish the no-op task",
               coordination: %{
                 mode: "operator-needed",
                 agent_can_continue: false,
                 operator_needed: true,
                 operator_reason: "profile prompt is blocked"
               }
             }
           ] = blocked_profile_report.profiles

    refute "missing next prompt" in blocked_gaps

    {:ok, queue_report} =
      Workspace.session_queues(host_name: "build-1", type: "agent", queue_limit: 3)

    assert %{
             action: "blocked-profile",
             total: 1,
             items: [%{ref: ^ref, reason: "profile prompt is blocked"}]
           } = Enum.find(queue_report.queues, &(&1.action == "blocked-profile"))

    refute Enum.any?(queue_report.queues, &(&1.action == "send-session"))

    assert {:ok, _profile} =
             Workspace.set_session_profile(ref, %{
               next_prompt: "Report current status and next step.",
               prompt_status: "draft"
             })

    {:ok, draft_queue_report} =
      Workspace.session_queues(host_name: "build-1", type: "agent", queue_limit: 3)

    assert %{
             action: "draft-profile",
             total: 1,
             items: [%{ref: ^ref, reason: "profile prompt is drafted; review or mark ready"}]
           } = Enum.find(draft_queue_report.queues, &(&1.action == "draft-profile"))

    refute Enum.any?(draft_queue_report.queues, &(&1.action == "send-session"))

    assert {:ok, _profile} =
             Workspace.set_session_profile(ref, %{
               next_prompt: "",
               prompt_status: "none",
               lifecycle_status: "done"
             })

    {:ok, done_profile_report} =
      Workspace.session_profiles(host_name: "build-1", type: "agent")

    assert [
             %{
               comparison: %{state: "done", gaps: []},
               next_prompt: %{source: "none", status: "none", text: ""},
               next_step: "done",
               coordination: %{
                 mode: "done",
                 agent_can_continue: false,
                 operator_needed: false,
                 next_agent_action: "done"
               }
             }
           ] = done_profile_report.profiles

    {:ok, done_queue_report} =
      Workspace.session_queues(host_name: "build-1", type: "agent", queue_limit: 3)

    refute Enum.any?(done_queue_report.queues, &(&1.action in ["draft-profile", "send-session"]))
  end

  test "session_profiles track running monitors without drafting prompts" do
    Process.put(
      :fake_ssh_tmux_capture,
      "⏵⏵ accept edits on · 1 monitor · ctrl+t to hide tasks · ↓ to manage"
    )

    {:ok, initial_board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = initial_board.items
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed", project: "saysure")

    assert {:ok, _profile} =
             Workspace.set_session_profile(ref, %{
               objective: "monitor CI",
               expected_completion: "after CI reaches a terminal state",
               prompt_status: "none"
             })

    {:ok, report} = Workspace.session_profiles(host_name: "build-1", type: "agent")

    assert [
             %{
               ref: ^ref,
               actual: %{work_state: "running"},
               comparison: %{state: "tracking", gaps: []},
               next_prompt: %{source: "none", status: "none", text: ""},
               next_step: "observe active work",
               coordination: %{
                 mode: "autonomous-monitoring",
                 agent_can_continue: true,
                 operator_needed: false,
                 review_required: false,
                 next_agent_action: "observe active work"
               }
             }
           ] = report.profiles
  end

  test "session_profiles classify waiting attention before missing prompts" do
    Process.put(:fake_ssh_tmux_capture, "Do you want to proceed?\n ❯ 1. Yes\n   2. No")

    {:ok, initial_board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = initial_board.items
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed", project: "saysure")

    assert {:ok, _profile} =
             Workspace.set_session_profile(ref, %{
               objective: "monitor CI",
               expected_completion: "after command approval resolves",
               prompt_status: "none"
             })

    {:ok, report} = Workspace.session_profiles(host_name: "build-1", type: "agent")

    assert [
             %{
               ref: ^ref,
               actual: %{work_state: "waiting"},
               comparison: %{state: "needs-attention"},
               next_prompt: %{source: "none", status: "none", text: ""},
               next_step: "inspect attention state",
               coordination: %{
                 mode: "agent-review",
                 agent_can_continue: true,
                 operator_needed: false,
                 review_required: true,
                 next_agent_action: "inspect attention state"
               }
             }
           ] = report.profiles
  end

  test "session_profiles do not ask the operator for ignored session intent" do
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    {:ok, initial_board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = initial_board.items
    assert {:ok, _control} = Workspace.set_session_control(ref, "ignored", project: "noise")

    {:ok, report} = Workspace.session_profiles(host_name: "build-1", type: "agent")

    assert [
             %{
               ref: ^ref,
               session: %{control_mode: "ignored"},
               comparison: %{state: "needs-profile"},
               coordination: %{
                 mode: "ignored",
                 agent_can_continue: false,
                 operator_needed: false,
                 operator_reason: ""
               }
             }
           ] = report.profiles
  end

  test "monitor_scan records deduplicated orchestration events" do
    Process.put(:fake_ssh_tmux_capture, "Would you like me to run the next command?")

    {:ok, first} = Workspace.monitor_scan(host_name: "build-1", type: "agent")

    assert first.sessions_total == 1
    assert first.events_saved >= 2
    assert Enum.any?(first.events, &(&1.kind == "queue.snapshot"))
    assert Enum.any?(first.events, &(&1.kind == "session.new"))

    assert events = Workspace.list_monitor_events(limit: 10)
    assert Enum.any?(events, &(&1.kind == "session.new"))

    latest_id = events |> Enum.map(& &1.id) |> Enum.max()

    {:ok, second} = Workspace.monitor_scan(host_name: "build-1", type: "agent")
    assert second.events_saved == 0

    assert [] = Workspace.list_monitor_events(since_id: latest_id, limit: 10)

    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    {:ok, third} = Workspace.monitor_scan(host_name: "build-1", type: "agent")
    assert Enum.any?(third.events, &(&1.kind == "session.changed"))
  end

  test "monitor_scan surfaces open call handoffs as events and notifications" do
    assert {:ok, handoff} =
             Workspace.create_call_handoff(
               %{
                 surface: "call",
                 project: "saysure",
                 ref: "s-target",
                 title: "Operator approval",
                 summary: "Continue async work and report blockers.",
                 decisions: ["continue async"],
                 follow_ups: ["report blockers"]
               },
               brief: false
             )

    {:ok, scan} = Workspace.monitor_scan(host_name: "build-1", type: "agent")

    assert scan.call_handoffs_total == 1
    assert [%CallHandoff{handoff_id: handoff_id}] = scan.call_handoffs
    assert handoff_id == handoff.handoff_id

    assert [%Event{kind: "call.handoff.open", ref: ^handoff_id, project: "saysure"}] =
             Workspace.list_monitor_events(kind: "call.handoff.open", limit: 10)

    assert [%Notification{kind: "call.handoff.open", ref: ^handoff_id, status: "unread"}] =
             Workspace.list_notifications(ref: handoff_id, limit: 10)

    assert {:ok, summary} = Workspace.portfolio_summary(host_name: "build-1", type: "agent")
    assert summary.orchestration.handoffs.open_total == 1

    assert {:ok, closed} = Workspace.close_call_handoff(handoff_id, "handled")
    assert closed.status == "closed"

    assert [%Notification{kind: "call.handoff.open", ref: ^handoff_id, status: "acknowledged"}] =
             Workspace.list_notifications(ref: handoff_id, limit: 10)
  end

  test "monitor_scan surfaces active delegations as events and portfolio state" do
    assert {:ok, delegation} =
             Workspace.create_delegation(%{
               project: "saysure",
               ref: "s-worker",
               title: "Investigate CI failure",
               brief: "Inspect failing logs and return the smallest safe patch.",
               context: ["PR #461 failed Test"],
               constraints: ["Do not touch unrelated files"],
               acceptance: ["Focused tests pass"]
             })

    {:ok, scan} = Workspace.monitor_scan(host_name: "build-1", type: "agent")

    assert scan.delegations_total == 1
    assert [%Delegation{delegation_id: delegation_id}] = scan.delegations
    assert delegation_id == delegation.delegation_id

    assert [%Event{kind: "delegation.open", ref: "s-worker", project: "saysure"}] =
             Workspace.list_monitor_events(kind: "delegation.open", limit: 10)

    assert [%Notification{kind: "delegation.open", ref: "s-worker", status: "unread"}] =
             Workspace.list_notifications(ref: "s-worker", limit: 10)

    assert {:ok, summary} = Workspace.portfolio_summary(host_name: "build-1", type: "agent")
    assert summary.orchestration.delegations.open_total == 1
  end

  test "monitor_scan surfaces completed delegation reviews and timing" do
    assert {:ok, delegation} =
             Workspace.create_delegation(%{
               project: "saysure",
               ref: "s-review",
               title: "Review completed worker output",
               brief: "Return a bounded patch with evidence.",
               context: ["Worker can finish while Dalton is away"],
               constraints: ["Only touch owned files"],
               acceptance: ["Evidence is structured"],
               verification: ["mix test"],
               write_paths: ["lib/example.ex"]
             })

    assert {:ok, completed} =
             Workspace.complete_delegation(delegation.delegation_id,
               worker_summary: "Patched owned file.",
               artifacts: ["lib/example.ex"],
               evidence: [
                 %{
                   command: "mix test",
                   cwd: "/repo",
                   exit_status: 0
                 }
               ]
             )

    {:ok, scan} = Workspace.monitor_scan(host_name: "build-1", type: "agent")

    assert scan.delegations_total == 0
    assert scan.delegation_reviews_total == 1
    assert [%{delegation_id: delegation_id, decision: "accept"}] = scan.delegation_reviews
    assert delegation_id == completed.delegation_id
    assert scan.delegation_timing.samples_total == 1
    assert scan.delegation_timing.pending_reviews.total == 1

    assert [%Event{kind: "delegation.review", ref: "s-review", project: "saysure"}] =
             Workspace.list_monitor_events(kind: "delegation.review", limit: 10)

    assert [%Notification{kind: "delegation.review", ref: "s-review", status: "unread"}] =
             Workspace.list_notifications(ref: "s-review", limit: 10)

    assert {:ok, inbox} = Workspace.orchestrator_inbox(host_name: "build-1", type: "agent")
    assert [%{delegation_id: ^delegation_id}] = inbox.sections.delegation_reviews
  end

  test "apply_call_handoff converts operator decisions into prompts watches and holds" do
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    {:ok, snapshot} = Workspace.snapshot_sessions(host_name: "build-1", type: "agent")
    [%{ref: ref}] = snapshot.sessions
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed", project: "saysure")

    {:ok, prompt_handoff} =
      Workspace.create_call_handoff(
        %{summary: "Operator said continue the implementation.", title: "Continue work"},
        brief: false
      )

    assert {:ok, prompt_apply} =
             Workspace.apply_call_handoff(prompt_handoff.handoff_id,
               action: "prompt",
               ref: ref,
               message: "Continue the implementation and report test results.",
               prompt_status: "ready",
               summary: "operator approved next prompt"
             )

    assert prompt_apply.handoff.status == "applied"
    assert prompt_apply.action.action == "handoff-prompt"
    assert prompt_apply.action.status == "executed"
    assert prompt_apply.action_record.source == "call-handoff"

    assert %SessionProfile{next_prompt: next_prompt, prompt_status: "ready"} =
             Repo.get_by!(SessionProfile, ref: ref)

    assert next_prompt == "Continue the implementation and report test results."

    {:ok, watch_handoff} =
      Workspace.create_call_handoff(
        %{summary: "Watch for completion evidence.", title: "Watch completion"},
        brief: false
      )

    assert {:ok, watch_apply} =
             Workspace.apply_call_handoff(watch_handoff.handoff_id,
               action: "watch",
               ref: ref,
               success_pattern: "Tests: .*0 failures",
               blocker_pattern: "Blocker:",
               mode: "notify",
               goal: "watch for test completion"
             )

    assert watch_apply.handoff.status == "applied"
    assert watch_apply.action.action == "handoff-watch"

    assert [%SessionWatch{status: "active", success_pattern: "Tests: .*0 failures"}] =
             Workspace.list_watches(ref: ref, status: "active")

    {:ok, hold_handoff} =
      Workspace.create_call_handoff(
        %{summary: "Operator asked to hold this session.", title: "Hold work"},
        brief: false
      )

    assert {:ok, hold_apply} =
             Workspace.apply_call_handoff(hold_handoff.handoff_id,
               action: "hold",
               ref: ref,
               reason: "operator wants strategy review"
             )

    assert hold_apply.handoff.status == "applied"
    assert hold_apply.action.action == "handoff-hold"

    assert %SessionProfile{prompt_status: "blocked", strategy: strategy} =
             Repo.get_by!(SessionProfile, ref: ref)

    assert strategy =~ "Held by call handoff"

    assert [
             %OrchestrationAction{source: "call-handoff"},
             %OrchestrationAction{source: "call-handoff"},
             %OrchestrationAction{source: "call-handoff"}
           ] = Workspace.list_orchestration_actions(source: "call-handoff", ref: ref, limit: 10)
  end

  test "orchestrate execute inspects open call handoff surface decisions" do
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    {:ok, snapshot} = Workspace.snapshot_sessions(host_name: "build-1", type: "agent")
    [%{ref: ref}] = snapshot.sessions

    assert {:ok, handoff} =
             Workspace.create_call_handoff(
               %{
                 ref: ref,
                 project: "saysure",
                 title: "Operator call follow-up",
                 summary: "Review the call handoff."
               },
               brief: false
             )

    assert {:ok, report} =
             Workspace.orchestrate(
               consumer: "handoff-surface-test",
               host_name: "build-1",
               type: "agent",
               execute: true,
               ack: false
             )

    assert %{
             state: "",
             prompt_status: "",
             message: "",
             event_ids: event_ids
           } =
             Enum.find(
               report.decisions,
               &(&1.action == "review-call-handoff" and
                   &1.recommendation_id == handoff.handoff_id)
             )

    assert is_list(event_ids)

    assert Enum.any?(
             report.execution.executed,
             &(&1.action == "review-call-handoff" and &1.recommendation_id == handoff.handoff_id)
           )

    assert [%CallHandoff{status: "open"}] = Workspace.list_call_handoffs(ref: ref)
  end

  test "orchestrate execute inspects completed delegation review surface decisions" do
    assert {:ok, delegation} =
             Workspace.create_delegation(%{
               ref: "s-review",
               project: "saysure",
               title: "Worker patch",
               brief: "Inspect worker output.",
               acceptance: ["summary present"]
             })

    assert {:ok, completed} =
             Workspace.complete_delegation(delegation.delegation_id,
               summary: "Patch ready for integration.",
               verification: ["focused tests passed"]
             )

    assert {:ok, report} =
             Workspace.orchestrate(
               consumer: "delegation-surface-test",
               host_name: "build-1",
               type: "agent",
               execute: true,
               ack: false,
               observe: false
             )

    assert Enum.any?(
             report.execution.executed,
             &(&1.action == "decide-delegation-review" and
                 &1.recommendation_id == completed.delegation_id)
           )

    assert [%{delegation_id: delegation_id}] =
             Workspace.delegation_reviews(integration_status: "pending")

    assert delegation_id == completed.delegation_id
  end

  test "monitor event cursor tracks unread events and acknowledgements" do
    Process.put(:fake_ssh_tmux_capture, "Would you like me to run the next command?")

    {:ok, first} = Workspace.monitor_scan(host_name: "build-1", type: "agent")
    assert first.events_saved > 0

    assert {:ok,
            %{
              consumer: "codex-test",
              unread_total: unread_total,
              matching_unread_total: matching_unread_total,
              events: unread_events
            }} =
             Workspace.unread_monitor_events(consumer: "codex-test", limit: 20)

    assert unread_total == first.events_saved
    assert matching_unread_total == first.events_saved
    assert length(unread_events) == first.events_saved

    latest_id = first.events |> Enum.map(& &1.id) |> Enum.max()

    assert {:ok, cursor} =
             Workspace.acknowledge_monitor_events(consumer: "codex-test", to_id: latest_id)

    assert cursor.consumer == "codex-test"
    assert cursor.last_event_id > 0

    assert {:ok, %{events: [], unread_total: 0, matching_unread_total: 0}} =
             Workspace.unread_monitor_events(consumer: "codex-test", limit: 20)

    status = Workspace.monitor_event_status(consumer: "codex-test")
    assert status.caught_up
    assert status.unread_total == 0

    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    {:ok, second} = Workspace.monitor_scan(host_name: "build-1", type: "agent")
    assert second.events_saved > 0

    assert {:ok, %{events: [_ | _], unread_total: unread_after_change}} =
             Workspace.unread_monitor_events(consumer: "codex-test", limit: 20)

    assert unread_after_change == second.events_saved
  end

  test "session watches complete from monitor scan evidence" do
    Process.put(
      :fake_ssh_tmux_capture,
      """
      Commit: f6512508365aeb34d7bb273a4bea2df122f82e04
      Remote verification: local HEAD equals upstream HEAD
      Tests: 22 tests, 0 failures
      """
    )

    {:ok, snapshot} = Workspace.snapshot_sessions(host_name: "build-1", type: "agent")
    [%{ref: ref}] = snapshot.sessions
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed", project: "saysure")

    assert {:ok, watch} =
             Workspace.add_watch(ref, %{
               goal: "watch for commit push completion",
               success_pattern: "Commit: [a-f0-9]{40}",
               blocker_pattern: "blocker"
             })

    assert watch.status == "active"
    assert watch.project == "saysure"

    assert {:ok, scan} = Workspace.monitor_scan(host_name: "build-1", type: "agent")

    assert [
             %{
               watch: %{watch_id: watch_id, status: "completed"},
               previous_status: "active",
               changed?: true
             }
           ] = scan.watch_updates

    assert watch_id == watch.watch_id

    assert [%SessionWatch{watch_id: ^watch_id, status: "completed"}] =
             Workspace.list_watches(status: "completed")

    assert [%Event{kind: "watch.completed", ref: ^ref}] =
             Workspace.list_monitor_events(kind: "watch.completed", limit: 10)
  end

  test "prompt mode watches chamber the next profile prompt after success" do
    Process.put(
      :fake_ssh_tmux_capture,
      """
      Local tests passed.
      Ready for follow-up.
      """
    )

    {:ok, snapshot} = Workspace.snapshot_sessions(host_name: "build-1", type: "agent")
    [%{ref: ref}] = snapshot.sessions
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed", project: "saysure")

    assert {:ok, watch} =
             Workspace.add_watch(ref, %{
               mode: "prompt",
               goal: "continue after local verification",
               success_pattern: "Local tests passed",
               prompt: "Summarize the diff and prepare the next scoped patch."
             })

    assert {:ok, scan} = Workspace.monitor_scan(host_name: "build-1", type: "agent")

    assert [
             %{
               watch: %{watch_id: watch_id, status: "completed"},
               profile_action: %{
                 action: "chamber-prompt",
                 status: "executed",
                 prompt_status: "draft"
               }
             }
           ] = scan.watch_updates

    assert watch_id == watch.watch_id

    assert [
             %{
               action: "chamber-prompt",
               status: "executed",
               watch_id: ^watch_id,
               ref: ^ref
             }
           ] = scan.watch_actions

    profile = Repo.get_by(SessionProfile, ref: ref)
    assert profile.next_prompt == "Summarize the diff and prepare the next scoped patch."
    assert profile.prompt_status == "draft"
    assert profile.strategy =~ "Chambered by watch #{watch_id}"
  end

  test "hold mode watches block the profile for review after blocker evidence" do
    Process.put(
      :fake_ssh_tmux_capture,
      """
      Blocker: SSH auth failed before task assignment.
      """
    )

    {:ok, snapshot} = Workspace.snapshot_sessions(host_name: "build-1", type: "agent")
    [%{ref: ref}] = snapshot.sessions
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed", project: "saysure")

    assert {:ok, watch} =
             Workspace.add_watch(ref, %{
               mode: "hold",
               goal: "stop when host setup fails",
               blocker_pattern: "SSH auth failed"
             })

    assert {:ok, scan} = Workspace.monitor_scan(host_name: "build-1", type: "agent")

    assert [
             %{
               watch: %{watch_id: watch_id, status: "blocked"},
               profile_action: %{action: "hold-profile", status: "executed"}
             }
           ] = scan.watch_updates

    assert watch_id == watch.watch_id

    profile = Repo.get_by(SessionProfile, ref: ref)
    assert profile.next_prompt == ""
    assert profile.prompt_status == "blocked"
    assert profile.strategy =~ "Held by watch #{watch_id}"
    assert profile.notes =~ "blocker matched"

    assert [%Event{kind: "watch.blocked", ref: ^ref}] =
             Workspace.list_monitor_events(kind: "watch.blocked", limit: 10)

    assert [%Notification{kind: "watch.blocked", ref: ^ref, status: "unread"}] =
             Workspace.list_notifications(ref: ref, limit: 10)
  end

  test "orchestrate plans ready profile prompts without sending by default" do
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    {:ok, initial_board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = initial_board.items
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed", project: "saysure")

    assert {:ok, _profile} =
             Workspace.set_session_profile(ref, %{
               objective: "finish status handoff",
               expected_completion: "after one reply",
               next_prompt: "Report current status and next step.",
               prompt_status: "ready"
             })

    assert {:ok, report} =
             Workspace.orchestrate(consumer: "orc-test", host_name: "build-1", type: "agent")

    assert report.mode == "dry-run"
    assert report.cursor == nil
    assert report.inbox.unread_total > 0

    assert [
             %{
               action: "send-profile-prompt",
               safety: "gated",
               status: "planned",
               ref: ^ref,
               message: "Report current status and next step."
             }
           ] = report.decisions

    assert report.execution.executed == []
    assert Repo.aggregate(Directive, :count) == 0
  end

  test "orchestrate records durable action queue entries and heartbeat state" do
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    {:ok, initial_board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = initial_board.items
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed", project: "saysure")

    assert {:ok, _profile} =
             Workspace.set_session_profile(ref, %{
               objective: "finish queued action test",
               expected_completion: "after one reply",
               next_prompt: "Report current status and next step.",
               prompt_status: "ready",
               owner: "codex",
               risk_level: "low",
               lifecycle_status: "active",
               current_hypothesis: "session is ready for a status prompt",
               last_evidence: "pane reported ready",
               stale_after_seconds: 900
             })

    assert {:ok, report} =
             Workspace.orchestrate(
               consumer: "queue-heartbeat-test",
               host_name: "build-1",
               type: "agent",
               interval_ms: 15_000
             )

    assert report.action_queue.planned.saved == 1
    assert report.action_queue.results.saved == 1
    assert report.heartbeat.consumer == "queue-heartbeat-test"
    assert report.heartbeat.guidance["counts"]["gated_decisions"] == 1
    assert report.heartbeat.guidance["top_priority"] =~ "gated action"
    assert "gated action approval" in report.heartbeat.guidance["operator_needed_for"]

    assert [
             %OrchestrationAction{
               source: "orchestrate",
               action: "send-profile-prompt",
               status: "planned",
               ref: ^ref
             }
           ] = Workspace.list_orchestration_actions(ref: ref)

    heartbeats = Workspace.list_orchestrator_heartbeats(consumer: "queue-heartbeat-test")
    assert [%Heartbeat{consumer: "queue-heartbeat-test", status: "running"}] = heartbeats

    [heartbeat] = heartbeats

    assert {:ok, %{"guidance" => %{"autonomous_next" => autonomous_next, "counts" => counts}}} =
             Jason.decode(heartbeat.scan_snapshot)

    assert is_binary(autonomous_next)
    assert counts["gated_decisions"] == 1

    assert {:ok, profile_report} = Workspace.session_profiles(ref: ref, observe: false, limit: 1)
    assert [profile] = profile_report.profiles
    assert profile.planned.owner == "codex"
    assert profile.planned.risk_level == "low"
    assert profile.planned.lifecycle_status == "active"
  end

  test "session reconciliation links remote observations to local refs" do
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    {:ok, snapshot} = Workspace.snapshot_sessions(host_name: "build-1", type: "agent")
    [%{ref: ref}] = snapshot.sessions

    assert {:ok, _remote} =
             %RemoteSessionObservation{}
             |> RemoteSessionObservation.changeset(%{
               local_ref: ref,
               ssh_target: "developer@example.test",
               tmux_server: "default",
               session_name: "remote-agent",
               current_path: "/srv/repos/saysure",
               windows: 1
             })
             |> Repo.insert()

    assert {:ok, reconciliation} =
             Workspace.session_reconciliation(host_name: "build-1", type: "agent", observe: false)

    assert reconciliation.totals.local_sessions == 1
    assert reconciliation.totals.remote_sessions == 1
    assert reconciliation.totals.matched_remote == 1
    assert [%{matched: true, local_ref: ^ref}] = reconciliation.remote
  end

  test "recovery_plan names explicit reattach work for orphan remote sessions" do
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    assert {:ok, _snapshot} = Workspace.snapshot_sessions(host_name: "build-1", type: "agent")

    assert {:ok, _remote} =
             %RemoteSessionObservation{}
             |> RemoteSessionObservation.changeset(%{
               local_ref: "",
               ssh_target: "developer@example.test",
               registered_host: "build-1",
               tmux_server: "default",
               session_name: "orphan-agent",
               current_path: "/workspace/saysure",
               windows: 1
             })
             |> Repo.insert()

    assert {:ok, recovery} =
             Workspace.recovery_plan(host_name: "build-1", type: "agent", observe: false)

    assert recovery.status == "needs_recovery"

    assert Enum.any?(
             recovery.recommendations,
             &(&1.action == "reattach-remote-session" and
                 &1.target == "developer@example.test/default/orphan-agent")
           )

    assert {:ok, inbox} = Workspace.orchestrator_inbox(host_name: "build-1", type: "agent")
    assert inbox.sections.recovery.status == "needs_recovery"
  end

  test "policy overview encodes autonomous release boundaries" do
    policy = Workspace.policy_overview()

    assert Enum.any?(policy.safety_tiers, &(&1.id == "gated"))
    assert Enum.any?(policy.release_rules, &(&1.action == "push" and &1.decision == "allowed"))
    assert Workspace.policy_check("force_push").confirmation == "required"
  end

  test "orchestrate skips ignored sessions" do
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    {:ok, initial_board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = initial_board.items
    assert {:ok, _control} = Workspace.set_session_control(ref, "ignored", project: "saysure")

    assert {:ok, _profile} =
             Workspace.set_session_profile(ref, %{
               objective: "finish status handoff",
               expected_completion: "after one reply",
               next_prompt: "Report current status and next step.",
               prompt_status: "ready"
             })

    assert {:ok, report} =
             Workspace.orchestrate(
               consumer: "orc-ignored-test",
               host_name: "build-1",
               type: "agent"
             )

    assert report.decisions == []
    assert report.execution.executed == []
  end

  test "orchestrate ack advances only through returned event batch" do
    Process.put(:fake_ssh_tmux_capture, "Would you like me to run the next command?")

    {:ok, first} = Workspace.monitor_scan(host_name: "build-1", type: "agent")
    assert first.events_saved > 1

    assert {:ok, report} =
             Workspace.orchestrate(
               consumer: "orc-limited-test",
               host_name: "build-1",
               type: "agent",
               event_limit: 1,
               ack: true
             )

    [returned_event] = report.inbox.events
    assert report.inbox.latest_event_id > returned_event.id
    assert report.cursor.last_event_id == returned_event.id
  end

  test "orchestrate execute bootstraps missing profiles as safe work" do
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    assert {:ok, report} =
             Workspace.orchestrate(
               consumer: "orc-profile-test",
               host_name: "build-1",
               type: "agent",
               execute: true
             )

    assert [
             %{
               action: "update-profile",
               status: "executed",
               result_summary: "profile updated"
             }
           ] = report.execution.executed

    assert [profile] = Repo.all(SessionProfile)
    assert profile.objective == "Track this session and determine the next safe action."
    assert profile.expected_completion == "After the next observation or chambered prompt."
    assert profile.prompt_status == "none"
  end

  test "orchestrate can send ready prompts and acknowledge processed events" do
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    {:ok, initial_board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = initial_board.items
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed", project: "saysure")

    assert {:ok, _profile} =
             Workspace.set_session_profile(ref, %{
               objective: "finish status handoff",
               expected_completion: "after one reply",
               next_prompt: "Report current status and next step.",
               prompt_status: "ready"
             })

    assert {:ok, report} =
             Workspace.orchestrate(
               consumer: "orc-exec-test",
               host_name: "build-1",
               type: "agent",
               execute: true,
               yes: true
             )

    assert report.mode == "execute+ack"
    assert report.cursor.last_event_id == report.inbox.latest_event_id

    assert [
             %{
               action: "send-profile-prompt",
               status: "executed",
               directive_id: "dir-" <> _suffix
             }
           ] = report.execution.executed

    assert Repo.aggregate(Directive, :count) == 1
    assert Repo.get_by(SessionProfile, ref: ref).prompt_status == "sent"
  end

  test "orchestrate does not send ready prompts into running sessions" do
    Process.put(:fake_ssh_tmux_capture, "✳ Tempering... (1m 10s · ↑ 2.5k tokens)")

    {:ok, initial_board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = initial_board.items
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed", project: "saysure")

    assert {:ok, _profile} =
             Workspace.set_session_profile(ref, %{
               objective: "finish status handoff",
               expected_completion: "after one reply",
               next_prompt: "Report current status and next step.",
               prompt_status: "ready"
             })

    assert {:ok, report} =
             Workspace.orchestrate(
               consumer: "orc-running-test",
               host_name: "build-1",
               type: "agent",
               execute: true,
               yes: true
             )

    assert report.decisions == []
    assert report.execution.executed == []
    assert Repo.aggregate(Directive, :count) == 0
    assert Repo.get_by(SessionProfile, ref: ref).prompt_status == "ready"
  end

  test "orchestrate can execute observe decisions and clear sent prompt state" do
    prompt = "Report current status and next step."
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    {:ok, initial_board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = initial_board.items
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed", project: "saysure")

    assert {:ok, _profile} =
             Workspace.set_session_profile(ref, %{
               objective: "finish status handoff",
               expected_completion: "after one reply",
               next_prompt: prompt,
               prompt_status: "sent"
             })

    assert {:ok, %Directive{}} = Workspace.send_session(ref, prompt)

    Process.put(
      :fake_ssh_tmux_capture,
      """
      ❯ #{prompt}

      Current Status
      No code changes, pushes, merges, or rebases performed.
      ⏵⏵ accept edits on (shift+tab to cycle) · PR #460 · esc to interrupt · ctrl+t to hide tasks
      """
    )

    assert {:ok, report} =
             Workspace.orchestrate(
               consumer: "orc-observe-test",
               host_name: "build-1",
               type: "agent",
               execute: true,
               min_observe_age_seconds: 0
             )

    assert [
             %{
               action: "observe",
               status: "executed",
               result_summary: "observed 1 session",
               observations_saved: 1
             }
           ] = report.execution.executed

    profile = Repo.get_by(SessionProfile, ref: ref)
    assert profile.prompt_status == "none"
    assert profile.next_prompt == ""
    assert Repo.aggregate(SessionObservation, :count) == 2
  end

  test "orchestrate keeps sent state when observe sees no new answer after directive" do
    prompt = "Report current status and next step."
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    {:ok, initial_board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = initial_board.items
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed", project: "saysure")

    assert {:ok, _profile} =
             Workspace.set_session_profile(ref, %{
               objective: "finish status handoff",
               expected_completion: "after one reply",
               next_prompt: prompt,
               prompt_status: "sent"
             })

    assert {:ok, %Directive{}} = Workspace.send_session(ref, prompt)

    Process.put(
      :fake_ssh_tmux_capture,
      """
      Previous answer with useful status.

      ❯ #{prompt}

      ───────────────────────────────────────────────────────────────────────────
        ⏵⏵ accept edits on (shift+tab to cycle) · PR #460 · ctrl+t to hide tasks
      """
    )

    assert {:ok, report} =
             Workspace.orchestrate(
               consumer: "orc-observe-chrome-test",
               host_name: "build-1",
               type: "agent",
               execute: true,
               min_observe_age_seconds: 0
             )

    assert [
             %{
               action: "observe",
               status: "skipped",
               reason: "observation did not contain a meaningful session response yet",
               observations_saved: 1
             }
           ] = report.execution.skipped

    profile = Repo.get_by(SessionProfile, ref: ref)
    assert profile.prompt_status == "sent"
    assert profile.next_prompt == prompt
    assert Repo.aggregate(SessionObservation, :count) > 0
  end

  test "orchestrate clears sent state when a completed response scrolls past the directive marker" do
    prompt = "Run the coverage check and report the result."
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    {:ok, initial_board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = initial_board.items
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed", project: "saysure")

    assert {:ok, _profile} =
             Workspace.set_session_profile(ref, %{
               objective: "finish status handoff",
               expected_completion: "after coverage completes",
               next_prompt: prompt,
               prompt_status: "sent"
             })

    assert {:ok, %Directive{}} = Workspace.send_session(ref, prompt)

    Process.put(
      :fake_ssh_tmux_capture,
      """
      Status — coverage check completed

      Changed files:
      - test/example_test.exs

      Test results:
      29 tests, 0 failures

      Ready to proceed with the next target.
      ⏵⏵ accept edits on (shift+tab to cycle) · PR #460 · ctrl+t to hide tasks
      """
    )

    assert {:ok, report} =
             Workspace.orchestrate(
               consumer: "orc-observe-truncated-test",
               host_name: "build-1",
               type: "agent",
               execute: true,
               min_observe_age_seconds: 0
             )

    assert [
             %{
               action: "observe",
               status: "executed",
               result_summary: "observed 1 session"
             }
           ] = report.execution.executed

    profile = Repo.get_by(SessionProfile, ref: ref)
    assert profile.prompt_status == "none"
    assert profile.next_prompt == ""
  end

  test "orchestrate keeps sent state when observe sees a running background shell" do
    prompt = "Run the coverage check and report the result."
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    {:ok, initial_board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = initial_board.items
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed", project: "saysure")

    assert {:ok, _profile} =
             Workspace.set_session_profile(ref, %{
               objective: "finish status handoff",
               expected_completion: "after coverage completes",
               next_prompt: prompt,
               prompt_status: "sent"
             })

    assert {:ok, %Directive{}} = Workspace.send_session(ref, prompt)

    Process.put(
      :fake_ssh_tmux_capture,
      """
      ❯ #{prompt}

      Bash(MIX_ENV=test mix test --cover)
        ⎿  Running in the background (↓ to manage)

      ✻ Cogitated for 4m 12s · 1 shell still running
      ⏵⏵ accept edits on · 1 shell · ctrl+t to hide tasks · ↓ to manage
      """
    )

    assert {:ok, report} =
             Workspace.orchestrate(
               consumer: "orc-observe-running-test",
               host_name: "build-1",
               type: "agent",
               execute: true,
               min_observe_age_seconds: 0
             )

    assert [
             %{
               action: "observe",
               status: "skipped",
               reason: "observation did not contain a meaningful session response yet",
               observations_saved: 1
             }
           ] = report.execution.skipped

    profile = Repo.get_by(SessionProfile, ref: ref)
    assert profile.prompt_status == "sent"
    assert profile.next_prompt == prompt
  end

  test "orchestrate keeps sent state when observe sees active thinking output" do
    prompt = "Fix the scoped Credo failures and report the result."
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    {:ok, initial_board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = initial_board.items
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed", project: "saysure")

    assert {:ok, _profile} =
             Workspace.set_session_profile(ref, %{
               objective: "fix scoped credo failures",
               expected_completion: "after credo passes",
               next_prompt: prompt,
               prompt_status: "sent"
             })

    assert {:ok, %Directive{}} = Workspace.send_session(ref, prompt)

    Process.put(
      :fake_ssh_tmux_capture,
      """
      ❯ #{prompt}

      ⏺ Thinking
        ⎿  Working through it…

      ⏵⏵ accept edits on (shift+tab to cycle) · PR #460 · esc to interrupt · ctrl+t to hide tasks
      """
    )

    assert {:ok, report} =
             Workspace.orchestrate(
               consumer: "orc-observe-thinking-test",
               host_name: "build-1",
               type: "agent",
               execute: true,
               min_observe_age_seconds: 0
             )

    assert [
             %{
               action: "observe",
               status: "skipped",
               reason: "observation did not contain a meaningful session response yet",
               observations_saved: 1
             }
           ] = report.execution.skipped

    profile = Repo.get_by(SessionProfile, ref: ref)
    assert profile.prompt_status == "sent"
    assert profile.next_prompt == prompt
  end

  test "orchestrate keeps sent state when observe sees a command approval prompt" do
    prompt = "Commit and push the scoped Credo fix."
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    {:ok, initial_board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = initial_board.items
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed", project: "saysure")

    assert {:ok, _profile} =
             Workspace.set_session_profile(ref, %{
               objective: "commit scoped credo fix",
               expected_completion: "after commit and push",
               next_prompt: prompt,
               prompt_status: "sent"
             })

    assert {:ok, %Directive{}} = Workspace.send_session(ref, prompt)

    Process.put(
      :fake_ssh_tmux_capture,
      """
      ❯ #{prompt}

      Bash command

         git commit -m "test: fix Credo violations"

      This command requires approval

      Do you want to proceed?
       ❯ 1. Yes
         2. Yes, and don't ask again for: git commit *
         3. No

      Esc to cancel · Tab to amend · ctrl+e to explain
      """
    )

    assert {:ok, report} =
             Workspace.orchestrate(
               consumer: "orc-observe-approval-test",
               host_name: "build-1",
               type: "agent",
               execute: true,
               min_observe_age_seconds: 0
             )

    assert [
             %{
               action: "observe",
               status: "skipped",
               reason: "observation did not contain a meaningful session response yet",
               observations_saved: 1
             }
           ] = report.execution.skipped

    profile = Repo.get_by(SessionProfile, ref: ref)
    assert profile.prompt_status == "sent"
    assert profile.next_prompt == prompt
  end

  test "orchestrate keeps sent state when observe sees only tool output after directive" do
    prompt = "Monitor PR #460 CI for commit 2bc15e02."
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    {:ok, initial_board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = initial_board.items
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed", project: "saysure")

    assert {:ok, _profile} =
             Workspace.set_session_profile(ref, %{
               objective: "monitor CI",
               expected_completion: "after final grouped CI report",
               next_prompt: prompt,
               prompt_status: "sent"
             })

    assert {:ok, %Directive{}} = Workspace.send_session(ref, prompt)

    Process.put(
      :fake_ssh_tmux_capture,
      """
      ❯ #{prompt}

      ⏺ Bash(gh pr checks 460 --repo acme-corp/example-project)
        ⎿  Check Coverage on Changed Files    pending 0
           Compile & Verify                   pending 0

      ⏵⏵ accept edits on (shift+tab to cycle) · PR #460 · ctrl+t to hide tasks
      """
    )

    assert {:ok, report} =
             Workspace.orchestrate(
               consumer: "orc-observe-tool-output-test",
               host_name: "build-1",
               type: "agent",
               execute: true,
               min_observe_age_seconds: 0
             )

    assert [
             %{
               action: "observe",
               status: "skipped",
               reason: "observation did not contain a meaningful session response yet",
               observations_saved: 1
             }
           ] = report.execution.skipped

    profile = Repo.get_by(SessionProfile, ref: ref)
    assert profile.prompt_status == "sent"
    assert profile.next_prompt == prompt
  end

  test "orchestrate keeps sent state while interruptible progress is visible" do
    prompt = "Fix the scoped Credo failures and report the result."
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    {:ok, initial_board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = initial_board.items
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed", project: "saysure")

    assert {:ok, _profile} =
             Workspace.set_session_profile(ref, %{
               objective: "fix scoped credo failures",
               expected_completion: "after credo passes",
               next_prompt: prompt,
               prompt_status: "sent"
             })

    assert {:ok, %Directive{}} = Workspace.send_session(ref, prompt)

    Process.put(
      :fake_ssh_tmux_capture,
      """
      ❯ #{prompt}

      ✳ Writing context tests…
      ⏵⏵ accept edits on (shift+tab to cycle) · PR #460 · esc to interrupt · ctrl+t to hide tasks
      """
    )

    assert {:ok, report} =
             Workspace.orchestrate(
               consumer: "orc-observe-interrupt-progress-test",
               host_name: "build-1",
               type: "agent",
               execute: true,
               min_observe_age_seconds: 0
             )

    assert [
             %{
               action: "observe",
               status: "skipped",
               reason: "observation did not contain a meaningful session response yet",
               observations_saved: 1
             }
           ] = report.execution.skipped

    profile = Repo.get_by(SessionProfile, ref: ref)
    assert profile.prompt_status == "sent"
    assert profile.next_prompt == prompt
  end

  test "orchestrate keeps sent state when prompt is staged but not submitted" do
    prompt = "Fix the scoped Credo failures and report the result."
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    {:ok, initial_board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = initial_board.items
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed", project: "saysure")

    assert {:ok, _profile} =
             Workspace.set_session_profile(ref, %{
               objective: "fix scoped credo failures",
               expected_completion: "after credo passes",
               next_prompt: prompt,
               prompt_status: "sent"
             })

    assert {:ok, %Directive{}} = Workspace.send_session(ref, prompt)

    Process.put(
      :fake_ssh_tmux_capture,
      """
      Previous completed status report.

      ───────────────────────────────────────────────────────────────────────────
      ❯ [Pasted text #1]Enter
      ───────────────────────────────────────────────────────────────────────────
        ⏵⏵ accept edits on (shift+tab to cycle) · PR #460 · ctrl+t to hide tasks
      """
    )

    assert {:ok, report} =
             Workspace.orchestrate(
               consumer: "orc-observe-staged-prompt-test",
               host_name: "build-1",
               type: "agent",
               execute: true,
               min_observe_age_seconds: 0
             )

    assert [
             %{
               action: "observe",
               status: "skipped",
               reason: "observation did not contain a meaningful session response yet",
               observations_saved: 1
             }
           ] = report.execution.skipped

    profile = Repo.get_by(SessionProfile, ref: ref)
    assert profile.prompt_status == "sent"
    assert profile.next_prompt == prompt
  end

  test "orchestrate observe anchors on the sent profile prompt after approval replies" do
    prompt = "Run the coverage check and report the result."
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    {:ok, initial_board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = initial_board.items
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed", project: "saysure")

    assert {:ok, _profile} =
             Workspace.set_session_profile(ref, %{
               objective: "finish status handoff",
               expected_completion: "after coverage completes",
               next_prompt: prompt,
               prompt_status: "sent"
             })

    assert {:ok, %Directive{}} = Workspace.send_session(ref, prompt)
    assert {:ok, %Directive{message: "1"}} = Workspace.send_session(ref, "1")

    assert {:ok, report} =
             Workspace.orchestrate(
               consumer: "orc-observe-anchor-test",
               host_name: "build-1",
               type: "agent"
             )

    assert [
             %{
               action: "observe",
               directive_message: ^prompt
             }
           ] = report.decisions
  end

  test "orchestrate can execute current observe decisions after cursor is caught up" do
    prompt = "Report current status and next step."
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    {:ok, initial_board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = initial_board.items
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed", project: "saysure")

    assert {:ok, _profile} =
             Workspace.set_session_profile(ref, %{
               objective: "finish status handoff",
               expected_completion: "after one reply",
               next_prompt: prompt,
               prompt_status: "sent"
             })

    assert {:ok, %Directive{}} = Workspace.send_session(ref, prompt)

    assert {:ok, _scan} = Workspace.monitor_scan(host_name: "build-1", type: "agent")
    assert {:ok, _cursor} = Workspace.acknowledge_monitor_events(consumer: "orc-current-test")

    Process.put(
      :fake_ssh_tmux_capture,
      """
      ❯ #{prompt}

      Current Status
      Ready for the next instruction.
      """
    )

    assert {:ok, report} =
             Workspace.orchestrate(
               consumer: "orc-current-test",
               host_name: "build-1",
               type: "agent",
               execute: true,
               min_observe_age_seconds: 0
             )

    assert report.inbox.returned == 0

    assert [
             %{
               action: "observe",
               status: "executed",
               result_summary: "observed 1 session"
             }
           ] = report.execution.executed

    assert Repo.get_by(SessionProfile, ref: ref).prompt_status == "none"
  end

  test "orchestrate does not clear sent state when directive is too recent to observe" do
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    {:ok, initial_board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = initial_board.items
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed", project: "saysure")

    assert {:ok, _profile} =
             Workspace.set_session_profile(ref, %{
               objective: "finish status handoff",
               expected_completion: "after one reply",
               next_prompt: "Report current status and next step.",
               prompt_status: "sent"
             })

    assert {:ok, %Directive{}} =
             Workspace.send_session(ref, "Report current status and next step.")

    assert {:ok, report} =
             Workspace.orchestrate(
               consumer: "orc-observe-age-test",
               host_name: "build-1",
               type: "agent",
               execute: true,
               min_observe_age_seconds: 999
             )

    assert [
             %{
               action: "observe",
               status: "skipped",
               reason: "directive is too recent to observe" <> _suffix
             }
           ] = report.execution.skipped

    assert Repo.get_by(SessionProfile, ref: ref).prompt_status == "sent"
  end

  test "orchestrate can mark directable draft prompts ready without sending" do
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    {:ok, initial_board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = initial_board.items
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed", project: "saysure")

    assert {:ok, _profile} =
             Workspace.set_session_profile(ref, %{
               objective: "finish status handoff",
               expected_completion: "after one reply",
               next_prompt: "Report current status and next step.",
               prompt_status: "draft"
             })

    assert {:ok, report} =
             Workspace.orchestrate(
               consumer: "orc-ready-test",
               host_name: "build-1",
               type: "agent",
               execute: true
             )

    assert [
             %{
               action: "mark-prompt-ready",
               status: "executed",
               result_summary: "prompt marked ready"
             }
           ] = report.execution.executed

    profile = Repo.get_by(SessionProfile, ref: ref)
    assert profile.prompt_status == "ready"
    assert profile.next_prompt == "Report current status and next step."
    assert Repo.aggregate(Directive, :count) == 0
  end

  test "orchestrate observes stale ready profiles without clearing chambered prompt" do
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    {:ok, initial_board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = initial_board.items
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed", project: "saysure")

    {:ok, snapshot} = Workspace.snapshot_sessions(host_name: "build-1", type: "agent")
    assert {:ok, [_observation]} = Workspace.record_session_observations(snapshot)

    old_at = DateTime.add(DateTime.utc_now(), -120, :second)
    Repo.update_all(SessionObservation, set: [inserted_at: old_at])

    prompt = "Continue with the scoped follow-up and report results."

    assert {:ok, _profile} =
             Workspace.set_session_profile(ref, %{
               objective: "keep worker moving",
               expected_completion: "after scoped follow-up",
               next_prompt: prompt,
               prompt_status: "ready",
               stale_after_seconds: 60,
               last_seen_at: old_at
             })

    Process.put(:fake_ssh_tmux_capture, "Still idle and ready.")

    assert {:ok, report} =
             Workspace.orchestrate(
               consumer: "orc-stale-ready-test",
               host_name: "build-1",
               type: "agent",
               observe: false,
               execute: true,
               yes: true
             )

    assert [
             %{
               action: "observe",
               status: "executed",
               result_summary: "observed 1 session"
             }
           ] = report.execution.executed

    assert Repo.aggregate(Directive, :count) == 0

    profile = Repo.get_by(SessionProfile, ref: ref)
    assert profile.prompt_status == "ready"
    assert profile.next_prompt == prompt
    assert Repo.aggregate(SessionObservation, :count) == 2
  end

  test "orchestrate does not auto-ready generic suggested draft prompts" do
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    {:ok, initial_board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = initial_board.items
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed", project: "saysure")

    assert {:ok, _profile} =
             Workspace.set_session_profile(ref, %{
               objective: "finish status handoff",
               expected_completion: "after one reply",
               next_prompt: "",
               prompt_status: "none"
             })

    assert {:ok, report} =
             Workspace.orchestrate(
               consumer: "orc-suggested-ready-test",
               host_name: "build-1",
               type: "agent",
               execute: true
             )

    assert [
             %{
               action: "update-profile",
               status: "executed"
             }
           ] = report.execution.executed

    refute Enum.any?(
             report.decisions,
             &(&1.action in ["mark-prompt-ready", "send-profile-prompt"])
           )

    profile = Repo.get_by(SessionProfile, ref: ref)
    assert profile.prompt_status == "none"
    assert profile.next_prompt == ""

    assert {:ok, repeated_report} =
             Workspace.orchestrate(
               consumer: "orc-suggested-ready-test",
               host_name: "build-1",
               type: "agent",
               execute: true
             )

    assert repeated_report.execution.executed == []
  end

  test "orchestrate does not emit manual hold decisions for already parked profiles" do
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    {:ok, initial_board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = initial_board.items
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed", project: "saysure")

    assert {:ok, _profile} =
             Workspace.set_session_profile(ref, %{
               objective: "wait for explicit strategy",
               expected_completion: "after a concrete next step is chosen",
               next_prompt: "Hold until the repo decision is made.",
               prompt_status: "blocked"
             })

    assert {:ok, report} =
             Workspace.orchestrate(
               consumer: "orc-parked-blocked-test",
               host_name: "build-1",
               type: "agent",
               execute: true,
               auto_plan: true
             )

    assert report.decisions == []
    assert report.execution.executed == []
    assert report.execution.skipped == []

    profile = Repo.get_by(SessionProfile, ref: ref)
    assert profile.prompt_status == "blocked"
    assert profile.next_prompt == "Hold until the repo decision is made."
  end

  test "orchestrate auto-plans a safe continuation from a completed report" do
    Process.put(
      :fake_ssh_tmux_capture,
      """
      Current Status
      Plantings tests added and targeted suite is green.

      Next concrete step
      Fix the Plantings nil-guard bug, mirroring the CropPlans fix.
      Run mix format and mix test test/one/farms/plantings_test.exs.
      """
    )

    {:ok, initial_board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = initial_board.items
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed", project: "saysure")

    assert {:ok, _profile} =
             Workspace.set_session_profile(ref, %{
               objective: "continue coverage work",
               expected_completion: "after next targeted patch",
               next_prompt: "",
               prompt_status: "none"
             })

    assert {:ok, report} =
             Workspace.orchestrate(
               consumer: "orc-auto-plan-test",
               host_name: "build-1",
               type: "agent",
               execute: true,
               auto_plan: true
             )

    assert [
             %{
               action: "auto-plan-next",
               status: "executed",
               result_summary: "next prompt auto-planned"
             }
           ] = report.execution.executed

    profile = Repo.get_by(SessionProfile, ref: ref)
    assert profile.prompt_status == "ready"
    assert profile.next_prompt =~ "ExampleApp.Plantings.validate_planting_consistency/2"
    assert Repo.aggregate(Directive, :count) == 0
  end

  test "orchestrate auto-holds completed reports that recommend waiting on blockers" do
    Process.put(
      :fake_ssh_tmux_capture,
      """
      Status Report
      CI is not green because of an upstream environmental flake.

      Next concrete step
      Hold. Nothing in this PR can clear the Test failure. Wait for develop to go green.
      """
    )

    {:ok, initial_board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = initial_board.items
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed", project: "saysure")

    assert {:ok, _profile} =
             Workspace.set_session_profile(ref, %{
               objective: "track PR blocker",
               expected_completion: "after upstream CI is green",
               next_prompt: "",
               prompt_status: "none"
             })

    assert {:ok, report} =
             Workspace.orchestrate(
               consumer: "orc-auto-hold-test",
               host_name: "build-1",
               type: "agent",
               execute: true,
               auto_plan: true
             )

    assert [
             %{
               action: "auto-hold",
               status: "executed",
               result_summary: "profile marked blocked for review"
             }
           ] = report.execution.executed

    profile = Repo.get_by(SessionProfile, ref: ref)
    assert profile.prompt_status == "blocked"
    assert profile.next_prompt == ""
    assert profile.strategy =~ "Auto-held by orchestrator"
    assert Repo.aggregate(Directive, :count) == 0

    assert {:ok, review} =
             Workspace.orchestrator_review(ref, host_name: "build-1", type: "agent")

    assert review.recommendation.type == "manual-review"
    assert review.recommendation.safety == "manual"
    assert get_in(review.profile, [:next_prompt, :status]) == "blocked"
    assert Enum.any?(review.commands, &(&1.action == "attach"))
    assert Enum.any?(review.commands, &(&1.action == "hold"))
  end

  test "orchestrator_decide queues prompts and marks manual holds" do
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    {:ok, initial_board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = initial_board.items
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed", project: "saysure")

    assert {:ok, decision} =
             Workspace.orchestrator_decide(ref, %{
               action: "prompt",
               prompt: "Continue the narrow test task.",
               prompt_status: "ready"
             })

    assert decision.action == "prompt"
    assert decision.result_summary == "profile prompt queued"
    profile = Repo.get_by(SessionProfile, ref: ref)
    assert profile.prompt_status == "ready"
    assert profile.next_prompt == "Continue the narrow test task."

    assert {:ok, decision} =
             Workspace.orchestrator_decide(ref, %{
               action: "hold",
               reason: "needs foreground judgment"
             })

    assert decision.action == "hold"
    assert decision.result_summary == "profile marked blocked for review"
    profile = Repo.get_by(SessionProfile, ref: ref)
    assert profile.prompt_status == "blocked"
    assert profile.next_prompt == ""
  end

  test "orchestrator_inbox surfaces planner suggestions separately from judgment items" do
    Process.put(
      :fake_ssh_tmux_capture,
      """
      Next highest-value coverage target
      Recommend: ExampleApp.Harvests — same CRUD pattern, about 16 tests.
      """
    )

    {:ok, initial_board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = initial_board.items
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed", project: "saysure")

    assert {:ok, _profile} =
             Workspace.set_session_profile(ref, %{
               objective: "continue coverage work",
               expected_completion: "after next targeted patch",
               next_prompt: "",
               prompt_status: "none"
             })

    assert {:ok, inbox} =
             Workspace.orchestrator_inbox(host_name: "build-1", type: "agent", limit: 5)

    assert [%{ref: ^ref, reason: "continue next Farms coverage target", prompt: prompt}] =
             inbox.sections.suggestions

    assert prompt =~ "ExampleApp.Harvests"
    assert Enum.any?(inbox.sections.ready, &(&1.ref == ref and not is_nil(&1.suggested_plan)))
  end

  test "portfolio_summary groups active sessions by project and recommends next portfolio action" do
    Process.put(
      :fake_ssh_tmux_capture,
      """
      Current Status
      PR #460 Harvests refactor is complete. Targeted tests: 22 tests, 0 failures.

      Next concrete step
      Commit and push current work after one final diff review.
      """
    )

    {:ok, initial_board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = initial_board.items
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed", project: "saysure")

    assert {:ok, _profile} =
             Workspace.set_session_profile(ref, %{
               objective: "complete PR #460 Harvests work",
               expected_completion: "after commit and push",
               next_prompt: "",
               prompt_status: "blocked",
               notes: "Hold for final diff review, then commit and push."
             })

    assert {:ok, summary} =
             Workspace.portfolio_summary(host_name: "build-1", type: "agent", limit: 5)

    assert summary.totals.registered_projects == 1
    assert summary.totals.active_projects == 1
    assert summary.totals.blocked_sessions == 1

    assert [
             %{
               name: "saysure",
               registered: true,
               host: "build-1",
               sessions_total: 1,
               blocked_total: 1,
               prs: ["#460"],
               next_action: "review diff, commit, and push if scope is clean",
               refs: [%{ref: ^ref, prompt_status: "blocked"}]
             }
           ] = summary.projects
  end

  test "work_board includes local git health for a pane path" do
    repo = init_git_repo!()
    repo_root = run_git!(["-C", repo, "rev-parse", "--show-toplevel"]) |> String.trim()
    File.write!(Path.join(repo, "scratch.txt"), "scratch\n")
    Process.put(:fake_ssh_tmux_pane_discovery, work_board_pane_discovery(repo))
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    {:ok, board} = Workspace.work_board(host_name: "build-1", type: "agent")

    assert [
             %{
               git: %{
                 branch: "main",
                 root: ^repo_root,
                 dirty: true,
                 changes: 1,
                 untracked: 1,
                 submodules: "ok"
               }
             }
           ] = board.items
  end

  test "work_board reports malformed submodule metadata as git health" do
    repo = init_git_repo!()

    File.write!(Path.join(repo, ".gitmodules"), """
    [submodule "Skills"]
      path = Skills
      url = https://example.test/Skills.git
    """)

    run_git!(["-C", repo, "add", ".gitmodules"])

    run_git!([
      "-C",
      repo,
      "update-index",
      "--add",
      "--cacheinfo",
      "160000,a964847ff37ae3a2e8091355e16d2baa4484cc9d,Skills"
    ])

    run_git!([
      "-C",
      repo,
      "update-index",
      "--add",
      "--cacheinfo",
      "160000,77b8f7d20f5ee5d125d285b8228f406b90754944,Tools/Advance-Commerce-CLI"
    ])

    Process.put(:fake_ssh_tmux_pane_discovery, work_board_pane_discovery(repo))
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    {:ok, board} = Workspace.work_board(host_name: "build-1", type: "agent")

    assert [%{git: %{submodules: "error", submodule_error: error}}] = board.items
    assert error =~ "fatal: no submodule mapping found in .gitmodules"
    refute error =~ "Skillsfatal"

    {:ok, dossier_report} =
      Workspace.session_dossiers(
        host_name: "build-1",
        type: "agent",
        next_action: "resolve-repo-blocker"
      )

    assert [%{next_action: %{action: "resolve-repo-blocker"}}] = dossier_report.dossiers

    {:ok, queue_report} =
      Workspace.session_queues(
        host_name: "build-1",
        type: "agent",
        queue_limit: 1
      )

    assert %{
             action: "resolve-repo-blocker",
             total: 1,
             by_safety: %{"manual" => 1},
             items: [%{repo: %{blockers: ["submodules:error"]}}]
           } = Enum.find(queue_report.queues, &(&1.action == "resolve-repo-blocker"))
  end

  test "operate skips gated recommendations without confirmation" do
    Process.put(:fake_ssh_tmux_capture, "Would you like me to run the next command?")

    {:ok, operation} = Workspace.operate(host_name: "build-1", type: "agent")
    gated_id = operation.gated_actions |> List.first() |> Map.fetch!(:id)

    {:ok, execution_operation} =
      Workspace.operate(host_name: "build-1", type: "agent", execute: gated_id)

    assert execution_operation.execution.executed == []

    assert [
             %{
               id: ^gated_id,
               safety: "gated",
               status: "skipped",
               reason: "recommendation requires explicit gated execution"
             }
           ] = execution_operation.execution.skipped

    assert [%OperationExecution{recommendation_id: ^gated_id, status: "skipped"}] =
             Workspace.list_operation_executions(status: "skipped")
  end

  test "operate does not execute unsupported gated actions even with confirmation" do
    Process.put(:fake_ssh_tmux_capture, "Would you like me to run the next command?")

    {:ok, operation} = Workspace.operate(host_name: "build-1", type: "agent")
    gated_id = operation.gated_actions |> List.first() |> Map.fetch!(:id)

    {:ok, execution_operation} =
      Workspace.operate(host_name: "build-1", type: "agent", execute: gated_id, yes: true)

    assert execution_operation.execution.executed == []

    assert [
             %{
               id: ^gated_id,
               action: "send-session",
               safety: "gated",
               status: "skipped",
               reason: "gated execution for this action is not implemented"
             }
           ] = execution_operation.execution.skipped
  end

  test "operate reports stale recommendation ids" do
    {:ok, operation} =
      Workspace.operate(host_name: "build-1", type: "agent", execute: "rec-missing")

    assert [
             %{
               id: "rec-missing",
               status: "skipped",
               reason: "recommendation not found"
             }
           ] = operation.execution.skipped

    assert [%OperationExecution{recommendation_id: "rec-missing", status: "skipped"}] =
             Workspace.list_operation_executions(ref: "")
  end

  test "remote session observations persist probe results" do
    probe = %{
      ssh_target: "build-remote",
      registered_host: "build-1",
      target: "default/ssh:0.0",
      remote_sessions: [
        %{
          server: "default",
          session: "remote-agent",
          created_at: ~U[2026-04-25 12:00:00Z],
          attached: 1,
          windows: 2,
          current_path: "/srv/repos/saysure"
        }
      ]
    }

    recommendation = %{id: "rec-remote", ref: "s-local"}

    assert {:ok, [%RemoteSessionObservation{} = observation]} =
             RemoteSessions.record_probe(probe, recommendation)

    assert observation.ssh_target == "build-remote"
    assert observation.local_ref == "s-local"
    assert observation.recommendation_id == "rec-remote"

    assert [%{session_name: "remote-agent"}] =
             Workspace.list_remote_session_observations(target: "build-remote")
  end

  test "session_summary can refresh observations before summarizing" do
    Process.put(:fake_ssh_tmux_capture, "Would you like me to run the next command?")

    assert Repo.aggregate(SessionObservation, :count) == 0

    {:ok, summary} =
      Workspace.session_summary(host_name: "build-1", type: "agent", observe: true)

    assert summary.observation_refresh == %{
             observed: true,
             saved: 1,
             captured: 1,
             errors: 0
           }

    assert summary.observations.by_work_state["waiting"] == 1
    assert summary.observations.attention_total == 1
    assert [%{change: "new", work_state: "waiting"}] = summary.attention
    assert Repo.aggregate(SessionObservation, :count) == 1
  end

  test "session changes compare latest and previous observations" do
    Process.put(:fake_ssh_tmux_capture, "66.4K (25%) · $1.14 ctrl+p commands")

    {:ok, idle_report} = Workspace.snapshot_sessions(host_name: "build-1", type: "agent")
    {:ok, [%{ref: ref}]} = Workspace.record_session_observations(idle_report)

    Process.put(:fake_ssh_tmux_capture, "Would you like me to run the next command?")

    {:ok, waiting_report} = Workspace.snapshot_sessions(host_name: "build-1", type: "agent")
    {:ok, [%{ref: ^ref}]} = Workspace.record_session_observations(waiting_report)

    assert [
             %{
               ref: ^ref,
               change: "changed",
               work_state: "waiting",
               previous_work_state: "idle",
               needs_attention: true,
               changed_fields: changed_fields
             }
           ] = Workspace.list_session_changes(ref: ref)

    assert "work_state" in changed_fields
    assert "summary" in changed_fields

    assert [%{ref: ^ref}] = Workspace.list_session_changes(ref: ref, attention: true)
  end

  test "session changes can be limited to current observation refs" do
    Process.put(:fake_ssh_tmux_capture, "66.4K (25%) · $1.14 ctrl+p commands")

    {:ok, report} = Workspace.snapshot_sessions(host_name: "build-1", type: "agent")
    {:ok, [%{ref: observed_ref}]} = Workspace.record_session_observations(report)

    assert [%{ref: ^observed_ref}] = Workspace.list_session_changes(refs: [observed_ref])
    assert [] = Workspace.list_session_changes(refs: ["s-missing"])
  end

  test "attention changes only flag currently actionable states" do
    Process.put(:fake_ssh_tmux_capture, "Error: exit code 1")

    {:ok, blocked_report} = Workspace.snapshot_sessions(host_name: "build-1", type: "agent")
    {:ok, [%{ref: ref}]} = Workspace.record_session_observations(blocked_report)

    Process.put(:fake_ssh_tmux_capture, "66.4K (25%) · $1.14 ctrl+p commands")

    {:ok, idle_report} = Workspace.snapshot_sessions(host_name: "build-1", type: "agent")
    {:ok, [%{ref: ^ref}]} = Workspace.record_session_observations(idle_report)

    assert [
             %{
               ref: ^ref,
               previous_work_state: "blocked",
               work_state: "idle",
               needs_attention: false
             }
           ] = Workspace.list_session_changes(ref: ref)

    assert [] = Workspace.list_session_changes(ref: ref, attention: true)
  end

  test "unknown non-agent tmux observations do not need attention" do
    Process.put(
      :fake_ssh_tmux_pane_discovery,
      "default\tshell\t0\t0\t%7\t1\t/dev/pts/1\tzsh\t/srv/repos/saysure\tShell\n"
    )

    Process.put(
      :fake_ssh_processes,
      """
        PID  PPID STAT TTY      COMMAND
        20      1 S+   pts/1    zsh
      """
    )

    Process.put(:fake_ssh_tmux_capture, "custom status line without known signals")

    {:ok, report} = Workspace.observe_sessions(host_name: "build-1", type: "tmux")

    assert report.saved == 1
    assert [%{work_state: "unknown", needs_attention: false}] = report.changes
    assert [] = Workspace.list_session_changes(attention: true)
  end

  test "stale session observations use latest observation per ref" do
    Process.put(:fake_ssh_tmux_capture, "66.4K (25%) · $1.14 ctrl+p commands")

    {:ok, report} = Workspace.snapshot_sessions(host_name: "build-1", type: "agent")
    {:ok, [%{ref: ref, inserted_at: observed_at}]} = Workspace.record_session_observations(report)

    now = DateTime.add(observed_at, 120, :second)

    assert [
             %{
               ref: ^ref,
               work_state: "idle",
               capture_status: "ok",
               stale_seconds: 120,
               needs_attention: false
             }
           ] =
             Workspace.list_stale_session_observations(
               ref: ref,
               stale_after_seconds: 60,
               now: now
             )

    assert [] =
             Workspace.list_stale_session_observations(
               ref: ref,
               stale_after_seconds: 180,
               now: now
             )
  end

  test "broadcast_sessions dry-runs sendable attention targets" do
    Process.put(:fake_ssh_tmux_capture, "Would you like me to run the next command?")

    {:ok, report} =
      Workspace.broadcast_sessions("continue with the next safe step",
        host_name: "build-1",
        type: "agent",
        attention: true
      )

    assert report.dry_run == true
    assert report.errors == []

    assert [
             %{
               status: "dry_run",
               work_state: "waiting",
               capture_status: "ok",
               ref: ref
             }
           ] = report.targets

    assert ref =~ "s-"
    assert Repo.aggregate(Directive, :count) == 0
  end

  test "broadcast_sessions can send to selected targets when executed" do
    Process.put(:fake_ssh_tmux_capture, "Would you like me to run the next command?")

    {:ok, snapshot} = Workspace.snapshot_sessions(host_name: "build-1", type: "agent")
    [%{ref: ref}] = snapshot.sessions
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed")

    {:ok, report} =
      Workspace.broadcast_sessions("continue with the next safe step",
        host_name: "build-1",
        type: "agent",
        attention: true,
        execute: true
      )

    assert report.dry_run == false

    assert [
             %{
               status: "sent",
               directive_id: "dir-" <> _suffix,
               work_state: "waiting"
             }
           ] = report.targets

    assert Repo.aggregate(Directive, :count) == 1
  end

  test "send_session captures immediately before directive policy" do
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    {:ok, snapshot} = Workspace.snapshot_sessions(host_name: "build-1", type: "agent")
    [%{ref: ref}] = snapshot.sessions
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed")

    assert {:ok, %Directive{directive_id: "dir-" <> _suffix}} =
             Workspace.send_session(ref, "report current status")

    assert Repo.aggregate(SessionObservation, :count) == 0
    assert Repo.aggregate(Directive, :count) == 1
  end

  test "send_session_prompt keeps the session profile aligned with the directive" do
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    {:ok, snapshot} = Workspace.snapshot_sessions(host_name: "build-1", type: "agent")
    [%{ref: ref}] = snapshot.sessions
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed")

    assert {:ok, %Directive{enter: false}} =
             Workspace.send_session_prompt(ref, "prepare status report", enter: false)

    assert %SessionProfile{
             next_prompt: "prepare status report",
             prompt_status: "ready",
             last_seen_at: %DateTime{}
           } = Repo.get_by!(SessionProfile, ref: ref)

    assert {:ok, %Directive{enter: true}} =
             Workspace.send_session_prompt(ref, "send status report", enter: true)

    assert %SessionProfile{
             next_prompt: "send status report",
             prompt_status: "sent",
             last_seen_at: %DateTime{}
           } = Repo.get_by!(SessionProfile, ref: ref)
  end

  test "send_session_keys sends raw approval input without recording a directive or profile" do
    Process.put(:fake_ssh_tmux_capture, "Do you want to proceed?")

    {:ok, snapshot} = Workspace.snapshot_sessions(host_name: "build-1", type: "agent")
    [%{ref: ref}] = snapshot.sessions
    assert_received {:ssh_script, _discovery_script}
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed")

    assert {:ok,
            %{
              host: "build-1",
              tmux_server: "jx",
              session_name: "jx_saysure_task_deadbeef_codex",
              window: 0,
              pane: 0,
              keys: "1",
              enter: true
            }} = Workspace.send_session_keys(ref, "1")

    script = assert_ssh_script_containing("jx-send-key-tokens")
    assert script =~ "jx-send-key-tokens"
    assert script =~ "send-keys -t \"$pane_target\" -- '1' 'Enter'"
    refute script =~ "send-keys -t \"$pane_target\" -l --"

    assert Repo.aggregate(Directive, :count) == 0
    assert Repo.get_by(SessionProfile, ref: ref) == nil
  end

  test "send_session_keys sends special tmux key tokens instead of literal text" do
    Process.put(:fake_ssh_tmux_capture, "❯ [Pasted text #1]Enter")

    {:ok, snapshot} = Workspace.snapshot_sessions(host_name: "build-1", type: "agent")
    [%{ref: ref}] = snapshot.sessions
    assert_received {:ssh_script, _discovery_script}
    assert {:ok, _control} = Workspace.set_session_control(ref, "managed")

    assert {:ok,
            %{
              keys: "C-u Enter",
              enter: false
            }} = Workspace.send_session_keys(ref, "C-u Enter", enter: false)

    script = assert_ssh_script_containing("jx-send-key-tokens")
    assert script =~ "jx-send-key-tokens"
    assert script =~ "send-keys -t \"$pane_target\" -- 'C-u' 'Enter'"
    refute script =~ "-l -- 'C-u Enter'"
    assert Repo.aggregate(Directive, :count) == 0
    assert Repo.get_by(SessionProfile, ref: ref) == nil
  end

  test "attach and logs target the persisted session and log path" do
    {:ok, task} = Workspace.assign_task("saysure", "check reconnect")

    assert :ok = Workspace.attach(task.task_id)
    assert :ok = Workspace.logs(task.task_id, lines: 50, follow: true)

    assert_received {:ssh_attach, "jx_saysure_" <> _, [tmux_server: "jx"]}
    assert_received {:ssh_log, log_path, [lines: 50, follow: true]}
    assert log_path == task.log_path
  end

  test "repo_gate evaluates instance eligibility and aggregates reasons" do
    Process.put(:fake_ssh_repo_doctors, %{
      "build-1" => """
      jx-repo-doctor\t1
      repo_path\t/srv/repos/saysure
      status\tok
      branch\tdevelop
      head\tabc123
      upstream\torigin/develop
      remote\torigin
      remote_url\tgit@example.test:saysure.git
      remote_refs_start
      abc123\trefs/heads/develop
      remote_refs_end
      remote_status\t0
      status_short_start
      ## develop...origin/develop
      status_short_end
      worktree_start
      worktree /srv/repos/saysure
      HEAD abc123
      branch refs/heads/develop
      worktree_end
      branches_start
      develop\torigin/develop\t\tabc123\tdevelop commit
      branches_end
      """
    })

    assert {:ok, gate} = Workspace.repo_gate("saysure")
    assert gate.project == "saysure"
    # push_allowed defaults to "unknown" from repo_doctor, which gates promotion
    assert gate.eligible == false
    assert gate.status == "blocked"
    assert "push_not_verified" in gate.reasons
    assert gate.summary.total == 1
    assert gate.summary.allowed == 0
    assert gate.summary.blocked == 1
    assert [%{host: "build-1", eligible: false, status: "blocked"}] = gate.instances
  end

  test "repo_gate aggregates blocked reasons and required fixes across degraded instances" do
    Process.put(:fake_ssh_repo_doctors, %{
      "build-1" => """
      jx-repo-doctor\t1
      repo_path\t/srv/repos/saysure
      status\tok
      branch\tdevelop
      head\tabc123
      upstream\torigin/develop
      remote\torigin
      remote_url\thttps://github.com/example/private.git
      remote_refs_start
      remote: Invalid username or token.
      fatal: Authentication failed
      remote_refs_end
      remote_status\t128
      tracking_refs_start
      abc123\trefs/remotes/origin/develop
      tracking_refs_end
      status_short_start
      ## develop...origin/develop
      status_short_end
      worktree_start
      worktree /srv/repos/saysure
      HEAD abc123
      branch refs/heads/develop
      worktree_end
      branches_start
      develop\torigin/develop\t\tabc123\tdevelop commit
      branches_end
      """
    })

    assert {:ok, gate} = Workspace.repo_gate("saysure")
    assert gate.eligible == false
    assert gate.status == "blocked"
    assert gate.summary.total == 1
    assert gate.summary.allowed == 0
    assert gate.summary.blocked == 1
    assert gate.reasons != []
    assert gate.required_fixes != []
    assert [%{host: "build-1", eligible: false, status: "blocked"}] = gate.instances
  end

  test "project_gate returns no_hosts when project is not found" do
    assert {:ok, gate} = Workspace.project_gate("missing-project")
    assert gate.eligible == false
    assert gate.status == "blocked"
    assert gate.reasons == ["no_hosts_registered"]
    assert gate.hosts == []
  end

  test "project_gate evaluates project eligibility from repo gate" do
    Process.put(:fake_ssh_repo_doctors, %{
      "build-1" => """
      jx-repo-doctor\t1
      repo_path\t/srv/repos/saysure
      status\tok
      branch\tdevelop
      head\tabc123
      upstream\torigin/develop
      remote\torigin
      remote_url\tgit@example.test:saysure.git
      remote_refs_start
      abc123\trefs/heads/develop
      remote_refs_end
      remote_status\t0
      status_short_start
      ## develop...origin/develop
      status_short_end
      worktree_start
      worktree /srv/repos/saysure
      HEAD abc123
      branch refs/heads/develop
      worktree_end
      branches_start
      develop\torigin/develop\t\tabc123\tdevelop commit
      branches_end
      """
    })

    assert {:ok, gate} = Workspace.project_gate("saysure")
    # push_allowed defaults to "unknown" from repo_doctor, which gates promotion
    assert gate.eligible == false
    assert gate.status == "blocked"
    assert [%{host: "build-1", eligible: false}] = gate.hosts
  end

  test "project_brief builds a comprehensive project brief" do
    Process.put(:fake_ssh_tmux_capture, "Would you like me to run the next command?")

    {:ok, brief} = Workspace.project_brief("saysure", limit: 5)
    assert brief.project.name == "saysure"
    assert brief.headline != nil
    assert brief.next != nil
    assert brief.mode != nil
    assert is_map(brief.counts)
    assert is_list(brief.agenda)
    assert is_list(brief.notifications)
    assert is_list(brief.ci_watches)
    assert is_list(brief.handoffs)
    assert is_list(brief.delegations)
    assert is_list(brief.wake_triggers)
    assert brief.headline != nil
    assert brief.next != nil
  end

  test "call_brief builds a call brief from orchestration state" do
    Process.put(:fake_ssh_tmux_capture, "Would you like me to run the next command?")

    assert {:ok, call_brief} = Workspace.call_brief(limit: 5)
    assert call_brief.surface == "call"
    assert call_brief.mode == "brief"
    assert call_brief.headline != nil
    assert is_map(call_brief.operator)
    assert is_map(call_brief.orchestrator)
    assert is_list(call_brief.agenda)
    assert is_list(call_brief.projects)
    assert is_list(call_brief.notifications)
    assert is_list(call_brief.watches)
    assert is_list(call_brief.handoffs)
    assert is_list(call_brief.delegations)
    assert is_list(call_brief.delegation_reviews)
  end

  test "wake rejects an empty message" do
    assert {:error, "wake requires a non-empty message"} =
             Workspace.wake(%{message: "", summary: "  "})
  end

  test "wake rejects an unsupported severity" do
    assert {:error, error} = Workspace.wake(%{message: "test wake", severity: "fatal"})
    assert error =~ "unsupported monitor severity"
    assert error =~ "fatal"
  end

  test "manage rejects an unsupported policy" do
    assert {:error, {:unsupported_manage_policy, "aggressive"}} =
             Workspace.manage(policy: "aggressive")
  end

  test "policy_check classifies known and unknown release actions" do
    assert Workspace.policy_check("commit").decision == "allowed"
    assert Workspace.policy_check("push").decision == "allowed"
    assert Workspace.policy_check("force-push").confirmation == "required"

    unknown = Workspace.policy_check("deploy_to_orbit")
    assert unknown.decision == "hold"
    assert unknown.confirmation == "required"
  end

  test "orchestrator_decide returns error for invalid actions" do
    Process.put(:fake_ssh_tmux_capture, "Ready for the next instruction.")

    {:ok, snapshot} = Workspace.snapshot_sessions(host_name: "build-1", type: "agent")
    [%{ref: ref}] = snapshot.sessions

    assert {:error, :invalid_orchestrator_decision} =
             Workspace.orchestrator_decide(ref, %{action: "deploy"})
  end

  test "snapshot_sessions can filter by ref" do
    Process.put(:fake_ssh_tmux_capture, "Would you like me to run the next command?")

    {:ok, report} = Workspace.snapshot_sessions(host_name: "build-1", type: "agent")
    [%{ref: ref}] = report.sessions

    {:ok, filtered} = Workspace.snapshot_sessions(host_name: "build-1", type: "agent", ref: ref)
    assert length(filtered.sessions) == 1
    assert hd(filtered.sessions).ref == ref

    {:ok, empty} =
      Workspace.snapshot_sessions(host_name: "build-1", type: "agent", ref: "nonexistent")

    assert empty.sessions == []
  end

  test "work_board can filter by ref" do
    Process.put(:fake_ssh_tmux_capture, "Would you like me to run the next command?")

    {:ok, board} = Workspace.work_board(host_name: "build-1", type: "agent")
    [%{ref: ref}] = board.items

    {:ok, filtered} = Workspace.work_board(host_name: "build-1", type: "agent", ref: ref)
    assert length(filtered.items) == 1
    assert hd(filtered.items).ref == ref

    {:ok, empty} = Workspace.work_board(host_name: "build-1", type: "agent", ref: "nonexistent")
    assert empty.items == []
  end

  test "capacity_host assesses probed resources and computes recommendation" do
    Process.put(:fake_ssh_capacity_ram, "32768 24576\n")
    Process.put(:fake_ssh_capacity_disk, "204800 102400\n")
    Process.put(:fake_ssh_capacity_cpu, "16\n")

    assert {:ok, result} = Workspace.capacity_host("build-1")
    assert result.host == "build-1"
    assert result.resources.ram_total_mb == 32768
    assert result.resources.ram_available_mb == 24576
    assert result.resources.disk_total_mb == 204_800
    assert result.resources.disk_available_mb == 102_400
    assert result.resources.cpu_cores == 16
    assert result.formula_recommended > 0
    assert result.recommended_worktrees == result.formula_recommended
    assert result.limit_source == :formula
  end

  test "capacity_hosts aggregates assessments across all hosts" do
    Process.put(:fake_ssh_capacity_ram, "16384 8192\n")
    Process.put(:fake_ssh_capacity_disk, "204800 102400\n")
    Process.put(:fake_ssh_capacity_cpu, "8\n")

    assert {:ok, report} = Workspace.capacity_hosts()
    assert report.generated_at
    assert length(report.results) == 1
    assert [%{host: "build-1"}] = report.results
  end

  test "evaluate_capacity reports insufficient data without observations" do
    assert {:ok, result} = Workspace.evaluate_capacity("build-1")
    assert result.host == "build-1"
    assert result.verdict == :insufficient_data
    assert result.suggested_limit == nil
    assert result.observations_analysed == 0
    assert result.reasoning =~ "Need at least"
  end

  test "evaluate_all_capacity evaluates every registered host" do
    assert {:ok, report} = Workspace.evaluate_all_capacity()
    assert length(report.results) == 1
    assert [%{host: "build-1", verdict: :insufficient_data}] = report.results
  end

  test "set_project_capacity_profile stores a named preset on the project" do
    {:ok, _project} =
      Workspace.add_project(%{
        name: "saysure",
        host_name: "build-1",
        repo_path: "/srv/repos/saysure"
      })

    assert {:ok, project} =
             Workspace.set_project_capacity_profile("saysure", "build-1", "elixir-phoenix")

    assert project.capacity_profile == "elixir-phoenix"
  end

  test "set_project_capacity_profile rejects unknown profile names" do
    {:ok, _project} =
      Workspace.add_project(%{
        name: "saysure",
        host_name: "build-1",
        repo_path: "/srv/repos/saysure"
      })

    assert {:error, message} =
             Workspace.set_project_capacity_profile("saysure", "build-1", "cobol-mainframe")

    assert message =~ "unknown profile"
    assert message =~ "cobol-mainframe"
  end

  test "list_capacity_profiles returns all built-in presets" do
    assert {:ok, profiles} = Workspace.list_capacity_profiles()
    assert Map.has_key?(profiles, "elixir-phoenix")
    assert Map.has_key?(profiles, "rails")
    assert Map.has_key?(profiles, "nodejs")
    assert Map.has_key?(profiles, "go")
    assert Map.has_key?(profiles, "python-ml")
  end

  test "compute_target_parallel sums capacity limits across all hosts" do
    # build-1 already set up in the test; set its capacity limit
    Workspace.set_capacity_limit("build-1", 5)

    {:ok, _host2} =
      Workspace.add_host(%{
        name: "build-2",
        ssh_target: "developer@build2.example.test",
        workspace_path: "/srv/agent"
      })

    Workspace.set_capacity_limit("build-2", 4)

    summary = Workspace.delegation_timing()
    # 5 + 4 = 9
    assert summary.assignment.target_parallel == 9
  end

  test "delegation_timing falls back to per-host default when no capacity_limit set" do
    summary = Workspace.delegation_timing()
    # build-1 has no capacity_limit → uses @per_host_default_parallel (3)
    assert summary.assignment.target_parallel == 3
  end

  test "promotion_preflight returns blocked when project gate has unverified push" do
    Process.put(:fake_ssh_repo_doctors, %{
      "build-1" => """
      jx-repo-doctor\t1
      repo_path\t/srv/repos/saysure
      status\tok
      branch\tdevelop
      head\tabc123
      upstream\torigin/develop
      remote\torigin
      remote_url\tgit@example.test:saysure.git
      remote_refs_start
      abc123\trefs/heads/develop
      remote_refs_end
      remote_status\t0
      status_short_start
      ## develop...origin/develop
      status_short_end
      worktree_start
      worktree /srv/repos/saysure
      HEAD abc123
      branch refs/heads/develop
      worktree_end
      branches_start
      develop\torigin/develop\t\tabc123\tdevelop commit
      branches_end
      """
    })

    assert {:ok, preflight} =
             Workspace.promotion_preflight("saysure", "develop", "master")

    assert preflight.project == "saysure"
    assert preflight.source_branch == "develop"
    assert preflight.target_branch == "master"
    assert preflight.eligible == false
    assert preflight.status == "blocked"
    assert Enum.any?(preflight.reasons, &String.contains?(&1, "push_not_verified"))
  end

  test "promotion_preflight returns blocked when project gate is not eligible" do
    Process.put(:fake_ssh_repo_doctors, %{
      "build-1" => """
      jx-repo-doctor\t1
      repo_path\t/srv/repos/saysure
      status\tok
      branch\tdevelop
      head\tabc123
      upstream\torigin/develop
      remote\torigin
      remote_url\thttps://github.com/example/private.git
      remote_refs_start
      remote: Invalid username or token.
      fatal: Authentication failed
      remote_refs_end
      remote_status\t128
      tracking_refs_start
      abc123\trefs/remotes/origin/develop
      tracking_refs_end
      status_short_start
      ## develop...origin/develop
      status_short_end
      worktree_start
      worktree /srv/repos/saysure
      HEAD abc123
      branch refs/heads/develop
      worktree_end
      branches_start
      develop\torigin/develop\t\tabc123\tdevelop commit
      branches_end
      """
    })

    assert {:ok, preflight} =
             Workspace.promotion_preflight("saysure", "develop", "master")

    assert preflight.eligible == false
    assert preflight.status == "blocked"
    assert preflight.reasons != []
  end

  defp assert_ssh_script_containing(pattern) do
    receive do
      {:ssh_script, script} ->
        if script =~ pattern do
          script
        else
          assert_ssh_script_containing(pattern)
        end
    after
      100 -> flunk("expected ssh script containing #{inspect(pattern)}")
    end
  end

  defp init_git_repo! do
    root =
      Path.join(
        System.tmp_dir!(),
        "jx-test-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)

    run_git!(["init", "-b", "main", repo])
    File.write!(Path.join(repo, "README.md"), "# Test\n")
    run_git!(["-C", repo, "add", "README.md"])

    run_git!([
      "-C",
      repo,
      "-c",
      "user.name=jx",
      "-c",
      "user.email=agent@example.test",
      "-c",
      "commit.gpgsign=false",
      "commit",
      "-m",
      "initial"
    ])

    repo
  end

  defp run_git!(args) do
    {output, status} = System.cmd("git", args, stderr_to_stdout: true)
    assert status == 0, output
    output
  end

  defp work_board_pane_discovery(path) do
    "jx\tjx_saysure_task_deadbeef_codex\t0\t0\t%1\t1\t/dev/pts/1\tcodex\t#{path}\tCodex\n"
  end
end
