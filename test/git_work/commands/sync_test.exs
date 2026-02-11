defmodule GitWork.Commands.SyncTest do
  use ExUnit.Case

  alias GitWork.Commands.{Sync, Checkout}

  setup do
    old_cwd = File.cwd!()
    tmp = Path.join(System.tmp_dir!(), "gw_sync_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    on_exit(fn ->
      File.cd!(old_cwd)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  test "prunes worktree whose remote branch was deleted", %{tmp: tmp} do
    origin = GitWork.TestHelper.create_origin_repo(tmp)
    project = Path.join(tmp, "project")
    {:ok, _} = GitWork.Commands.Clone.run([origin, project])

    # Create remote branch, fetch, checkout
    GitWork.TestHelper.create_remote_branch(origin, "feature-stale")
    System.cmd("git", ["fetch", "--all"], cd: Path.join(project, ".bare"))

    File.cd!(Path.join(project, "main"))

    {:ok, _} = Checkout.run(["feature-stale"])
    assert File.dir?(Path.join(project, "feature-stale"))

    # Go back to main before deleting
    File.cd!(Path.join(project, "main"))

    # Delete the branch on remote
    GitWork.TestHelper.delete_remote_branch(origin, "feature-stale")

    # Sync should prune it
    assert {:ok, _} = Sync.run([])

    refute File.dir?(Path.join(project, "feature-stale"))
  end

  test "--dry-run shows candidates without removing", %{tmp: tmp} do
    origin = GitWork.TestHelper.create_origin_repo(tmp)
    project = Path.join(tmp, "project")
    {:ok, _} = GitWork.Commands.Clone.run([origin, project])

    GitWork.TestHelper.create_remote_branch(origin, "feature-dry")
    System.cmd("git", ["fetch", "--all"], cd: Path.join(project, ".bare"))

    File.cd!(Path.join(project, "main"))

    {:ok, _} = Checkout.run(["feature-dry"])
    File.cd!(Path.join(project, "main"))

    GitWork.TestHelper.delete_remote_branch(origin, "feature-dry")

    # Dry run
    assert {:ok, _} = Sync.run(["--dry-run"])

    # Worktree should still exist
    assert File.dir?(Path.join(project, "feature-dry"))
  end

  test "never prunes HEAD branch", %{tmp: tmp} do
    origin = GitWork.TestHelper.create_origin_repo(tmp)
    project = Path.join(tmp, "project")
    {:ok, _} = GitWork.Commands.Clone.run([origin, project])

    File.cd!(Path.join(project, "main"))

    # Sync should never touch main
    assert {:ok, _} = Sync.run([])
    assert File.dir?(Path.join(project, "main"))
  end
end
