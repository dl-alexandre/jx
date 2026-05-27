defmodule JX do
  @moduledoc """
  Public domain API for jx's durable SSH/tmux-backed agent workspaces.

  The public product name is **jx** with `jx` as the CLI. The boundary is
  intentionally small: callers should use this module or `JX.Workspace`
  instead of reaching into the persistence schemas or transport modules
  directly.

  The API is organized around a few durable primitives:

  * hosts and projects define where work can run
  * tasks launch isolated worktrees and tmux sessions
  * session inventory discovers existing tmux, SSH, and agent processes
  * profiles describe expected work and chambered next prompts
  * watches, notifications, and heartbeats let a foreground agent stay out of
    the polling loop

  Most functions delegate to `JX.Workspace`, which owns policy
  enforcement for SSH, tmux, Git, and session direction.
  """

  alias JX.Workspace

  defdelegate add_host(attrs), to: Workspace
  defdelegate add_project(attrs), to: Workspace
  defdelegate doctor_host(host_name, opts \\ []), to: Workspace
  defdelegate doctor_hosts(opts \\ []), to: Workspace
  defdelegate project_gate(project_name, opts \\ []), to: Workspace

  defdelegate promotion_preflight(project_name, source_branch, target_branch, opts \\ []),
    to: Workspace

  defdelegate promotion_run(project_name, source_branch, target_branch, opts \\ []), to: Workspace
  defdelegate repo_doctor(project_name, opts \\ []), to: Workspace
  defdelegate repo_gate(project_name, opts \\ []), to: Workspace
  defdelegate assign_task(project_name, prompt, opts \\ []), to: Workspace
  defdelegate list_statuses(), to: Workspace
  defdelegate reconcile_task_statuses(opts \\ []), to: Workspace
  defdelegate recap(opts \\ []), to: Workspace
  defdelegate record_agent_report(attrs), to: Workspace
  defdelegate list_sessions(opts \\ []), to: Workspace
  defdelegate snapshot_sessions(opts \\ []), to: Workspace
  defdelegate observe_sessions(opts \\ []), to: Workspace
  defdelegate list_session_observations(opts \\ []), to: Workspace
  defdelegate list_session_changes(opts \\ []), to: Workspace
  defdelegate list_stale_session_observations(opts \\ []), to: Workspace
  defdelegate list_operation_executions(opts \\ []), to: Workspace
  defdelegate ci_digest(repo, pr_number, opts \\ []), to: Workspace
  defdelegate add_ci_watch(attrs), to: Workspace
  defdelegate call_brief(opts \\ []), to: Workspace
  defdelegate participant_plugins(), to: Workspace
  defdelegate google_meet_configure_auth(attrs), to: Workspace
  defdelegate google_meet_auth_profiles(opts \\ []), to: Workspace
  defdelegate google_meet_auth_url(profile_name, opts \\ []), to: Workspace
  defdelegate google_meet_exchange_auth_code(profile_name, code, opts \\ []), to: Workspace
  defdelegate google_meet_create_session(attrs, opts \\ []), to: Workspace
  defdelegate google_meet_sessions(opts \\ []), to: Workspace
  defdelegate google_meet_session(session_id), to: Workspace
  defdelegate google_meet_join_plan(session_id), to: Workspace
  defdelegate google_meet_join_session(session_id, opts \\ []), to: Workspace
  defdelegate google_meet_realtime_plan(session_id, opts \\ []), to: Workspace
  defdelegate google_meet_start_realtime(session_id, attrs \\ %{}, opts \\ []), to: Workspace
  defdelegate google_meet_realtime_consult(session_id, attrs, opts \\ []), to: Workspace
  defdelegate google_meet_realtime_watch(session_id, opts \\ []), to: Workspace
  defdelegate google_meet_recover_open_tabs(attrs, opts \\ []), to: Workspace
  defdelegate google_meet_sync_artifacts(session_id, opts \\ []), to: Workspace
  defdelegate google_meet_export_session(session_id, opts \\ []), to: Workspace
  defdelegate create_delegation(attrs), to: Workspace
  defdelegate list_delegations(opts \\ []), to: Workspace
  defdelegate start_delegation(delegation_id, attrs \\ []), to: Workspace
  defdelegate add_delegation_evidence(delegation_id, attrs), to: Workspace
  defdelegate complete_delegation(delegation_id, attrs \\ []), to: Workspace
  defdelegate block_delegation(delegation_id, summary), to: Workspace
  defdelegate fail_delegation(delegation_id, summary), to: Workspace
  defdelegate cancel_delegation(delegation_id, summary \\ ""), to: Workspace
  defdelegate delegation_brief(delegation_id), to: Workspace
  defdelegate delegation_preflight(delegation_id), to: Workspace
  defdelegate delegation_review(delegation_id), to: Workspace
  defdelegate delegation_reviews(opts \\ []), to: Workspace
  defdelegate delegation_timing(opts \\ []), to: Workspace
  defdelegate decide_delegation_review(delegation_id, decision, attrs \\ []), to: Workspace
  defdelegate list_approvals(opts \\ []), to: Workspace
  defdelegate get_approval(approval_id), to: Workspace
  defdelegate approval_detail(approval_id), to: Workspace
  defdelegate approval_summary(opts \\ []), to: Workspace
  defdelegate acknowledge_approval(approval_id), to: Workspace
  defdelegate dismiss_approval(approval_id), to: Workspace
  defdelegate create_call_handoff(attrs, opts \\ []), to: Workspace
  defdelegate list_call_handoffs(opts \\ []), to: Workspace
  defdelegate close_call_handoff(handoff_id, summary \\ ""), to: Workspace
  defdelegate apply_call_handoff(handoff_id, summary \\ ""), to: Workspace
  defdelegate list_ci_watches(opts \\ []), to: Workspace
  defdelegate review_ci_watch(watch_id, opts \\ []), to: Workspace
  defdelegate cancel_ci_watch(watch_id, summary), to: Workspace
  defdelegate list_session_controls(opts \\ []), to: Workspace
  defdelegate set_session_control(ref, mode, opts \\ []), to: Workspace
  defdelegate clear_session_control(ref), to: Workspace
  defdelegate list_remote_session_observations(opts \\ []), to: Workspace
  defdelegate session_summary(opts \\ []), to: Workspace
  defdelegate session_profiles(opts \\ []), to: Workspace
  defdelegate set_session_profile(ref, attrs), to: Workspace
  defdelegate operator_profile(), to: Workspace
  defdelegate set_operator_profile(attrs), to: Workspace
  defdelegate operate(opts \\ []), to: Workspace
  defdelegate work_board(opts \\ []), to: Workspace
  defdelegate remote_session_candidates(opts \\ []), to: Workspace
  defdelegate probe_remote_sessions(opts \\ []), to: Workspace
  defdelegate broadcast_sessions(message, opts \\ []), to: Workspace
  defdelegate resume_adopt_session(ref, project_name, opts \\ []), to: Workspace
  defdelegate stream_adopt_session(ref, project_name, opts \\ []), to: Workspace
  defdelegate cleanup_dry_run(opts \\ []), to: JX.ResourceOwnerships
  defdelegate attach(task_id), to: Workspace
  defdelegate logs(task_id, opts \\ []), to: Workspace
  defdelegate stop(task_id), to: Workspace
end

defmodule JX.Repo do
  use Ecto.Repo,
    otp_app: :jx,
    adapter: Ecto.Adapters.SQLite3

  @impl true
  def init(_type, config) do
    config
    |> Keyword.get(:database)
    |> ensure_database_dir()

    {:ok, config}
  end

  defp ensure_database_dir(nil), do: :ok
  defp ensure_database_dir(":memory:"), do: :ok

  defp ensure_database_dir(database) do
    database
    |> Path.dirname()
    |> File.mkdir_p!()
  end
end
