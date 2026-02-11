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

  test "checkout creates worktree for new branch", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)

    File.cd!(Path.join(project, "main"))

    assert {:ok, path} = Checkout.run(["feature-new"])
    assert path == Path.join(project, "feature-new")
    assert File.dir?(path)

    # Verify git knows about the worktree
    {output, 0} = System.cmd("git", ["worktree", "list"], cd: Path.join(project, ".bare"))
    assert output =~ "feature-new"
  end

  test "checkout fuzzy matches substring", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)

    File.cd!(Path.join(project, "main"))

    # Create a feature branch worktree first
    {:ok, _} = Checkout.run(["feature-login"])

    # Now fuzzy match with substring
    assert {:ok, path} = Checkout.run(["login"])
    assert path == Path.join(project, "feature-login")
  end

  test "checkout ambiguous match returns error", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)

    File.cd!(Path.join(project, "main"))

    # Create two feature branches
    {:ok, _} = Checkout.run(["feature-login"])
    {:ok, _} = Checkout.run(["feature-signup"])

    # Ambiguous match
    assert {:error, msg} = Checkout.run(["feature"])
    assert msg =~ "ambiguous"
    assert msg =~ "feature-login"
    assert msg =~ "feature-signup"
  end

  test "checkout tracks remote branch", %{tmp: tmp} do
    origin = GitWork.TestHelper.create_origin_repo(tmp)
    project = Path.join(tmp, "project")
    {:ok, _} = GitWork.Commands.Clone.run([origin, project])

    # Create a branch on the remote
    GitWork.TestHelper.create_remote_branch(origin, "feature-remote")

    # Fetch so the project knows about it
    System.cmd("git", ["fetch", "--all"], cd: Path.join(project, ".bare"))

    File.cd!(Path.join(project, "main"))

    assert {:ok, path} = Checkout.run(["feature-remote"])
    assert File.dir?(path)
    assert File.regular?(Path.join(path, "feature-remote.txt"))
  end
end
