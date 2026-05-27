defmodule JX.Tasks do
  @moduledoc """
  Task persistence operations.
  """

  import Ecto.Query

  alias JX.Repo
  alias JX.Tasks.Task

  def get_task_by_id(task_id) do
    case Repo.get_by(Task, task_id: task_id) do
      nil -> nil
      task -> Repo.preload(task, [:host, :project])
    end
  end

  def get_task_by_prompt(project_id, prompt_hash) do
    case Repo.get_by(Task, project_id: project_id, prompt_hash: prompt_hash) do
      nil -> nil
      task -> Repo.preload(task, [:host, :project])
    end
  end

  def get_task_by_pane(project_id, tmux_server, session_name, window, pane) do
    case Repo.get_by(Task,
           project_id: project_id,
           tmux_server: tmux_server,
           session_name: session_name,
           window: window,
           pane: pane
         ) do
      nil -> nil
      task -> Repo.preload(task, [:host, :project])
    end
  end

  def list_tasks do
    Task
    |> order_by([task], desc: task.id)
    |> preload([:host, :project])
    |> Repo.all()
  end

  def list_tasks_for_hosts(host_ids) do
    Task
    |> where([task], task.host_id in ^host_ids)
    |> preload([:host, :project])
    |> Repo.all()
  end

  def list_tasks_by_status(statuses) when is_list(statuses) do
    Task
    |> where([task], task.status in ^statuses)
    |> order_by([task], asc: task.updated_at)
    |> preload([:host, :project])
    |> Repo.all()
  end

  def count_running_for_host(host_id) do
    Task
    |> where([t], t.host_id == ^host_id and t.status == "running")
    |> Repo.aggregate(:count)
  end

  def insert_task(attrs) do
    %Task{}
    |> Task.changeset(attrs)
    |> Repo.insert()
  end

  def update_status(%Task{} = task, status, last_error \\ "") do
    task
    |> Task.changeset(%{status: status, last_error: last_error})
    |> Repo.update()
  end

  def update_launch_command(%Task{} = task, launch_command) do
    task
    |> Task.changeset(%{launch_command: launch_command})
    |> Repo.update()
  end
end
