defmodule JX.CLI.Recap do
  @moduledoc false

  alias JX.Workspace

  import JX.CLI.Support, only: [expect_no_args: 2, print_json: 1, validate_options: 1]

  @usage "jx recap [--days 7 | --since <iso8601>] [--until <iso8601>] [-n 10] [--json]"
  @week_usage "jx week [same options as recap]"

  def usage, do: @usage
  def usage_lines, do: [@usage, @week_usage]

  def run(args, opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [days: :integer, since: :string, until: :string, n: :integer, json: :boolean],
        aliases: [n: :n]
      )

    days = parsed[:days] || 7
    limit = parsed[:n] || 10

    with :ok <- validate_options(invalid),
         :ok <- expect_no_args(rest, @usage),
         :ok <- validate_positive("days", days),
         :ok <- validate_positive("n", limit),
         {:ok, since} <- parse_optional_time(parsed[:since], "since"),
         {:ok, until_at} <- parse_optional_time(parsed[:until], "until"),
         :ok <- start_app(opts) do
      report =
        workspace(opts).recap(
          days: days,
          since: since,
          until: until_at,
          limit: limit
        )

      print_recap(report, json: parsed[:json] || false)
      :ok
    end
  end

  defp print_recap(report, json: true), do: print_json(json_ready(report))

  defp print_recap(report, json: false) do
    IO.puts("jx recap")
    IO.puts("window: #{format_time(report.since)} -> #{format_time(report.until)}")
    IO.puts("")
    IO.puts("tasks: #{report.tasks.total} #{count_line(report.tasks.by_status)}")
    IO.puts("  hosts: #{count_line(report.tasks.by_host)}")
    IO.puts("  projects: #{count_line(report.tasks.by_project)}")
    IO.puts("  agents: #{count_line(report.tasks.by_agent)}")
    IO.puts("directives: #{report.directives.total} #{count_line(report.directives.by_status)}")
    IO.puts("  hosts: #{count_line(report.directives.by_host)}")
    IO.puts("resources: #{report.resources.total} #{count_line(report.resources.by_type)}")
    IO.puts("handoffs: #{report.handoffs.total} #{count_line(report.handoffs.by_status)}")

    IO.puts(
      "session profiles: #{report.session_profiles.total} #{count_line(report.session_profiles.by_prompt_status)}"
    )

    IO.puts(
      "operational events: #{report.operational_events.total} #{count_line(report.operational_events.by_severity)}"
    )

    print_latest_tasks(report.tasks.latest)
  end

  defp print_latest_tasks([]), do: :ok

  defp print_latest_tasks(tasks) do
    IO.puts("")
    IO.puts("recent tasks")

    Enum.each(tasks, fn task ->
      IO.puts(
        "  - #{format_time(task.updated_at)} #{task.task_id} #{task.status} #{task.host}/#{task.project} #{task.agent} #{task.branch}"
      )
    end)
  end

  defp count_line(counts) when counts == %{}, do: "-"

  defp count_line(counts) do
    counts
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> "#{key}:#{value}" end)
    |> Enum.join(" ")
  end

  defp parse_optional_time(nil, _name), do: {:ok, nil}

  defp parse_optional_time(value, name) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      {:error, _reason} ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive} -> {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
          {:error, _reason} -> {:error, "#{name} must be ISO8601"}
        end
    end
  end

  defp validate_positive(_name, value) when is_integer(value) and value > 0, do: :ok
  defp validate_positive(name, _value), do: {:error, "#{name} must be a positive integer"}

  defp json_ready(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_ready(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp json_ready(values) when is_list(values), do: Enum.map(values, &json_ready/1)

  defp json_ready(%{} = map) do
    Map.new(map, fn {key, value} -> {key, json_ready(value)} end)
  end

  defp json_ready(value), do: value

  defp format_time(nil), do: "-"
  defp format_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_time(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp format_time(value) when is_binary(value), do: if(value == "", do: "-", else: value)

  defp workspace(opts), do: Keyword.get(opts, :workspace, Workspace)

  defp start_app(opts) do
    case Keyword.fetch(opts, :start_app) do
      {:ok, start_app} -> start_app.()
      :error -> {:error, :missing_start_app_callback}
    end
  end
end
