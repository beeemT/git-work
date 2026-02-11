defmodule GitWork.Commands.InitTest do
  use ExUnit.Case

  alias GitWork.Commands.Init

  setup do
    old_cwd = File.cwd!()
    tmp = Path.join(System.tmp_dir!(), "gw_init_test_#{System.unique_integer([:positive])}")
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

  test "converts normal repo to gw layout", %{tmp: tmp} do
    repo = GitWork.TestHelper.create_normal_repo(tmp)

    File.cd!(repo)

    assert {:ok, main_path} = Init.run([])
    assert main_path == Path.join(repo, "main")

    # .bare/ exists
    assert File.dir?(Path.join(repo, ".bare"))

    # .git is a file
    git_file = Path.join(repo, ".git")
    assert File.regular?(git_file)
    assert File.read!(git_file) == "gitdir: ./.bare\n"

    # files moved into main/
    assert File.regular?(Path.join(main_path, "README.md"))
    assert File.regular?(Path.join(main_path, "src.ex"))

    # files NOT at project root
    refute File.regular?(Path.join(repo, "README.md"))
    refute File.regular?(Path.join(repo, "src.ex"))

    # git worktree list works
    {output, 0} = System.cmd("git", ["worktree", "list"], cd: Path.join(repo, ".bare"))
    assert output =~ "main"

    # git log works inside the worktree
    {log, 0} = System.cmd("git", ["log", "--oneline"], cd: main_path)
    assert log =~ "initial"
  end

  test "aborts if already initialized", %{tmp: tmp} do
    repo = GitWork.TestHelper.create_normal_repo(tmp)

    File.cd!(repo)

    assert {:ok, _} = Init.run([])

    # Second run should fail
    assert {:error, msg} = Init.run([])
    assert msg =~ "already initialized"
  end

  test "handles dirty working tree with stash", %{tmp: tmp} do
    repo = GitWork.TestHelper.create_normal_repo(tmp)

    # Make uncommitted changes
    File.write!(Path.join(repo, "dirty.txt"), "uncommitted\n")
    System.cmd("git", ["add", "dirty.txt"], cd: repo)

    File.cd!(repo)

    assert {:ok, main_path} = Init.run([])

    # The dirty file should be in the worktree (stash popped)
    assert File.regular?(Path.join(main_path, "dirty.txt"))
    assert File.read!(Path.join(main_path, "dirty.txt")) == "uncommitted\n"
  end
end
