defmodule GitWork.Commands.RmTest do
  use ExUnit.Case

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

  test "removes worktree and branch", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)

    File.cd!(Path.join(project, "main"))

    # Create a feature branch
    {:ok, _} = Checkout.run(["feature-rm-test"])
    assert File.dir?(Path.join(project, "feature-rm-test"))

    # Remove it
    assert {:ok, _} = Rm.run(["feature-rm-test"])

    # Directory should be gone
    refute File.dir?(Path.join(project, "feature-rm-test"))

    # git worktree list should not show it
    {output, 0} = System.cmd("git", ["worktree", "list"], cd: Path.join(project, ".bare"))
    refute output =~ "feature-rm-test"

    # Branch should be gone
    {branches, 0} = System.cmd("git", ["branch"], cd: Path.join(project, ".bare"))
    refute branches =~ "feature-rm-test"
  end

  test "refuses to remove HEAD branch without --force", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)

    File.cd!(Path.join(project, "main"))

    assert {:error, msg} = Rm.run(["main"])
    assert msg =~ "refusing"
    assert msg =~ "force"

    # main should still exist
    assert File.dir?(Path.join(project, "main"))
  end

  test "rm from inside worktree returns main path", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)

    File.cd!(Path.join(project, "main"))

    {:ok, _} = Checkout.run(["feature-inside"])

    # cd into the feature worktree
    File.cd!(Path.join(project, "feature-inside"))

    assert {:ok, path} = Rm.run(["feature-inside"])
    # Should return main path for shell wrapper to cd into
    assert path == Path.join(project, "main")
  end
end
