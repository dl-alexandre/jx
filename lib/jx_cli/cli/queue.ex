defmodule JX.CLI.Queue do
  @moduledoc false

  alias JX.Workspace

  import JX.CLI.Support,
    only: [expect_no_args: 2, print_json: 1, print_table: 2, validate_options: 1]

  @queue_ls_usage "jx queue ls [--kind workspace|blocker|approval|action|lease|agent|runner|assignment|session] [--workspace <id>] [--owner <owner>] [--risk blocked|stale|risky|awaiting_operator] [--freshness fresh|stale|unknown] [--sort urgency|freshness|owner|risk] [--stale-after-seconds 900] [-n 50] [--json]"
  @queue_workspace_usage "jx queue workspace <workspace-id> [--json]"
  @queue_rebuild_usage "jx queue rebuild [--json]"

  def usage_lines do
    [
      @queue_ls_usage,
      @queue_workspace_usage,
      @queue_rebuild_usage
    ]
  end

  def usage, do: Enum.join(usage_lines(), " | ")

  def run(["ls" | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          kind: :string,
          workspace: :string,
          owner: :string,
          risk: :string,
          freshness: :string,
          sort: :string,
          stale_after_seconds: :integer,
          n: :integer,
          json: :boolean
        ],
        aliases: [n: :n]
      )

    limit = parsed[:n] || 50

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @queue_ls_usage),
         :ok <- validate_optional_queue_kind(parsed[:kind]),
         :ok <- validate_optional_queue_risk(parsed[:risk]),
         :ok <- validate_optional_freshness(parsed[:freshness]),
         :ok <- validate_optional_queue_sort(parsed[:sort]),
         :ok <- validate_positive("n", limit),
         :ok <- validate_optional_positive("stale-after-seconds", parsed[:stale_after_seconds]),
         :ok <- start_app(opts) do
      workspace(opts)
      |> apply(:operational_queue, [
        [
          kind: parsed[:kind],
          workspace_id: parsed[:workspace],
          owner: parsed[:owner],
          risk: parsed[:risk],
          freshness: parsed[:freshness],
          sort: parsed[:sort],
          stale_after_seconds: parsed[:stale_after_seconds] || 15 * 60,
          limit: limit
        ]
      ])
      |> print_queue(json: parsed[:json] || false)

      :ok
    end
  end

  def run(["workspace", workspace_id | args], opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args, strict: [stale_after_seconds: :integer, json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @queue_workspace_usage),
         :ok <- validate_optional_positive("stale-after-seconds", parsed[:stale_after_seconds]),
         :ok <- start_app(opts) do
      workspace(opts)
      |> apply(:operational_workspace, [
        workspace_id,
        [stale_after_seconds: parsed[:stale_after_seconds] || 15 * 60]
      ])
      |> print_queue_workspace(json: parsed[:json] || false)

      :ok
    end
  end

  def run(["rebuild" | args], opts) do
    {parsed, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @queue_rebuild_usage),
         :ok <- start_app(opts) do
      workspace(opts)
      |> apply(:operational_rebuilt_state, [])
      |> print_rebuilt_state(json: parsed[:json] || false)

      :ok
    end
  end

  def run(_args, _opts), do: {:error, "usage: #{usage()}"}

  defp workspace(opts), do: Keyword.get(opts, :workspace, Workspace)

  defp start_app(opts) do
    case Keyword.fetch(opts, :start_app) do
      {:ok, start_app} -> start_app.()
      :error -> {:error, :missing_start_app_callback}
    end
  end

  defp validate_positive(_name, value) when is_integer(value) and value > 0, do: :ok
  defp validate_positive(name, _value), do: {:error, "#{name} must be a positive integer"}

  defp validate_optional_positive(_name, nil), do: :ok
  defp validate_optional_positive(name, value), do: validate_positive(name, value)

  defp validate_optional_queue_kind(nil), do: :ok

  defp validate_optional_queue_kind(kind)
       when kind in ~w(workspace blocker approval action lease agent runner assignment session),
       do: :ok

  defp validate_optional_queue_kind(kind),
    do:
      {:error,
       "unsupported queue kind #{inspect(kind)}; expected workspace, blocker, approval, action, lease, agent, runner, assignment, or session"}

  defp validate_optional_queue_risk(nil), do: :ok

  defp validate_optional_queue_risk(risk)
       when risk in ~w(blocked stale risky awaiting_operator healthy),
       do: :ok

  defp validate_optional_queue_risk(risk),
    do:
      {:error,
       "unsupported queue risk #{inspect(risk)}; expected blocked, stale, risky, awaiting_operator, or healthy"}

  defp validate_optional_freshness(nil), do: :ok
  defp validate_optional_freshness(freshness) when freshness in ~w(fresh stale unknown), do: :ok

  defp validate_optional_freshness(freshness),
    do: {:error, "unsupported freshness #{inspect(freshness)}; expected fresh, stale, or unknown"}

  defp validate_optional_queue_sort(nil), do: :ok
  defp validate_optional_queue_sort(sort) when sort in ~w(urgency freshness owner risk), do: :ok

  defp validate_optional_queue_sort(sort),
    do:
      {:error,
       "unsupported queue sort #{inspect(sort)}; expected urgency, freshness, owner, or risk"}

  defp print_queue(queue, opts) do
    if opts[:json] do
      print_json(queue)
    else
      IO.puts("attention queue")
      IO.puts("generated: #{format_time(queue.generated_at)}")
      IO.puts("stale_after_seconds: #{queue.stale_after_seconds}")
      print_summary_counts("queue totals", queue.totals)

      rows =
        Enum.map(queue.items, fn item ->
          [
            item.type,
            item.id,
            item.risk,
            item.reason,
            item.freshness,
            item.urgency,
            blank_to_dash(item.owner),
            blank_to_dash(item.workspace_id),
            truncate(item.summary, 72),
            item.next
          ]
        end)

      if rows == [] do
        IO.puts("")
        IO.puts("no attention items")
      else
        IO.puts("")

        print_table(
          [
            "TYPE",
            "ID",
            "RISK",
            "REASON",
            "FRESH",
            "URG",
            "OWNER",
            "WORKSPACE",
            "SUMMARY",
            "NEXT"
          ],
          rows
        )
      end
    end
  end

  defp print_queue_workspace(report, opts) do
    if opts[:json] do
      print_json(report)
    else
      IO.puts("workspace queue #{report.workspace_id}")
      IO.puts("generated: #{format_time(report.generated_at)}")
      print_summary_counts("health", Map.take(report.health, [:status, :freshness, :risk]))

      print_queue_workspace_list("approvals", report.approvals, [
        :approval_id,
        :kind,
        :severity,
        :freshness,
        :owner
      ])

      print_queue_workspace_list("actions", report.actions, [
        :action_id,
        :action,
        :status,
        :outcome,
        :owner
      ])

      print_queue_workspace_list("leases", report.leases, [
        :lease_id,
        :resource_type,
        :resource_id,
        :owner,
        :status
      ])

      IO.puts("")
      IO.puts("next")
      IO.puts("  approvals: #{report.next.approvals}")
      IO.puts("  devide_status: #{report.next.devide_status}")
      IO.puts("  timeline: #{report.next.timeline}")
    end
  end

  defp print_queue_workspace_list(label, [], _fields) do
    IO.puts("")
    IO.puts("#{label}: none")
  end

  defp print_queue_workspace_list(label, items, fields) do
    IO.puts("")
    IO.puts(label)

    rows =
      Enum.map(items, fn item ->
        Enum.map(fields, fn field -> item |> Map.get(field, "") |> blank_to_dash() end)
      end)

    headers = Enum.map(fields, &(&1 |> Atom.to_string() |> String.upcase()))
    print_table(headers, rows)
  end

  defp print_rebuilt_state(report, opts) do
    if opts[:json] do
      print_json(report)
    else
      IO.puts("rebuilt operational state")
      IO.puts("events: #{report.events}")
      print_summary_counts("queue", report.queue)
    end
  end

  defp print_summary_counts(name, counts) do
    rows =
      counts
      |> Enum.flat_map(fn
        {key, %_struct{} = value} ->
          [[to_string(key), "", to_string(value)]]

        {key, value} when is_map(value) ->
          value
          |> Enum.map(fn {nested_key, nested_value} ->
            [to_string(key), to_string(nested_key), summary_value(nested_value)]
          end)

        {key, value} when is_integer(value) ->
          [[to_string(key), "", Integer.to_string(value)]]

        {key, value} when is_boolean(value) ->
          [[to_string(key), "", format_bool(value)]]

        {key, value} when is_binary(value) ->
          [[to_string(key), "", value]]

        _other ->
          []
      end)

    IO.puts(name)
    print_table(["METRIC", "KEY", "VALUE"], rows)
  end

  defp summary_value(value) when is_integer(value), do: Integer.to_string(value)
  defp summary_value(value) when is_boolean(value), do: format_bool(value)
  defp summary_value(value) when is_binary(value), do: value
  defp summary_value(%_struct{} = value), do: to_string(value)
  defp summary_value(nil), do: ""
  defp summary_value(value), do: inspect(value)

  defp format_bool(true), do: "yes"
  defp format_bool(false), do: "no"

  defp format_time(nil), do: "-"
  defp format_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_time(value) when is_binary(value), do: if(value == "", do: "-", else: value)

  defp blank_to_dash(value) when value in [nil, ""], do: "-"
  defp blank_to_dash(value), do: to_string(value)

  defp truncate(value, max_length) do
    value = blank_to_dash(value)

    if String.length(value) > max_length do
      String.slice(value, 0, max_length - 1) <> "..."
    else
      value
    end
  end
end
