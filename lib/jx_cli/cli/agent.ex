defmodule JX.CLI.Agent do
  @moduledoc """
  CLI handler for the Agent Protocol.

  Commands external agents (Claude, Cursor, Aider, etc.) use to interact with
  jx. Every command routes through `JX.Workspace`, the policy boundary, so the
  CLI never bypasses safety or writes durable records directly.

  Adapters implementing `JX.Agent.Protocol` are the long-term home for this
  behaviour; today these commands call `Workspace` directly.
  """

  import JX.CLI.Support, only: [expect_no_args: 2, print_json: 1]

  alias JX.Workspace

  @report_usage "jx agent report --session <id> [--kind observation|error|progress] --text <text> [--json]"
  @request_approval_usage "jx agent request-approval --action <command> --reason <text> [--risk low|medium|high] [--json]"
  @status_usage "jx agent status [--project <name>] [--json]"
  @handoff_usage "jx agent handoff --to <operator|agent> --summary <text> [--context-ref <id>] [--json]"

  @risk_to_severity %{"low" => "notice", "medium" => "warning", "high" => "critical"}

  def usage do
    "#{@report_usage} | #{@request_approval_usage} | #{@status_usage} | #{@handoff_usage}"
  end

  def usage_lines do
    [@report_usage, @request_approval_usage, @status_usage, @handoff_usage]
  end

  def run(["report" | _args], _opts) do
    # `report` has no honest durable home yet: delegation evidence requires a
    # command/cwd/exit_status (it is execution evidence, not a freeform note),
    # and session observations are snapshot-based. Returning an error is more
    # truthful than fabricating an observation id. See docs/architecture-evolution.md.
    {:error,
     "jx agent report is not yet implemented — needs a durable agent-observation primitive " <>
       "(tracked in docs/architecture-evolution.md). Use `jx agent request-approval` or " <>
       "`jx agent handoff` to record durable items today."}
  end

  def run(["request-approval" | args], opts) do
    {parsed, rest, _invalid} =
      OptionParser.parse(args,
        strict: [action: :string, reason: :string, risk: :string, json: :boolean]
      )

    with :ok <- expect_no_args(rest, @request_approval_usage),
         :ok <- require_flag(parsed[:action], "action"),
         :ok <- require_flag(parsed[:reason], "reason"),
         :ok <- start_app(opts) do
      risk = parsed[:risk] || "medium"

      workspace(opts).create_approval(%{
        kind: "agent_request",
        source: "agent",
        target_ref: parsed[:action],
        summary: parsed[:reason],
        severity: severity_for_risk(risk),
        metadata: %{action: parsed[:action], reason: parsed[:reason], risk: risk}
      })
      |> render_approval(parsed[:json], fn approval ->
        IO.puts("Approval requested (id: #{approval.approval_id})")
        IO.puts("Action: #{approval.target_ref}")
      end)
    end
  end

  def run(["handoff" | args], opts) do
    {parsed, rest, _invalid} =
      OptionParser.parse(args,
        strict: [to: :string, summary: :string, context_ref: :string, json: :boolean]
      )

    with :ok <- expect_no_args(rest, @handoff_usage),
         :ok <- require_flag(parsed[:to], "to"),
         :ok <- require_flag(parsed[:summary], "summary"),
         :ok <- start_app(opts) do
      workspace(opts).create_approval(%{
        kind: "agent_handoff",
        source: "agent",
        target_ref: parsed[:to],
        summary: parsed[:summary],
        severity: "warning",
        metadata: %{to: parsed[:to], summary: parsed[:summary], context_ref: parsed[:context_ref]}
      })
      |> render_approval(parsed[:json], fn approval ->
        IO.puts("Handoff recorded to #{parsed[:to]} (id: #{approval.approval_id})")
      end)
    end
  end

  def run(["status" | args], opts) do
    {parsed, rest, _invalid} =
      OptionParser.parse(args, strict: [project: :string, json: :boolean])

    with :ok <- expect_no_args(rest, @status_usage),
         :ok <- start_app(opts) do
      ws = workspace(opts)
      summary = ws.approval_summary()

      result = %{
        project: parsed[:project] || "all",
        open_approvals: Map.get(summary, :open_total, 0),
        active_approvals: Map.get(summary, :active_total, 0),
        agents: length(ws.list_agents()),
        delegations: length(ws.list_delegations())
      }

      if parsed[:json] do
        print_json(result)
      else
        IO.puts("Agent view for project: #{result.project}")
        IO.puts("Open approvals: #{result.open_approvals}")
        IO.puts("Active approvals: #{result.active_approvals}")
        IO.puts("Registered agents: #{result.agents}")
        IO.puts("Delegations: #{result.delegations}")
      end

      :ok
    end
  end

  def run(_args, _opts) do
    IO.puts("Usage: #{usage()}")
    :ok
  end

  defp render_approval({:ok, :duplicate}, json?, _human) do
    if json?, do: print_json(%{status: "duplicate"}), else: IO.puts("Duplicate of an open item.")
    :ok
  end

  defp render_approval({:ok, approval}, json?, human) do
    if json? do
      print_json(%{
        status: "open",
        approval_id: approval.approval_id,
        kind: approval.kind,
        severity: approval.severity
      })
    else
      human.(approval)
    end

    :ok
  end

  defp render_approval({:error, reason}, _json?, _human) do
    {:error, "could not record approval: #{inspect(reason)}"}
  end

  defp severity_for_risk(risk), do: Map.get(@risk_to_severity, risk, "warning")

  defp workspace(opts), do: Keyword.get(opts, :workspace, Workspace)

  defp require_flag(nil, name), do: {:error, "missing required --#{name}"}
  defp require_flag(_, _), do: :ok

  defp start_app(opts) do
    case Keyword.fetch(opts, :start_app) do
      {:ok, start_app} -> start_app.()
      :error -> {:error, :missing_start_app_callback}
    end
  end
end
