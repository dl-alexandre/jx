defmodule JX.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :jx,
      version: @version,
      elixir: "~> 1.19",
      name: "jx",
      description: description(),
      elixirc_paths: elixirc_paths(Mix.env()),
      escript: escript(),
      ecto_repos: [JX.Repo],
      aliases: aliases(),
      compilers: [:stale_beam_cleaner] ++ Mix.compilers(),
      docs: docs(),
      package: package(),
      releases: releases(),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {JX.Application, []}
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test, "jx.contract": :test]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp escript do
    [
      main_module: JX.CLI,
      name: "jx",
      app: nil,
      include_priv_for: [:jx, :tzdata, :exqlite]
    ]
  end

  defp description do
    "jx is an agent-facing TUI and orchestrator for durable SSH/tmux-backed work sessions."
  end

  defp docs do
    [
      main: "overview",
      homepage_url: "https://hexdocs.pm/jido_orchestrator",
      source_url: "https://github.com/dl-alexandre/jido_orchestrator",
      source_ref: "v#{@version}",
      extras: [
        "docs/hexdocs/overview.md",
        "docs/hexdocs/installation.md",
        "docs/hexdocs/concepts.md",
        "docs/hexdocs/usage_modes.md",
        "docs/hexdocs/cli.md",
        "docs/hexdocs/orchestration.md",
        "docs/hexdocs/session_profiles.md",
        "docs/hexdocs/delegation.md",
        "docs/hexdocs/ci_watches.md",
        "docs/hexdocs/devide.md",
        "docs/hexdocs/safe_actions.md",
        "docs/hexdocs/call_handoffs.md",
        "docs/hexdocs/google_meet.md",
        "docs/hexdocs/jido_runtime.md",
        "docs/hexdocs/safety_policy.md",
        "docs/hexdocs/branding.md",
        "docs/hexdocs/publishing.md",
        "README.md"
      ],
      groups_for_extras: [
        "Start Here": [
          "docs/hexdocs/overview.md",
          "docs/hexdocs/installation.md",
          "docs/hexdocs/concepts.md",
          "docs/hexdocs/usage_modes.md",
          "docs/hexdocs/cli.md"
        ],
        Operations: [
          "docs/hexdocs/orchestration.md",
          "docs/hexdocs/session_profiles.md",
          "docs/hexdocs/delegation.md",
          "docs/hexdocs/ci_watches.md",
          "docs/hexdocs/devide.md",
          "docs/hexdocs/safe_actions.md",
          "docs/hexdocs/call_handoffs.md",
          "docs/hexdocs/google_meet.md",
          "docs/hexdocs/safety_policy.md"
        ],
        Project: [
          "docs/hexdocs/jido_runtime.md",
          "docs/hexdocs/branding.md",
          "docs/hexdocs/publishing.md",
          "README.md"
        ]
      ],
      groups_for_modules: [
        "Public API": [JX, JX.Workspace],
        Runtime: [
          JX.Application,
          JX.CliRuntime,
          JX.Jido,
          JX.OrchestratorDaemon,
          JX.OrchestratorAgent
        ],
        Sessions: [
          JX.SessionInventory,
          JX.SessionDossiers,
          JX.SessionProfiles,
          JX.SessionStatus,
          JX.SessionControls,
          JX.SessionWatches,
          JX.SessionReconciliation,
          JX.RemoteSessions,
          JX.SSHSessions,
          JX.ProcessInventory
        ],
        Orchestration: [
          JX.TUI,
          JX.MonitorEvents,
          JX.Notifications,
          JX.NextStep,
          JX.OperationPolicy,
          JX.OperationExecutions,
          JX.OrchestrationActions,
          JX.OrchestratorGuidance,
          JX.OrchestratorPlanner,
          JX.OrchestratorQueueDecisions,
          JX.OrchestratorHeartbeats,
          JX.UsageModes,
          JX.WakeTriggers
        ],
        "Work Execution": [
          JX.AgentRunner,
          JX.DelegationPreflight,
          JX.Delegations,
          JX.Directives,
          JX.GitWorktrees,
          JX.HostDoctor,
          JX.Hosts,
          JX.Projects,
          JX.Tasks,
          JX.Tmux,
          JX.SSH,
          JX.SSH.Local,
          JX.SSH.System,
          JX.Shell,
          JX.PaneTransport
        ],
        "Briefs and Watches": [
          JX.CallBrief,
          JX.CallHandoffs,
          JX.CiDigest,
          JX.CiWatches,
          JX.ProjectBrief,
          JX.PortfolioSummary,
          JX.ParticipantPlugins,
          JX.ParticipantPlugins.GoogleMeet,
          JX.GoogleMeet
        ]
      ]
    ]
  end

  defp package do
    [
      name: "jido_orchestrator",
      files: [
        "bin",
        "config",
        "docs/hexdocs",
        "lib",
        "priv",
        ".formatter.exs",
        "mix.exs",
        "README.md",
        "CHANGELOG.md",
        "LICENSE"
      ],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => "https://github.com/dl-alexandre/jido_orchestrator",
        "Changelog" =>
          "https://github.com/dl-alexandre/jido_orchestrator/blob/master/CHANGELOG.md"
      }
    ]
  end

  defp deps do
    [
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, "~> 0.22.0"},
      {:jido, "~> 2.2"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:bypass, "~> 2.1", only: :test},
      {:ex_doc, "~> 0.40.1", only: :dev, runtime: false},
      {:burrito, "~> 1.5", runtime: false, only: :prod}
    ]
  end

  defp releases do
    steps = [:assemble]
    steps = if burrito_enabled?(), do: steps ++ [&Burrito.wrap/1], else: steps

    [
      jx: [
        steps: steps,
        burrito: [
          targets: [
            macos: [os: :darwin, cpu: :aarch64],
            macos_intel: [os: :darwin, cpu: :x86_64],
            linux: [os: :linux, cpu: :x86_64],
            linux_aarch64: [os: :linux, cpu: :aarch64]
          ]
        ]
      ]
    ]
  end

  defp burrito_enabled? do
    System.get_env("BURRITO_BUILD", "") != ""
  end

  defp aliases do
    [
      "jx.contract": [
        "test test/jx/dev_ide/contract_test.exs test/jx/safe_actions/registry_contract_test.exs"
      ],
      "jx.build": ["cmd", "MIX_ENV=prod mix escript.build"],
      precommit: ["compile --warnings-as-errors", "format --check-formatted", "test"]
    ]
  end
