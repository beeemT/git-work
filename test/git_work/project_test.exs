defmodule GitWork.ProjectTest do
  use ExUnit.Case, async: true

  alias GitWork.Project

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

    test "lists non-hidden directories", %{tmp: tmp} do
      File.mkdir_p!(Path.join(tmp, ".bare"))
      File.mkdir_p!(Path.join(tmp, "main"))
      File.mkdir_p!(Path.join(tmp, "feature-login"))
      File.write!(Path.join(tmp, ".git"), "gitdir: ./.bare\n")

      dirs = Project.worktree_dirs(tmp)
      assert "main" in dirs
      assert "feature-login" in dirs
      refute ".bare" in dirs
      refute ".git" in dirs
    end
  end
end
