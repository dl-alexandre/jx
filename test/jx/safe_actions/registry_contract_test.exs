defmodule JX.SafeActions.RegistryContractTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureIO

  alias JX.Approvals
  alias JX.Approvals.Approval
  alias JX.CLI
  alias JX.DevIDE.Client
  alias JX.DevIDE.WorkspaceSnapshot
  alias JX.HostCapacity.Observation
  alias JX.OperationalLeases.Lease
  alias JX.OrchestrationActions.OrchestrationAction
  alias JX.Repo
  alias JX.SafeActions
  alias JX.SafeActions.{Action, Audit, ExecutionEvent, Kind, Registry}
  alias JX.SafeActions.Kinds.{AcknowledgeApproval, RerunDevIDECommand}

  @registered_modules [RerunDevIDECommand, AcknowledgeApproval]
  @registered_kinds ~w(rerun_devide_command acknowledge_approval)

  setup do
    cleanup_state()
    :ok
  end

  test "registry is explicit and every registered kind implements the behaviour callbacks" do
    assert Registry.default_kind() == "rerun_devide_command"
    assert Registry.modules() == @registered_modules
    assert Registry.kinds() == @registered_kinds
    assert Action.kinds() == @registered_kinds

    callbacks = Kind.behaviour_info(:callbacks)

    for module <- Registry.modules() do
      assert {:ok, ^module} = Registry.fetch(module.kind())

      for {name, arity} <- callbacks do
        assert function_exported?(module, name, arity),
               "#{inspect(module)} missing #{name}/#{arity}"
      end
    end
  end

  test "registered kinds consistently propose authorize dry-run expose evidence and guidance" do
    for module <- Registry.modules() do
      cleanup_state()
      approval = seed_kind!(module)

      assert {:ok, proposed} = SafeActions.propose(approval.approval_id, kind: module.kind())
      safe_action = action_from_result(proposed.safe_action)

      assert proposed.action.action == module.kind()
      assert proposed.action.source == "approval"
      assert proposed.action.status == "planned"
      assert proposed.action.target == module.target(safe_action)
      assert proposed.would_do == module.would_do(safe_action)
      assert Action.to_decision(safe_action).contract == module.contract(safe_action)

      payload = Jason.decode!(proposed.action.payload)
      assert_expected_fields(module.expected_fields(safe_action), payload)

      assert {:ok, authorized, _evidence} =
               module.authorize(
                 proposed.action,
                 Repo.get_by!(Approval, approval_id: approval.approval_id),
                 contract_context()
               )

      assert authorized.kind == safe_action.kind
      assert authorized.approval_id == safe_action.approval_id
      assert authorized.workspace_id == safe_action.workspace_id

      assert {:ok, dry_run} = SafeActions.dry_run(proposed.action.action_id)
      assert dry_run.mode == "dry_run"
      assert dry_run.executed == false
      assert dry_run.would_do == module.would_do(safe_action)

      assert %ExecutionEvent{kind: "dry_run_viewed"} =
               Repo.get_by!(ExecutionEvent,
                 action_id: proposed.action.action_id,
                 kind: "dry_run_viewed"
               )

      assert module.recovery_guidance(proposed.action, [], "confirmation_required") =~ "--confirm"

      assert map_size(module.audit_payload("contract_probe", proposed.action, safe_action, %{})) ==
               0

      assert_audit_payload_shape(module, proposed.action, safe_action, approval)
    end
  end

  test "registered execution callbacks preserve each kind authority boundary" do
    for module <- Registry.modules() do
      cleanup_state()
      approval = seed_kind!(module)
      assert {:ok, proposed} = SafeActions.propose(approval.approval_id, kind: module.kind())

      assert {:ok, result} = execute_kind(module, proposed)

      assert result.executed == true
      assert result.mode == "executed"

      action = Repo.get_by!(OrchestrationAction, action_id: proposed.action.action_id)
      assert action.status == "executed"
      assert Repo.get_by!(Approval, approval_id: approval.approval_id).status == "acknowledged"

      event_kinds =
        proposed.action.action_id
        |> events_for_action()
        |> Enum.map(& &1.kind)

      assert "execute_attempted" in event_kinds
      assert "approval_ack_attempted" in event_kinds
      assert "executed" in event_kinds
      assert "approval_acknowledged" in event_kinds
    end
  end

  test "unknown proposal kind is rejected before persistence" do
    insert_snapshot!("ws-unknown", db_isolation: "local")
    insert_approval!("apr-unknown", workspace_id: "ws-unknown", command_id: "test")

    assert {:error, {:unsupported_safe_action, "unknown_kind"}} =
             SafeActions.propose("apr-unknown", kind: "unknown_kind")

    assert Repo.aggregate(OrchestrationAction, :count) == 0
    assert Repo.aggregate(ExecutionEvent, :count) == 0
  end

  test "unknown stored action kind is rejected before execution events or side effects" do
    insert_approval!("apr-unknown", workspace_id: "ws-unknown", command_id: "test")
    insert_unknown_action!("act-unknown", "apr-unknown")

    assert {:error, {:unsupported_safe_action, "unknown_kind"}} =
             SafeActions.execute("act-unknown", confirm: true)

    assert Repo.get_by!(OrchestrationAction, action_id: "act-unknown").status == "planned"
    assert Repo.get_by!(Approval, approval_id: "apr-unknown").status == "open"
    assert Repo.aggregate(ExecutionEvent, :count) == 0
  end

  test "operator inspection output is compact stable and includes recovery fields" do
    approval = seed_kind!(RerunDevIDECommand)
    assert {:ok, proposed} = SafeActions.propose(approval.approval_id)
    assert {:ok, _dry_run} = SafeActions.dry_run(proposed.action.action_id)

    show_output =
      capture_io(fn ->
        assert :ok = CLI.run(["actions", "show", proposed.action.action_id])
      end)
      |> normalize_safe_action_output()

    assert show_output == """
           action act-<id>
           kind: rerun_devide_command
           status: planned
           outcome: -
           correlation_id: corr-<id>
           approval: apr-rerun
           approval_detail: jx approvals show apr-rerun
           devide_status: jx devide status ws-rerun
           side_effect_target: ws-rerun:test
           evidence: approval=apr-rerun workspace=ws-rerun command=test db_isolation=local target_ref=test
           policy_denial: -
           result: would request DevIDE to rerun allowlisted command test for workspace ws-rerun via POST /api/workspaces/ws-rerun/runs
           next: Retry with `jx actions execute act-<id> --confirm`, or run `jx actions dry-run act-<id>` first.
           events
             - action=act-<id> kind=proposed outcome=proposed correlation_id=corr-<id> target=ws-rerun:test reason=-
             - action=act-<id> kind=dry_run_viewed outcome=dry_run_viewed correlation_id=corr-<id> target=ws-rerun:test reason=-
           """

    history_output =
      capture_io(fn ->
        assert :ok = CLI.run(["actions", "history", approval.approval_id])
      end)
      |> normalize_safe_action_output()

    assert history_output == """
           action history apr-rerun
           approval_detail: jx approvals show apr-rerun
           actions
             - id=act-<id> kind=rerun_devide_command status=planned outcome=- correlation_id=corr-<id> target=ws-rerun:test policy_denial=-
               evidence: approval=apr-rerun workspace=ws-rerun command=test db_isolation=local target_ref=test
               next: Retry with `jx actions execute act-<id> --confirm`, or run `jx actions dry-run act-<id>` first.
           events
             - action=act-<id> kind=proposed outcome=proposed correlation_id=corr-<id> target=ws-rerun:test reason=-
             - action=act-<id> kind=dry_run_viewed outcome=dry_run_viewed correlation_id=corr-<id> target=ws-rerun:test reason=-
           """
  end

  defp seed_kind!(RerunDevIDECommand) do
    insert_snapshot!("ws-rerun", db_isolation: "local")
    insert_approval!("apr-rerun", workspace_id: "ws-rerun", command_id: "test")
  end

  defp seed_kind!(AcknowledgeApproval) do
    insert_approval!("apr-ack",
      workspace_id: "ws-ack",
      kind: "policy_blocked",
      command_id: "policy.blocked"
    )
  end

  defp execute_kind(RerunDevIDECommand, proposed) do
    bypass = Bypass.open()
    client = Client.new(base_url: "http://localhost:#{bypass.port}", api_token: "safe-token")

    Bypass.expect_once(bypass, "POST", "/api/workspaces/ws-rerun/runs", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"command_id" => "test"}

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(201, Jason.encode!(%{id: "run-1", command_id: "test", status: "running"}))
    end)

    SafeActions.execute(proposed.action.action_id, confirm: true, client: client)
  end

  defp execute_kind(AcknowledgeApproval, proposed) do
    SafeActions.execute(proposed.action.action_id, confirm: true)
  end

  defp assert_audit_payload_shape(RerunDevIDECommand = module, record, safe_action, approval) do
    envelope = %{status: 201, body: %{"id" => "run-1"}, correlation_id: "corr-contract"}

    assert module.audit_payload("executed", record, safe_action, %{envelope: envelope}) == %{
             devide_response: envelope
           }

    assert module.audit_payload("approval_ack_attempted", record, safe_action, %{
             approval: approval,
             envelope: envelope
           }) == %{approval_id: approval.approval_id, devide_response: envelope}
  end

  defp assert_audit_payload_shape(AcknowledgeApproval = module, record, safe_action, approval) do
    assert module.audit_payload("executed", record, safe_action, %{approval: approval}) == %{
             approval_id: approval.approval_id,
             status: approval.status
           }

    assert module.audit_payload("approval_acknowledged", record, safe_action, %{
             approval: approval
           }) == %{approval_id: approval.approval_id, status: approval.status}
  end

  defp assert_expected_fields(expected, payload) do
    Enum.each(expected, fn {key, value} ->
      assert Map.fetch!(payload, key) == value
    end)
  end

  defp action_from_result(safe_action) do
    %Action{
      kind: safe_action.kind,
      source: safe_action.source,
      safety: safe_action.safety,
      dry_run_only: safe_action.dry_run_only,
      requires_confirmation: safe_action.requires_confirmation,
      approval_id: safe_action.approval_id,
      workspace_id: safe_action.workspace_id,
      command_id: safe_action.command_id,
      db_isolation: safe_action.db_isolation,
      target_ref: safe_action.target_ref,
      reason: safe_action.reason
    }
  end

  defp contract_context do
    %{
      opts: [],
      client: nil,
      stored_snapshot: &fetch_snapshot/1,
      record_event: &Audit.record/2,
      record_result: &record_result/1,
      record_denied: &record_denied/4,
      acknowledge_approval: fn approval_id, _opts -> Approvals.acknowledge(approval_id) end,
      reason_text: &inspect/1,
      result: &contract_result/2
    }
  end

  defp fetch_snapshot(workspace_id) do
    case Repo.get_by(WorkspaceSnapshot, workspace_id: workspace_id) do
      %WorkspaceSnapshot{} = snapshot -> {:ok, snapshot}
      nil -> {:error, {:workspace_snapshot_not_found, workspace_id}}
    end
  end

  defp record_result(decision) do
    JX.OrchestrationActions.record_result("contract", decision, source: "approval")
  end

  defp record_denied(record, reason, safe_action, opts) do
    attrs =
      if safe_action do
        Audit.attrs(record, safe_action)
      else
        Audit.attrs(record)
      end

    Audit.record(
      "execute_denied",
      attrs
      |> Map.put(:outcome, Keyword.get(opts, :outcome, "policy_denied"))
      |> Map.put(:reason, inspect(reason))
    )
  end

  defp contract_result(%OrchestrationAction{} = record, %Action{} = safe_action) do
    %{
      action: record,
      safe_action: Action.to_map(safe_action),
      would_do: Action.would_do(safe_action),
      dry_run_only: false,
      executed: false,
      mode: "planned"
    }
  end

  defp insert_unknown_action!(action_id, approval_id) do
    %OrchestrationAction{}
    |> OrchestrationAction.changeset(%{
      action_id: action_id,
      queue_key: "q-unknown-kind",
      requested: "actions.propose",
      source: "approval",
      recommendation_id: "safe-unknown",
      action: "unknown_kind",
      safety: "gated",
      ref: approval_id,
      target: "ws-unknown:test",
      status: "planned",
      reason: "unknown test action",
      payload:
        Jason.encode!(%{
          "approval_id" => approval_id,
          "workspace_id" => "ws-unknown",
          "command_id" => "test",
          "target" => "ws-unknown:test",
          "ref" => approval_id,
          "correlation_id" => "corr-unknown"
        })
    })
    |> Repo.insert!()
  end

  defp insert_snapshot!(workspace_id, opts) do
    db_isolation = Keyword.fetch!(opts, :db_isolation)
    now = DateTime.utc_now()

    %WorkspaceSnapshot{}
    |> WorkspaceSnapshot.changeset(%{
      workspace_id: workspace_id,
      name: "Workspace #{workspace_id}",
      lifecycle_status: "running",
      status: "blocked",
      mode: "review",
      db_isolation: db_isolation,
      attention_flags: "[]",
      snapshot: Jason.encode!(%{"id" => workspace_id, "db_isolation" => db_isolation}),
      fingerprint: "fp-#{workspace_id}-#{db_isolation}",
      source_url: "http://devide.local",
      last_observed_at: now,
      last_changed_at: now
    })
    |> Repo.insert!()
  end

  defp insert_approval!(approval_id, opts) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    command_id = Keyword.fetch!(opts, :command_id)
    kind = Keyword.get(opts, :kind, "failed_run")

    %Approval{}
    |> Approval.changeset(%{
      approval_id: approval_id,
      source: "devide",
      workspace_id: workspace_id,
      kind: kind,
      severity: "warning",
      target_ref: command_id,
      summary: "DevIDE workspace #{workspace_id} has #{command_id} #{kind}",
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

  defp cleanup_state do
    Repo.delete_all(Lease)
    Repo.delete_all(Observation)
    Repo.delete_all(ExecutionEvent)
    Repo.delete_all(OrchestrationAction)
    Repo.delete_all(Approval)
    Repo.delete_all(WorkspaceSnapshot)
  end

  defp events_for_action(action_id) do
    ExecutionEvent
    |> where([event], event.action_id == ^action_id)
    |> order_by([event], asc: event.id)
    |> Repo.all()
  end

  defp normalize_safe_action_output(output) do
    output
    |> then(&Regex.replace(~r/act-[a-f0-9]{10}/, &1, "act-<id>"))
    |> then(&Regex.replace(~r/corr-[a-f0-9]{16}/, &1, "corr-<id>"))
  end
end
