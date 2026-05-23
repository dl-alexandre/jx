defmodule JX.SafeActionsTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureIO

  alias JX.Approvals.Approval
  alias JX.CLI
  alias JX.DevIDE.Client
  alias JX.DevIDE.WorkspaceSnapshot
  alias JX.HostCapacity.Observation
  alias JX.OperationalLeases.Lease
  alias JX.OperationExecutions.OperationExecution
  alias JX.OrchestrationActions.OrchestrationAction
  alias JX.Repo
  alias JX.SafeActions
  alias JX.SafeActions.Action
  alias JX.SafeActions.ExecutionEvent
  alias JX.SafeActions.Registry
  alias JX.SafeActions.Kinds.{AcknowledgeApproval, RerunDevIDECommand}

  setup do
    cleanup_state()
    :ok
  end

  test "proposes deterministic DevIDE rerun actions for allowlisted commands" do
    insert_snapshot!("ws-1", db_isolation: "local")
    insert_approval!("apr-test", workspace_id: "ws-1", command_id: "test")

    assert {:ok, first} = SafeActions.propose("apr-test")
    assert first.safe_action.kind == "rerun_devide_command"
    assert first.safe_action.command_id == "test"
    assert first.safe_action.db_isolation == "local"
    refute first.dry_run_only
    assert first.executed == false
    assert first.would_do =~ "POST /api/workspaces/ws-1/runs"

    assert first.action.status == "planned"
    assert first.action.source == "approval"
    assert first.action.action == "rerun_devide_command"
    assert first.action.safety == "gated"
    assert first.action.ref == "apr-test"
    assert first.action.target == "ws-1:test"

    assert {:ok, second} = SafeActions.propose("apr-test")
    assert second.action.action_id == first.action.action_id
    assert Repo.aggregate(OrchestrationAction, :count) == 1

    assert [%ExecutionEvent{kind: "proposed", action_id: action_id}] =
             Repo.all(ExecutionEvent)

    assert action_id == first.action.action_id

    payload = Jason.decode!(first.action.payload)
    assert payload["expires_at"]
    assert payload["correlation_id"] =~ "corr-"
    assert Repo.one!(ExecutionEvent).correlation_id == payload["correlation_id"]
  end

  test "safe action registry exposes exactly command rerun plus approval acknowledgment" do
    assert Registry.default_kind() == "rerun_devide_command"
    assert Registry.modules() == [RerunDevIDECommand, AcknowledgeApproval]
    assert Registry.kinds() == ~w(rerun_devide_command acknowledge_approval)
    assert Action.kinds() == ~w(rerun_devide_command acknowledge_approval)

    for module <- Registry.modules() do
      assert {:ok, ^module} = Registry.fetch(module.kind())
      assert function_exported?(module, :propose, 2)
      assert function_exported?(module, :authorize, 3)
      assert function_exported?(module, :dry_run, 4)
      assert function_exported?(module, :execute, 4)
      assert function_exported?(module, :audit_payload, 4)
      assert function_exported?(module, :recovery_guidance, 3)
    end

    assert {:error, {:unsupported_safe_action, "other"}} = Registry.fetch("other")
  end

  test "dry-run rechecks policy and emits would-do output without execution records" do
    insert_snapshot!("ws-1", db_isolation: "ephemeral")
    insert_approval!("apr-compile", workspace_id: "ws-1", command_id: "compile")

    assert {:ok, proposed} = SafeActions.propose("apr-compile")
    assert {:ok, dry_run} = SafeActions.dry_run(proposed.action.action_id)

    assert dry_run.mode == "dry_run"
    assert dry_run.executed == false
    assert dry_run.would_do =~ "compile"
    assert Repo.aggregate(OperationExecution, :count) == 0

    assert Repo.get_by!(ExecutionEvent, kind: "dry_run_viewed").action_id ==
             proposed.action.action_id

    output =
      capture_io(fn ->
        assert :ok = CLI.run(["actions", "dry-run", proposed.action.action_id])
      end)

    assert output =~ "dry run #{proposed.action.action_id}"
    assert output =~ "would do:"
    assert output =~ "execution: requires --confirm"

    assert Repo.aggregate(ExecutionEvent, :count) == 3
  end

  test "CLI propose records a planned action and prints clear would-do output" do
    insert_snapshot!("ws-1", db_isolation: "unknown")
    insert_approval!("apr-format", workspace_id: "ws-1", command_id: "format")

    output =
      capture_io(fn ->
        assert :ok = CLI.run(["actions", "propose", "apr-format"])
      end)

    assert output =~ "proposed act-"
    assert output =~ "command: format"
    assert output =~ "would do:"

    assert [%OrchestrationAction{action: "rerun_devide_command", status: "planned"}] =
             Repo.all(OrchestrationAction)
  end

  test "proposes dry-runs and executes approval acknowledgment without DevIDE" do
    insert_approval!("apr-policy",
      workspace_id: "ws-policy",
      kind: "policy_blocked",
      command_id: "policy.blocked"
    )

    assert {:ok, proposed} = SafeActions.propose("apr-policy", kind: "acknowledge_approval")
    assert proposed.safe_action.kind == "acknowledge_approval"
    assert proposed.action.action == "acknowledge_approval"
    assert proposed.action.target == "ws-policy:apr-policy"
    assert proposed.would_do =~ "without calling DevIDE"

    assert {:ok, dry_run} = SafeActions.dry_run(proposed.action.action_id)
    assert dry_run.mode == "dry_run"
    assert dry_run.executed == false
    assert dry_run.would_do =~ "acknowledge JX approval apr-policy"

    output =
      capture_io(fn ->
        assert :ok = CLI.run(["actions", "execute", proposed.action.action_id, "--confirm"])
      end)

    assert output =~ "executed #{proposed.action.action_id}"
    assert output =~ "kind: acknowledge_approval"
    assert output =~ "approval_status: acknowledged"
    refute output =~ "POST /api/workspaces"

    action = Repo.get_by!(OrchestrationAction, action_id: proposed.action.action_id)
    assert action.status == "executed"
    assert action.result_summary == "JX approval apr-policy acknowledged"
    assert Repo.get_by!(Approval, approval_id: "apr-policy").status == "acknowledged"

    correlation_id = action.payload |> Jason.decode!() |> Map.fetch!("correlation_id")

    assert [
             "proposed",
             "dry_run_viewed",
             "execute_attempted",
             "approval_ack_attempted",
             "executed",
             "approval_acknowledged"
           ] = proposed.action.action_id |> events_for_action() |> Enum.map(& &1.kind)

    assert proposed.action.action_id
           |> events_for_action()
           |> Enum.all?(&(&1.correlation_id == correlation_id))

    action_id = proposed.action.action_id

    assert {:error, {:action_already_executed, ^action_id}} =
             SafeActions.execute(proposed.action.action_id, confirm: true)
  end

  test "CLI proposes acknowledgment action explicitly and denies acknowledged approvals" do
    insert_approval!("apr-unsafe",
      workspace_id: "ws-unsafe",
      kind: "unsafe_db",
      command_id: "unsafe"
    )

    output =
      capture_io(fn ->
        assert :ok =
                 CLI.run([
                   "actions",
                   "propose",
                   "apr-unsafe",
                   "--kind",
                   "acknowledge_approval"
                 ])
      end)

    assert output =~ "proposed act-"
    assert output =~ "kind: acknowledge_approval"
    assert output =~ "without calling DevIDE"
    refute output =~ "command:"

    assert [%OrchestrationAction{action: "acknowledge_approval", status: "planned"}] =
             Repo.all(OrchestrationAction)

    assert {:ok, _approval} = JX.Approvals.acknowledge("apr-unsafe")

    assert {:error, {:approval_not_open, "acknowledged"}} =
             SafeActions.propose("apr-unsafe", kind: "acknowledge_approval")
  end

  test "denies unsafe and shared DevIDE database isolation" do
    insert_snapshot!("ws-unsafe", db_isolation: "unsafe")
    insert_approval!("apr-unsafe", workspace_id: "ws-unsafe", command_id: "test")

    assert {:error, {:unsafe_db_isolation, "unsafe"}} = SafeActions.propose("apr-unsafe")

    insert_snapshot!("ws-shared", db_isolation: "shared_stage")
    insert_approval!("apr-shared", workspace_id: "ws-shared", command_id: "test")

    assert {:error, {:unsafe_db_isolation, "shared_stage"}} =
             SafeActions.propose("apr-shared")

    assert Repo.aggregate(OrchestrationAction, :count) == 0
  end

  test "denies missing workspace snapshots and non-allowlisted commands" do
    insert_approval!("apr-missing", workspace_id: "missing", command_id: "test")

    assert {:error, {:workspace_snapshot_not_found, "missing"}} =
             SafeActions.propose("apr-missing")

    insert_snapshot!("ws-1", db_isolation: "local")
    insert_approval!("apr-deploy", workspace_id: "ws-1", command_id: "deploy")

    assert {:error, {:unsupported_devide_command, "deploy", allowed}} =
             SafeActions.propose("apr-deploy")

    assert allowed == ~w(compile test format precommit)
    assert Repo.aggregate(OrchestrationAction, :count) == 0
  end

  test "CLI execute without confirmation refuses and prints dry-run guidance" do
    insert_snapshot!("ws-1", db_isolation: "local")
    insert_approval!("apr-test", workspace_id: "ws-1", command_id: "test")
    assert {:ok, proposed} = SafeActions.propose("apr-test")

    output =
      capture_io(fn ->
        assert {:error, message} = CLI.run(["actions", "execute", proposed.action.action_id])
        assert message =~ "confirmation required"
      end)

    assert output =~ "dry run #{proposed.action.action_id}"
    assert output =~ "execution: requires --confirm"

    assert Repo.get_by!(OrchestrationAction, action_id: proposed.action.action_id).status ==
             "planned"

    assert Repo.get_by!(Approval, approval_id: "apr-test").status == "open"

    assert %ExecutionEvent{reason: ":confirmation_required", outcome: "confirmation_required"} =
             Repo.get_by!(ExecutionEvent,
               action_id: proposed.action.action_id,
               kind: "execute_denied"
             )
  end

  test "confirmed execute calls only the DevIDE run endpoint and acknowledges approval" do
    bypass = Bypass.open()
    restore_env!("JX_DEVIDE_URL")
    restore_env!("JX_DEVIDE_API_TOKEN")
    System.put_env("JX_DEVIDE_URL", "http://localhost:#{bypass.port}")
    System.put_env("JX_DEVIDE_API_TOKEN", "safe-token")

    insert_snapshot!("ws-1", db_isolation: "local")
    insert_approval!("apr-test", workspace_id: "ws-1", command_id: "test")
    assert {:ok, proposed} = SafeActions.propose("apr-test")

    action_correlation_id =
      proposed.action.payload |> Jason.decode!() |> Map.fetch!("correlation_id")

    Bypass.expect_once(bypass, "POST", "/api/workspaces/ws-1/runs", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer safe-token"]
      assert Plug.Conn.get_req_header(conn, "x-jx-correlation-id") == [action_correlation_id]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"command_id" => "test"}

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        201,
        Jason.encode!(%{
          id: "run-1",
          workspace_id: "ws-1",
          command_id: "test",
          status: "running"
        })
      )
    end)

    output =
      capture_io(fn ->
        assert :ok = CLI.run(["actions", "execute", proposed.action.action_id, "--confirm"])
      end)

    assert output =~ "executed #{proposed.action.action_id}"
    assert output =~ "run: run-1"
    assert output =~ "status: running"

    action = Repo.get_by!(OrchestrationAction, action_id: proposed.action.action_id)
    assert action.status == "executed"
    assert action.result_summary =~ "run-1"

    payload = Jason.decode!(action.payload)
    assert payload["correlation_id"] == action_correlation_id
    assert payload["devide_response"]["status"] == 201
    assert payload["devide_response"]["body"]["id"] == "run-1"
    assert payload["devide_response"]["correlation_id"] == action_correlation_id

    assert Repo.get_by!(Approval, approval_id: "apr-test").status == "acknowledged"

    events = events_for_action(proposed.action.action_id)

    assert [
             "proposed",
             "execute_attempted",
             "executed",
             "approval_ack_attempted",
             "approval_acknowledged"
           ] = Enum.map(events, & &1.kind)

    outcomes = Enum.map(events, & &1.outcome)
    assert Enum.all?(events, &(&1.correlation_id == action_correlation_id))
    assert "success" in outcomes
    assert "approval_acknowledged" in outcomes
  end

  test "execute is idempotent by action id and refuses already executed actions" do
    bypass = Bypass.open()
    client = Client.new(base_url: "http://localhost:#{bypass.port}", api_token: "safe-token")

    insert_snapshot!("ws-1", db_isolation: "local")
    insert_approval!("apr-test", workspace_id: "ws-1", command_id: "test")
    assert {:ok, proposed} = SafeActions.propose("apr-test")

    Bypass.expect_once(bypass, "POST", "/api/workspaces/ws-1/runs", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(201, Jason.encode!(%{id: "run-1", command_id: "test", status: "running"}))
    end)

    assert {:ok, _result} =
             SafeActions.execute(proposed.action.action_id, confirm: true, client: client)

    assert {:error, {:action_already_executed, action_id}} =
             SafeActions.execute(proposed.action.action_id, confirm: true, client: client)

    assert action_id == proposed.action.action_id
    assert Repo.aggregate(OrchestrationAction, :count) == 1

    assert [
             "proposed",
             "execute_attempted",
             "executed",
             "approval_ack_attempted",
             "approval_acknowledged",
             "execute_attempted",
             "execute_denied"
           ] =
             proposed.action.action_id
             |> events_for_action()
             |> Enum.map(& &1.kind)
  end

  test "execute denies expired revoked and approval-mismatched actions" do
    insert_snapshot!("ws-1", db_isolation: "local")
    insert_approval!("apr-test", workspace_id: "ws-1", command_id: "test")
    assert {:ok, proposed} = SafeActions.propose("apr-test")

    update_action_payload!(proposed.action.action_id, %{
      "expires_at" => DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.to_iso8601()
    })

    assert {:error, {:action_expired, _}} =
             SafeActions.execute(proposed.action.action_id, confirm: true)

    insert_snapshot!("ws-2", db_isolation: "local")
    insert_approval!("apr-compile", workspace_id: "ws-2", command_id: "compile")
    assert {:ok, revoked} = SafeActions.propose("apr-compile")
    update_action_payload!(revoked.action.action_id, %{"revoked" => true})

    assert {:error, {:action_revoked, _}} =
             SafeActions.execute(revoked.action.action_id, confirm: true)

    insert_snapshot!("ws-3", db_isolation: "local")
    insert_approval!("apr-format", workspace_id: "ws-3", command_id: "format")
    assert {:ok, mismatched} = SafeActions.propose("apr-format")
    update_action_payload!(mismatched.action.action_id, %{"command_id" => "test"})

    assert {:error, {:approval_mismatch, _}} =
             SafeActions.execute(mismatched.action.action_id, confirm: true)

    assert Repo.aggregate(OrchestrationAction, :count) == 3
    assert Repo.aggregate(ExecutionEvent, :count) == 9
    assert Enum.count(Repo.all(ExecutionEvent), &(&1.outcome == "policy_denied")) == 3
  end

  test "execute rechecks local unsafe DB policy before calling DevIDE" do
    bypass = Bypass.open()
    client = Client.new(base_url: "http://localhost:#{bypass.port}", api_token: "safe-token")

    insert_snapshot!("ws-1", db_isolation: "local")
    insert_approval!("apr-test", workspace_id: "ws-1", command_id: "test")
    assert {:ok, proposed} = SafeActions.propose("apr-test")

    Repo.get_by!(WorkspaceSnapshot, workspace_id: "ws-1")
    |> WorkspaceSnapshot.changeset(%{
      db_isolation: "unsafe",
      fingerprint: "unsafe-now",
      snapshot: Jason.encode!(%{"id" => "ws-1", "db_isolation" => "unsafe"})
    })
    |> Repo.update!()

    assert {:error, {:unsafe_db_isolation, "unsafe"}} =
             SafeActions.execute(proposed.action.action_id, confirm: true, client: client)

    assert Repo.get_by!(OrchestrationAction, action_id: proposed.action.action_id).status ==
             "planned"

    assert %ExecutionEvent{
             kind: "execute_denied",
             outcome: "policy_denied",
             reason: "{:unsafe_db_isolation, \"unsafe\"}"
           } =
             Repo.get_by!(ExecutionEvent,
               action_id: proposed.action.action_id,
               kind: "execute_denied"
             )

    show_output =
      capture_io(fn ->
        assert :ok = CLI.run(["actions", "show", proposed.action.action_id])
      end)

    assert show_output =~ "policy_denial: {:unsafe_db_isolation, \"unsafe\"}"
    assert show_output =~ "next: Refresh DevIDE state and repropose"
  end

  test "execute distinguishes DevIDE failure, network failure, and malformed response" do
    insert_snapshot!("ws-devide", db_isolation: "local")
    insert_approval!("apr-devide", workspace_id: "ws-devide", command_id: "test")
    assert {:ok, devide_failure} = SafeActions.propose("apr-devide")

    bypass = Bypass.open()
    client = Client.new(base_url: "http://localhost:#{bypass.port}", api_token: "safe-token")

    Bypass.expect_once(bypass, "POST", "/api/workspaces/ws-devide/runs", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(503, Jason.encode!(%{error: "temporarily_unavailable"}))
    end)

    assert {:error, %Client.Error{status: 503}} =
             SafeActions.execute(devide_failure.action.action_id, confirm: true, client: client)

    assert latest_event(devide_failure.action.action_id).outcome == "devide_failure"

    assert Repo.get_by!(OrchestrationAction, action_id: devide_failure.action.action_id).status ==
             "planned"

    insert_snapshot!("ws-network", db_isolation: "local")
    insert_approval!("apr-network", workspace_id: "ws-network", command_id: "test")
    assert {:ok, network_failure} = SafeActions.propose("apr-network")

    down = Bypass.open()
    Bypass.down(down)
    down_client = Client.new(base_url: "http://localhost:#{down.port}", api_token: "safe-token")

    assert {:error, %Client.Error{status: nil}} =
             SafeActions.execute(network_failure.action.action_id,
               confirm: true,
               client: down_client
             )

    assert latest_event(network_failure.action.action_id).outcome == "network_failure"

    assert Repo.get_by!(OrchestrationAction, action_id: network_failure.action.action_id).status ==
             "planned"

    insert_snapshot!("ws-bad", db_isolation: "local")
    insert_approval!("apr-bad", workspace_id: "ws-bad", command_id: "test")
    assert {:ok, malformed} = SafeActions.propose("apr-bad")

    bad = Bypass.open()
    bad_client = Client.new(base_url: "http://localhost:#{bad.port}", api_token: "safe-token")

    Bypass.expect_once(bad, "POST", "/api/workspaces/ws-bad/runs", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(201, Jason.encode!(%{unexpected: "shape"}))
    end)

    assert {:error, {:malformed_devide_response, :missing_run_id}} =
             SafeActions.execute(malformed.action.action_id, confirm: true, client: bad_client)

    assert latest_event(malformed.action.action_id).outcome == "malformed_response"

    assert Repo.get_by!(OrchestrationAction, action_id: malformed.action.action_id).status ==
             "error"
  end

  test "approval acknowledgment failure is audited after a successful DevIDE run" do
    bypass = Bypass.open()
    client = Client.new(base_url: "http://localhost:#{bypass.port}", api_token: "safe-token")

    insert_snapshot!("ws-1", db_isolation: "local")
    insert_approval!("apr-test", workspace_id: "ws-1", command_id: "test")
    assert {:ok, proposed} = SafeActions.propose("apr-test")

    Bypass.expect_once(bypass, "POST", "/api/workspaces/ws-1/runs", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(201, Jason.encode!(%{id: "run-1", command_id: "test", status: "running"}))
    end)

    assert {:error, {:approval_ack_failed, :db_busy}} =
             SafeActions.execute(proposed.action.action_id,
               confirm: true,
               client: client,
               acknowledge_fun: fn _approval_id -> {:error, :db_busy} end
             )

    action = Repo.get_by!(OrchestrationAction, action_id: proposed.action.action_id)
    assert action.status == "executed"
    assert Repo.get_by!(Approval, approval_id: "apr-test").status == "open"

    assert latest_event(proposed.action.action_id).outcome == "approval_ack_failure"

    show_output =
      capture_io(fn ->
        assert :ok = CLI.run(["actions", "show", proposed.action.action_id])
      end)

    assert show_output =~ "Inspect DevIDE"
    assert show_output =~ "Do not retry"
    assert show_output =~ "acknowledge"
  end

  test "missing snapshot is denied before DevIDE POST" do
    bypass = Bypass.open()
    client = Client.new(base_url: "http://localhost:#{bypass.port}", api_token: "safe-token")
    {:ok, requests} = Agent.start_link(fn -> [] end)

    Bypass.stub(bypass, "POST", "/api/workspaces/ws-1/runs", fn conn ->
      Agent.update(requests, &[{conn.method, conn.request_path} | &1])
      Plug.Conn.resp(conn, 500, "unexpected")
    end)

    insert_snapshot!("ws-1", db_isolation: "local")
    insert_approval!("apr-test", workspace_id: "ws-1", command_id: "test")
    assert {:ok, proposed} = SafeActions.propose("apr-test")
    Repo.delete_all(WorkspaceSnapshot)

    assert {:error, {:workspace_snapshot_not_found, "ws-1"}} =
             SafeActions.execute(proposed.action.action_id, confirm: true, client: client)

    assert Agent.get(requests, & &1) == []
    assert latest_event(proposed.action.action_id).outcome == "policy_denied"
  end

  test "actions show and history use stable operator inspection format" do
    insert_snapshot!("ws-1", db_isolation: "local")
    insert_approval!("apr-test", workspace_id: "ws-1", command_id: "test")
    assert {:ok, proposed} = SafeActions.propose("apr-test")
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
           approval: apr-test
           approval_detail: jx approvals show apr-test
           devide_status: jx devide status ws-1
           side_effect_target: ws-1:test
           evidence: approval=apr-test workspace=ws-1 command=test db_isolation=local target_ref=test
           policy_denial: -
           result: would request DevIDE to rerun allowlisted command test for workspace ws-1 via POST /api/workspaces/ws-1/runs
           next: Retry with `jx actions execute act-<id> --confirm`, or run `jx actions dry-run act-<id>` first.
           events
             - action=act-<id> kind=proposed outcome=proposed correlation_id=corr-<id> target=ws-1:test reason=-
             - action=act-<id> kind=dry_run_viewed outcome=dry_run_viewed correlation_id=corr-<id> target=ws-1:test reason=-
           """

    history_output =
      capture_io(fn ->
        assert :ok = CLI.run(["actions", "history", "apr-test"])
      end)
      |> normalize_safe_action_output()

    assert history_output == """
           action history apr-test
           approval_detail: jx approvals show apr-test
           actions
             - id=act-<id> kind=rerun_devide_command status=planned outcome=- correlation_id=corr-<id> target=ws-1:test policy_denial=-
               evidence: approval=apr-test workspace=ws-1 command=test db_isolation=local target_ref=test
               next: Retry with `jx actions execute act-<id> --confirm`, or run `jx actions dry-run act-<id>` first.
           events
             - action=act-<id> kind=proposed outcome=proposed correlation_id=corr-<id> target=ws-1:test reason=-
             - action=act-<id> kind=dry_run_viewed outcome=dry_run_viewed correlation_id=corr-<id> target=ws-1:test reason=-
           """
  end

  defp insert_snapshot!(workspace_id, opts) do
    db_isolation = Keyword.fetch!(opts, :db_isolation)
    now = DateTime.utc_now()

    snapshot = %{
      id: workspace_id,
      name: "Workspace #{workspace_id}",
      status: "blocked",
      lifecycle_status: "running",
      mode: "review",
      db_isolation: db_isolation,
      active_run: nil,
      latest_runs: [],
      proposal_risks: [],
      recent_blocks: [],
      attention_flags: []
    }

    %WorkspaceSnapshot{}
    |> WorkspaceSnapshot.changeset(%{
      workspace_id: workspace_id,
      name: "Workspace #{workspace_id}",
      lifecycle_status: "running",
      status: "blocked",
      mode: "review",
      db_isolation: db_isolation,
      attention_flags: "[]",
      snapshot: Jason.encode!(snapshot),
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
    Repo.delete_all(OperationExecution)
    Repo.delete_all(OrchestrationAction)
    Repo.delete_all(Approval)
    Repo.delete_all(WorkspaceSnapshot)
  end

  defp restore_env!(key) do
    previous = System.get_env(key)

    on_exit(fn ->
      if is_nil(previous), do: System.delete_env(key), else: System.put_env(key, previous)
    end)
  end

  defp events_for_action(action_id) do
    ExecutionEvent
    |> where([event], event.action_id == ^action_id)
    |> order_by([event], asc: event.id)
    |> Repo.all()
  end

  defp latest_event(action_id) do
    action_id
    |> events_for_action()
    |> List.last()
  end

  defp update_action_payload!(action_id, attrs) do
    action = Repo.get_by!(OrchestrationAction, action_id: action_id)

    payload =
      action.payload
      |> Jason.decode!()
      |> Map.merge(attrs)
      |> Jason.encode!()

    action
    |> OrchestrationAction.changeset(%{payload: payload})
    |> Repo.update!()
  end

  defp normalize_safe_action_output(output) do
    output
    |> then(&Regex.replace(~r/act-[a-f0-9]{10}/, &1, "act-<id>"))
    |> then(&Regex.replace(~r/corr-[a-f0-9]{16}/, &1, "corr-<id>"))
  end
end
