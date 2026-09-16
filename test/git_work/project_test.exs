defmodule GitWork.ProjectTest do
  use ExUnit.Case, async: true

  alias GitWork.Project
  alias GitWork.Git

  describe "sanitize_branch/1" do
    test "replaces / with -" do
      assert Project.sanitize_branch("feature/login") == "feature-login"
    end

    test "handles multiple slashes" do
      assert Project.sanitize_branch("feature/auth/login") == "feature-auth-login"
    end

    test "no-op for names without slashes" do
      assert Project.sanitize_branch("main") == "main"
    end

    test "idempotent — already sanitized name unchanged" do
      assert Project.sanitize_branch("feature-login") == "feature-login"
    end
  end

  describe "dir_from_url/1" do
    test "extracts name from HTTPS URL with .git" do
      assert Project.dir_from_url("https://github.com/org/repo.git") == "repo"
    end

    test "extracts name from SSH URL with .git" do
      assert Project.dir_from_url("git@github.com:org/repo.git") == "repo"
    end

    test "extracts name from URL without .git" do
      assert Project.dir_from_url("https://github.com/org/repo") == "repo"
    end
  end

  describe "Git.current_branch/1" do
    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "gw_current_branch_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp}
    end

    test "returns the full branch name when it contains a ref-like prefix", %{tmp: tmp} do
      repo = GitWork.TestHelper.create_normal_repo(tmp)

      {_, 0} = System.cmd("git", ["branch", "-m", "main", "heads/main"], cd: repo)

      assert Git.current_branch(repo) == {:ok, "heads/main"}
    end
  end

  describe "configure_bare/1" do
    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "gw_configure_bare_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp}
    end

    test "preserves multiple fetch mappings and remains idempotent", %{tmp: tmp} do
      bare = GitWork.TestHelper.create_origin_repo(tmp)
      custom_heads = "+refs/heads/release:refs/remotes/upstream/release"
      custom_tags = "+refs/tags/*:refs/tags/*"
      standard_heads = "+refs/heads/*:refs/remotes/upstream/*"

      {_, 0} = System.cmd("git", ["config", "remote.upstream.url", bare], cd: bare)
      {_, 0} = System.cmd("git", ["config", "remote.upstream.fetch", custom_heads], cd: bare)

      {_, 0} =
        System.cmd("git", ["config", "--add", "remote.upstream.fetch", custom_tags], cd: bare)

      assert :ok = Project.configure_bare(bare)
      assert :ok = Project.configure_bare(bare)

      {fetches, 0} =
        System.cmd("git", ["config", "--get-all", "remote.upstream.fetch"], cd: bare)

      assert String.split(fetches, "\n", trim: true) == [
               custom_heads,
               custom_tags,
               standard_heads
             ]
    end
  end

  describe "find_root/1" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "gw_project_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp}
    end

    test "finds root when .bare/ exists in given dir", %{tmp: tmp} do
      File.mkdir_p!(Path.join(tmp, ".bare"))
      assert Project.find_root(tmp) == {:ok, tmp}
    end

    test "finds root from a subdirectory", %{tmp: tmp} do
      File.mkdir_p!(Path.join(tmp, ".bare"))
      subdir = Path.join(tmp, "main/src/lib")
      File.mkdir_p!(subdir)
      assert Project.find_root(subdir) == {:ok, tmp}
    end

    test "returns error when no .bare/ found", %{tmp: tmp} do
      assert {:error, _} = Project.find_root(tmp)
    end
  end

  describe "worktree_dirs/1" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "gw_wt_dirs_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp}
    end

    test "lists registered direct-child worktrees", %{tmp: tmp} do
      project = GitWork.TestHelper.create_gw_project(tmp)
      feature_path = Path.join(project, "feature-login")

      {_, 0} =
        System.cmd("git", ["branch", "feature/login", "main"], cd: Path.join(project, ".bare"))

      {_, 0} =
        System.cmd("git", ["worktree", "add", feature_path, "feature/login"],
          cd: Path.join(project, ".bare")
        )

      File.mkdir_p!(Path.join(project, "unregistered"))

      dirs = Project.worktree_dirs(project)
      assert "main" in dirs
      assert "feature-login" in dirs
      refute "unregistered" in dirs
      refute ".bare" in dirs
      refute ".git" in dirs
    end
  end
end
