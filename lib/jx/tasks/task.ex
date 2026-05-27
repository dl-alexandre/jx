defmodule JX.Tasks.Task do
  @moduledoc """
  Durable task record tying a prompt to a branch, worktree, tmux session, and log.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias JX.Hosts.Host
  alias JX.Projects.Project

  @statuses ~w(creating running completed failed stopped stale expired error)
  @agent_transports ~w(native acpx)

  @type t :: %__MODULE__{}

  schema "tasks" do
    field(:task_id, :string)
    field(:prompt_hash, :string)
    field(:prompt, :string)
    field(:goal_objective, :string, default: "")
    field(:agent_name, :string)
    field(:agent_transport, :string, default: "native")
    field(:branch, :string)
    field(:worktree_path, :string)
    field(:task_dir, :string)
    field(:log_path, :string)
    field(:session_name, :string)
    field(:tmux_server, :string, default: "jx")
    field(:window, :integer, default: 0)
    field(:pane, :integer, default: 0)
    field(:launch_command, :string, default: "")
    field(:status, :string, default: "creating")
    field(:last_error, :string, default: "")

    belongs_to(:project, Project)
    belongs_to(:host, Host)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :task_id,
      :prompt_hash,
      :prompt,
      :goal_objective,
      :agent_name,
      :agent_transport,
      :branch,
      :worktree_path,
      :task_dir,
      :log_path,
      :session_name,
      :tmux_server,
      :window,
      :pane,
      :launch_command,
      :status,
      :last_error,
      :project_id,
      :host_id
    ])
    |> validate_required([
      :task_id,
      :prompt_hash,
      :prompt,
      :agent_name,
      :agent_transport,
      :branch,
      :worktree_path,
      :task_dir,
      :log_path,
      :session_name,
      :tmux_server,
      :window,
      :pane,
      :status,
      :project_id,
      :host_id
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:agent_transport, @agent_transports)
    |> validate_number(:window, greater_than_or_equal_to: 0)
    |> validate_number(:pane, greater_than_or_equal_to: 0)
    |> assoc_constraint(:project)
    |> assoc_constraint(:host)
    |> unique_constraint(:task_id)
    |> unique_constraint([:project_id, :prompt_hash])
  end
end
