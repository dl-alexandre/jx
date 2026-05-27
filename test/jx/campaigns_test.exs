defmodule JX.CampaignsTest do
  use ExUnit.Case, async: false

  alias JX.Campaigns

  setup do
    root = Path.join(System.tmp_dir!(), "jx-campaign-test-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    worktrees = Path.join(root, "worktrees")
    state_root = Path.join(root, "state")

    File.mkdir_p!(repo)
    File.write!(Path.join(repo, "README.md"), "test\n")
    git!(repo, ["init"])
    git!(repo, ["config", "user.email", "test@example.test"])
    git!(repo, ["config", "user.name", "Test User"])
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "-m", "init"])

    for issue <- [1153, 1152] do
      git!(repo, [
        "worktree",
        "add",
        "-B",
        "onebackend-v3-grok-#{issue}",
        Path.join(worktrees, "onebackend-v3-grok-#{issue}"),
        "HEAD"
      ])
    end

    on_exit(fn -> File.rm_rf(root) end)

    %{root: root, repo: repo, worktrees: worktrees, state_root: state_root}
  end

  test "seed from existing worktrees records active slots without creating duplicates", ctx do
    assert {:ok, state} =
             Campaigns.init("onebackend-v3-e14",
               issues: "1151..1153",
               direction: "desc",
               root: ctx.state_root
             )

    assert state["issues"] == [1153, 1152, 1151]

    assert {:ok, seeded} =
             Campaigns.seed_from_existing_worktrees("onebackend-v3-e14",
               root: ctx.state_root,
               repo_root: ctx.repo,
               branch_prefix: "onebackend-v3-",
               host_id: "host-a"
             )

    assert Enum.map(seeded["slots"], & &1["issue_number"]) == [1152, 1153]
    assert Enum.all?(seeded["slots"], &(&1["status"] == "agent_working"))
    assert seeded["summary"]["slots_total"] == 2
    assert seeded["summary"]["by_host"]["host-a"] == 2

    assert {:ok, reseeded} =
             Campaigns.seed_from_existing_worktrees("onebackend-v3-e14",
               root: ctx.state_root,
               repo_root: ctx.repo,
               branch_prefix: "onebackend-v3-",
               host_id: "host-a"
             )

    assert length(reseeded["slots"]) == 2
  end

  test "confirm records operator confirmation and derived next actions", ctx do
    {:ok, _state} =
      Campaigns.init("onebackend-v3-e14",
        issues: "1151",
        direction: "desc",
        root: ctx.state_root
      )

    assert {:ok, confirmed} =
             Campaigns.confirm(
               "onebackend-v3-e14",
               %{"slot_index" => 0, "message" => "batch reviewed", "status" => "ready"},
               root: ctx.state_root
             )

    assert [%{"message" => "batch reviewed", "status" => "ready"}] =
             confirmed["confirmations"]

    assert [%{"type" => "confirmed"}] = confirmed["events"]
    assert confirmed["summary"]["slots_total"] == 0
    assert confirmed["next_actions"] == []
  end

  test "dry-run tick detects PRs without writing state and apply advances the slot once", ctx do
    {:ok, _state} =
      Campaigns.init("onebackend-v3-e14",
        issues: "1151..1153",
        direction: "desc",
        root: ctx.state_root
      )

    {:ok, _seeded} =
      Campaigns.seed_from_existing_worktrees("onebackend-v3-e14",
        root: ctx.state_root,
        repo_root: ctx.repo,
        branch_prefix: "onebackend-v3-",
        host_id: "host-a"
      )

    with_fake_gh(
      ctx.root,
      %{
        "onebackend-v3-grok-1153" => %{
          "number" => 1234,
          "url" => "https://github.test/acme/onebackend-v3/pull/1234"
        }
      },
      fn ->
        assert {:ok, dry_run} =
                 Campaigns.tick("onebackend-v3-e14",
                   root: ctx.state_root,
                   repo_root: ctx.repo,
                   github_repo: "acme/onebackend-v3"
                 )

        assert dry_run["mode"] == "dry_run"
        assert [%{"branch" => "onebackend-v3-grok-1153"}] = dry_run["detections"]

        assert {:ok, persisted_after_dry_run} =
                 Campaigns.status("onebackend-v3-e14", root: ctx.state_root)

        refute Enum.any?(persisted_after_dry_run["slots"], &(&1["status"] == "pr_detected"))

        assert {:ok, applied} =
                 Campaigns.tick("onebackend-v3-e14",
                   root: ctx.state_root,
                   repo_root: ctx.repo,
                   github_repo: "acme/onebackend-v3",
                   apply: true
                 )

        assert [%{"action" => "created_worktree", "branch" => "onebackend-v3-grok-1151"}] =
                 applied["actions"]

        assert {:ok, applied_again} =
                 Campaigns.tick("onebackend-v3-e14",
                   root: ctx.state_root,
                   repo_root: ctx.repo,
                   github_repo: "acme/onebackend-v3",
                   apply: true
                 )

        assert applied_again["actions"] == []

        assert File.exists?(Path.join(ctx.worktrees, "onebackend-v3-grok-1151/.git"))
      end
    )
  end

  test "apply tick does not advance pr_detected slots owned by another host", ctx do
    state = %{
      "version" => 1,
      "name" => "onebackend-v3-e14",
      "created_at" => "2026-05-22T00:00:00Z",
      "updated_at" => "2026-05-22T00:00:00Z",
      "issues" => [1153, 1152],
      "slots" => [
        %{
          "slot_index" => 0,
          "issue_number" => 1153,
          "branch" => "onebackend-v3-grok-1153",
          "worktree_path" => Path.join(ctx.worktrees, "onebackend-v3-grok-1153"),
          "host_id" => "host-a",
          "agent_kind" => "grok",
          "status" => "pr_detected",
          "pr_number" => 1234,
          "pr_url" => "https://github.test/acme/onebackend-v3/pull/1234"
        }
      ],
      "events" => []
    }

    path = Campaigns.state_path("onebackend-v3-e14", root: ctx.state_root)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(state))

    assert {:ok, result} =
             Campaigns.tick("onebackend-v3-e14",
               root: ctx.state_root,
               repo_root: ctx.repo,
               apply: true,
               host_id: "host-b"
             )

    assert result["actions"] == []

    assert {:ok, persisted} = Campaigns.status("onebackend-v3-e14", root: ctx.state_root)
    assert [%{"status" => "pr_detected", "host_id" => "host-a"}] = persisted["slots"]
    # host-b must not claim issue 1152 (which it does not own): no slot is created
    # for it. The 1152 worktree dir itself is pre-seeded by setup/0, so its presence
    # is not a usable signal here — assert on campaign state instead.
    refute Enum.any?(persisted["slots"], &(&1["issue_number"] == 1152))
  end

  defp git!(repo, args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end

  defp with_fake_gh(root, prs_by_branch, fun) do
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    gh = Path.join(bin, "gh")

    File.write!(gh, fake_gh_script(prs_by_branch))
    File.chmod!(gh, 0o755)

    old_path = System.get_env("PATH", "")
    System.put_env("PATH", bin <> ":" <> old_path)

    try do
      fun.()
    after
      System.put_env("PATH", old_path)
    end
  end

  defp fake_gh_script(prs_by_branch) do
    cases =
      Enum.map_join(prs_by_branch, "\n", fn {branch, pr} ->
        payload = Jason.encode!([Map.merge(%{"headRefName" => branch, "state" => "OPEN"}, pr)])

        """
          #{branch})
            cat <<'JSON'
        #{payload}
        JSON
            ;;
        """
      end)

    """
    #!/usr/bin/env sh
    set -eu
    branch=""
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "--head" ]; then
        shift
        branch="$1"
      fi
      shift || true
    done
    case "$branch" in
    #{cases}
      *)
        echo "[]"
        ;;
    esac
    """
  end
end
