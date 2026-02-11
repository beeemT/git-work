defmodule GitWork.Commands.Checkout do
  @moduledoc """
  Switch to a branch worktree. Creates the worktree if it doesn't exist.
  Supports fuzzy matching against existing worktrees.
  """

  alias GitWork.{Git, Project, Fuzzy}

  def help do
    """
    usage: git-work checkout <branch>

    Switch to a branch by navigating to its worktree directory.

    If the worktree already exists, prints its path. If not, creates a new
    worktree (tracking the remote branch if one exists, or creating a new
    local branch otherwise).

    Supports fuzzy matching against existing worktrees:
      - Substring: 'login' matches 'feature-login'
      - Typos: 'featur-login' matches 'feature-login'
      - Ambiguous matches exit non-zero and list candidates

    Must be run from within a git-work project (any worktree or the root).

    Examples:
      git-work checkout feature-login    # exact or create new
      git-work checkout login            # fuzzy match
      git-work checkout feature/new      # creates feature-new/ worktree
    """
  end

  def run(args) do
    case args do
      [branch] ->
        with {:ok, root} <- Project.find_root() do
          do_checkout(root, branch)
        end

      _ ->
        {:error, "usage: git-work checkout <branch>"}
    end
  end

  defp do_checkout(root, input) do
    existing = Project.worktree_dirs(root)
    sanitized = Project.sanitize_branch(input)

    # First try exact match on sanitized name
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
              {:ok, _} -> {:ok, worktree_dir}
              {:error, msg} -> {:error, "worktree add failed: #{msg}"}
            end

          {:error, _} ->
            # Brand new branch
            case Git.cmd(["worktree", "add", "-b", branch, worktree_dir], cd: bare_dir) do
              {:ok, _} -> {:ok, worktree_dir}
              {:error, msg} -> {:error, "worktree add failed: #{msg}"}
            end
        end

      {:ok, _} ->
        # Remote branch exists — track it
        case Git.cmd(["worktree", "add", worktree_dir, branch], cd: bare_dir) do
          {:ok, _} -> {:ok, worktree_dir}
          {:error, msg} -> {:error, "worktree add failed: #{msg}"}
        end

      {:error, msg} ->
        {:error, "failed to check remote branches: #{msg}"}
    end
  end
end
