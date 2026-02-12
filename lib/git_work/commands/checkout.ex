defmodule GitWork.Commands.Checkout do
  @moduledoc """
  Switch to a branch worktree, or create a new one with -b.
  Supports fuzzy matching against existing worktrees.
  """

  alias GitWork.{Git, Project, Fuzzy, Hooks}

  def help do
    """
    usage: git-work checkout <branch>
           git-work checkout -b <branch>

    Switch to a branch by navigating to its worktree directory.

    Without -b, matches an existing worktree (exact or fuzzy) and prints its
    path. If no worktree matches but a remote branch with that exact name
    exists, a new worktree is automatically created tracking the remote branch.
    Returns an error only if neither a worktree nor a remote branch is found.

    With -b, creates a new worktree for the given branch (tracking the remote
    branch if one exists, or creating a new local branch otherwise). Returns
    an error if a worktree for that branch already exists.

    Supports fuzzy matching against existing worktrees:
      - Substring: 'login' matches 'feature-login'
      - Typos: 'featur-login' matches 'feature-login'
      - Ambiguous matches exit non-zero and list candidates

    Must be run from within a git-work project (any worktree or the root).

    Examples:
      git-work checkout feature-login    # switch to existing worktree
      git-work checkout login            # fuzzy match existing worktree
      git-work checkout feature/remote   # auto-create from remote branch
      git-work checkout -b feature/new   # create new worktree
    """
  end

  def run(args) do
    case args do
      ["-b", branch] ->
        with {:ok, root} <- Project.find_root() do
          do_create(root, branch)
        end

      [branch] ->
        with {:ok, root} <- Project.find_root() do
          do_checkout(root, branch)
        end

      _ ->
        {:error, "usage: git-work checkout [-b] <branch>"}
    end
  end

  defp do_checkout(root, input) do
    existing = Project.worktree_dirs(root)
    sanitized = Project.sanitize_branch(input)

    case Fuzzy.match(sanitized, existing) do
      {:exact, name} ->
        {:ok, Path.join(root, name)}

      {:match, name} ->
        IO.write(:stderr, "fuzzy match: '#{input}' -> '#{name}'\n")
        {:ok, Path.join(root, name)}

      {:ambiguous, candidates} ->
        formatted = Enum.map_join(candidates, "\n", &"  #{&1}")
        {:error, "ambiguous match for '#{input}':\n#{formatted}"}

      :no_match ->
        # No existing worktree — check if a remote branch matches
        bare_dir = Project.bare_path(root)

        case Git.cmd(["branch", "-r", "--list", "origin/#{input}"], cd: bare_dir) do
          {:ok, ""} ->
            {:error, "no worktree found for '#{input}' (use -b to create one)"}

          {:ok, _} ->
            IO.write(:stderr, "creating worktree from remote branch: '#{input}'\n")
            create_worktree(root, input, sanitized)

          {:error, _} ->
            {:error, "no worktree found for '#{input}' (use -b to create one)"}
        end
    end
  end

  defp do_create(root, input) do
    existing = Project.worktree_dirs(root)
    sanitized = Project.sanitize_branch(input)

    if sanitized in existing do
      {:error, "worktree '#{sanitized}' already exists"}
    else
      create_worktree(root, input, sanitized)
    end
  end

  defp create_worktree(root, branch, dir_name) do
    bare_dir = Project.bare_path(root)
    worktree_dir = Path.join(root, dir_name)

    # Check if branch exists on remote
    case Git.cmd(["branch", "-r", "--list", "origin/#{branch}"], cd: bare_dir) do
      {:ok, ""} ->
        # Branch doesn't exist on remote — check local
        case Git.cmd(["show-ref", "--verify", "refs/heads/#{branch}"], cd: bare_dir) do
          {:ok, _} ->
            # Local branch exists
            case Git.cmd(["worktree", "add", worktree_dir, branch], cd: bare_dir) do
              {:ok, _} ->
                run_hooks(root, worktree_dir, branch)

              {:error, msg} ->
                {:error, "worktree add failed: #{msg}"}
            end

          {:error, _} ->
            # Brand new branch
            case Git.cmd(["worktree", "add", "-b", branch, worktree_dir], cd: bare_dir) do
              {:ok, _} ->
                run_hooks(root, worktree_dir, branch)

              {:error, msg} ->
                {:error, "worktree add failed: #{msg}"}
            end
        end

      {:ok, _} ->
        # Remote branch exists — track it
        case Git.cmd(["worktree", "add", worktree_dir, branch], cd: bare_dir) do
          {:ok, _} ->
            run_hooks(root, worktree_dir, branch)

          {:error, msg} ->
            {:error, "worktree add failed: #{msg}"}
        end

      {:error, msg} ->
        {:error, "failed to check remote branches: #{msg}"}
    end
  end

  defp run_hooks(root, worktree_dir, branch) do
    ctx = %{
      root: root,
      worktree_dir: worktree_dir,
      branch: branch,
      source_worktree: File.cwd!()
    }

    case Hooks.run(:post_worktree_create, ctx) do
      :ok ->
        {:ok, worktree_dir}

      {:error, msg} ->
        rollback_worktree(root, worktree_dir, branch, msg)
    end
  end

  defp rollback_worktree(root, worktree_dir, branch, reason) do
    bare_dir = Project.bare_path(root)

    case Git.cmd(["worktree", "remove", worktree_dir], cd: bare_dir) do
      {:ok, _} -> :ok
      {:error, msg} -> IO.write(:stderr, "rollback: worktree remove failed: #{msg}\n")
    end

    case Git.cmd(["branch", "-D", branch], cd: bare_dir) do
      {:ok, _} -> :ok
      {:error, msg} -> IO.write(:stderr, "rollback: branch delete failed: #{msg}\n")
    end

    {:error, reason}
  end
end