end

defmodule Mix.Tasks.Compile.StaleBeamCleaner do
  @moduledoc false

  use Mix.Task.Compiler

  @impl true
  def run(_args) do
    Enum.each(stale_beam_dirs(), &File.rm_rf/1)

    stale_files = stale_beam_files()

    Enum.each(stale_files, &File.rm/1)
    Enum.each(stale_app_files(stale_files), &File.rm/1)

    {:ok, []}
  end

  defp stale_beam_files do
    Mix.Project.build_path()
    |> Path.join("lib/*/{ebin,consolidated}")
    |> Path.wildcard()
    |> Enum.flat_map(fn dir ->
      dir
      |> Path.join("* [0-9]*.beam")
      |> Path.wildcard()
    end)
  end

  defp stale_beam_dirs do
    Mix.Project.build_path()
    |> Path.join("lib/*/{ebin,consolidated} [0-9]*")
    |> Path.wildcard()
  end

  defp stale_app_files(stale_files) do
    stale_files
    |> Enum.map(&Path.dirname/1)
    |> Enum.uniq()
    |> Enum.filter(&(Path.basename(&1) == "ebin"))
    |> Enum.map(fn ebin_dir ->
      app_name =
        ebin_dir
        |> Path.dirname()
        |> Path.basename()

      Path.join(ebin_dir, "#{app_name}.app")
    end)
  end
end
