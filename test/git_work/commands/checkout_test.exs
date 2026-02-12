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

    assert {:ok, path} = Checkout.run(["main"])
    assert path == Path.join(project, "main")
  end

  test "checkout -b creates worktree for new branch", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)

    File.cd!(Path.join(project, "main"))

    assert {:ok, path} = Checkout.run(["-b", "feature-new"])
    assert path == Path.join(project, "feature-new")
    assert File.dir?(path)

    # Verify git knows about the worktree
    {output, 0} = System.cmd("git", ["worktree", "list"], cd: Path.join(project, ".bare"))
    assert output =~ "feature-new"
  end

  test "checkout without -b errors on non-existent branch", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)

    File.cd!(Path.join(project, "main"))

    assert {:error, msg} = Checkout.run(["feature-new"])
    assert msg =~ "no worktree found"
    assert msg =~ "-b"
  end

  test "checkout -b errors when worktree already exists", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)

    File.cd!(Path.join(project, "main"))

    assert {:error, msg} = Checkout.run(["-b", "main"])
    assert msg =~ "already exists"
  end

  test "checkout fuzzy matches substring", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)

    File.cd!(Path.join(project, "main"))

    # Create a feature branch worktree first
    {:ok, _} = Checkout.run(["-b", "feature-login"])

    # Now fuzzy match with substring
    assert {:ok, path} = Checkout.run(["login"])
    assert path == Path.join(project, "feature-login")
  end

  test "checkout ambiguous match returns error", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)

    File.cd!(Path.join(project, "main"))

    # Create two feature branches
    {:ok, _} = Checkout.run(["-b", "feature-login"])
    {:ok, _} = Checkout.run(["-b", "feature-signup"])

    # Ambiguous match
    assert {:error, msg} = Checkout.run(["feature"])
    assert msg =~ "ambiguous"
    assert msg =~ "feature-login"
    assert msg =~ "feature-signup"
  end

  test "checkout -b tracks remote branch", %{tmp: tmp} do
    origin = GitWork.TestHelper.create_origin_repo(tmp)
    project = Path.join(tmp, "project")
    {:ok, _} = GitWork.Commands.Clone.run([origin, project])

    {_, 0} =
      System.cmd("git", ["config", "git-work.hooks.mise.task", ""],
        cd: Path.join(project, ".bare")
      )

    # Create a branch on the remote
    GitWork.TestHelper.create_remote_branch(origin, "feature-remote")

    # Fetch so the project knows about it
    System.cmd("git", ["fetch", "--all"], cd: Path.join(project, ".bare"))

    File.cd!(Path.join(project, "main"))

    assert {:ok, path} = Checkout.run(["-b", "feature-remote"])
    assert File.dir?(path)
    assert File.regular?(Path.join(path, "feature-remote.txt"))
  end

  test "checkout without -b auto-creates worktree from remote branch", %{tmp: tmp} do
    origin = GitWork.TestHelper.create_origin_repo(tmp)
    project = Path.join(tmp, "project")
    {:ok, _} = GitWork.Commands.Clone.run([origin, project])

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
    assert {:ok, path} = Checkout.run(["feature-remote"])
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

    assert {:ok, path} = Checkout.run(["-b", "feature-hook"])
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

    assert {:ok, _} = Checkout.run(["-b", "feature-existing"])
    File.rm!(Path.join([project, "feature-existing", "hook-ran"]))

    assert {:ok, path} = Checkout.run(["feature-existing"])
    refute File.regular?(Path.join(path, "hook-ran"))
  end

  test "post worktree hook failure triggers rollback", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)
    bare = Path.join(project, ".bare")

    GitWork.TestHelper.write_hook_script(tmp)
    GitWork.TestHelper.prepend_path(tmp)

    {_, 0} = System.cmd("git", ["config", "git-work.hooks.mise.task", "hook-fail"], cd: bare)

    File.cd!(Path.join(project, "main"))

    assert {:error, msg} = Checkout.run(["-b", "feature-fail"])
    assert msg =~ "mise run"
    refute File.dir?(Path.join(project, "feature-fail"))

    {output, 0} = System.cmd("git", ["branch", "--list", "feature-fail"], cd: bare)
    assert output == ""
  end
end
