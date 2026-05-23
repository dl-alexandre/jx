defmodule JX.HostCapacity.Observation do
  @moduledoc """
  A point-in-time snapshot of a host's hardware resources captured while one
  or more worktree sessions were active.

  Observations are the raw material that `JX.HostCapacity.Evaluator` uses to
  produce calibration recommendations.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "host_capacity_observations" do
    field(:host_name, :string)
    field(:active_sessions, :integer, default: 0)

    field(:ram_total_mb, :integer)
    field(:ram_available_mb, :integer)
    field(:disk_total_mb, :integer)
    field(:disk_available_mb, :integer)
    field(:cpu_cores, :integer)

    # 1-minute load average; nil when the host doesn't expose it
    field(:load_avg_1m, :float)

    # The capacity_limit that was in effect when this snapshot was taken
    field(:capacity_limit_at_observation, :integer)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required ~w(host_name active_sessions ram_total_mb ram_available_mb
               disk_total_mb disk_available_mb cpu_cores)a
  @optional ~w(load_avg_1m capacity_limit_at_observation)a

  def changeset(obs, attrs) do
    obs
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_number(:active_sessions, greater_than_or_equal_to: 0)
    |> validate_number(:ram_available_mb, greater_than_or_equal_to: 0)
    |> validate_number(:disk_available_mb, greater_than_or_equal_to: 0)
  end
end
