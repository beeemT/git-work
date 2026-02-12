defmodule GitWork.TestHelper do
  @moduledoc """
  Helpers for integration tests. Creates real git repos in tmp directories.
  GIT_CONFIG_GLOBAL=/dev/null is set in test_helper.exs so user config
  (1Password, GPG signing, etc.) never interferes.
  """

  defp git(args, opts) do
    System.cmd("git", args, opts)
  end

  @doc """
  Create a bare git repo that can be used as a "remote" for clone tests.
  Returns the path to the bare repo.
  """
  def create_origin_repo(base_dir) do
    normal = Path.join(base_dir, "origin_normal")
    File.mkdir_p!(normal)

    git(["init", "-b", "main"], cd: normal)
    File.write!(Path.join(normal, "README.md"), "# Test\n")
    git(["add", "."], cd: normal)

    git(["-c", "user.name=Test", "-c", "user.email=test@test.com", "commit", "-m", "init"],
      cd: normal
    )

    bare = Path.join(base_dir, "origin.git")
    git(["clone", "--bare", normal, bare], cd: base_dir)

    bare
  end

  @doc """
  Create a normal (non-bare) git repo with a commit.
  Returns the path to the repo.
  """
  def create_normal_repo(base_dir) do
    repo = Path.join(base_dir, "myrepo")
    File.mkdir_p!(repo)

    git(["init", "-b", "main"], cd: repo)
    File.write!(Path.join(repo, "README.md"), "# Test\n")
    File.write!(Path.join(repo, "src.ex"), "defmodule Test, do: nil\n")
    git(["add", "."], cd: repo)

    git(["-c", "user.name=Test", "-c", "user.email=test@test.com", "commit", "-m", "initial"],
      cd: repo
    )

    repo
  end

  @doc """
  Create a git-work project (already cloned layout) for testing checkout/rm/sync.
  Returns the project root path.
  """
  def create_gw_project(base_dir) do
    origin = create_origin_repo(base_dir)
    project = Path.join(base_dir, "project")

    {:ok, _main_path} = GitWork.Commands.Clone.run([origin, project])

    # Disable mise hook by default for tests unless explicitly enabled
    bare = Path.join(project, ".bare")
    git(["config", "git-work.hooks.mise.task", ""], cd: bare)

    project
  end

  @doc """
  Create an additional branch on the origin repo.
  """
  def create_remote_branch(origin_bare, branch_name) do
    tmp = Path.join(Path.dirname(origin_bare), "tmp_clone_#{System.unique_integer([:positive])}")
    git(["clone", origin_bare, tmp], cd: Path.dirname(origin_bare))
    git(["checkout", "-b", branch_name], cd: tmp)
    File.write!(Path.join(tmp, "#{branch_name}.txt"), "branch file\n")
    git(["add", "."], cd: tmp)

    git(
      [
        "-c",
        "user.name=Test",
        "-c",
        "user.email=test@test.com",
        "commit",
        "-m",
        "add #{branch_name}"
      ],
      cd: tmp
    )

    git(["push", "origin", branch_name], cd: tmp)
    File.rm_rf!(tmp)
    :ok
  end

  @doc """
  Delete a branch on the origin bare repo.
  """
  def delete_remote_branch(origin_bare, branch_name) do
    git(["branch", "-D", branch_name], cd: origin_bare)
    :ok
  end

  @doc """
  Write a fake mise script into base_dir that supports trust/run for tests.
  """
  def write_hook_script(base_dir) do
    script = Path.join(base_dir, "mise")

    File.write!(script, """
    #!/bin/sh
    set -eu
    cmd="$1"
    shift || true

    case "$cmd" in
      trust)
        if [ "${1:-}" = "--show" ]; then
          if [ -f ".trusted" ]; then
            echo "trusted"
          fi
          exit 0
        fi

        touch .trusted
        exit 0
        ;;
      run)
        task="$1"
        if [ "$task" = "hook-fail" ]; then
          echo "hook failed" >&2
          exit 1
        fi

        echo "$task" > hook-ran
        exit 0
        ;;
      *)
        echo "unknown command" >&2
        exit 1
        ;;
    esac
    """)

    File.chmod!(script, 0o755)
  end

  @doc """
  Prepend base_dir to PATH for current process.
  """
  def prepend_path(base_dir) do
    current = System.get_env("PATH") || ""
    System.put_env("PATH", base_dir <> ":" <> current)
  end
end
