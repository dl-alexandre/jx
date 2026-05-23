defmodule JX.Fanout do
  @moduledoc """
  File-backed fanout orchestration primitives.

  Fanout keeps orchestration safety in `jx`: assignment records are mutable
  control-plane state, while agent reports are immutable execution-plane facts.
  The first implementation is intentionally filesystem-backed so status can be
  replayed from durable artifacts before any daemon or database layer exists.
  """

  require Logger

  defmodule RunManifest do
    @moduledoc "Machine-readable fanout run manifest."

    @enforce_keys [
      :run_id,
      :plan_id,
      :repo,
      :baseline,
      :base_branch,
      :created_at,
      :publishability_contract,
      :assignments,
      :evidence
    ]
    defstruct [
      :run_id,
      :plan_id,
      :repo,
      :baseline,
      :base_branch,
      :created_at,
      :publishability_contract,
      :assignments,
      :evidence
    ]
  end

  defmodule Assignment do
    @moduledoc "Control-plane assignment record written by `jx`."

    @enforce_keys [
      :run_id,
      :assignment_id,
      :state,
      :excluded,
      :intent,
      :resolved_environment,
      :preflight,
      :evidence
    ]
    defstruct [
      :run_id,
      :assignment_id,
      :state,
      :excluded,
      :intent,
      :resolved_environment,
      :preflight,
      :evidence,
      :exclusion,
      :launch
    ]
  end

  defmodule AssignmentReport do
    @moduledoc "Immutable execution-plane report candidate from an agent."

    @enforce_keys [
      :report_id,
      :assignment_id,
      :agent_id,
      :sequence,
      :previous_report_id,
      :state,
      :reported_at,
      :data
    ]
    defstruct [
      :report_id,
      :assignment_id,
      :agent_id,
      :sequence,
      :previous_report_id,
      :state,
      :reported_at,
      :data
    ]
  end

  defmodule PreflightResult do
    @moduledoc "Time-bound publishability assertion produced by `jx fanout preflight`."

    @enforce_keys [:publishability, :checked_at, :ttl_seconds, :checks]
    defstruct [:publishability, :checked_at, :ttl_seconds, :checks]
  end

  defmodule LaunchLease do
    @moduledoc "Lease used while handing a preflight-passed assignment to an agent."

    @enforce_keys [:leased_at, :lease_timeout_seconds]
    defstruct [:leased_at, :lease_timeout_seconds, :agent_id]
  end

  @control_states ~w(planned preflight_failed preflight_passed excluded launching local_validated pr_opened ci_pending ci_failed ci_green ready)
  @agent_states ~w(in_progress blocked validation_failed local_validated pr_opened ci_pending ci_failed ci_green ready complete)
  @report_states @agent_states

  @publishability_contract %{
    "required" => [
      "clean_repo",
      "expected_head",
      "fresh_worktree",
      "assigned_branch",
      "base_branch_matches",
      "validation_prefix_known",
      "mix_version_passes",
      "hook_health_passes",
      "github_auth_passes",
      "dry_run_push_passes"
    ],
    "agent_forbidden" => [
      "live_workspace_editing",
      "branch_switching",
      "worktree_creation",
      "no_verify_push",
      "unassigned_scope_edits"
    ]
  }

  @agent_rules [
    "do_not_change_branches",
    "do_not_create_or_move_worktrees",
    "do_not_use_no_verify",
    "do_not_edit_outside_scope",
    "push_only_assigned_branch",
    "open_pr_only_after_validation_passes"
  ]

  @safe_path_id ~r/\A[A-Za-z0-9][A-Za-z0-9._:-]*\z/
  @completion_states %{
    "planned" => "planned",
    "preflight_failed" => "preflight failed",
    "preflight_passed" => "preflight passed",
    "excluded" => "excluded",
    "launching" => "launching",
    "local_validated" => "local validated",
    "pr_opened" => "PR opened",
    "ci_pending" => "CI pending",
    "ci_failed" => "CI failed",
    "ci_green" => "CI green",
    "ready" => "ready",
    "complete" => "ready"
  }

  @preflight_check_names @publishability_contract["required"]
  @default_preflight_ttl_seconds 3_600
  @default_lease_timeout_seconds 86_400

  def control_states, do: @control_states
  def agent_states, do: @agent_states

  @doc """
  Creates a file-backed fanout run.

  The MVP ships one built-in plan, `test-coverage`, which is the
  workflow that exposed the orchestration boundary. The generated files are the
  executable source of truth for later preflight, launch, and status commands.
  """
  def plan(plan_id, opts) when plan_id in ["test-coverage", "coverage-dynamic"] do
    with {:ok, baseline} <- required_string(opts, :baseline),
         {:ok, run_id} <- run_id(plan_id, opts),
         {:ok, run_path} <- prepare_run_path(opts[:root] || ".jx/runs", run_id),
         {:ok, created_at} <- timestamp(opts[:now]),
         {:ok, assignments} <- plan_assignments(plan_id, run_id, baseline, opts, run_path),
         :ok <- validate_unique(assignments, :assignment_id, "assignment ids"),
         :ok <- validate_unique(assignments, :branch, "branches", & &1.intent.branch),
         :ok <-
           validate_unique(assignments, :worktree_path, "worktree paths", fn assignment ->
             assignment.resolved_environment.worktree_path
           end),
         manifest <- manifest(plan_id, run_id, baseline, opts, assignments, created_at, run_path),
         :ok <- write_run(run_path, manifest, assignments) do
      {:ok,
       %{
         run_id: run_id,
         run_path: run_path,
         manifest_path: Path.join(run_path, "run_manifest.json"),
         assignment_count: length(assignments),
         assignment_ids: Enum.map(assignments, & &1.assignment_id)
       }}
    end
  end

  def plan(plan_id, _opts), do: {:error, "unknown fanout plan #{inspect(plan_id)}"}

  @doc """
  Returns a deterministic status summary from assignment records and accepted reports.
  """
  def status(run_ref, opts \\ []) do
    with {:ok, run_path} <- resolve_run_path(run_ref, opts[:root] || ".jx/runs"),
         {:ok, manifest} <- read_json(Path.join(run_path, "run_manifest.json")),
         {:ok, assignments} <- read_assignments(run_path) do
      rows =
        assignments
        |> Enum.map(&assignment_status(run_path, &1))
        |> Enum.sort_by(& &1.assignment_id)

      {:ok,
       %{
         run_id: manifest["run_id"],
         run_path: run_path,
         assignments: rows,
         counts: status_counts(rows)
       }}
    end
  end

  @doc """
  Runs publishability preflight for every non-excluded assignment in a fanout run.

  The generated remote script proves the configured baseline, branch safety,
  hook executability, GitHub auth, toolchain availability, and dry-run push path.
  Assignment records are updated with durable evidence and launch can only use
  fresh `preflight_passed` assignments.
  """
  def preflight(run_ref, opts \\ []) do
    with {:ok, run_path} <- resolve_run_path(run_ref, opts[:root] || ".jx/runs"),
         {:ok, manifest} <- read_json(Path.join(run_path, "run_manifest.json")),
         {:ok, assignments} <- read_assignments(run_path),
         {:ok, checked_at} <- timestamp(opts[:now]) do
      ttl_seconds = opts[:ttl_seconds] || @default_preflight_ttl_seconds

      updates =
        Enum.map(assignments, fn assignment ->
          preflight_assignment(run_path, manifest, assignment, checked_at, ttl_seconds, opts)
        end)

      :ok = write_preflight_report(run_path, updates)

      {:ok,
       %{
         run_id: manifest["run_id"],
         run_path: run_path,
         checked_at: checked_at,
         ttl_seconds: ttl_seconds,
         result: fanout_preflight_result(updates),
         assignments: Enum.map(updates, & &1.summary)
       }}
    end
  end

  @doc """
  Launches all or one assignment after every non-excluded assignment has fresh
  passing preflight evidence.
  """
  def launch(run_ref, opts) when is_list(opts), do: launch(run_ref, :all, opts)

  def launch(run_ref, assignment_id, opts \\ []) do
    with {:ok, run_path} <- resolve_run_path(run_ref, opts[:root] || ".jx/runs"),
         {:ok, manifest} <- read_json(Path.join(run_path, "run_manifest.json")),
         {:ok, assignments} <- read_assignments(run_path),
         :ok <- ensure_all_preflight_passed(assignments, opts),
         {:ok, targets} <- launch_targets(assignments, assignment_id),
         :ok <- preflight_capacity(run_path, targets),
         {:ok, launched_at} <- timestamp(opts[:now]) do
      launches =
        Enum.map(targets, fn assignment ->
          launch_assignment(run_path, manifest, assignment, launched_at, opts)
        end)

      launch_errors = Enum.filter(launches, &match?({:error, _reason}, &1))

      if launch_errors == [] do
        {:ok,
         %{
           run_id: manifest["run_id"],
           run_path: run_path,
           launched_at: launched_at,
           assignments: Enum.map(launches, fn {:ok, launch} -> launch end)
         }}
      else
        {:error, {:launch_failed, Enum.map(launch_errors, fn {:error, reason} -> reason end)}}
      end
    end
  end

  @doc """
  Refreshes registered CI watches into fanout assignment state.
  """
  def monitor(run_ref, opts \\ []) do
    with {:ok, run_path} <- resolve_run_path(run_ref, opts[:root] || ".jx/runs"),
         {:ok, manifest} <- read_json(Path.join(run_path, "run_manifest.json")),
         {:ok, assignments} <- read_assignments(run_path) do
      updates =
        Enum.map(assignments, fn assignment ->
          monitor_assignment(run_path, assignment, opts)
        end)

      {:ok,
       %{
         run_id: manifest["run_id"],
         run_path: run_path,
         assignments: updates,
         counts: status_counts(Enum.map(updates, &Map.take(&1, [:derived_state])))
       }}
    end
  end

  @doc """
  Checks an assignment diff against its declared ownership scope.
  """
  def ownership_check(run_ref, assignment_id, opts \\ []) do
    with {:ok, run_path} <- resolve_run_path(run_ref, opts[:root] || ".jx/runs"),
         {:ok, manifest} <- read_json(Path.join(run_path, "run_manifest.json")),
         {:ok, assignment} <- read_assignment(run_path, assignment_id),
         {:ok, paths} <- diff_paths(manifest, assignment, opts) do
      review = ownership_review(paths, get_in(assignment, ["intent", "scope"]) || %{})
      updated = put_in(assignment, ["evidence", "ownership"], review)
      :ok = write_assignment!(run_path, updated)

      if review["status"] == "passed" or opts[:warn_only] do
        {:ok, Map.put(review, "assignment_id", assignment_id)}
      else
        {:error, {:ownership_failed, Map.put(review, "assignment_id", assignment_id)}}
      end
    end
  end

  @doc """
  Opens the assignment PR after local validation and ownership checks pass.

  When a CI watch callback or `register_ci_watch: true` is supplied, the opened
  PR is also registered with `JX.CiWatches` and the assignment moves to
  `ci_pending`.
  """
  def open_pr(run_ref, assignment_id, opts \\ []) do
    with {:ok, run_path} <- resolve_run_path(run_ref, opts[:root] || ".jx/runs"),
         {:ok, manifest} <- read_json(Path.join(run_path, "run_manifest.json")),
         {:ok, assignment} <- read_assignment(run_path, assignment_id),
         :ok <- ensure_local_validated(run_path, assignment, opts),
         {:ok, ownership} <-
           ownership_check(run_path, assignment_id, Keyword.put(opts, :root, nil)),
         {:ok, opened_at} <- timestamp(opts[:now]),
         {:ok, pr} <- create_pr(manifest, assignment, opened_at, opts),
         ci_watch <- maybe_register_ci_watch(manifest, assignment, pr, opts) do
      updated =
        assignment
        |> Map.put("state", if(ci_watch, do: "ci_pending", else: "pr_opened"))
        |> put_in(["evidence", "ownership"], ownership)
        |> put_in(["evidence", "pr"], pr)
        |> maybe_put_ci_watch(ci_watch)

      :ok = write_assignment!(run_path, updated)

      {:ok,
       %{
         run_id: manifest["run_id"],
         assignment_id: assignment_id,
         pr: pr,
         ci_watch: ci_watch,
         state: updated["state"]
       }}
    end
  end

  @doc """
  Accepts or rejects an immutable agent report candidate.

  Accepted reports are written under `reports/<assignment>/accepted/`. Rejected
  report attempts are preserved under `reports/<assignment>/rejected/` with
  rejection metadata and are never reducer inputs.
  """
  def accept_report(run_ref, attrs, opts \\ []) do
    with {:ok, run_path} <- resolve_run_path(run_ref, opts[:root] || ".jx/runs"),
         {:ok, report} <- normalize_report(attrs),
         {:ok, assignment} <- read_assignment(run_path, report.assignment_id),
         :ok <- validate_report(report, assignment, run_path) do
      write_accepted_report(run_path, report)
    else
      {:error, reason, report} ->
        write_rejected_report(run_ref, report, reason, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def to_map(%RunManifest{} = manifest) do
    %{
      "run_id" => manifest.run_id,
      "plan_id" => manifest.plan_id,
      "repo" => manifest.repo,
      "baseline" => manifest.baseline,
      "base_branch" => manifest.base_branch,
      "created_at" => manifest.created_at,
      "publishability_contract" => manifest.publishability_contract,
      "assignments" => manifest.assignments,
      "evidence" => manifest.evidence
    }
  end

  def to_map(%Assignment{} = assignment) do
    %{
      "run_id" => assignment.run_id,
      "assignment_id" => assignment.assignment_id,
      "state" => assignment.state,
      "excluded" => assignment.excluded,
      "intent" => atomize_nested(assignment.intent),
      "resolved_environment" => atomize_nested(assignment.resolved_environment),
      "preflight" => assignment.preflight,
      "evidence" => atomize_nested(assignment.evidence),
      "exclusion" => assignment.exclusion,
      "launch" => assignment.launch
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def to_map(%AssignmentReport{} = report) do
    %{
      "report_id" => report.report_id,
      "assignment_id" => report.assignment_id,
      "agent_id" => report.agent_id,
      "sequence" => report.sequence,
      "previous_report_id" => report.previous_report_id,
      "state" => report.state,
      "reported_at" => report.reported_at,
      "data" => report.data
    }
  end

  defp manifest(plan_id, run_id, baseline, opts, assignments, created_at, run_path) do
    %RunManifest{
      run_id: run_id,
      plan_id: plan_id,
      repo: opts[:repo] || "example-project",
      baseline: baseline,
      base_branch: opts[:base_branch] || "develop",
      created_at: created_at,
      publishability_contract: @publishability_contract,
      assignments:
        Enum.map(assignments, fn assignment ->
          %{
            "id" => assignment.assignment_id,
            "path" => relative_path(run_path, assignment_path(run_path, assignment.assignment_id))
          }
        end),
      evidence: %{
        "preflight_report" => relative_path(run_path, Path.join(run_path, "preflight_report.md")),
        "agent_packet" => relative_path(run_path, Path.join(run_path, "agent_packet.md"))
      }
    }
  end

  defp plan_assignments("test-coverage", run_id, baseline, opts, run_path) do
    if dynamic_coverage_opts?(opts) do
      dynamic_coverage_assignments(run_id, baseline, opts, run_path)
    else
      {:ok, test_coverage_assignments(run_id, baseline, opts, run_path)}
    end
  end

  defp plan_assignments("coverage-dynamic", run_id, baseline, opts, run_path) do
    dynamic_coverage_assignments(run_id, baseline, opts, run_path)
  end

  @doc """
  Scans `runs_root` for all active fanout assignments and returns
  `%{host_name => count}`.  Used by `JX.HostCapacity.CapacityPoller`
  to include fanout sessions in per-host active counts.

  Pass the runs root directory (default `~/.jx/runs`).
  """
  def active_assignments_per_host(runs_root \\ Path.expand("~/.jx/runs")) do
    case File.ls(runs_root) do
      {:ok, run_dirs} ->
        Enum.reduce(run_dirs, %{}, fn dir, acc ->
          run_path = Path.join(runs_root, dir)

          if File.dir?(run_path) do
            per_host = active_fanout_assignments_per_host(run_path)
            Map.merge(acc, per_host, fn _k, a, b -> a + b end)
          else
            acc
          end
        end)

      _ ->
        %{}
    end
  end

  def dynamic_coverage_opts?(opts) do
    Enum.any?([:coverage_file, :coverage_modules, :host_count, :risk_rules], fn key ->
      case Keyword.get(opts, key) do
        nil -> false
        "" -> false
        [] -> false
        _value -> true
      end
    end)
  end

  defp test_coverage_assignments(run_id, baseline, opts, run_path) do
    base_branch = opts[:base_branch] || "develop"

    [
      %{
        id: "auth-api-security",
        host: "host-a",
        base_path: "~/work/acme",
        worktree_path: "~/work/worktrees/test-coverage-auth-api-security",
        branch: "test/auth-api-security-coverage",
        validation_prefix: "mise exec --",
        title: "test: expand auth and API security coverage",
        allowed: [
          "lib/one/api/**",
          "lib/one_web/controllers/api/**",
          "lib/one_web/plugs/**",
          "test/one/api/**",
          "test/one_web/controllers/api/**",
          "test/one_web/plugs/**"
        ],
        forbidden: [
          "lib/one_web/live/**",
          "test/one_web/live/**",
          "lib/one/reports/**",
          "test/one/reports/**"
        ],
        objective:
          "Expand coverage for valid/invalid JWT flows, expired tokens, missing or malformed auth headers, forbidden paths, unauthorized access, malformed payloads, invalid JSON handling, fallback behavior, and stable API error shapes."
      },
      %{
        id: "liveview-ui",
        host: "host-b",
        base_path: "~/work/acme",
        worktree_path: "~/work/worktrees/test-coverage-liveview-ui",
        branch: "test/liveview-ui-coverage",
        validation_prefix: "mise exec --",
        title: "test: expand LiveView interaction coverage",
        allowed: [
          "lib/one_web/live/**",
          "lib/one_web/components/**",
          "test/one_web/live/**",
          "test/one_web/components/**"
        ],
        forbidden: [
          "lib/one/api/**",
          "test/one/api/**",
          "lib/one/reports/**",
          "test/one/reports/**"
        ],
        objective:
          "Expand behavioral LiveView and component coverage for mounts, redirects, empty states, validation, events, handle_info, pagination/search/filter, rendering branches, and UI regressions."
      },
      %{
        id: "oban-audit",
        host: "host-c",
        base_path: "~/work/acme",
        worktree_path: "~/work/worktrees/test-coverage-oban-audit",
        branch: "test/oban-audit-coverage",
        validation_prefix: "mise exec --",
        title: "test: expand background job and audit coverage",
        allowed: [
          "lib/one/workers/**",
          "lib/one/audit/**",
          "lib/one/security/**",
          "test/one/workers/**",
          "test/one/audit/**",
          "test/one/security/**"
        ],
        forbidden: [
          "lib/one_web/live/**",
          "test/one_web/live/**",
          "lib/one/reports/**",
          "test/one/reports/**"
        ],
        objective:
          "Expand deterministic worker, retry/idempotency, audit envelope, metadata, redaction, append-only, malformed args, and security event logging coverage."
      },
      %{
        id: "reports-export",
        host: "host-d",
        base_path: "~/work/acme",
        worktree_path: "~/work/worktrees/test-coverage-reports-export",
        branch: "test/reports-export-coverage",
        validation_prefix: "docker compose run --rm app",
        title: "test: expand reports and export coverage",
        allowed: [
          "lib/one/reports/**",
          "lib/one/reports/renderers/**",
          "lib/one_web/controllers/report",
          "lib/one_web/controllers/export",
          "test/one/reports/**",
          "test/one_web/controllers/report",
          "test/one_web/controllers/export"
        ],
        forbidden: [
          "lib/one/api/**",
          "test/one/api/**",
          "lib/one_web/live/**",
          "test/one_web/live/**",
          "lib/one/workers/**",
          "test/one/workers/**"
        ],
        objective:
          "Expand report context, document build, filename, renderer adapter, artifact persistence/status, download authorization, empty data, malformed context, and export failure coverage."
      },
      %{
        id: "integrations-boundaries",
        host: "devbox",
        base_path: "/data/workspaces/dalexandre-twenty-one",
        worktree_path: "/data/workspaces/worktrees/test-coverage-integrations-boundaries",
        branch: "test/integrations-boundaries-coverage",
        validation_prefix: "mise exec --",
        title: "test: expand integration and boundary coverage",
        allowed: [
          "lib/one/integrations/**",
          "lib/one/integration",
          "lib/one/adapter",
          "lib/one/boundary",
          ".boundary.exs",
          "test/one/integrations/**",
          "test/one/integration",
          "test/one/adapter",
          "test/one/boundary"
        ],
        forbidden: [
          "lib/one/reports/**",
          "test/one/reports/**",
          "lib/one_web/live/**",
          "test/one_web/live/**",
          "lib/one_web/controllers/api/**",
          "test/one_web/controllers/api/**"
        ],
        objective:
          "Expand adapter success/failure, malformed payload, timeout/error tuple, telemetry/error path, public context API, boundary regression, and invalid external state coverage."
      }
    ]
    |> Enum.map(&assignment(run_id, baseline, base_branch, &1, run_path))
  end

  defp dynamic_coverage_assignments(run_id, baseline, opts, run_path) do
    with {:ok, modules} <- coverage_modules(opts),
         :ok <- require_coverage_modules(modules),
         {:ok, hosts} <- dynamic_hosts(opts),
         {:ok, risk_rules} <- coverage_risk_rules(opts) do
      assignments =
        modules
        |> balance_coverage_modules(length(hosts), risk_rules)
        |> Enum.with_index(1)
        |> Enum.map(fn {bucket, index} ->
          host = Enum.at(hosts, index - 1)
          dynamic_assignment_attrs(bucket, index, host, risk_rules, opts)
        end)
        |> Enum.reject(&(Map.get(&1, :modules, []) == []))
        |> Enum.map(fn attrs ->
          assignment(
            run_id,
            attrs.baseline || baseline,
            opts[:base_branch] || "develop",
            attrs,
            run_path
          )
        end)

      {:ok, assignments}
    end
  end

  defp coverage_modules(opts) do
    cond do
      is_list(opts[:coverage_modules]) ->
        opts[:coverage_modules]
        |> Enum.map(&normalize_coverage_module/1)
        |> Enum.reject(&is_nil/1)
        |> then(&{:ok, &1})

      is_binary(opts[:coverage_file]) and opts[:coverage_file] != "" ->
        load_coverage_file(opts[:coverage_file])

      true ->
        {:error, "coverage modules are required for dynamic coverage fanout"}
    end
  end

  defp require_coverage_modules([]), do: {:error, "coverage modules cannot be empty"}
  defp require_coverage_modules(_modules), do: :ok

  defp load_coverage_file(path) do
    with {:ok, text} <- File.read(path) do
      case Jason.decode(text) do
        {:ok, decoded} -> decoded_coverage_modules(decoded)
        {:error, _error} -> text_coverage_modules(text)
      end
    else
      {:error, reason} -> {:error, "could not read coverage file #{path}: #{inspect(reason)}"}
    end
  end

  defp decoded_coverage_modules(%{"modules" => modules}) when is_list(modules),
    do: decoded_coverage_modules(modules)

  defp decoded_coverage_modules(%{modules: modules}) when is_list(modules),
    do: decoded_coverage_modules(modules)

  defp decoded_coverage_modules(modules) when is_list(modules) do
    modules
    |> Enum.map(&normalize_coverage_module/1)
    |> Enum.reject(&is_nil/1)
    |> then(&{:ok, &1})
  end

  defp decoded_coverage_modules(_decoded),
    do: {:error, "coverage file must be a JSON list or map with a modules list"}

  defp text_coverage_modules(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.map(&parse_coverage_line/1)
    |> Enum.reject(&is_nil/1)
    |> then(&{:ok, &1})
  end

  defp parse_coverage_line(line) do
    parts =
      line
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    case parts do
      [module, path, coverage, risk | _rest] ->
        normalize_coverage_module(%{
          "module" => module,
          "path" => path,
          "coverage" => coverage,
          "risk" => risk
        })

      [path, coverage, risk] ->
        normalize_coverage_module(%{"path" => path, "coverage" => coverage, "risk" => risk})

      [path, coverage] ->
        normalize_coverage_module(%{"path" => path, "coverage" => coverage})

      [path] ->
        normalize_coverage_module(%{"path" => path})

      _other ->
        nil
    end
  end

  def normalize_coverage_module(attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    path = first_present([attrs["path"], attrs["file"], attrs["source"]])
    module = first_present([attrs["module"], attrs["name"], module_name_from_path(path)])

    if blank?(path) and blank?(module) do
      nil
    else
      %{
        module: module || path,
        path: path || module,
        coverage: parse_coverage(attrs["coverage"] || attrs["covered"]),
        risk: normalize_text(attrs["risk"] || "medium")
      }
    end
  end

  def normalize_coverage_module(value) when is_binary(value),
    do: normalize_coverage_module(%{"path" => value})

  def normalize_coverage_module(_value), do: nil

  def module_name_from_path(nil), do: nil

  def module_name_from_path(path) do
    path
    |> to_string()
    |> Path.basename(Path.extname(to_string(path)))
  end

  def parse_coverage(value) when is_number(value), do: value * 1.0

  def parse_coverage(value) when is_binary(value) do
    value =
      value
      |> String.trim()
      |> String.trim_trailing("%")

    case Float.parse(value) do
      {number, _rest} -> number
      :error -> 0.0
    end
  end

  def parse_coverage(_value), do: 0.0

  defp dynamic_hosts(opts) do
    hosts =
      opts
      |> Keyword.get_values(:host)
      |> Kernel.++(List.wrap(opts[:hosts]))
      |> List.flatten()
      |> Enum.reject(&blank?/1)

    host_count = opts[:host_count] || max(length(hosts), 1)

    if host_count < 1 do
      {:error, "host-count must be positive"}
    else
      hosts
      |> pad_dynamic_hosts(host_count)
      |> Enum.take(host_count)
      |> Enum.with_index(1)
      |> Enum.map(fn {host, index} -> normalize_dynamic_host(host, index, opts) end)
      |> then(&{:ok, &1})
    end
  end

  def pad_dynamic_hosts([], host_count) do
    Enum.map(1..host_count, &"host-#{&1}")
  end

  def pad_dynamic_hosts(hosts, host_count) when length(hosts) >= host_count, do: hosts

  def pad_dynamic_hosts(hosts, host_count) do
    hosts ++ Enum.map((length(hosts) + 1)..host_count, &"host-#{&1}")
  end

  defp normalize_dynamic_host(%{} = host, index, opts) do
    host = stringify_keys(host)
    name = first_present([host["name"], "host-#{index}"])
    worktree_root = first_present([host["worktree_root"], opts[:worktree_root], "/tmp/jx-fanout"])

    %{
      name: name,
      base_path: first_present([host["base_path"], opts[:base_path], "."]),
      worktree_root: worktree_root,
      validation_prefix:
        first_present([host["validation_prefix"], opts[:validation_prefix], "mise exec --"]),
      baseline: first_present([host["baseline"], opts[:baseline], nil])
    }
  end

  defp normalize_dynamic_host(host, index, opts) do
    {name, details} =
      host
      |> to_string()
      |> String.split("=", parts: 2)
      |> case do
        [name, details] -> {String.trim(name), String.trim(details)}
        [name] -> {String.trim(name), ""}
      end

    [base_path, worktree_root, validation_prefix, baseline] =
      details
      |> String.split(",", parts: 4)
      |> Enum.map(&String.trim/1)
      |> pad_list(4)

    normalize_dynamic_host(
      %{
        "name" => if(name == "", do: "host-#{index}", else: name),
        "base_path" => base_path,
        "worktree_root" => worktree_root,
        "validation_prefix" => validation_prefix,
        "baseline" => baseline
      },
      index,
      opts
    )
  end

  def pad_list(list, count) when length(list) >= count, do: list
  def pad_list(list, count), do: list ++ List.duplicate("", count - length(list))

  defp coverage_risk_rules(opts) do
    rules = opts[:risk_rules] || %{}

    cond do
      is_map(rules) ->
        {:ok, stringify_keys(rules)}

      is_binary(rules) and File.exists?(rules) ->
        with {:ok, text} <- File.read(rules),
             {:ok, decoded} <- Jason.decode(text) do
          {:ok, stringify_keys(decoded)}
        else
          {:error, reason} -> {:error, "could not read risk rules #{rules}: #{inspect(reason)}"}
        end

      is_binary(rules) and String.trim(rules) != "" ->
        case Jason.decode(rules) do
          {:ok, decoded} -> {:ok, stringify_keys(decoded)}
          {:error, _error} -> {:ok, %{"risk_weights" => parse_inline_risk_weights(rules)}}
        end

      true ->
        {:ok, %{}}
    end
  end

  defp parse_inline_risk_weights(text) do
    text
    |> String.split([",", ";"], trim: true)
    |> Enum.map(&String.split(&1, "=", parts: 2))
    |> Enum.reduce(%{}, fn
      [risk, weight], acc -> Map.put(acc, String.trim(risk), parse_integer(weight) || 0)
      _other, acc -> acc
    end)
  end

  def balance_coverage_modules(modules, host_count, risk_rules) do
    empty_buckets = Enum.map(1..host_count, fn _index -> %{score: 0.0, modules: []} end)

    modules
    |> Enum.sort_by(&coverage_score(&1, risk_rules), :desc)
    |> Enum.reduce(empty_buckets, fn module, buckets ->
      {bucket, index} =
        buckets
        |> Enum.with_index()
        |> Enum.min_by(fn {bucket, _index} -> bucket.score end)

      List.replace_at(buckets, index, %{
        bucket
        | score: bucket.score + coverage_score(module, risk_rules),
          modules: bucket.modules ++ [module]
      })
    end)
  end

  def coverage_score(module, risk_rules) do
    deficit = max(0.0, 100.0 - module.coverage)
    weights = Map.get(risk_rules, "risk_weights", %{})
    risk_weight = Map.get(weights, module.risk, Map.get(default_risk_weights(), module.risk, 15))
    deficit + risk_weight
  end

  def default_risk_weights do
    %{"critical" => 60, "high" => 35, "medium" => 15, "low" => 0}
  end

  defp dynamic_assignment_attrs(bucket, index, host, risk_rules, opts) do
    assignment_id = "coverage-#{String.pad_leading(to_string(index), 2, "0")}"
    modules = bucket.modules
    paths = Enum.map(modules, & &1.path)

    %{
      id: assignment_id,
      host: host.name,
      base_path: host.base_path,
      worktree_path: Path.join(host.worktree_root, "test-coverage-#{assignment_id}"),
      branch: "test/#{assignment_id}",
      validation_prefix: host.validation_prefix,
      baseline: host.baseline,
      title: "test: expand coverage packet #{index}",
      allowed: Enum.uniq(paths ++ Enum.map(paths, &test_path_for_source/1)),
      forbidden: normalize_list(Map.get(risk_rules, "forbidden_paths", [])),
      modules: modules,
      objective: dynamic_objective(modules, opts)
    }
  end

  def test_path_for_source("lib/" <> rest) do
    root = Path.rootname(rest)
    "test/#{root}_test.exs"
  end

  def test_path_for_source(path), do: path

  defp dynamic_objective(modules, opts) do
    prefix =
      opts[:objective] ||
        "Raise focused test coverage for the assigned low-coverage modules without editing outside the declared ownership scope."

    module_lines =
      modules
      |> Enum.map(fn module ->
        "#{module.module} (#{module.path}, #{format_coverage(module.coverage)}%, #{module.risk} risk)"
      end)
      |> Enum.join("; ")

    "#{prefix} Modules: #{module_lines}."
  end

  def format_coverage(number) when is_float(number) do
    :erlang.float_to_binary(number, decimals: 1)
  end

  def format_coverage(number), do: to_string(number)

  defp assignment(run_id, baseline, base_branch, attrs, run_path) do
    validation_sequence =
      Enum.map(
        [
          "mix deps.get",
          "mix format --check-formatted",
          "mix compile --warnings-as-errors",
          "mix test"
        ],
        &"#{attrs.validation_prefix} #{&1}"
      )

    %Assignment{
      run_id: run_id,
      assignment_id: attrs.id,
      state: "planned",
      excluded: false,
      intent: %{
        repo: attrs[:repo] || "example-project",
        base_branch: base_branch,
        baseline: baseline,
        branch: attrs.branch,
        validation_sequence: validation_sequence,
        pr: %{base: base_branch, title: attrs.title, draft: true},
        scope: %{allowed: attrs.allowed, forbidden: attrs.forbidden},
        task_objective: attrs.objective,
        agent_rules: @agent_rules
      },
      resolved_environment: %{
        host: attrs.host,
        base_path: attrs.base_path,
        worktree_path: attrs.worktree_path,
        validation_prefix: attrs.validation_prefix,
        baseline: baseline,
        assignment_start_commit: nil
      },
      preflight: nil,
      evidence: %{
        preflight_report: relative_path(run_path, Path.join(run_path, "preflight_report.md")),
        agent_packet: relative_path(run_path, Path.join(run_path, "agent_packet.md"))
      }
    }
  end

  defp write_run(run_path, manifest, assignments) do
    File.mkdir_p!(Path.join(run_path, "assignments"))
    File.mkdir_p!(Path.join(run_path, "reports"))

    write_json!(Path.join(run_path, "run_manifest.json"), to_map(manifest))
    write_text!(Path.join(run_path, "agent_packet.md"), agent_packet_text(manifest, assignments))
    write_text!(Path.join(run_path, "preflight_report.md"), preflight_report_text(assignments))

    Enum.each(assignments, fn assignment ->
      assignment_id = assignment.assignment_id

      File.mkdir_p!(Path.join([run_path, "reports", assignment_id, "accepted"]))
      File.mkdir_p!(Path.join([run_path, "reports", assignment_id, "rejected"]))
      write_json!(assignment_path(run_path, assignment_id), to_map(assignment))
    end)

    :ok
  end

  defp agent_packet_text(manifest, assignments) do
    assignment_lines =
      assignments
      |> Enum.map(fn assignment ->
        "- `#{assignment.assignment_id}`: #{get_in(assignment.intent, [:pr, :title])}"
      end)
      |> Enum.join("\n")

    """
    # jx fanout assignment contract

    Run: `#{manifest.run_id}`

    This packet is human-readable policy and task context. The JSON manifest and
    per-assignment files are the executable source of truth.

    `jx` is the control plane. It owns planning, preflight, launch eligibility,
    isolated worktree setup, leases, and evidence aggregation. Agents are the
    execution plane and may only perform bounded domain work inside their
    assigned `jx`-created worktree.

    This workflow is independent of `CLI-Tools`; target repositories are external
    workspaces managed by `jx`.

    ## Agent Rules

    #{Enum.map_join(@agent_rules, "\n", &"- #{&1}")}

    ## Assignments

    #{assignment_lines}
    """
  end

  defp preflight_report_text(assignments) do
    rows =
      Enum.map(assignments, fn assignment ->
        env = assignment.resolved_environment

        "| #{env.host} | #{env.base_path} | #{env.worktree_path} | #{assignment.state} | pending |"
      end)
      |> Enum.join("\n")

    """
    # Fanout Preflight Report

    Preflight has not run yet.

    | host | base_path | worktree_path | state | result |
    | --- | --- | --- | --- | --- |
    #{rows}
    """
  end

  defp preflight_assignment(
         run_path,
         _manifest,
         %{"excluded" => true} = assignment,
         checked_at,
         ttl_seconds,
         _opts
       ) do
    preflight = %{
      "publishability" => "skipped",
      "checked_at" => checked_at,
      "ttl_seconds" => ttl_seconds,
      "checks" => []
    }

    updated = Map.put(assignment, "preflight", preflight)
    :ok = write_assignment!(run_path, updated)

    %{
      assignment: updated,
      summary: preflight_summary(updated, preflight),
      result: "skipped"
    }
  end

  defp preflight_assignment(run_path, manifest, assignment, checked_at, ttl_seconds, opts) do
    script = preflight_script(manifest, assignment)

    {runner_status, output} =
      case run_assignment_script(assignment, script, opts) do
        {:ok, output} -> {:ok, output}
        {:error, reason} -> {:error, command_output(reason)}
      end

    checks = parse_preflight_checks(output, runner_status)
    publishability = if preflight_passed?(checks), do: "pass", else: "fail"
    state = if publishability == "pass", do: "preflight_passed", else: "preflight_failed"

    preflight = %{
      "publishability" => publishability,
      "checked_at" => checked_at,
      "ttl_seconds" => ttl_seconds,
      "checks" => checks,
      "output" => String.trim(output || ""),
      "script_sha256" => :crypto.hash(:sha256, script) |> Base.encode16(case: :lower)
    }

    updated =
      assignment
      |> Map.put("state", state)
      |> Map.put("preflight", preflight)

    :ok = write_assignment!(run_path, updated)

    %{
      assignment: updated,
      summary: preflight_summary(updated, preflight),
      result: publishability
    }
  end

  defp preflight_summary(assignment, preflight) do
    %{
      assignment_id: assignment["assignment_id"],
      host: get_in(assignment, ["resolved_environment", "host"]),
      state: assignment["state"],
      publishability: preflight["publishability"],
      checked_at: preflight["checked_at"],
      failed_checks:
        preflight["checks"]
        |> Enum.filter(&(Map.get(&1, "status") != "pass"))
        |> Enum.map(&Map.get(&1, "name"))
    }
  end

  defp fanout_preflight_result(updates) do
    cond do
      Enum.any?(updates, &(&1.result == "fail")) -> "fail"
      Enum.any?(updates, &(&1.result == "pass")) -> "pass"
      true -> "skipped"
    end
  end

  defp write_preflight_report(run_path, updates) do
    rows =
      updates
      |> Enum.map(fn update ->
        assignment = update.assignment
        preflight = assignment["preflight"] || %{}

        failed =
          preflight
          |> Map.get("checks", [])
          |> Enum.filter(&(Map.get(&1, "status") != "pass"))
          |> Enum.map(&Map.get(&1, "name"))
          |> Enum.join(", ")

        "| #{get_in(assignment, ["resolved_environment", "host"])} | #{assignment["assignment_id"]} | #{assignment["state"]} | #{preflight["publishability"]} | #{failed} |"
      end)
      |> Enum.join("\n")

    write_text!(
      Path.join(run_path, "preflight_report.md"),
      """
      # Fanout Preflight Report

      | host | assignment | state | result | failed checks |
      | --- | --- | --- | --- | --- |
      #{rows}
      """
    )
  end

  defp preflight_script(manifest, assignment) do
    env = assignment["resolved_environment"] || %{}
    intent = assignment["intent"] || %{}
    base_path = env["base_path"]
    worktree_path = env["worktree_path"]
    baseline = intent["baseline"] || manifest["baseline"]
    base_branch = manifest["base_branch"] || "develop"
    branch = intent["branch"]
    validation_prefix = env["validation_prefix"] || ""
    validation_bin = validation_prefix |> String.split(~r/\s+/, trim: true) |> List.first()

    validation_prefix_check =
      if blank?(validation_bin),
        do: "true",
        else: "command -v #{JX.Shell.quote(validation_bin)} >/dev/null"

    """
    set +e
    base=#{JX.Shell.quote(base_path)}
    worktree=#{JX.Shell.quote(worktree_path)}
    baseline=#{JX.Shell.quote(baseline)}
    base_branch=#{JX.Shell.quote(base_branch)}
    branch=#{JX.Shell.quote(branch)}
    failed=0

    emit_check() {
      name="$1"
      status="$2"
      detail="$(printf %s "$3" | tr '\\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g' | cut -c1-240)"
      printf 'JX_CHECK\\t%s\\t%s\\t%s\\n' "$name" "$status" "$detail"
    }

    check() {
      name="$1"
      command="$2"
      output="$(eval "$command" 2>&1)"
      status=$?
      if [ "$status" -eq 0 ]; then
        emit_check "$name" pass "$output"
      else
        failed=1
        emit_check "$name" fail "$output"
      fi
    }

    check clean_repo 'test -d "$base" && git -C "$base" diff --quiet && git -C "$base" diff --cached --quiet'
    check expected_head 'test "$(git -C "$base" rev-parse HEAD)" = "$baseline"'
    check fresh_worktree 'if git -C "$base" worktree list --porcelain | grep -F "worktree $worktree" >/dev/null; then exit 1; fi; if [ -e "$worktree" ] && [ -n "$(find "$worktree" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)" ]; then exit 1; fi'
    check assigned_branch 'if git -C "$base" show-ref --verify --quiet "refs/heads/$branch"; then test "$(git -C "$base" rev-parse "$branch")" = "$baseline"; else true; fi'
    check validation_prefix_known #{JX.Shell.quote(validation_prefix_check)}
    check mix_version_passes #{JX.Shell.quote("#{validation_prefix} mix --version >/dev/null")}
    check hook_health_passes 'hooks_path="$(git -C "$base" config --get core.hooksPath || true)"; if [ -z "$hooks_path" ]; then hooks_path="$base/.git/hooks"; elif [ "${hooks_path#/}" = "$hooks_path" ]; then hooks_path="$base/$hooks_path"; fi; for hook in pre-commit pre-push; do if [ -e "$hooks_path/$hook" ] && [ ! -x "$hooks_path/$hook" ]; then echo "$hook is not executable"; exit 1; fi; done'
    check github_auth_passes 'gh auth status >/dev/null'
    check dry_run_push_passes 'git -C "$base" push --dry-run origin "$baseline:refs/heads/$branch" >/dev/null'
    check base_branch_matches 'test "$(git -C "$base" rev-parse --abbrev-ref HEAD)" = "$base_branch"'

    exit "$failed"
    """
  end

  defp parse_preflight_checks(output, runner_status) do
    checks =
      output
      |> to_string()
      |> String.split("\n")
      |> Enum.flat_map(&parse_preflight_check_line/1)

    cond do
      checks != [] ->
        checks

      runner_status == :ok ->
        Enum.map(@preflight_check_names, &%{"name" => &1, "status" => "pass", "detail" => ""})

      true ->
        [%{"name" => "runner", "status" => "fail", "detail" => String.trim(to_string(output))}]
    end
  end

  defp parse_preflight_check_line("JX_CHECK\t" <> rest) do
    case String.split(rest, "\t", parts: 3) do
      [name, status, detail] -> [%{"name" => name, "status" => status, "detail" => detail}]
      [name, status] -> [%{"name" => name, "status" => status, "detail" => ""}]
      _other -> []
    end
  end

  defp parse_preflight_check_line(_line), do: []

  defp preflight_passed?(checks) do
    by_name = Map.new(checks, &{&1["name"], &1["status"]})
    Enum.all?(@preflight_check_names, &(Map.get(by_name, &1) == "pass"))
  end

  defp ensure_all_preflight_passed(assignments, opts) do
    now = opts[:now] || DateTime.utc_now()

    failures =
      assignments
      |> Enum.reject(&(&1["excluded"] == true))
      |> Enum.reject(&fresh_preflight_passed?(&1, now))
      |> Enum.map(& &1["assignment_id"])

    case failures do
      [] -> :ok
      _ -> {:error, {:preflight_required, failures}}
    end
  end

  defp fresh_preflight_passed?(assignment, now) do
    preflight = assignment["preflight"] || %{}

    preflight["publishability"] == "pass" and
      preflight_fresh?(preflight["checked_at"], preflight["ttl_seconds"], now)
  end

  defp preflight_fresh?(checked_at, ttl_seconds, now) do
    with {:ok, checked_at, _offset} <- DateTime.from_iso8601(to_string(checked_at)),
         ttl when is_integer(ttl) and ttl > 0 <- ttl_seconds do
      DateTime.diff(now, checked_at, :second) <= ttl
    else
      _other -> false
    end
  end

  defp launch_targets(assignments, :all),
    do: {:ok, Enum.reject(assignments, &(&1["excluded"] == true))}

  defp launch_targets(assignments, "all"), do: launch_targets(assignments, :all)

  defp launch_targets(assignments, assignment_id) do
    case Enum.find(assignments, &(&1["assignment_id"] == assignment_id)) do
      nil -> {:error, "unknown assignment #{inspect(assignment_id)}"}
      assignment -> {:ok, [assignment]}
    end
  end

  defp launch_assignment(run_path, manifest, assignment, launched_at, opts) do
    host_name = get_in(assignment, ["resolved_environment", "host"])

    case check_fanout_host_capacity(run_path, host_name) do
      {:error, reason} ->
        {:error,
         %{assignment_id: assignment["assignment_id"], reason: :host_at_capacity, detail: reason}}

      :ok ->
        do_launch_assignment(run_path, manifest, assignment, launched_at, opts)
    end
  end

  defp do_launch_assignment(run_path, manifest, assignment, launched_at, opts) do
    lease_timeout = opts[:lease_timeout_seconds] || @default_lease_timeout_seconds
    script = launch_script(manifest, assignment, launched_at, lease_timeout, opts)

    case run_assignment_script(assignment, script, opts) do
      {:ok, output} ->
        markers = parse_launch_markers(output)
        start_commit = markers["assignment_start_commit"]
        baseline = manifest["baseline"]

        if start_commit in [nil, "", baseline] do
          launch = %{
            "leased_at" => launched_at,
            "lease_timeout_seconds" => lease_timeout,
            "agent_id" => markers["agent_id"] || fanout_agent_id(manifest, assignment),
            "session_name" => markers["session_name"],
            "assignment_start_commit" => start_commit || baseline,
            "goal_objective" => get_in(assignment, ["intent", "task_objective"]),
            "goal_path" => markers["goal_path"],
            "goal_status_path" => markers["goal_status_path"],
            "goal_status" => "requested",
            "goal_requested_at" => launched_at,
            "output" => String.trim(output)
          }

          updated =
            assignment
            |> Map.put("state", "launching")
            |> put_in(
              ["resolved_environment", "assignment_start_commit"],
              launch["assignment_start_commit"]
            )
            |> Map.put("launch", launch)

          :ok = write_assignment!(run_path, updated)

          with :ok <- register_fanout_resources(manifest, assignment, launch, opts) do
            {:ok,
             %{
               assignment_id: assignment["assignment_id"],
               state: "launching",
               agent_id: launch["agent_id"],
               session_name: launch["session_name"],
               assignment_start_commit: launch["assignment_start_commit"],
               goal_status: launch["goal_status"]
             }}
          else
            {:error, reason} ->
              {:error,
               %{
                 assignment_id: assignment["assignment_id"],
                 reason: "resource_ownership_registration_failed",
                 detail: inspect(reason),
                 output: output
               }}
          end
        else
          {:error,
           %{
             assignment_id: assignment["assignment_id"],
             reason: "assignment_start_commit_mismatch",
             expected: baseline,
             actual: start_commit,
             output: output
           }}
        end

      {:error, reason} ->
        {:error,
         %{
           assignment_id: assignment["assignment_id"],
           reason: "launch_command_failed",
           detail: inspect(reason),
           output: command_output(reason)
         }}
    end
  end

  # Plan-time capacity check: group all targets by host and verify none would
  # exceed its capacity_limit before a single launch script fires.
  defp preflight_capacity(run_path, targets) do
    planned_by_host =
      Enum.reduce(targets, %{}, fn assignment, acc ->
        host_name = get_in(assignment, ["resolved_environment", "host"])
        Map.update(acc, host_name, 1, &(&1 + 1))
      end)

    # Accurate per-host active counts from the run directory.
    active_by_host = active_fanout_assignments_per_host(run_path)

    violations =
      Enum.flat_map(planned_by_host, fn {host_name, planned} ->
        case JX.Hosts.get_host_by_name(host_name) do
          %{capacity_limit: limit, name: name} when is_integer(limit) ->
            host_active = Map.get(active_by_host, host_name, 0)

            if host_active + planned > limit do
              [
                "host #{name}: #{planned} planned + #{host_active} active would exceed limit #{limit}"
              ]
            else
              []
            end

          _ ->
            []
        end
      end)

    case violations do
      [] -> :ok
      _ -> {:error, {:capacity_preflight_failed, violations}}
    end
  end

  defp check_fanout_host_capacity(_run_path, nil), do: :ok

  defp check_fanout_host_capacity(run_path, host_name) do
    case JX.Hosts.get_host_by_name(host_name) do
      nil ->
        :ok

      %{capacity_limit: nil} ->
        :ok

      %{capacity_limit: limit, name: name} ->
        active = Map.get(active_fanout_assignments_per_host(run_path), host_name, 0)

        if active < limit do
          :ok
        else
          {:error,
           "host #{name} is at capacity (#{active}/#{limit} active fanout assignments); " <>
             "wait for assignments to complete or raise: jx host capacity set #{name} <n>"}
        end
    end
  end

  defp register_fanout_resources(manifest, assignment, launch, opts) do
    env = assignment["resolved_environment"] || %{}
    run_id = manifest["run_id"]
    assignment_id = assignment["assignment_id"]
    owner_project = "fanout:#{run_id}"
    session_name = launch["session_name"] || fanout_session_name(run_id, assignment_id)
    tmux_server = opts[:tmux_server] || "jx"
    worktree_path = env["worktree_path"]
    goal_path = launch["goal_path"]
    goal_dir = if is_binary(goal_path), do: Path.dirname(goal_path), else: nil
    metadata = fanout_resource_metadata(manifest, assignment, launch)

    [
      {:temp_path,
       %{
         owner_project: owner_project,
         assignment_id: assignment_id,
         execution_id: session_name,
         resource_type: "worktree_path",
         resource_name: "#{run_id}:#{assignment_id}:worktree",
         resource_path: worktree_path,
         reason: "fanout assignment worktree",
         metadata: metadata
       }},
      {:temp_path,
       %{
         owner_project: owner_project,
         assignment_id: assignment_id,
         execution_id: session_name,
         resource_type: "temp_path",
         resource_name: "#{run_id}:#{assignment_id}:goal_dir",
         resource_path: goal_dir,
         reason: "fanout assignment goal directory",
         metadata: metadata
       }},
      {:tmux_session,
       %{
         owner_project: owner_project,
         assignment_id: assignment_id,
         execution_id: session_name,
         resource_name: session_name,
         tmux_server: tmux_server,
         reason: "fanout assignment tmux session",
         metadata: metadata
       }}
    ]
    |> Enum.reject(fn
      {_kind, %{resource_name: name}} when name in [nil, ""] -> true
      {:temp_path, attrs} -> Map.get(attrs, :resource_path) == nil
      _other -> false
    end)
    |> Enum.reduce_while(:ok, fn {kind, attrs}, :ok ->
      case register_fanout_resource(kind, attrs) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp register_fanout_resource(:tmux_session, attrs) do
    case resource_ownerships().register_tmux_session(attrs) do
      {:ok, _resource} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp register_fanout_resource(:temp_path, attrs) do
    case resource_ownerships().register_temp_path(attrs) do
      {:ok, _resource} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp fanout_resource_metadata(manifest, assignment, launch) do
    Jason.encode!(%{
      run_id: manifest["run_id"],
      assignment_id: assignment["assignment_id"],
      repo: manifest["repo"],
      agent_id: launch["agent_id"],
      session_name: launch["session_name"]
    })
  end

  defp resource_ownerships do
    Application.get_env(:jx, :resource_ownerships, JX.ResourceOwnerships)
  end

  defp launch_script(manifest, assignment, launched_at, lease_timeout, opts) do
    env = assignment["resolved_environment"] || %{}
    intent = assignment["intent"] || %{}
    run_id = manifest["run_id"]
    assignment_id = assignment["assignment_id"]
    base_path = env["base_path"]
    worktree_path = env["worktree_path"]
    branch = intent["branch"]
    baseline = intent["baseline"] || manifest["baseline"]
    objective = intent["task_objective"] || ""
    agent_name = opts[:agent] || "codex"
    agent_bin = opts[:agent_bin] || agent_binary(agent_name)
    tmux_server = opts[:tmux_server] || "jx"
    session_name = fanout_session_name(run_id, assignment_id)
    goal_dir = Path.join([worktree_path, ".jx", "fanout", run_id, assignment_id])
    goal_path = Path.join(goal_dir, "goal.md")
    prompt_path = Path.join(goal_dir, "prompt.md")
    goal_status_path = Path.join(goal_dir, "goal_status.json")
    goal_completion_path = Path.join(goal_dir, "goal_completion.json")
    agent_script_path = Path.join(goal_dir, "launch_agent_goal.sh")
    agent_id = fanout_agent_id(manifest, assignment, agent_name)

    requested_status =
      Jason.encode!(%{
        status: "requested",
        requested_at: launched_at,
        objective: objective,
        goal_path: goal_path,
        prompt_path: prompt_path
      })

    agent_command =
      build_agent_command(
        agent_name,
        agent_bin,
        worktree_path: worktree_path,
        goal_path: goal_path,
        prompt_path: prompt_path
      )

    """
    set -eu
    base=#{JX.Shell.quote(base_path)}
    worktree=#{JX.Shell.quote(worktree_path)}
    branch=#{JX.Shell.quote(branch)}
    baseline=#{JX.Shell.quote(baseline)}
    goal_dir=#{JX.Shell.quote(goal_dir)}
    goal_path=#{JX.Shell.quote(goal_path)}
    prompt_path=#{JX.Shell.quote(prompt_path)}
    goal_status_path=#{JX.Shell.quote(goal_status_path)}
    goal_completion_path=#{JX.Shell.quote(goal_completion_path)}
    agent_script_path=#{JX.Shell.quote(agent_script_path)}
    session_name=#{JX.Shell.quote(session_name)}
    agent_id=#{JX.Shell.quote(agent_id)}

    if [ ! -d "$base/.git" ] && [ ! -f "$base/.git" ]; then
      echo "repo path is not a git checkout: $base" >&2
      exit 1
    fi

    mkdir -p "$(dirname "$worktree")" "$goal_dir"
    printf %s #{JX.Shell.quote(objective)} > "$goal_path"
    printf '%s\\n' #{JX.Shell.quote(agent_prompt_text(manifest, assignment))} > "$prompt_path"
    printf %s #{JX.Shell.quote(requested_status)} > "$goal_status_path"

    if [ ! -d "$worktree/.git" ] && [ ! -f "$worktree/.git" ]; then
      if [ -e "$worktree" ] && [ -n "$(find "$worktree" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)" ]; then
        echo "worktree path exists and is not empty: $worktree" >&2
        exit 1
      fi
      git -C "$base" worktree add -B "$branch" "$worktree" "$baseline"
    fi

    actual="$(git -C "$worktree" rev-parse HEAD)"
    if [ "$actual" != "$baseline" ]; then
      echo "assignment start commit mismatch: expected $baseline got $actual" >&2
      exit 1
    fi

    current_branch="$(git -C "$worktree" rev-parse --abbrev-ref HEAD)"
    if [ "$current_branch" != "$branch" ]; then
      echo "assignment branch mismatch: expected $branch got $current_branch" >&2
      exit 1
    fi

    printf 'JX_LAUNCH\\tassignment_start_commit\\t%s\\n' "$actual"
    printf 'JX_LAUNCH\\tagent_id\\t%s\\n' "$agent_id"
    printf 'JX_LAUNCH\\tsession_name\\t%s\\n' "$session_name"
    printf 'JX_LAUNCH\\tgoal_path\\t%s\\n' "$goal_path"
    printf 'JX_LAUNCH\\tgoal_status_path\\t%s\\n' "$goal_status_path"
    printf 'JX_LAUNCH\\tgoal_requested_at\\t%s\\n' #{JX.Shell.quote(launched_at)}
    printf 'JX_LAUNCH\\tlease_timeout_seconds\\t%s\\n' #{JX.Shell.quote(lease_timeout)}

    cat > "$agent_script_path" <<'JX_AGENT_GOAL'
    #!/bin/sh
    set +e
    #{agent_command}
    status=$?
    completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ "$status" -eq 0 ]; then goal_state=completed; else goal_state=failed; fi
    printf '{"status":"%s","completed_at":"%s","exit_status":%s}\\n' "$goal_state" "$completed_at" "$status" > #{JX.Shell.quote(goal_completion_path)}
    cat #{JX.Shell.quote(goal_completion_path)} > #{JX.Shell.quote(goal_status_path)}
    exit "$status"
    JX_CODEX_GOAL
    chmod +x "$agent_script_path"

    if command -v tmux >/dev/null 2>&1; then
      if ! tmux -L #{JX.Shell.quote(tmux_server)} has-session -t "$session_name" 2>/dev/null; then
        tmux -L #{JX.Shell.quote(tmux_server)} new-session -d -s "$session_name" "$agent_script_path"
      fi
    else
      echo "tmux not found" >&2
      exit 1
    fi
    """
  end

  defp parse_launch_markers(output) do
    output
    |> to_string()
    |> String.split("\n")
    |> Enum.flat_map(fn
      "JX_LAUNCH\t" <> rest ->
        case String.split(rest, "\t", parts: 2) do
          [key, value] -> [{key, value}]
          _other -> []
        end

      _line ->
        []
    end)
    |> Map.new()
  end

  defp diff_paths(manifest, assignment, opts) do
    case opts[:diff_paths] do
      paths when is_list(paths) ->
        {:ok, Enum.map(paths, &to_string/1)}

      _other ->
        run_diff_paths(manifest, assignment, opts)
    end
  end

  defp run_diff_paths(manifest, assignment, opts) do
    script = diff_script(manifest, assignment)

    case run_assignment_script(assignment, script, opts) do
      {:ok, output} ->
        paths =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        {:ok, paths}

      {:error, reason} ->
        {:error, {:diff_failed, reason}}
    end
  end

  defp diff_script(manifest, assignment) do
    env = assignment["resolved_environment"] || %{}
    worktree_path = env["worktree_path"]
    baseline = get_in(assignment, ["intent", "baseline"]) || manifest["baseline"]

    """
    set -eu
    worktree=#{JX.Shell.quote(worktree_path)}
    baseline=#{JX.Shell.quote(baseline)}
    git -C "$worktree" diff --name-only "$baseline...HEAD"
    """
  end

  defp ownership_review(paths, scope) do
    allowed = normalize_list(Map.get(scope, "allowed", []))
    forbidden = normalize_list(Map.get(scope, "forbidden", []))

    forbidden_touches =
      paths
      |> Enum.filter(&(forbidden != [] and matches_any_path?(&1, forbidden)))
      |> Enum.uniq()

    outside_allowed =
      if allowed == [] do
        []
      else
        paths
        |> Enum.reject(&matches_any_path?(&1, allowed))
        |> Enum.reject(&matches_any_path?(&1, forbidden))
        |> Enum.uniq()
      end

    status =
      if forbidden_touches == [] and outside_allowed == [] do
        "passed"
      else
        "failed"
      end

    %{
      "status" => status,
      "diff_paths" => paths,
      "allowed" => allowed,
      "forbidden" => forbidden,
      "outside_write_paths" => outside_allowed,
      "forbidden_touches" => forbidden_touches,
      "warnings" => ownership_warnings(outside_allowed, forbidden_touches)
    }
  end

  defp ownership_warnings(outside_allowed, forbidden_touches) do
    []
    |> warn_if(outside_allowed != [], "diff includes paths outside declared write ownership")
    |> warn_if(forbidden_touches != [], "diff touches forbidden paths")
  end

  defp matches_any_path?(_path, []), do: false
  defp matches_any_path?(path, patterns), do: Enum.any?(patterns, &path_match?(&1, path))

  defp path_match?(pattern, path) do
    pattern = normalize_repo_path(pattern)
    path = normalize_repo_path(path)

    cond do
      pattern == "" ->
        false

      pattern == path ->
        true

      String.ends_with?(pattern, "/**") ->
        String.starts_with?(path, String.trim_trailing(pattern, "/**") <> "/")

      String.ends_with?(pattern, "/*") ->
        path |> Path.dirname() |> Kernel.==(String.trim_trailing(pattern, "/*"))

      String.contains?(pattern, "*") ->
        glob_regex(pattern) |> Regex.match?(path)

      true ->
        String.starts_with?(path, pattern <> "/")
    end
  end

  defp glob_regex(pattern) do
    pattern
    |> Regex.escape()
    |> String.replace("\\*\\*", ".*")
    |> String.replace("\\*", "[^/]*")
    |> then(&Regex.compile!("^#{&1}$"))
  end

  defp normalize_repo_path(path) do
    path
    |> to_string()
    |> String.trim()
    |> String.replace("\\", "/")
    |> String.split("/", trim: true)
    |> normalize_path_segments([])
    |> Enum.join("/")
  end

  defp ensure_local_validated(run_path, assignment, opts) do
    latest = latest_report(run_path, assignment["assignment_id"])
    state = (latest && latest["state"]) || assignment["state"]

    cond do
      opts[:allow_unvalidated] -> :ok
      state in ["local_validated", "ready", "complete"] -> :ok
      true -> {:error, {:local_validation_required, assignment["assignment_id"]}}
    end
  end

  defp create_pr(manifest, assignment, opened_at, opts) do
    script = pr_script(manifest, assignment, opened_at, opts)

    case run_assignment_script(assignment, script, opts) do
      {:ok, output} ->
        markers = parse_pr_markers(output)
        url = markers["url"] || String.trim(output)

        if blank?(url) do
          {:error, {:pr_create_failed, "missing PR URL"}}
        else
          {:ok,
           %{
             "url" => url,
             "number" => pr_number(url),
             "repo" => opts[:repo] || pr_repo(url),
             "head_sha" => markers["head_sha"],
             "opened_at" => opened_at,
             "output" => String.trim(output)
           }}
        end

      {:error, reason} ->
        {:error, {:pr_create_failed, reason}}
    end
  end

  defp pr_script(_manifest, assignment, _opened_at, _opts) do
    env = assignment["resolved_environment"] || %{}
    intent = assignment["intent"] || %{}
    pr = intent["pr"] || %{}
    worktree_path = env["worktree_path"]
    branch = intent["branch"]
    base = pr["base"] || "develop"
    title = pr["title"] || assignment["assignment_id"]
    draft = if pr["draft"] == false, do: "", else: "--draft"
    body = pr_body(assignment)

    """
    set -eu
    worktree=#{JX.Shell.quote(worktree_path)}
    branch=#{JX.Shell.quote(branch)}
    base=#{JX.Shell.quote(base)}
    title=#{JX.Shell.quote(title)}
    body=#{JX.Shell.quote(body)}
    head_sha="$(git -C "$worktree" rev-parse HEAD)"
    cd "$worktree"
    url="$(gh pr create --base "$base" --head "$branch" --title "$title" #{draft} --body "$body")"
    printf 'JX_PR\\turl\\t%s\\n' "$url"
    printf 'JX_PR\\thead_sha\\t%s\\n' "$head_sha"
    """
  end

  defp pr_body(assignment) do
    """
    Fanout assignment: #{assignment["assignment_id"]}

    #{get_in(assignment, ["intent", "task_objective"])}

    Generated by jx fanout.
    """
  end

  defp parse_pr_markers(output) do
    output
    |> to_string()
    |> String.split("\n")
    |> Enum.flat_map(fn
      "JX_PR\t" <> rest ->
        case String.split(rest, "\t", parts: 2) do
          [key, value] -> [{key, value}]
          _other -> []
        end

      _line ->
        []
    end)
    |> Map.new()
  end

  defp maybe_register_ci_watch(manifest, assignment, pr, opts) do
    attrs = ci_watch_attrs(manifest, assignment, pr, opts)

    cond do
      is_function(opts[:ci_watch_fun], 1) ->
        case opts[:ci_watch_fun].(attrs) do
          {:ok, watch} -> jsonish_watch(watch)
          watch when is_map(watch) -> jsonish_watch(watch)
          _other -> nil
        end

      Keyword.get(opts, :register_ci_watch, true) ->
        register_ci_watch(attrs)

      true ->
        nil
    end
  end

  defp register_ci_watch(%{repo: repo, pr_number: pr_number} = attrs)
       when is_binary(repo) and repo != "" and is_integer(pr_number) and pr_number > 0 do
    case JX.CiWatches.add_watch(attrs) do
      {:ok, watch} -> jsonish_watch(watch)
      _other -> nil
    end
  rescue
    _error -> nil
  end

  defp register_ci_watch(_attrs), do: nil

  defp ci_watch_attrs(manifest, assignment, pr, opts) do
    %{
      repo: pr["repo"] || opts[:repo] || manifest["repo"],
      pr_number: pr["number"],
      ref: assignment["assignment_id"],
      project: manifest["repo"],
      head_sha: pr["head_sha"] || "",
      mode: opts[:ci_watch_mode] || "notify",
      goal: "fanout #{manifest["run_id"]} #{assignment["assignment_id"]} CI"
    }
  end

  defp maybe_put_ci_watch(assignment, nil), do: assignment

  defp maybe_put_ci_watch(assignment, ci_watch),
    do: put_in(assignment, ["evidence", "ci_watch"], ci_watch)

  defp jsonish_watch(nil), do: nil

  defp jsonish_watch(watch) do
    %{
      "watch_id" => map_field(watch, :watch_id),
      "status" => map_field(watch, :status) || "active",
      "repo" => map_field(watch, :repo),
      "pr_number" => map_field(watch, :pr_number),
      "head_sha" => map_field(watch, :head_sha)
    }
  end

  defp pr_number(url) when is_binary(url) do
    case Regex.run(~r{/pull/(\d+)}, url) do
      [_match, number] -> parse_integer(number)
      _other -> nil
    end
  end

  defp pr_number(_url), do: nil

  defp pr_repo(url) when is_binary(url) do
    case Regex.run(~r{github\.com[:/](?<owner>[^/\s]+)/(?<repo>[^/\s]+?)(?:\.git)?/pull/\d+}, url) do
      [_match, owner, repo] -> "#{owner}/#{repo}"
      _other -> nil
    end
  end

  defp pr_repo(_url), do: nil

  # Number of retries for container-backed hosts where startup latency is high.
  @container_max_retries 3
  @container_retry_delay_ms 5_000

  defp run_assignment_script(assignment, script, opts) do
    runner = opts[:runner]

    cond do
      is_function(runner, 2) ->
        runner.(assignment, script)

      is_function(runner, 1) ->
        runner.(script)

      true ->
        default_assignment_runner(assignment, script)
    end
  end

  defp default_assignment_runner(assignment, script) do
    host = get_in(assignment, ["resolved_environment", "host"])
    validation_prefix = get_in(assignment, ["resolved_environment", "validation_prefix"]) || ""
    container_host? = String.contains?(validation_prefix, "docker")

    max_retries = if container_host?, do: @container_max_retries, else: 0
    retry_delay = if container_host?, do: @container_retry_delay_ms, else: 0

    run_with_retries(host, script, max_retries, retry_delay, 0)
  end

  defp run_with_retries(host, script, max_retries, retry_delay_ms, attempt) do
    result =
      if local_host?(host) do
        case System.cmd("sh", ["-lc", script], stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          {output, status} -> {:error, {:command_failed, status, output}}
        end
      else
        case System.cmd(
               "ssh",
               [
                 "-o",
                 "BatchMode=yes",
                 "-o",
                 "ConnectTimeout=10",
                 "--",
                 host,
                 "sh -lc #{JX.Shell.quote(script)}"
               ],
               stderr_to_stdout: true
             ) do
          {output, 0} -> {:ok, output}
          {output, status} -> {:error, {:ssh_failed, status, output}}
        end
      end

    case result do
      {:ok, _} ->
        result

      {:error, _} when attempt < max_retries ->
        Logger.debug(
          "[Fanout] script failed on #{host} (attempt #{attempt + 1}/#{max_retries + 1}), " <>
            "retrying in #{retry_delay_ms}ms"
        )

        Process.sleep(retry_delay_ms)
        run_with_retries(host, script, max_retries, retry_delay_ms, attempt + 1)

      {:error, _} ->
        result
    end
  end

  defp local_host?(host) do
    host in [nil, "", "localhost", "127.0.0.1", System.get_env("HOSTNAME")]
  end

  defp command_output({_kind, _status, output}) when is_binary(output), do: output
  defp command_output(output) when is_binary(output), do: output
  defp command_output(reason), do: inspect(reason)

  defp fanout_agent_id(manifest, assignment, agent_name \\ "codex") do
    "#{agent_name}-#{manifest["run_id"]}-#{assignment["assignment_id"]}"
  end

  defp fanout_session_name(run_id, assignment_id) do
    "jx_fanout_#{safe_session_part(run_id)}_#{safe_session_part(assignment_id)}"
  end

  defp safe_session_part(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_]/, "_")
  end

  defp agent_binary(agent_name) do
    binaries = Application.get_env(:jx, :agent_binaries, %{})
    Map.get(binaries, agent_name, agent_name)
  end

  defp build_agent_command(agent_name, agent_bin, bindings) do
    commands = Application.get_env(:jx, :agent_commands, %{})
    command_template = Map.get(commands, agent_name, default_agent_command(agent_name))

    command_template
    |> String.replace("{{agent_bin}}", JX.Shell.quote(agent_bin))
    |> String.replace("{{worktree_path}}", JX.Shell.quote(bindings[:worktree_path] || ""))
    |> String.replace("{{prompt_path}}", JX.Shell.quote(bindings[:prompt_path] || ""))
    |> String.replace("{{goal_path}}", JX.Shell.quote(bindings[:goal_path] || ""))
  end

  defp default_agent_command("codex") do
    "{{agent_bin}} exec --dangerously-bypass-approvals-and-sandbox -C {{worktree_path}} --goal {{goal_path}}"
  end

  defp default_agent_command("claude") do
    "{{agent_bin}} -p --dangerously-skip-permissions < {{prompt_path}}"
  end

  defp default_agent_command("opencode") do
    "{{agent_bin}} run --dir {{worktree_path}} --dangerously-skip-permissions \"Read the attached prompt file and complete the task.\" --file {{prompt_path}}"
  end

  defp default_agent_command(_agent_name) do
    "{{agent_bin}} < {{prompt_path}}"
  end

  defp agent_prompt_text(manifest, assignment) do
    intent = assignment["intent"] || %{}
    scope = intent["scope"] || %{}
    run_id = manifest["run_id"]
    assignment_id = assignment["assignment_id"]

    """
    You are working under jx fanout control.

    Run: #{run_id}
    Assignment: #{assignment_id}
    Branch: #{intent["branch"]}
    Baseline: #{manifest["baseline"]}

    Objective:
    #{intent["task_objective"]}

    Allowed paths:
    #{Enum.map_join(normalize_list(scope["allowed"]), "\n", &"- #{&1}")}

    Forbidden paths:
    #{Enum.map_join(normalize_list(scope["forbidden"]), "\n", &"- #{&1}")}

    ## Reporting

    Submit status updates back to jx with:

      jx fanout report #{run_id} --assignment-id #{assignment_id} --report-id <id> --agent-id <id> --sequence <n> --state <state> [--previous-report-id <id>] [--data <json>]

    Valid states: #{Enum.join(@agent_states, ", ")}
    """
  end

  defp latest_report(run_path, assignment_id) do
    run_path
    |> accepted_reports(assignment_id)
    |> List.last()
  end

  defp monitor_assignment(run_path, assignment, opts) do
    case refresh_assignment_ci_watch(assignment, opts) do
      nil ->
        %{
          assignment_id: assignment["assignment_id"],
          derived_state: assignment["state"],
          completion_state:
            completion_state(
              assignment,
              latest_report(run_path, assignment["assignment_id"]),
              assignment["state"]
            ),
          ci_watch: get_in(assignment, ["evidence", "ci_watch"])
        }

      ci_watch ->
        state = fanout_state_for_ci_watch(ci_watch)

        updated =
          assignment
          |> Map.put("state", state)
          |> put_in(["evidence", "ci_watch"], ci_watch)

        :ok = write_assignment!(run_path, updated)

        %{
          assignment_id: updated["assignment_id"],
          derived_state: state,
          completion_state:
            completion_state(updated, latest_report(run_path, updated["assignment_id"]), state),
          ci_watch: ci_watch
        }
    end
  end

  defp refresh_assignment_ci_watch(assignment, opts) do
    watch = get_in(assignment, ["evidence", "ci_watch"])
    watch_id = watch && watch["watch_id"]

    cond do
      blank?(watch_id) ->
        nil

      is_function(opts[:ci_watch_status_fun], 1) ->
        opts[:ci_watch_status_fun].(watch_id) |> jsonish_watch()

      true ->
        review_ci_watch(watch_id)
    end
  end

  defp review_ci_watch(watch_id) do
    case JX.CiWatches.review_watch(watch_id, logs: false) do
      {:ok, %{watch: watch}} -> jsonish_watch(watch)
      {:ok, watch} -> jsonish_watch(watch)
      _other -> nil
    end
  rescue
    _error -> nil
  end

  defp fanout_state_for_ci_watch(%{"status" => "passed"}), do: "ci_green"
  defp fanout_state_for_ci_watch(%{"status" => "failed"}), do: "ci_failed"
  defp fanout_state_for_ci_watch(%{"status" => "cancelled"}), do: "ci_failed"
  defp fanout_state_for_ci_watch(%{"status" => "superseded"}), do: "ci_failed"
  defp fanout_state_for_ci_watch(%{"status" => "active"}), do: "ci_pending"
  defp fanout_state_for_ci_watch(_watch), do: "ci_pending"

  defp assignment_status(run_path, assignment) do
    reports = accepted_reports(run_path, assignment["assignment_id"])
    latest_report = List.last(reports)

    derived_state =
      cond do
        assignment["excluded"] -> "excluded"
        latest_report -> latest_report["state"]
        true -> assignment["state"]
      end

    completion_state = completion_state(assignment, latest_report, derived_state)

    %{
      assignment_id: assignment["assignment_id"],
      host: get_in(assignment, ["resolved_environment", "host"]),
      branch: get_in(assignment, ["intent", "branch"]),
      orchestration_state: assignment["state"],
      derived_state: derived_state,
      completion_state: completion_state,
      excluded: assignment["excluded"] || false,
      report_count: length(reports),
      latest_report_id: latest_report && latest_report["report_id"],
      pr_url:
        (latest_report && get_in(latest_report, ["data", "pr_url"])) ||
          get_in(assignment, ["evidence", "pr", "url"]),
      ci_watch: get_in(assignment, ["evidence", "ci_watch"]),
      goal_status:
        get_in(assignment, ["launch", "goal_status"]) ||
          (latest_report && get_in(latest_report, ["data", "goal_status"]))
    }
  end

  defp completion_state(assignment, latest_report, derived_state) do
    ci_status =
      get_in(assignment, ["evidence", "ci_watch", "status"]) ||
        (latest_report && get_in(latest_report, ["data", "ci_status"]))

    cond do
      ci_status in ["passed", "ci_green"] -> "CI green"
      ci_status in ["failed", "ci_failed"] -> "CI failed"
      ci_status in ["active", "pending", "ci_pending"] -> "CI pending"
      derived_state == "complete" -> "ready"
      true -> Map.get(@completion_states, derived_state, derived_state || "unknown")
    end
  end

  defp status_counts(rows) do
    Enum.reduce(rows, %{}, fn row, acc ->
      Map.update(acc, row.derived_state, 1, &(&1 + 1))
    end)
  end

  defp validate_report(%AssignmentReport{} = report, assignment, run_path) do
    accepted = accepted_reports(run_path, report.assignment_id)
    latest = List.last(accepted)
    expected_sequence = length(accepted) + 1
    expected_previous = latest && latest["report_id"]

    cond do
      report.state not in @report_states ->
        {:error, rejection(report, "invalid_state", %{"received_state" => report.state}), report}

      assignment["excluded"] ->
        {:error, rejection(report, "assignment_excluded", %{}), report}

      report.sequence != expected_sequence ->
        {:error,
         rejection(report, "sequence_mismatch", %{
           "expected_sequence" => expected_sequence,
           "received_sequence" => report.sequence
         }), report}

      report.previous_report_id != expected_previous ->
        {:error,
         rejection(report, "previous_report_mismatch", %{
           "expected_previous_report_id" => expected_previous,
           "received_previous_report_id" => report.previous_report_id
         }), report}

      accepted_report_exists?(run_path, report) ->
        {:error, rejection(report, "report_already_exists", %{}), report}

      true ->
        :ok
    end
  end

  defp write_accepted_report(run_path, report) do
    path = accepted_report_path(run_path, report)
    File.mkdir_p!(Path.dirname(path))

    case write_new_json(path, to_map(report)) do
      :ok -> {:ok, %{status: :accepted, path: path, report: to_map(report)}}
      {:error, reason} -> {:error, "could not write accepted report: #{reason}"}
    end
  end

  defp write_rejected_report(run_ref, %AssignmentReport{} = report, rejection, opts) do
    with {:ok, run_path} <- resolve_run_path(run_ref, opts[:root] || ".jx/runs") do
      path = rejected_report_path(run_path, report)
      File.mkdir_p!(Path.dirname(path))

      payload =
        Map.merge(rejection, %{
          "original_report" => to_map(report),
          "original_report_path" => relative_path(run_path, path)
        })

      case write_new_json(path, payload) do
        :ok -> {:error, rejection["reason"], %{status: :rejected, path: path, rejection: payload}}
        {:error, reason} -> {:error, "could not write rejected report: #{reason}"}
      end
    end
  end

  defp write_rejected_report(_run_ref, _report, reason, _opts), do: {:error, reason}

  defp rejection(report, reason, data) do
    %{
      "rejected_report_id" =>
        "#{DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()}-rejected",
      "original_report_id" => report.report_id,
      "assignment_id" => report.assignment_id,
      "rejected_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "reason" => reason
    }
    |> Map.merge(data)
  end

  defp normalize_report(attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    report = %AssignmentReport{
      report_id: normalize_text(attrs["report_id"]),
      assignment_id: normalize_text(attrs["assignment_id"]),
      agent_id: normalize_text(attrs["agent_id"]),
      sequence: attrs["sequence"],
      previous_report_id: attrs["previous_report_id"],
      state: normalize_text(attrs["state"]),
      reported_at: normalize_text(attrs["reported_at"]),
      data: attrs["data"] || %{}
    }

    missing =
      [:report_id, :assignment_id, :agent_id, :sequence, :state, :reported_at]
      |> Enum.filter(fn field -> blank?(Map.fetch!(Map.from_struct(report), field)) end)

    cond do
      missing != [] -> {:error, "report missing required fields: #{Enum.join(missing, ", ")}"}
      not is_integer(report.sequence) -> {:error, "report sequence must be an integer"}
      true -> validate_report_path_ids(report)
    end
  end

  defp accepted_reports(run_path, assignment_id) do
    with :ok <- validate_path_id(assignment_id, "assignment id"),
         {:ok, path} <-
           safe_child_path(run_path, ["reports", assignment_id, "accepted", "*.json"]) do
      path
      |> Path.wildcard()
      |> Enum.map(&read_json!/1)
      |> Enum.sort_by(& &1["sequence"])
    else
      {:error, _reason} -> []
    end
  end

  defp read_assignments(run_path) do
    assignments =
      Path.join([run_path, "assignments", "*.json"])
      |> Path.wildcard()
      |> Enum.map(&read_json!/1)

    {:ok, assignments}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp read_assignment(run_path, assignment_id) do
    path = assignment_path(run_path, assignment_id)

    case read_json(path) do
      {:ok, assignment} -> {:ok, assignment}
      {:error, _reason} -> {:error, "unknown assignment #{inspect(assignment_id)}"}
    end
  end

  # States where we want a capacity snapshot: entering active work or leaving it.
  @snapshot_states ~w(launching preflight_failed ci_green ci_failed ready)

  defp write_assignment!(run_path, assignment) do
    assignment_id = Map.fetch!(assignment, "assignment_id")
    write_json!(assignment_path(run_path, assignment_id), assignment)

    if Map.get(assignment, "state") in @snapshot_states do
      fire_fanout_capacity_snapshot(run_path, assignment)
    end

    :ok
  end

  defp fire_fanout_capacity_snapshot(run_path, assignment) do
    host_name = get_in(assignment, ["resolved_environment", "host"])

    # Supervised fire-and-forget — see comment on fire_capacity_snapshot/1
    # in JX.Workspace for the rationale.
    Task.Supervisor.start_child(JX.TaskSupervisor, fn ->
      with %{} = host <- JX.Hosts.get_host_by_name(host_name) do
        active = count_active_fanout_assignments(run_path)
        JX.HostCapacity.Observer.snapshot(host, active)
      end
    end)
  end

  @fanout_active_states ~w(launching local_validated pr_opened ci_pending)

  # Returns %{host_name => active_count} for all active assignments in the run.
  defp active_fanout_assignments_per_host(run_path) do
    assignments_dir = Path.join(run_path, "assignments")

    case File.ls(assignments_dir) do
      {:ok, files} ->
        Enum.reduce(files, %{}, fn file, acc ->
          path = Path.join(assignments_dir, file)

          with {:ok, text} <- File.read(path),
               {:ok, %{"state" => state} = assignment} <- Jason.decode(text),
               true <- state in @fanout_active_states,
               host_name when is_binary(host_name) <-
                 get_in(assignment, ["resolved_environment", "host"]) do
            Map.update(acc, host_name, 1, &(&1 + 1))
          else
            _ -> acc
          end
        end)

      _ ->
        %{}
    end
  end

  # Convenience: total active assignments across all hosts in the run.
  defp count_active_fanout_assignments(run_path) do
    run_path
    |> active_fanout_assignments_per_host()
    |> Map.values()
    |> Enum.sum()
  end

  defp read_json(path) do
    with {:ok, text} <- File.read(path),
         {:ok, decoded} <- Jason.decode(text) do
      {:ok, decoded}
    else
      {:error, %Jason.DecodeError{} = error} -> {:error, Exception.message(error)}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp read_json!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  end

  defp write_json!(path, payload), do: File.write!(path, Jason.encode!(payload, pretty: true))
  defp write_text!(path, text), do: File.write!(path, text)

  defp write_new_json(path, payload) do
    case File.open(
           path,
           [:write, :exclusive],
           &IO.write(&1, Jason.encode!(payload, pretty: true))
         ) do
      {:ok, :ok} -> :ok
      {:error, :eexist} -> {:error, "file already exists"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp prepare_run_path(root, run_id) do
    with :ok <- validate_path_id(run_id, "run id"),
         root <- Path.expand(root),
         {:ok, run_path} <- safe_child_path(root, [run_id]) do
      if File.exists?(run_path) do
        {:error, "fanout run already exists: #{run_path}"}
      else
        File.mkdir_p!(run_path)
        {:ok, run_path}
      end
    end
  end

  defp resolve_run_path(run_ref, root) do
    cond do
      is_nil(run_ref) or run_ref == "" ->
        {:error, "run id or path is required"}

      File.dir?(run_ref) ->
        {:ok, Path.expand(run_ref)}

      true ->
        resolve_run_id_path(run_ref, root)
    end
  end

  defp resolve_run_id_path(run_ref, root) do
    with :ok <- validate_path_id(run_ref, "run id"),
         root <- Path.expand(root),
         {:ok, path} <- safe_child_path(root, [run_ref]) do
      if File.dir?(path) do
        {:ok, path}
      else
        {:error, "fanout run not found: #{run_ref}"}
      end
    end
  end

  defp validate_report_path_ids(%AssignmentReport{} = report) do
    with :ok <- validate_path_id(report.report_id, "report id"),
         :ok <- validate_path_id(report.assignment_id, "assignment id") do
      {:ok, report}
    end
  end

  defp run_id(plan_id, opts) do
    cond do
      is_binary(opts[:run_id]) and String.trim(opts[:run_id]) != "" ->
        {:ok, opts[:run_id]}

      true ->
        {:ok, "#{plan_id}-#{Date.utc_today() |> Date.to_iso8601()}"}
    end
  end

  defp timestamp(%DateTime{} = value), do: {:ok, DateTime.to_iso8601(value)}

  defp timestamp(nil) do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> then(&{:ok, &1})
  end

  defp required_string(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, "#{String.replace(to_string(key), "_", "-")} is required"}
    end
  end

  defp validate_unique(items, _field, label, extractor \\ nil) do
    values =
      Enum.map(items, fn item ->
        if extractor do
          extractor.(item)
        else
          Map.fetch!(item, :assignment_id)
        end
      end)

    duplicates =
      values
      |> Enum.frequencies()
      |> Enum.filter(fn {_value, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    case duplicates do
      [] -> :ok
      _ -> {:error, "duplicate #{label}: #{Enum.join(duplicates, ", ")}"}
    end
  end

  defp assignment_path(run_path, assignment_id) do
    safe_child_path!(run_path, ["assignments", "#{assignment_id}.json"])
  end

  defp accepted_report_path(run_path, report) do
    safe_child_path!(run_path, [
      "reports",
      report.assignment_id,
      "accepted",
      "#{report.report_id}.json"
    ])
  end

  defp rejected_report_path(run_path, report) do
    safe_child_path!(run_path, [
      "reports",
      report.assignment_id,
      "rejected",
      "#{report.report_id}.json"
    ])
  end

  defp accepted_report_exists?(run_path, report) do
    File.exists?(accepted_report_path(run_path, report))
  end

  def relative_path(run_path, path) do
    Path.relative_to(path, Path.dirname(run_path))
  end

  defp safe_child_path!(root, parts) do
    case safe_child_path(root, parts) do
      {:ok, path} -> path
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  def safe_child_path(root, parts) do
    root = Path.expand(root)
    path = Path.expand(Path.join([root | parts]))

    if inside_path?(path, root) do
      {:ok, path}
    else
      {:error, "path escapes fanout run root: #{path}"}
    end
  end

  defp inside_path?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  def validate_path_id(value, label) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        {:error, "#{label} is required"}

      String.contains?(value, ["/", "\\"]) or value in [".", ".."] ->
        {:error, "#{label} contains path separators or dot segments"}

      !Regex.match?(@safe_path_id, value) ->
        {:error, "#{label} contains unsupported characters"}

      true ->
        :ok
    end
  end

  def validate_path_id(_value, label), do: {:error, "#{label} is required"}

  defp normalize_text(value) when is_binary(value), do: String.trim(value)
  defp normalize_text(value), do: value

  def blank?(value) when is_binary(value), do: String.trim(value) == ""
  def blank?(nil), do: true
  def blank?(_value), do: false

  def first_present(values) do
    Enum.find(values, fn value ->
      not blank?(value)
    end)
  end

  defp warn_if(warnings, true, warning), do: warnings ++ [warning]
  defp warn_if(warnings, false, _warning), do: warnings

  def normalize_list(nil), do: []

  def normalize_list(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, list} when is_list(list) -> normalize_list(list)
      _other -> normalize_list([value])
    end
  end

  def normalize_list(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  def normalize_list(_value), do: []

  defp normalize_path_segments([], acc), do: Enum.reverse(acc)
  defp normalize_path_segments(["." | rest], acc), do: normalize_path_segments(rest, acc)

  defp normalize_path_segments([".." | rest], [".." | _] = acc),
    do: normalize_path_segments(rest, [".." | acc])

  defp normalize_path_segments([".." | rest], [_segment | acc]),
    do: normalize_path_segments(rest, acc)

  defp normalize_path_segments([".." | rest], []), do: normalize_path_segments(rest, [".."])

  defp normalize_path_segments([segment | rest], acc),
    do: normalize_path_segments(rest, [segment | acc])

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _other -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp map_field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp atomize_nested(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), atomize_nested(value)} end)
  end

  defp atomize_nested(list) when is_list(list), do: Enum.map(list, &atomize_nested/1)
  defp atomize_nested(value), do: value

  def stringify_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  def stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  def stringify_keys(value), do: value
end
