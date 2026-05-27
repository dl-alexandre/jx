defmodule JX.OperationalControlPlaneTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureIO

  alias JX.Approvals.Approval
  alias JX.CLI
  alias JX.DevIDE.{Client, WorkspaceSnapshot}
  alias JX.MonitorEvents.Event, as: MonitorEvent
  alias JX.Notifications.Notification
  alias JX.OperationalEvents
  alias JX.OperationalEvents.Event, as: OperationalEvent
  alias JX.OperationalLeases
  alias JX.OperationalLeases.Lease
  alias JX.OrchestrationActions.OrchestrationAction
  alias JX.Repo
  alias JX.SafeActions
  alias JX.SafeActions.ExecutionEvent
  alias JX.Workspace

  @token "control-plane-token"

  setup do
    cleanup_state()
    :ok
  end

  test "fleet queue, leases, safe actions, and timelines compose across workspaces" do
    now = DateTime.utc_now()

    alpha =
      insert_snapshot!("ws-alpha",
        status: "blocked",
        db_isolation: "local",
        attention_flags: ["active_run:failed"],
        observed_at: now
      )

    beta =
      insert_snapshot!("ws-beta",
        status: "needs_review",
        db_isolation: "ephemeral",
        attention_flags: ["proposal:conflict"],
        observed_at: now
      )

    stale =
      insert_snapshot!("ws-stale",
        status: "healthy",
        db_isolation: "local",
        attention_flags: [],
        observed_at: DateTime.add(now, -1_200, :second)
      )

    {:ok, _event} = OperationalEvents.record_workspace_snapshot(alpha, "devide.snapshot.changed")
    {:ok, _event} = OperationalEvents.record_workspace_snapshot(beta, "devide.snapshot.changed")
    {:ok, _event} = OperationalEvents.record_workspace_snapshot(stale, "devide.snapshot.changed")

    alpha_approval =
      insert_approval!("apr-alpha",
        workspace_id: "ws-alpha",
        kind: "failed_run",
        command_id: "test"
      )

    beta_approval =
      insert_approval!("apr-beta",
        workspace_id: "ws-beta",
        kind: "proposal_conflict",
        command_id: "proposal-1",
        target_ref: "proposal-1"
      )

    {:ok, _event} = OperationalEvents.record_approval(alpha_approval, "approval.created")
    {:ok, _event} = OperationalEvents.record_approval(beta_approval, "approval.created")

    assert {:ok, approval_lease} =
             OperationalLeases.acquire("approval", alpha_approval.approval_id, "alice",
               ttl_seconds: 900,
               correlation_id: "corr-lease-alpha",
               metadata: %{workspace_id: "ws-alpha"}
             )

    assert {:error, {:lease_conflict, %Lease{owner: "alice"}}} =
             OperationalLeases.acquire("approval", alpha_approval.approval_id, "bob")

    assert {:error, {:lease_conflict, %Lease{owner: "alice"}}} =
             SafeActions.propose(alpha_approval.approval_id, owner: "bob")

    assert {:ok, proposed} = SafeActions.propose(alpha_approval.approval_id, owner: "alice")
    action_id = proposed.action.action_id
    action_payload = Jason.decode!(proposed.action.payload)
    assert action_payload["correlation_id"] == approval_lease.correlation_id

    assert {:ok, _action_lease} =
             OperationalLeases.acquire("action", action_id, "alice",
               ttl_seconds: 900,
               correlation_id: approval_lease.correlation_id,
               metadata: %{workspace_id: "ws-alpha", approval_id: alpha_approval.approval_id}
             )

    assert {:error, {:lease_conflict, %Lease{owner: "alice"}}} =
             SafeActions.dry_run(action_id, owner: "bob")

    assert {:ok, dry_run} = SafeActions.dry_run(action_id, owner: "alice")
    assert dry_run.executed == false

    queue = Workspace.operational_queue(sort: "urgency", stale_after_seconds: 600, limit: 50)

    assert Enum.any?(
             queue.items,
             &match?(%{type: "workspace", id: "ws-stale", risk: "stale"}, &1)
           )

    assert Enum.any?(queue.items, &match?(%{type: "approval", id: "apr-beta", risk: "risky"}, &1))

    assert Enum.any?(
             queue.items,
             &match?(%{type: "approval", id: "apr-alpha", owner: "alice"}, &1)
           )

    assert Enum.any?(queue.items, &match?(%{type: "action", id: ^action_id, owner: "alice"}, &1))

    owner_queue = Workspace.operational_queue(owner: "alice", limit: 50)
    assert Enum.all?(owner_queue.items, &(&1.owner == "alice"))
    assert Enum.any?(owner_queue.items, &(&1.id == alpha_approval.approval_id))
    assert Enum.any?(owner_queue.items, &(&1.id == action_id))

    queue_output =
      capture_io(fn ->
        assert :ok = CLI.run(["queue", "ls", "--owner", "alice", "--sort", "urgency"])
      end)

    assert queue_output =~ "attention queue"
    assert queue_output =~ alpha_approval.approval_id
    assert queue_output =~ action_id
    assert queue_output =~ "jx approvals show #{alpha_approval.approval_id}"

    workspace_output =
      capture_io(fn ->
        assert :ok = CLI.run(["queue", "workspace", "ws-alpha"])
      end)

    assert workspace_output =~ "workspace queue ws-alpha"
    assert workspace_output =~ "approvals"
    assert workspace_output =~ "leases"
    assert workspace_output =~ "jx timeline workspace ws-alpha"

    bypass = Bypass.open()
    client = Client.new(base_url: "http://localhost:#{bypass.port}", api_token: @token)

    Bypass.expect_once(bypass, "POST", "/api/workspaces/ws-alpha/runs", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> @token]

      assert Plug.Conn.get_req_header(conn, "x-jx-correlation-id") == [
               approval_lease.correlation_id
             ]

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"command_id" => "test"}

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        201,
        Jason.encode!(%{
          id: "run-alpha",
          workspace_id: "ws-alpha",
          command_id: "test",
          status: "running"
        })
      )
    end)

    assert {:ok, executed} =
             SafeActions.execute(action_id, confirm: true, owner: "alice", client: client)

    assert executed.run["id"] == "run-alpha"

    assert Repo.get_by!(Approval, approval_id: alpha_approval.approval_id).status ==
             "acknowledged"

    assert {:error, {:action_already_executed, ^action_id}} =
             SafeActions.execute(action_id, confirm: true, owner: "alice", client: client)

    action_events = operational_events(action_id: action_id)
    action_kinds = Enum.map(action_events, & &1.kind)
    assert "safe_action.proposed" in action_kinds
    assert "lease.acquired" in action_kinds
    assert "safe_action.executed" in action_kinds
    assert Enum.all?(action_events, &(&1.correlation_id == approval_lease.correlation_id))

    approval_timeline = Workspace.operational_timeline("approval", alpha_approval.approval_id)
    approval_kinds = Enum.map(approval_timeline.events, & &1.kind)
    assert "approval.created" in approval_kinds
    assert "lease.acquired" in approval_kinds
    assert "safe_action.proposed" in approval_kinds
    assert "safe_action.executed" in approval_kinds
    assert "approval.acknowledged" in approval_kinds

    rebuilt = Workspace.operational_rebuilt_state(limit: 1_000)
    assert rebuilt.state.actions[action_id].status == "executed"
    assert rebuilt.state.approvals[alpha_approval.approval_id].status == "acknowledged"
    assert map_size(rebuilt.state.timelines) > 0

    timeline_output =
      capture_io(fn ->
        assert :ok = CLI.run(["timeline", "approval", alpha_approval.approval_id])
      end)

    assert timeline_output =~ "timeline approval #{alpha_approval.approval_id}"
    assert timeline_output =~ approval_lease.correlation_id
    assert timeline_output =~ "safe_action.executed"
  end

  test "agent blocker reports surface as queue blockers" do
    {:ok, event} =
      Workspace.record_agent_report(%{
        session_id: "session-1",
        task_id: "task-1",
        agent_id: "codex-1",
        kind: "blocker",
        text: "CSS lint failed on dashboard styles"
      })

    queue = Workspace.operational_queue(kind: "blocker", limit: 10)

    assert [
             %{
               type: "blocker",
               id: event_id,
               risk: "blocked",
               owner: "codex-1",
               reason: "agent.report.blocker",
               summary: "CSS lint failed on dashboard styles",
               next: "jx task send task-1 \"<next step>\""
             }
           ] = queue.items

    assert event_id == event.event_id
  end

  test "lease expiration, release, and reassignment prevent stale ownership conflicts" do
    now = ~U[2026-05-09 20:00:00Z]

    assert {:ok, alice} =
             OperationalLeases.acquire("approval", "apr-expiring", "alice",
               now: now,
               ttl_seconds: 1
             )

    assert {:error, {:lease_conflict, %Lease{owner: "alice"}}} =
             OperationalLeases.acquire("approval", "apr-expiring", "bob", now: now)

    later = DateTime.add(now, 2, :second)

    assert [%Lease{lease_id: lease_id, status: "expired", owner: "alice"}] =
             OperationalLeases.expire_all(later)

    assert lease_id == alice.lease_id

    assert {:ok, bob} =
             OperationalLeases.acquire("approval", "apr-expiring", "bob",
               now: later,
               ttl_seconds: 300
             )

    assert {:ok, carol} =
             OperationalLeases.reassign("approval", "apr-expiring", "carol",
               now: DateTime.add(later, 1, :second),
               ttl_seconds: 300
             )

    assert carol.owner == "carol"
    assert Repo.get_by!(Lease, lease_id: bob.lease_id).status == "reassigned"

    assert {:error, {:lease_owner_mismatch, "carol"}} =
             OperationalLeases.release(carol.lease_id, "bob")

    assert {:ok, released} = OperationalLeases.release(carol.lease_id, "carol")
    assert released.status == "released"

    lease_queue = Workspace.operational_queue(kind: "lease", freshness: "stale", limit: 10)
    assert Enum.any?(lease_queue.items, &match?(%{id: ^lease_id, risk: "stale"}, &1))

    events = operational_events(lease_id: lease_id)
    assert Enum.map(events, & &1.kind) == ["lease.acquired", "lease.expired"]
  end

  defp insert_snapshot!(workspace_id, opts) do
    observed_at = Keyword.get(opts, :observed_at, DateTime.utc_now())
    status = Keyword.fetch!(opts, :status)
    db_isolation = Keyword.fetch!(opts, :db_isolation)
    attention_flags = Keyword.get(opts, :attention_flags, [])

    snapshot = %{
      id: workspace_id,
      name: "Workspace #{workspace_id}",
      status: status,
      lifecycle_status: "running",
      mode: "review",
      db_isolation: db_isolation,
      active_run: nil,
      latest_runs: [%{command_id: "test", status: "failed"}],
      proposal_risks: [],
      recent_blocks: [],
      attention_flags: attention_flags
    }

    %WorkspaceSnapshot{}
    |> WorkspaceSnapshot.changeset(%{
      workspace_id: workspace_id,
      name: "Workspace #{workspace_id}",
      lifecycle_status: "running",
      status: status,
      mode: "review",
      db_isolation: db_isolation,
      attention_flags: Jason.encode!(attention_flags),
      snapshot: Jason.encode!(snapshot),
      fingerprint: "fp-#{workspace_id}-#{System.unique_integer([:positive])}",
      source_url: "http://devide.local",
      last_observed_at: observed_at,
      last_changed_at: observed_at
    })
    |> Repo.insert!()
  end

  defp insert_approval!(approval_id, opts) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    kind = Keyword.fetch!(opts, :kind)
    command_id = Keyword.fetch!(opts, :command_id)
    target_ref = Keyword.get(opts, :target_ref, command_id)

    %Approval{}
    |> Approval.changeset(%{
      approval_id: approval_id,
      source: "devide",
      workspace_id: workspace_id,
      kind: kind,
      severity: "warning",
      target_ref: target_ref,
      summary: "DevIDE workspace #{workspace_id} has #{target_ref} #{kind}",
      status: "open",
      metadata:
        Jason.encode!(%{
          "run" => %{
            "id" => "run-#{command_id}",
            "command_id" => command_id,
            "status" => "failed"
          }
        }),
      dedupe_key: "dedupe-#{approval_id}"
    })
    |> Repo.insert!()
  end

  defp operational_events(filter) do
    OperationalEvent
    |> maybe_filter_action(Keyword.get(filter, :action_id))
    |> maybe_filter_lease(Keyword.get(filter, :lease_id))
    |> order_by([event], asc: event.id)
    |> Repo.all()
  end

  defp maybe_filter_action(query, nil), do: query

  defp maybe_filter_action(query, action_id),
    do: where(query, [event], event.action_id == ^action_id)

  defp maybe_filter_lease(query, nil), do: query
  defp maybe_filter_lease(query, lease_id), do: where(query, [event], event.lease_id == ^lease_id)

  defp cleanup_state do
    Repo.delete_all(OperationalEvent)
    Repo.delete_all(Lease)
    Repo.delete_all(ExecutionEvent)
    Repo.delete_all(OrchestrationAction)
    Repo.delete_all(Approval)
    Repo.delete_all(Notification)
    Repo.delete_all(MonitorEvent)
    Repo.delete_all(WorkspaceSnapshot)
  end
end
