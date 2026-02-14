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

    # Second run should repair and succeed
    assert {:ok, path} = Init.run([])
    assert path == Path.join(repo, "main")

    # core.bare should be true in .bare
    {value, 0} =
      System.cmd("git", ["config", "--bool", "core.bare"], cd: Path.join(repo, ".bare"))

    assert String.trim(value) == "true"
  end

  test "recreates missing HEAD worktree on rerun", %{tmp: tmp} do
    repo = GitWork.TestHelper.create_normal_repo(tmp)

    File.cd!(repo)

    assert {:ok, main_path} = Init.run([])
    File.rm_rf!(main_path)

    assert {:ok, new_path} = Init.run([])
    assert new_path == main_path
    assert File.dir?(new_path)
    assert File.regular?(Path.join(new_path, "README.md"))
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

  test "rolls back cleanly when init fails mid-way", %{tmp: tmp} do
    repo = GitWork.TestHelper.create_normal_repo(tmp)

    File.write!(Path.join(repo, "main"), "block worktree dir")

    File.cd!(repo)

    assert {:error, msg} = Init.run([])
    assert msg =~ "failed to create worktree directory"

    # .git restored as directory, .bare removed
    assert File.dir?(Path.join(repo, ".git"))
    refute File.exists?(Path.join(repo, ".bare"))

    # files remain at project root
    assert File.regular?(Path.join(repo, "README.md"))
    assert File.regular?(Path.join(repo, "src.ex"))
    assert File.regular?(Path.join(repo, "main"))
  end

  test "sets upstream for main worktree when origin exists", %{tmp: tmp} do
    repo = GitWork.TestHelper.create_normal_repo(tmp)
    origin = Path.join(tmp, "origin.git")

    System.cmd("git", ["init", "--bare", origin], cd: tmp)
    System.cmd("git", ["remote", "add", "origin", origin], cd: repo)
    System.cmd("git", ["push", "origin", "main"], cd: repo)

    {_, status} =
      System.cmd("git", ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], cd: repo)

    assert status != 0

    File.cd!(repo)
    assert {:ok, main_path} = Init.run([])

    {upstream, 0} =
      System.cmd("git", ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
        cd: main_path
      )

    assert upstream =~ "origin/main"
  end
end
