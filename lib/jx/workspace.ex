defmodule JX.Workspace do
  @moduledoc """
  Main orchestration API shared by the CLI, daemon workers, and Jido actions.

  `Workspace` is the policy boundary for jx. It coordinates durable task
  records, remote worktrees, tmux panes, session profiles, CI watches,
  delegation packets, call handoffs, notifications, and orchestrator
  heartbeats. Lower-level modules provide storage and transport details, but
  callers should route behavior through this module so safety checks remain in
  one place.

  The API returns plain maps and tagged tuples because its primary consumers are
  command-line flows, Jido actions, and other agents that need stable JSON-like
  packets. Prefer adding a small Workspace function over bypassing policy in a
  schema or transport module.
  """

  alias JX.AgentRunner
  alias JX.Approvals
  alias JX.CallBrief
  alias JX.CallHandoffs
  alias JX.CiDigest
  alias JX.CiWatches
  alias JX.Command
  alias JX.ControlPlane
  alias JX.DelegatedExecution
  alias JX.DelegationPreflight
  alias JX.Delegations
  alias JX.DevIDE.State, as: DevIDEState
  alias JX.Directives
  alias JX.GitWorktrees
  alias JX.GoogleMeet
  alias JX.HostCapacity.Observer, as: CapacityObserver
  alias JX.HostDoctor
  alias JX.Hosts
  alias JX.IDs
  alias JX.MonitorEvents
  alias JX.NextStep
  alias JX.Notifications
  alias JX.OperationExecutions
  alias JX.OperationPolicy
  alias JX.OperationalEvents
  alias JX.OperationalEvents.Check, as: OperationalEventsCheck
  alias JX.OperationalLeases
  alias JX.OrchestrationActions
  alias JX.OrchestratorGuidance
  alias JX.OrchestratorHeartbeats
  alias JX.OrchestratorPlanner
  alias JX.OrchestratorQueueDecisions
  alias JX.OrchestratorRecovery
  alias JX.OrchestratorSurfaceDecisions
  alias JX.PaneTransport
  alias JX.PortfolioSummary
  alias JX.ProcessInventory
  alias JX.ProjectAudit
  alias JX.ProjectBrief
  alias JX.ProjectMatcher
  alias JX.Projects
  alias JX.RepoDoctor
  alias JX.Recap
  alias JX.RemoteSessions
  alias JX.ResourceOwnerships
  alias JX.SSHSessions
  alias JX.SafeActions
  alias JX.RuntimeEnvironments
  alias JX.SessionControls
  alias JX.SessionDossiers
  alias JX.SessionInventory
  alias JX.SessionObservations
  alias JX.SessionProfiles
  alias JX.SessionReconciliation
  alias JX.SessionStatus
  alias JX.SessionWatches
  alias JX.SSH
  alias JX.Tasks
  alias JX.Tmux
  alias JX.UsageModes
  alias JX.WakeTriggers
  alias JX.Workspace.ProjectGate
  alias JX.Workspace.Promotion
  alias JX.Workspace.PromotionPreflight
  alias JX.Workspace.RepoGate

  @git_timeout_ms 2_000
  @agent_report_kinds ~w(observation progress error blocker)
  @active_task_statuses ~w(creating running)
  @terminal_task_statuses ~w(completed failed stopped stale expired error)
  @default_task_stale_after_seconds 6 * 60 * 60
  @default_task_expire_after_seconds 48 * 60 * 60

  def add_host(attrs), do: Hosts.upsert_host(attrs)

  def list_hosts, do: Hosts.list_hosts()

  def add_project(attrs), do: Projects.upsert_project(attrs)

  def list_projects, do: Projects.list_projects()

  def project_audit(project_name, opts \\ []) do
    projects =
      project_name
      |> Projects.list_projects_by_name()
      |> filter_projects_by_host(Keyword.get(opts, :host_name))

    case projects do
      [] -> {:error, :project_not_found}
      projects -> {:ok, ProjectAudit.build(project_name, projects)}
    end
  end

  def project_gate(project_name, opts \\ []) do
    case repo_gate(project_name, opts) do
      {:ok, repo_gate_report} -> {:ok, ProjectGate.evaluate(project_name, repo_gate_report)}
      {:error, :project_not_found} -> {:ok, ProjectGate.no_hosts(project_name)}
      other -> other
    end
  end

  def promotion_preflight(project_name, source_branch, target_branch, opts \\ []) do
    PromotionPreflight.run(project_name, source_branch, target_branch, fn project, gate_opts ->
      project_gate(project, Keyword.merge(opts, gate_opts))
    end)
  end

  def promotion_run(project_name, source_branch, target_branch, opts \\ []) do
    Promotion.run(
      project_name,
      source_branch,
      target_branch,
      fn project, source, target -> promotion_preflight(project, source, target, opts) end,
      &run_promotion_mutation/1
    )
  end

  def repo_doctor(project_name, opts \\ []) do
    projects =
      project_name
      |> Projects.list_projects_by_name()
      |> filter_projects_by_host(Keyword.get(opts, :host_name))

    case projects do
      [] ->
        {:error, :project_not_found}

      projects ->
        with {:ok, session_report} <-
               list_sessions(
                 host_name: Keyword.get(opts, :host_name),
                 all_processes: true
               ) do
          {:ok,
           RepoDoctor.run(
             project_name,
             projects,
             Keyword.put(opts, :sessions, session_report.sessions)
           )}
        end
    end
  end

  def repo_gate(project_name, opts \\ []) do
    with {:ok, doctor_report} <- repo_doctor(project_name, opts) do
      instances = Enum.map(doctor_report.instances, &repo_gate_instance/1)
      reasons = unique_flat(instances, :reasons)
      required_fixes = unique_flat(instances, :required_fixes)
      eligible = instances != [] and Enum.all?(instances, & &1.eligible)

      {:ok,
       %{
         project: doctor_report.project,
         eligible: eligible,
         status: if(eligible, do: "allowed", else: "blocked"),
         reasons: reasons,
         required_fixes: required_fixes,
         summary: %{
           total: length(instances),
           allowed: Enum.count(instances, & &1.eligible),
           blocked: Enum.count(instances, &(not &1.eligible))
         },
         instances: instances
       }}
    end
  end

  defp repo_gate_instance(instance) do
    gate = RepoGate.evaluate(instance)

    %{
      host: Map.get(instance, :host, ""),
      repo_path: Map.get(instance, :repo_path, ""),
      eligible: gate.eligible,
      status: gate.status,
      reasons: gate.reasons,
      required_fixes: gate.required_fixes,
      reconciliation_status: Map.get(instance, :reconciliation_status, "unknown"),
      trust_status: Map.get(instance, :trust_status, "unknown"),
      confidence: Map.get(instance, :confidence, "unknown"),
      drift_status: get_in(instance, [:drift, :status]) || "unknown",
      auth: %{
        fetch_allowed: get_in(instance, [:auth, :fetch_allowed]) || "unknown",
        push_allowed: get_in(instance, [:auth, :push_allowed]) || "unknown",
        api_allowed: get_in(instance, [:auth, :api_allowed]) || "unknown"
      }
    }
  end

  defp unique_flat(items, key) do
    items
    |> Enum.flat_map(&Map.get(&1, key, []))
    |> Enum.uniq()
  end

  defp run_promotion_mutation(preflight) do
    with {:ok, project} <- promotion_project(preflight),
         {:ok, output} <-
           SSH.adapter(project.host).run(
             project.host,
             Promotion.promotion_script(
               project.repo_path,
               preflight.source_branch,
               preflight.target_branch
             )
           ) do
      Promotion.parse_output(output)
    else
      {:error, reason} -> {:error, [], [format_promotion_error(reason)]}
    end
  end

  defp promotion_project(preflight) do
    case promotion_hosts(preflight) do
      [host] ->
        host_name = Map.get(host, :host) || Map.get(host, "host")

        case Projects.get_project_by_name(preflight.project, host_name) do
          nil -> {:error, "promotion project host not found"}
          project -> {:ok, project}
        end

      [] ->
        {:error, "promotion requires exactly one eligible host"}

      hosts ->
        {:error,
         "ambiguous promotion hosts: #{hosts |> Enum.map(&promotion_host_name/1) |> Enum.join(", ")}"}
    end
  end

  defp promotion_hosts(preflight) do
    preflight
    |> get_in([:project_gate, :hosts])
    |> case do
      hosts when is_list(hosts) -> hosts
      _other -> []
    end
  end

  defp promotion_host_name(host), do: Map.get(host, :host) || Map.get(host, "host") || ""

  defp format_promotion_error(reason) when is_binary(reason), do: reason
  defp format_promotion_error(reason), do: inspect(reason)

  def project_brief(project_name, opts \\ []) do
    project_name = project_name |> to_string() |> String.trim()
    limit = Keyword.get(opts, :limit, 5)

    brief_opts =
      opts
      |> Keyword.put(:project, project_name)
      |> Keyword.put(:limit, limit)

    with {:ok, portfolio} <- portfolio_summary(brief_opts),
         {:ok, call_brief} <- call_brief(brief_opts) do
      next_step = NextStep.build(call_brief)
      {:ok, playbook} = UsageModes.playbook(next_step.mode)

      {:ok,
       ProjectBrief.build(
         project_name,
         %{
           project: Projects.get_project_by_name(project_name),
           portfolio: portfolio,
           call_brief: call_brief,
           next_step: next_step,
           playbook: playbook,
           notifications:
             list_notifications(
               status: Keyword.get(opts, :notification_status, "unread"),
               project: project_name,
               limit: Keyword.get(opts, :notification_limit, limit * 2)
             ),
           ci_watches:
             list_ci_watches(
               status: Keyword.get(opts, :ci_status),
               project: project_name,
               limit: Keyword.get(opts, :ci_limit, limit * 2)
             ),
           handoffs:
             list_call_handoffs(
               status: Keyword.get(opts, :handoff_status, "open"),
               project: project_name,
               limit: Keyword.get(opts, :handoff_limit, limit * 2)
             ),
           delegation_reviews:
             delegation_reviews(
               integration_status: Keyword.get(opts, :integration_status, "pending"),
               project: project_name,
               limit: Keyword.get(opts, :delegation_review_limit, limit * 2)
             ),
           delegations:
             list_delegations(
               status: Keyword.get(opts, :delegation_status),
               project: project_name,
               limit: Keyword.get(opts, :delegation_limit, limit * 2)
             ),
           wake_triggers:
             list_wake_triggers(
               status: Keyword.get(opts, :wake_status),
               project: project_name,
               limit: Keyword.get(opts, :wake_limit, limit * 2)
             )
         },
         limit: limit
       )}
    end
  end

  @doc """
  Retrospective analysis of past runs over the durable record.

  Unlike `portfolio_summary/1` (a live snapshot), this looks backward over
  persisted tasks and observations: it clusters tasks into runs, flags
  `running` tasks that went stale without a terminal state, reports
  observation coverage per run (including *blind runs* with no observations),
  and surfaces recoverable agent-attribution gaps. See `JX.Reflection`.
  """
  def reflect(opts \\ []), do: {:ok, JX.Reflection.reflect(opts)}

  def portfolio_summary(opts \\ []) do
    opts = Keyword.put_new(opts, :observe, true)
    limit = Keyword.get(opts, :limit, 25)
    scan_limit = Keyword.get(opts, :scan_limit, max(limit * 5, 100))

    profile_opts =
      opts
      |> Keyword.delete(:scan_limit)
      |> Keyword.put(:limit, scan_limit)

    with {:ok, profile_report} <- session_profiles(profile_opts) do
      devide_summary = DevIDEState.summary(limit: Keyword.get(opts, :devide_limit, 100))
      approval_summary = Approvals.summary(status: "active", limit: 500, latest: 5)

      summary =
        Projects.list_projects()
        |> PortfolioSummary.build(profile_report, limit: limit)
        |> attach_devide_summary(devide_summary)
        |> attach_approval_summary(approval_summary)

      {:ok,
       Map.put(summary, :orchestration, %{
         actions: OrchestrationActions.summary(limit: 500, latest: 5),
         approvals: approval_summary,
         notifications: Notifications.summary(status: "unread", limit: 500, latest: 5),
         delegations: Delegations.summary(limit: 500, latest: 5),
         handoffs: CallHandoffs.summary(status: "open", limit: 500, latest: 5)
       })}
    end
  end

  def list_approvals(opts \\ []), do: Approvals.list(opts)

  def get_approval(approval_id), do: Approvals.get(approval_id)

  def approval_detail(approval_id), do: Approvals.detail(approval_id)

  def approval_summary(opts \\ []), do: Approvals.summary(opts)

  def create_approval(attrs), do: Approvals.create(attrs)

  def recap(opts \\ []), do: Recap.run(opts)

  def record_agent_report(attrs) do
    attrs = Map.new(attrs)
    session_id = attrs |> Map.get(:session_id, Map.get(attrs, "session_id", "")) |> clean_text()
    task_id = attrs |> Map.get(:task_id, Map.get(attrs, "task_id", "")) |> clean_text()
    agent_id = attrs |> Map.get(:agent_id, Map.get(attrs, "agent_id", "")) |> clean_text()
    kind = attrs |> Map.get(:kind, Map.get(attrs, "kind", "observation")) |> clean_text()
    text = attrs |> Map.get(:text, Map.get(attrs, "text", "")) |> clean_text()

    with :ok <- require_text(:session_id, session_id),
         :ok <- require_text(:text, text),
         :ok <- validate_agent_report_kind(kind) do
      OperationalEvents.record(%{
        source: "agent",
        kind: "agent.report.#{kind}",
        entity_type: "runner_session",
        entity_id: session_id,
        owner: agent_id,
        severity: agent_report_severity(kind),
        summary: agent_report_summary(kind, text),
        payload: %{
          session_id: session_id,
          task_id: task_id,
          agent_id: agent_id,
          report_kind: kind,
          text: text
        }
      })
    end
  end

  defp require_text(field, ""), do: {:error, {:missing_required, field}}
  defp require_text(_field, _value), do: :ok

  defp validate_agent_report_kind(kind) when kind in @agent_report_kinds, do: :ok

  defp validate_agent_report_kind(kind),
    do: {:error, "unsupported agent report kind #{inspect(kind)}"}

  defp agent_report_severity("error"), do: "warning"
  defp agent_report_severity("blocker"), do: "critical"
  defp agent_report_severity("progress"), do: "notice"
  defp agent_report_severity(_kind), do: "info"

  defp agent_report_summary(kind, text), do: "agent #{kind}: #{String.slice(text, 0, 220)}"

  defp clean_text(nil), do: ""
  defp clean_text(value), do: value |> to_string() |> String.trim()

  def acknowledge_approval(approval_id, opts \\ []), do: Approvals.acknowledge(approval_id, opts)

  def dismiss_approval(approval_id, opts \\ []), do: Approvals.dismiss(approval_id, opts)

  defp attach_devide_summary(summary, devide_summary) do
    summary
    |> Map.put(:devide, devide_summary)
    |> update_in([:totals], &Map.merge(&1, DevIDEState.portfolio_totals(devide_summary)))
  end

  defp attach_approval_summary(summary, approval_summary) do
    summary
    |> Map.put(:approvals, approval_summary)
    |> update_in([:totals], &Map.merge(&1, Approvals.portfolio_totals(approval_summary)))
  end

  def ci_digest(repo, pr_number, opts \\ []) do
    CiDigest.run(repo, pr_number, opts)
  end

  def add_ci_watch(attrs), do: CiWatches.add_watch(attrs)

  def list_ci_watches(opts \\ []), do: CiWatches.list_watches(opts)

  def review_ci_watch(watch_id, opts \\ []), do: CiWatches.review_watch(watch_id, opts)

  def cancel_ci_watch(watch_id, summary), do: CiWatches.cancel_watch(watch_id, summary)

  def list_directives(opts \\ []) do
    Directives.list_directives(opts)
  end

  def list_operation_executions(opts \\ []) do
    OperationExecutions.list_executions(opts)
  end

  def list_orchestration_actions(opts \\ []) do
    OrchestrationActions.list_actions(opts)
  end

  def propose_action(approval_id, opts \\ []), do: SafeActions.propose(approval_id, opts)

  def dry_run_action(action_id, opts \\ []), do: SafeActions.dry_run(action_id, opts)

  def execute_action(action_id, opts \\ []), do: SafeActions.execute(action_id, opts)

  def show_action(action_id), do: SafeActions.show(action_id)

  def action_history(approval_id), do: SafeActions.history(approval_id)

  def orchestration_action_summary(opts \\ []) do
    OrchestrationActions.summary(opts)
  end

  def operational_queue(opts \\ []), do: ControlPlane.queue(opts)

  def operator_dashboard(opts \\ []), do: ControlPlane.dashboard(opts)

  def operator_dashboard_workspace(workspace_id, opts \\ []),
    do: ControlPlane.dashboard_workspace(workspace_id, opts)

  def operator_dashboard_runner(runner_id, opts \\ []),
    do: ControlPlane.dashboard_runner(runner_id, opts)

  def operator_dashboard_assignment(assignment_id, opts \\ []),
    do: ControlPlane.dashboard_assignment(assignment_id, opts)

  def operator_dashboard_action(action_id, opts \\ []),
    do: ControlPlane.dashboard_action(action_id, opts)

  def provision_runtime_for_action(action_id, opts \\ []),
    do: RuntimeEnvironments.provision_for_action(action_id, opts)

  def assign_runtime_action(runtime_id, action_id, opts \\ []),
    do: RuntimeEnvironments.assign_action(runtime_id, action_id, opts)

  def release_runtime(runtime_id, opts \\ []), do: RuntimeEnvironments.release(runtime_id, opts)

  def list_runtime_environments(opts \\ []), do: RuntimeEnvironments.list(opts)

  def get_runtime_environment(runtime_id), do: RuntimeEnvironments.get(runtime_id)

  def operational_workspace(workspace_id, opts \\ []),
    do: ControlPlane.workspace(workspace_id, opts)

  def operational_timeline(scope, id, opts \\ []), do: ControlPlane.timeline(scope, id, opts)

  def operational_rebuilt_state(opts \\ []), do: ControlPlane.rebuilt_state(opts)

  def operational_events_check(opts \\ []), do: OperationalEventsCheck.run(opts)

  def list_leases(opts \\ []), do: OperationalLeases.list(opts)

  def acquire_lease(resource_type, resource_id, owner, opts \\ []),
    do: OperationalLeases.acquire(resource_type, resource_id, owner, opts)

  def release_lease(lease_id, owner, opts \\ []),
    do: OperationalLeases.release(lease_id, owner, opts)

  def reassign_lease(resource_type, resource_id, owner, opts \\ []),
    do: OperationalLeases.reassign(resource_type, resource_id, owner, opts)

  def register_agent(attrs), do: DelegatedExecution.register_agent(attrs)

  def heartbeat_agent(agent_id, opts \\ []), do: DelegatedExecution.heartbeat(agent_id, opts)

  def list_agents(opts \\ []), do: DelegatedExecution.list_agents(opts)

  def register_runner(attrs), do: DelegatedExecution.register_runner(attrs)

  def heartbeat_runner(runner_id, opts \\ []),
    do: DelegatedExecution.heartbeat_runner(runner_id, opts)

  def list_runners(opts \\ []), do: DelegatedExecution.list_runners(opts)

  def get_runner(runner_id), do: DelegatedExecution.get_runner(runner_id)

  def create_assignment(action_id, opts \\ []),
    do: DelegatedExecution.create_assignment(action_id, opts)

  def enqueue_devide_runner_assignment(assignment_id, opts \\ []),
    do: DelegatedExecution.enqueue_devide_runner_assignment(assignment_id, opts)

  def reconcile_devide_runner_assignment(devide_assignment_id, opts \\ []),
    do: DelegatedExecution.reconcile_devide_runner_assignment(devide_assignment_id, opts)

  def reconcile_devide_runner_replay(replay, opts \\ []),
    do: DelegatedExecution.reconcile_devide_runner_replay(replay, opts)

  def reconcile_devide_runner_assignments(opts \\ []),
    do: DelegatedExecution.reconcile_devide_runner_assignments(opts)

  def list_assignments(opts \\ []), do: DelegatedExecution.list_assignments(opts)

  def claim_assignment(assignment_id, agent_id, opts \\ []),
    do: DelegatedExecution.claim_assignment(assignment_id, agent_id, opts)

  def claim_runner_assignment(assignment_id, runner_id, opts \\ []),
    do: DelegatedExecution.claim_runner_assignment(assignment_id, runner_id, opts)

  def start_assignment(assignment_id, agent_id, opts \\ []),
    do: DelegatedExecution.start_assignment(assignment_id, agent_id, opts)

  def start_runner_session(session_id, runner_id, opts \\ []),
    do: DelegatedExecution.start_runner_session(session_id, runner_id, opts)

  def progress_assignment(assignment_id, agent_id, summary, opts \\ []),
    do: DelegatedExecution.progress_assignment(assignment_id, agent_id, summary, opts)

  def progress_runner_session(session_id, runner_id, summary, opts \\ []),
    do: DelegatedExecution.progress_runner_session(session_id, runner_id, summary, opts)

  def execute_assignment(assignment_id, agent_id, opts \\ []),
    do: DelegatedExecution.execute_assignment(assignment_id, agent_id, opts)

  def execute_runner_session(session_id, runner_id, opts \\ []),
    do: DelegatedExecution.execute_runner_session(session_id, runner_id, opts)

  def fail_assignment(assignment_id, agent_id, summary, opts \\ []),
    do: DelegatedExecution.fail_assignment(assignment_id, agent_id, summary, opts)

  def fail_runner_session(session_id, runner_id, summary, opts \\ []),
    do: DelegatedExecution.fail_runner_session(session_id, runner_id, summary, opts)

  def expire_assignments(opts \\ []), do: DelegatedExecution.expire_assignments(opts)

  def list_runner_sessions(opts \\ []), do: DelegatedExecution.list_runner_sessions(opts)

  def get_runner_session(session_id), do: DelegatedExecution.get_runner_session(session_id)

  def runner_session_logs(session_id, opts \\ []),
    do: DelegatedExecution.runner_session_logs(session_id, opts)

  def runner_session_attach_plan(session_id, opts \\ []),
    do: DelegatedExecution.runner_session_attach_plan(session_id, opts)

  def expire_runner_sessions(opts \\ []), do: DelegatedExecution.expire_runner_sessions(opts)

  def list_orchestrator_heartbeats(opts \\ []) do
    OrchestratorHeartbeats.list(opts)
  end

  def orchestrator_health(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    stale_after_seconds = Keyword.get(opts, :stale_after_seconds, 120)
    opts = Keyword.put_new(opts, :limit, 20)
    heartbeats = list_orchestrator_heartbeats(opts)

    alerts =
      opts
      |> Keyword.put(:now, now)
      |> Keyword.put(:stale_after_seconds, stale_after_seconds)
      |> OrchestratorHeartbeats.health_alerts()

    %{
      generated_at: now,
      status: if(alerts == [], do: "ok", else: "attention"),
      stale_after_seconds: stale_after_seconds,
      heartbeats_total: length(heartbeats),
      alerts_total: length(alerts),
      alerts: alerts,
      heartbeats: heartbeats
    }
  end

  def list_notifications(opts \\ []) do
    Notifications.list(opts)
  end

  def notification_summary(opts \\ []) do
    Notifications.summary(opts)
  end

  def call_brief(opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)
    opts = Keyword.put_new(opts, :observe, false)

    scan_opts =
      opts
      |> Keyword.put(:limit, limit)
      |> Keyword.put_new(:scan_limit, max(limit * 5, 100))

    with {:ok, portfolio} <- portfolio_summary(scan_opts),
         {:ok, inbox} <- orchestrator_inbox(scan_opts) do
      {:ok,
       CallBrief.build(
         %{
           operator: operator_profile(),
           portfolio: portfolio,
           inbox: inbox,
           heartbeats:
             list_orchestrator_heartbeats(
               status: Keyword.get(opts, :heartbeat_status),
               limit: Keyword.get(opts, :heartbeat_limit, 3)
             ),
           notifications:
             list_notifications(
               status: Keyword.get(opts, :notification_status, "unread"),
               project: Keyword.get(opts, :project),
               ref: Keyword.get(opts, :ref),
               limit: Keyword.get(opts, :notification_limit, limit * 2)
             ),
           ci_watches:
             list_ci_watches(
               status: Keyword.get(opts, :ci_status),
               repo: Keyword.get(opts, :repo),
               project: Keyword.get(opts, :project),
               ref: Keyword.get(opts, :ref),
               limit: Keyword.get(opts, :ci_limit, limit * 2)
             ),
           handoffs:
             list_call_handoffs(
               status: Keyword.get(opts, :handoff_status, "open"),
               surface: Keyword.get(opts, :surface),
               project: Keyword.get(opts, :project),
               ref: Keyword.get(opts, :ref),
               limit: Keyword.get(opts, :handoff_limit, limit * 2)
             ),
           delegation_reviews:
             delegation_reviews(
               integration_status: Keyword.get(opts, :integration_status, "pending"),
               project: Keyword.get(opts, :project),
               ref: Keyword.get(opts, :ref),
               limit: Keyword.get(opts, :delegation_review_limit, limit * 2)
             ),
           delegations:
             list_delegations(
               status: Keyword.get(opts, :delegation_status),
               project: Keyword.get(opts, :project),
               ref: Keyword.get(opts, :ref),
               limit: Keyword.get(opts, :delegation_limit, limit * 2)
             )
         },
         limit: limit
       )}
    end
  end

  def participant_plugins do
    JX.ParticipantPlugins.list()
  end

  def google_meet_configure_auth(attrs), do: GoogleMeet.configure_auth(attrs)

  def google_meet_auth_profiles(opts \\ []), do: GoogleMeet.list_auth_profiles(opts)

  def google_meet_auth_url(profile_name, opts \\ []), do: GoogleMeet.auth_url(profile_name, opts)

  def google_meet_exchange_auth_code(profile_name, code, opts \\ []),
    do: GoogleMeet.exchange_auth_code(profile_name, code, opts)

  def google_meet_create_session(attrs, opts \\ []), do: GoogleMeet.create_session(attrs, opts)

  def google_meet_sessions(opts \\ []), do: GoogleMeet.list_sessions(opts)

  def google_meet_session(session_id), do: GoogleMeet.get_session(session_id)

  def google_meet_join_plan(session_id), do: GoogleMeet.join_plan(session_id)

  def google_meet_join_session(session_id, opts \\ []),
    do: GoogleMeet.join_session(session_id, opts)

  def google_meet_realtime_plan(session_id, opts \\ []),
    do: GoogleMeet.realtime_plan(session_id, opts)

  def google_meet_start_realtime(session_id, attrs \\ %{}, opts \\ []),
    do: GoogleMeet.start_realtime(session_id, attrs, opts)

  def google_meet_realtime_consult(session_id, attrs, opts \\ []) do
    brief_opts =
      opts
      |> Keyword.take([:project, :ref, :host_name, :all_tmux, :all_processes])
      |> Keyword.put_new(:observe, false)

    with {:ok, brief} <- call_brief(brief_opts) do
      GoogleMeet.realtime_consult(session_id, attrs, Keyword.put(opts, :brief, brief))
    end
  end

  def google_meet_realtime_watch(session_id, opts \\ []) do
    consult_opts = Keyword.delete(opts, :consult_fun)

    GoogleMeet.realtime_watch(
      session_id,
      Keyword.put(opts, :consult_fun, fn meet_session_id, attrs ->
        google_meet_realtime_consult(meet_session_id, attrs, consult_opts)
      end)
    )
  end

  def google_meet_recover_open_tabs(attrs, opts \\ []),
    do: GoogleMeet.recover_open_tabs(attrs, opts)

  def google_meet_sync_artifacts(session_id, opts \\ []),
    do: GoogleMeet.sync_artifacts(session_id, opts)

  def google_meet_export_session(session_id, opts \\ []),
    do: GoogleMeet.export_session(session_id, opts)

  def create_delegation(attrs), do: Delegations.create(attrs)

  def list_delegations(opts \\ []), do: Delegations.list(opts)

  def start_delegation(delegation_id, attrs \\ []), do: Delegations.start(delegation_id, attrs)

  def add_delegation_evidence(delegation_id, attrs),
    do: Delegations.add_evidence(delegation_id, attrs)

  def complete_delegation(delegation_id, attrs \\ []),
    do: Delegations.complete(delegation_id, attrs)

  def block_delegation(delegation_id, summary), do: Delegations.block(delegation_id, summary)

  def fail_delegation(delegation_id, summary), do: Delegations.fail(delegation_id, summary)

  def cancel_delegation(delegation_id, summary \\ ""),
    do: Delegations.cancel(delegation_id, summary)

  def delegation_brief(delegation_id), do: Delegations.brief_packet(delegation_id)

  def delegation_preflight(delegation_id), do: Delegations.preflight(delegation_id)

  def delegation_review(delegation_id), do: Delegations.review(delegation_id)

  def delegation_reviews(opts \\ []), do: Delegations.list_reviews(opts)

  def delegation_timing(opts \\ []) do
    opts = Keyword.put_new_lazy(opts, :target_parallel, &compute_target_parallel/0)
    Delegations.timing_summary(opts)
  end

  # Sum the capacity_limit across all registered hosts.  Hosts without a
  # set limit contribute a conservative per-host default so the number is
  # never zero.  This gives the orchestrator a data-driven parallelism ceiling
  # rather than the hardcoded value of 3.
  @per_host_default_parallel 3

  defp compute_target_parallel do
    Hosts.list_hosts()
    |> Enum.map(fn host ->
      host.capacity_limit || @per_host_default_parallel
    end)
    |> Enum.sum()
    |> max(1)
  end

  def decide_delegation_review(delegation_id, decision, attrs \\ []),
    do: Delegations.decide_review(delegation_id, decision, attrs)

  def create_call_handoff(attrs, opts \\ []) do
    brief? = Keyword.get(opts, :brief, true)

    with {:ok, brief_snapshot} <- maybe_call_brief_snapshot(brief?, attrs, opts) do
      CallHandoffs.create(attrs, brief_snapshot: brief_snapshot)
    end
  end

  def list_call_handoffs(opts \\ []), do: CallHandoffs.list(opts)

  def call_handoff_summary(opts \\ []), do: CallHandoffs.summary(opts)

  def close_call_handoff(handoff_id, summary \\ ""), do: CallHandoffs.close(handoff_id, summary)

  def apply_call_handoff(handoff_id, summary_or_attrs \\ "")

  def apply_call_handoff(handoff_id, summary) when is_binary(summary) do
    CallHandoffs.apply(handoff_id, summary)
  end

  def apply_call_handoff(handoff_id, attrs) when is_list(attrs) or is_map(attrs) do
    attrs = Map.new(attrs)

    with {:ok, handoff} <- open_call_handoff(handoff_id),
         {:ok, action_result} <- apply_call_handoff_action(handoff, attrs),
         {:ok, action_record} <-
           OrchestrationActions.record_result("call-handoff", action_result,
             source: "call-handoff"
           ),
         {:ok, applied_handoff} <-
           CallHandoffs.apply(
             handoff_id,
             call_handoff_apply_summary(handoff, attrs, action_result)
           ) do
      {:ok, %{handoff: applied_handoff, action: action_result, action_record: action_record}}
    else
      {:error, %{action: _action} = action_result} ->
        _record =
          OrchestrationActions.record_result("call-handoff", action_result,
            source: "call-handoff"
          )

        {:error, action_result.error}

      other ->
        other
    end
  end

  def acknowledge_notifications(opts \\ []) do
    case Keyword.get(opts, :notification_id) do
      nil -> Notifications.acknowledge_all(opts)
      notification_id -> Notifications.acknowledge(notification_id)
    end
  end

  def compact_notifications(opts \\ []) do
    Notifications.compact_unread(opts)
  end

  def wake(attrs) do
    attrs = Map.new(attrs)

    message =
      attrs |> Map.get(:message, Map.get(attrs, :summary, "")) |> to_string() |> String.trim()

    severity = attrs |> Map.get(:severity, "warning") |> to_string() |> String.trim()

    cond do
      message == "" ->
        {:error, "wake requires a non-empty message"}

      severity not in MonitorEvents.Event.severities() ->
        {:error,
         "unsupported monitor severity #{inspect(severity)}; expected one of: #{Enum.join(MonitorEvents.Event.severities(), ", ")}"}

      true ->
        wake_id = wake_id()

        with {:ok, events} <-
               MonitorEvents.record_event(%{
                 kind: "external.wake",
                 severity: severity,
                 ref: string_attr(attrs, :ref),
                 project: string_attr(attrs, :project),
                 action: "wake",
                 summary: message,
                 payload: %{
                   wake_id: wake_id,
                   message: message,
                   source: string_attr(attrs, :source, "cli")
                 }
               }) do
          notifications = Notifications.record_events(events)

          {:ok,
           %{
             wake_id: wake_id,
             events: events,
             notifications: notifications
           }}
        end
    end
  end

  def add_wake_trigger(attrs) do
    WakeTriggers.add(Map.new(attrs))
  end

  def list_wake_triggers(opts \\ []) do
    WakeTriggers.list(opts)
  end

  def cancel_wake_trigger(trigger_id) do
    WakeTriggers.cancel(trigger_id)
  end

  def run_due_wake_triggers(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    limit = Keyword.get(opts, :limit, 20)
    triggers = WakeTriggers.list_due(now: now, limit: limit)

    runs = Enum.map(triggers, &run_wake_trigger(&1, now))

    {:ok,
     %{
       generated_at: now,
       total: length(triggers),
       notifications_saved: wake_trigger_notifications_saved(runs),
       runs: runs,
       errors: Enum.flat_map(runs, &Map.get(&1, :errors, []))
     }}
  end

  defp string_attr(attrs, key, default \\ "") do
    attrs
    |> Map.get(key, default)
    |> to_string()
    |> String.trim()
  end

  defp wake_id do
    random =
      5
      |> :crypto.strong_rand_bytes()
      |> Base.encode16(case: :lower)

    "wak-" <> random
  end

  defp run_wake_trigger(trigger, now) do
    wake_attrs = %{
      message: trigger.message,
      project: trigger.project || "",
      ref: trigger.ref || "",
      severity: trigger.severity || "warning",
      source: "wake-trigger:#{trigger.trigger_id}"
    }

    case wake(wake_attrs) do
      {:ok, wake_result} ->
        result = wake_trigger_result_summary(trigger, wake_result)

        case WakeTriggers.mark_run(trigger, now: now, result: result) do
          {:ok, updated_trigger} ->
            %{
              status: "emitted",
              trigger: updated_trigger,
              wake: wake_result,
              result: result,
              errors: []
            }

          {:error, reason} ->
            %{
              status: "error",
              trigger: trigger,
              wake: wake_result,
              result: result,
              errors: [wake_trigger_error(reason)]
            }
        end

      {:error, reason} ->
        result = "wake trigger failed: #{inspect(reason)}"

        case WakeTriggers.mark_run(trigger, now: now, result: result) do
          {:ok, updated_trigger} ->
            %{
              status: "error",
              trigger: updated_trigger,
              wake: nil,
              result: result,
              errors: [wake_trigger_error(reason)]
            }

          {:error, mark_reason} ->
            %{
              status: "error",
              trigger: trigger,
              wake: nil,
              result: result,
              errors: [wake_trigger_error(reason), wake_trigger_error(mark_reason)]
            }
        end
    end
  end

  defp wake_trigger_result_summary(trigger, wake_result) do
    event_ids =
      wake_result.events
      |> Enum.map(& &1.event_id)
      |> Enum.join(", ")

    case event_ids do
      "" -> "wake trigger #{trigger.trigger_id} emitted no new event"
      ids -> "wake trigger #{trigger.trigger_id} emitted #{ids}"
    end
  end

  defp wake_trigger_notifications_saved(runs) do
    Enum.reduce(runs, 0, fn run, total ->
      case get_in(run, [:wake, :notifications, :saved]) do
        saved when is_integer(saved) -> total + saved
        _saved -> total
      end
    end)
  end

  defp wake_trigger_error(reason) do
    %{
      subsystem: "wake_triggers",
      error: reason
    }
  end

  def policy_overview do
    OperationPolicy.policy_overview(operator_profile())
  end

  def policy_check(action) do
    OperationPolicy.classify_release_action(action)
  end

  defp maybe_call_brief_snapshot(false, _attrs, _opts), do: {:ok, %{}}

  defp maybe_call_brief_snapshot(true, attrs, opts) do
    attrs = Map.new(attrs)

    brief_opts =
      opts
      |> Keyword.take([:host_name, :all_tmux, :all_processes, :type, :ssh_target, :work_state])
      |> Keyword.put_new(:project, Map.get(attrs, :project) || Map.get(attrs, "project"))
      |> Keyword.put_new(:ref, Map.get(attrs, :ref) || Map.get(attrs, "ref"))
      |> Keyword.put_new(:surface, Map.get(attrs, :surface) || Map.get(attrs, "surface"))
      |> Keyword.put_new(:observe, false)
      |> Keyword.put_new(:limit, 5)

    call_brief(brief_opts)
  end

  defp open_call_handoff(handoff_id) do
    case CallHandoffs.get(handoff_id) do
      nil ->
        {:error, :call_handoff_not_found}

      %{status: "open"} = handoff ->
        {:ok, handoff}

      handoff ->
        {:error, "call handoff #{handoff.handoff_id} is #{handoff.status}"}
    end
  end

  defp apply_call_handoff_action(handoff, %{action: "prompt"} = attrs) do
    ref = Map.get(attrs, :ref, "")
    message = Map.get(attrs, :message, "")
    prompt_status = Map.get(attrs, :prompt_status, "ready")

    profile_attrs = %{
      next_prompt: message,
      prompt_status: prompt_status,
      strategy: "Chambered by call handoff #{handoff.handoff_id}: #{handoff.title}",
      notes:
        first_present([Map.get(attrs, :summary), handoff.summary, handoff.operator_input]) || "",
      last_seen_at: DateTime.utc_now()
    }

    case set_session_profile(ref, profile_attrs) do
      {:ok, _profile} ->
        {:ok,
         call_handoff_action_result(handoff, attrs, %{
           action: "handoff-prompt",
           ref: ref,
           target: ref,
           safety: "gated",
           result_summary:
             "call handoff #{handoff.handoff_id} chambered #{prompt_status} prompt for #{ref}",
           prompt_status: prompt_status
         })}

      {:error, reason} ->
        {:error, call_handoff_action_error(handoff, attrs, ref, reason)}
    end
  end

  defp apply_call_handoff_action(handoff, %{action: "hold"} = attrs) do
    ref = Map.get(attrs, :ref, "")
    reason = Map.get(attrs, :reason, "")

    profile_attrs = %{
      next_prompt: "",
      prompt_status: "blocked",
      strategy: "Held by call handoff #{handoff.handoff_id}: #{reason}",
      notes:
        first_present([Map.get(attrs, :summary), handoff.summary, handoff.operator_input]) || "",
      last_seen_at: DateTime.utc_now()
    }

    case set_session_profile(ref, profile_attrs) do
      {:ok, _profile} ->
        {:ok,
         call_handoff_action_result(handoff, attrs, %{
           action: "handoff-hold",
           ref: ref,
           target: ref,
           safety: "manual",
           reason: reason,
           result_summary: "call handoff #{handoff.handoff_id} held #{ref}: #{reason}"
         })}

      {:error, reason} ->
        {:error, call_handoff_action_error(handoff, attrs, ref, reason)}
    end
  end

  defp apply_call_handoff_action(handoff, %{action: "watch"} = attrs) do
    ref = Map.get(attrs, :ref, "")

    watch_attrs = %{
      mode: Map.get(attrs, :mode, "notify"),
      goal: first_present([Map.get(attrs, :goal), handoff.title, handoff.summary]) || "",
      success_pattern: Map.get(attrs, :success_pattern, ""),
      blocker_pattern: Map.get(attrs, :blocker_pattern, ""),
      prompt: Map.get(attrs, :prompt, "")
    }

    case add_watch(ref, watch_attrs) do
      {:ok, watch} ->
        {:ok,
         call_handoff_action_result(handoff, attrs, %{
           action: "handoff-watch",
           ref: ref,
           target: watch.watch_id,
           safety: "safe",
           watch_id: watch.watch_id,
           result_summary: "call handoff #{handoff.handoff_id} added watch #{watch.watch_id}"
         })}

      {:error, reason} ->
        {:error, call_handoff_action_error(handoff, attrs, ref, reason)}
    end
  end

  defp apply_call_handoff_action(handoff, attrs) do
    {:error,
     call_handoff_action_error(
       handoff,
       attrs,
       Map.get(attrs, :ref, ""),
       "unsupported handoff action #{inspect(Map.get(attrs, :action))}"
     )}
  end

  defp call_handoff_action_result(handoff, attrs, result) do
    Map.merge(
      %{
        id: "handoff-#{handoff.handoff_id}-#{Map.get(attrs, :action, "")}",
        recommendation_id: handoff.handoff_id,
        source: "call-handoff",
        status: "executed",
        reason: call_handoff_action_reason(handoff, attrs),
        error: ""
      },
      result
    )
  end

  defp call_handoff_action_error(handoff, attrs, ref, reason) do
    %{
      id: "handoff-#{handoff.handoff_id}-#{Map.get(attrs, :action, "")}",
      recommendation_id: handoff.handoff_id,
      source: "call-handoff",
      action: "handoff-#{Map.get(attrs, :action, "unknown")}",
      status: "error",
      safety: "manual",
      ref: ref || "",
      target: ref || "",
      reason: call_handoff_action_reason(handoff, attrs),
      error: inspect(reason),
      result_summary: "call handoff #{handoff.handoff_id} apply failed"
    }
  end

  defp call_handoff_action_reason(handoff, attrs) do
    first_present([
      Map.get(attrs, :summary),
      Map.get(attrs, :reason),
      handoff.summary,
      handoff.operator_input,
      handoff.title
    ]) || "call handoff"
  end

  defp call_handoff_apply_summary(handoff, attrs, action_result) do
    first_present([
      Map.get(attrs, :summary),
      Map.get(action_result, :result_summary),
      "Applied call handoff #{handoff.handoff_id}"
    ])
  end

  def list_monitor_events(opts \\ []) do
    MonitorEvents.list_events(opts)
  end

  def unread_monitor_events(opts \\ []) do
    MonitorEvents.unread_events(opts)
  end

  def acknowledge_monitor_events(opts \\ []) do
    MonitorEvents.acknowledge(opts)
  end

  def monitor_event_status(opts \\ []) do
    MonitorEvents.status(opts)
  end

  def list_session_controls(opts \\ []) do
    SessionControls.list_controls(opts)
  end

  def set_session_control(ref, mode, opts \\ []) do
    with :ok <- validate_session_control_mode(mode),
         {:ok, session} <- get_session(ref) do
      SessionControls.upsert_session(session, mode, opts)
    end
  end

  def clear_session_control(ref), do: SessionControls.delete(ref)

  def set_session_profile(ref, attrs), do: SessionProfiles.upsert_session_profile(ref, attrs)

  def operator_profile, do: SessionProfiles.get_operator_profile()

  def set_operator_profile(attrs), do: SessionProfiles.upsert_operator_profile(attrs)

  def add_watch(ref, attrs) do
    with {:ok, session} <- get_session(ref) do
      watch_attrs =
        attrs
        |> Map.new()
        |> Map.put_new(
          :project,
          first_present([Map.get(session, :control_project), Map.get(session, :project)])
        )
        |> Map.put_new(:session_type, Map.get(session, :type, ""))
        |> Map.put_new(:session_kind, Map.get(session, :kind, ""))

      SessionWatches.add_watch(ref, watch_attrs)
    end
  end

  def list_watches(opts \\ []), do: SessionWatches.list_watches(opts)

  def complete_watch(watch_id, summary), do: SessionWatches.complete(watch_id, summary)

  def cancel_watch(watch_id, summary), do: SessionWatches.cancel(watch_id, summary)

  def review_watch(watch_id, opts \\ []) do
    with %{} = watch <- SessionWatches.get_watch(watch_id),
         {:ok, profile_report} <-
           session_profiles(
             opts
             |> Keyword.put(:ref, watch.ref)
             |> Keyword.put(:limit, 1)
           ),
         {:profile, [%{} = profile | _rest]} <- {:profile, profile_report.profiles} do
      {[update], _actions} =
        watch
        |> SessionWatches.evaluate_watch(profile)
        |> List.wrap()
        |> apply_watch_actions()

      {:ok, watch_review(update, profile_report)}
    else
      nil -> {:error, :watch_not_found}
      {:profile, []} -> {:error, :session_not_found}
      other -> other
    end
  end

  def list_remote_session_observations(opts \\ []) do
    RemoteSessions.list_observations(opts)
  end

  def doctor_host(host_name, opts \\ []) do
    with %{} = host <- Hosts.get_host_with_projects_by_name(host_name) do
      {:ok, HostDoctor.run(host, opts)}
    else
      nil -> {:error, :host_not_found}
    end
  end

  def doctor_hosts(opts \\ []) do
    reports =
      Hosts.list_hosts()
      |> Enum.map(&Hosts.get_host_with_projects_by_name(&1.name))
      |> Enum.map(&HostDoctor.run(&1, opts))

    {:ok, %{generated_at: DateTime.utc_now(), reports: reports}}
  end

  def capacity_host(host_name, opts \\ []) do
    with %{} = host <- Hosts.get_host_by_name(host_name) do
      JX.HostCapacity.assess(host, opts)
    else
      nil -> {:error, :host_not_found}
    end
  end

  def capacity_hosts(opts \\ []) do
    results =
      Hosts.list_hosts()
      |> Enum.map(&Hosts.get_host_with_projects_by_name(&1.name))
      |> Enum.map(fn host ->
        host_opts = Keyword.put_new(opts, :profile, dominant_project_profile(host))

        case JX.HostCapacity.assess(host, host_opts) do
          {:ok, result} -> result
          {:error, reason} -> %{host: host.name, error: inspect(reason)}
        end
      end)

    {:ok, %{generated_at: DateTime.utc_now(), results: results}}
  end

  # Returns the most resource-intensive profile across all projects on the host,
  # or nil (which lets assess/2 fall back to the default) if none are set.
  defp dominant_project_profile(%{projects: projects}) when is_list(projects) do
    projects
    |> Enum.flat_map(fn p ->
      case Projects.Project.resolve_profile(p.capacity_profile) do
        nil -> []
        profile -> [profile]
      end
    end)
    |> Enum.max_by(& &1.ram_mb_per_slot, fn -> nil end)
  end

  defp dominant_project_profile(_), do: nil

  def set_capacity_limit(host_name, limit) do
    Hosts.set_capacity_limit(host_name, limit)
  end

  def set_project_capacity_profile(project_name, host_name, profile_name) do
    if profile_name in Projects.Project.profile_names() do
      Projects.set_capacity_profile(project_name, host_name, profile_name)
    else
      {:error,
       "unknown profile #{inspect(profile_name)}; valid: #{Enum.join(Projects.Project.profile_names(), ", ")}"}
    end
  end

  def list_capacity_profiles do
    {:ok, Projects.Project.profiles()}
  end

  def snapshot_capacity(host_name, active_sessions) do
    case Hosts.get_host_by_name(host_name) do
      nil -> {:error, :host_not_found}
      host -> JX.HostCapacity.Observer.snapshot(host, active_sessions)
    end
  end

  def evaluate_capacity(host_name, opts \\ []) do
    case Hosts.get_host_by_name(host_name) do
      nil ->
        {:error, :host_not_found}

      host ->
        eval_opts = Keyword.put_new(opts, :current_limit, host.capacity_limit)
        {:ok, JX.HostCapacity.Evaluator.evaluate(host_name, eval_opts)}
    end
  end

  def capacity_history(host_name, limit \\ 20) do
    case Hosts.get_host_by_name(host_name) do
      nil -> {:error, :host_not_found}
      _host -> {:ok, JX.HostCapacity.Observer.recent(host_name, limit)}
    end
  end

  def evaluate_all_capacity(opts \\ []) do
    results =
      Hosts.list_hosts()
      |> Enum.map(fn host ->
        eval_opts = Keyword.put_new(opts, :current_limit, host.capacity_limit)
        JX.HostCapacity.Evaluator.evaluate(host.name, eval_opts)
      end)

    {:ok, %{generated_at: DateTime.utc_now(), results: results}}
  end

  def assign_task(project_name, prompt, opts \\ []) do
    agent_name = Keyword.get(opts, :agent_name, "claude") |> IDs.slug()
    agent_transport = normalize_agent_transport(Keyword.get(opts, :agent_transport))
    host_name = normalize_optional_host_name(Keyword.get(opts, :host_name))
    prompt = String.trim(prompt)
    goal_objective = normalize_goal_objective(prompt, opts)

    with :ok <- validate_agent_transport(agent_transport),
         :ok <- validate_goal_options(goal_objective, agent_name, agent_transport),
         {:project, %{} = project} <- {:project, assign_project(project_name, host_name)},
         :ok <- check_host_capacity_with_project(project.host, project) do
      host = project.host

      prompt_hash =
        IDs.prompt_hash(
          prompt_hash_scope(project, agent_name, agent_transport),
          prompt_hash_input(prompt, goal_objective)
        )

      task =
        Tasks.get_task_by_prompt(project.id, prompt_hash) ||
          create_task!(
            project,
            host,
            prompt,
            prompt_hash,
            agent_name,
            agent_transport,
            goal_objective
          )

      {:ok, task} = ensure_launch_command(task)
      ensure_task(project, host, task)
    else
      {:project, nil} -> {:error, assign_project_not_found(project_name, host_name)}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_statuses do
    Tasks.list_tasks()
    |> Enum.map(&status_for_task/1)
  end

  def reconcile_task_statuses(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    statuses = Keyword.get(opts, :statuses, @active_task_statuses)

    results =
      statuses
      |> Tasks.list_tasks_by_status()
      |> Enum.map(&status_for_task(&1, Keyword.put(opts, :now, now)))

    {:ok,
     %{
       generated_at: now,
       total: length(results),
       updated: Enum.count(results, &task_reconciled?/1),
       by_status: task_result_counts(results),
       results: results
     }}
  end

  def discover_sessions(opts \\ []) do
    with {:ok, hosts} <- discovery_hosts(opts) do
      tasks_by_host_session = tasks_by_host_session(hosts)
      projects_by_host_id = projects_by_host_id(hosts)
      all_tmux? = Keyword.get(opts, :all_tmux, true)

      hosts
      |> Enum.map(
        &discover_host_sessions(&1, tasks_by_host_session, projects_by_host_id, all_tmux?)
      )
      |> build_discovery_report()
    end
  end

  def list_activity(opts \\ []) do
    with {:ok, hosts} <- discovery_hosts(opts) do
      all_tmux? = Keyword.get(opts, :all_tmux, true)
      all_processes? = Keyword.get(opts, :all_processes, false)

      host_results = Enum.map(hosts, &activity_for_host(&1, all_tmux?, all_processes?))

      hosts
      |> local_unregistered_activity_results(Keyword.get(opts, :host_name), all_processes?)
      |> then(&(host_results ++ &1))
      |> build_activity_report()
    end
  end

  def list_sessions(opts \\ []) do
    with {:ok, hosts} <- discovery_hosts(opts),
         {:ok, activity_report} <-
           list_activity(
             host_name: Keyword.get(opts, :host_name),
             all_tmux: Keyword.get(opts, :all_tmux, true),
             all_processes: Keyword.get(opts, :all_processes, false)
           ),
         {:ok, ssh_sessions} <- SSHSessions.list(Hosts.list_hosts()) do
      tasks = hosts |> Enum.map(& &1.id) |> Tasks.list_tasks_for_hosts()

      report =
        activity_report
        |> SessionInventory.build(ssh_sessions, tasks)
        |> then(fn report ->
          %{report | sessions: SessionControls.apply_controls(report.sessions)}
        end)

      {:ok,
       %{
         report
         | sessions:
             SessionInventory.filter(report.sessions,
               type: Keyword.get(opts, :type),
               action: Keyword.get(opts, :action),
               ssh_target: Keyword.get(opts, :ssh_target)
             )
       }}
    end
  end

  def snapshot_sessions(opts \\ []) do
    lines = Keyword.get(opts, :lines, 40)
    work_state = Keyword.get(opts, :work_state)
    ref = Keyword.get(opts, :ref)

    with {:ok, report} <- list_sessions(opts) do
      sessions =
        report.sessions
        |> filter_snapshot_ref(ref)
        |> Enum.map(fn session ->
          Map.put(session, :capture, session_capture(session, lines))
        end)
        |> filter_snapshot_work_state(work_state)

      {:ok, %{report | sessions: sessions}}
    end
  end

  def observe_sessions(opts \\ []) do
    with {:ok, report} <- snapshot_sessions(opts),
         {:ok, observations} <- record_session_observations(report) do
      refs = Enum.map(observations, & &1.ref)
      limit = max(length(refs), 1)

      changes =
        list_session_changes(
          refs: refs,
          limit: limit,
          attention: Keyword.get(opts, :attention, false)
        )

      {:ok,
       %{
         saved: length(observations),
         observations: observations,
         changes: changes,
         errors: report.errors
       }}
    end
  end

  def record_session_observations(report), do: SessionObservations.record_snapshot(report)

  def list_session_observations(opts \\ []) do
    SessionObservations.list_observations(opts)
  end

  def list_session_changes(opts \\ []) do
    SessionObservations.list_changes(opts)
  end

  def list_stale_session_observations(opts \\ []) do
    SessionObservations.list_stale(opts)
  end

  def session_summary(opts \\ []) do
    stale_after_seconds = Keyword.get(opts, :stale_after_seconds, 300)
    limit = Keyword.get(opts, :limit, 20)

    with {:ok, {current_report, observation_refresh}} <- summary_current_report(opts),
         {:ok, remote_candidates} <- remote_session_candidates(target: Keyword.get(opts, :target)) do
      latest_observations = list_session_changes(limit: max(limit * 5, 100))
      attention_changes = list_session_changes(attention: true, limit: limit)
      remote_observations = RemoteSessions.latest_by_identity(limit: max(limit * 5, 100))

      stale =
        list_stale_session_observations(
          stale_after_seconds: stale_after_seconds,
          limit: limit
        )

      {:ok,
       %{
         generated_at: DateTime.utc_now(),
         registry: registry_summary(),
         current: current_summary(current_report),
         observations: observations_summary(latest_observations, attention_changes, stale),
         observation_refresh: observation_refresh,
         reconciliation:
           reconciliation_summary(current_report.sessions, latest_observations, limit),
         remote: remote_summary(remote_candidates, remote_observations),
         workflow:
           workflow_summary(
             current_report.sessions,
             latest_observations,
             remote_candidates,
             remote_observations,
             limit
           ),
         attention: attention_changes,
         stale: stale,
         errors: current_report.errors
       }}
    end
  end

  def operate(opts \\ []) do
    opts = Keyword.put_new(opts, :observe, true)

    with {:ok, summary} <- session_summary(opts) do
      recommendations = summary.workflow.recommendations

      {:ok,
       %{
         generated_at: summary.generated_at,
         mode: if(summary.observation_refresh.observed, do: "observe", else: "inspect"),
         observation_refresh: summary.observation_refresh,
         state: operation_state(summary),
         attention: summary.attention,
         stale: summary.stale,
         recommendations: recommendations,
         safe_actions: Enum.filter(recommendations, &(&1.safety == "safe")),
         gated_actions: Enum.filter(recommendations, &(&1.safety == "gated")),
         manual_actions: Enum.filter(recommendations, &(&1.safety == "manual")),
         unknowns: operation_unknowns(summary),
         execution: operation_execution(Keyword.get(opts, :execute), recommendations, opts),
         errors: summary.errors
       }}
    end
  end

  def manage(opts \\ []) do
    policy = Keyword.get(opts, :policy, "conservative")
    iterations = Keyword.get(opts, :iterations, 1)
    sleep_ms = Keyword.get(opts, :sleep_ms, 0)

    with :ok <- validate_manage_policy(policy) do
      runs =
        1..iterations
        |> Enum.map(&manage_iteration(&1, opts, sleep_ms))

      {:ok, %{policy: policy, iterations: iterations, runs: runs}}
    end
  end

  def work_board(opts \\ []) do
    observe? = Keyword.get(opts, :observe, true)
    limit = Keyword.get(opts, :limit, 50)
    control_mode = Keyword.get(opts, :control_mode)

    report_result =
      if observe? do
        snapshot_sessions(opts)
      else
        list_sessions(opts)
      end

    with {:ok, report} <- report_result do
      {:ok, build_work_board(report, observe?, limit, control_mode)}
    end
  end

  def session_dossiers(opts \\ []) do
    opts = Keyword.put_new(opts, :observe, true)
    limit = Keyword.get(opts, :limit, 50)
    ref = Keyword.get(opts, :ref)
    project = Keyword.get(opts, :project)
    registered_projects = project && Projects.list_projects_by_name(project)
    control_mode = Keyword.get(opts, :control_mode)
    next_action = Keyword.get(opts, :next_action)

    with {:ok, {report, observation_refresh}} <- summary_current_report(opts) do
      items =
        report.sessions
        |> filter_sessions_project_hint(project, registered_projects)
        |> build_work_board_items(control_mode)
        |> filter_work_board_ref(ref)

      refs = Enum.map(items, & &1.ref)
      changes = dossier_changes(refs, max(length(refs), limit))
      directives = Directives.list_directives(limit: Keyword.get(opts, :directive_limit, 200))

      dossiers =
        items
        |> SessionDossiers.build(changes, directives)
        |> filter_dossier_project(project, registered_projects)
        |> filter_dossier_next_action(next_action)
        |> Enum.take(limit)

      {:ok,
       %{
         generated_at: DateTime.utc_now(),
         observed: Keyword.get(opts, :observe),
         observation_refresh: observation_refresh,
         total: length(dossiers),
         dossiers: dossiers,
         errors: report.errors
       }}
    end
  end

  def session_queues(opts \\ []) do
    queue_limit = Keyword.get(opts, :queue_limit, 5)
    scan_limit = Keyword.get(opts, :scan_limit, Keyword.get(opts, :limit, 100))

    dossier_opts =
      opts
      |> Keyword.delete(:next_action)
      |> Keyword.put(:limit, scan_limit)

    with {:ok, dossier_report} <- session_dossiers(dossier_opts) do
      queues =
        dossier_report.dossiers
        |> SessionProfiles.apply_queue_overrides()
        |> SessionDossiers.queues(limit: queue_limit)

      {:ok,
       %{
         generated_at: dossier_report.generated_at,
         observed: dossier_report.observed,
         observation_refresh: dossier_report.observation_refresh,
         total: dossier_report.total,
         queues_total: length(queues),
         queues: queues,
         errors: dossier_report.errors
       }}
    end
  end

  def session_profiles(opts \\ []) do
    prompt_status = Keyword.get(opts, :prompt_status)
    limit = Keyword.get(opts, :limit, 50)
    scan_limit = Keyword.get(opts, :scan_limit, session_profile_scan_limit(prompt_status, limit))

    dossier_opts =
      opts
      |> Keyword.delete(:prompt_status)
      |> Keyword.put(:limit, scan_limit)

    with {:ok, dossier_report} <- session_dossiers(dossier_opts) do
      report =
        dossier_report
        |> SessionProfiles.build_report(prompt_status: prompt_status)
        |> limit_session_profile_report(limit)

      {:ok, report}
    end
  end

  def session_reconciliation(opts \\ []) do
    opts = Keyword.put_new(opts, :observe, false)
    limit = Keyword.get(opts, :limit, 25)

    profile_opts =
      opts
      |> Keyword.put(:limit, Keyword.get(opts, :scan_limit, max(limit * 5, 100)))

    with {:ok, profile_report} <- session_profiles(profile_opts) do
      remote_observations =
        RemoteSessions.latest_by_identity(limit: Keyword.get(opts, :remote_limit, 200))

      {:ok, SessionReconciliation.build(profile_report, remote_observations, limit: limit)}
    end
  end

  def recovery_plan(opts \\ []) do
    with {:ok, reconciliation} <- session_reconciliation(opts) do
      {:ok, OrchestratorRecovery.build(reconciliation, limit: Keyword.get(opts, :limit, 25))}
    end
  end

  def orchestrator_inbox(opts \\ []) do
    opts = Keyword.put_new(opts, :observe, true)
    limit = Keyword.get(opts, :limit, 20)
    profile_limit = Keyword.get(opts, :scan_limit, max(limit * 5, 100))
    profile_opts = Keyword.put(opts, :limit, profile_limit)

    with {:ok, profile_report} <- session_profiles(profile_opts) do
      latest_by_ref = latest_observations_by_ref(profile_report.profiles)
      suggestions = planner_suggestions(profile_report.profiles, latest_by_ref, limit)
      items = Enum.map(profile_report.profiles, &orchestrator_inbox_item(&1, suggestions))
      reviews = delegation_reviews(integration_status: "pending", limit: limit)
      recovery = recovery_plan!(opts, limit)

      {:ok,
       %{
         generated_at: DateTime.utc_now(),
         observed: profile_report.observed,
         observation_refresh: profile_report.observation_refresh,
         total: profile_report.total,
         sections: %{
           needs_judgment: items |> Enum.filter(&inbox_needs_judgment?/1) |> Enum.take(limit),
           delegation_reviews: reviews,
           recovery: recovery,
           suggestions: suggestions,
           ready: items |> Enum.filter(&inbox_ready?/1) |> Enum.take(limit),
           awaiting_observation:
             items |> Enum.filter(&inbox_awaiting_observation?/1) |> Enum.take(limit),
           recently_completed:
             items |> Enum.filter(&inbox_recently_completed?/1) |> Enum.take(limit)
         },
         errors: profile_report.errors
       }}
    end
  end

  def orchestrator_review(ref, opts \\ []) do
    opts = Keyword.put_new(opts, :observe, true)
    lines = Keyword.get(opts, :lines, 160)

    profile_opts =
      opts
      |> Keyword.put(:ref, ref)
      |> Keyword.put(:limit, 1)
      |> Keyword.put(:lines, lines)

    with {:ok, profile_report} <- session_profiles(profile_opts),
         {:profile, [%{} = profile | _rest]} <- {:profile, profile_report.profiles} do
      observation = latest_session_observation(ref)
      recommendation = orchestrator_review_recommendation(profile, observation)

      {:ok,
       %{
         generated_at: DateTime.utc_now(),
         ref: ref,
         observed: profile_report.observed,
         observation_refresh: profile_report.observation_refresh,
         profile: profile,
         latest_observation: observation_summary(observation),
         recommendation: recommendation,
         commands: orchestrator_review_commands(ref, profile, recommendation, lines),
         errors: profile_report.errors
       }}
    else
      {:profile, []} -> {:error, :session_not_found}
      other -> other
    end
  end

  defp recovery_plan!(opts, limit) do
    opts
    |> Keyword.put(:observe, false)
    |> Keyword.put(:limit, limit)
    |> recovery_plan()
    |> case do
      {:ok, recovery} ->
        recovery

      {:error, reason} ->
        %{
          generated_at: DateTime.utc_now(),
          status: "error",
          recommendations_total: 1,
          recommendations: [
            %{
              action: "inspect-corrupt-observation",
              safety: "inspect",
              ref: "",
              target: "",
              reason: inspect(reason),
              evidence: []
            }
          ],
          counts: %{orphan_remote: 0, local_without_remote: 0, duplicate_paths: 0, errors: 1}
        }
    end
  end

  def orchestrator_decide(ref, attrs) do
    action = attrs |> Map.get(:action, "") |> to_string()

    case action do
      "prompt" ->
        orchestrator_decide_prompt(ref, attrs)

      "hold" ->
        reason = first_present([Map.get(attrs, :reason), "Manual hold"])

        set_session_profile(ref, %{
          next_prompt: "",
          prompt_status: "blocked",
          strategy: "Manual orchestrator decision: #{reason}",
          notes: first_present([Map.get(attrs, :notes), reason]),
          last_seen_at: DateTime.utc_now()
        })
        |> wrap_orchestrator_decision(ref, "hold", "profile marked blocked for review")

      "clear" ->
        set_session_profile(ref, %{
          next_prompt: "",
          prompt_status: "none",
          strategy:
            first_present([Map.get(attrs, :strategy), "Manual orchestrator decision: cleared"]),
          notes: Map.get(attrs, :notes, ""),
          last_seen_at: DateTime.utc_now()
        })
        |> wrap_orchestrator_decision(ref, "clear", "profile prompt cleared")

      "ignore" ->
        set_session_control(ref, "ignored",
          note: Map.get(attrs, :notes, "Ignored by orchestrator decision")
        )
        |> wrap_orchestrator_decision(ref, "ignore", "session marked ignored")

      "protect" ->
        set_session_control(ref, "protected",
          note: Map.get(attrs, :notes, "Protected by orchestrator decision")
        )
        |> wrap_orchestrator_decision(ref, "protect", "session marked protected")

      "managed" ->
        set_session_control(ref, "managed",
          note: Map.get(attrs, :notes, "Managed by orchestrator decision")
        )
        |> wrap_orchestrator_decision(ref, "managed", "session marked managed")

      _other ->
        {:error, :invalid_orchestrator_decision}
    end
  end

  def monitor_scan(opts \\ []) do
    opts = Keyword.put_new(opts, :observe, true)
    queue_limit = Keyword.get(opts, :queue_limit, 5)
    event_limit = Keyword.get(opts, :event_limit, 20)
    prompt_status = Keyword.get(opts, :prompt_status)

    dossier_opts =
      opts
      |> Keyword.delete(:queue_limit)
      |> Keyword.delete(:event_limit)
      |> Keyword.delete(:prompt_status)

    with {:ok, due_wake_triggers} <-
           run_due_wake_triggers(limit: Keyword.get(opts, :wake_limit, 20)),
         {:ok, dossier_report} <- session_dossiers(dossier_opts),
         {:ok, scan_context} <-
           record_monitor_events(dossier_report, queue_limit, prompt_status, opts) do
      events = scan_context.events
      queues = scan_context.queues
      profiles = scan_context.profiles
      watch_updates = scan_context.watch_updates
      watch_actions = scan_context.watch_actions
      ci_watch_updates = scan_context.ci_watch_updates
      daemon_health_alerts = scan_context.daemon_health_alerts
      notifications = scan_context.notifications
      delegation_preflight = delegation_preflight_summary(scan_context.delegations)
      delegation_timing = Delegations.timing_summary(limit: 500)

      {:ok,
       %{
         generated_at: DateTime.utc_now(),
         observed: dossier_report.observed,
         observation_refresh: dossier_report.observation_refresh,
         sessions_total: dossier_report.total,
         events_saved: length(events),
         events: Enum.take(events, event_limit),
         queues_total: length(queues),
         queues: queues,
         watches_total: length(watch_updates),
         watch_updates: Enum.take(watch_updates, event_limit),
         watch_actions_total: length(watch_actions),
         watch_actions: Enum.take(watch_actions, event_limit),
         ci_watches_total: length(ci_watch_updates),
         ci_watch_updates: Enum.take(ci_watch_updates, event_limit),
         daemon_health_total: length(daemon_health_alerts),
         daemon_health: Enum.take(daemon_health_alerts, event_limit),
         wake_triggers_total: due_wake_triggers.total,
         wake_triggers: Enum.take(due_wake_triggers.runs, event_limit),
         call_handoffs_total: length(scan_context.call_handoffs),
         call_handoffs: Enum.take(scan_context.call_handoffs, event_limit),
         delegations_total: length(scan_context.delegations),
         delegations: Enum.take(scan_context.delegations, event_limit),
         delegation_reviews_total: length(scan_context.delegation_reviews),
         delegation_reviews: Enum.take(scan_context.delegation_reviews, event_limit),
         delegation_preflight: delegation_preflight,
         delegation_timing: delegation_timing,
         notifications_saved: notifications.saved,
         wake_notifications_saved: due_wake_triggers.notifications_saved,
         notifications: Enum.take(notifications.notifications, event_limit),
         profiles_total: length(profiles),
         profiles: profiles,
         errors: dossier_report.errors ++ due_wake_triggers.errors
       }}
    end
  end

  def orchestrate(opts \\ []) do
    opts = Keyword.put_new(opts, :observe, true)
    consumer = Keyword.get(opts, :consumer) || MonitorEvents.default_consumer()
    event_limit = Keyword.get(opts, :event_limit, 50)
    decision_limit = Keyword.get(opts, :decision_limit, 20)
    execute? = Keyword.get(opts, :execute, false)
    ack? = Keyword.get(opts, :ack, execute?)

    scan_opts =
      opts
      |> Keyword.drop([:consumer, :decision_limit, :execute, :yes, :ack])
      |> Keyword.put(:event_limit, event_limit)

    with {:ok, scan} <- monitor_scan(scan_opts),
         {:ok, inbox} <-
           unread_monitor_events(
             consumer: consumer,
             limit: event_limit,
             kinds: MonitorEvents.change_kinds()
           ) do
      profile_decisions = orchestrator_decisions(scan.profiles, inbox.events, opts)

      queue_decisions =
        OrchestratorQueueDecisions.build(scan.queues, scan.profiles, inbox.events, opts)

      surface_decisions = OrchestratorSurfaceDecisions.build(scan, inbox.events, opts)

      decisions =
        (profile_decisions ++ queue_decisions ++ surface_decisions)
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&normalize_orchestrator_decision/1)
        |> Enum.uniq_by(&{Map.get(&1, :ref), Map.get(&1, :action)})
        |> Enum.take(decision_limit)

      planned_actions = OrchestrationActions.record_planned("orchestrate", decisions)
      execution = execute_orchestrator_decisions(decisions, execute?, opts)

      action_results =
        OrchestrationActions.record_results(
          "orchestrate",
          execution.executed ++ execution.skipped
        )

      {cursor, cursor_errors} = maybe_ack_orchestrator(consumer, orchestrator_ack_id(inbox), ack?)

      report = %{
        generated_at: DateTime.utc_now(),
        consumer: consumer,
        mode: orchestrator_mode(execute?, ack?),
        scan: scan,
        inbox: %{
          cursor: inbox.cursor,
          latest_event_id: inbox.latest_event_id,
          unread_total: inbox.unread_total,
          matching_unread_total: inbox.matching_unread_total,
          returned: inbox.returned,
          events: inbox.events
        },
        decisions: decisions,
        action_queue: %{
          planned: action_queue_summary(planned_actions),
          results: action_queue_summary(action_results)
        },
        execution: execution,
        cursor: cursor,
        errors: scan.errors ++ cursor_errors
      }

      {:ok, Map.put(report, :heartbeat, record_orchestrator_heartbeat(report, opts))}
    end
  end

  defp normalize_orchestrator_decision(decision) do
    decision
    |> Map.new()
    |> Map.put_new(:id, "")
    |> Map.put_new(:action, "")
    |> Map.put_new(:source, "")
    |> Map.put_new(:safety, "manual")
    |> Map.put_new(:status, "planned")
    |> Map.put_new(:ref, "")
    |> Map.put_new(:state, "")
    |> Map.put_new(:prompt_status, "")
    |> Map.put_new(:message, "")
    |> Map.put_new(:reason, "")
    |> Map.put_new(:event_ids, [])
  end

  defp record_monitor_events(dossier_report, queue_limit, prompt_status, opts) do
    queues =
      dossier_report.dossiers
      |> SessionProfiles.apply_queue_overrides()
      |> SessionDossiers.queues(limit: queue_limit)

    profiles =
      dossier_report
      |> SessionProfiles.build_report(prompt_status: prompt_status)
      |> Map.fetch!(:profiles)

    {watch_updates, watch_actions} =
      profiles
      |> SessionWatches.evaluate_profiles()
      |> apply_watch_actions()

    ci_watch_updates = CiWatches.evaluate_active(limit: 20)

    daemon_health_alerts =
      OrchestratorHeartbeats.health_alerts(
        now: Keyword.get(opts, :now, DateTime.utc_now()),
        stale_after_seconds: Keyword.get(opts, :daemon_stale_after_seconds, 120),
        limit: Keyword.get(opts, :heartbeat_limit, 50)
      )

    call_handoffs = CallHandoffs.list(status: "open", limit: 100)

    delegations =
      Delegations.list(limit: 500) |> Enum.filter(&(&1.status in ~w(queued running blocked)))

    delegation_reviews = Delegations.list_reviews(integration_status: "pending", limit: 100)

    case MonitorEvents.record_scan(%{
           queues: queues,
           profiles: profiles,
           watch_updates: watch_updates,
           ci_watch_updates: ci_watch_updates,
           daemon_health_alerts: daemon_health_alerts,
           call_handoffs: call_handoffs,
           delegations: delegations,
           delegation_reviews: delegation_reviews
         }) do
      {:ok, events} ->
        notifications = Notifications.record_events(events)

        {:ok,
         %{
           events: events,
           queues: queues,
           profiles: profiles,
           watch_updates: watch_updates,
           watch_actions: watch_actions,
           ci_watch_updates: ci_watch_updates,
           daemon_health_alerts: daemon_health_alerts,
           call_handoffs: call_handoffs,
           delegations: delegations,
           delegation_reviews: delegation_reviews,
           notifications: notifications
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delegation_preflight_summary(delegations) do
    reports = Enum.map(delegations, &DelegationPreflight.lint(&1, delegations))

    %{
      total: length(reports),
      ready: Enum.count(reports, &(&1.status == "ready")),
      warning: Enum.count(reports, &(&1.status == "warning")),
      blocked: Enum.count(reports, &(&1.status == "blocked")),
      warnings_total: reports |> Enum.flat_map(& &1.warnings) |> length(),
      conflicts_total: reports |> Enum.flat_map(& &1.conflicts) |> length()
    }
  end

  defp watch_review(update, profile_report) do
    %{
      generated_at: DateTime.utc_now(),
      observed: profile_report.observed,
      observation_refresh: profile_report.observation_refresh,
      watch: update.watch,
      previous_status: update.previous_status,
      status: update.status,
      changed: update.changed?,
      profile_action: Map.get(update, :profile_action),
      profile: update.profile,
      summary: update.summary,
      errors: profile_report.errors
    }
  end

  defp apply_watch_actions(updates) do
    {updates, actions} =
      Enum.map_reduce(updates, [], fn update, actions ->
        action = watch_profile_action(update)

        case apply_watch_action(update, action) do
          nil ->
            {update, actions}

          applied ->
            {Map.put(update, :profile_action, applied), [applied | actions]}
        end
      end)

    {updates, Enum.reverse(actions)}
  end

  defp watch_profile_action(%{changed?: true, status: "blocked", watch: %{mode: mode}})
       when mode in ["hold", "prompt"] do
    {:hold, "watch blocker matched"}
  end

  defp watch_profile_action(%{changed?: true, status: "completed", watch: %{mode: "hold"}}) do
    {:hold, "watch completed; held for review"}
  end

  defp watch_profile_action(%{
         changed?: true,
         status: "completed",
         watch: %{mode: "prompt", prompt: prompt}
       }) do
    if text_present?(prompt), do: {:prompt, prompt}, else: nil
  end

  defp watch_profile_action(_update), do: nil

  defp apply_watch_action(_update, nil), do: nil

  defp apply_watch_action(update, {:hold, reason}) do
    attrs = %{
      next_prompt: "",
      prompt_status: "blocked",
      strategy: "Held by watch #{update.watch.watch_id}: #{reason}",
      notes: update.watch.result_summary,
      last_seen_at: DateTime.utc_now()
    }

    update
    |> apply_watch_profile_update("hold-profile", attrs)
    |> Map.put(:reason, reason)
  end

  defp apply_watch_action(update, {:prompt, prompt}) do
    attrs = %{
      next_prompt: prompt,
      prompt_status: "draft",
      strategy: "Chambered by watch #{update.watch.watch_id}: #{update.watch.goal}",
      notes: update.watch.result_summary,
      last_seen_at: DateTime.utc_now()
    }

    update
    |> apply_watch_profile_update("chamber-prompt", attrs)
    |> Map.put(:prompt_status, "draft")
  end

  defp apply_watch_profile_update(update, action, attrs) do
    result =
      case set_session_profile(update.watch.ref, attrs) do
        {:ok, _profile} ->
          %{
            action: action,
            status: "executed",
            source: "watch",
            watch_id: update.watch.watch_id,
            recommendation_id: update.watch.watch_id,
            ref: update.watch.ref,
            result_summary: watch_profile_action_summary(action, update)
          }

        {:error, reason} ->
          %{
            action: action,
            status: "error",
            source: "watch",
            watch_id: update.watch.watch_id,
            recommendation_id: update.watch.watch_id,
            ref: update.watch.ref,
            error: inspect(reason),
            result_summary: "watch profile action failed"
          }
      end

    OrchestrationActions.record_result("watch", result, source: "watch")

    result
  end

  defp action_queue_summary(%{saved: saved, records: records, errors: errors}) do
    %{
      saved: saved,
      action_ids: Enum.map(records, & &1.action_id),
      errors: errors
    }
  end

  defp record_orchestrator_heartbeat(report, opts) do
    now = report.generated_at
    interval_ms = Keyword.get(opts, :interval_ms)

    attrs = %{
      daemon_key: Keyword.get(opts, :daemon_key) || report.consumer,
      consumer: report.consumer,
      session_name: Keyword.get(opts, :session_name) || "",
      status: if(report.errors == [], do: "running", else: "error"),
      mode: report.mode,
      last_scan_at: now,
      last_decision_at: if(report.decisions == [], do: nil, else: now),
      last_error: report.errors |> Enum.map(&inspect/1) |> Enum.join("\n") |> truncate_text(500),
      next_wake_at: next_wake_at(now, interval_ms),
      scan_snapshot: heartbeat_snapshot(report)
    }

    case OrchestratorHeartbeats.upsert(attrs) do
      {:ok, heartbeat} ->
        %{
          daemon_key: heartbeat.daemon_key,
          consumer: heartbeat.consumer,
          status: heartbeat.status,
          mode: heartbeat.mode,
          last_scan_at: heartbeat.last_scan_at,
          last_decision_at: heartbeat.last_decision_at,
          next_wake_at: heartbeat.next_wake_at,
          guidance: heartbeat_guidance(heartbeat)
        }

      {:error, reason} ->
        %{error: inspect(reason)}
    end
  end

  defp next_wake_at(_now, nil), do: nil

  defp next_wake_at(now, interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    DateTime.add(now, div(interval_ms, 1_000), :second)
  end

  defp next_wake_at(_now, _interval_ms), do: nil

  defp heartbeat_snapshot(report) do
    Jason.encode!(%{
      sessions: report.scan.sessions_total,
      events_saved: report.scan.events_saved,
      decisions: length(report.decisions),
      executed: length(report.execution.executed),
      skipped: length(report.execution.skipped),
      unread: report.inbox.unread_total,
      watch_actions: Map.get(report.scan, :watch_actions_total, 0),
      ci_watches: Map.get(report.scan, :ci_watches_total, 0),
      wake_triggers: Map.get(report.scan, :wake_triggers_total, 0),
      call_handoffs: Map.get(report.scan, :call_handoffs_total, 0),
      delegations: Map.get(report.scan, :delegations_total, 0),
      delegation_reviews: Map.get(report.scan, :delegation_reviews_total, 0),
      delegation_long_running:
        get_in(report, [:scan, :delegation_timing, :active, :long_running]) || 0,
      stale_delegation_reviews:
        get_in(report, [:scan, :delegation_timing, :pending_reviews, :stale]) || 0,
      notifications: Map.get(report.scan, :notifications_saved, 0),
      guidance: OrchestratorGuidance.build(report)
    })
  rescue
    ArgumentError -> "{}"
  end

  defp heartbeat_guidance(heartbeat) do
    case Jason.decode(heartbeat.scan_snapshot || "{}") do
      {:ok, %{"guidance" => guidance}} -> guidance
      _other -> %{}
    end
  end

  defp watch_profile_action_summary("chamber-prompt", update) do
    "watch #{update.watch.watch_id} chambered follow-up prompt"
  end

  defp watch_profile_action_summary("hold-profile", update) do
    "watch #{update.watch.watch_id} held profile for review"
  end

  defp orchestrator_decisions(profiles, events, opts) do
    latest_by_ref =
      if Keyword.get(opts, :auto_plan, false) do
        latest_observations_by_ref(profiles)
      else
        %{}
      end

    events_by_ref =
      events
      |> Enum.reject(&(Map.get(&1, :ref, "") == ""))
      |> Enum.group_by(& &1.ref)

    event_decisions =
      profiles
      |> Enum.filter(&Map.has_key?(events_by_ref, &1.ref))
      |> Enum.reject(&orchestrator_suppressed?/1)
      |> Enum.map(
        &orchestrator_decision(&1, Map.fetch!(events_by_ref, &1.ref), opts, latest_by_ref)
      )
      |> Enum.reject(&is_nil/1)

    current_decisions =
      if Keyword.get(opts, :include_current, true) do
        profiles
        |> Enum.reject(&orchestrator_suppressed?/1)
        |> Enum.map(&orchestrator_decision(&1, [], opts, latest_by_ref))
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(&orchestrator_current_decision?/1)
      else
        []
      end

    (event_decisions ++ current_decisions)
    |> Enum.uniq_by(& &1.id)
  end

  defp orchestrator_suppressed?(profile) do
    get_in(profile, [:session, :control_mode]) in ["ignored", "protected"]
  end

  defp orchestrator_current_decision?(%{action: action})
       when action in [
              "auto-plan-next",
              "auto-hold",
              "mark-prompt-ready",
              "observe",
              "send-profile-prompt",
              "update-profile"
            ],
       do: true

  defp orchestrator_current_decision?(_decision), do: false

  defp orchestrator_decision(profile, events, opts, latest_by_ref) do
    state = get_in(profile, [:comparison, :state])
    auto_plan_decision = orchestrator_auto_plan_decision(profile, events, opts, latest_by_ref)

    cond do
      parked_blocked_profile?(profile) ->
        nil

      state == "awaiting-observation" ->
        orchestrator_observe_decision(profile, events)

      stale_profile?(profile) ->
        orchestrator_stale_observe_decision(profile, events)

      draft_prompt_ready_candidate?(profile, state) ->
        orchestrator_mark_ready_decision(profile, events)

      state == "ready-to-send" ->
        orchestrator_send_decision(profile, events)

      auto_plan_decision ->
        auto_plan_decision

      state == "blocked" ->
        orchestrator_hold_decision(profile, events)

      state == "needs-attention" ->
        orchestrator_attention_decision(profile, events)

      state in ["needs-profile", "needs-prompt"] ->
        orchestrator_plan_decision(profile, events)

      true ->
        nil
    end
  end

  defp parked_blocked_profile?(profile) do
    get_in(profile, [:next_prompt, :status]) == "blocked" or
      get_in(profile, [:planned, :prompt_status]) == "blocked"
  end

  defp stale_profile?(profile), do: get_in(profile, [:timing, :stale]) == true

  defp orchestrator_auto_plan_decision(profile, events, opts, latest_by_ref) do
    if Keyword.get(opts, :auto_plan, false) do
      observation = Map.get(latest_by_ref, profile.ref)

      case OrchestratorPlanner.plan(profile, observation) do
        {:ok, plan} ->
          %{
            id: orchestrator_decision_id(profile, "auto-plan-next", plan.prompt),
            action: "auto-plan-next",
            safety: plan.safety,
            status: "planned",
            ref: profile.ref,
            state: get_in(profile, [:comparison, :state]),
            prompt_status: get_in(profile, [:next_prompt, :status]),
            message: plan.prompt,
            profile_update: %{
              next_prompt: plan.prompt,
              prompt_status: plan.prompt_status,
              strategy: "Auto-planned by orchestrator: #{plan.reason}",
              notes: planner_notes(plan),
              last_seen_at: DateTime.utc_now()
            },
            reason: plan.reason,
            evidence: plan.evidence,
            event_ids: Enum.map(events, & &1.id)
          }

        {:skip, _reason} ->
          orchestrator_auto_hold_decision(profile, events, observation)
      end
    end
  end

  defp orchestrator_auto_hold_decision(profile, events, observation) do
    case OrchestratorPlanner.hold(profile, observation) do
      {:ok, hold} ->
        %{
          id: orchestrator_decision_id(profile, "auto-hold", hold.reason),
          action: "auto-hold",
          safety: hold.safety,
          status: "planned",
          ref: profile.ref,
          state: get_in(profile, [:comparison, :state]),
          prompt_status: get_in(profile, [:next_prompt, :status]),
          message: "",
          profile_update: %{
            next_prompt: "",
            prompt_status: hold.prompt_status,
            strategy: "Auto-held by orchestrator: #{hold.reason}",
            notes: planner_notes(hold),
            last_seen_at: DateTime.utc_now()
          },
          reason: hold.reason,
          evidence: hold.evidence,
          event_ids: Enum.map(events, & &1.id)
        }

      {:skip, _reason} ->
        nil
    end
  end

  defp draft_prompt_ready_candidate?(profile, state) do
    state != "blocked" and
      not running_session?(profile) and
      get_in(profile, [:session, :can_direct]) == true and
      get_in(profile, [:next_prompt, :source]) == "profile" and
      get_in(profile, [:next_prompt, :status]) == "draft" and
      text_present?(get_in(profile, [:next_prompt, :text]))
  end

  defp running_session?(profile), do: get_in(profile, [:actual, :work_state]) == "running"

  defp orchestrator_mark_ready_decision(profile, events) do
    message = get_in(profile, [:next_prompt, :text]) || ""

    %{
      id: orchestrator_decision_id(profile, "mark-prompt-ready", message),
      action: "mark-prompt-ready",
      safety: "safe",
      status: "planned",
      ref: profile.ref,
      state: get_in(profile, [:comparison, :state]),
      prompt_status: get_in(profile, [:next_prompt, :status]),
      message: message,
      reason: "draft prompt is chambered; mark ready for gated send",
      event_ids: Enum.map(events, & &1.id)
    }
  end

  defp orchestrator_send_decision(profile, events) do
    message = get_in(profile, [:next_prompt, :text]) || ""

    if running_session?(profile) do
      nil
    else
      %{
        id: orchestrator_decision_id(profile, "send-profile-prompt", message),
        action: "send-profile-prompt",
        safety: "gated",
        status: "planned",
        ref: profile.ref,
        state: get_in(profile, [:comparison, :state]),
        prompt_status: get_in(profile, [:next_prompt, :status]),
        message: message,
        reason: "profile has a ready chambered prompt and the session is directable",
        event_ids: Enum.map(events, & &1.id)
      }
    end
  end

  defp orchestrator_observe_decision(profile, events) do
    %{
      id: orchestrator_decision_id(profile, "observe", ""),
      action: "observe",
      safety: "inspect",
      status: "planned",
      ref: profile.ref,
      state: get_in(profile, [:comparison, :state]),
      prompt_status: get_in(profile, [:next_prompt, :status]),
      message: "",
      directive_sent_at: get_in(profile, [:actual, :last_directive, :sent_at]),
      directive_message:
        first_present([
          get_in(profile, [:next_prompt, :text]),
          get_in(profile, [:actual, :last_directive, :message])
        ]),
      reason: "a directive was sent; observe before sending again",
      event_ids: Enum.map(events, & &1.id)
    }
  end

  defp orchestrator_stale_observe_decision(profile, events) do
    %{
      id: orchestrator_decision_id(profile, "observe-stale", ""),
      action: "observe",
      safety: "inspect",
      status: "planned",
      ref: profile.ref,
      state: get_in(profile, [:comparison, :state]),
      prompt_status: get_in(profile, [:next_prompt, :status]),
      message: "",
      clear_after_observe: false,
      reason: get_in(profile, [:timing, :next_check]) || "profile observation is stale",
      event_ids: Enum.map(events, & &1.id)
    }
  end

  defp orchestrator_hold_decision(profile, events) do
    %{
      id: orchestrator_decision_id(profile, "hold", ""),
      action: "hold",
      safety: "manual",
      status: "planned",
      ref: profile.ref,
      state: get_in(profile, [:comparison, :state]),
      prompt_status: get_in(profile, [:next_prompt, :status]),
      message: "",
      reason: profile.next_step || "session is blocked",
      event_ids: Enum.map(events, & &1.id)
    }
  end

  defp orchestrator_attention_decision(profile, events) do
    %{
      id: orchestrator_decision_id(profile, "review-attention", ""),
      action: "review-attention",
      safety: "manual",
      status: "planned",
      ref: profile.ref,
      state: get_in(profile, [:comparison, :state]),
      prompt_status: get_in(profile, [:next_prompt, :status]),
      message: get_in(profile, [:next_prompt, :text]) || "",
      reason: profile.next_step || "session needs attention",
      event_ids: Enum.map(events, & &1.id)
    }
  end

  defp orchestrator_plan_decision(profile, events) do
    profile_update = orchestrator_profile_update(profile)

    if profile_update_changes?(profile, profile_update) do
      %{
        id: orchestrator_decision_id(profile, "update-profile", ""),
        action: "update-profile",
        safety: "safe",
        status: "planned",
        ref: profile.ref,
        state: get_in(profile, [:comparison, :state]),
        prompt_status: get_in(profile, [:next_prompt, :status]),
        message: get_in(profile, [:next_prompt, :text]) || "",
        profile_update: profile_update,
        reason: profile.next_step || "profile needs planning",
        event_ids: Enum.map(events, & &1.id)
      }
    end
  end

  defp orchestrator_profile_update(profile) do
    next_prompt =
      if get_in(profile, [:next_prompt, :source]) == "profile" do
        get_in(profile, [:next_prompt, :text]) || ""
      else
        ""
      end

    %{
      summary:
        first_present([
          get_in(profile, [:planned, :summary]),
          get_in(profile, [:actual, :summary]),
          get_in(profile, [:actual, :task]),
          get_in(profile, [:session, :project]),
          profile.ref
        ]),
      objective:
        first_present([
          get_in(profile, [:planned, :objective]),
          "Track this session and determine the next safe action."
        ]),
      expected_completion:
        first_present([
          get_in(profile, [:planned, :expected_completion]),
          "After the next observation or chambered prompt."
        ]),
      next_prompt: next_prompt,
      prompt_status: if(String.trim(next_prompt) == "", do: "none", else: "draft"),
      notes:
        first_present([
          get_in(profile, [:planned, :notes]),
          "Bootstrapped by orchestrator from live observation."
        ]),
      last_seen_at: DateTime.utc_now()
    }
  end

  defp profile_update_changes?(profile, update) do
    [
      {:summary, [:planned, :summary]},
      {:objective, [:planned, :objective]},
      {:expected_completion, [:planned, :expected_completion]},
      {:next_prompt, [:planned, :next_prompt]},
      {:prompt_status, [:planned, :prompt_status]},
      {:notes, [:planned, :notes]}
    ]
    |> Enum.any?(fn {update_key, profile_path} ->
      normalize_optional(Map.get(update, update_key)) !=
        normalize_optional(get_in(profile, profile_path))
    end)
  end

  defp normalize_optional(value) when is_binary(value), do: String.trim(value)
  defp normalize_optional(nil), do: ""
  defp normalize_optional(value), do: to_string(value)

  defp planner_notes(plan) do
    evidence =
      plan.evidence
      |> Enum.map(&"- #{&1}")
      |> Enum.join("\n")

    if evidence == "" do
      "Auto-planned from the latest completed session observation."
    else
      "Auto-planned from the latest completed session observation.\n#{evidence}"
    end
  end

  defp latest_observations_by_ref(profiles) do
    refs =
      profiles
      |> Enum.map(& &1.ref)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    refs
    |> latest_observations()
    |> Map.new(&{&1.ref, &1})
  end

  defp latest_observations([]), do: []

  defp latest_observations(refs) do
    refs_set = MapSet.new(refs)

    list_session_observations(limit: max(length(refs) * 5, 100))
    |> Enum.filter(&MapSet.member?(refs_set, &1.ref))
    |> Enum.group_by(& &1.ref)
    |> Enum.map(fn {_ref, observations} -> Enum.max_by(observations, & &1.id) end)
  end

  defp planner_suggestions(profiles, latest_by_ref, limit) do
    profiles
    |> Enum.flat_map(fn profile ->
      case OrchestratorPlanner.plan(profile, Map.get(latest_by_ref, profile.ref)) do
        {:ok, plan} -> [orchestrator_inbox_suggestion(profile, plan)]
        {:skip, _reason} -> []
      end
    end)
    |> Enum.take(limit)
  end

  defp orchestrator_inbox_suggestion(profile, plan) do
    %{
      ref: profile.ref,
      project: get_in(profile, [:session, :project]) || "",
      work_state: get_in(profile, [:actual, :work_state]) || "",
      safety: plan.safety,
      prompt_status: plan.prompt_status,
      reason: plan.reason,
      prompt: plan.prompt,
      evidence: plan.evidence
    }
  end

  defp orchestrator_inbox_item(profile, suggestions) do
    suggestion = Enum.find(suggestions, &(&1.ref == profile.ref))

    %{
      ref: profile.ref,
      project: get_in(profile, [:session, :project]) || "",
      type: get_in(profile, [:session, :type]) || "",
      kind: get_in(profile, [:session, :kind]) || "",
      pane: get_in(profile, [:session, :pane]) || "",
      control_mode: get_in(profile, [:session, :control_mode]) || "",
      state: get_in(profile, [:comparison, :state]) || "",
      work_state: get_in(profile, [:actual, :work_state]) || "",
      prompt_status: get_in(profile, [:next_prompt, :status]) || "",
      next_step: profile.next_step || "",
      actual: get_in(profile, [:comparison, :actual_summary]) || "",
      objective: get_in(profile, [:planned, :objective]) || "",
      expected_completion: get_in(profile, [:planned, :expected_completion]) || "",
      repo_blockers: get_in(profile, [:comparison, :repo_blockers]) || [],
      repo_risks: get_in(profile, [:comparison, :repo_risks]) || [],
      suggested_plan: suggestion
    }
  end

  defp inbox_needs_judgment?(item) do
    item.state in ["blocked", "needs-attention"] or item.repo_blockers != [] or
      item.prompt_status == "blocked"
  end

  defp inbox_ready?(item) do
    not inbox_needs_judgment?(item) and
      (item.state == "ready-to-send" or item.prompt_status in ["ready", "draft"] or
         not is_nil(item.suggested_plan))
  end

  defp inbox_awaiting_observation?(item), do: item.state == "awaiting-observation"

  defp inbox_recently_completed?(item) do
    item.work_state == "idle" and item.state in ["tracking", "needs-prompt"] and
      item.actual != ""
  end

  defp latest_session_observation(ref) do
    list_session_observations(ref: ref, limit: 1)
    |> List.first()
  end

  defp observation_summary(nil), do: nil

  defp observation_summary(observation) do
    %{
      id: observation.id,
      inserted_at: observation.inserted_at,
      work_state: observation.work_state,
      capture_status: observation.capture_status,
      summary: observation.summary || ""
    }
  end

  defp orchestrator_review_recommendation(profile, observation) do
    cond do
      get_in(profile, [:planned, :prompt_status]) == "blocked" or
          get_in(profile, [:next_prompt, :status]) == "blocked" ->
        %{
          type: "manual-review",
          safety: "manual",
          reason: "profile is held for review",
          prompt: "",
          evidence: profile_block_evidence(profile)
        }

      true ->
        planner_review_recommendation(profile, observation)
    end
  end

  defp planner_review_recommendation(profile, observation) do
    case OrchestratorPlanner.plan(profile, observation) do
      {:ok, plan} ->
        %{
          type: "safe-continuation",
          safety: plan.safety,
          reason: plan.reason,
          prompt: plan.prompt,
          evidence: plan.evidence
        }

      {:skip, _reason} ->
        hold_review_recommendation(profile, observation)
    end
  end

  defp hold_review_recommendation(profile, observation) do
    case OrchestratorPlanner.hold(profile, observation) do
      {:ok, hold} ->
        %{
          type: "hold",
          safety: hold.safety,
          reason: hold.reason,
          prompt: "",
          evidence: hold.evidence
        }

      {:skip, _reason} ->
        fallback_review_recommendation(profile)
    end
  end

  defp fallback_review_recommendation(profile) do
    state = get_in(profile, [:comparison, :state]) || ""

    cond do
      state == "awaiting-observation" ->
        %{
          type: "observe",
          safety: "inspect",
          reason: "sent directive is awaiting observation",
          prompt: "",
          evidence: profile_block_evidence(profile)
        }

      state == "ready-to-send" ->
        %{
          type: "send-ready",
          safety: "gated",
          reason: "profile has a ready prompt",
          prompt: get_in(profile, [:next_prompt, :text]) || "",
          evidence: profile_block_evidence(profile)
        }

      state == "blocked" ->
        %{
          type: "manual-review",
          safety: "manual",
          reason: profile.next_step || "session is blocked",
          prompt: "",
          evidence: profile_block_evidence(profile)
        }

      true ->
        %{
          type: "status",
          safety: "inspect",
          reason: profile.next_step || "review current session state",
          prompt: "",
          evidence: profile_block_evidence(profile)
        }
    end
  end

  defp profile_block_evidence(profile) do
    [
      get_in(profile, [:planned, :strategy]),
      get_in(profile, [:planned, :notes]),
      get_in(profile, [:comparison, :actual_summary]),
      profile.next_step
    ]
    |> Enum.filter(&text_present?/1)
    |> Enum.take(6)
  end

  defp orchestrator_review_commands(ref, _profile, recommendation, lines) do
    base = [
      %{action: "attach", command: "jx session attach #{ref}"},
      %{action: "capture", command: "jx session capture #{ref} -n #{lines}"},
      %{action: "hold", command: "jx orchestrator decide #{ref} --hold \"<reason>\""},
      %{action: "clear", command: "jx orchestrator decide #{ref} --clear"}
    ]

    case recommendation.type do
      "safe-continuation" ->
        [
          %{
            action: "accept-plan",
            command:
              "jx orchestrator decide #{ref} --prompt \"#{shell_preview(recommendation.prompt)}\" --ready"
          }
          | base
        ]

      "send-ready" ->
        [
          %{action: "send-ready", command: "jx orchestrate step --execute --yes --auto-plan"}
          | base
        ]

      "observe" ->
        [
          %{action: "observe", command: "jx orchestrate step --execute --yes --auto-plan"}
          | base
        ]

      _other ->
        base
    end
  end

  defp shell_preview(value) do
    value
    |> to_string()
    |> String.replace("\"", "\\\"")
    |> truncate_text(160)
  end

  defp orchestrator_decide_prompt(ref, attrs) do
    prompt = Map.get(attrs, :prompt, "")
    prompt_status = Map.get(attrs, :prompt_status, "ready")

    cond do
      not text_present?(prompt) ->
        {:error, :prompt_required}

      prompt_status not in ["draft", "ready"] ->
        {:error, :invalid_prompt_status}

      true ->
        set_session_profile(ref, %{
          next_prompt: prompt,
          prompt_status: prompt_status,
          strategy: "Manual orchestrator decision: queued prompt",
          notes: Map.get(attrs, :notes, ""),
          last_seen_at: DateTime.utc_now()
        })
        |> wrap_orchestrator_decision(ref, "prompt", "profile prompt queued")
    end
  end

  defp wrap_orchestrator_decision({:ok, result}, ref, action, summary) do
    {:ok, %{ref: ref, action: action, result_summary: summary, result: result}}
  end

  defp wrap_orchestrator_decision({:error, reason}, _ref, _action, _summary), do: {:error, reason}

  defp execute_orchestrator_decisions(decisions, false, _opts) do
    %{
      requested: "orchestrate",
      mode: "dry-run",
      executed: [],
      skipped: Enum.map(decisions, &Map.put(&1, :status, "planned")),
      audit: %{saved: 0, errors: []}
    }
  end

  defp execute_orchestrator_decisions(decisions, true, opts) do
    results = Enum.map(decisions, &execute_orchestrator_decision(&1, opts))

    %{
      requested: "orchestrate",
      mode: "execute",
      executed: Enum.filter(results, &(&1.status == "executed")),
      skipped: Enum.reject(results, &(&1.status == "executed")),
      audit: OperationExecutions.audit_results("orchestrate", results)
    }
  end

  defp execute_orchestrator_decision(%{action: "send-profile-prompt"} = decision, opts) do
    cond do
      not Keyword.get(opts, :yes, false) ->
        decision
        |> Map.merge(%{
          status: "skipped",
          reason: "send-profile-prompt requires --yes"
        })
        |> Map.delete(:message)

      String.trim(decision.message || "") == "" ->
        decision
        |> Map.merge(%{status: "skipped", reason: "no chambered prompt text"})
        |> Map.delete(:message)

      true ->
        case send_session_prompt(decision.ref, decision.message,
               enter: Keyword.get(opts, :enter, true),
               lines: Keyword.get(opts, :lines, 80)
             ) do
          {:ok, directive} ->
            decision
            |> Map.merge(%{
              status: "executed",
              directive_id: directive.directive_id,
              result_summary: "sent #{directive.directive_id}"
            })
            |> Map.delete(:message)

          {:error, reason} ->
            decision
            |> Map.merge(%{status: "error", error: inspect(reason)})
            |> Map.delete(:message)
        end
    end
  end

  defp execute_orchestrator_decision(%{action: "update-profile"} = decision, _opts) do
    case set_session_profile(decision.ref, decision.profile_update) do
      {:ok, _profile} ->
        decision
        |> Map.merge(%{status: "executed", result_summary: "profile updated"})
        |> Map.delete(:message)

      {:error, reason} ->
        decision
        |> Map.merge(%{status: "error", error: inspect(reason)})
        |> Map.delete(:message)
    end
  end

  defp execute_orchestrator_decision(%{action: "auto-plan-next"} = decision, _opts) do
    case set_session_profile(decision.ref, decision.profile_update) do
      {:ok, _profile} ->
        decision
        |> Map.merge(%{status: "executed", result_summary: "next prompt auto-planned"})
        |> Map.delete(:message)

      {:error, reason} ->
        decision
        |> Map.merge(%{status: "error", error: inspect(reason)})
        |> Map.delete(:message)
    end
  end

  defp execute_orchestrator_decision(%{action: "auto-hold"} = decision, _opts) do
    case set_session_profile(decision.ref, decision.profile_update) do
      {:ok, _profile} ->
        decision
        |> Map.merge(%{status: "executed", result_summary: "profile marked blocked for review"})
        |> Map.delete(:message)

      {:error, reason} ->
        decision
        |> Map.merge(%{status: "error", error: inspect(reason)})
        |> Map.delete(:message)
    end
  end

  defp execute_orchestrator_decision(%{action: "mark-prompt-ready"} = decision, _opts) do
    case set_session_profile(decision.ref, %{
           next_prompt: decision.message,
           prompt_status: "ready",
           last_seen_at: DateTime.utc_now()
         }) do
      {:ok, _profile} ->
        decision
        |> Map.merge(%{status: "executed", result_summary: "prompt marked ready"})
        |> Map.delete(:message)

      {:error, reason} ->
        decision
        |> Map.merge(%{status: "error", error: inspect(reason)})
        |> Map.delete(:message)
    end
  end

  defp execute_orchestrator_decision(%{action: "observe"} = decision, opts) do
    with :ok <- authorize_observe_age(decision, opts),
         {:ok, report} <- observe_sessions(orchestrator_observe_opts(decision, opts)) do
      execute_orchestrator_observe_result(decision, report)
    else
      {:skip, reason} ->
        decision
        |> Map.merge(%{status: "skipped", reason: reason})
        |> Map.delete(:message)

      {:error, reason} ->
        decision
        |> Map.merge(%{status: "error", error: inspect(reason)})
        |> Map.delete(:message)
    end
  end

  defp execute_orchestrator_decision(%{action: "review-ci-watch"} = decision, _opts) do
    case review_ci_watch(decision.recommendation_id, logs: false) do
      {:ok, review} ->
        decision
        |> Map.merge(%{
          status: "executed",
          result_summary: first_present([Map.get(review, :summary), "CI watch reviewed"])
        })
        |> Map.delete(:message)

      {:error, reason} ->
        decision
        |> Map.merge(%{status: "error", error: inspect(reason)})
        |> Map.delete(:message)
    end
  end

  defp execute_orchestrator_decision(%{action: "review-call-handoff"} = decision, _opts) do
    case open_call_handoff(decision.recommendation_id) do
      {:ok, handoff} ->
        decision
        |> Map.merge(%{
          status: "executed",
          result_summary: first_present([handoff.title, handoff.summary, "call handoff reviewed"])
        })
        |> Map.delete(:message)

      {:error, reason} ->
        decision
        |> Map.merge(%{status: "error", error: inspect(reason)})
        |> Map.delete(:message)
    end
  end

  defp execute_orchestrator_decision(%{action: "decide-delegation-review"} = decision, _opts) do
    case delegation_review(decision.recommendation_id) do
      {:ok, review} ->
        decision
        |> Map.merge(%{
          status: "executed",
          result_summary:
            first_present([
              Map.get(review, :worker_summary),
              Map.get(review, :title),
              "delegation review inspected"
            ])
        })
        |> Map.delete(:message)

      {:error, reason} ->
        decision
        |> Map.merge(%{status: "error", error: inspect(reason)})
        |> Map.delete(:message)
    end
  end

  defp execute_orchestrator_decision(decision, _opts) do
    decision
    |> Map.merge(%{status: "skipped", reason: "no executable handler for #{decision.action}"})
    |> Map.delete(:message)
  end

  defp execute_orchestrator_observe_result(decision, %{saved: saved, errors: []} = report)
       when saved > 0 do
    if Map.get(decision, :clear_after_observe, true) == false do
      decision
      |> Map.merge(%{
        status: "executed",
        result_summary: "observed #{saved} session",
        observations_saved: saved,
        changes: Enum.map(report.changes, &orchestrator_change_summary/1)
      })
      |> Map.delete(:message)
    else
      execute_orchestrator_observe_sent_result(decision, report, saved)
    end
  end

  defp execute_orchestrator_observe_result(decision, %{saved: 0, errors: []}) do
    decision
    |> Map.merge(%{status: "skipped", reason: "session not found for observation"})
    |> Map.delete(:message)
  end

  defp execute_orchestrator_observe_result(decision, %{saved: saved, errors: errors}) do
    decision
    |> Map.merge(%{
      status: "error",
      observations_saved: saved,
      error: inspect(errors)
    })
    |> Map.delete(:message)
  end

  defp execute_orchestrator_observe_sent_result(decision, report, saved) do
    if meaningful_observation_saved?(decision, report.observations) do
      case clear_sent_profile(decision.ref) do
        {:ok, _profile} ->
          decision
          |> Map.merge(%{
            status: "executed",
            result_summary: "observed #{saved} session",
            observations_saved: saved,
            changes: Enum.map(report.changes, &orchestrator_change_summary/1)
          })
          |> Map.delete(:message)

        {:error, reason} ->
          decision
          |> Map.merge(%{
            status: "error",
            observations_saved: saved,
            error: "observed session but failed to clear sent profile: #{inspect(reason)}"
          })
          |> Map.delete(:message)
      end
    else
      decision
      |> Map.merge(%{
        status: "skipped",
        reason: "observation did not contain a meaningful session response yet",
        observations_saved: saved,
        changes: Enum.map(report.changes, &orchestrator_change_summary/1)
      })
      |> Map.delete(:message)
    end
  end

  defp meaningful_observation_saved?(decision, observations) do
    Enum.any?(observations, fn observation ->
      output = observation_output(observation)

      observation_complete?(observation, output) and
        meaningful_response_for_decision?(decision, observation, output)
    end)
  end

  defp observation_complete?(%{work_state: "running"}, _output), do: false

  defp observation_complete?(_observation, output) do
    not SessionStatus.approval_prompt?(output) and
      not SessionStatus.active_work?(output) and
      not SessionStatus.interrupt_hint?(output) and
      not SessionStatus.staged_prompt?(output)
  end

  defp meaningful_response_for_decision?(decision, observation, output) do
    marker = Map.get(decision, :directive_message)

    SessionStatus.final_response_after?(output, marker) or
      truncated_meaningful_response?(decision, observation, output, marker)
  end

  defp truncated_meaningful_response?(decision, observation, output, marker) do
    text_present?(marker) and
      not normalized_contains?(output, marker) and
      observation_after_directive?(decision, observation) and
      SessionStatus.final_response?(output)
  end

  defp normalized_contains?(output, marker) do
    output
    |> normalize_space()
    |> String.contains?(normalize_space(marker))
  end

  defp normalize_space(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp observation_after_directive?(decision, %{inserted_at: %DateTime{} = observed_at}) do
    case parse_optional_time(Map.get(decision, :directive_sent_at)) do
      {:ok, %DateTime{} = sent_at} -> DateTime.compare(observed_at, sent_at) != :lt
      _other -> false
    end
  end

  defp observation_after_directive?(_decision, _observation), do: false

  defp observation_output(%{snapshot: snapshot, summary: summary}) do
    case Jason.decode(snapshot || "") do
      {:ok, %{"capture" => %{"output" => output}}} when is_binary(output) ->
        output

      _other ->
        summary || ""
    end
  end

  defp observation_output(%{summary: summary}), do: summary || ""
  defp observation_output(_observation), do: ""

  defp authorize_observe_age(decision, opts) do
    min_age_seconds = Keyword.get(opts, :min_observe_age_seconds, 30)

    case parse_optional_time(Map.get(decision, :directive_sent_at)) do
      {:ok, nil} ->
        :ok

      {:ok, sent_at} ->
        age_seconds = DateTime.diff(DateTime.utc_now(), sent_at, :second)

        if age_seconds >= min_age_seconds do
          :ok
        else
          {:skip,
           "directive is too recent to observe (#{age_seconds}s old; wait #{min_age_seconds}s)"}
        end
    end
  end

  defp parse_optional_time(nil), do: {:ok, nil}
  defp parse_optional_time(""), do: {:ok, nil}

  defp parse_optional_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:ok, nil}
    end
  end

  defp parse_optional_time(_value), do: {:ok, nil}

  defp orchestrator_observe_opts(decision, opts) do
    opts
    |> Keyword.take([
      :host_name,
      :all_tmux,
      :all_processes,
      :type,
      :ssh_target,
      :work_state,
      :lines
    ])
    |> Keyword.put_new(:lines, 160)
    |> Keyword.put(:ref, decision.ref)
    |> Keyword.put(:attention, false)
  end

  defp clear_sent_profile(ref) do
    set_session_profile(ref, %{
      next_prompt: "",
      prompt_status: "none",
      last_seen_at: DateTime.utc_now()
    })
  end

  defp orchestrator_change_summary(change) do
    %{
      ref: change.ref,
      work_state: change.work_state,
      capture_status: change.capture_status,
      change: change.change,
      changed_fields: change.changed_fields,
      summary: change.summary
    }
  end

  defp text_present?(value) when is_binary(value), do: String.trim(value) != ""
  defp text_present?(_value), do: false

  defp maybe_ack_orchestrator(consumer, latest_event_id, true) do
    case acknowledge_monitor_events(consumer: consumer, to_id: latest_event_id) do
      {:ok, cursor} ->
        {cursor, []}

      {:error, reason} ->
        {nil, [%{host: "", transport: "", subsystem: "event-cursor", error: reason}]}
    end
  end

  defp maybe_ack_orchestrator(_consumer, _latest_event_id, false), do: {nil, []}

  defp orchestrator_ack_id(%{events: []} = inbox), do: inbox.latest_event_id

  defp orchestrator_ack_id(%{events: events}) do
    events
    |> Enum.map(& &1.id)
    |> Enum.max()
  end

  defp orchestrator_mode(true, true), do: "execute+ack"
  defp orchestrator_mode(true, false), do: "execute"
  defp orchestrator_mode(false, true), do: "ack"
  defp orchestrator_mode(false, false), do: "dry-run"

  defp orchestrator_decision_id(profile, action, message) do
    source = [
      profile.ref,
      action,
      get_in(profile, [:comparison, :state]),
      get_in(profile, [:next_prompt, :status]),
      message
    ]

    hash =
      :crypto.hash(:sha256, Enum.intersperse(source, <<0>>))
      |> Base.encode16(case: :lower)

    "orc-" <> binary_part(hash, 0, 10)
  end

  defp session_profile_scan_limit(nil, limit), do: limit
  defp session_profile_scan_limit(_prompt_status, limit), do: max(limit, 100)

  defp limit_session_profile_report(report, limit) do
    profiles = Enum.take(report.profiles, limit)

    report
    |> Map.put(:profiles, profiles)
    |> Map.put(:total, length(profiles))
  end

  defp validate_manage_policy("conservative"), do: :ok
  defp validate_manage_policy(policy), do: {:error, {:unsupported_manage_policy, policy}}

  defp build_work_board(report, observe?, limit, control_mode) do
    items =
      report.sessions
      |> build_work_board_items(control_mode)
      |> Enum.take(limit)

    reviews = delegation_reviews(integration_status: "pending", limit: limit)

    %{
      generated_at: DateTime.utc_now(),
      observed: observe?,
      total: length(items),
      items: items,
      delegation_reviews_total: length(reviews),
      delegation_reviews: reviews,
      delegation_timing: delegation_timing(limit: limit),
      errors: report.errors
    }
  end

  defp build_work_board_items(sessions, control_mode) do
    sessions
    |> Enum.map(&work_board_item/1)
    |> filter_work_board_control(control_mode)
  end

  defp filter_work_board_ref(items, nil), do: items
  defp filter_work_board_ref(items, ref), do: Enum.filter(items, &(&1.ref == ref))

  defp filter_snapshot_ref(sessions, nil), do: sessions
  defp filter_snapshot_ref(sessions, ref), do: Enum.filter(sessions, &(&1.ref == ref))

  defp filter_dossier_next_action(dossiers, nil), do: dossiers

  defp filter_dossier_next_action(dossiers, next_action) do
    Enum.filter(dossiers, &(get_in(&1, [:next_action, :action]) == next_action))
  end

  defp filter_dossier_project(dossiers, nil, _registered_projects), do: dossiers
  defp filter_dossier_project(dossiers, "", _registered_projects), do: dossiers

  defp filter_dossier_project(dossiers, project, registered_projects) do
    Enum.filter(dossiers, &ProjectMatcher.matches_dossier?(&1, project, registered_projects))
  end

  defp filter_sessions_project_hint(sessions, nil, _registered_projects), do: sessions
  defp filter_sessions_project_hint(sessions, "", _registered_projects), do: sessions

  defp filter_sessions_project_hint(sessions, project, registered_projects) do
    Enum.filter(sessions, fn session ->
      explicit =
        first_present([
          Map.get(session, :control_project),
          Map.get(session, :project)
        ])

      explicit == project or
        ProjectMatcher.path_matches_project?(
          [Map.get(session, :current_path)],
          registered_projects || []
        )
    end)
  end

  defp filter_projects_by_host(projects, nil), do: projects
  defp filter_projects_by_host(projects, ""), do: projects

  defp filter_projects_by_host(projects, host_name) do
    Enum.filter(projects, &(get_in(&1, [Access.key(:host), Access.key(:name)]) == host_name))
  end

  defp dossier_changes([], _limit), do: []

  defp dossier_changes(refs, limit) do
    list_session_changes(
      refs: refs,
      limit: max(limit, 1),
      history_limit: max(limit * 5, 100)
    )
  end

  defp work_board_item(session) do
    capture = Map.get(session, :capture, %{})
    control_mode = Map.get(session, :control_mode, "uncontrolled")
    work_state = Map.get(capture, :work_state, "")
    capture_status = Map.get(capture, :status, "")
    allowed = work_board_allowed_action(session, capture)

    %{
      ref: session.ref,
      host: session.host,
      type: session.type,
      kind: session.kind,
      process_role: Map.get(session, :process_role, ""),
      resume_available: Map.get(session, :resume_available, false),
      resume_ref: Map.get(session, :resume_ref, ""),
      zed_workspace: Map.get(session, :zed_workspace, ""),
      state: session.state,
      control_mode: control_mode,
      control_project: Map.get(session, :control_project, ""),
      project: work_board_project(session),
      task: work_board_task(session, capture),
      task_id: session.task_id,
      agent_name: session.agent_name,
      ssh_target: session.ssh_target,
      tmux_server: Map.get(session, :server, ""),
      session_name: Map.get(session, :session, ""),
      window: Map.get(session, :window),
      pane_index: Map.get(session, :pane),
      pane: work_board_pane(session),
      current_path: session.current_path,
      title: session.title,
      git: work_board_git(session),
      work_state: work_state,
      capture_status: capture_status,
      summary: work_board_summary(capture),
      actions: session.actions,
      allowed_action: allowed.action,
      can_direct: allowed.can_direct,
      reason: allowed.reason
    }
  end

  defp filter_work_board_control(items, nil), do: items
  defp filter_work_board_control(items, mode), do: Enum.filter(items, &(&1.control_mode == mode))

  defp work_board_allowed_action(session, capture) do
    actions = session_actions(session)
    capture_status = Map.get(capture, :status)
    send_capable? = send_capable?(actions, capture)

    cond do
      Map.get(session, :control_mode) == "protected" ->
        %{action: "none", can_direct: false, reason: "protected"}

      Map.get(session, :control_mode) == "ignored" ->
        %{action: "none", can_direct: false, reason: "ignored"}

      send_capable? and session.type == "task" and capture_status == "ok" ->
        %{action: "send", can_direct: true, reason: "task-owned with fresh capture"}

      send_capable? and SessionControls.managed?(session) and capture_status == "ok" ->
        %{action: "send", can_direct: true, reason: send_capable_reason(actions)}

      send_capable? and SessionControls.managed?(session) ->
        %{action: "capture-first", can_direct: false, reason: "fresh capture required"}

      send_capable? ->
        %{action: "mark-managed", can_direct: false, reason: "mark managed before directing"}

      "adopt" in actions ->
        %{action: "adopt", can_direct: false, reason: "can be linked to a task record"}

      "resume-adopt" in actions ->
        %{
          action: "resume-adopt",
          can_direct: false,
          reason: "Zed/ACP agent can be relaunched with resume context"
        }

      "stream-adopt" in actions ->
        %{
          action: "stream-adopt",
          can_direct: false,
          reason: "process-only agent needs managed stream bridge"
        }

      "capture" in actions ->
        %{action: "capture", can_direct: false, reason: "read-only capture available"}

      "inspect" in actions ->
        %{action: "inspect", can_direct: false, reason: "process-only inspection available"}

      true ->
        %{action: "observe", can_direct: false, reason: "no direct action available"}
    end
  end

  defp work_board_project(session) do
    first_present([
      Map.get(session, :control_project),
      Map.get(session, :project)
    ])
  end

  defp work_board_task(session, capture) do
    first_present([
      Map.get(session, :task_id),
      work_board_task_from_capture(capture),
      Map.get(session, :title),
      path_label(Map.get(session, :current_path))
    ])
  end

  defp work_board_task_from_capture(%{output: output}) when is_binary(output) and output != "" do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&clean_work_board_line/1)
    |> Enum.reject(&unhelpful_work_board_line?/1)
    |> List.last("")
    |> truncate_text(240)
  end

  defp work_board_task_from_capture(capture), do: work_board_summary(capture)

  defp clean_work_board_line(line) do
    line
    |> String.trim()
    |> String.replace(~r/^[┃│╹▣\s]+/u, "")
    |> String.trim()
  end

  defp unhelpful_work_board_line?(""), do: true

  defp unhelpful_work_board_line?(line) do
    Regex.match?(~r/^[─━┌┬┐├┼┤└┴┘│┃╹▀▁\s]+$/u, line) or
      Regex.match?(~r/^\d+(\.\d+)?[Kk]?\s+\(\d+%\).*ctrl\+p commands/i, line) or
      Regex.match?(~r/^\d+h\s+\d+%.*weekly/i, line) or
      Regex.match?(~r/^[❯>]$/u, line) or
      String.starts_with?(line, [
        "Build ·",
        "Thinking:",
        "Click to expand",
        "⏵⏵",
        "/clear"
      ])
  end

  defp work_board_summary(%{summary: summary}) when is_binary(summary) and summary != "" do
    summary
  end

  defp work_board_summary(%{output: output}) when is_binary(output) and output != "" do
    SessionStatus.summary(output, 240)
  end

  defp work_board_summary(%{error: error}) when is_binary(error), do: error
  defp work_board_summary(_capture), do: ""

  defp work_board_pane(%{server: server, session: session, window: window, pane: pane})
       when server not in [nil, ""] and session not in [nil, ""] do
    "#{server}/#{session}:#{window}.#{pane}"
  end

  defp work_board_pane(_session), do: ""

  defp session_actions(session) do
    session
    |> Map.get(:actions, "")
    |> String.split(",", trim: true)
  end

  defp send_capable?(actions, capture) do
    "send" in actions or agent_ui_capture?(capture)
  end

  defp send_capable_reason(actions) do
    if "send" in actions do
      "managed with fresh capture"
    else
      "managed agent UI capture with fresh capture"
    end
  end

  defp agent_ui_capture?(%{status: "ok", output: output}) when is_binary(output) do
    output = String.downcase(output)

    Enum.any?(
      [
        "claude code",
        "bypass permissions",
        "accept edits",
        "esc to interrupt",
        "new task? /clear",
        "ctrl+p commands",
        "do you want to proceed?",
        "would you like me"
      ],
      &String.contains?(output, &1)
    ) or opencode_capture?(output) or codex_capture?(output)
  end

  defp agent_ui_capture?(_capture), do: false

  defp opencode_capture?(output) do
    String.contains?(output, "opencode") and
      Enum.any?(["ctrl+p commands", "build ·", "context", "mcp"], &String.contains?(output, &1))
  end

  defp codex_capture?(output) do
    String.contains?(output, "codex") and
      Enum.any?(
        ["/skills", "esc to interrupt", "new task? /clear"],
        &String.contains?(output, &1)
      )
  end

  defp first_present(values) do
    Enum.find_value(values, "", fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _value ->
        nil
    end)
  end

  defp path_label(path) when is_binary(path) and path != "" do
    Path.basename(path)
  end

  defp path_label(_path), do: ""

  defp work_board_git(%{type: "ssh"}) do
    remote_git_unverified()
  end

  defp work_board_git(%{kind: "ssh"}) do
    remote_git_unverified()
  end

  defp work_board_git(%{current_path: path}), do: work_board_git(path)

  defp work_board_git(path) when is_binary(path) and path != "" do
    case git_cmd(path, ["status", "--porcelain=v1", "-b"]) do
      {:ok, output, 0} ->
        output
        |> parse_git_status()
        |> Map.put(:root, git_root(path))
        |> Map.merge(git_submodule_health(path))

      _error ->
        nil
    end
  end

  defp work_board_git(_path), do: nil

  defp remote_git_unverified do
    %{
      present: false,
      root: "",
      branch: "",
      upstream: "",
      dirty: false,
      changes: 0,
      untracked: 0,
      ahead: 0,
      behind: 0,
      submodules: "",
      submodule_error: "",
      remote_unverified: true
    }
  end

  defp parse_git_status(output) do
    [branch_line | status_lines] = String.split(output, "\n", trim: true)
    branch = parse_git_branch(branch_line)

    %{
      branch: branch.branch,
      upstream: branch.upstream,
      ahead: branch.ahead,
      behind: branch.behind,
      dirty: status_lines != [],
      changes: length(status_lines),
      untracked: Enum.count(status_lines, &String.starts_with?(&1, "?? "))
    }
  end

  defp parse_git_branch("## " <> line) do
    [branch_part | _rest] = String.split(line, " ", parts: 2)
    [branch_name | upstream_parts] = String.split(branch_part, "...", parts: 2)
    tracking = parse_git_tracking(line)

    %{
      branch: branch_name,
      upstream: List.first(upstream_parts) || "",
      ahead: tracking.ahead,
      behind: tracking.behind
    }
  end

  defp parse_git_branch(_line), do: %{branch: "", upstream: "", ahead: 0, behind: 0}

  defp parse_git_tracking(line) do
    %{
      ahead: parse_git_tracking_count(line, ~r/ahead (\d+)/),
      behind: parse_git_tracking_count(line, ~r/behind (\d+)/)
    }
  end

  defp parse_git_tracking_count(line, pattern) do
    case Regex.run(pattern, line) do
      [_match, count] -> String.to_integer(count)
      nil -> 0
    end
  end

  defp git_root(path) do
    case git_cmd(path, ["rev-parse", "--show-toplevel"]) do
      {:ok, output, 0} -> String.trim(output)
      _error -> ""
    end
  end

  defp git_submodule_health(path) do
    case git_cmd(path, ["submodule", "status"]) do
      {:ok, _output, 0} ->
        %{submodules: "ok", submodule_error: ""}

      {:ok, output, _status} ->
        %{submodules: "error", submodule_error: normalize_git_error(output)}

      {:error, :timeout} ->
        %{
          submodules: "timeout",
          submodule_error: "git submodule status timed out after #{@git_timeout_ms}ms"
        }
    end
  end

  defp git_cmd(path, args) do
    task =
      Task.async(fn ->
        System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
      end)

    case Task.yield(task, @git_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, status}} -> {:ok, output, status}
      _timeout -> {:error, :timeout}
    end
  end

  defp normalize_git_error(output) do
    output
    |> String.replace(~r/([^\n])((?:fatal|error): )/, "\\1\n\\2")
    |> String.trim()
  end

  defp truncate_text(value, max_length) do
    if String.length(value) > max_length do
      String.slice(value, 0, max_length - 3) <> "..."
    else
      value
    end
  end

  defp manage_iteration(iteration, opts, sleep_ms) do
    if iteration > 1 and sleep_ms > 0, do: Process.sleep(sleep_ms)

    opts
    |> Keyword.put(:observe, true)
    |> Keyword.put(:execute, "safe")
    |> operate()
    |> manage_iteration_result(iteration)
  end

  defp manage_iteration_result({:ok, operation}, iteration) do
    %{
      iteration: iteration,
      status: "ok",
      mode: operation.mode,
      observed: operation.observation_refresh.saved,
      executed: length(operation.execution.executed),
      skipped: length(operation.execution.skipped),
      audit: operation.execution.audit,
      attention: length(operation.attention),
      gated: length(operation.gated_actions),
      manual: length(operation.manual_actions)
    }
  end

  defp manage_iteration_result({:error, reason}, iteration) do
    %{
      iteration: iteration,
      status: "error",
      mode: "error",
      observed: 0,
      executed: 0,
      skipped: 0,
      audit: %{saved: 0, errors: []},
      attention: 0,
      gated: 0,
      manual: 0,
      error: inspect(reason)
    }
  end

  def broadcast_sessions(message, opts \\ []) do
    execute? = Keyword.get(opts, :execute, false)
    enter? = Keyword.get(opts, :enter, true)
    attention? = Keyword.get(opts, :attention, false)

    with {:ok, report} <- snapshot_sessions(opts) do
      targets =
        report.sessions
        |> Enum.filter(&broadcast_target?(&1, attention?))

      results =
        Enum.map(targets, fn session ->
          broadcast_result(session, message, execute?, enter?)
        end)

      {:ok, %{dry_run: !execute?, targets: results, errors: report.errors}}
    end
  end

  def remote_session_candidates(opts \\ []) do
    with {:ok, sessions} <- SSHSessions.list(Hosts.list_hosts()) do
      candidates =
        sessions
        |> PaneTransport.ssh_pane_candidates(target: Keyword.get(opts, :target))
        |> Enum.map(&Map.put(&1, :probe_action, remote_probe_action(&1)))

      {:ok, candidates}
    end
  end

  def probe_remote_sessions(opts \\ []) do
    with {:ok, sessions} <- SSHSessions.list(Hosts.list_hosts()) do
      candidates = PaneTransport.ssh_pane_candidates(sessions, target: Keyword.get(opts, :target))
      {manual, executable} = Enum.split_with(candidates, &remote_probe_manual?/1)
      {force_required, safe} = Enum.split_with(executable, &remote_probe_requires_force?/1)

      probe_candidates =
        if Keyword.get(opts, :force, false) do
          executable
        else
          safe
        end

      {:ok,
       manual_remote_probes(manual) ++
         skipped_remote_probes(force_required, Keyword.get(opts, :force, false)) ++
         PaneTransport.probe_ssh_candidates(probe_candidates,
           timeout_ms: Keyword.get(opts, :timeout_ms, 5_000)
         )}
    end
  end

  def get_session(ref, opts \\ []) do
    with {:ok, report} <- list_sessions(Keyword.put_new(opts, :all_processes, true)) do
      case SessionInventory.find(report.sessions, ref) do
        nil -> {:error, :session_not_found}
        session -> {:ok, session}
      end
    end
  end

  def capture_session(ref, opts \\ []) do
    with {:ok, session} <- get_session(ref),
         :ok <- require_tmux_session(session) do
      capture_tmux_pane(session.host, session.session,
        tmux_server: session.server,
        window: session.window,
        pane: session.pane,
        lines: Keyword.get(opts, :lines, 80)
      )
    end
  end

  def attach_session(ref) do
    with {:ok, session} <- get_session(ref),
         :ok <- require_tmux_session(session) do
      attach_tmux(session.host, session.session, tmux_server: session.server)
    end
  end

  def send_session(ref, message, opts \\ []) do
    with {:ok, session} <- get_session(ref),
         :ok <- require_tmux_session(session),
         {:ok, capture} <- directive_capture(session, opts),
         :ok <- OperationPolicy.authorize_directive(session, capture, opts) do
      send_tmux(session.host, session.session, message,
        tmux_server: session.server,
        window: session.window,
        pane: session.pane,
        enter: Keyword.get(opts, :enter, true)
      )
    end
  end

  def send_session_prompt(ref, message, opts \\ []) do
    prompt_status =
      if Keyword.get(opts, :enter, true) do
        "sent"
      else
        "ready"
      end

    with {:ok, directive} <- send_session(ref, message, opts),
         {:ok, _profile} <-
           set_session_profile(ref, %{
             next_prompt: message,
             prompt_status: prompt_status,
             last_seen_at: DateTime.utc_now()
           }) do
      {:ok, directive}
    end
  end

  def send_session_keys(ref, keys, opts \\ []) do
    with {:ok, session} <- get_session(ref),
         :ok <- require_tmux_session(session),
         {:ok, capture} <- directive_capture(session, opts),
         :ok <- OperationPolicy.authorize_directive(session, capture, opts) do
      send_tmux_keys(session.host, session.session, keys,
        tmux_server: session.server,
        window: session.window,
        pane: session.pane,
        enter: Keyword.get(opts, :enter, true)
      )
    end
  end

  defp validate_session_control_mode(mode) do
    if mode in SessionControls.modes() do
      :ok
    else
      {:error, {:unsupported_session_control_mode, mode}}
    end
  end

  defp directive_capture(session, opts) do
    case Keyword.get(opts, :capture) do
      nil ->
        capture =
          session_capture(
            session,
            Keyword.get(opts, :capture_lines, Keyword.get(opts, :lines, 80))
          )

        {:ok, capture}

      capture ->
        {:ok, capture}
    end
  end

  def probe_session(ref, opts \\ []) do
    with {:ok, session} <- get_session(ref),
         :ok <- require_ssh_tmux_session(session),
         :ok <- authorize_session_probe(session, Keyword.get(opts, :force, false)) do
      session
      |> pane_transport_opts(opts)
      |> PaneTransport.probe()
      |> case do
        {:ok, probe} ->
          {:ok,
           Map.merge(probe, %{
             ref: ref,
             ssh_target: session.ssh_target,
             registered_host: session.registered_host
           })}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def adopt_session(ref, project_name, opts \\ []) do
    agent_name = Keyword.get(opts, :agent_name, "claude")

    with {:ok, session} <- get_session(ref),
         :ok <- require_tmux_session(session),
         {:ok, worktree_path} <- session_worktree(session) do
      adopt_tmux_task(project_name,
        session_name: session.session,
        worktree_path: worktree_path,
        tmux_server: session.server,
        window: session.window,
        pane: session.pane,
        agent_name: agent_name
      )
    end
  end

  def stream_adopt_session(ref, project_name, opts \\ []) do
    agent_transport = normalize_agent_transport(Keyword.get(opts, :agent_transport))

    with {:ok, session} <- get_session(ref),
         {:project, %{} = project} <- {:project, Projects.get_project_by_name(project_name)},
         :ok <- validate_stream_agent_name(Keyword.get(opts, :agent_name)),
         :ok <- validate_agent_transport(agent_transport),
         :ok <- require_stream_adoptable_session(session),
         :ok <- require_project_host_match(project, session) do
      do_stream_adopt_session(
        session,
        project,
        Keyword.put(opts, :agent_transport, agent_transport)
      )
    else
      {:project, nil} -> {:error, :project_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def resume_adopt_session(ref, project_name, opts \\ []) do
    with {:ok, session} <- get_session(ref),
         {:project, %{} = project} <- {:project, Projects.get_project_by_name(project_name)},
         :ok <- validate_stream_agent_name(Keyword.get(opts, :agent_name)),
         :ok <- require_resume_adoptable_session(session),
         :ok <- require_project_host_match(project, session) do
      do_resume_adopt_session(session, project, opts)
    else
      {:project, nil} -> {:error, :project_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_tmux_sessions(host_name, opts \\ []) do
    all_tmux? = Keyword.get(opts, :all_tmux) == true
    server = Keyword.get(opts, :tmux_server, Tmux.managed_server()) |> Tmux.normalize_server()

    with {:host, %{} = host} <- {:host, Hosts.get_host_by_name(host_name)},
         {:ok, output} <- SSH.adapter(host).run(host, tmux_list_script(all_tmux?, server)) do
      {:ok, parse_tmux_sessions(output, server_field: all_tmux?, server: server)}
    else
      {:host, nil} -> {:error, :host_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_tmux_panes(host_name, opts \\ []) do
    all_tmux? = Keyword.get(opts, :all_tmux) == true
    server = Keyword.get(opts, :tmux_server, Tmux.managed_server()) |> Tmux.normalize_server()

    with {:host, %{} = host} <- {:host, Hosts.get_host_by_name(host_name)},
         {:ok, output} <- SSH.adapter(host).run(host, tmux_panes_script(all_tmux?, server)) do
      {:ok, parse_tmux_panes(output, server_field: all_tmux?, server: server)}
    else
      {:host, nil} -> {:error, :host_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def capture_tmux_pane(host_name, session_name, opts \\ []) do
    server = Keyword.get(opts, :tmux_server, Tmux.managed_server()) |> Tmux.normalize_server()
    window = Keyword.get(opts, :window, 0)
    pane = Keyword.get(opts, :pane, 0)
    lines = Keyword.get(opts, :lines, 80)

    with {:host, %{} = host} <- {:host, Hosts.get_host_by_name(host_name)} do
      SSH.adapter(host).run(
        host,
        Tmux.capture_pane_script(session_name,
          tmux_server: server,
          window: window,
          pane: pane,
          lines: lines
        )
      )
    else
      {:host, nil} -> {:error, :host_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def send_tmux(host_name, session_name, message, opts \\ []) do
    server = Keyword.get(opts, :tmux_server, Tmux.managed_server()) |> Tmux.normalize_server()
    window = Keyword.get(opts, :window, 0)
    pane = Keyword.get(opts, :pane, 0)
    enter? = Keyword.get(opts, :enter, true)

    with {:host, %{} = host} <- {:host, Hosts.get_host_by_name(host_name)} do
      result =
        SSH.adapter(host).run(
          host,
          Tmux.send_keys_script(session_name, message, Keyword.put(opts, :tmux_server, server))
        )

      record_directive_result(
        %{
          target_type: "tmux",
          host_id: host.id,
          tmux_server: server,
          session_name: session_name,
          window: window,
          pane: pane,
          message: message,
          enter: enter?
        },
        result
      )
    else
      {:host, nil} -> {:error, :host_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def send_tmux_keys(host_name, session_name, keys, opts \\ []) do
    server = Keyword.get(opts, :tmux_server, Tmux.managed_server()) |> Tmux.normalize_server()
    window = Keyword.get(opts, :window, 0)
    pane = Keyword.get(opts, :pane, 0)
    enter? = Keyword.get(opts, :enter, true)

    with {:host, %{} = host} <- {:host, Hosts.get_host_by_name(host_name)},
         {:ok, _output} <-
           SSH.adapter(host).run(
             host,
             Tmux.send_key_tokens_script(
               session_name,
               keys,
               Keyword.put(opts, :tmux_server, server)
             )
           ) do
      {:ok,
       %{
         host: host_name,
         tmux_server: server,
         session_name: session_name,
         window: window,
         pane: pane,
         keys: keys,
         enter: enter?
       }}
    else
      {:host, nil} -> {:error, :host_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_directive_result(attrs, {:ok, _output}) do
    attrs
    |> Map.put(:status, "sent")
    |> Directives.insert_directive()
  end

  defp record_directive_result(attrs, {:error, reason}) do
    attrs
    |> Map.put(:status, "error")
    |> Map.put(:error, inspect(reason))
    |> Directives.insert_directive()

    {:error, reason}
  end

  def attach_tmux(host_name, session_name, opts \\ []) do
    server = Keyword.get(opts, :tmux_server, Tmux.managed_server()) |> Tmux.normalize_server()

    with {:host, %{} = host} <- {:host, Hosts.get_host_by_name(host_name)} do
      SSH.adapter(host).attach(host, session_name, tmux_server: server)
    else
      {:host, nil} -> {:error, :host_not_found}
    end
  end

  def stop_tmux(host_name, session_name, opts \\ []) do
    server = Keyword.get(opts, :tmux_server, Tmux.managed_server()) |> Tmux.normalize_server()

    with {:host, %{} = host} <- {:host, Hosts.get_host_by_name(host_name)},
         {:ok, _output} <-
           SSH.adapter(host).run(host, Tmux.stop_session_script(session_name, server)) do
      :ok
    else
      {:host, nil} -> {:error, :host_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp discovery_hosts(opts) do
    case Keyword.get(opts, :host_name) do
      nil ->
        {:ok, Hosts.list_hosts()}

      host_name ->
        case Hosts.get_host_with_projects_by_name(host_name) do
          nil -> {:error, {:host_not_found, host_name}}
          host -> {:ok, [host]}
        end
    end
  end

  defp tasks_by_host_session(hosts) do
    host_ids = Enum.map(hosts, & &1.id)

    host_ids
    |> Tasks.list_tasks_for_hosts()
    |> Map.new(fn task -> {{task.host_id, task.tmux_server, task.session_name}, task} end)
  end

  defp projects_by_host_id(hosts) do
    Map.new(hosts, fn host ->
      projects =
        host
        |> ensure_projects_loaded()
        |> Map.fetch!(:projects)

      {host.id, projects}
    end)
  end

  defp discover_host_sessions(host, tasks_by_host_session, projects_by_host_id, all_tmux?) do
    case SSH.adapter(host).run(host, tmux_list_script(all_tmux?, Tmux.managed_server())) do
      {:ok, output} ->
        sessions =
          output
          |> parse_tmux_sessions(server_field: all_tmux?)
          |> Enum.map(
            &discovery_session(
              host,
              &1,
              tasks_by_host_session,
              Map.fetch!(projects_by_host_id, host.id)
            )
          )

        {:ok, sessions}

      {:error, reason} ->
        {:error,
         %{
           host: host.name,
           transport: host.transport,
           error: reason
         }}
    end
  end

  defp discovery_session(host, session, tasks_by_host_session, projects) do
    task = Map.get(tasks_by_host_session, {host.id, session.server, session.name})

    inferred_project =
      (task && task.project) || infer_project(host, projects, session.current_path)

    %{
      host: host.name,
      transport: host.transport,
      server: session.server,
      session: session.name,
      state: discovery_state(task),
      task_id: task && task.task_id,
      project: inferred_project && inferred_project.name,
      agent_name: task && task.agent_name,
      worktree_path: (task && task.worktree_path) || session.current_path,
      created_at: session.created_at,
      attached: session.attached,
      windows: session.windows
    }
  end

  defp tmux_list_script(true, _server), do: Tmux.list_all_sessions_script()
  defp tmux_list_script(false, server), do: Tmux.list_sessions_script(server)

  defp tmux_panes_script(true, _server), do: Tmux.list_all_panes_script()
  defp tmux_panes_script(false, server), do: Tmux.list_panes_script(server)

  defp build_discovery_report(results) do
    report =
      Enum.reduce(results, %{sessions: [], errors: []}, fn
        {:ok, sessions}, acc ->
          %{acc | sessions: acc.sessions ++ sessions}

        {:error, error}, acc ->
          %{acc | errors: acc.errors ++ [error]}
      end)

    {:ok, report}
  end

  defp activity_for_host(host, all_tmux?, all_processes?) do
    panes_result =
      case SSH.adapter(host).run(host, tmux_panes_script(all_tmux?, Tmux.managed_server())) do
        {:ok, output} ->
          {:ok, parse_tmux_panes(output, server_field: all_tmux?)}

        {:error, reason} ->
          {:error,
           %{host: host.name, transport: host.transport, subsystem: "tmux", error: reason}}
      end

    processes_result = activity_processes(host, all_processes?)

    activity =
      build_host_activity(
        host,
        result_value(panes_result, []),
        result_value(processes_result, []),
        all_processes?
      )

    errors =
      [panes_result, processes_result]
      |> Enum.flat_map(fn
        {:error, error} -> [error]
        {:ok, _value} -> []
      end)

    {:ok, activity, errors}
  end

  defp local_unregistered_activity_results(hosts, nil, all_processes?) do
    if Enum.any?(hosts, &(&1.transport == "local")) do
      []
    else
      [local_unregistered_activity(all_processes?)]
    end
  end

  defp local_unregistered_activity_results(_hosts, _host_name, _all_processes?), do: []

  defp local_unregistered_activity(all_processes?) do
    case ProcessInventory.list(kinds: ~w(codex claude opencode), all: all_processes?) do
      {:ok, processes} ->
        host = %{name: "local", transport: "local"}
        {:ok, build_host_activity(host, [], processes, all_processes?), []}

      {:error, reason} ->
        {:ok, [],
         [
           %{
             host: "local",
             transport: "local",
             subsystem: "processes",
             error: reason
           }
         ]}
    end
  end

  defp activity_processes(host, all_processes?) do
    case SSH.adapter(host).run(host, ProcessInventory.ps_script()) do
      {:ok, output} ->
        processes =
          output
          |> ProcessInventory.parse_ps_output()
          |> ProcessInventory.filter(kinds: ProcessInventory.known_kinds(), all: all_processes?)

        {:ok, processes}

      {:error, reason} ->
        {:error,
         %{host: host.name, transport: host.transport, subsystem: "processes", error: reason}}
    end
  end

  defp build_host_activity(host, panes, processes, all_processes?) do
    processes_by_tty = Enum.group_by(processes, &normalize_tty(&1.tty))
    pane_ttys = panes |> Enum.map(&normalize_tty(&1.tty)) |> MapSet.new()

    pane_activity =
      Enum.map(panes, fn pane ->
        process =
          processes_by_tty
          |> Map.get(normalize_tty(pane.tty), [])
          |> best_process_for_pane(pane)

        activity_entry(host, pane, process)
      end)

    process_activity =
      processes
      |> Enum.reject(&(normalize_tty(&1.tty) in pane_ttys))
      |> Enum.reject(&(!all_processes? && &1.kind == "tmux"))
      |> Enum.group_by(&standalone_process_key/1)
      |> Enum.map(fn {_key, tty_processes} ->
        process = best_standalone_process(tty_processes)
        activity_entry(host, nil, process)
      end)

    pane_activity ++ process_activity
  end

  defp activity_entry(host, pane, process) do
    %{
      host: host.name,
      transport: host.transport,
      server: (pane && pane.server) || "",
      session: (pane && pane.session) || "",
      window: pane && pane.window,
      pane: pane && pane.pane,
      tty: (pane && pane.tty) || (process && process.tty) || "",
      active: pane && pane.active,
      kind: (process && process.kind) || (pane && pane.kind) || "",
      process_role: (process && Map.get(process, :role)) || "",
      resume_available: (process && Map.get(process, :resume_available)) || false,
      resume_ref: (process && Map.get(process, :resume_ref)) || "",
      zed_workspace: (process && Map.get(process, :zed_workspace)) || "",
      pane_kind: (pane && pane.kind) || "",
      pane_command: (pane && pane.command) || "",
      process_pid: process && process.pid,
      process_ppid: process && process.ppid,
      process_stat: (process && process.stat) || "",
      process_command: (process && process.command) || "",
      current_path: (pane && pane.current_path) || "",
      title: (pane && pane.title) || ""
    }
  end

  defp best_process_for_pane([], _pane), do: nil

  defp best_process_for_pane(processes, pane) do
    Enum.min_by(processes, &process_score(&1, pane), fn -> nil end)
  end

  defp best_standalone_process(processes) do
    Enum.min_by(processes, &process_score(&1, nil), fn -> nil end)
  end

  defp process_score(process, pane) do
    [
      if(String.starts_with?(process.stat || "", "T"), do: 1, else: 0),
      if(pane && process.kind == pane.kind, do: 0, else: 1),
      if(process_basename(process) == process.kind, do: 0, else: 1),
      process_kind_priority(process.kind),
      process.pid || 0
    ]
  end

  defp process_kind_priority(kind) when kind in ~w(codex claude opencode), do: 0
  defp process_kind_priority("ssh"), do: 1
  defp process_kind_priority("tmux"), do: 2
  defp process_kind_priority(_kind), do: 3

  defp process_basename(%{command: command}) do
    command
    |> String.split(~r/\s+/, parts: 2)
    |> hd()
    |> Path.basename()
    |> String.downcase()
  end

  defp normalize_tty(nil), do: ""

  defp normalize_tty(tty) do
    tty
    |> String.trim()
    |> String.replace_prefix("/dev/", "")
  end

  defp standalone_process_key(process) do
    case normalize_tty(process.tty) do
      tty when tty in ["", "??"] -> {:pid, process.pid}
      tty -> {:tty, tty}
    end
  end

  defp build_activity_report(results) do
    report =
      Enum.reduce(results, %{activity: [], errors: []}, fn
        {:ok, activity, errors}, acc ->
          %{acc | activity: acc.activity ++ activity, errors: acc.errors ++ errors}
      end)

    {:ok, report}
  end

  defp result_value({:ok, value}, _default), do: value
  defp result_value({:error, _reason}, default), do: default

  defp ensure_projects_loaded(%{projects: %Ecto.Association.NotLoaded{}} = host) do
    Hosts.get_host_with_projects_by_name(host.name)
  end

  defp ensure_projects_loaded(host), do: host

  defp discovery_state(nil), do: "unmanaged"
  defp discovery_state(_task), do: "managed"

  defp infer_project(host, projects, current_path)
       when is_binary(current_path) and current_path != "" do
    Enum.find(projects, fn project ->
      path_inside?(current_path, project.repo_path) ||
        path_inside?(
          current_path,
          Path.join([host.workspace_path, "projects", project.slug])
        )
    end)
  end

  defp infer_project(_host, _projects, _current_path), do: nil

  defp path_inside?(path, root) do
    path_candidates = expanded_path_aliases(path)
    root_candidates = expanded_path_aliases(root)

    Enum.any?(path_candidates, fn path ->
      Enum.any?(root_candidates, fn root ->
        path == root || String.starts_with?(path, root <> "/")
      end)
    end)
  end

  defp expanded_path_aliases(path) do
    path = Path.expand(path)

    path
    |> tmp_path_aliases()
    |> Enum.uniq()
  end

  defp tmp_path_aliases("/private/tmp" <> rest = path), do: [path, "/tmp" <> rest]
  defp tmp_path_aliases("/tmp" <> rest = path), do: [path, "/private/tmp" <> rest]
  defp tmp_path_aliases(path), do: [path]

  defp require_tmux_session(%{server: server, session: session, window: window, pane: pane})
       when server not in [nil, ""] and session not in [nil, ""] and is_integer(window) and
              is_integer(pane) do
    :ok
  end

  defp require_tmux_session(_session), do: {:error, :session_not_tmux}

  defp tmux_session?(session), do: require_tmux_session(session) == :ok

  defp require_stream_adoptable_session(session) do
    cond do
      tmux_session?(session) -> :ok
      action?(session, "stream-adopt") -> :ok
      true -> {:error, {:session_not_stream_adoptable, Map.get(session, :ref, "")}}
    end
  end

  defp require_resume_adoptable_session(session) do
    cond do
      action?(session, "resume-adopt") -> :ok
      true -> {:error, {:session_not_resume_adoptable, Map.get(session, :ref, "")}}
    end
  end

  defp require_project_host_match(project, session) do
    project_host = get_in(project, [Access.key(:host), Access.key(:name)])
    session_host = Map.get(session, :host)

    cond do
      project_host in [nil, ""] or session_host in [nil, ""] ->
        :ok

      project_host == session_host ->
        :ok

      true ->
        {:error, {:project_host_mismatch, project.name, project_host, session_host}}
    end
  end

  defp filter_snapshot_work_state(sessions, nil), do: sessions

  defp filter_snapshot_work_state(sessions, work_state) do
    Enum.filter(sessions, fn session ->
      get_in(session, [:capture, :work_state]) == work_state
    end)
  end

  defp broadcast_target?(session, attention?) do
    action?(session, "send") and (!attention? or session_needs_attention?(session))
  end

  defp action?(session, action) do
    session
    |> Map.get(:actions, "")
    |> String.split(",", trim: true)
    |> Enum.member?(action)
  end

  defp session_needs_attention?(%{capture: capture}) do
    Map.get(capture, :work_state) in ~w(blocked waiting unknown) or
      Map.get(capture, :status) == "error"
  end

  defp session_needs_attention?(_session), do: false

  defp broadcast_result(session, _message, false, _enter?) do
    session_broadcast_result(session, "dry_run")
  end

  defp broadcast_result(session, message, true, enter?) do
    case send_session(session.ref, message, enter: enter?, capture: Map.get(session, :capture)) do
      {:ok, directive} ->
        session
        |> session_broadcast_result("sent")
        |> Map.put(:directive_id, directive.directive_id)

      {:error, reason} ->
        session
        |> session_broadcast_result("error")
        |> Map.put(:error, inspect(reason))
    end
  end

  defp session_broadcast_result(session, status) do
    %{
      ref: session.ref,
      host: session.host,
      type: session.type,
      state: session.state,
      kind: session.kind,
      agent_name: session.agent_name,
      task_id: session.task_id,
      tmux_server: session.server,
      session_name: session.session,
      window: session.window,
      pane: session.pane,
      work_state: get_in(session, [:capture, :work_state]),
      capture_status: get_in(session, [:capture, :status]),
      summary: get_in(session, [:capture, :summary]) || "",
      status: status
    }
  end

  defp current_summary(report) do
    sessions = report.sessions

    %{
      total: length(sessions),
      by_type: count_by(sessions, :type),
      by_state: count_by(sessions, :state),
      by_control: count_by(sessions, :control_mode),
      by_kind: count_by(sessions, :kind),
      by_action: count_actions(sessions),
      errors: length(report.errors)
    }
  end

  defp registry_summary do
    hosts = Hosts.list_hosts()
    projects = Projects.list_projects()

    %{
      hosts: length(hosts),
      projects: length(projects),
      warnings: registry_warnings(hosts, projects)
    }
  end

  defp registry_warnings(hosts, projects) do
    []
    |> maybe_add_warning(
      hosts == [],
      "no hosts registered; discovery is limited to local unmanaged processes"
    )
    |> maybe_add_warning(
      projects == [],
      "no projects registered; project matching cannot use repo roots"
    )
  end

  defp maybe_add_warning(warnings, true, warning), do: warnings ++ [warning]
  defp maybe_add_warning(warnings, false, _warning), do: warnings

  defp summary_current_report(opts) do
    if Keyword.get(opts, :observe, false) do
      with {:ok, report} <- snapshot_sessions(opts),
           {:ok, observations} <- record_session_observations(report) do
        prune_missing_process_observations(report, opts)

        {:ok,
         {report,
          %{
            observed: true,
            saved: length(observations),
            captured: length(report.sessions),
            errors: length(report.errors)
          }}}
      end
    else
      with {:ok, report} <- list_sessions(opts) do
        {:ok, {report, %{observed: false, saved: 0, captured: 0, errors: 0}}}
      end
    end
  end

  defp prune_missing_process_observations(%{errors: []} = report, opts) do
    SessionObservations.prune_missing_process_only(report.sessions,
      host: Keyword.get(opts, :host_name),
      type: Keyword.get(opts, :type),
      ssh_target: Keyword.get(opts, :ssh_target)
    )
  end

  defp prune_missing_process_observations(_report, _opts), do: {0, nil}

  defp observations_summary(latest_observations, attention_changes, stale) do
    %{
      latest_total: length(latest_observations),
      by_work_state: count_by(latest_observations, :work_state),
      by_capture_status: count_by(latest_observations, :capture_status),
      attention_total: length(attention_changes),
      stale_total: length(stale)
    }
  end

  defp remote_summary(candidates, remote_observations) do
    %{
      candidates_total: length(candidates),
      by_target: count_by(candidates, :target),
      by_probe_action: count_by(candidates, :probe_action),
      discovered_total: length(remote_observations),
      discovered_by_target: count_by(remote_observations, :ssh_target)
    }
  end

  defp workflow_summary(
         sessions,
         latest_observations,
         remote_candidates,
         remote_observations,
         limit
       ) do
    latest_by_ref = Map.new(latest_observations, &{&1.ref, &1})

    clusters =
      sessions
      |> Enum.group_by(&workspace_label/1)
      |> Enum.map(fn {name, grouped_sessions} ->
        workflow_cluster(name, grouped_sessions, latest_by_ref, limit)
      end)
      |> Enum.sort_by(&{-&1.active, -&1.agents, -&1.total, &1.name})
      |> Enum.take(limit)

    %{
      clusters_total: sessions |> Enum.map(&workspace_label/1) |> Enum.uniq() |> length(),
      clusters: clusters,
      remote_targets: remote_target_groups(remote_candidates, limit),
      remote_discovered: remote_discovered_groups(remote_observations, limit),
      unobservable_agents:
        workflow_refs(sessions, latest_by_ref, limit, fn session ->
          not session_suppressed?(session) and session.type == "agent" and
            workflow_state(session, latest_by_ref) == "unobservable"
        end),
      unmanaged_sendable:
        workflow_refs(sessions, latest_by_ref, limit, fn session ->
          not session_suppressed?(session) and session.state == "unmanaged" and
            action?(session, "send")
        end),
      adoptable:
        workflow_refs(sessions, latest_by_ref, limit, fn session ->
          not session_suppressed?(session) and session.state == "unmanaged" and
            action?(session, "adopt")
        end),
      recommendations: workflow_recommendations(sessions, latest_by_ref, remote_candidates, limit)
    }
  end

  defp workflow_cluster(name, sessions, latest_by_ref, limit) do
    %{
      name: name,
      sample_path: sample_path(sessions),
      total: length(sessions),
      active: Enum.count(sessions, &(&1.active == true)),
      agents: Enum.count(sessions, &(&1.type == "agent")),
      ssh: Enum.count(sessions, &(&1.type == "ssh")),
      tmux: Enum.count(sessions, &(&1.type == "tmux")),
      sendable: Enum.count(sessions, &action?(&1, "send")),
      adoptable: Enum.count(sessions, &action?(&1, "adopt")),
      by_work_state: workflow_work_states(sessions, latest_by_ref),
      refs: Enum.take(Enum.map(sessions, &session_workflow_ref(&1, latest_by_ref)), limit)
    }
  end

  defp remote_target_groups(candidates, limit) do
    candidates
    |> Enum.group_by(&(Map.get(&1, :target) || ""))
    |> Enum.map(fn {target, grouped_candidates} ->
      %{
        target: target,
        total: length(grouped_candidates),
        active: Enum.count(grouped_candidates, &(&1.active == true)),
        probe: Enum.count(grouped_candidates, &(&1.probe_action == "probe")),
        force_probe: Enum.count(grouped_candidates, &(&1.probe_action == "force-probe")),
        manual: Enum.count(grouped_candidates, &(&1.probe_action == "manual")),
        refs:
          grouped_candidates
          |> Enum.map(&remote_workflow_ref/1)
          |> Enum.take(limit)
      }
    end)
    |> Enum.sort_by(&{-&1.manual, -&1.force_probe, -&1.total, &1.target})
    |> Enum.take(limit)
  end

  defp remote_discovered_groups(observations, limit) do
    observations
    |> Enum.group_by(& &1.ssh_target)
    |> Enum.map(fn {target, grouped_observations} ->
      %{
        target: target,
        total: length(grouped_observations),
        refs:
          grouped_observations
          |> Enum.map(&remote_discovered_ref/1)
          |> Enum.take(limit)
      }
    end)
    |> Enum.sort_by(&{-&1.total, &1.target})
    |> Enum.take(limit)
  end

  defp workflow_refs(sessions, latest_by_ref, limit, predicate) do
    sessions
    |> Enum.filter(predicate)
    |> Enum.map(&session_workflow_ref(&1, latest_by_ref))
    |> Enum.take(limit)
  end

  defp workflow_recommendations(sessions, latest_by_ref, remote_candidates, limit) do
    (attention_recommendations(sessions, latest_by_ref) ++
       remote_probe_recommendations(remote_candidates, sessions) ++
       unobservable_agent_recommendations(sessions, latest_by_ref) ++
       adoption_recommendations(sessions, latest_by_ref))
    |> Enum.map(&with_recommendation_metadata/1)
    |> Enum.take(limit)
  end

  defp attention_recommendations(sessions, latest_by_ref) do
    sessions
    |> Enum.reject(&session_suppressed?/1)
    |> Enum.filter(&(workflow_state(&1, latest_by_ref) in ~w(blocked waiting)))
    |> Enum.flat_map(&attention_recommendations_for_session(&1, latest_by_ref))
  end

  defp attention_recommendations_for_session(session, latest_by_ref) do
    work_state = workflow_state(session, latest_by_ref)

    safe =
      if action?(session, "capture") do
        [
          %{
            priority: "high",
            kind: "attention",
            action: "capture-session",
            ref: session.ref,
            target: recommendation_target(session),
            reason: "#{work_state} session needs a fresh read-only capture before direction"
          }
        ]
      else
        []
      end

    gated =
      if action?(session, "send") or action?(session, "force-probe") do
        [
          %{
            priority: "high",
            kind: "attention",
            action: recommendation_action(session),
            ref: session.ref,
            target: recommendation_target(session),
            reason: "#{work_state} session needs operator direction"
          }
        ]
      else
        []
      end

    safe ++ gated
  end

  defp remote_probe_recommendations(remote_candidates, sessions) do
    refs_by_pane =
      Map.new(sessions, fn session ->
        {{Map.get(session, :ssh_target), Map.get(session, :server), Map.get(session, :session),
          Map.get(session, :window), Map.get(session, :pane)}, session.ref}
      end)

    suppressed_panes =
      sessions
      |> Enum.filter(&session_suppressed?/1)
      |> MapSet.new(fn session ->
        {Map.get(session, :ssh_target), Map.get(session, :server), Map.get(session, :session),
         Map.get(session, :window), Map.get(session, :pane)}
      end)

    remote_candidates
    |> Enum.filter(&(&1.probe_action in ~w(force-probe manual)))
    |> Enum.reject(fn candidate ->
      MapSet.member?(
        suppressed_panes,
        {candidate.target, candidate.server, candidate.session, candidate.window, candidate.pane}
      )
    end)
    |> Enum.map(fn candidate ->
      ref =
        Map.get(
          refs_by_pane,
          {candidate.target, candidate.server, candidate.session, candidate.window,
           candidate.pane},
          ""
        )

      remote_probe_recommendation(candidate, ref)
    end)
  end

  defp unobservable_agent_recommendations(sessions, latest_by_ref) do
    sessions
    |> Enum.reject(&session_suppressed?/1)
    |> Enum.filter(&(workflow_state(&1, latest_by_ref) == "unobservable" and &1.type == "agent"))
    |> Enum.map(fn session ->
      %{
        priority: "medium",
        kind: "visibility",
        action: "reattach-or-ignore-external-agent",
        ref: session.ref,
        target: recommendation_target(session),
        reason: "agent process is not backed by an observable tmux pane"
      }
    end)
  end

  defp adoption_recommendations(sessions, latest_by_ref) do
    sessions
    |> Enum.reject(&session_suppressed?/1)
    |> Enum.filter(
      &(action?(&1, "adopt") and &1.type in ~w(agent tmux) and &1.state == "unmanaged")
    )
    |> Enum.map(fn session ->
      %{
        priority: "low",
        kind: "adoption",
        action: "adopt-session",
        ref: session.ref,
        target: recommendation_target(session),
        reason: "unmanaged #{session.type} can be linked to a project/task record"
      }
    end)
    |> Enum.reject(&recommendation_unobservable?(&1, latest_by_ref))
  end

  defp recommendation_unobservable?(recommendation, latest_by_ref) do
    case Map.get(latest_by_ref, recommendation.ref) do
      nil -> false
      observation -> observation.work_state == "unobservable"
    end
  end

  defp with_recommendation_metadata(recommendation) do
    recommendation
    |> Map.put(:id, recommendation_id(recommendation))
    |> Map.put(:safety, recommendation_safety(recommendation.action))
  end

  defp recommendation_id(recommendation) do
    source = [
      recommendation.priority,
      recommendation.kind,
      recommendation.action,
      recommendation.ref,
      recommendation.target,
      recommendation.reason
    ]

    hash =
      :crypto.hash(:sha256, Enum.intersperse(source, <<0>>))
      |> Base.encode16(case: :lower)

    "rec-" <> binary_part(hash, 0, 10)
  end

  defp recommendation_safety(action) when action in ~w(inspect-session capture-session) do
    "safe"
  end

  defp recommendation_safety(action)
       when action in ~w(send-session capture-before-force-probe adopt-session) do
    "gated"
  end

  defp recommendation_safety(_action), do: "manual"

  defp operation_state(summary) do
    %{
      current: summary.current,
      observations: summary.observations,
      reconciliation: summary.reconciliation,
      remote: summary.remote,
      workflow: %{
        clusters_total: summary.workflow.clusters_total,
        clusters: summary.workflow.clusters,
        remote_targets: summary.workflow.remote_targets,
        remote_discovered: summary.workflow.remote_discovered
      }
    }
  end

  defp operation_unknowns(summary) do
    %{
      unobservable_agents: summary.workflow.unobservable_agents,
      observed_missing: summary.reconciliation.observed_missing,
      current_unobserved: summary.reconciliation.current_unobserved
    }
  end

  defp operation_execution(nil, _recommendations, _opts) do
    %{
      requested: nil,
      mode: "dry-run",
      executed: [],
      skipped: [],
      audit: %{saved: 0, errors: []}
    }
  end

  defp operation_execution(requested, recommendations, opts) do
    targets =
      if requested == "safe" do
        Enum.filter(recommendations, &(&1.safety == "safe"))
      else
        Enum.filter(recommendations, &(&1.id == requested))
      end

    results =
      cond do
        targets == [] and requested != "safe" ->
          [
            %{
              id: requested,
              action: nil,
              safety: nil,
              status: "skipped",
              reason: "recommendation not found"
            }
          ]

        true ->
          Enum.map(targets, &execute_recommendation(&1, opts))
      end

    %{
      requested: requested,
      mode: "execute",
      executed: Enum.filter(results, &(&1.status == "executed")),
      skipped: Enum.reject(results, &(&1.status == "executed")),
      audit: OperationExecutions.audit_results(requested, results)
    }
  end

  defp execute_recommendation(%{safety: "gated"} = recommendation, opts) do
    if Keyword.get(opts, :yes, false) do
      execute_gated_recommendation(recommendation, opts)
    else
      %{
        id: recommendation.id,
        action: recommendation.action,
        safety: recommendation.safety,
        status: "skipped",
        ref: recommendation.ref,
        target: recommendation.target,
        reason: "recommendation requires explicit gated execution"
      }
    end
  end

  defp execute_recommendation(%{safety: "manual"} = recommendation, _opts) do
    %{
      id: recommendation.id,
      action: recommendation.action,
      safety: recommendation.safety,
      status: "skipped",
      ref: recommendation.ref,
      target: recommendation.target,
      reason: "recommendation requires manual handling"
    }
  end

  defp execute_recommendation(%{action: "capture-session"} = recommendation, opts) do
    lines = Keyword.get(opts, :lines, 80)

    case capture_session(recommendation.ref, lines: lines) do
      {:ok, output} ->
        %{
          id: recommendation.id,
          action: recommendation.action,
          safety: recommendation.safety,
          status: "executed",
          ref: recommendation.ref,
          target: recommendation.target,
          capture: %{
            status: "ok",
            summary: SessionStatus.summary(output, 500),
            output: output
          }
        }

      {:error, reason} ->
        %{
          id: recommendation.id,
          action: recommendation.action,
          safety: recommendation.safety,
          status: "error",
          ref: recommendation.ref,
          target: recommendation.target,
          error: inspect(reason)
        }
    end
  end

  defp execute_recommendation(recommendation, _opts) do
    %{
      id: recommendation.id,
      action: recommendation.action,
      safety: recommendation.safety,
      status: "skipped",
      reason: "safe execution for this action is not implemented"
    }
  end

  defp execute_gated_recommendation(
         %{action: "capture-before-force-probe"} = recommendation,
         opts
       ) do
    case OperationPolicy.authorize_gated(recommendation) do
      :ok ->
        execute_force_probe_recommendation(recommendation, opts)

      {:skip, reason} ->
        skipped_gated_recommendation(recommendation, reason)
    end
  end

  defp execute_gated_recommendation(recommendation, _opts),
    do:
      skipped_gated_recommendation(
        recommendation,
        "gated execution for this action is not implemented"
      )

  defp execute_force_probe_recommendation(recommendation, opts) do
    lines = Keyword.get(opts, :lines, 80)
    timeout_ms = Keyword.get(opts, :timeout_ms, 5_000)

    case capture_session(recommendation.ref, lines: lines) do
      {:ok, output} ->
        execute_force_probe_after_capture(recommendation, output, timeout_ms)

      {:error, reason} ->
        %{
          id: recommendation.id,
          action: recommendation.action,
          safety: recommendation.safety,
          status: "error",
          ref: recommendation.ref,
          target: recommendation.target,
          error: inspect(reason)
        }
    end
  end

  defp skipped_gated_recommendation(recommendation, reason) do
    %{
      id: recommendation.id,
      action: recommendation.action,
      safety: recommendation.safety,
      status: "skipped",
      ref: recommendation.ref,
      target: recommendation.target,
      reason: reason
    }
  end

  defp execute_force_probe_after_capture(recommendation, output, timeout_ms) do
    capture = %{
      status: "ok",
      summary: SessionStatus.summary(output, 500),
      output: output
    }

    case probe_session(recommendation.ref, force: true, timeout_ms: timeout_ms) do
      {:ok, probe} ->
        remote_audit = audit_remote_probe(probe, recommendation)

        %{
          id: recommendation.id,
          action: recommendation.action,
          safety: recommendation.safety,
          status: "executed",
          ref: recommendation.ref,
          target: recommendation.target,
          capture: capture,
          probe: probe,
          remote: remote_audit
        }

      {:error, reason} ->
        %{
          id: recommendation.id,
          action: recommendation.action,
          safety: recommendation.safety,
          status: "error",
          ref: recommendation.ref,
          target: recommendation.target,
          capture: capture,
          error: inspect(reason)
        }
    end
  end

  defp audit_remote_probe(probe, recommendation) do
    case RemoteSessions.record_probe(probe, recommendation) do
      {:ok, observations} -> %{saved: length(observations), errors: []}
      {:error, reason} -> %{saved: 0, errors: [inspect(reason)]}
    end
  end

  defp recommendation_action(session) do
    cond do
      action?(session, "send") -> "send-session"
      action?(session, "force-probe") -> "capture-before-force-probe"
      action?(session, "attach") -> "attach-session"
      true -> "inspect-session"
    end
  end

  defp recommendation_target(%{ssh_target: ssh_target}) when ssh_target not in [nil, ""] do
    ssh_target
  end

  defp recommendation_target(%{session: session, server: server, window: window, pane: pane})
       when session not in [nil, ""] and server not in [nil, ""] do
    "#{server}/#{session}:#{window}.#{pane}"
  end

  defp recommendation_target(%{command: command}) when command not in [nil, ""], do: command
  defp recommendation_target(_session), do: ""

  defp workflow_work_states(sessions, latest_by_ref) do
    sessions
    |> Enum.map(&workflow_state(&1, latest_by_ref))
    |> Enum.reject(&(&1 == ""))
    |> Enum.frequencies()
  end

  defp workflow_state(session, latest_by_ref) do
    case Map.get(latest_by_ref, session.ref) do
      nil -> ""
      observation -> observation.work_state || ""
    end
  end

  defp session_suppressed?(session), do: SessionControls.suppressed?(session)

  defp session_workflow_ref(session, latest_by_ref) do
    %{
      ref: session.ref,
      type: session.type,
      kind: session.kind,
      state: session.state,
      control_mode: Map.get(session, :control_mode, "uncontrolled"),
      control_project: Map.get(session, :control_project, ""),
      work_state: workflow_state(session, latest_by_ref),
      session_name: session.session,
      ssh_target: session.ssh_target,
      current_path: session.current_path,
      actions: session.actions
    }
  end

  defp remote_workflow_ref(candidate) do
    %{
      target: candidate.target,
      tmux_pane: "#{candidate.server}/#{candidate.session}:#{candidate.window}.#{candidate.pane}",
      active: Map.get(candidate, :active),
      probe_action: candidate.probe_action,
      title: Map.get(candidate, :title, ""),
      current_path: Map.get(candidate, :current_path, "")
    }
  end

  defp remote_discovered_ref(observation) do
    %{
      local_ref: observation.local_ref,
      ssh_target: observation.ssh_target,
      tmux_server: observation.tmux_server,
      session_name: observation.session_name,
      attached: observation.attached,
      windows: observation.windows,
      current_path: observation.current_path,
      observed_at: observation.inserted_at
    }
  end

  defp workspace_label(%{current_path: path}) when is_binary(path) and path != "" do
    normalized_path = normalize_tmp_path(path)

    cond do
      match = Regex.run(~r{/workspaces/([^/]+)/USER/worktrees/[^/]+/([^/]+)}, normalized_path) ->
        [_path, workspace, project] = match
        "#{workspace}/#{project}"

      match = Regex.run(~r{/workspaces/([^/]+)}, normalized_path) ->
        [_path, workspace] = match
        workspace

      String.starts_with?(normalized_path, "/tmp/") ->
        "tmp"

      true ->
        Path.basename(normalized_path)
    end
  end

  defp workspace_label(_session), do: "unknown"

  defp normalize_tmp_path("/private/tmp" <> rest), do: "/tmp" <> rest
  defp normalize_tmp_path(path), do: path

  defp sample_path(sessions) do
    sessions
    |> Enum.map(& &1.current_path)
    |> Enum.find("", &(&1 not in [nil, ""]))
  end

  defp reconciliation_summary(current_sessions, latest_observations, limit) do
    current_refs = current_sessions |> Enum.map(& &1.ref) |> MapSet.new()
    observed_refs = latest_observations |> Enum.map(& &1.ref) |> MapSet.new()

    current_unobserved =
      current_sessions
      |> Enum.reject(&MapSet.member?(observed_refs, &1.ref))
      |> Enum.map(&session_reconciliation_ref/1)
      |> Enum.take(limit)

    observed_missing =
      latest_observations
      |> Enum.reject(&MapSet.member?(current_refs, &1.ref))
      |> Enum.map(&observation_reconciliation_ref/1)
      |> Enum.take(limit)

    %{
      current_observed_total: MapSet.intersection(current_refs, observed_refs) |> MapSet.size(),
      current_unobserved_total: MapSet.difference(current_refs, observed_refs) |> MapSet.size(),
      observed_missing_total: MapSet.difference(observed_refs, current_refs) |> MapSet.size(),
      current_unobserved: current_unobserved,
      observed_missing: observed_missing
    }
  end

  defp session_reconciliation_ref(session) do
    %{
      ref: session.ref,
      host: session.host,
      type: session.type,
      state: session.state,
      kind: session.kind,
      agent_name: session.agent_name,
      task_id: session.task_id,
      session_name: session.session,
      ssh_target: session.ssh_target,
      actions: session.actions
    }
  end

  defp observation_reconciliation_ref(observation) do
    %{
      ref: observation.ref,
      host: observation.host,
      type: observation.type,
      state: observation.state,
      kind: observation.kind,
      agent_name: observation.agent_name,
      task_id: observation.task_id,
      session_name: observation.session_name,
      ssh_target: observation.ssh_target,
      work_state: observation.work_state,
      observed_at: observation.observed_at
    }
  end

  defp count_by(items, key) do
    items
    |> Enum.map(&(Map.get(&1, key) || ""))
    |> Enum.reject(&(&1 == ""))
    |> Enum.frequencies()
  end

  defp count_actions(sessions) do
    sessions
    |> Enum.flat_map(fn session ->
      session
      |> Map.get(:actions, "")
      |> String.split(",", trim: true)
    end)
    |> Enum.frequencies()
  end

  defp remote_probe_action(candidate) do
    cond do
      remote_probe_manual?(candidate) -> "manual"
      remote_probe_requires_force?(candidate) -> "force-probe"
      true -> "probe"
    end
  end

  defp remote_probe_manual?(candidate) do
    candidate
    |> Map.put(:type, "ssh")
    |> SessionInventory.probe_runs_in_agent_ui?()
  end

  defp remote_probe_requires_force?(candidate) do
    candidate
    |> Map.put(:type, "ssh")
    |> SessionInventory.probe_requires_force?()
  end

  defp manual_remote_probes(candidates) do
    Enum.map(candidates, fn candidate ->
      candidate
      |> Map.merge(%{
        target: "#{candidate.server}/#{candidate.session}:#{candidate.window}.#{candidate.pane}",
        tmux: "unknown",
        sessions: 0,
        remote_sessions: [],
        detail: "remote probe needs a shell prompt; pane appears to be an agent UI",
        status: "skipped",
        error: :remote_probe_needs_shell_prompt
      })
    end)
  end

  defp skipped_remote_probes(_candidates, true), do: []

  defp skipped_remote_probes(candidates, false) do
    Enum.map(candidates, fn candidate ->
      candidate
      |> Map.merge(%{
        target: "#{candidate.server}/#{candidate.session}:#{candidate.window}.#{candidate.pane}",
        tmux: "unknown",
        sessions: 0,
        remote_sessions: [],
        detail: "force required for active SSH shell pane",
        status: "skipped",
        error: :remote_probe_requires_force
      })
    end)
  end

  defp session_capture(session, lines) do
    case require_tmux_session(session) do
      :ok ->
        case capture_tmux_pane(session.host, session.session,
               tmux_server: session.server,
               window: session.window,
               pane: session.pane,
               lines: lines
             ) do
          {:ok, output} ->
            capture =
              %{
                status: "ok",
                output: output,
                summary: SessionStatus.summary(output)
              }
              |> Map.merge(SessionStatus.analyze(session, %{status: "ok", output: output}))

            capture

          {:error, reason} ->
            capture = %{status: "error", error: inspect(reason), output: ""}
            Map.merge(capture, SessionStatus.analyze(session, capture))
        end

      {:error, _reason} ->
        capture = %{status: "skipped", output: "", summary: ""}
        Map.merge(capture, SessionStatus.analyze(session, capture))
    end
  end

  defp require_ssh_tmux_session(%{type: "ssh"} = session), do: require_tmux_session(session)
  defp require_ssh_tmux_session(_session), do: {:error, :session_not_ssh}

  defp authorize_session_probe(session, force?) do
    cond do
      SessionInventory.probe_runs_in_agent_ui?(session) ->
        {:error, {:session_probe_needs_shell_prompt, session.ref}}

      not force? and SessionInventory.probe_requires_force?(session) ->
        {:error, {:session_probe_requires_force, session.ref}}

      true ->
        :ok
    end
  end

  defp remote_probe_recommendation(%{probe_action: "manual"} = candidate, ref) do
    %{
      priority: "medium",
      kind: "remote",
      action: "remote-discovery-needs-shell",
      ref: ref,
      target:
        "#{candidate.target} #{candidate.server}/#{candidate.session}:#{candidate.window}.#{candidate.pane}",
      reason:
        "SSH pane appears to be an agent UI; remote discovery needs direct SSH auth or a shell prompt",
      source: remote_probe_source(candidate)
    }
  end

  defp remote_probe_recommendation(candidate, ref) do
    %{
      priority: "medium",
      kind: "remote",
      action: "capture-before-force-probe",
      ref: ref,
      target:
        "#{candidate.target} #{candidate.server}/#{candidate.session}:#{candidate.window}.#{candidate.pane}",
      reason: "active SSH shell pane gates remote tmux discovery",
      source: remote_probe_source(candidate)
    }
  end

  defp remote_probe_source(candidate) do
    %{
      ssh_target: candidate.target,
      tmux_server: candidate.server,
      session_name: candidate.session,
      window: candidate.window,
      pane: candidate.pane,
      active: Map.get(candidate, :active),
      current_path: Map.get(candidate, :current_path),
      title: Map.get(candidate, :title)
    }
  end

  defp pane_transport_opts(session, opts) do
    [
      session_name: session.session,
      tmux_server: session.server,
      window: session.window,
      pane: session.pane,
      timeout_ms: Keyword.get(opts, :timeout_ms, 5_000)
    ]
  end

  defp session_worktree(%{current_path: path}) when is_binary(path) and path != "" do
    {:ok, path}
  end

  defp session_worktree(_session), do: {:error, :pane_worktree_unknown}

  defp do_stream_adopt_session(session, project, opts) do
    cond do
      tmux_session?(session) ->
        stream_adopt_tmux_session(session, project, opts)

      Keyword.get(opts, :relaunch, false) ->
        stream_adopt_relaunch(session, project, opts)

      true ->
        {:ok, stream_adoption_plan(session, project, opts)}
    end
  end

  defp do_resume_adopt_session(session, project, opts) do
    if Keyword.get(opts, :relaunch, false) do
      resume_adopt_relaunch(session, project, opts)
    else
      {:ok, resume_adoption_plan(session, project, opts)}
    end
  end

  defp stream_adopt_tmux_session(session, project, opts) do
    agent_name = stream_agent_name(session, opts)

    with {:ok, task} <- adopt_session(session.ref, project.name, agent_name: agent_name) do
      {:ok,
       %{
         status: "adopted",
         mode: "tmux-adopt",
         ref: session.ref,
         project: project.name,
         reason: "session already has a controllable tmux pane",
         session: stream_session_summary(session),
         task: stream_task_summary(task),
         next_action: %{
           action: "send-session",
           ref: session.ref,
           safety: "gated",
           reason: "future input can flow through the adopted tmux pane"
         }
       }}
    end
  end

  defp stream_adopt_relaunch(session, project, opts) do
    agent_name = stream_agent_name(session, opts)
    agent_transport = Keyword.fetch!(opts, :agent_transport)
    prompt = stream_adoption_prompt(session, project)

    with {:ok, task} <-
           assign_task(project.name, prompt,
             agent_name: agent_name,
             agent_transport: agent_transport
           ) do
      {:ok,
       %{
         status: "relaunched",
         mode: "managed-relaunch",
         ref: session.ref,
         project: project.name,
         reason:
           "process-only agent cannot be safely attached; launched a managed replacement under tmux",
         session: stream_session_summary(session),
         task: stream_task_summary(task),
         next_action: %{
           action: "send-session",
           task_id: task.task_id,
           safety: "gated",
           reason: "future input and logs now flow through the managed task"
         }
       }}
    end
  end

  defp stream_adoption_plan(session, project, opts) do
    agent_name = stream_agent_name(session, opts)
    agent_transport = Keyword.get(opts, :agent_transport, AgentRunner.default_agent_transport())

    %{
      status: "needs-managed-bridge",
      mode: "plan",
      ref: session.ref,
      project: project.name,
      can_hijack: false,
      can_relaunch: true,
      reason:
        "process-only agent stdio is not safely attachable; relaunch under managed tmux to bridge future stream and input",
      session: stream_session_summary(session),
      next_action: %{
        action: "relaunch-managed",
        safety: "manual",
        agent_name: agent_name,
        command:
          "jx session stream-adopt #{session.ref} #{project.name} --agent #{agent_name}#{agent_transport_flag(agent_transport)} --relaunch",
        reason: "start a managed replacement session with durable tmux logging"
      }
    }
  end

  defp resume_adopt_relaunch(session, project, opts) do
    agent_name = stream_agent_name(session, opts)
    resume_cwd = session_process_cwd(project, session)
    prompt = resume_adoption_prompt(session, project, resume_cwd)

    with {:ok, resume_id} <- session_resume_id(session),
         {:ok, task} <-
           create_resume_adopted_task(project, session, prompt, agent_name, resume_id, resume_cwd),
         {:ok, task} <- ensure_task(project, project.host, task) do
      {:ok,
       %{
         status: "relaunched",
         mode: "resume-relaunch",
         ref: session.ref,
         project: project.name,
         reason:
           "launched a managed agent with resume context from the discovered Zed/ACP process",
         session: stream_session_summary(session),
         task: stream_task_summary(task),
         next_action: %{
           action: "send-session",
           task_id: task.task_id,
           safety: "gated",
           reason: "future input and logs now flow through the managed resumed task"
         }
       }}
    end
  end

  defp resume_adoption_plan(session, project, opts) do
    agent_name = stream_agent_name(session, opts)

    %{
      status: "resume-available",
      mode: "plan",
      ref: session.ref,
      project: project.name,
      can_hijack: false,
      can_resume: true,
      resume_ref: Map.get(session, :resume_ref, ""),
      zed_workspace: Map.get(session, :zed_workspace, ""),
      reason:
        "Zed/ACP owns this agent stream; relaunch with resume context to bring future logs and input under Jido",
      session: stream_session_summary(session),
      next_action: %{
        action: "resume-relaunch",
        safety: "manual",
        agent_name: agent_name,
        command:
          "jx session resume-adopt #{session.ref} #{project.name} --agent #{agent_name} --relaunch",
        reason: "start a managed replacement session with resume context"
      }
    }
  end

  defp resume_adoption_prompt(session, project, resume_cwd) do
    """
    Resume work from a Zed/ACP-launched #{session.kind} agent.

    Existing process:
    - ref: #{session.ref}
    - host: #{session.host}
    - pid: #{format_prompt_value(session.pid)}
    - parent pid: #{format_prompt_value(Map.get(session, :ppid))}
    - role: #{format_prompt_value(Map.get(session, :process_role))}
    - resume ref: #{format_prompt_value(Map.get(session, :resume_ref))}
    - Zed workspace: #{format_prompt_value(Map.get(session, :zed_workspace))}
    - original cwd: #{format_prompt_value(resume_cwd)}

    The original Zed ACP stdio stream is owned by Zed, so Jido cannot safely hijack it. Resume the conversation where supported, preserve the original process cwd when needed for Claude's resume lookup, and continue under managed tmux logging for the #{project.name} project.
    """
    |> String.trim()
  end

  defp stream_adoption_prompt(session, project) do
    """
    Continue work from a locally discovered process-only #{session.kind} agent.

    Existing process:
    - ref: #{session.ref}
    - host: #{session.host}
    - pid: #{format_prompt_value(session.pid)}
    - tty: #{format_prompt_value(session.tty)}
    - command: #{format_prompt_value(session.command)}
    - current path: #{format_prompt_value(session.current_path)}

    The original process is outside jx's managed tmux transport, so its stdio cannot be hijacked safely. Re-establish context from the #{project.name} project worktree and continue from visible repo state. Do not assume access to hidden terminal history from the original process.
    """
    |> String.trim()
  end

  defp stream_session_summary(session) do
    %{
      ref: session.ref,
      host: session.host,
      transport: Map.get(session, :transport, ""),
      type: session.type,
      kind: session.kind,
      pid: Map.get(session, :pid),
      ppid: Map.get(session, :ppid),
      tty: Map.get(session, :tty, ""),
      command: Map.get(session, :command, ""),
      process_role: Map.get(session, :process_role, ""),
      resume_available: Map.get(session, :resume_available, false),
      resume_ref: Map.get(session, :resume_ref, ""),
      zed_workspace: Map.get(session, :zed_workspace, ""),
      current_path: Map.get(session, :current_path, ""),
      tmux_server: Map.get(session, :server, ""),
      session_name: Map.get(session, :session, ""),
      window: Map.get(session, :window),
      pane: Map.get(session, :pane)
    }
  end

  defp stream_task_summary(task) do
    %{
      task_id: task.task_id,
      agent_name: task.agent_name,
      agent_transport: task.agent_transport,
      branch: task.branch,
      status: task.status,
      worktree_path: task.worktree_path,
      tmux_server: task.tmux_server,
      session_name: task.session_name,
      window: task.window,
      pane: task.pane,
      log_path: task.log_path
    }
  end

  defp stream_agent_name(session, opts) do
    case Keyword.get(opts, :agent_name) do
      nil -> session_agent_name(session)
      "" -> session_agent_name(session)
      agent_name -> agent_name
    end
  end

  defp validate_stream_agent_name(nil), do: :ok
  defp validate_stream_agent_name(""), do: :ok

  defp validate_stream_agent_name(agent_name) do
    if agent_name in AgentRunner.agent_names() do
      :ok
    else
      {:error, {:unsupported_agent, agent_name}}
    end
  end

  defp normalize_agent_transport(nil), do: AgentRunner.default_agent_transport()
  defp normalize_agent_transport(""), do: AgentRunner.default_agent_transport()

  defp normalize_agent_transport(agent_transport) do
    agent_transport
    |> to_string()
    |> String.trim()
  end

  defp normalize_optional_host_name(nil), do: nil
  defp normalize_optional_host_name(""), do: nil

  defp normalize_optional_host_name(host_name) do
    host_name
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp assign_project(project_name, nil), do: Projects.get_project_by_name(project_name)

  defp assign_project(project_name, host_name),
    do: Projects.get_project_by_name(project_name, host_name)

  defp assign_project_not_found(_project_name, nil), do: :project_not_found

  defp assign_project_not_found(project_name, host_name),
    do: {:project_not_found, project_name, host_name}

  defp validate_agent_transport(agent_transport) do
    if agent_transport in AgentRunner.agent_transports() do
      :ok
    else
      {:error, {:unsupported_agent_transport, agent_transport}}
    end
  end

  defp validate_goal_options("", _agent_name, _agent_transport), do: :ok
  defp validate_goal_options(_goal_objective, "codex", "native"), do: :ok

  defp validate_goal_options(_goal_objective, "codex", agent_transport),
    do: {:error, {:unsupported_goal_transport, agent_transport}}

  defp validate_goal_options(_goal_objective, agent_name, _agent_transport),
    do: {:error, {:unsupported_goal_agent, agent_name}}

  defp agent_transport_flag("native"), do: ""
  defp agent_transport_flag(agent_transport), do: " --transport #{agent_transport}"

  defp session_resume_id(%{pid: pid} = session) when is_integer(pid) do
    case session_ps_output(session) do
      {:ok, output} -> ProcessInventory.resume_id_from_ps(output, pid)
      {:error, reason} -> {:error, reason}
    end
  end

  defp session_resume_id(_session), do: {:error, :resume_not_found}

  defp session_ps_output(%{host: "local"}) do
    case Command.run("ps", ["-axo", "pid,ppid,stat,tty,command"],
           stderr_to_stdout: true,
           timeout_ms: 5_000
         ) do
      {:ok, {output, 0}} ->
        {:ok, output}

      {:ok, {output, status}} ->
        {:error, {:process_inventory_failed, status, output}}

      {:error, {:command_timeout, _command, _args, timeout_ms}} ->
        {:error, {:process_inventory_timeout, timeout_ms}}
    end
  end

  defp session_ps_output(%{host: host_name}) do
    with {:host, %{} = host} <- {:host, Hosts.get_host_by_name(host_name)} do
      SSH.adapter(host).run(host, ProcessInventory.ps_script())
    else
      {:host, nil} -> {:error, :host_not_found}
    end
  end

  defp session_process_cwd(project, %{pid: pid}) when is_integer(pid) do
    script = """
    echo jx-process-cwd >/dev/null
    pid=#{pid}
    if [ -e "/proc/$pid/cwd" ]; then
      readlink "/proc/$pid/cwd" 2>/dev/null || true
    fi
    """

    case SSH.adapter(project.host).run(project.host, script) do
      {:ok, output} -> absolute_path_or_empty(String.trim(output))
      {:error, _reason} -> ""
    end
  end

  defp session_process_cwd(_project, _session), do: ""

  defp absolute_path_or_empty(path) when is_binary(path) and path != "" do
    if Path.type(path) == :absolute, do: path, else: ""
  end

  defp absolute_path_or_empty(_path), do: ""

  defp session_agent_name(%{kind: kind}) when kind in ["claude", "opencode", "codex", "grok"],
    do: kind

  defp session_agent_name(_session), do: "claude"

  defp prompt_hash_scope(project, agent_name, "native"), do: "#{project.slug}:#{agent_name}"

  defp prompt_hash_scope(project, agent_name, transport),
    do: "#{project.slug}:#{agent_name}:#{transport}"

  defp prompt_hash_input(prompt, ""), do: prompt

  defp prompt_hash_input(prompt, goal_objective) do
    "prompt:\n#{prompt}\n\ngoal:\n#{goal_objective}"
  end

  defp normalize_goal_objective(prompt, opts) do
    case Keyword.get(opts, :goal_objective) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> if Keyword.get(opts, :goal, false), do: prompt, else: ""
          trimmed -> trimmed
        end

      _other ->
        if Keyword.get(opts, :goal, false), do: prompt, else: ""
    end
  end

  defp format_prompt_value(value) when value in [nil, ""], do: "unknown"
  defp format_prompt_value(value), do: to_string(value)

  def adopt_tmux_task(project_name, opts) do
    agent_name = opts |> Keyword.get(:agent_name, "claude") |> IDs.slug()
    session_name = opts |> Keyword.fetch!(:session_name) |> String.trim()
    worktree_path = opts |> Keyword.fetch!(:worktree_path) |> String.trim()
    window = Keyword.get(opts, :window, 0)
    pane = Keyword.get(opts, :pane, 0)

    tmux_server =
      opts |> Keyword.get(:tmux_server, Tmux.managed_server()) |> Tmux.normalize_server()

    with {:project, %{} = project} <- {:project, Projects.get_project_by_name(project_name)},
         {:ok, inspected} <-
           inspect_tmux_adoption(project.host, session_name, worktree_path, tmux_server,
             window: window,
             pane: pane
           ) do
      task =
        Tasks.get_task_by_pane(project.id, tmux_server, session_name, window, pane) ||
          create_adopted_task!(project, project.host, %{
            agent_name: agent_name,
            branch: inspected.branch,
            session_name: session_name,
            tmux_server: tmux_server,
            window: window,
            pane: pane,
            worktree_path: worktree_path
          })

      ensure_adopted_task(project, project.host, task)
    else
      {:project, nil} -> {:error, :project_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def adopt_activity_task(project_name, opts) do
    agent_name = opts |> Keyword.get(:agent_name, "claude") |> IDs.slug()
    session_name = opts |> Keyword.fetch!(:session_name) |> String.trim()
    window = Keyword.get(opts, :window, 0)
    pane = Keyword.get(opts, :pane, 0)

    tmux_server =
      opts |> Keyword.fetch!(:tmux_server) |> Tmux.normalize_server()

    with {:project, %{} = project} <- {:project, Projects.get_project_by_name(project_name)},
         {:ok, activity_pane} <-
           find_activity_pane(project.host, tmux_server, session_name, window, pane),
         {:ok, worktree_path} <- activity_worktree(activity_pane) do
      adopt_tmux_task(project_name,
        session_name: session_name,
        worktree_path: worktree_path,
        tmux_server: tmux_server,
        window: window,
        pane: pane,
        agent_name: agent_name
      )
    else
      {:project, nil} -> {:error, :project_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def attach(task_id) do
    with %{} = task <- Tasks.get_task_by_id(task_id) do
      SSH.adapter(task.host).attach(task.host, task.session_name, tmux_server: task.tmux_server)
    else
      nil -> {:error, :task_not_found}
    end
  end

  def logs(task_id, opts \\ []) do
    with %{} = task <- Tasks.get_task_by_id(task_id) do
      SSH.adapter(task.host).stream_log(task.host, task.log_path, opts)
    else
      nil -> {:error, :task_not_found}
    end
  end

  def send(task_id, message, opts \\ []) do
    enter? = Keyword.get(opts, :enter, true)

    with %{} = task <- Tasks.get_task_by_id(task_id) do
      window = Keyword.get(opts, :window, task.window || 0)
      pane = Keyword.get(opts, :pane, task.pane || 0)

      send_opts =
        opts
        |> Keyword.put(:tmux_server, task.tmux_server)
        |> Keyword.put(:window, window)
        |> Keyword.put(:pane, pane)

      result =
        SSH.adapter(task.host).run(
          task.host,
          Tmux.send_keys_script(task.session_name, message, send_opts)
        )

      record_directive_result(
        %{
          target_type: "task",
          task_ref: task.task_id,
          host_id: task.host_id,
          tmux_server: task.tmux_server,
          session_name: task.session_name,
          window: window,
          pane: pane,
          message: message,
          enter: enter?
        },
        result
      )
    else
      nil -> {:error, :task_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def stop(task_id) do
    with %{} = task <- Tasks.get_task_by_id(task_id),
         {:ok, _output} <- SSH.adapter(task.host).run(task.host, Tmux.stop_script(task)),
         {:ok, task} <- Tasks.update_status(task, "stopped") do
      {:ok, task}
    else
      nil -> {:error, :task_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_task!(
         project,
         host,
         prompt,
         prompt_hash,
         agent_name,
         agent_transport,
         goal_objective
       ) do
    task_id = IDs.task_id(prompt_hash)
    paths = IDs.task_paths(host, project, task_id)

    attrs =
      %{
        task_id: task_id,
        prompt_hash: prompt_hash,
        prompt: prompt,
        goal_objective: goal_objective,
        agent_name: agent_name,
        agent_transport: agent_transport,
        branch: IDs.branch(task_id),
        session_name: IDs.session_name(project.slug, task_id, agent_name),
        tmux_server: Tmux.managed_server(),
        window: 0,
        pane: 0,
        status: "creating",
        last_error: "",
        project_id: project.id,
        host_id: host.id
      }
      |> Map.merge(paths)

    attrs = Map.put(attrs, :launch_command, AgentRunner.command(attrs))

    case Tasks.insert_task(attrs) do
      {:ok, task} ->
        task = Tasks.get_task_by_id(task.task_id)
        register_task_resources!(project, task)
        task

      {:error, changeset} ->
        raise "could not create task: #{inspect(changeset.errors)}"
    end
  end

  defp register_task_resources!(project, task) do
    owner_project = project.slug || project.name || "unknown"

    with :ok <-
           register_resource(
             %{
               owner_project: owner_project,
               execution_id: task.task_id,
               resource_name: task.session_name,
               tmux_server: task.tmux_server,
               reason: "JX task tmux session",
               metadata: Jason.encode!(%{task_id: task.task_id, project: owner_project})
             },
             :tmux_session
           ),
         :ok <-
           register_task_paths(owner_project, task) do
      :ok
    else
      {:error, reason} ->
        {:ok, _task} =
          Tasks.update_status(
            task,
            "error",
            "resource ownership registration failed: #{inspect(reason)}"
          )

        raise "resource ownership registration failed: #{inspect(reason)}"
    end
  end

  defp register_task_paths(owner_project, task) do
    [
      {"worktree_path", task.worktree_path, "JX task worktree path"},
      {"task_dir", task.task_dir, "JX task metadata directory"},
      {"log_path", task.log_path, "JX task log path"}
    ]
    |> Enum.reduce_while(:ok, fn {type, path, reason}, :ok ->
      result =
        register_resource(
          %{
            owner_project: owner_project,
            execution_id: task.task_id,
            resource_type: type,
            resource_name: task.task_id,
            resource_path: path,
            reason: reason,
            metadata: Jason.encode!(%{task_id: task.task_id, project: owner_project})
          },
          :temp_path
        )

      case result do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp register_resource(attrs, :tmux_session) do
    case resource_ownerships().register_tmux_session(attrs) do
      {:ok, _resource} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp register_resource(attrs, :temp_path) do
    case resource_ownerships().register_temp_path(attrs) do
      {:ok, _resource} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp resource_ownerships do
    Application.get_env(:jx, :resource_ownerships, ResourceOwnerships)
  end

  defp create_resume_adopted_task(project, session, prompt, agent_name, resume_id, resume_cwd) do
    host = project.host
    agent_bin = resume_agent_bin(session, agent_name)

    prompt_hash =
      IDs.prompt_hash(
        "#{project.slug}:#{agent_name}:resume-adopt",
        "#{session.ref}\n#{session.host}\n#{Map.get(session, :pid)}\n#{Map.get(session, :resume_ref)}\n#{agent_bin}\n#{resume_cwd}"
      )

    task =
      Tasks.get_task_by_prompt(project.id, prompt_hash) ||
        create_resume_adopted_task!(
          project,
          host,
          prompt,
          prompt_hash,
          agent_name,
          agent_bin,
          resume_cwd,
          resume_id
        )

    {:ok, task}
  end

  defp create_resume_adopted_task!(
         project,
         host,
         prompt,
         prompt_hash,
         agent_name,
         agent_bin,
         resume_cwd,
         resume_id
       ) do
    task_id = IDs.task_id(prompt_hash)
    paths = IDs.task_paths(host, project, task_id)

    attrs =
      %{
        task_id: task_id,
        prompt_hash: prompt_hash,
        prompt: prompt,
        agent_name: agent_name,
        branch: IDs.branch(task_id),
        session_name: IDs.session_name(project.slug, task_id, agent_name),
        tmux_server: Tmux.managed_server(),
        window: 0,
        pane: 0,
        agent_bin: agent_bin,
        resume_cwd: resume_cwd,
        status: "creating",
        last_error: "",
        project_id: project.id,
        host_id: host.id
      }
      |> Map.merge(paths)

    attrs = Map.put(attrs, :launch_command, AgentRunner.resume_command(attrs, resume_id))

    case Tasks.insert_task(attrs) do
      {:ok, task} -> Tasks.get_task_by_id(task.task_id)
      {:error, changeset} -> raise "could not create resume task: #{inspect(changeset.errors)}"
    end
  end

  defp resume_agent_bin(session, agent_name) do
    executable =
      session
      |> Map.get(:command, "")
      |> command_executable()

    if executable not in [nil, ""] and Path.type(executable) == :absolute do
      executable
    else
      AgentRunner.binary(agent_name)
    end
  end

  defp command_executable(command) when is_binary(command) do
    command
    |> String.trim()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
  end

  defp command_executable(_command), do: nil

  defp create_adopted_task!(project, host, attrs) do
    prompt =
      "Adopted tmux session #{attrs.session_name} at #{attrs.worktree_path}"

    prompt_hash =
      IDs.prompt_hash(
        "#{project.slug}:#{attrs.agent_name}:adopt-tmux",
        "#{attrs.tmux_server}\n#{attrs.session_name}\n#{attrs.window}\n#{attrs.pane}\n#{attrs.worktree_path}"
      )

    task_id = IDs.task_id(prompt_hash)

    paths =
      host
      |> IDs.task_paths(project, task_id)
      |> Map.put(:worktree_path, attrs.worktree_path)

    task_attrs =
      %{
        task_id: task_id,
        prompt_hash: prompt_hash,
        prompt: prompt,
        agent_name: attrs.agent_name,
        branch: attrs.branch,
        session_name: attrs.session_name,
        tmux_server: attrs.tmux_server,
        window: attrs.window,
        pane: attrs.pane,
        launch_command: "",
        status: "running",
        last_error: "",
        project_id: project.id,
        host_id: host.id
      }
      |> Map.merge(paths)

    case Tasks.insert_task(task_attrs) do
      {:ok, task} ->
        fire_capacity_snapshot(host)
        Tasks.get_task_by_id(task.task_id)

      {:error, changeset} ->
        raise "could not adopt task: #{inspect(changeset.errors)}"
    end
  end

  defp ensure_task(project, host, task) do
    task_json = task_json(project, host, task)

    script =
      GitWorktrees.ensure_worktree_script(project, task, task_json) <>
        Tmux.ensure_session_script(task) <>
        AgentRunner.launch_script(task)

    case SSH.adapter(host).run(host, script) do
      {:ok, _output} ->
        result = Tasks.update_status(task, "running")
        fire_capacity_snapshot(host)
        result

      {:error, reason} ->
        {:ok, failed_task} = Tasks.update_status(task, "error", inspect(reason))
        fire_capacity_snapshot(host)
        {:error, {reason, failed_task}}
    end
  end

  defp ensure_adopted_task(project, host, task) do
    script = Tmux.adopt_session_script(task, task_json(project, host, task))

    case SSH.adapter(host).run(host, script) do
      {:ok, _output} ->
        result = Tasks.update_status(task, "running")
        fire_capacity_snapshot(host)
        result

      {:error, reason} ->
        {:ok, failed_task} = Tasks.update_status(task, "error", inspect(reason))
        fire_capacity_snapshot(host)
        {:error, {reason, failed_task}}
    end
  end

  defp ensure_launch_command(%{launch_command: command} = task)
       when is_binary(command) and command != "" do
    {:ok, task}
  end

  defp ensure_launch_command(task) do
    launch_command = AgentRunner.command(task)
    Tasks.update_launch_command(task, launch_command)
  end

  @capacity_snapshot_statuses ~w(completed failed stopped stale expired error)

  defp status_for_task(task, opts \\ []) do
    case SSH.adapter(task.host).run(task.host, Tmux.status_script(task)) do
      {:ok, output} ->
        {session_status, last_activity, exit_status} = parse_remote_status(output)
        {status, last_error} = task_status(task, session_status, last_activity, exit_status, opts)
        {:ok, updated_task} = Tasks.update_status(task, status, last_error)

        if status in @capacity_snapshot_statuses do
          fire_capacity_snapshot(task.host)
        end

        %{
          task: %{updated_task | host: task.host, project: task.project},
          session_status: session_status,
          last_activity: last_activity,
          exit_status: exit_status,
          goal_status: task_goal_status(task)
        }

      {:error, reason} ->
        task = stale_task_on_remote_error(task, reason, opts)
        %{task: task, session_status: "unknown", last_activity: nil, error: reason}
    end
  end

  defp parse_remote_status(output) do
    [session_status | rest] = String.split(output, ~r/\s+/, trim: true)

    last_activity =
      rest
      |> List.first()
      |> parse_unix_time()

    exit_status =
      rest
      |> Enum.at(1)
      |> parse_exit_status()

    {session_status, last_activity, exit_status}
  end

  defp task_goal_status(%{goal_objective: goal_objective} = task)
       when is_binary(goal_objective) and goal_objective != "" do
    case SSH.adapter(task.host).run(task.host, AgentRunner.goal_status_script(task)) do
      {:ok, output} ->
        case Jason.decode(String.trim(output)) do
          {:ok, %{} = status} -> status
          _other -> %{"status" => "unknown"}
        end

      {:error, reason} ->
        %{"status" => "unknown", "error" => inspect(reason)}
    end
  end

  defp task_goal_status(_task), do: nil

  defp inspect_tmux_adoption(host, session_name, worktree_path, tmux_server, opts) do
    case SSH.adapter(host).run(
           host,
           Tmux.inspect_session_script(session_name, worktree_path, tmux_server, opts)
         ) do
      {:ok, output} ->
        {:ok, parse_adoption_inspection(output)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_activity_pane(host, tmux_server, session_name, window, pane) do
    case SSH.adapter(host).run(host, Tmux.list_panes_script(tmux_server)) do
      {:ok, output} ->
        output
        |> parse_tmux_panes(server_field: false, server: tmux_server)
        |> Enum.find(&(&1.session == session_name and &1.window == window and &1.pane == pane))
        |> case do
          nil -> {:error, :pane_not_found}
          pane -> {:ok, pane}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp activity_worktree(%{current_path: path}) when is_binary(path) and path != "" do
    {:ok, path}
  end

  defp activity_worktree(_pane), do: {:error, :pane_worktree_unknown}

  defp parse_adoption_inspection(output) do
    values =
      output
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        case String.split(line, "\t", parts: 2) do
          [key, value] -> {key, value}
          [key] -> {key, ""}
        end
      end)

    %{branch: Map.get(values, "branch", "adopted")}
  end

  defp parse_tmux_sessions(output, opts) do
    server_field? = Keyword.get(opts, :server_field, false)
    server = Keyword.get(opts, :server, Tmux.managed_server())

    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      if String.contains?(line, "\t") do
        case parse_tmux_session(line, server_field?, server) do
          nil ->
            maybe_debug_dropped_tmux_line("session", line)
            []

          session ->
            [session]
        end
      else
        maybe_debug_dropped_tmux_line("session", line)
        []
      end
    end)
  end

  defp parse_tmux_session(line, false, server) do
    case String.split(line, "\t", parts: 5) do
      [name, created, attached, windows, current_path] ->
        build_tmux_session(server, name, created, attached, windows, current_path)

      [name, created, attached, windows] ->
        build_tmux_session(server, name, created, attached, windows, "")

      _ ->
        nil
    end
  end

  defp parse_tmux_session(line, true, _server) do
    case String.split(line, "\t", parts: 2) do
      [server, rest] ->
        rest
        |> parse_tmux_session(false, server)
        |> then(fn
          nil -> nil
          session -> Map.put(session, :server, server)
        end)

      _ ->
        nil
    end
  end

  defp parse_tmux_panes(output, opts) do
    server_field? = Keyword.get(opts, :server_field, false)
    server = Keyword.get(opts, :server, Tmux.managed_server())

    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      if String.contains?(line, "\t") do
        case parse_tmux_pane(line, server_field?, server) do
          nil ->
            maybe_debug_dropped_tmux_line("pane", line)
            []

          pane ->
            [pane]
        end
      else
        maybe_debug_dropped_tmux_line("pane", line)
        []
      end
    end)
  end

  defp parse_tmux_pane(line, false, server) do
    case String.split(line, "\t", parts: 9) do
      [session, window, pane, pane_id, active, tty, command, current_path, title] ->
        build_tmux_pane(
          server,
          session,
          window,
          pane,
          pane_id,
          active,
          tty,
          command,
          current_path,
          title
        )

      [session, window, pane, pane_id, active, tty, command, current_path] ->
        build_tmux_pane(
          server,
          session,
          window,
          pane,
          pane_id,
          active,
          tty,
          command,
          current_path,
          ""
        )

      _ ->
        nil
    end
  end

  defp parse_tmux_pane(line, true, _server) do
    case String.split(line, "\t", parts: 2) do
      [server, rest] ->
        rest
        |> parse_tmux_pane(false, server)
        |> then(fn
          nil -> nil
          pane -> Map.put(pane, :server, server)
        end)

      _ ->
        nil
    end
  end

  defp build_tmux_session(server, name, created, attached, windows, current_path) do
    with %DateTime{} = created_at <- parse_unix_time(created),
         attached when is_integer(attached) <- parse_integer(attached),
         windows when is_integer(windows) <- parse_integer(windows),
         true <- String.trim(name) != "" do
      %{
        server: server,
        name: name,
        created_at: created_at,
        attached: attached,
        windows: windows,
        current_path: current_path
      }
    else
      _invalid -> nil
    end
  end

  defp build_tmux_pane(
         server,
         session,
         window,
         pane,
         pane_id,
         active,
         tty,
         command,
         current_path,
         title
       ) do
    with window when is_integer(window) <- parse_integer(window),
         pane when is_integer(pane) <- parse_integer(pane),
         {:ok, active?} <- parse_tmux_bool(active),
         true <- String.trim(session) != "",
         true <- String.trim(pane_id) != "" do
      %{
        server: server,
        session: session,
        window: window,
        pane: pane,
        pane_id: pane_id,
        active: active?,
        tty: tty,
        kind: pane_kind(command, title),
        command: command,
        current_path: current_path,
        title: title
      }
    else
      _invalid -> nil
    end
  end

  defp parse_tmux_bool("1"), do: {:ok, true}
  defp parse_tmux_bool("0"), do: {:ok, false}
  defp parse_tmux_bool(_value), do: :error

  defp maybe_debug_dropped_tmux_line(kind, line) do
    if System.get_env("JX_DEBUG") in ["1", "true", "TRUE", "yes", "YES"] do
      IO.warn("jx: dropped malformed tmux #{kind} line: #{inspect(line)}")
    end
  end

  defp pane_kind(command, title) do
    text = String.downcase("#{command} #{title}")

    cond do
      String.contains?(text, "codex") -> "codex"
      String.contains?(text, "claude") -> "claude"
      String.match?(command, ~r/^\d+\.\d+\.\d+$/) -> "claude"
      String.contains?(text, "opencode") -> "opencode"
      command in ["ssh", "sshs"] -> "ssh"
      command in ["sh", "bash", "zsh", "fish"] -> "shell"
      true -> "other"
    end
  end

  defp task_status(_task, _session_status, _last_activity, 0, _opts), do: {"completed", ""}

  defp task_status(_task, _session_status, _last_activity, exit_status, _opts)
       when is_integer(exit_status) do
    {"failed", "agent exited #{exit_status}"}
  end

  defp task_status(task, "running", last_activity, nil, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    if active_task?(task) and stale_heartbeat?(task, last_activity, now, opts) do
      stale_age = task_heartbeat_age(task, last_activity, now)
      {"stale", "no task heartbeat for #{stale_age}s"}
    else
      {"running", ""}
    end
  end

  defp task_status(
         %{status: status, last_error: last_error},
         _session_status,
         _last_activity,
         nil,
         _opts
       )
       when status in @terminal_task_statuses do
    {status, last_error || ""}
  end

  defp task_status(task, _session_status, last_activity, nil, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    age = task_heartbeat_age(task, last_activity, now)

    cond do
      active_task?(task) and age >= expire_after_seconds(opts) ->
        {"expired", "no session or exit status for #{age}s"}

      active_task?(task) and age >= stale_after_seconds(opts) ->
        {"stale", "no session or exit status for #{age}s"}

      true ->
        {"stopped", ""}
    end
  end

  defp stale_task_on_remote_error(task, reason, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    age = task_heartbeat_age(task, nil, now)

    if active_task?(task) and age >= stale_after_seconds(opts) do
      status = if age >= expire_after_seconds(opts), do: "expired", else: "stale"
      last_error = "status check failed after #{age}s: #{inspect(reason)}"

      case Tasks.update_status(task, status, last_error) do
        {:ok, updated_task} -> %{updated_task | host: task.host, project: task.project}
        {:error, _changeset} -> task
      end
    else
      task
    end
  end

  defp task_reconciled?(%{task: task}) do
    task.status in @terminal_task_statuses or task.status == "running"
  end

  defp task_reconciled?(_result), do: false

  defp task_result_counts(results) do
    results
    |> Enum.map(& &1.task.status)
    |> Enum.frequencies()
  end

  defp active_task?(%{status: status}), do: status in @active_task_statuses

  defp stale_heartbeat?(task, last_activity, now, opts) do
    task_heartbeat_age(task, last_activity, now) >= stale_after_seconds(opts)
  end

  defp task_heartbeat_age(task, last_activity, now) do
    task
    |> task_heartbeat_at(last_activity)
    |> seconds_since(now)
  end

  defp task_heartbeat_at(%{updated_at: %DateTime{} = updated_at}, %DateTime{} = last_activity) do
    Enum.max_by([updated_at, last_activity], &DateTime.to_unix/1)
  end

  defp task_heartbeat_at(_task, %DateTime{} = last_activity), do: last_activity
  defp task_heartbeat_at(%{updated_at: %DateTime{} = updated_at}, _last_activity), do: updated_at
  defp task_heartbeat_at(_task, _last_activity), do: DateTime.utc_now()

  defp seconds_since(%DateTime{} = from, %DateTime{} = now) do
    max(DateTime.diff(now, from, :second), 0)
  end

  defp stale_after_seconds(opts),
    do: Keyword.get(opts, :stale_after_seconds, @default_task_stale_after_seconds)

  defp expire_after_seconds(opts),
    do: Keyword.get(opts, :expire_after_seconds, @default_task_expire_after_seconds)

  defp parse_unix_time(nil), do: nil
  defp parse_unix_time("0"), do: nil

  defp parse_unix_time(value) do
    case Integer.parse(value) do
      {seconds, ""} -> DateTime.from_unix!(seconds)
      _other -> nil
    end
  end

  defp parse_exit_status(nil), do: nil
  defp parse_exit_status("none"), do: nil

  defp parse_exit_status(value) do
    case Integer.parse(value) do
      {status, ""} -> status
      _other -> nil
    end
  end

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> nil
    end
  end

  # Returns :ok if the host has room for another session, or {:error, ...} if at limit.
  # When an operator-set capacity_limit exists, it is a hard ceiling.
  # When no limit is set, we pass through — the operator has not chosen to enforce one yet.
  defp check_host_capacity(%{capacity_limit: nil}), do: :ok

  defp check_host_capacity(%{id: host_id, capacity_limit: limit, name: name})
       when is_integer(limit) do
    running = Tasks.count_running_for_host(host_id)

    if running < limit do
      :ok
    else
      {:error,
       "host #{name} is at capacity (#{running}/#{limit} sessions running); " <>
         "wait for a session to finish or raise the limit with: jx host capacity set #{name} <n>"}
    end
  end

  # Capacity check that also accepts a project so callers can pass richer context.
  # Currently the project is used for profile resolution in assess/2 but the
  # hard-limit check is identical — kept as a separate head so future per-project
  # sub-limits can be added without touching callers.
  defp check_host_capacity_with_project(host, _project), do: check_host_capacity(host)

  # Fire-and-forget capacity snapshot.  Runs under JX.TaskSupervisor so SSH
  # probe failures are logged rather than silently dropped, while still being
  # unlinked from the calling process (supervisor restart strategy is
  # :temporary by default — no propagation back to the task lifecycle path).
  defp fire_capacity_snapshot(%{id: host_id} = host) do
    active = Tasks.count_running_for_host(host_id)

    Task.Supervisor.start_child(JX.TaskSupervisor, fn ->
      CapacityObserver.snapshot(host, active)
    end)
  end

  defp task_json(project, host, task) do
    Jason.encode!(%{
      task_id: task.task_id,
      project: project.name,
      host: host.name,
      agent_name: task.agent_name,
      agent_transport: task.agent_transport,
      goal_objective: task.goal_objective,
      branch: task.branch,
      worktree_path: task.worktree_path,
      task_dir: task.task_dir,
      log_path: task.log_path,
      session_name: task.session_name,
      tmux_server: task.tmux_server,
      window: task.window,
      pane: task.pane,
      launch_command: task.launch_command
    })
  end
end
