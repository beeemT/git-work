defmodule GitWork.Commands.RmTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias GitWork.Commands.{Rm, Checkout}

  setup do
    old_cwd = File.cwd!()
    tmp = Path.join(System.tmp_dir!(), "gw_rm_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    # Resolve macOS /var -> /private/var symlink
    File.cd!(tmp)
    tmp = File.cwd!()
    File.cd!(old_cwd)

    on_exit(fn ->
      File.cd!(old_cwd)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  test "removes worktree and branch after confirmation", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)

    File.cd!(Path.join(project, "main"))

    # Create a feature branch
    {:ok, _} = Checkout.run(["-b", "feature-rm-test"], :text)
    assert File.dir?(Path.join(project, "feature-rm-test"))

    # Remove it
    capture_io("yes\n", fn ->
      assert {:ok, _} = Rm.run(["feature-rm-test"], :text)
    end)

    # Directory should be gone
    refute File.dir?(Path.join(project, "feature-rm-test"))

    # git worktree list should not show it
    {output, 0} = System.cmd("git", ["worktree", "list"], cd: Path.join(project, ".bare"))
    refute output =~ "feature-rm-test"

    # Branch should be gone
    {branches, 0} = System.cmd("git", ["branch"], cd: Path.join(project, ".bare"))
    refute branches =~ "feature-rm-test"
  end

  test "removes a merged branch when its upstream was pruned", %{tmp: tmp} do
    origin = GitWork.TestHelper.create_origin_repo(tmp)
    {_, 0} = System.cmd("git", ["branch", "feature-pruned", "main"], cd: origin)

    project = Path.join(tmp, "project")
    {:ok, _} = GitWork.Commands.Clone.run([origin, project], :text)
    bare = Path.join(project, ".bare")

    {_, 0} =
      System.cmd("git", ["config", "git-work.hooks.mise.task", ""], cd: bare)

    File.cd!(Path.join(project, "main"))
    assert {:ok, _path} = Checkout.run(["feature-pruned"], :text)

    GitWork.TestHelper.delete_remote_branch(origin, "feature-pruned")
    {_, 0} = System.cmd("git", ["fetch", "--prune"], cd: bare)

    assert {:ok, _} = Rm.run(["--yes", "feature-pruned"], :text)
    refute File.dir?(Path.join(project, "feature-pruned"))
    {branches, 0} = System.cmd("git", ["branch", "--list", "feature-pruned"], cd: bare)
    refute branches =~ "feature-pruned"
  end

  test "uses an existing upstream when checking whether a branch is merged", %{tmp: tmp} do
    origin = GitWork.TestHelper.create_origin_repo(tmp)
    GitWork.TestHelper.create_remote_branch(origin, "feature-upstream")

    project = Path.join(tmp, "project")
    {:ok, _} = GitWork.Commands.Clone.run([origin, project], :text)
    bare = Path.join(project, ".bare")

    {_, 0} =
      System.cmd("git", ["config", "git-work.hooks.mise.task", ""], cd: bare)

    File.cd!(Path.join(project, "main"))
    assert {:ok, _path} = Checkout.run(["feature-upstream"], :text)

    assert {:ok, _} = Rm.run(["--yes", "feature-upstream"], :text)
    refute File.dir?(Path.join(project, "feature-upstream"))
  end

  test "keeps an unmerged branch when its upstream was pruned", %{tmp: tmp} do
    origin = GitWork.TestHelper.create_origin_repo(tmp)
    {_, 0} = System.cmd("git", ["branch", "feature-pruned", "main"], cd: origin)

    project = Path.join(tmp, "project")
    {:ok, _} = GitWork.Commands.Clone.run([origin, project], :text)
    bare = Path.join(project, ".bare")

    {_, 0} =
      System.cmd("git", ["config", "git-work.hooks.mise.task", ""], cd: bare)

    File.cd!(Path.join(project, "main"))
    assert {:ok, feature_path} = Checkout.run(["feature-pruned"], :text)

    File.write!(Path.join(feature_path, "unmerged.txt"), "unmerged\n")
    {_, 0} = System.cmd("git", ["add", "unmerged.txt"], cd: feature_path)

    {_, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "user.name=Test",
          "-c",
          "user.email=test@test.com",
          "commit",
          "-m",
          "unmerged feature"
        ],
        cd: feature_path
      )

    GitWork.TestHelper.delete_remote_branch(origin, "feature-pruned")
    {_, 0} = System.cmd("git", ["fetch", "--prune"], cd: bare)

    assert {:error, msg} = Rm.run(["--yes", "feature-pruned"], :text)
    assert msg =~ "not fully merged"
    assert File.dir?(feature_path)
  end

  test "removes non-HEAD branch when a same-name tag exists", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)
    bare = Path.join(project, ".bare")

    File.cd!(Path.join(project, "main"))
    {:ok, _} = Checkout.run(["-b", "collision"], :text)
    File.cd!(Path.join(project, "main"))

    {branch_oid, 0} =
      System.cmd("git", ["rev-parse", "refs/heads/collision^{commit}"], cd: bare)

    {_, 0} = System.cmd("git", ["tag", "collision", "refs/heads/collision"], cd: bare)

    assert {:ok, _} = Rm.run(["--yes", "collision"], :text)
    refute File.dir?(Path.join(project, "collision"))

    {_, branch_status} =
      System.cmd("git", ["show-ref", "--verify", "--quiet", "refs/heads/collision"], cd: bare)

    assert branch_status != 0

    {tag_oid, 0} =
      System.cmd("git", ["rev-parse", "refs/tags/collision^{commit}"], cd: bare)

    assert String.trim(tag_oid) == String.trim(branch_oid)
  end

  test "force-removes an unmerged collision branch while retaining its tag", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)
    bare = Path.join(project, ".bare")

    File.cd!(Path.join(project, "main"))
    {:ok, collision_path} = Checkout.run(["-b", "collision-force"], :text)
    File.write!(Path.join(collision_path, "unmerged.txt"), "unmerged\n")
    {_, 0} = System.cmd("git", ["add", "unmerged.txt"], cd: collision_path)

    {_, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "user.name=Test",
          "-c",
          "user.email=test@test.com",
          "commit",
          "-m",
          "unmerged collision"
        ],
        cd: collision_path
      )

    File.cd!(Path.join(project, "main"))

    {branch_oid, 0} =
      System.cmd("git", ["rev-parse", "refs/heads/collision-force^{commit}"], cd: bare)

    {_, 0} =
      System.cmd("git", ["tag", "collision-force", "refs/heads/collision-force"], cd: bare)

    assert {:ok, _} = Rm.run(["--yes", "--force", "collision-force"], :text)
    refute File.dir?(collision_path)

    {_, branch_status} =
      System.cmd(
        "git",
        ["show-ref", "--verify", "--quiet", "refs/heads/collision-force"],
        cd: bare
      )

    assert branch_status != 0

    {tag_oid, 0} =
      System.cmd("git", ["rev-parse", "refs/tags/collision-force^{commit}"], cd: bare)

    assert String.trim(tag_oid) == String.trim(branch_oid)
  end

  test "refuses to remove HEAD branch when a same-name tag exists without --force", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)
    bare = Path.join(project, ".bare")

    {_, 0} = System.cmd("git", ["tag", "main", "refs/heads/main"], cd: bare)
    File.cd!(Path.join(project, "main"))

    assert {:error, msg} = Rm.run(["main"], :text)
    assert msg =~ "refusing"
    assert msg =~ "force"

    assert File.dir?(Path.join(project, "main"))

    {_, 0} = System.cmd("git", ["show-ref", "--verify", "--quiet", "refs/heads/main"], cd: bare)
    {_, 0} = System.cmd("git", ["show-ref", "--verify", "--quiet", "refs/tags/main"], cd: bare)
  end

  test "rm from inside worktree returns main path", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)

    File.cd!(Path.join(project, "main"))

    {:ok, _} = Checkout.run(["-b", "feature-inside"], :text)

    # cd into the feature worktree
    File.cd!(Path.join(project, "feature-inside"))

    assert {:ok, path} = Rm.run(["--yes", "feature-inside"], :text)
    # Should return main path for shell wrapper to cd into
    assert path == Path.join(project, "main")
  end

  test "aborts when confirmation is declined", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)

    File.cd!(Path.join(project, "main"))
    {:ok, _} = Checkout.run(["-b", "feature-abort"], :text)

    capture_io("n\n", fn ->
      assert {:error, msg} = Rm.run(["feature-abort"], :text)
      assert msg =~ "aborted"
    end)

    assert File.dir?(Path.join(project, "feature-abort"))
  end

  test "removes without prompting when --yes is passed", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)

    File.cd!(Path.join(project, "main"))
    {:ok, _} = Checkout.run(["-b", "feature-yes"], :text)

    # No stdin capture here: this would fail if rm still required interaction.
    assert {:ok, _} = Rm.run(["--yes", "feature-yes"], :text)
    refute File.dir?(Path.join(project, "feature-yes"))
  end

  test "fuzzy matching removes the matched branch", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)
    bare = Path.join(project, ".bare")

    File.cd!(Path.join(project, "main"))
    {:ok, _} = Checkout.run(["-b", "feature/login"], :text)
    assert File.dir?(Path.join(project, "feature-login"))

    assert {:ok, _} = Rm.run(["--yes", "login"], :text)
    refute File.dir?(Path.join(project, "feature-login"))

    {branches, 0} = System.cmd("git", ["branch"], cd: bare)
    refute branches =~ "feature/login"
  end
end
