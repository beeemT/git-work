defmodule GitWork.Commands.List do
  @moduledoc """
  List all worktrees. Thin wrapper around `git worktree list`.
  """

  alias GitWork.{Git, Project}

  def help do
    """
    usage: git-work list

    List all worktrees and their branches.

    Thin wrapper around 'git worktree list'. Must be run from within a
    git-work project.

    Examples:
      git-work list
    """
  end

  def run(_args) do
    with {:ok, root} <- Project.find_root() do
      bare_dir = Project.bare_path(root)

      case Git.cmd(["worktree", "list"], cd: bare_dir) do
        {:ok, output} -> {:ok, output}
        {:error, msg} -> {:error, "worktree list failed: #{msg}"}
      end
    end
  end
end
