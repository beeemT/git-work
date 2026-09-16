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
    project = GitWork.TestHelper.create_gw_project(tmp)
    origin = Path.join(tmp, "origin.git")

    # Create remote branch, fetch, checkout
    GitWork.TestHelper.create_remote_branch(origin, "feature-stale")
    System.cmd("git", ["fetch", "--all"], cd: Path.join(project, ".bare"))

    File.cd!(Path.join(project, "main"))

    {:ok, _} = Checkout.run(["-b", "feature-stale"], :text)
    assert File.dir?(Path.join(project, "feature-stale"))

    # Go back to main before deleting
    File.cd!(Path.join(project, "main"))

    # Merge the branch locally so normal sync can prune it safely.
    {_, 0} =
      System.cmd("git", ["merge", "--ff-only", "feature-stale"], cd: Path.join(project, "main"))

    # Delete the branch on remote
    GitWork.TestHelper.delete_remote_branch(origin, "feature-stale")

    # Sync should prune it
    assert {:ok, _} = Sync.run([], :text)

    refute File.dir?(Path.join(project, "feature-stale"))
  end

  test "--dry-run shows candidates without removing", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)
    origin = Path.join(tmp, "origin.git")

    GitWork.TestHelper.create_remote_branch(origin, "feature-dry")
    System.cmd("git", ["fetch", "--all"], cd: Path.join(project, ".bare"))

    File.cd!(Path.join(project, "main"))

    {:ok, _} = Checkout.run(["-b", "feature-dry"], :text)
    File.cd!(Path.join(project, "main"))

    # Merge the branch locally so normal sync can prune it safely.
    {_, 0} =
      System.cmd("git", ["merge", "--ff-only", "feature-dry"], cd: Path.join(project, "main"))

    GitWork.TestHelper.delete_remote_branch(origin, "feature-dry")

    # Dry run
    assert {:ok, _} = Sync.run(["--dry-run"], :text)

    # Worktree should still exist
    assert File.dir?(Path.join(project, "feature-dry"))
  end

  test "refuses to prune a stale unmerged worktree", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)
    origin = Path.join(tmp, "origin.git")

    GitWork.TestHelper.create_remote_branch(origin, "feature-unmerged")
    System.cmd("git", ["fetch", "--all"], cd: Path.join(project, ".bare"))

    File.cd!(Path.join(project, "main"))
    {:ok, _} = Checkout.run(["-b", "feature-unmerged"], :text)
    File.cd!(Path.join(project, "main"))

    GitWork.TestHelper.delete_remote_branch(origin, "feature-unmerged")

    assert {:error, message} = Sync.run([], :text)
    assert message =~ "refusing to prune unmerged branches"
    assert File.dir?(Path.join(project, "feature-unmerged"))

    {branches, 0} =
      System.cmd("git", ["branch", "--format=%(refname:short)"], cd: Path.join(project, ".bare"))

    assert "feature-unmerged" in String.split(branches, "\n", trim: true)
  end

  test "keeps HEAD worktree when its remote and a same-name tag are gone", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)
    bare = Path.join(project, ".bare")
    origin = Path.join(tmp, "origin.git")

    GitWork.TestHelper.create_remote_branch(origin, "feature-stale")
    System.cmd("git", ["fetch", "--all"], cd: bare)

    File.cd!(Path.join(project, "main"))
    {:ok, feature_path} = Checkout.run(["feature-stale"], :text)
    File.cd!(Path.join(project, "main"))

    {_, 0} =
      System.cmd("git", ["merge", "--ff-only", "feature-stale"], cd: Path.join(project, "main"))

    {main_oid, 0} = System.cmd("git", ["rev-parse", "refs/heads/main^{commit}"], cd: bare)
    main_readme = File.read!(Path.join(project, "main/README.md"))
    main_feature_file = File.read!(Path.join(project, "main/feature-stale.txt"))

    {_, 0} = System.cmd("git", ["tag", "main", "refs/heads/main"], cd: bare)

    GitWork.TestHelper.delete_remote_branch(origin, "feature-stale")
    GitWork.TestHelper.delete_remote_branch(origin, "main")

    File.cd!(project)
    assert {:ok, _} = Sync.run(["--dry-run"], :text)
    assert File.dir?(Path.join(project, "main"))
    assert File.dir?(feature_path)

    assert {:ok, _} = Sync.run(["--force"], :text)
    assert File.dir?(Path.join(project, "main"))
    refute File.dir?(feature_path)

    {_, stale_branch_status} =
      System.cmd(
        "git",
        ["show-ref", "--verify", "--quiet", "refs/heads/feature-stale"],
        cd: bare
      )

    assert stale_branch_status != 0

    {remaining_oid, 0} =
      System.cmd("git", ["rev-parse", "refs/heads/main^{commit}"], cd: bare)

    assert String.trim(remaining_oid) == String.trim(main_oid)
    assert File.read!(Path.join(project, "main/README.md")) == main_readme
    assert File.read!(Path.join(project, "main/feature-stale.txt")) == main_feature_file

    {_, 0} = System.cmd("git", ["show-ref", "--verify", "--quiet", "refs/tags/main"], cd: bare)
  end

  test "never prunes HEAD branch", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)

    File.cd!(Path.join(project, "main"))

    # Sync should never touch main
    assert {:ok, _} = Sync.run([], :text)
    assert File.dir?(Path.join(project, "main"))
  end
end
