defmodule JX.CLI.QueueTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias JX.CLI.Queue

  defmodule FakeWorkspace do
    def operational_queue(opts) do
      send(self(), {:operational_queue, opts})

      %{
        generated_at: "2026-05-12T00:00:00Z",
        stale_after_seconds: opts[:stale_after_seconds],
        totals: %{total: 1, stale: 1},
        items: [
          %{
            type: opts[:kind] || "workspace",
            id: "queue-1",
            risk: opts[:risk] || "stale",
            reason: "stale",
            freshness: opts[:freshness] || "stale",
            urgency: "high",
            owner: opts[:owner],
            workspace_id: opts[:workspace_id],
            summary: "Queue item",
            next: "jx queue workspace workspace-1"
          }
        ]
      }
    end

    def operational_workspace(workspace_id, opts) do
      send(self(), {:operational_workspace, workspace_id, opts})

      %{
        workspace_id: workspace_id,
        generated_at: "2026-05-12T00:00:00Z",
        health: %{status: "attention", freshness: "stale", risk: "stale"},
        approvals: [
          %{
            approval_id: "apr-1",
            kind: "safe_action",
            severity: "warning",
            freshness: "fresh",
            owner: "operator"
          }
        ],
        actions: [],
        leases: [],
        next: %{
          approvals: "jx approvals ls --workspace #{workspace_id}",
          devide_status: "jx devide status #{workspace_id}",
          timeline: "jx timeline workspace #{workspace_id}"
        }
      }
    end

    def operational_rebuilt_state do
      send(self(), :operational_rebuilt_state)

      %{
        events: 3,
        queue: %{open_approvals: 1, planned_actions: 1, active_leases: 1}
      }
    end
  end

  test "queue ls owns filters and json output" do
    output =
      capture_io(fn ->
        assert :ok =
                 Queue.run(
                   [
                     "ls",
                     "--kind",
                     "workspace",
                     "--workspace",
                     "workspace-1",
                     "--owner",
                     "agent-1",
                     "--risk",
                     "stale",
                     "--freshness",
                     "fresh",
                     "--sort",
                     "urgency",
                     "--stale-after-seconds",
                     "120",
                     "-n",
                     "5",
                     "--json"
                   ],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:operational_queue, opts}
    assert opts[:kind] == "workspace"
    assert opts[:workspace_id] == "workspace-1"
    assert opts[:owner] == "agent-1"
    assert opts[:risk] == "stale"
    assert opts[:freshness] == "fresh"
    assert opts[:sort] == "urgency"
    assert opts[:stale_after_seconds] == 120
    assert opts[:limit] == 5

    assert %{"items" => [%{"id" => "queue-1"}], "stale_after_seconds" => 120} =
             Jason.decode!(output)
  end

  test "queue ls validates filters before starting the app" do
    assert {:error, message} =
             Queue.run(["ls", "--kind", "bad"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "unsupported queue kind"
    refute_received :started
    refute_received :operational_queue
  end

  test "queue ls accepts blocker kind" do
    capture_io(fn ->
      assert :ok =
               Queue.run(["ls", "--kind", "blocker"],
                 start_app: start_app_callback(),
                 workspace: FakeWorkspace
               )
    end)

    assert_received {:operational_queue, opts}
    assert opts[:kind] == "blocker"
  end

  test "queue workspace routes workspace id and staleness window" do
    output =
      capture_io(fn ->
        assert :ok =
                 Queue.run(
                   ["workspace", "workspace-1", "--stale-after-seconds", "300", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:operational_workspace, "workspace-1", opts}
    assert opts[:stale_after_seconds] == 300

    assert %{"workspace_id" => "workspace-1", "health" => %{"risk" => "stale"}} =
             Jason.decode!(output)
  end

  test "queue workspace validates staleness window before starting the app" do
    assert {:error, message} =
             Queue.run(["workspace", "workspace-1", "--stale-after-seconds", "0"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message == "stale-after-seconds must be a positive integer"
    refute_received :started
    refute_received :operational_workspace
  end

  test "queue rebuild renders rebuilt state" do
    output =
      capture_io(fn ->
        assert :ok =
                 Queue.run(["rebuild", "--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received :operational_rebuilt_state

    assert %{
             "events" => 3,
             "queue" => %{"active_leases" => 1, "open_approvals" => 1, "planned_actions" => 1}
           } = Jason.decode!(output)
  end

  test "unknown queue command returns focused usage" do
    assert {:error, message} =
             Queue.run(["unknown"],
               start_app: start_app_callback(),
               workspace: FakeWorkspace
             )

    assert message =~ "usage: jx queue ls"
    assert message =~ "jx queue rebuild"
  end

  defp start_app_callback do
    fn ->
      send(self(), :started)
      :ok
    end
  end
end
