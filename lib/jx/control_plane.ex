defmodule JX.ControlPlane do
  @moduledoc """
  Fleet-oriented operator control-plane reducers.

  The control plane reads existing JX state plus append-only operational events.
  It does not execute commands or call DevIDE.
  """

  import Ecto.Query

  alias JX.Approvals
  alias JX.Approvals.Approval
  alias JX.DelegatedExecution
  alias JX.DelegatedExecution.{Assignment, Report, RunnerReport}
  alias JX.DevIDE.{State, WorkspaceSnapshot}
  alias JX.OperationalEvents
  alias JX.OperationalEvents.Event
  alias JX.OperationalEvents.Reducer
  alias JX.OperationalLeases
  alias JX.OperationalLeases.Lease
  alias JX.OrchestrationActions
  alias JX.OrchestrationActions.OrchestrationAction
  alias JX.Repo
  alias JX.RuntimeEnvironments
  alias JX.SafeActions

  @default_stale_after_seconds 15 * 60
  @terminal_assignment_statuses ~w(completed failed expired abandoned)
  @active_assignment_statuses ~w(created claimed started progressed)
  @failed_assignment_statuses ~w(failed expired abandoned)

  def dashboard(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    stale_after_seconds = Keyword.get(opts, :stale_after_seconds, @default_stale_after_seconds)
    limit = Keyword.get(opts, :limit, 50)
    event_limit = Keyword.get(opts, :event_limit, 25)

    events = OperationalEvents.list(limit: Keyword.get(opts, :rebuild_limit, 10_000))
    state = Reducer.rebuild(events)
    assignments = DelegatedExecution.list_assignments(status: "all", limit: limit, now: now)
    assignment_rows = assignment_rows(limit)
    runners = DelegatedExecution.list_runners(status: "all", limit: limit, now: now)
    sessions = DelegatedExecution.list_runner_sessions(status: "all", limit: limit, now: now)
    leases = OperationalLeases.list(status: "all", limit: limit, now: now)
    workspaces = workspace_health_items(now, stale_after_seconds, limit)
    runtimes = RuntimeEnvironments.list(status: "all", limit: limit, now: now)

    %{
      generated_at: now,
      stale_after_seconds: stale_after_seconds,
      queue: queue(Keyword.merge(opts, now: now, stale_after_seconds: stale_after_seconds)),
      projections: %{
        events: length(events),
        queue: Reducer.queue_projection(state),
        assignments: Reducer.assignment_projection(state),
        runner_fleet: Reducer.runner_fleet_state(state),
        workspaces: Reducer.workspace_state(state),
        failures: Reducer.failure_summary(state)
      },
      workspaces: %{
        total: length(workspaces),
        stale: Enum.count(workspaces, &(&1.health.freshness == "stale")),
        blocked: Enum.count(workspaces, &(&1.health.risk == "blocked")),
        items: workspaces
      },
      runner_fleet: %{
        total: length(runners),
        stale: Enum.count(runners, &Map.get(&1, :stale, false)),
        busy: Enum.count(runners, &(&1.status == "busy")),
        active_sessions:
          Enum.count(sessions, &(&1.status in ["claimed", "running", "progressed"])),
        runners: runners,
        sessions: sessions
      },
      runtime_environments: %{
        total: length(runtimes),
        ready: Enum.count(runtimes, &(&1.status == "ready")),
        assigned: Enum.count(runtimes, &(&1.status == "assigned")),
        stale: Enum.count(runtimes, &(&1.status in ["expired", "failed"])),
        items: runtimes
      },
      leases: lease_projection(leases, now),
      assignments: assignment_projection(assignments, assignment_rows),
      failures: failure_projection(assignments, sessions, state),
      reconciliation: reconciliation_projection(assignment_rows),
      recent_events: recent_operational_events(limit: event_limit),
      next: %{
        queue: "jx queue ls",
        rebuild: "jx queue rebuild --json",
        timeline: "jx timeline recent",
        runners: "jx runners ls",
        assignments: "jx assignments ls --status all"
      }
    }
  end

  def dashboard_workspace(workspace_id, opts \\ []) do
    event_limit = Keyword.get(opts, :event_limit, 25)

    workspace(workspace_id, opts)
    |> Map.merge(%{
      timeline: timeline_summary("workspace", workspace_id, limit: event_limit),
      recent_events: recent_operational_events(workspace_id: workspace_id, limit: event_limit),
      next: %{
        queue: "jx queue workspace #{workspace_id}",
        timeline: "jx timeline workspace #{workspace_id}",
        approvals: "jx approvals ls --source devide --workspace #{workspace_id}",
        actions: "jx actions history --workspace #{workspace_id}",
        assignments: "jx assignments ls --workspace #{workspace_id} --status all"
      }
    })
  end

  def dashboard_runner(runner_id, opts \\ []) do
    runner_id = to_string(runner_id)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    event_limit = Keyword.get(opts, :event_limit, 25)
    limit = Keyword.get(opts, :limit, 100)

    case runner_summary(runner_id, now) do
      nil ->
        {:error, :runner_not_found}

      runner ->
        sessions =
          DelegatedExecution.list_runner_sessions(
            runner_id: runner_id,
            status: "all",
            limit: limit,
            now: now
          )

        assignments =
          DelegatedExecution.list_assignments(status: "all", limit: limit, now: now)
          |> Enum.filter(&(&1.runner_id == runner_id or &1.claimant_agent_id == runner.agent_id))

        {:ok,
         %{
           runner_id: runner_id,
           generated_at: now,
           runner: runner,
           sessions: sessions,
           assignments: assignments,
           reports:
             runner_reports(runner_id, limit)
             |> Enum.map(&runner_report_summary/1),
           timeline: timeline_summary("runner", runner_id, limit: event_limit),
           recent_events:
             recent_operational_events(
               entity_type: "runner",
               entity_id: runner_id,
               limit: event_limit
             ),
           next: %{
             runners: "jx runners show #{runner_id}",
             sessions: "jx runners sessions --runner #{runner_id}",
             timeline: "jx timeline runner #{runner_id}"
           }
         }}
    end
  end

  def dashboard_assignment(assignment_id, opts \\ []) do
    assignment_id = to_string(assignment_id)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    event_limit = Keyword.get(opts, :event_limit, 25)
    limit = Keyword.get(opts, :limit, 100)

    case DelegatedExecution.get_assignment(assignment_id) do
      nil ->
        {:error, :assignment_not_found}

      %Assignment{} = assignment ->
        {:ok,
         %{
           assignment_id: assignment.assignment_id,
           generated_at: now,
           assignment: assignment_detail(assignment, now),
           reports:
             DelegatedExecution.reports_for_assignment(assignment.assignment_id)
             |> Enum.map(&assignment_report_summary/1),
           runner_reports:
             runner_reports_for_assignment(assignment.assignment_id, limit)
             |> Enum.map(&runner_report_summary/1),
           timeline: timeline_summary("assignment", assignment.assignment_id, limit: event_limit),
           replay: assignment_replay_state(assignment),
           failure_chain: assignment_failure_chain(assignment),
           next: %{
             assignments: "jx assignments show #{assignment.assignment_id}",
             timeline: "jx timeline assignment #{assignment.assignment_id}",
             workspace: "jx dashboard workspace #{assignment.workspace_id}",
             runner: "jx dashboard runner #{assignment.runner_id}"
           }
         }}
    end
  end

  def dashboard_action(action_id, opts \\ []) do
    action_id = to_string(action_id)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    event_limit = Keyword.get(opts, :event_limit, 25)
    limit = Keyword.get(opts, :limit, 100)

    case SafeActions.show(action_id) do
      {:error, reason} ->
        {:error, reason}

      {:ok, detail} ->
        assignments =
          DelegatedExecution.list_assignments(status: "all", limit: limit, now: now)
          |> Enum.filter(&(&1.action_id == action_id))

        {:ok,
         %{
           action_id: action_id,
           generated_at: now,
           action: safe_action_summary(detail.action, detail.payload),
           approval_id: detail.action.ref,
           approval: approval_detail(detail.action.ref, now),
           evidence: detail.payload,
           execution_events: Enum.map(detail.events, &execution_event_summary/1),
           assignments: assignments,
           reconciliation:
             assignments
             |> Enum.map(&assignment_id_to_row/1)
             |> Enum.reject(&is_nil/1)
             |> reconciliation_projection(),
           timeline: timeline_summary("action", action_id, limit: event_limit),
           recent_events:
             recent_operational_events(
               entity_type: "action",
               entity_id: action_id,
               limit: event_limit
             ),
           next: %{
             action: "jx actions show #{action_id}",
             history: "jx actions history #{detail.action.ref}",
             timeline: "jx timeline action #{action_id}"
           }
         }}
    end
  end

  def queue(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    stale_after_seconds = Keyword.get(opts, :stale_after_seconds, @default_stale_after_seconds)

    items =
      []
      |> Kernel.++(workspace_items(now, stale_after_seconds))
      |> Kernel.++(blocker_items(now, stale_after_seconds))
      |> Kernel.++(approval_items(now, stale_after_seconds))
      |> Kernel.++(action_items(now, stale_after_seconds))
      |> Kernel.++(agent_items(now))
      |> Kernel.++(runner_items(now))
      |> Kernel.++(assignment_items(now))
      |> Kernel.++(runner_session_items(now))
      |> Kernel.++(lease_items(now))
      |> filter_items(opts)
      |> sort_items(Keyword.get(opts, :sort, "urgency"))
      |> Enum.take(Keyword.get(opts, :limit, 50))

    %{
      generated_at: now,
      stale_after_seconds: stale_after_seconds,
      totals: %{
        total: length(items),
        blocked: Enum.count(items, &(&1.risk == "blocked")),
        stale: Enum.count(items, &(&1.freshness == "stale")),
        risky: Enum.count(items, &(&1.risk == "risky")),
        awaiting_operator: Enum.count(items, &(&1.risk == "awaiting_operator")),
        leased: Enum.count(items, &(&1.owner not in [nil, ""]))
      },
      items: items
    }
  end

  def workspace(workspace_id, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    stale_after_seconds = Keyword.get(opts, :stale_after_seconds, @default_stale_after_seconds)
    snapshot = Repo.get_by(WorkspaceSnapshot, workspace_id: workspace_id)
    approvals = Approvals.list(status: "active", workspace_id: workspace_id, limit: 100)
    actions = actions_for_workspace(workspace_id)
    leases = leases_for_workspace(workspace_id)

    %{
      workspace_id: workspace_id,
      generated_at: now,
      stale_after_seconds: stale_after_seconds,
      health: workspace_health(snapshot, now, stale_after_seconds),
      approvals: Enum.map(approvals, &approval_summary(&1, now, stale_after_seconds)),
      actions: Enum.map(actions, &action_summary/1),
      assignments:
        DelegatedExecution.list_assignments(workspace_id: workspace_id, status: "all", limit: 100),
      runner_sessions:
        DelegatedExecution.list_runner_sessions(
          workspace_id: workspace_id,
          status: "all",
          limit: 100
        ),
      leases: Enum.map(leases, &lease_summary/1),
      next: %{
        approvals: "jx approvals ls --source devide --workspace #{workspace_id}",
        devide_status: "jx devide status #{workspace_id}",
        timeline: "jx timeline workspace #{workspace_id}"
      }
    }
  end

  def timeline(scope, id, opts \\ []) do
    events = OperationalEvents.timeline(scope, id, opts)

    %{
      scope: to_string(scope),
      id: id,
      events: events,
      rebuilt: Reducer.rebuild(events)
    }
  end

  def rebuilt_state(opts \\ []) do
    events = OperationalEvents.list(Keyword.put_new(opts, :limit, 10_000))
    state = Reducer.rebuild(events)
    %{events: length(events), state: state, queue: Reducer.queue_state(state)}
  end

  defp workspace_health_items(now, stale_after_seconds, limit) do
    State.list_snapshots(limit: limit)
    |> Enum.map(fn snapshot ->
      %{
        workspace_id: snapshot.workspace_id,
        status: snapshot.status,
        health: workspace_health(snapshot, now, stale_after_seconds),
        next: "jx dashboard workspace #{snapshot.workspace_id}"
      }
    end)
  end

  defp timeline_summary(scope, id, opts) do
    report = timeline(scope, id, opts)

    %{
      scope: report.scope,
      id: report.id,
      events: Enum.map(report.events, &event_summary/1),
      rebuilt: report.rebuilt
    }
  end

  defp lease_projection(leases, now) do
    summaries = Enum.map(leases, &lease_summary/1)

    %{
      total: length(summaries),
      active: Enum.filter(summaries, &(&1.status == "active")),
      stale:
        leases
        |> Enum.filter(&stale_lease?(&1, now))
        |> Enum.map(&lease_summary/1),
      terminal: Enum.filter(summaries, &(&1.status in ["released", "expired", "reassigned"]))
    }
  end

  defp stale_lease?(%Lease{status: "expired"}, _now), do: true
  defp stale_lease?(%Lease{expires_at: nil}, _now), do: true

  defp stale_lease?(%Lease{expires_at: expires_at}, now),
    do: DateTime.compare(expires_at, now) != :gt

  defp assignment_projection(assignments, assignment_rows) do
    %{
      total: length(assignments),
      active: Enum.filter(assignments, &(&1.status in @active_assignment_statuses)),
      terminal: Enum.filter(assignments, &(&1.status in @terminal_assignment_statuses)),
      failed: Enum.filter(assignments, &(&1.status in @failed_assignment_statuses)),
      by_status: count_statuses(assignments),
      replay: reconciliation_projection(assignment_rows)
    }
  end

  defp failure_projection(assignments, sessions, state) do
    %{
      summary: Reducer.failure_summary(state),
      assignments: Enum.filter(assignments, &(&1.status in @failed_assignment_statuses)),
      runner_sessions: Enum.filter(sessions, &(&1.status in ["failed", "expired", "stale"])),
      stale_runners:
        count_in(state.runners, fn {_id, runner} -> Map.get(runner, :status) == "stale" end)
    }
  end

  defp reconciliation_projection(assignments) do
    items =
      assignments
      |> Enum.map(&assignment_reconciliation_item/1)
      |> Enum.reject(&is_nil/1)

    %{
      total: length(items),
      pending: Enum.count(items, &(&1.status in ["pending", "running", "progressed"])),
      succeeded: Enum.count(items, &(&1.status == "succeeded")),
      failed: Enum.count(items, &(&1.status in ["failed", "replay_mismatch"])),
      items: items
    }
  end

  defp assignment_reconciliation_item(%Assignment{} = assignment) do
    metadata = decode_json(assignment.metadata, %{})
    runner = Map.get(metadata, "devide_runner") || Map.get(metadata, :devide_runner)

    if is_map(runner) do
      %{
        assignment_id: assignment.assignment_id,
        action_id: assignment.action_id,
        workspace_id: assignment.workspace_id,
        runner_id: assignment.runner_id,
        session_id: assignment.session_id,
        devide_assignment_id: text_field(runner, "assignment_id"),
        devide_workspace_id: text_field(runner, "workspace_id"),
        status: reconciliation_status(assignment, runner),
        replay_event_id: text_field(runner, "replay_event_id"),
        failure_class: text_field(runner, "failure_class"),
        last_reconciled_at: text_field(runner, "last_reconciled_at")
      }
    end
  end

  defp assignment_reconciliation_item(_assignment), do: nil

  defp reconciliation_status(%Assignment{status: "completed"}, _runner), do: "succeeded"

  defp reconciliation_status(%Assignment{status: status}, _runner)
       when status in @failed_assignment_statuses, do: status

  defp reconciliation_status(_assignment, runner) do
    text_field(runner, "status") || text_field(runner, "state") || "pending"
  end

  defp assignment_replay_state(%Assignment{} = assignment) do
    metadata = decode_json(assignment.metadata, %{})
    runner = Map.get(metadata, "devide_runner") || %{}

    %{
      status: reconciliation_status(assignment, runner),
      devide_assignment_id: text_field(runner, "assignment_id"),
      replay_event_id: text_field(runner, "replay_event_id"),
      failure_class: text_field(runner, "failure_class"),
      last_reconciled_at: text_field(runner, "last_reconciled_at"),
      metadata: runner
    }
  end

  defp assignment_failure_chain(%Assignment{} = assignment) do
    reports =
      DelegatedExecution.reports_for_assignment(assignment.assignment_id)
      |> Enum.filter(
        &(&1.status in @failed_assignment_statuses or
            &1.kind in ["assignment.failed", "assignment.expired"])
      )
      |> Enum.map(&assignment_report_summary/1)

    replay = assignment_replay_state(assignment)

    if replay.failure_class do
      [%{kind: "replay", status: replay.status, failure_class: replay.failure_class} | reports]
    else
      reports
    end
  end

  defp assignment_rows(limit) do
    Assignment
    |> order_by([assignment], desc: assignment.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp assignment_id_to_row(%{assignment_id: assignment_id}) do
    Repo.get_by(Assignment, assignment_id: assignment_id)
  end

  defp runner_summary(runner_id, now) do
    DelegatedExecution.list_runners(status: "all", limit: 1_000, now: now)
    |> Enum.find(&(&1.runner_id == runner_id))
  end

  defp runner_reports(runner_id, limit) do
    RunnerReport
    |> where([report], report.runner_id == ^runner_id)
    |> order_by([report], desc: report.inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  defp runner_reports_for_assignment(assignment_id, limit) do
    RunnerReport
    |> where([report], report.assignment_id == ^assignment_id)
    |> order_by([report], desc: report.inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  defp recent_operational_events(opts) do
    limit = Keyword.get(opts, :limit, 25)

    Event
    |> maybe_filter_recent_workspace(Keyword.get(opts, :workspace_id))
    |> maybe_filter_recent_entity(Keyword.get(opts, :entity_type), Keyword.get(opts, :entity_id))
    |> maybe_filter_recent_action(Keyword.get(opts, :action_id))
    |> order_by([event], desc: event.id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
    |> Enum.map(&event_summary/1)
  end

  defp event_summary(%Event{} = event) do
    %{
      event_id: event.event_id,
      correlation_id: event.correlation_id,
      source: event.source,
      kind: event.kind,
      entity_type: event.entity_type,
      entity_id: event.entity_id,
      workspace_id: event.workspace_id,
      approval_id: event.approval_id,
      action_id: event.action_id,
      lease_id: event.lease_id,
      owner: event.owner,
      severity: event.severity,
      summary: event.summary,
      payload: OperationalEvents.decode_payload(event),
      inserted_at: event.inserted_at
    }
  end

  defp assignment_detail(%Assignment{} = assignment, now) do
    assignment
    |> assignment_to_summary(now)
    |> Map.put(:metadata, decode_json(assignment.metadata, %{}))
    |> Map.put(:timing, %{
      claimed_at: assignment.claimed_at,
      started_at: assignment.started_at,
      last_report_at: assignment.last_report_at,
      completed_at: assignment.completed_at,
      expires_at: assignment.expires_at
    })
  end

  defp assignment_to_summary(%Assignment{} = assignment, now) do
    DelegatedExecution.list_assignments(status: "all", limit: 1_000, now: now)
    |> Enum.find(&(&1.assignment_id == assignment.assignment_id))
    |> case do
      nil ->
        %{
          assignment_id: assignment.assignment_id,
          action_id: assignment.action_id,
          approval_id: assignment.approval_id,
          workspace_id: assignment.workspace_id,
          safe_action_kind: assignment.safe_action_kind,
          status: assignment.status,
          claimant_agent_id: assignment.claimant_agent_id,
          runner_id: assignment.runner_id,
          session_id: assignment.session_id,
          lease_id: assignment.lease_id,
          correlation_id: assignment.correlation_id,
          required_capabilities: decode_json(assignment.required_capabilities, []),
          summary: assignment.summary,
          stale: false,
          next: "jx assignments show #{assignment.assignment_id}"
        }

      summary ->
        summary
    end
  end

  defp assignment_report_summary(%Report{} = report) do
    %{
      report_id: report.report_id,
      assignment_id: report.assignment_id,
      agent_id: report.agent_id,
      action_id: report.action_id,
      workspace_id: report.workspace_id,
      kind: report.kind,
      status: report.status,
      correlation_id: report.correlation_id,
      summary: report.summary,
      payload: decode_json(report.payload, %{}),
      inserted_at: report.inserted_at
    }
  end

  defp runner_report_summary(%RunnerReport{} = report) do
    %{
      report_id: report.report_id,
      session_id: report.session_id,
      runner_id: report.runner_id,
      agent_id: report.agent_id,
      assignment_id: report.assignment_id,
      workspace_id: report.workspace_id,
      action_id: report.action_id,
      kind: report.kind,
      status: report.status,
      correlation_id: report.correlation_id,
      summary: report.summary,
      payload: decode_json(report.payload, %{}),
      inserted_at: report.inserted_at
    }
  end

  defp safe_action_summary(%OrchestrationAction{} = action, payload) do
    action_summary(action)
    |> Map.merge(%{
      safe_action: action.action,
      ref: action.ref,
      outcome_reason: action.outcome_reason,
      payload: payload
    })
  end

  defp approval_detail(nil, _now), do: nil
  defp approval_detail("", _now), do: nil

  defp approval_detail(approval_id, now) do
    case Repo.get_by(Approval, approval_id: approval_id) do
      nil -> nil
      approval -> approval_summary(approval, now, @default_stale_after_seconds)
    end
  end

  defp execution_event_summary(event) do
    %{
      event_id: Map.get(event, :event_id),
      action_id: Map.get(event, :action_id),
      kind: Map.get(event, :kind),
      status: Map.get(event, :outcome),
      summary: Map.get(event, :reason),
      payload: decode_json(Map.get(event, :payload), %{}),
      inserted_at: Map.get(event, :inserted_at)
    }
  end

  defp count_statuses(items) do
    items
    |> Enum.group_by(& &1.status)
    |> Map.new(fn {status, status_items} -> {status, length(status_items)} end)
  end

  defp count_in(map, fun) when is_map(map), do: Enum.count(map, fun)

  defp maybe_filter_recent_workspace(query, nil), do: query

  defp maybe_filter_recent_workspace(query, workspace_id),
    do: where(query, [event], event.workspace_id == ^workspace_id)

  defp maybe_filter_recent_entity(query, nil, _entity_id), do: query

  defp maybe_filter_recent_entity(query, entity_type, nil),
    do: where(query, [event], event.entity_type == ^entity_type)

  defp maybe_filter_recent_entity(query, entity_type, entity_id),
    do: where(query, [event], event.entity_type == ^entity_type and event.entity_id == ^entity_id)

  defp maybe_filter_recent_action(query, nil), do: query

  defp maybe_filter_recent_action(query, action_id),
    do: where(query, [event], event.action_id == ^action_id)

  defp workspace_items(now, stale_after_seconds) do
    State.list_snapshots(limit: 500)
    |> Enum.flat_map(fn snapshot ->
      health = workspace_health(snapshot, now, stale_after_seconds)
      stale_item? = health.freshness == "stale"
      attention_item? = snapshot.status in ["blocked", "needs_review", "unknown"]

      if stale_item? or attention_item? do
        [
          %{
            type: "workspace",
            id: snapshot.workspace_id,
            workspace_id: snapshot.workspace_id,
            approval_id: "",
            action_id: "",
            lease_id: "",
            status: snapshot.status,
            risk: workspace_risk(snapshot, health),
            reason: workspace_reason(snapshot, health),
            freshness: health.freshness,
            urgency: workspace_urgency(snapshot, health),
            urgency_rank: urgency_rank(workspace_urgency(snapshot, health)),
            owner: lease_owner("workspace", snapshot.workspace_id),
            summary: "workspace #{snapshot.workspace_id} #{snapshot.status}",
            evidence_at: snapshot.last_observed_at,
            updated_at: snapshot.updated_at,
            next: "jx queue workspace #{snapshot.workspace_id}"
          }
        ]
      else
        []
      end
    end)
  end

  defp blocker_items(now, stale_after_seconds) do
    Event
    |> where([event], event.kind == "agent.report.blocker" or event.severity == "critical")
    |> order_by([event], desc: event.id)
    |> limit(100)
    |> Repo.all()
    |> Enum.map(&blocker_queue_item(&1, now, stale_after_seconds))
  end

  defp blocker_queue_item(%Event{} = event, now, stale_after_seconds) do
    payload = OperationalEvents.decode_payload(event)
    evidence_at = event.inserted_at

    %{
      type: "blocker",
      id: event.event_id,
      workspace_id: event.workspace_id,
      approval_id: event.approval_id,
      action_id: event.action_id,
      lease_id: event.lease_id,
      status: "open",
      risk: "blocked",
      reason: event.kind,
      freshness: freshness(evidence_at, now, stale_after_seconds),
      urgency: event.severity,
      urgency_rank: urgency_rank(event.severity),
      owner: event.owner,
      summary: blocker_summary(event, payload),
      evidence_at: evidence_at,
      updated_at: event.inserted_at,
      next: blocker_next(event, payload)
    }
  end

  defp blocker_summary(%Event{} = event, payload) do
    text_field(payload, "text") || event.summary
  end

  defp blocker_next(%Event{} = event, payload) do
    cond do
      text_field(payload, "next_command") ->
        text_field(payload, "next_command")

      text_field(payload, "task_id") ->
        "jx task send #{text_field(payload, "task_id")} \"<next step>\""

      event.entity_type != "" and event.entity_id != "" ->
        "jx timeline #{timeline_scope(event.entity_type)} #{event.entity_id}"

      true ->
        "jx timeline recent"
    end
  end

  defp timeline_scope("runner_session"), do: "session"
  defp timeline_scope(scope), do: scope

  defp approval_items(now, stale_after_seconds) do
    Approvals.list(status: "active", limit: 500)
    |> Enum.map(&approval_queue_item(&1, now, stale_after_seconds))
  end

  defp approval_queue_item(%Approval{} = approval, now, stale_after_seconds) do
    summary = approval_summary(approval, now, stale_after_seconds)

    %{
      type: "approval",
      id: approval.approval_id,
      workspace_id: approval.workspace_id,
      approval_id: approval.approval_id,
      action_id: "",
      lease_id: "",
      status: approval.status,
      risk: approval_risk(approval),
      reason: approval.kind,
      freshness: summary.freshness,
      urgency: approval.severity,
      urgency_rank: urgency_rank(approval.severity),
      owner: lease_owner("approval", approval.approval_id),
      summary: approval.summary,
      evidence_at: summary.evidence_at,
      updated_at: approval.updated_at,
      next: "jx approvals show #{approval.approval_id}"
    }
  end

  defp action_items(now, stale_after_seconds) do
    (OrchestrationActions.list_actions(status: "planned", limit: 500) ++
       OrchestrationActions.list_actions(status: "queued", limit: 500) ++
       OrchestrationActions.list_actions(status: "error", limit: 500))
    |> Enum.map(&action_queue_item(&1, now, stale_after_seconds))
  end

  defp action_queue_item(%OrchestrationAction{} = action, now, stale_after_seconds) do
    payload = decode_json(action.payload, %{})
    evidence_at = parse_time(payload["expires_at"]) || action.updated_at
    freshness = freshness(evidence_at, now, stale_after_seconds)

    %{
      type: "action",
      id: action.action_id,
      workspace_id: text_field(payload, "workspace_id") || "",
      approval_id: action.ref,
      action_id: action.action_id,
      lease_id: "",
      status: action.status,
      risk: if(action.status == "error", do: "blocked", else: "awaiting_operator"),
      reason: action_reason(action, freshness),
      freshness: freshness,
      urgency: if(action.status == "error", do: "warning", else: "notice"),
      urgency_rank:
        if(action.status == "error", do: urgency_rank("warning"), else: urgency_rank("notice")),
      owner: lease_owner("action", action.action_id),
      summary: action.result_summary,
      evidence_at: evidence_at,
      updated_at: action.updated_at,
      next: "jx actions show #{action.action_id}"
    }
  end

  defp lease_items(now) do
    OperationalLeases.list(status: "all", limit: 500, now: now)
    |> Enum.filter(&(&1.status in ["active", "expired"]))
    |> Enum.map(fn lease ->
      stale? = lease.status == "expired" or DateTime.compare(lease.expires_at, now) != :gt

      %{
        type: "lease",
        id: lease.lease_id,
        workspace_id: "",
        approval_id: if(lease.resource_type == "approval", do: lease.resource_id, else: ""),
        action_id: if(lease.resource_type == "action", do: lease.resource_id, else: ""),
        lease_id: lease.lease_id,
        status: lease.status,
        risk: if(stale?, do: "stale", else: "awaiting_operator"),
        reason: if(stale?, do: "stale_lease", else: "active_lease"),
        freshness: if(stale?, do: "stale", else: "fresh"),
        urgency: if(stale?, do: "warning", else: "notice"),
        urgency_rank: if(stale?, do: urgency_rank("warning"), else: urgency_rank("notice")),
        owner: lease.owner,
        summary: "#{lease.resource_type} #{lease.resource_id} claimed by #{lease.owner}",
        evidence_at: lease.expires_at,
        updated_at: lease.updated_at,
        next: "jx leases ls --owner #{lease.owner}"
      }
    end)
  end

  defp agent_items(_now) do
    DelegatedExecution.list_agents(status: "all", limit: 500)
    |> Enum.flat_map(fn agent ->
      attention? = agent.status in ["stale", "busy"]

      if attention? do
        [
          %{
            type: "agent",
            id: agent.agent_id,
            workspace_id: "",
            approval_id: "",
            action_id: "",
            lease_id: "",
            status: agent.status,
            risk: if(agent.status == "stale", do: "stale", else: "awaiting_operator"),
            reason: if(agent.status == "stale", do: "stale_agent", else: "busy_agent"),
            freshness: if(agent.status == "stale", do: "stale", else: "fresh"),
            urgency: if(agent.status == "stale", do: "warning", else: "notice"),
            urgency_rank:
              if(agent.status == "stale",
                do: urgency_rank("warning"),
                else: urgency_rank("notice")
              ),
            owner: agent.agent_id,
            summary:
              "agent #{agent.agent_id} #{agent.status} assignments=#{agent.active_assignments}",
            evidence_at: agent.last_heartbeat_at,
            updated_at: agent.last_heartbeat_at,
            next: "jx agents ls --status #{agent.status}"
          }
        ]
      else
        []
      end
    end)
  end

  defp runner_items(_now) do
    DelegatedExecution.list_runners(status: "all", limit: 500)
    |> Enum.flat_map(fn runner ->
      attention? = runner.status in ["stale", "busy"]

      if attention? do
        [
          %{
            type: "runner",
            id: runner.runner_id,
            workspace_id: "",
            approval_id: "",
            action_id: "",
            lease_id: "",
            status: runner.status,
            risk: if(runner.status == "stale", do: "stale", else: "awaiting_operator"),
            reason: if(runner.status == "stale", do: "stale_runner", else: "busy_runner"),
            freshness: if(runner.status == "stale", do: "stale", else: "fresh"),
            urgency: if(runner.status == "stale", do: "warning", else: "notice"),
            urgency_rank:
              if(runner.status == "stale",
                do: urgency_rank("warning"),
                else: urgency_rank("notice")
              ),
            owner: runner.runner_id,
            summary:
              "runner #{runner.runner_id} #{runner.status} sessions=#{runner.active_sessions}",
            evidence_at: runner.last_heartbeat_at,
            updated_at: runner.last_heartbeat_at,
            next: "jx runners show #{runner.runner_id}"
          }
        ]
      else
        []
      end
    end)
  end

  defp assignment_items(_now) do
    DelegatedExecution.list_assignments(status: "all", limit: 500)
    |> Enum.flat_map(fn assignment ->
      attention? =
        assignment.status in ["created", "claimed", "started", "progressed", "failed", "expired"]

      if attention? do
        [
          %{
            type: "assignment",
            id: assignment.assignment_id,
            workspace_id: assignment.workspace_id,
            approval_id: assignment.approval_id,
            action_id: assignment.action_id,
            lease_id: assignment.lease_id,
            status: assignment.status,
            risk: assignment_risk(assignment),
            reason: assignment_reason(assignment),
            freshness: if(assignment.stale, do: "stale", else: "fresh"),
            urgency: assignment_urgency(assignment),
            urgency_rank: urgency_rank(assignment_urgency(assignment)),
            owner: assignment.claimant_agent_id,
            summary: assignment.summary,
            evidence_at: nil,
            updated_at: nil,
            next: assignment.next
          }
        ]
      else
        []
      end
    end)
  end

  defp runner_session_items(_now) do
    DelegatedExecution.list_runner_sessions(status: "all", limit: 500)
    |> Enum.flat_map(fn session ->
      attention? =
        session.status in [
          "created",
          "claimed",
          "running",
          "progressed",
          "failed",
          "expired",
          "stale"
        ]

      if attention? do
        [
          %{
            type: "session",
            id: session.session_id,
            workspace_id: session.workspace_id,
            approval_id: session.approval_id,
            action_id: session.action_id,
            lease_id: "",
            status: session.status,
            risk: runner_session_risk(session),
            reason: runner_session_reason(session),
            freshness: if(session.stale, do: "stale", else: "fresh"),
            urgency: runner_session_urgency(session),
            urgency_rank: urgency_rank(runner_session_urgency(session)),
            owner: session.runner_id,
            summary: session.last_summary,
            evidence_at: session.heartbeat_at,
            updated_at: session.heartbeat_at,
            next: session.next
          }
        ]
      else
        []
      end
    end)
  end

  defp approval_summary(%Approval{} = approval, now, stale_after_seconds) do
    evidence = Approvals.detail(approval).evidence
    workspace = Map.get(evidence, :workspace, %{})
    evidence_at = Map.get(workspace, :last_observed_at)

    %{
      approval_id: approval.approval_id,
      workspace_id: approval.workspace_id,
      kind: approval.kind,
      severity: approval.severity,
      status: approval.status,
      target_ref: approval.target_ref,
      summary: approval.summary,
      freshness: freshness(evidence_at, now, stale_after_seconds),
      evidence_source: Map.get(evidence, :source, "missing"),
      evidence_at: evidence_at,
      owner: lease_owner("approval", approval.approval_id)
    }
  end

  defp action_summary(%OrchestrationAction{} = action) do
    %{
      action_id: action.action_id,
      approval_id: action.ref,
      action: action.action,
      status: action.status,
      outcome: action.outcome,
      target: action.target,
      summary: action.result_summary,
      owner: lease_owner("action", action.action_id),
      updated_at: action.updated_at
    }
  end

  defp lease_summary(%Lease{} = lease) do
    %{
      lease_id: lease.lease_id,
      resource_type: lease.resource_type,
      resource_id: lease.resource_id,
      owner: lease.owner,
      status: lease.status,
      expires_at: lease.expires_at
    }
  end

  defp workspace_health(nil, _now, _stale_after_seconds) do
    %{status: "missing", freshness: "unknown", risk: "stale", evidence_at: nil}
  end

  defp workspace_health(%WorkspaceSnapshot{} = snapshot, now, stale_after_seconds) do
    freshness = freshness(snapshot.last_observed_at, now, stale_after_seconds)

    %{
      status: snapshot.status,
      freshness: freshness,
      risk: workspace_risk(snapshot, %{freshness: freshness}),
      db_isolation: snapshot.db_isolation,
      attention_flags: decode_json(snapshot.attention_flags, []),
      evidence_at: snapshot.last_observed_at,
      changed_at: snapshot.last_changed_at
    }
  end

  defp workspace_risk(_snapshot, %{freshness: "stale"}), do: "stale"
  defp workspace_risk(%WorkspaceSnapshot{status: "blocked"}, _health), do: "blocked"
  defp workspace_risk(%WorkspaceSnapshot{status: "needs_review"}, _health), do: "risky"
  defp workspace_risk(%WorkspaceSnapshot{status: "unknown"}, _health), do: "stale"
  defp workspace_risk(_snapshot, _health), do: "healthy"

  defp workspace_reason(_snapshot, %{freshness: "stale"}), do: "stale_evidence"
  defp workspace_reason(%WorkspaceSnapshot{status: "blocked"}, _health), do: "blocked_workspace"

  defp workspace_reason(%WorkspaceSnapshot{status: "needs_review"}, _health),
    do: "risky_workspace"

  defp workspace_reason(%WorkspaceSnapshot{status: "unknown"}, _health), do: "unknown_workspace"
  defp workspace_reason(_snapshot, _health), do: "workspace_attention"

  defp workspace_urgency(%WorkspaceSnapshot{status: "blocked"}, _health), do: "critical"
  defp workspace_urgency(_snapshot, %{freshness: "stale"}), do: "warning"
  defp workspace_urgency(%WorkspaceSnapshot{status: "needs_review"}, _health), do: "warning"
  defp workspace_urgency(_snapshot, _health), do: "notice"

  defp approval_risk(%Approval{kind: kind}) when kind in ["unsafe_db", "policy_blocked"],
    do: "blocked"

  defp approval_risk(%Approval{kind: "proposal_conflict"}), do: "risky"
  defp approval_risk(%Approval{kind: "failed_run"}), do: "awaiting_operator"
  defp approval_risk(_approval), do: "awaiting_operator"

  defp assignment_risk(%{status: "failed"}), do: "blocked"
  defp assignment_risk(%{status: "expired"}), do: "stale"
  defp assignment_risk(%{stale: true}), do: "stale"
  defp assignment_risk(_assignment), do: "awaiting_operator"

  defp assignment_reason(%{status: "failed"}), do: "failed_assignment"
  defp assignment_reason(%{status: "expired"}), do: "expired_assignment"
  defp assignment_reason(%{stale: true}), do: "stale_assignment"
  defp assignment_reason(%{status: "created"}), do: "awaiting_agent_claim"
  defp assignment_reason(%{status: status}), do: "assignment_#{status}"

  defp assignment_urgency(%{status: "failed"}), do: "warning"
  defp assignment_urgency(%{status: "expired"}), do: "warning"
  defp assignment_urgency(%{stale: true}), do: "warning"
  defp assignment_urgency(_assignment), do: "notice"

  defp runner_session_risk(%{status: "failed"}), do: "blocked"
  defp runner_session_risk(%{status: "expired"}), do: "stale"
  defp runner_session_risk(%{status: "stale"}), do: "stale"
  defp runner_session_risk(%{stale: true}), do: "stale"
  defp runner_session_risk(_session), do: "awaiting_operator"

  defp runner_session_reason(%{status: "failed"}), do: "failed_runner_session"
  defp runner_session_reason(%{status: "expired"}), do: "expired_runner_session"
  defp runner_session_reason(%{status: "stale"}), do: "stale_runner_session"
  defp runner_session_reason(%{stale: true}), do: "stale_runner_session"
  defp runner_session_reason(%{status: status}), do: "runner_session_#{status}"

  defp runner_session_urgency(%{status: "failed"}), do: "warning"
  defp runner_session_urgency(%{status: "expired"}), do: "warning"
  defp runner_session_urgency(%{status: "stale"}), do: "warning"
  defp runner_session_urgency(%{stale: true}), do: "warning"
  defp runner_session_urgency(_session), do: "notice"

  defp action_reason(%OrchestrationAction{status: "error", outcome_reason: reason}, _freshness)
       when reason not in [nil, ""],
       do: reason

  defp action_reason(%OrchestrationAction{status: "error"}, _freshness), do: "failed_execution"
  defp action_reason(_action, "stale"), do: "stale_action_evidence"
  defp action_reason(_action, _freshness), do: "awaiting_operator"

  defp freshness(nil, _now, _stale_after_seconds), do: "unknown"

  defp freshness(%DateTime{} = observed_at, now, stale_after_seconds) do
    if DateTime.diff(now, observed_at, :second) > stale_after_seconds, do: "stale", else: "fresh"
  end

  defp freshness(_observed_at, _now, _stale_after_seconds), do: "unknown"

  defp lease_owner(resource_type, resource_id) do
    case OperationalLeases.active(resource_type, resource_id) do
      %Lease{owner: owner} -> owner
      _other -> ""
    end
  end

  defp leases_for_workspace(workspace_id) do
    approval_ids =
      Approvals.list(status: "all", workspace_id: workspace_id, limit: 500)
      |> Enum.map(& &1.approval_id)

    action_ids =
      actions_for_workspace(workspace_id)
      |> Enum.map(& &1.action_id)

    OperationalLeases.list(status: "all", limit: 500)
    |> Enum.filter(fn lease ->
      (lease.resource_type == "workspace" and lease.resource_id == workspace_id) or
        (lease.resource_type == "approval" and lease.resource_id in approval_ids) or
        (lease.resource_type == "action" and lease.resource_id in action_ids)
    end)
  end

  defp actions_for_workspace(workspace_id) do
    OrchestrationActions.list_actions(limit: 500)
    |> Enum.filter(fn action ->
      payload = decode_json(action.payload, %{})
      text_field(payload, "workspace_id") == workspace_id
    end)
  end

  defp filter_items(items, opts) do
    items
    |> filter_eq(:type, Keyword.get(opts, :kind))
    |> filter_eq(:workspace_id, Keyword.get(opts, :workspace_id))
    |> filter_eq(:owner, Keyword.get(opts, :owner))
    |> filter_eq(:risk, Keyword.get(opts, :risk))
    |> filter_eq(:freshness, Keyword.get(opts, :freshness))
  end

  defp filter_eq(items, _field, nil), do: items

  defp filter_eq(items, field, value) do
    Enum.filter(items, &(Map.get(&1, field) == value))
  end

  defp sort_items(items, "freshness") do
    Enum.sort_by(items, &{freshness_rank(&1.freshness), -&1.urgency_rank, &1.id})
  end

  defp sort_items(items, "owner"), do: Enum.sort_by(items, &{&1.owner, -&1.urgency_rank, &1.id})
  defp sort_items(items, "risk"), do: Enum.sort_by(items, &{&1.risk, -&1.urgency_rank, &1.id})

  defp sort_items(items, _sort) do
    Enum.sort_by(items, &{-&1.urgency_rank, freshness_rank(&1.freshness), &1.id})
  end

  defp urgency_rank("critical"), do: 4
  defp urgency_rank("warning"), do: 3
  defp urgency_rank("notice"), do: 2
  defp urgency_rank("info"), do: 1
  defp urgency_rank(_urgency), do: 0

  defp freshness_rank("stale"), do: 0
  defp freshness_rank("unknown"), do: 1
  defp freshness_rank("fresh"), do: 2
  defp freshness_rank(_freshness), do: 3

  defp decode_json(text, fallback) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> fallback
    end
  end

  defp decode_json(_text, fallback), do: fallback

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _offset} -> time
      _other -> nil
    end
  end

  defp parse_time(_value), do: nil

  defp text_field(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when value in [nil, ""] -> nil
      value -> to_string(value)
    end
  end

  defp text_field(_map, _key), do: nil
end
