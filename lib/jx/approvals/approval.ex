defmodule JX.Approvals.Approval do
  @moduledoc """
  Operator review item derived from observed orchestration risk.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias JX.MonitorEvents

  @statuses ~w(open acknowledged dismissed)
  @sources ~w(devide agent)
  @kinds ~w(proposal_conflict unsafe_db failed_run policy_blocked agent_request agent_handoff)

  @type t :: %__MODULE__{}

  schema "approval_items" do
    field(:approval_id, :string)
    field(:source, :string, default: "devide")
    field(:workspace_id, :string, default: "")
    field(:kind, :string)
    field(:severity, :string, default: "warning")
    field(:target_ref, :string, default: "")
    field(:summary, :string, default: "")
    field(:status, :string, default: "open")
    field(:metadata, :string, default: "{}")
    field(:dedupe_key, :string)
    field(:acknowledged_at, :utc_datetime_usec)
    field(:dismissed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
  def active_statuses, do: ~w(open acknowledged)
  def sources, do: @sources
  def kinds, do: @kinds

  def changeset(approval, attrs) do
    approval
    |> cast(attrs, [
      :approval_id,
      :source,
      :workspace_id,
      :kind,
      :severity,
      :target_ref,
      :summary,
      :status,
      :metadata,
      :dedupe_key,
      :acknowledged_at,
      :dismissed_at
    ])
    |> trim_fields([
      :approval_id,
      :source,
      :workspace_id,
      :kind,
      :severity,
      :target_ref,
      :summary,
      :status,
      :metadata,
      :dedupe_key
    ])
    |> validate_required([
      :approval_id,
      :source,
      :workspace_id,
      :kind,
      :severity,
      :status,
      :metadata,
      :dedupe_key
    ])
    |> validate_inclusion(:source, @sources)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:severity, MonitorEvents.Event.severities())
    |> unique_constraint(:approval_id)
  end

  defp trim_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      update_change(changeset, field, &trim/1)
    end)
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(to_string(value))
end
