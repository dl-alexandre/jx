defmodule JX.Approvals do
  @moduledoc """
  Durable operator review queue.

  Acknowledging or dismissing an item changes JX state but never mutates a
  workspace or calls DevIDE write endpoints. Approval-gated execution is handled
  separately by `JX.SafeActions`.
  """

  import Ecto.Query

  alias JX.Approvals.{Approval, Evidence, Recommendation}
  alias JX.Notifications.{Notification, Router}
  alias JX.OperationalEvents
  alias JX.Repo

  @approval_prefix "apr-"
  @proposal_risks ~w(conflict overlap invalid)
  @unsafe_isolations ~w(unsafe shared_stage)
  @failed_run_statuses ~w(failed timed_out)

  def statuses, do: Approval.statuses()
  def active_statuses, do: Approval.active_statuses()
  def kinds, do: Approval.kinds()
  def sources, do: Approval.sources()

  def record_devide_notifications(notifications) when is_list(notifications) do
    notifications
    |> Enum.flat_map(&attrs_from_devide_notification/1)
    |> insert_new()
  end

  @doc """
  Create an operator review item from a caller-supplied request (e.g. an agent
  asking for approval or recording a handoff).

  Reuses the same dedupe + routing + operational-event pipeline as DevIDE
  notifications. Returns `{:ok, approval}` for a newly created item,
  `{:ok, :duplicate}` when an active item with the same dedupe key already
  exists, or `{:error, reason}`.
  """
  def create(attrs) when is_map(attrs) do
    case insert_new([normalize_request_attrs(attrs)]) do
      %{saved: 1, records: [approval]} -> {:ok, approval}
      %{saved: 0, duplicates: dups} when dups > 0 -> {:ok, :duplicate}
      %{errors: [error | _]} -> {:error, error}
      _ -> {:error, :create_failed}
    end
  end

  defp normalize_request_attrs(attrs) do
    kind = to_string(attrs[:kind] || attrs["kind"])
    metadata = attrs[:metadata] || attrs["metadata"] || %{}

    %{
      approval_id: approval_id(),
      source: to_string(attrs[:source] || attrs["source"] || "agent"),
      workspace_id: to_string(attrs[:workspace_id] || attrs["workspace_id"] || ""),
      kind: kind,
      severity: to_string(attrs[:severity] || attrs["severity"] || "warning"),
      target_ref: to_string(attrs[:target_ref] || attrs["target_ref"] || ""),
      summary: to_string(attrs[:summary] || attrs["summary"] || ""),
      status: "open",
      metadata: encode_json(metadata)
    }
    |> then(fn normalized -> Map.put(normalized, :dedupe_key, dedupe_key(normalized)) end)
  end

  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Approval
    |> maybe_filter_status(Keyword.get(opts, :status))
    |> maybe_filter_source(Keyword.get(opts, :source))
    |> maybe_filter_workspace(Keyword.get(opts, :workspace_id))
    |> maybe_filter_kind(Keyword.get(opts, :kind))
    |> order_by([approval],
      asc:
        fragment(
          "case ? when 'open' then 0 when 'acknowledged' then 1 else 2 end",
          approval.status
        ),
      desc: approval.updated_at
    )
    |> limit(^limit)
    |> Repo.all()
  end

  def get(approval_id), do: Repo.get_by(Approval, approval_id: approval_id)

  def detail(%Approval{} = approval) do
    evidence = Evidence.build(approval)

    %{
      approval: approval,
      evidence: evidence,
      recommendation: Recommendation.build(approval, evidence)
    }
  end

  def detail(approval_id) when is_binary(approval_id) do
    case get(approval_id) do
      nil -> {:error, :approval_not_found}
      approval -> {:ok, detail(approval)}
    end
  end

  def acknowledge(approval_id, opts \\ []) do
    case get(approval_id) do
      nil ->
        {:error, :approval_not_found}

      approval ->
        case approval
             |> Approval.changeset(%{
               status: "acknowledged",
               acknowledged_at: DateTime.utc_now()
             })
             |> Repo.update() do
          {:ok, approval} ->
            _ =
              OperationalEvents.record_approval(approval, "approval.acknowledged",
                correlation_id: Keyword.get(opts, :correlation_id)
              )

            {:ok, approval}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  def dismiss(approval_id, opts \\ []) do
    case get(approval_id) do
      nil ->
        {:error, :approval_not_found}

      approval ->
        case approval
             |> Approval.changeset(%{
               status: "dismissed",
               dismissed_at: DateTime.utc_now()
             })
             |> Repo.update() do
          {:ok, approval} ->
            _ =
              OperationalEvents.record_approval(approval, "approval.dismissed",
                correlation_id: Keyword.get(opts, :correlation_id)
              )

            {:ok, approval}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  def summary(opts \\ []) do
    approvals = list(Keyword.put_new(opts, :limit, 500))
    open_approvals = Enum.filter(approvals, &(&1.status == "open"))

    %{
      total: length(approvals),
      open_total: length(open_approvals),
      active_total: Enum.count(approvals, &(&1.status in Approval.active_statuses())),
      by_status: count_by(approvals, & &1.status),
      by_source: count_by(approvals, & &1.source),
      open_by_source: count_by(open_approvals, & &1.source),
      by_kind: count_by(approvals, & &1.kind),
      by_workspace: count_by(approvals, & &1.workspace_id),
      latest:
        approvals
        |> Enum.take(Keyword.get(opts, :latest, 10))
        |> Enum.map(&approval_summary/1)
    }
  end

  def portfolio_totals(summary) when is_map(summary) do
    %{
      open_approvals: Map.get(summary, :open_total, 0),
      active_approvals: Map.get(summary, :active_total, 0),
      devide_open_approvals: get_in(summary, [:open_by_source, "devide"]) || 0
    }
  end

  defp insert_new([]),
    do: %{saved: 0, records: [], duplicates: 0, routed: empty_route(), errors: []}

  defp insert_new(attrs_list) do
    Repo.transaction(fn ->
      Enum.reduce(attrs_list, %{records: [], duplicates: 0, sink_events: []}, fn attrs, acc ->
        case active_duplicate(attrs.dedupe_key) do
          %Approval{} = approval ->
            {:ok, _approval, sink_events} = update_duplicate(approval, attrs)

            %{
              acc
              | duplicates: acc.duplicates + 1,
                sink_events: prepend_sink_events(sink_events, acc.sink_events)
            }

          nil ->
            approval =
              %Approval{}
              |> Approval.changeset(attrs)
              |> Repo.insert()
              |> case do
                {:ok, approval} -> approval
                {:error, changeset} -> Repo.rollback(changeset)
              end

            %{
              acc
              | records: [approval | acc.records],
                sink_events: [
                  sink_event("approval.created", approval, nil, approval) | acc.sink_events
                ]
            }
            |> tap(fn _acc ->
              _ = OperationalEvents.record_approval(approval, "approval.created")
            end)
        end
      end)
    end)
    |> case do
      {:ok, %{records: records, duplicates: duplicates, sink_events: sink_events}} ->
        records = Enum.reverse(records)
        sink_events = Enum.reverse(sink_events)
        routed = route_sink_events(sink_events)

        %{
          saved: length(records),
          records: records,
          duplicates: duplicates,
          routed: routed,
          errors: routed.errors
        }

      {:error, reason} ->
        %{saved: 0, records: [], duplicates: 0, routed: empty_route(), errors: [inspect(reason)]}
    end
  end

  defp update_duplicate(%Approval{} = approval, attrs) do
    previous = approval
    sink_events = duplicate_sink_events(previous, attrs)

    case approval
         |> Approval.changeset(%{
           severity: max_severity(approval.severity, attrs.severity),
           summary: attrs.summary,
           metadata: attrs.metadata
         })
         |> Repo.update() do
      {:ok, updated} ->
        _ = OperationalEvents.record_approval(updated, "approval.updated")
        {:ok, updated, Enum.map(sink_events, & &1.(updated))}

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp duplicate_sink_events(%Approval{} = approval, attrs) do
    [
      if severity_rank(attrs.severity) > severity_rank(approval.severity) do
        fn updated -> sink_event("approval.severity_escalated", updated, approval, attrs) end
      end,
      if repeated_failure?(approval, attrs) do
        fn updated -> sink_event("approval.repeated_failure", updated, approval, attrs) end
      end
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp repeated_failure?(%Approval{kind: "failed_run"} = approval, attrs) do
    failure_signature(approval.metadata) != failure_signature(attrs.metadata)
  end

  defp repeated_failure?(_approval, _attrs), do: false

  defp failure_signature(metadata) do
    metadata = decode_json(metadata, %{})
    run = field(metadata, "run") || %{}

    %{
      id: field(run, "id"),
      command_id: field(run, "command_id"),
      status: field(run, "status"),
      exit_code: field(run, "exit_code"),
      started_at: field(run, "started_at"),
      finished_at: field(run, "finished_at")
    }
  end

  defp severity_rank("critical"), do: 4
  defp severity_rank("warning"), do: 3
  defp severity_rank("notice"), do: 2
  defp severity_rank("info"), do: 1
  defp severity_rank(_severity), do: 0

  defp max_severity(current, incoming) do
    if severity_rank(incoming) > severity_rank(current), do: incoming, else: current
  end

  defp sink_event(event, %Approval{} = approval, previous, source) do
    metadata = decode_json(approval.metadata, %{})

    %{
      event: event,
      source: "approvals",
      severity: approval.severity,
      summary: sink_summary(event, approval),
      approval: approval_packet(approval),
      previous: previous && approval_packet(previous),
      reason: approval.kind,
      target_ref: approval.target_ref,
      metadata: metadata,
      source_event_id: field(metadata, "source_event_id"),
      source_context: source_context(source)
    }
  end

  defp sink_summary("approval.created", approval),
    do: "new approval #{approval.approval_id}: #{approval.summary}"

  defp sink_summary("approval.severity_escalated", approval),
    do: "approval #{approval.approval_id} escalated to #{approval.severity}: #{approval.summary}"

  defp sink_summary("approval.repeated_failure", approval),
    do: "approval #{approval.approval_id} saw a repeated failure: #{approval.summary}"

  defp sink_summary(_event, approval), do: approval.summary

  defp approval_packet(%Approval{} = approval) do
    %{
      approval_id: approval.approval_id,
      source: approval.source,
      workspace_id: approval.workspace_id,
      kind: approval.kind,
      severity: approval.severity,
      target_ref: approval.target_ref,
      summary: approval.summary,
      status: approval.status,
      updated_at: approval.updated_at
    }
  end

  defp source_context(%Approval{} = approval), do: approval_packet(approval)

  defp source_context(attrs) when is_map(attrs),
    do: Map.take(attrs, [:severity, :summary, :metadata])

  defp source_context(_source), do: %{}

  defp prepend_sink_events([], list), do: list
  defp prepend_sink_events(events, list), do: Enum.reverse(events) ++ list

  defp route_sink_events([]), do: empty_route()
  defp route_sink_events(events), do: Router.route_many(events)

  defp empty_route, do: %{events: 0, sinks: 0, delivered: 0, errors: []}

  defp active_duplicate(dedupe_key) do
    Approval
    |> where([approval], approval.dedupe_key == ^dedupe_key)
    |> where([approval], approval.status in ^Approval.active_statuses())
    |> order_by([approval], desc: approval.updated_at)
    |> limit(1)
    |> Repo.one()
  end

  defp attrs_from_devide_notification(%Notification{kind: kind} = notification)
       when kind in ["devide.workspace.blocked", "devide.workspace.needs_review"] do
    payload = decode_json(notification.payload, %{})
    current = field(payload, "current") || %{}
    snapshot = field(current, "snapshot") || %{}
    workspace_id = first_present([notification.ref, field(payload, "id"), field(snapshot, "id")])

    snapshot
    |> risk_attrs(notification, workspace_id)
    |> Enum.map(&put_common_attrs(&1, notification, workspace_id, payload))
  end

  defp attrs_from_devide_notification(_notification), do: []

  defp risk_attrs(snapshot, notification, workspace_id) do
    db_approval(snapshot, notification, workspace_id) ++
      run_approvals(snapshot, notification, workspace_id) ++
      proposal_approvals(snapshot, notification, workspace_id) ++
      policy_approvals(snapshot, notification, workspace_id)
  end

  defp db_approval(snapshot, notification, workspace_id) do
    isolation = field(snapshot, "db_isolation") |> text()

    if isolation in @unsafe_isolations do
      [
        %{
          kind: "unsafe_db",
          target_ref: isolation,
          summary: "DevIDE workspace #{workspace_id} uses #{isolation} database isolation",
          metadata: %{db_isolation: isolation, notification_id: notification.notification_id}
        }
      ]
    else
      []
    end
  end

  defp run_approvals(snapshot, notification, workspace_id) do
    snapshot
    |> run_risks()
    |> Enum.map(fn run ->
      command_id = first_present([field(run, "command_id"), field(run, "id"), "run"])
      status = field(run, "status") |> text()

      %{
        kind: "failed_run",
        target_ref: command_id,
        summary: "DevIDE workspace #{workspace_id} has #{command_id} run #{status}",
        metadata: %{run: run, notification_id: notification.notification_id}
      }
    end)
  end

  defp proposal_approvals(snapshot, notification, workspace_id) do
    snapshot
    |> field("proposal_risks")
    |> list_value()
    |> Enum.filter(fn proposal -> text(field(proposal, "risk")) in @proposal_risks end)
    |> Enum.map(fn proposal ->
      path = first_present([field(proposal, "path"), "proposal"])
      risk = field(proposal, "risk") |> text()

      %{
        kind: "proposal_conflict",
        target_ref: path,
        summary: "DevIDE workspace #{workspace_id} has #{risk} proposal #{path}",
        metadata: %{proposal: proposal, risk: risk, notification_id: notification.notification_id}
      }
    end)
  end

  defp policy_approvals(snapshot, notification, workspace_id) do
    snapshot
    |> field("recent_blocks")
    |> list_value()
    |> Enum.map(fn block ->
      target_ref = block_target(block)

      %{
        kind: "policy_blocked",
        target_ref: target_ref,
        summary: "DevIDE workspace #{workspace_id} policy blocked #{target_ref}",
        metadata: %{block: block, notification_id: notification.notification_id}
      }
    end)
  end

  defp put_common_attrs(attrs, notification, workspace_id, payload) do
    attrs =
      attrs
      |> Map.put(:approval_id, approval_id())
      |> Map.put(:source, "devide")
      |> Map.put(:workspace_id, workspace_id)
      |> Map.put(:severity, notification.severity || "warning")
      |> Map.put(:status, "open")
      |> Map.update(:metadata, %{}, fn metadata ->
        current = field(payload, "current") || %{}

        Map.merge(metadata, %{
          source_event_id: notification.source_event_id,
          transition: Map.take(payload, ["previous_status", "status", "attention_flags"]),
          evidence: %{
            captured_at: field(current, "last_observed_at") || field(current, "last_changed_at"),
            source: "devide.notification",
            workspace:
              Map.take(current, [
                "id",
                "name",
                "status",
                "lifecycle_status",
                "mode",
                "db_isolation",
                "attention_flags",
                "last_observed_at",
                "last_changed_at"
              ]),
            snapshot: field(current, "snapshot") || %{}
          }
        })
      end)

    attrs
    |> Map.put(:metadata, encode_json(attrs.metadata))
    |> Map.put(:dedupe_key, dedupe_key(attrs))
  end

  defp run_risks(snapshot) do
    active_run = field(snapshot, "active_run")

    active =
      if failed_run?(active_run), do: [active_run], else: []

    latest =
      snapshot
      |> field("latest_runs")
      |> list_value()
      |> Enum.filter(&failed_run?/1)

    Enum.uniq_by(active ++ latest, fn run ->
      {field(run, "id"), field(run, "command_id"), field(run, "status")}
    end)
  end

  defp failed_run?(run) when is_map(run),
    do: text(field(run, "status")) in @failed_run_statuses

  defp failed_run?(_run), do: false

  defp block_target(block) do
    [field(block, "target_type"), field(block, "target_ref"), field(block, "reason")]
    |> Enum.map(&text/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> first_present([field(block, "action"), "policy.blocked"])
      values -> Enum.join(values, ":")
    end
  end

  defp maybe_filter_status(query, nil),
    do: where(query, [approval], approval.status in ^Approval.active_statuses())

  defp maybe_filter_status(query, "active"),
    do: where(query, [approval], approval.status in ^Approval.active_statuses())

  defp maybe_filter_status(query, "all"), do: query

  defp maybe_filter_status(query, status),
    do: where(query, [approval], approval.status == ^status)

  defp maybe_filter_source(query, nil), do: query

  defp maybe_filter_source(query, source),
    do: where(query, [approval], approval.source == ^source)

  defp maybe_filter_workspace(query, nil), do: query

  defp maybe_filter_workspace(query, workspace_id),
    do: where(query, [approval], approval.workspace_id == ^workspace_id)

  defp maybe_filter_kind(query, nil), do: query
  defp maybe_filter_kind(query, kind), do: where(query, [approval], approval.kind == ^kind)

  defp count_by(items, fun) do
    items
    |> Enum.map(fun)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.frequencies()
  end

  defp approval_summary(%Approval{} = approval) do
    %{
      approval_id: approval.approval_id,
      source: approval.source,
      workspace_id: approval.workspace_id,
      kind: approval.kind,
      severity: approval.severity,
      target_ref: approval.target_ref,
      summary: approval.summary,
      status: approval.status,
      acknowledged_at: approval.acknowledged_at,
      dismissed_at: approval.dismissed_at,
      updated_at: approval.updated_at
    }
  end

  defp dedupe_key(attrs) do
    [
      attrs.source,
      attrs.workspace_id,
      attrs.kind,
      attrs.target_ref
    ]
    |> Enum.join("|")
    |> then(fn value -> :crypto.hash(:sha256, value) end)
    |> Base.encode16(case: :lower)
  end

  defp approval_id do
    random =
      5
      |> :crypto.strong_rand_bytes()
      |> Base.encode16(case: :lower)

    @approval_prefix <> random
  end

  defp decode_json(text, fallback) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> fallback
    end
  end

  defp decode_json(_text, fallback), do: fallback

  defp encode_json(value) do
    Jason.encode!(value)
  rescue
    Protocol.UndefinedError -> "{}"
    ArgumentError -> "{}"
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, atom_key(key))

  defp field(_value, _key), do: nil

  defp atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp atom_key(_key), do: nil

  defp list_value(value) when is_list(value), do: value
  defp list_value(_value), do: []

  defp first_present(values) do
    Enum.find_value(values, "", fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      nil ->
        nil

      value ->
        value |> to_string() |> String.trim() |> present_or_nil()
    end)
  end

  defp present_or_nil(""), do: nil
  defp present_or_nil(value), do: value

  defp text(nil), do: ""
  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(value), do: value |> to_string() |> String.trim()
end
