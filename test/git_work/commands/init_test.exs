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

    assert {:ok, main_path} = Init.run([], :text)
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

    assert {:ok, _} = Init.run([], :text)

    # Second run should repair and succeed
    assert {:ok, path} = Init.run([], :text)
    assert path == Path.join(repo, "main")

    # core.bare should be true in .bare
    {value, 0} =
      System.cmd("git", ["config", "--bool", "core.bare"], cd: Path.join(repo, ".bare"))

    assert String.trim(value) == "true"

    # push.autoSetupRemote should be set by repair
    {auto_setup, 0} =
      System.cmd("git", ["config", "push.autoSetupRemote"], cd: Path.join(repo, ".bare"))

    assert String.trim(auto_setup) == "true"
  end

  test "recreates missing HEAD worktree on rerun", %{tmp: tmp} do
    repo = GitWork.TestHelper.create_normal_repo(tmp)

    File.cd!(repo)

    assert {:ok, main_path} = Init.run([], :text)
    File.rm_rf!(main_path)

    assert {:ok, new_path} = Init.run([], :text)
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

    assert {:ok, main_path} = Init.run([], :text)

    # The dirty file should be in the worktree (stash popped)
    assert File.regular?(Path.join(main_path, "dirty.txt"))
    assert File.read!(Path.join(main_path, "dirty.txt")) == "uncommitted\n"
  end

  test "rolls back cleanly when init fails mid-way", %{tmp: tmp} do
    repo = GitWork.TestHelper.create_normal_repo(tmp)

    File.write!(Path.join(repo, "main"), "block worktree dir")

    File.cd!(repo)

    assert {:error, msg} = Init.run([], :text)
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
    assert {:ok, main_path} = Init.run([], :text)

    {upstream, 0} =
      System.cmd("git", ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
        cd: main_path
      )

    assert upstream =~ "origin/main"
  end
  test "propagates mise trust to worktree when source was trusted", %{tmp: tmp} do
    repo = GitWork.TestHelper.create_normal_repo(tmp)
    GitWork.TestHelper.write_trust_check_script(tmp, true)
    GitWork.TestHelper.prepend_path(tmp)

    File.cd!(repo)

    assert {:ok, main_path} = Init.run([], :text)
    # .mise-hook-trusted is written by fake `mise trust` (not --show),
    # proving trust was actively applied to the worktree.
    assert File.regular?(Path.join(main_path, ".mise-hook-trusted"))
  end

  test "does not run mise trust when source was not trusted", %{tmp: tmp} do
    repo = GitWork.TestHelper.create_normal_repo(tmp)
    GitWork.TestHelper.write_trust_check_script(tmp, false)
    GitWork.TestHelper.prepend_path(tmp)

    File.cd!(repo)

    assert {:ok, main_path} = Init.run([], :text)
    refute File.regular?(Path.join(main_path, ".mise-hook-trusted"))
  end

  test "respects git-work.hooks.mise.trust false config", %{tmp: tmp} do
    repo = GitWork.TestHelper.create_normal_repo(tmp)
    GitWork.TestHelper.write_trust_check_script(tmp, true)
    GitWork.TestHelper.prepend_path(tmp)

    # Set in .git/config now; it becomes .bare/config after init renames .git/ -> .bare/
    System.cmd("git", ["config", "git-work.hooks.mise.trust", "false"], cd: repo)

    File.cd!(repo)

    assert {:ok, main_path} = Init.run([], :text)
    refute File.regular?(Path.join(main_path, ".mise-hook-trusted"))
  end

  test "repair resets stale index showing files as deleted", %{tmp: tmp} do
    # Simulate the user's scenario: files are physically deleted from the worktree
    # (e.g. git clean -fd or manual deletion), causing git status to show all files
    # as deleted. Running gw init should reset the index to match HEAD, clearing
    # the stale "deleted" entries from the index so status shows clean (since
    # the committed state matches the index — both say the files don't exist).
    repo = GitWork.TestHelper.create_normal_repo(tmp)
    File.cd!(repo)

    assert {:ok, main_path} = Init.run([], :text)

    # Physically delete tracked files from the worktree
    File.rm!(Path.join(main_path, "README.md"))
    File.rm!(Path.join(main_path, "src.ex"))

    # Verify the corruption: git status shows deleted files (porcelain uses " D" for staged deletions)
    {status_output, _} = System.cmd("git", ["status", "--porcelain"], cd: main_path)
    assert status_output =~ "README.md"

    # Repair with a second init run
    assert {:ok, _} = Init.run([], :text)

    # checkout-index -a -f restores deleted files from the index
    assert File.regular?(Path.join(main_path, "README.md"))
    assert File.regular?(Path.join(main_path, "src.ex"))

    # git status should be clean
    {status_output, _} = System.cmd("git", ["status", "--porcelain"], cd: main_path)
    assert status_output == ""
  end

  test "repair fixes corrupted .git pointer file", %{tmp: tmp} do
    repo = GitWork.TestHelper.create_normal_repo(tmp)
    File.cd!(repo)

    assert {:ok, _} = Init.run([], :text)

    # Overwrite the .git pointer with garbage
    File.write!(Path.join(repo, ".git"), "garbage content\n")

    assert {:ok, _} = Init.run([], :text)

    # .git pointer should be restored
    assert File.read!(Path.join(repo, ".git")) == "gitdir: ./.bare\n"
  end

  test "--force allows repair when .git is a directory", %{tmp: tmp} do
    repo = GitWork.TestHelper.create_normal_repo(tmp)
    File.cd!(repo)

    assert {:ok, _} = Init.run([], :text)

    # Simulate corrupt state: .git exists as a directory
    File.rm_rf!(Path.join(repo, ".git"))
    File.mkdir!(Path.join(repo, ".git"))
    # Put something inside so it looks like a real .git dir
    File.write!(Path.join([repo, ".git", "config"]), "[core]\n")

    # Without --force this should error
    assert {:error, msg} = Init.run([], :text)
    assert msg =~ ".git directory"

    # With --force it should repair
    assert {:ok, _} = Init.run(["--force"], :text)

    # .git should be a pointer file again
    assert File.regular?(Path.join(repo, ".git"))
    assert File.read!(Path.join(repo, ".git")) == "gitdir: ./.bare\n"
  end

  test "repair re-registers unregistered worktree with --force", %{tmp: tmp} do
    repo = GitWork.TestHelper.create_normal_repo(tmp)
    File.cd!(repo)

    assert {:ok, main_path} = Init.run([], :text)

    # Remove the worktree metadata from the bare repo (but leave files intact)
    worktree_meta = Path.join([repo, ".bare", "worktrees", "main"])
    File.rm_rf!(worktree_meta)
    # Also remove the .git pointer inside the worktree so git worktree add won't complain
    File.rm!(Path.join([main_path, ".git"]))

    # Without --force, repair fails with a helpful error
    assert {:error, msg} = Init.run([], :text)
    assert msg =~ "worktree is not registered"
    assert msg =~ "--force"

    # With --force, repair should detect the worktree is not registered and re-create it
    assert {:ok, _} = Init.run(["--force"], :text)

    # Worktree should be re-registered
    {output, 0} = System.cmd("git", ["worktree", "list"], cd: Path.join(repo, ".bare"))
    assert output =~ "main"

    # git status should work cleanly (no deleted files)
    {status_output, _} = System.cmd("git", ["status", "--porcelain"], cd: main_path)
    assert status_output == ""
  end

  test "repair restores deleted files but silently destroys local modifications", %{tmp: tmp} do
    repo = GitWork.TestHelper.create_normal_repo(tmp)
    File.cd!(repo)

    assert {:ok, main_path} = Init.run([], :text)

    # Delete tracked files — git status shows them as "deleted" (stale index)
    File.rm!(Path.join(main_path, "README.md"))
    File.rm!(Path.join(main_path, "src.ex"))

    # Also make an unstaged local modification to a different file
    File.write!(Path.join(main_path, "README.md"), "# My local changes\n")

    # Repair resets the index and runs checkout-index -a -f, which restores
    # all tracked files from the index — overwriting the unstaged modification.
    assert {:ok, _} = Init.run([], :text)

    # Deleted files are restored
    assert File.regular?(Path.join(main_path, "src.ex"))
    # The unstaged local modification is overwritten by checkout-index
    assert File.read!(Path.join(main_path, "README.md")) == "# Test\n"
  end
end
