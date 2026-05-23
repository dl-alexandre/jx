defmodule JX.CLI.AgentTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias JX.CLI.Agent

  defmodule FakeWorkspace do
    def create_approval(attrs) do
      send(self(), {:create_approval, attrs})

      {:ok,
       %{
         approval_id: "apr-test",
         kind: attrs.kind,
         severity: attrs.severity,
         target_ref: attrs.target_ref
       }}
    end

    def approval_summary, do: %{open_total: 3, active_total: 5}
    def list_agents, do: [%{}, %{}]
    def list_delegations, do: [%{}]
  end

  test "request-approval routes through Workspace with risk mapped to severity" do
    output =
      capture_io(fn ->
        assert :ok =
                 Agent.run(
                   [
                     "request-approval",
                     "--action",
                     "rm -rf build",
                     "--reason",
                     "stale",
                     "--risk",
                     "high",
                     "--json"
                   ],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:create_approval, attrs}
    assert attrs.kind == "agent_request"
    assert attrs.source == "agent"
    assert attrs.severity == "critical"
    assert attrs.target_ref == "rm -rf build"
    assert %{"status" => "open", "approval_id" => "apr-test"} = Jason.decode!(output)
  end

  test "request-approval validates required flags before starting the app" do
    assert {:error, message} =
             Agent.run(["request-approval", "--action", "x"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "missing required --reason"
    refute_received :started
    refute_received {:create_approval, _}
  end

  test "handoff records an agent_handoff approval" do
    capture_io(fn ->
      assert :ok =
               Agent.run(
                 ["handoff", "--to", "operator", "--summary", "blocked on creds"],
                 start_app: start_app_callback(),
                 workspace: FakeWorkspace
               )
    end)

    assert_received {:create_approval, attrs}
    assert attrs.kind == "agent_handoff"
    assert attrs.target_ref == "operator"
  end

  test "status aggregates real workspace counts" do
    output =
      capture_io(fn ->
        assert :ok =
                 Agent.run(["status", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert %{
             "open_approvals" => 3,
             "active_approvals" => 5,
             "agents" => 2,
             "delegations" => 1
           } = Jason.decode!(output)
  end

  test "report returns an explicit not-implemented error rather than fabricating" do
    assert {:error, message} =
             Agent.run(["report", "--session", "s1", "--text", "hi"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "not yet implemented"
    refute_received :started
  end

  defp start_app_callback do
    test = self()

    fn ->
      send(test, :started)
      :ok
    end
  end
end
