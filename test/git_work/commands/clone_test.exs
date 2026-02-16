defmodule GitWork.Commands.CloneTest do
  use ExUnit.Case

  alias GitWork.Commands.Clone

  setup do
    old_cwd = File.cwd!()
    tmp = Path.join(System.tmp_dir!(), "gw_clone_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    on_exit(fn ->
      File.cd!(old_cwd)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  test "clone creates expected layout", %{tmp: tmp} do
    origin = GitWork.TestHelper.create_origin_repo(tmp)
    project = Path.join(tmp, "myproject")

    assert {:ok, main_path} = Clone.run([origin, project])
    assert main_path == Path.join(project, "main")

    # .bare/ exists and is a git dir
    assert File.dir?(Path.join(project, ".bare"))
    assert File.dir?(Path.join(project, ".bare/objects"))

    # .git is a file with gitdir pointer
    git_file = Path.join(project, ".git")
    assert File.regular?(git_file)
    assert File.read!(git_file) == "gitdir: ./.bare\n"

    # main/ worktree exists and has files
    assert File.dir?(main_path)
    assert File.regular?(Path.join(main_path, "README.md"))

    # main/ has a .git file (not directory) pointing to bare worktree
    wt_git = Path.join(main_path, ".git")
    assert File.regular?(wt_git)

    # git worktree list shows main
    {output, 0} = System.cmd("git", ["worktree", "list"], cd: Path.join(project, ".bare"))
    assert output =~ "main"

    {upstream, 0} =
      System.cmd("git", ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
        cd: main_path
      )

    assert upstream =~ "origin/main"
  end

  test "clone derives directory from URL", %{tmp: tmp} do
    origin = GitWork.TestHelper.create_origin_repo(tmp)
    # origin path ends with "origin.git"

    # cd to tmp so relative paths work
    File.cd!(tmp)

    assert {:ok, _} = Clone.run([origin])

    # Should have created "origin/" directory (stripped .git suffix)
    assert File.dir?(Path.join(tmp, "origin"))
    assert File.dir?(Path.join(tmp, "origin/.bare"))
  end

  test "clone fails if directory already exists", %{tmp: tmp} do
    origin = GitWork.TestHelper.create_origin_repo(tmp)
    project = Path.join(tmp, "existing")
    File.mkdir_p!(project)

    assert {:error, msg} = Clone.run([origin, project])
    assert msg =~ "already exists"
  end
end
