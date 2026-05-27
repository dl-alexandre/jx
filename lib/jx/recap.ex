defmodule JX.Recap do
  @moduledoc """
  Builds an operator recap from durable state, not only operational events.
  """

  import Ecto.Query

  alias JX.CallHandoffs.CallHandoff
  alias JX.Directives.Directive
  alias JX.Hosts.Host
  alias JX.OperationalEvents.Event, as: OperationalEvent
  alias JX.Projects.Project
  alias JX.Repo
  alias JX.ResourceOwnerships.Resource
  alias JX.SessionProfiles.SessionProfile
  alias JX.Tasks.Task

  @default_days 7
  @default_limit 10

  def run(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    {since, until_at} = time_window(opts, now)
    limit = Keyword.get(opts, :limit, @default_limit)

    %{
      generated_at: now,
      since: since,
      until: until_at,
      days: Keyword.get(opts, :days, @default_days),
      tasks: task_summary(since, until_at, limit),
      directives: directive_summary(since, until_at, limit),
      resources: resource_summary(since, until_at),
      handoffs: handoff_summary(since, until_at, limit),
      session_profiles: profile_summary(since, until_at, limit),
      operational_events: event_summary(since, until_at, limit)
    }
  end

  defp time_window(opts, now) do
    until_at = Keyword.get(opts, :until) || now
    since = Keyword.get(opts, :since) || DateTime.add(until_at, -days(opts) * 86_400, :second)
    {since, until_at}
  end

  defp days(opts), do: Keyword.get(opts, :days, @default_days)

  defp task_summary(since, until_at, limit) do
    base = task_window(since, until_at)

    %{
      total: Repo.aggregate(base, :count),
      by_status: count_by(base, :status),
      by_agent: count_by(base, :agent_name),
      by_project: task_count_by_project(base),
      by_host: task_count_by_host(base),
      latest: latest_tasks(base, limit)
    }
  end

  defp directive_summary(since, until_at, limit) do
    base = directive_window(since, until_at)

    %{
      total: Repo.aggregate(base, :count),
      by_status: count_by(base, :status),
      by_host: directive_count_by_host(base),
      latest: latest_directives(base, limit)
    }
  end

  defp resource_summary(since, until_at) do
    base = resource_window(since, until_at)

    %{
      total: Repo.aggregate(base, :count),
      by_type: count_by(base, :resource_type),
      by_state: count_by(base, :state),
      by_project: count_by(base, :owner_project)
    }
  end

  defp handoff_summary(since, until_at, limit) do
    base = timestamp_window(CallHandoff, since, until_at)

    %{
      total: Repo.aggregate(base, :count),
      by_status: count_by(base, :status),
      by_surface: count_by(base, :surface),
      latest: latest_handoffs(base, limit)
    }
  end

  defp profile_summary(since, until_at, limit) do
    base = timestamp_window(SessionProfile, since, until_at)

    %{
      total: Repo.aggregate(base, :count),
      by_prompt_status: count_by(base, :prompt_status),
      by_lifecycle: count_by(base, :lifecycle_status),
      by_risk: count_by(base, :risk_level),
      latest: latest_profiles(base, limit)
    }
  end

  defp event_summary(since, until_at, limit) do
    base = inserted_window(OperationalEvent, since, until_at)

    %{
      total: Repo.aggregate(base, :count),
      by_kind: count_by(base, :kind),
      by_severity: count_by(base, :severity),
      latest: latest_events(base, limit)
    }
  end

  defp task_window(since, until_at) do
    from(t in Task,
      where:
        (t.inserted_at >= ^since and t.inserted_at <= ^until_at) or
          (t.updated_at >= ^since and t.updated_at <= ^until_at)
    )
  end

  defp directive_window(since, until_at) do
    from(d in Directive,
      where:
        (d.inserted_at >= ^since and d.inserted_at <= ^until_at) or
          (d.updated_at >= ^since and d.updated_at <= ^until_at)
    )
  end

  defp resource_window(since, until_at) do
    from(r in Resource,
      where:
        (r.created_at >= ^since and r.created_at <= ^until_at) or
          (r.inserted_at >= ^since and r.inserted_at <= ^until_at) or
          (r.updated_at >= ^since and r.updated_at <= ^until_at)
    )
  end

  defp timestamp_window(schema, since, until_at) do
    from(row in schema,
      where:
        (row.inserted_at >= ^since and row.inserted_at <= ^until_at) or
          (row.updated_at >= ^since and row.updated_at <= ^until_at)
    )
  end

  defp inserted_window(schema, since, until_at) do
    from(row in schema, where: row.inserted_at >= ^since and row.inserted_at <= ^until_at)
  end

  defp count_by(query, field_name) do
    query
    |> group_by([row], field(row, ^field_name))
    |> select([row], {field(row, ^field_name), count(row.id)})
    |> Repo.all()
    |> count_map()
  end

  defp task_count_by_project(base) do
    from(t in base,
      left_join: p in Project,
      on: p.id == t.project_id,
      group_by: p.name,
      select: {p.name, count(t.id)}
    )
    |> Repo.all()
    |> count_map()
  end

  defp task_count_by_host(base) do
    from(t in base,
      left_join: h in Host,
      on: h.id == t.host_id,
      group_by: h.name,
      select: {h.name, count(t.id)}
    )
    |> Repo.all()
    |> count_map()
  end

  defp directive_count_by_host(base) do
    from(d in base,
      left_join: h in Host,
      on: h.id == d.host_id,
      group_by: h.name,
      select: {h.name, count(d.id)}
    )
    |> Repo.all()
    |> count_map()
  end

  defp latest_tasks(base, limit) do
    base
    |> order_by([task], desc: task.updated_at)
    |> limit(^limit)
    |> preload([:project, :host])
    |> Repo.all()
    |> Enum.map(fn task ->
      %{
        task_id: task.task_id,
        status: task.status,
        project: assoc_name(task.project),
        host: assoc_name(task.host),
        agent: task.agent_name,
        branch: task.branch,
        session: task.session_name,
        updated_at: task.updated_at
      }
    end)
  end

  defp latest_directives(base, limit) do
    base
    |> order_by([directive], desc: directive.updated_at)
    |> limit(^limit)
    |> preload([:host])
    |> Repo.all()
    |> Enum.map(fn directive ->
      %{
        directive_id: directive.directive_id,
        status: directive.status,
        host: assoc_name(directive.host),
        session: directive.session_name,
        message: truncate(directive.message, 180),
        updated_at: directive.updated_at
      }
    end)
  end

  defp latest_handoffs(base, limit) do
    base
    |> order_by([handoff], desc: handoff.updated_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(fn handoff ->
      %{
        handoff_id: handoff.handoff_id,
        status: handoff.status,
        surface: handoff.surface,
        project: handoff.project,
        ref: handoff.ref,
        title: handoff.title,
        summary: truncate(handoff.summary, 180),
        updated_at: handoff.updated_at
      }
    end)
  end

  defp latest_profiles(base, limit) do
    base
    |> order_by([profile], desc: profile.updated_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(fn profile ->
      %{
        ref: profile.ref,
        prompt_status: profile.prompt_status,
        lifecycle_status: profile.lifecycle_status,
        risk_level: profile.risk_level,
        owner: profile.owner,
        summary: truncate(profile.summary, 180),
        updated_at: profile.updated_at
      }
    end)
  end

  defp latest_events(base, limit) do
    base
    |> order_by([event], desc: event.id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(fn event ->
      %{
        event_id: event.event_id,
        source: event.source,
        kind: event.kind,
        severity: event.severity,
        entity_type: event.entity_type,
        entity_id: event.entity_id,
        summary: truncate(event.summary, 180),
        inserted_at: event.inserted_at
      }
    end)
  end

  defp count_map(rows) do
    rows
    |> Enum.reject(fn {key, _count} -> key in [nil, ""] end)
    |> Map.new(fn {key, count} -> {to_string(key), count} end)
  end

  defp assoc_name(%{name: name}) when is_binary(name), do: name
  defp assoc_name(_assoc), do: ""

  defp truncate(nil, _max), do: ""

  defp truncate(value, max) do
    value = to_string(value)

    if String.length(value) > max do
      String.slice(value, 0, max - 3) <> "..."
    else
      value
    end
  end
end
