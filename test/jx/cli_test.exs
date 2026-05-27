defmodule JX.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias JX.CLI

  test "--help prints top-level usage" do
    output = capture_io(fn -> assert :ok = CLI.run(["--help"]) end)

    assert output =~ "jx orchestrates durable SSH/tmux worktree sessions."
    assert output =~ "jx [--db path] help [group]"
    assert output =~ "jx [--db path] recap"
    assert output =~ "Common workflows:"
  end

  test "--version prints jx version" do
    output = capture_io(fn -> assert :ok = CLI.run(["--version"]) end)

    assert output =~ "jx "
  end

  test "help group prints focused usage" do
    output = capture_io(fn -> assert :ok = CLI.run(["help", "ci"]) end)

    assert output =~ "jx help ci"
    assert output =~ "jx ci digest <pr-number>"
    assert output =~ "jx ci watch <pr-number>"
  end

  test "help orchestrator includes health command" do
    output = capture_io(fn -> assert :ok = CLI.run(["help", "orchestrator"]) end)

    assert output =~ "jx help orchestrator"
    assert output =~ "orchestrator start|status|stop|logs|health|heartbeats"
  end

  test "help project includes project brief" do
    output = capture_io(fn -> assert :ok = CLI.run(["help", "project"]) end)

    assert output =~ "jx help project"
    assert output =~ "jx project brief <name>"
  end

  test "help fanout includes file-backed assignment commands" do
    output = capture_io(fn -> assert :ok = CLI.run(["help", "fanout"]) end)

    assert output =~ "jx help fanout"
    assert output =~ "jx fanout plan <plan-id>"
    assert output =~ "jx fanout preflight <run-id-or-path>"
    assert output =~ "jx fanout launch <run-id-or-path>"
    assert output =~ "jx fanout monitor <run-id-or-path>"
    assert output =~ "jx fanout ownership <run-id-or-path> <assignment-id>"
    assert output =~ "jx fanout pr <run-id-or-path> <assignment-id>"
    assert output =~ "jx fanout status <run-id-or-path>"
  end

  test "help tui includes snapshot, watch, and plan commands" do
    output = capture_io(fn -> assert :ok = CLI.run(["help", "tui"]) end)

    assert output =~ "jx help tui"
    assert output =~ "jx tui"
    assert output =~ "jx tui snapshot"
    assert output =~ "jx tui watch"
    assert output =~ "jx tui interactive"
    assert output =~ "jx tui plan"
  end

  test "--help group prints focused usage" do
    output = capture_io(fn -> assert :ok = CLI.run(["--help", "sessions"]) end)

    assert output =~ "jx help sessions"
    assert output =~ "jx sessions queues"
    assert output =~ "jx sessions profiles"
  end

  test "modes prints operator mode catalog" do
    output = capture_io(fn -> assert :ok = CLI.run(["modes"]) end)

    assert output =~ "jx usage modes"
    assert output =~ "tui - Terminal UI"
    assert output =~ "daemon - Detached Daemon"
    assert output =~ "wake - External Wake"
    assert output =~ "jx tui"
  end

  test "modes can print JSON" do
    output = capture_io(fn -> assert :ok = CLI.run(["modes", "--json"]) end)
    decoded = Jason.decode!(output)

    assert %{"modes" => modes} = decoded
    assert Enum.any?(modes, &(&1["id"] == "tui"))
    assert Enum.any?(modes, &(&1["id"] == "wake"))
    assert Enum.any?(modes, &(&1["id"] == "meet"))
  end

  test "modes can print a mode playbook" do
    output = capture_io(fn -> assert :ok = CLI.run(["modes", "wake"]) end)

    assert output =~ "mode wake - External Wake"
    assert output =~ "entrypoint: jx wake --message <text> --project <name>"
    assert output =~ "checks:"
    assert output =~ "switch when:"
  end

  test "modes can print a mode playbook as JSON" do
    output = capture_io(fn -> assert :ok = CLI.run(["modes", "playbook", "wake", "--json"]) end)
    decoded = Jason.decode!(output)

    assert %{"playbook" => playbook} = decoded
    assert playbook["id"] == "wake"
    assert playbook["entrypoint"] == "jx wake --message <text> --project <name>"
    assert "wake" in playbook["available_modes"]
    assert is_list(playbook["checks"])
    assert is_list(playbook["switch_when"])
  end

  test "unknown mode playbook returns available modes" do
    assert {:error, message} = CLI.run(["modes", "unknown"])

    assert message =~ "unknown mode"
    assert message =~ "tui"
    assert message =~ "wake"
  end

  test "help modes prints focused usage" do
    output = capture_io(fn -> assert :ok = CLI.run(["help", "modes"]) end)

    assert output =~ "jx help modes"
    assert output =~ "jx modes [<mode>|playbook <mode>] [--json]"
  end

  test "fanout plan creates a run from the CLI" do
    root =
      Path.join(
        System.tmp_dir!(),
        "jx-fanout-cli-test-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)

    output =
      capture_io(fn ->
        assert :ok =
                 CLI.run([
                   "fanout",
                   "plan",
                   "test-coverage",
                   "--baseline",
                   "53907e03",
                   "--root",
                   root,
                   "--run-id",
                   "test-coverage-cli"
                 ])
      end)

    assert output =~ "fanout run planned"
    assert output =~ "auth-api-security"
    assert File.exists?(Path.join([root, "test-coverage-cli", "run_manifest.json"]))
  end

  test "help next prints focused usage" do
    output = capture_io(fn -> assert :ok = CLI.run(["help", "next"]) end)

    assert output =~ "jx help next"
    assert output =~ "jx next"
    assert output =~ "--no-observe"
  end

  test "tui plan prints the monitor loop" do
    output = capture_io(fn -> assert :ok = CLI.run(["tui", "plan"]) end)

    assert output =~ "jx TUI runbook"
    assert output =~ "monitor loop"
    assert output =~ "jx tui --no-observe"
  end

  test "tui snapshot prints a monitorable snapshot" do
    output =
      capture_io(fn ->
        assert :ok =
                 CLI.run([
                   "tui",
                   "snapshot",
                   "--no-observe",
                   "--consumer",
                   "cli-tui-test"
                 ])
      end)

    assert output =~ "jx TUI"
    assert output =~ "NEXT"
    assert output =~ "QUEUE"
    assert output =~ "DAEMON"
    assert output =~ "INBOX"
    assert output =~ "ACTIONS"
    refute output =~ "FIELD    VALUE"
  end

  test "tui opens the steering loop by default" do
    output =
      capture_io("q\n", fn ->
        assert :ok =
                 CLI.run([
                   "tui",
                   "--no-observe",
                   "--no-clear",
                   "--consumer",
                   "cli-tui-default-interactive-test"
                 ])
      end)

    assert output =~ "jx TUI"
    assert output =~ "STEER"
    assert output =~ "j/k move"
  end

  test "tui interactive remains an explicit steering alias" do
    output =
      capture_io("q\n", fn ->
        assert :ok =
                 CLI.run([
                   "tui",
                   "interactive",
                   "--no-observe",
                   "--no-clear",
                   "--consumer",
                   "cli-tui-interactive-test"
                 ])
      end)

    assert output =~ "jx TUI"
    assert output =~ "STEER"
    assert output =~ "j/k move"
    assert output =~ "d draft prompt"
    assert output =~ "s send confirmed prompt"
  end

  test "tui interactive rejects json mode" do
    assert {:error, message} = CLI.run(["tui", "interactive", "--json"])

    assert message =~ "cannot be combined with --json"
  end

  test "tui can print JSON" do
    output =
      capture_io(fn ->
        assert :ok =
                 CLI.run([
                   "tui",
                   "--no-observe",
                   "--consumer",
                   "cli-tui-json-test",
                   "--json"
                 ])
      end)

    decoded = Jason.decode!(output)

    assert decoded["monitor"]["consumer"] == "cli-tui-json-test"
    assert decoded["next"]["command"]
    assert Enum.any?(decoded["commands"], &(&1["label"] == "watch"))
  end

  test "tui panel prints a monitorable snapshot" do
    output =
      capture_io(fn ->
        assert :ok =
                 CLI.run([
                   "tui",
                   "panel",
                   "--no-observe",
                   "--consumer",
                   "cli-tui-panel-test"
                 ])
      end)

    assert output =~ "jx TUI"
    assert output =~ "NEXT"
    assert output =~ "QUEUE"
    refute output =~ "FIELD    VALUE"
  end

  test "tui watch prints one iteration" do
    output =
      capture_io(fn ->
        assert :ok =
                 CLI.run([
                   "tui",
                   "watch",
                   "--no-observe",
                   "--consumer",
                   "cli-tui-watch-test",
                   "--iterations",
                   "1"
                 ])
      end)

    assert output =~ "jx TUI"
    assert output =~ "NEXT"
    assert output =~ "QUEUE"
  end

  test "help wake prints focused usage" do
    output = capture_io(fn -> assert :ok = CLI.run(["help", "wake"]) end)

    assert output =~ "jx help wake"
    assert output =~ "jx wake --message <text>"
    assert output =~ "jx wake add --message <text>"
    assert output =~ "jx wake run-due"
  end

  test "help policy includes safety tiers" do
    output = capture_io(fn -> assert :ok = CLI.run(["help", "policy"]) end)

    assert output =~ "jx policy tiers [--json]"
  end

  test "policy tiers prints safety ladder" do
    output = capture_io(fn -> assert :ok = CLI.run(["policy", "tiers"]) end)

    assert output =~ "policy safety tiers"
    assert output =~ "inspect: Inspect Only"
    assert output =~ "held-release: Held Release Or Destructive Action"
  end

  test "policy tiers can print JSON" do
    output = capture_io(fn -> assert :ok = CLI.run(["policy", "tiers", "--json"]) end)
    decoded = Jason.decode!(output)

    assert %{"tiers" => tiers} = decoded
    assert Enum.any?(tiers, &(&1["id"] == "gated"))
    assert Enum.any?(tiers, &(&1["id"] == "held-release"))
  end

  test "unknown help group returns available groups" do
    assert {:error, message} = CLI.run(["help", "unknown"])

    assert message =~ "unknown help group"
    assert message =~ "available groups:"
    assert message =~ "ci"
    assert message =~ "sessions"
  end

  # ---------------------------------------------------------------------------
  # Dispatch path coverage for run/1
  # ---------------------------------------------------------------------------

  test "init starts the app and prints initialized" do
    output = capture_io(fn -> assert :ok = CLI.run(["init"]) end)
    assert output =~ "initialized"
  end

  test "cleanup without args returns usage error" do
    assert {:error, message} = CLI.run(["cleanup"])
    assert message =~ "usage:"
    assert message =~ "jx cleanup"
  end

  test "host without args returns usage error via HostCLI" do
    assert {:error, message} = CLI.run(["host"])
    assert message =~ "usage:"
    assert message =~ "jx host"
  end

  test "hosts without args returns usage error via HostCLI.run_plural" do
    assert {:error, message} = CLI.run(["hosts"])
    assert message =~ "usage:"
    assert message =~ "jx hosts"
  end

  test "project without args returns usage error via ProjectCLI" do
    assert {:error, message} = CLI.run(["project"])
    assert message =~ "usage:"
    assert message =~ "jx project"
  end

  test "promote without args returns usage error" do
    assert {:error, message} = CLI.run(["promote"])
    assert message =~ "usage:"
    assert message =~ "jx promote"
  end

  test "repo without args returns usage error" do
    assert {:error, message} = CLI.run(["repo"])
    assert message =~ "usage:"
    assert message =~ "jx repo"
  end

  test "session without args returns usage error via SessionCLI" do
    assert {:error, message} = CLI.run(["session"])
    assert message =~ "usage:"
    assert message =~ "jx session"
  end

  test "sessions ls delegates to SessionsCLI and returns ok" do
    output = capture_io(fn -> assert :ok = CLI.run(["sessions", "ls"]) end)
    assert output =~ "no runner sessions"
  end

  test "timeline without args returns usage error via TimelineCLI" do
    assert {:error, message} = CLI.run(["timeline"])
    assert message =~ "usage:"
    assert message =~ "jx timeline"
  end

  test "assignments without args returns usage error via AssignmentsCLI" do
    assert {:error, message} = CLI.run(["assignments"])
    assert message =~ "usage:"
    assert message =~ "jx assignments"
  end

  test "leases without args returns usage error via LeasesCLI" do
    assert {:error, message} = CLI.run(["leases"])
    assert message =~ "usage:"
    assert message =~ "jx leases"
  end

  test "approvals without args returns usage error via ApprovalsCLI" do
    assert {:error, message} = CLI.run(["approvals"])
    assert message =~ "usage:"
    assert message =~ "jx approvals"
  end

  test "actions without args returns usage error via ActionsCLI" do
    assert {:error, message} = CLI.run(["actions"])
    assert message =~ "usage:"
    assert message =~ "jx actions"
  end

  test "events without args returns usage error via EventsCLI" do
    assert {:error, message} = CLI.run(["events"])
    assert message =~ "usage:"
    assert message =~ "jx events"
  end

  test "agents without args returns usage error via AgentsCLI" do
    assert {:error, message} = CLI.run(["agents"])
    assert message =~ "usage:"
    assert message =~ "jx agents"
  end

  test "ci without args returns usage error" do
    assert {:error, message} = CLI.run(["ci"])
    assert message =~ "usage:"
    assert message =~ "jx ci"
  end

  test "watch without args returns usage error" do
    assert {:error, message} = CLI.run(["watch"])
    assert message =~ "usage:"
    assert message =~ "jx watch"
  end

  test "dashboard delegates to DashboardCLI and prints operator dashboard" do
    output = capture_io(fn -> assert :ok = CLI.run(["dashboard"]) end)
    assert output =~ "operator dashboard"
  end

  test "orchestrator without args returns usage error via OrchestratorCLI" do
    assert {:error, message} = CLI.run(["orchestrator"])
    assert message =~ "usage:"
    assert message =~ "jx orchestrator"
  end

  test "orchestrate without args returns usage error via OrchestrateCLI" do
    assert {:error, message} = CLI.run(["orchestrate"])
    assert message =~ "usage:"
    assert message =~ "jx orchestrate"
  end

  test "fanout without args returns usage error via FanoutCLI" do
    assert {:error, message} = CLI.run(["fanout"])
    assert message =~ "usage:"
    assert message =~ "jx fanout"
  end

  test "monitor without args returns usage error via MonitorCLI" do
    assert {:error, message} = CLI.run(["monitor"])
    assert message =~ "usage:"
    assert message =~ "jx monitor"
  end

  test "delegate without args returns usage error" do
    assert {:error, message} = CLI.run(["delegate"])
    assert message =~ "usage:"
    assert message =~ "jx delegate"
  end

  test "devide without args returns usage error via DevIDECLI" do
    assert {:error, message} = CLI.run(["devide"])
    assert message =~ "usage:"
    assert message =~ "jx devide"
  end

  test "unknown command returns top-level usage" do
    assert {:error, message} = CLI.run(["unknown"])
    assert message =~ "jx orchestrates durable SSH/tmux worktree sessions"
    assert message =~ "Usage:"
  end

  # ---------------------------------------------------------------------------
  # Success paths that do not require app start
  # ---------------------------------------------------------------------------

  test "version prints jx version" do
    output = capture_io(fn -> assert :ok = CLI.run(["version"]) end)
    assert output =~ "jx "
    refute output =~ "Error"
  end

  # ---------------------------------------------------------------------------
  # Error-path coverage for dispatch clauses (validation before start_app)
  # ---------------------------------------------------------------------------

  test "promote preflight without required flags returns usage error" do
    assert {:error, message} = CLI.run(["promote", "preflight", "my-project"])
    assert message =~ "usage:"
    assert message =~ "jx promote preflight"
  end

  test "promote run without required flags returns usage error" do
    assert {:error, message} = CLI.run(["promote", "run", "my-project"])
    assert message =~ "usage:"
    assert message =~ "jx promote run"
  end

  test "repo doctor without name returns usage error" do
    assert {:error, message} = CLI.run(["repo", "doctor"])
    assert message =~ "usage:"
    assert message =~ "jx repo doctor"
  end

  test "repo gate without name returns usage error" do
    assert {:error, message} = CLI.run(["repo", "gate"])
    assert message =~ "usage:"
    assert message =~ "jx repo gate"
  end

  test "ci digest without repo returns usage error" do
    assert {:error, message} = CLI.run(["ci", "digest", "123"])
    assert message =~ "usage:"
    assert message =~ "jx ci digest"
  end

  test "ci watch without repo returns usage error" do
    assert {:error, message} = CLI.run(["ci", "watch", "123"])
    assert message =~ "usage:"
    assert message =~ "jx ci watch"
  end

  test "ci review without watch_id returns usage error" do
    assert {:error, message} = CLI.run(["ci", "review"])
    assert message =~ "usage:"
    assert message =~ "jx ci review"
  end

  test "ci cancel without watch_id returns usage error" do
    assert {:error, message} = CLI.run(["ci", "cancel"])
    assert message =~ "usage:"
    assert message =~ "jx ci cancel"
  end

  test "call handoff add without summary returns usage error" do
    assert {:error, message} = CLI.run(["call", "handoff", "add"])
    assert message =~ "usage:"
    assert message =~ "jx call handoff add"
  end

  test "call handoff close without handoff_id returns usage error" do
    assert {:error, message} = CLI.run(["call", "handoff", "close"])
    assert message =~ "usage:"
    assert message =~ "jx call handoff close"
  end

  test "call handoff apply without handoff_id returns usage error" do
    assert {:error, message} = CLI.run(["call", "handoff", "apply"])
    assert message =~ "usage:"
    assert message =~ "jx call handoff apply"
  end

  test "call handoff without subcommand returns usage error" do
    assert {:error, message} = CLI.run(["call", "handoff"])
    assert message =~ "usage:"
    assert message =~ "jx call handoff"
  end

  test "call without subcommand returns usage error" do
    assert {:error, message} = CLI.run(["call"])
    assert message =~ "usage:"
    assert message =~ "jx call"
  end

  test "wake without message returns usage error" do
    assert {:error, message} = CLI.run(["wake"])
    assert message =~ "usage:"
    assert message =~ "jx wake"
  end

  test "wake add without message returns usage error" do
    assert {:error, message} = CLI.run(["wake", "add"])
    assert message =~ "usage:"
    assert message =~ "jx wake add"
  end

  test "wake add without schedule returns usage error" do
    assert {:error, message} = CLI.run(["wake", "add", "--message", "hello"])
    assert message =~ "usage:"
    assert message =~ "jx wake add"
  end

  test "wake remove without trigger_id returns usage error" do
    assert {:error, message} = CLI.run(["wake", "remove"])
    assert message =~ "usage:"
    assert message =~ "jx wake remove"
  end

  test "meet auth configure without client_id returns usage error" do
    assert {:error, message} = CLI.run(["meet", "auth", "configure"])
    assert message =~ "usage:"
    assert message =~ "jx meet auth configure"
  end

  test "meet auth exchange without code returns usage error" do
    assert {:error, message} = CLI.run(["meet", "auth", "exchange"])
    assert message =~ "usage:"
    assert message =~ "jx meet auth exchange"
  end

  test "meet session create without meeting returns meeting required error" do
    assert {:error, message} = CLI.run(["meet", "session", "create"])
    assert message =~ "--meeting"
  end

  test "meet session plan without session_id returns usage error" do
    assert {:error, message} = CLI.run(["meet", "session", "plan"])
    assert message =~ "usage:"
    assert message =~ "jx meet session plan"
  end

  test "meet session join without session_id returns usage error" do
    assert {:error, message} = CLI.run(["meet", "session", "join"])
    assert message =~ "usage:"
    assert message =~ "jx meet session join"
  end

  test "meet realtime plan without session_id returns usage error" do
    assert {:error, message} = CLI.run(["meet", "realtime", "plan"])
    assert message =~ "usage:"
    assert message =~ "jx meet realtime plan"
  end

  test "meet realtime start without session_id returns usage error" do
    assert {:error, message} = CLI.run(["meet", "realtime", "start"])
    assert message =~ "usage:"
    assert message =~ "jx meet realtime start"
  end

  test "meet realtime watch without session_id returns usage error" do
    assert {:error, message} = CLI.run(["meet", "realtime", "watch"])
    assert message =~ "usage:"
    assert message =~ "jx meet realtime watch"
  end

  test "meet realtime consult without session_id returns usage error" do
    assert {:error, message} = CLI.run(["meet", "realtime", "consult"])
    assert message =~ "usage:"
    assert message =~ "jx meet realtime consult"
  end

  test "meet recover without debug_url returns usage error" do
    assert {:error, message} = CLI.run(["meet", "recover"])
    assert message =~ "usage:"
    assert message =~ "jx meet recover"
  end

  test "meet sync without session_id returns usage error" do
    assert {:error, message} = CLI.run(["meet", "sync"])
    assert message =~ "usage:"
    assert message =~ "jx meet sync"
  end

  test "meet export without session_id returns usage error" do
    assert {:error, message} = CLI.run(["meet", "export"])
    assert message =~ "usage:"
    assert message =~ "jx meet export"
  end

  test "meet without subcommand returns usage error" do
    assert {:error, message} = CLI.run(["meet"])
    assert message =~ "usage:"
    assert message =~ "jx meet"
  end

  test "meet auth without subcommand returns usage error" do
    assert {:error, message} = CLI.run(["meet", "auth"])
    assert message =~ "usage:"
    assert message =~ "jx meet auth"
  end

  test "meet session without subcommand returns usage error" do
    assert {:error, message} = CLI.run(["meet", "session"])
    assert message =~ "usage:"
    assert message =~ "jx meet session"
  end

  test "meet realtime without subcommand returns usage error" do
    assert {:error, message} = CLI.run(["meet", "realtime"])
    assert message =~ "usage:"
    assert message =~ "jx meet realtime"
  end

  test "delegate create without title returns usage error" do
    assert {:error, message} = CLI.run(["delegate", "create", "--brief", "do something"])
    assert message =~ "usage:"
    assert message =~ "jx delegate create"
  end

  test "delegate brief without delegation_id returns usage error" do
    assert {:error, message} = CLI.run(["delegate", "brief"])
    assert message =~ "usage:"
    assert message =~ "jx delegate brief"
  end

  test "delegate lint without delegation_id returns usage error" do
    assert {:error, message} = CLI.run(["delegate", "lint"])
    assert message =~ "usage:"
    assert message =~ "jx delegate lint"
  end

  test "delegate review without delegation_id returns usage error" do
    assert {:error, message} = CLI.run(["delegate", "review"])
    assert message =~ "usage:"
    assert message =~ "jx delegate review"
  end

  test "delegate decide without decision returns usage error" do
    assert {:error, message} = CLI.run(["delegate", "decide", "d-123"])
    assert message =~ "usage:"
    assert message =~ "jx delegate decide"
  end

  test "delegate evidence without delegation_id returns usage error" do
    assert {:error, message} = CLI.run(["delegate", "evidence"])
    assert message =~ "usage:"
    assert message =~ "jx delegate evidence"
  end

  test "delegate start without delegation_id returns usage error" do
    assert {:error, message} = CLI.run(["delegate", "start"])
    assert message =~ "usage:"
    assert message =~ "jx delegate start"
  end

  test "delegate complete without delegation_id returns usage error" do
    assert {:error, message} = CLI.run(["delegate", "complete"])
    assert message =~ "usage:"
    assert message =~ "jx delegate complete"
  end

  test "delegate block without delegation_id returns usage error" do
    assert {:error, message} = CLI.run(["delegate", "block"])
    assert message =~ "usage:"
    assert message =~ "jx delegate block"
  end

  test "delegate fail without delegation_id returns usage error" do
    assert {:error, message} = CLI.run(["delegate", "fail"])
    assert message =~ "usage:"
    assert message =~ "jx delegate fail"
  end

  test "delegate cancel without delegation_id returns usage error" do
    assert {:error, message} = CLI.run(["delegate", "cancel"])
    assert message =~ "usage:"
    assert message =~ "jx delegate cancel"
  end

  test "assign without prompt returns usage error" do
    assert {:error, message} = CLI.run(["assign", "my-project"])
    assert message =~ "usage:"
    assert message =~ "jx assign"
  end

  test "directives without subcommand returns usage error" do
    assert {:error, message} = CLI.run(["directives"])
    assert message =~ "usage:"
    assert message =~ "jx directives"
  end

  test "operations without subcommand returns usage error" do
    assert {:error, message} = CLI.run(["operations"])
    assert message =~ "usage:"
    assert message =~ "jx operations"
  end

  test "runners without args returns usage error via RunnersCLI" do
    assert {:error, message} = CLI.run(["runners"])
    assert message =~ "usage:"
    assert message =~ "jx runners"
  end

  test "queue without args returns usage error via QueueCLI" do
    assert {:error, message} = CLI.run(["queue"])
    assert message =~ "usage:"
    assert message =~ "jx queue"
  end

  test "runtimes without args returns usage error via RuntimesCLI" do
    assert {:error, message} = CLI.run(["runtimes"])
    assert message =~ "usage:"
    assert message =~ "jx runtimes"
  end

  test "notifications without subcommand returns usage error" do
    assert {:error, message} = CLI.run(["notifications"])
    assert message =~ "usage:"
    assert message =~ "jx notifications"
  end

  test "notifications ack without id or --all returns usage error" do
    assert {:error, message} = CLI.run(["notifications", "ack"])
    assert message =~ "jx notifications ack requires <notification-id> or --all"
  end

  test "policy check without action returns usage error" do
    assert {:error, message} = CLI.run(["policy", "check"])
    assert message =~ "usage:"
    assert message =~ "jx policy check"
  end

  test "policy without subcommand returns usage error" do
    assert {:error, message} = CLI.run(["policy"])
    assert message =~ "usage:"
    assert message =~ "jx policy"
  end

  test "controls without subcommand returns usage error" do
    assert {:error, message} = CLI.run(["controls"])
    assert message =~ "usage:"
    assert message =~ "jx controls"
  end

  test "watch add without ref returns usage error" do
    assert {:error, message} = CLI.run(["watch", "add"])
    assert message =~ "usage:"
    assert message =~ "jx watch add"
  end

  test "watch add without goal returns watch pattern error" do
    assert {:error, message} = CLI.run(["watch", "add", "my-ref"])
    assert message =~ "watch requires --success and/or --blocker pattern"
  end

  test "watch review without watch_id returns usage error" do
    assert {:error, message} = CLI.run(["watch", "review"])
    assert message =~ "usage:"
    assert message =~ "jx watch review"
  end

  test "watch complete without watch_id returns usage error" do
    assert {:error, message} = CLI.run(["watch", "complete"])
    assert message =~ "usage:"
    assert message =~ "jx watch complete"
  end

  test "watch cancel without watch_id returns usage error" do
    assert {:error, message} = CLI.run(["watch", "cancel"])
    assert message =~ "usage:"
    assert message =~ "jx watch cancel"
  end

  test "operator without subcommand returns usage error" do
    assert {:error, message} = CLI.run(["operator"])
    assert message =~ "usage:"
    assert message =~ "jx operator"
  end

  test "remote without subcommand returns usage error" do
    assert {:error, message} = CLI.run(["remote"])
    assert message =~ "usage:"
    assert message =~ "jx remote"
  end

  test "tmux without args returns usage error via TmuxCLI" do
    assert {:error, message} = CLI.run(["tmux"])
    assert message =~ "usage:"
    assert message =~ "jx tmux"
  end

  test "ssh without args returns usage error via SSHCLI" do
    assert {:error, message} = CLI.run(["ssh"])
    assert message =~ "usage:"
    assert message =~ "jx ssh"
  end

  test "task adopt-tmux without project returns usage error" do
    assert {:error, message} = CLI.run(["task", "adopt-tmux"])
    assert message =~ "usage:"
    assert message =~ "jx task adopt-tmux"
  end

  test "task adopt-activity without project returns usage error" do
    assert {:error, message} = CLI.run(["task", "adopt-activity"])
    assert message =~ "usage:"
    assert message =~ "jx task adopt-activity"
  end

  test "task send without message returns usage error" do
    assert {:error, message} = CLI.run(["task", "send", "t-123"])
    assert message =~ "usage:"
    assert message =~ "jx task send"
  end

  test "task without subcommand returns usage error" do
    assert {:error, message} = CLI.run(["task"])
    assert message =~ "usage:"
    assert message =~ "jx task"
    assert message =~ "jx task reconcile"
  end

  test "attach without task_id returns top-level usage" do
    assert {:error, message} = CLI.run(["attach"])
    assert message =~ "jx orchestrates durable SSH/tmux worktree sessions"
    assert message =~ "Usage:"
  end

  test "logs without task_id returns top-level usage" do
    assert {:error, message} = CLI.run(["logs"])
    assert message =~ "jx orchestrates durable SSH/tmux worktree sessions"
    assert message =~ "Usage:"
  end

  test "stop without task_id returns top-level usage" do
    assert {:error, message} = CLI.run(["stop"])
    assert message =~ "jx orchestrates durable SSH/tmux worktree sessions"
    assert message =~ "Usage:"
  end

  test "process ls returns ok" do
    output =
      capture_io(fn ->
        assert :ok = CLI.run(["process", "ls"])
      end)

    # When processes exist, a table is printed; otherwise "no processes".
    # We only assert that the dispatch clause was exercised.
    assert is_binary(output)
  end

  test "process without subcommand returns usage error" do
    assert {:error, message} = CLI.run(["process"])
    assert message =~ "usage:"
    assert message =~ "jx process"
  end

  test "portfolio without subcommand returns usage error" do
    assert {:error, message} = CLI.run(["portfolio"])
    assert message =~ "usage:"
    assert message =~ "jx portfolio"
  end

  test "status delegates to Workspace and prints statuses" do
    output = capture_io(fn -> assert :ok = CLI.run(["status"]) end)
    # Output varies depending on DB state; assert the dispatch clause ran
    assert is_binary(output)
  end

  test "directives ls delegates and prints directives" do
    output = capture_io(fn -> assert :ok = CLI.run(["directives", "ls"]) end)
    assert output =~ "no directives"
  end

  test "operations ls delegates and prints operations" do
    output = capture_io(fn -> assert :ok = CLI.run(["operations", "ls"]) end)
    assert output =~ "no operation executions"
  end

  test "notifications ls delegates and prints notifications" do
    output = capture_io(fn -> assert :ok = CLI.run(["notifications", "ls"]) end)
    assert output =~ "no notifications"
  end

  test "notifications compact delegates and compacts notifications" do
    output = capture_io(fn -> assert :ok = CLI.run(["notifications", "compact"]) end)
    assert output =~ "dismissed"
  end

  test "controls ls delegates and prints controls" do
    output = capture_io(fn -> assert :ok = CLI.run(["controls", "ls"]) end)
    assert output =~ "no session controls"
  end

  test "watch ls delegates and prints watches" do
    output = capture_io(fn -> assert :ok = CLI.run(["watch", "ls"]) end)
    assert output =~ "no session watches"
  end

  test "remote ls delegates and prints remote observations" do
    output = capture_io(fn -> assert :ok = CLI.run(["remote", "ls"]) end)
    assert output =~ "no remote session observations"
  end

  test "discover delegates and prints discovery report" do
    output = capture_io(fn -> assert :ok = CLI.run(["discover"]) end)
    assert output =~ "no active sessions"
  end

  test "activity delegates and prints activity report" do
    output = capture_io(fn -> assert :ok = CLI.run(["activity"]) end)
    assert is_binary(output)
  end

  test "call brief delegates and prints brief" do
    output = capture_io(fn -> assert :ok = CLI.run(["call", "brief"]) end)
    assert output =~ "call brief"
  end

  test "call handoff ls delegates and prints handoffs" do
    output = capture_io(fn -> assert :ok = CLI.run(["call", "handoff", "ls"]) end)
    assert output =~ "no call handoffs"
  end

  test "next delegates and prints next step" do
    output = capture_io(fn -> assert :ok = CLI.run(["next"]) end)
    assert output =~ "next"
  end

  test "operate delegates and prints operation" do
    output = capture_io(fn -> assert :ok = CLI.run(["operate"]) end)
    assert output =~ "generated"
  end

  test "manage delegates and prints manage report" do
    output = capture_io(fn -> assert :ok = CLI.run(["manage"]) end)
    assert output =~ "manage policy conservative"
  end

  test "work delegates to work board and prints items" do
    output = capture_io(fn -> assert :ok = CLI.run(["work"]) end)
    assert is_binary(output)
  end

  test "work ls delegates to work board and prints items" do
    output = capture_io(fn -> assert :ok = CLI.run(["work", "ls"]) end)
    assert is_binary(output)
  end

  test "portfolio summary delegates and prints summary" do
    output = capture_io(fn -> assert :ok = CLI.run(["portfolio", "summary"]) end)
    assert output =~ "portfolio summary"
  end

  test "ci watches delegates and prints watches" do
    output = capture_io(fn -> assert :ok = CLI.run(["ci", "watches"]) end)
    assert output =~ "no CI watches"
  end

  test "meet plugin delegates and prints plugin info" do
    output = capture_io(fn -> assert :ok = CLI.run(["meet", "plugin"]) end)
    assert output =~ "meet plugin"
    assert output =~ "google_meet"
  end

  test "meet auth url returns error when no profile exists" do
    assert {:error, _reason} = CLI.run(["meet", "auth", "url"])
  end

  test "meet auth status delegates and prints profiles" do
    output = capture_io(fn -> assert :ok = CLI.run(["meet", "auth", "status"]) end)
    assert output =~ "no Meet auth profiles"
  end

  test "meet session ls delegates and prints sessions" do
    output = capture_io(fn -> assert :ok = CLI.run(["meet", "session", "ls"]) end)
    assert output =~ "no Meet sessions"
  end

  test "delegate ls delegates and prints delegations" do
    output = capture_io(fn -> assert :ok = CLI.run(["delegate", "ls"]) end)
    assert output =~ "no delegations"
  end

  test "delegate reviews delegates and prints reviews" do
    output = capture_io(fn -> assert :ok = CLI.run(["delegate", "reviews"]) end)
    assert output =~ "no delegation reviews"
  end

  test "delegate timing delegates and prints timing" do
    output = capture_io(fn -> assert :ok = CLI.run(["delegate", "timing"]) end)
    assert output =~ "delegation timing"
  end

  test "operator profile delegates and prints profile" do
    output = capture_io(fn -> assert :ok = CLI.run(["operator", "profile"]) end)
    assert is_binary(output)
  end

  test "operator profile set delegates and prints profile" do
    output = capture_io(fn -> assert :ok = CLI.run(["operator", "profile", "set"]) end)
    assert is_binary(output)
  end
end
