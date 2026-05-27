defmodule JX.CLI.RecapTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias JX.CLI.Recap

  defmodule FakeWorkspace do
    def recap(opts) do
      send(self(), {:recap, opts})

      %{
        since: ~U[2026-05-19 00:00:00Z],
        until: ~U[2026-05-26 00:00:00Z],
        tasks: %{
          total: 2,
          by_status: %{"running" => 1, "completed" => 1},
          by_host: %{"build-1" => 2},
          by_project: %{"saysure" => 2},
          by_agent: %{"codex" => 2},
          latest: []
        },
        directives: %{total: 1, by_status: %{"sent" => 1}, by_host: %{"build-1" => 1}},
        resources: %{total: 4, by_type: %{"tmux_session" => 1}},
        handoffs: %{total: 1, by_status: %{"open" => 1}},
        session_profiles: %{total: 1, by_prompt_status: %{"blocked" => 1}},
        operational_events: %{total: 1, by_severity: %{"notice" => 1}}
      }
    end
  end

  test "prints a text recap" do
    output =
      capture_io(fn ->
        assert :ok =
                 Recap.run(["--days", "7"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    assert_received :started
    assert_received {:recap, opts}
    assert opts[:days] == 7
    assert output =~ "jx recap"
    assert output =~ "tasks: 2"
    assert output =~ "directives: 1"
  end

  test "prints JSON with ISO8601 dates" do
    output =
      capture_io(fn ->
        assert :ok =
                 Recap.run(["--json"],
                   start_app: start_app_callback(),
                   workspace: FakeWorkspace
                 )
      end)

    decoded = Jason.decode!(output)
    assert decoded["since"] == "2026-05-19T00:00:00Z"
    assert decoded["tasks"]["total"] == 2
  end

  defp start_app_callback do
    test = self()

    fn ->
      send(test, :started)
      :ok
    end
  end
end
