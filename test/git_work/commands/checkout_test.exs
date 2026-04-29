defmodule GitWork.Commands.CheckoutTest do
  use ExUnit.Case

  alias GitWork.Commands.Checkout

  setup do
    old_cwd = File.cwd!()
    tmp = Path.join(System.tmp_dir!(), "gw_co_test_#{System.unique_integer([:positive])}")
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

  test "checkout existing branch returns its path", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)

    File.cd!(Path.join(project, "main"))

    assert {:ok, path} = Checkout.run(["main"], :text)
    assert path == Path.join(project, "main")
  end

  test "checkout - switches to previous branch worktree", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)

    File.cd!(Path.join(project, "main"))

    assert {:ok, feature_path} = Checkout.run(["-b", "feature-prev"], :text)
    assert File.dir?(feature_path)

    assert {:ok, path} = Checkout.run(["-"], :text)
    assert path == Path.join(project, "main")
  end

  test "checkout - errors when no previous worktree tracked", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)

    File.cd!(Path.join(project, "main"))

    assert {:error, msg} = Checkout.run(["-"], :text)
    assert msg =~ "previous worktree"
  end

  test "checkout -b creates worktree for new branch", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)

    File.cd!(Path.join(project, "main"))

    assert {:ok, path} = Checkout.run(["-b", "feature-new"], :text)
    assert path == Path.join(project, "feature-new")
    assert File.dir?(path)

    # Verify git knows about the worktree
    {output, 0} = System.cmd("git", ["worktree", "list"], cd: Path.join(project, ".bare"))
    assert output =~ "feature-new"
  end

  test "checkout without -b errors on non-existent branch", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)

    File.cd!(Path.join(project, "main"))

    assert {:error, msg} = Checkout.run(["feature-new"], :text)
    assert msg =~ "no worktree found"
    assert msg =~ "-b"
  end

  test "checkout -b errors when worktree already exists", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)

    File.cd!(Path.join(project, "main"))

    assert {:error, msg} = Checkout.run(["-b", "main"], :text)
    assert msg =~ "already exists"
  end

  test "checkout fuzzy matches substring", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)

    File.cd!(Path.join(project, "main"))

    # Create a feature branch worktree first
    {:ok, _} = Checkout.run(["-b", "feature-login"], :text)

    # Now fuzzy match with substring
    assert {:ok, path} = Checkout.run(["login"], :text)
    assert path == Path.join(project, "feature-login")
  end

  test "checkout ambiguous match returns error", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)

    File.cd!(Path.join(project, "main"))

    # Create two feature branches
    {:ok, _} = Checkout.run(["-b", "feature-login"], :text)
    {:ok, _} = Checkout.run(["-b", "feature-signup"], :text)

    # Ambiguous match
    assert {:error, msg} = Checkout.run(["feature"], :text)
    assert msg =~ "ambiguous"
    assert msg =~ "feature-login"
    assert msg =~ "feature-signup"
  end

  test "checkout -b tracks remote branch", %{tmp: tmp} do
    origin = GitWork.TestHelper.create_origin_repo(tmp)
    project = Path.join(tmp, "project")
    {:ok, _} = GitWork.Commands.Clone.run([origin, project], :text)

    {_, 0} =
      System.cmd("git", ["config", "git-work.hooks.mise.task", ""],
        cd: Path.join(project, ".bare")
      )

    # Create a branch on the remote
    GitWork.TestHelper.create_remote_branch(origin, "feature-remote")

    # Fetch so the project knows about it
    System.cmd("git", ["fetch", "--all"], cd: Path.join(project, ".bare"))

    File.cd!(Path.join(project, "main"))

    assert {:ok, path} = Checkout.run(["-b", "feature-remote"], :text)
    assert File.dir?(path)
    assert File.regular?(Path.join(path, "feature-remote.txt"))
  end

  test "checkout without -b auto-creates worktree from remote branch", %{tmp: tmp} do
    origin = GitWork.TestHelper.create_origin_repo(tmp)
    project = Path.join(tmp, "project")
    {:ok, _} = GitWork.Commands.Clone.run([origin, project], :text)

    {_, 0} =
      System.cmd("git", ["config", "git-work.hooks.mise.task", ""],
        cd: Path.join(project, ".bare")
      )

    # Create a branch on the remote
    GitWork.TestHelper.create_remote_branch(origin, "feature-remote")

    # Fetch so the project knows about it
    System.cmd("git", ["fetch", "--all"], cd: Path.join(project, ".bare"))

    File.cd!(Path.join(project, "main"))

    # Checkout without -b should auto-create from remote
    assert {:ok, path} = Checkout.run(["feature-remote"], :text)
    assert File.dir?(path)
    assert path == Path.join(project, "feature-remote")
    assert File.regular?(Path.join(path, "feature-remote.txt"))

    # Verify git knows about the worktree
    {output, 0} = System.cmd("git", ["worktree", "list"], cd: Path.join(project, ".bare"))
    assert output =~ "feature-remote"
  end

  test "post worktree hook runs on -b and can modify worktree", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)
    bare = Path.join(project, ".bare")

    GitWork.TestHelper.write_hook_script(tmp)
    GitWork.TestHelper.prepend_path(tmp)

    File.write!(Path.join([project, "main", ".trusted"]), "ok")

    {_, 0} = System.cmd("git", ["config", "git-work.hooks.mise.task", "hook-task"], cd: bare)

    File.cd!(Path.join(project, "main"))

    assert {:ok, path} = Checkout.run(["-b", "feature-hook"], :text)
    assert File.regular?(Path.join(path, "hook-ran"))
    assert File.regular?(Path.join(path, ".trusted"))
  end

  test "existing worktree checkout does not run hook", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)
    bare = Path.join(project, ".bare")

    GitWork.TestHelper.write_hook_script(tmp)
    GitWork.TestHelper.prepend_path(tmp)

    {_, 0} = System.cmd("git", ["config", "git-work.hooks.mise.task", "hook-task"], cd: bare)

    File.cd!(Path.join(project, "main"))

    assert {:ok, _} = Checkout.run(["-b", "feature-existing"], :text)
    File.rm!(Path.join([project, "feature-existing", "hook-ran"]))

    assert {:ok, path} = Checkout.run(["feature-existing"], :text)
    refute File.regular?(Path.join(path, "hook-ran"))
  end

  test "post worktree hook failure triggers rollback", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)
    bare = Path.join(project, ".bare")

    GitWork.TestHelper.write_hook_script(tmp)
    GitWork.TestHelper.prepend_path(tmp)

    {_, 0} = System.cmd("git", ["config", "git-work.hooks.mise.task", "hook-fail"], cd: bare)

    File.cd!(Path.join(project, "main"))

    assert {:error, msg} = Checkout.run(["-b", "feature-fail"], :text)
    assert msg =~ "mise run"
    refute File.dir?(Path.join(project, "feature-fail"))

    {output, 0} = System.cmd("git", ["branch", "--list", "feature-fail"], cd: bare)
    assert output == ""
  end

  test "post worktree hook ignores missing mise task", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)
    bare = Path.join(project, ".bare")

    GitWork.TestHelper.write_hook_script(tmp)
    GitWork.TestHelper.prepend_path(tmp)

    {_, 0} = System.cmd("git", ["config", "git-work.hooks.mise.task", "hook-missing"], cd: bare)

    File.cd!(Path.join(project, "main"))

    assert {:ok, path} = Checkout.run(["-b", "feature-missing"], :text)
    assert File.dir?(path)
    refute File.regular?(Path.join(path, "hook-ran"))
  end

  test "checkout -b with explicit local branch as base starts from that branch", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)
    bare = Path.join(project, ".bare")

    # Create a side branch and advance it past main with a new commit
    File.cd!(Path.join(project, "main"))
    {:ok, side_path} = Checkout.run(["-b", "side"], :text)
    File.write!(Path.join(side_path, "side.txt"), "side content")
    System.cmd("git", ["add", "."], cd: side_path)
    System.cmd("git", ["-c", "user.name=Test", "-c", "user.email=test@test.com",
      "commit", "-m", "side commit"], cd: side_path)

    # Create a child branch from "side" while sitting in a different worktree
    File.cd!(Path.join(project, "main"))
    assert {:ok, path} = Checkout.run(["-b", "child-branch", "side"], :text)
    assert File.dir?(path)

    {child_sha, 0} = System.cmd("git", ["rev-parse", "child-branch"], cd: bare)
    {side_sha, 0} = System.cmd("git", ["rev-parse", "side"], cd: bare)
    assert String.trim(child_sha) == String.trim(side_sha)
  end

  test "checkout -b with origin/main as base creates branch from remote HEAD", %{tmp: tmp} do
    origin = GitWork.TestHelper.create_origin_repo(tmp)
    project = Path.join(tmp, "project")
    {:ok, _} = GitWork.Commands.Clone.run([origin, project], :text)

    {_, 0} =
      System.cmd("git", ["config", "git-work.hooks.mise.task", ""],
        cd: Path.join(project, ".bare")
      )

    File.cd!(Path.join(project, "main"))

    assert {:ok, path} = Checkout.run(["-b", "feature-from-remote", "origin/main"], :text)
    assert File.dir?(path)

    bare = Path.join(project, ".bare")
    {child_sha, 0} = System.cmd("git", ["rev-parse", "feature-from-remote"], cd: bare)
    {origin_sha, 0} = System.cmd("git", ["rev-parse", "origin/main"], cd: bare)
    assert String.trim(child_sha) == String.trim(origin_sha)
  end

  test "checkout -b with explicit base errors when branch already exists", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)

    File.cd!(Path.join(project, "main"))

    assert {:error, msg} = Checkout.run(["-b", "main", "some-base"], :text)
    assert msg =~ "already exists"
    assert msg =~ "base ref"
  end

  test "checkout -b without explicit base uses current worktree HEAD", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)
    bare = Path.join(project, ".bare")

    # Create a side branch and advance it past main
    File.cd!(Path.join(project, "main"))
    {:ok, side_path} = Checkout.run(["-b", "side"], :text)
    File.write!(Path.join(side_path, "side.txt"), "side content")
    System.cmd("git", ["add", "."], cd: side_path)
    System.cmd("git", ["-c", "user.name=Test", "-c", "user.email=test@test.com",
      "commit", "-m", "side commit"], cd: side_path)

    # From inside the side worktree, create a new branch with no explicit base
    File.cd!(side_path)
    assert {:ok, path} = Checkout.run(["-b", "child-branch"], :text)
    assert File.dir?(path)

    {child_sha, 0} = System.cmd("git", ["rev-parse", "child-branch"], cd: bare)
    {side_sha, 0} = System.cmd("git", ["rev-parse", "side"], cd: bare)
    {main_sha, 0} = System.cmd("git", ["rev-parse", "main"], cd: bare)
    # child-branch must start from side's HEAD, not main's (they differ by the extra commit)
    assert String.trim(child_sha) == String.trim(side_sha)
    refute String.trim(child_sha) == String.trim(main_sha)
  end

  test "trust not propagated to new worktree when source is untrusted", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)
    bare = Path.join(project, ".bare")

    GitWork.TestHelper.write_hook_script(tmp)
    GitWork.TestHelper.prepend_path(tmp)

    # Note: no .trusted written to main — source is untrusted
    {_, 0} = System.cmd("git", ["config", "git-work.hooks.mise.task", ""], cd: bare)

    File.cd!(Path.join(project, "main"))

    assert {:ok, path} = Checkout.run(["-b", "feature-no-trust"], :text)
    refute File.regular?(Path.join(path, ".trusted"))
  end

  test "trust propagated when auto-creating worktree from trusted remote branch", %{tmp: tmp} do
    origin = GitWork.TestHelper.create_origin_repo(tmp)
    project = Path.join(tmp, "project")
    {:ok, _} = GitWork.Commands.Clone.run([origin, project], :text)
    bare = Path.join(project, ".bare")

    GitWork.TestHelper.write_hook_script(tmp)
    GitWork.TestHelper.prepend_path(tmp)

    {_, 0} = System.cmd("git", ["config", "git-work.hooks.mise.task", ""], cd: bare)

    # Trust the source worktree
    File.write!(Path.join([project, "main", ".trusted"]), "ok")

    GitWork.TestHelper.create_remote_branch(origin, "feature-trust-remote")
    System.cmd("git", ["fetch", "--all"], cd: bare)

    File.cd!(Path.join(project, "main"))

    assert {:ok, path} = Checkout.run(["feature-trust-remote"], :text)
    assert File.regular?(Path.join(path, ".trusted"))
  end

  test "trust propagated from project root when source branch worktree is trusted", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)
    bare = Path.join(project, ".bare")

    GitWork.TestHelper.write_hook_script(tmp)
    GitWork.TestHelper.prepend_path(tmp)

    {_, 0} = System.cmd("git", ["config", "git-work.hooks.mise.task", ""], cd: bare)

    # Trust the main worktree
    File.write!(Path.join([project, "main", ".trusted"]), "ok")

    # Run checkout from project root (not from inside a worktree)
    File.cd!(project)

    assert {:ok, path} = Checkout.run(["-b", "feature-from-root"], :text)
    assert File.regular?(Path.join(path, ".trusted"))
  end

  test "checkout auto-create from remote sets upstream tracking", %{tmp: tmp} do
    origin = GitWork.TestHelper.create_origin_repo(tmp)
    project = Path.join(tmp, "project")
    {:ok, _} = GitWork.Commands.Clone.run([origin, project], :text)

    {_, 0} =
      System.cmd("git", ["config", "git-work.hooks.mise.task", ""],
        cd: Path.join(project, ".bare")
      )

    GitWork.TestHelper.create_remote_branch(origin, "feature-tracking")
    System.cmd("git", ["fetch", "--all"], cd: Path.join(project, ".bare"))

    File.cd!(Path.join(project, "main"))

    # Auto-create worktree from remote branch (no -b)
    assert {:ok, path} = Checkout.run(["feature-tracking"], :text)
    assert File.dir?(path)

    # Upstream tracking should be set to the remote branch
    {upstream, 0} =
      System.cmd("git", ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
        cd: path
      )

    assert String.trim(upstream) == "origin/feature-tracking"
  end

  test "checkout -b new branch has push.autoSetupRemote configured", %{tmp: tmp} do
    origin = GitWork.TestHelper.create_origin_repo(tmp)
    project = Path.join(tmp, "project")
    {:ok, _} = GitWork.Commands.Clone.run([origin, project], :text)

    {_, 0} =
      System.cmd("git", ["config", "git-work.hooks.mise.task", ""],
        cd: Path.join(project, ".bare")
      )

    File.cd!(Path.join(project, "main"))

    assert {:ok, path} = Checkout.run(["-b", "feature-fresh"], :text)
    assert File.dir?(path)

    # push.autoSetupRemote should be set on the bare repo so that
    # `git push` from any worktree automatically sets upstream tracking
    {auto_setup, 0} =
      System.cmd("git", ["config", "push.autoSetupRemote"], cd: Path.join(project, ".bare"))

    assert String.trim(auto_setup) == "true"

    # New branch has no upstream yet (nothing on remote)
    {_, exit_code} =
      System.cmd("git", ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
        cd: path
      )

    assert exit_code != 0

    # Default push with autoSetupRemote — should set upstream automatically
    {_, 0} = System.cmd("git", ["push"], cd: path)

    {upstream, 0} =
      System.cmd("git", ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
        cd: path
      )

    assert String.trim(upstream) == "origin/feature-fresh"
  end
end
