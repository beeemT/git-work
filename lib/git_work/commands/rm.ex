defmodule GitWork.Commands.Rm do
  @moduledoc """
  Remove a worktree and optionally delete its branch.
  """

  alias GitWork.{Git, Project}

  def help do
    """
    usage: git-work rm [--force] <branch>

    Remove a worktree and delete its branch.

    Removes the worktree directory and runs 'git branch -d' to delete the
    branch. Refuses to remove the HEAD branch (usually main) unless --force
    is given.

    If you are inside the worktree being removed, the command prints the
    path to the HEAD branch worktree so the shell wrapper can cd there.

    Options:
      --force    Use 'git branch -D' and allow removing the HEAD branch

    Examples:
      git-work rm feature-login
      git-work rm --force old-branch
    """
  end

  def run(args) do
    {opts, rest, _} = OptionParser.parse(args, strict: [force: :boolean])
    force? = Keyword.get(opts, :force, false)

    case rest do
      [branch] ->
        with {:ok, root} <- Project.find_root() do
          do_rm(root, branch, force?)
        end

      _ ->
        {:error, "usage: git-work rm [--force] <branch>"}
    end
  end

  defp do_rm(root, branch, force?) do
    dir_name = Project.sanitize_branch(branch)
    worktree_dir = Path.join(root, dir_name)
    bare_dir = Project.bare_path(root)

    # Check if this is the HEAD branch
    case Project.head_branch(root) do
      {:ok, head} when head == branch ->
        if force? do
          remove_worktree(root, branch, worktree_dir, bare_dir, force?)
        else
          {:error, "refusing to remove HEAD branch '#{branch}' (use --force)"}
        end

      _ ->
        remove_worktree(root, branch, worktree_dir, bare_dir, force?)
    end
  end

  defp remove_worktree(root, branch, worktree_dir, bare_dir, force?) do
    if not File.dir?(worktree_dir) do
      {:error, "worktree '#{branch}' does not exist"}
    else
      # Check if user is inside the worktree being removed
      cwd = File.cwd!()
      inside? = String.starts_with?(Path.expand(cwd), Path.expand(worktree_dir))

      # Move process CWD out of the worktree before removing it,
      # otherwise Erlang's open_port fails with :enoent after deletion.
      if inside?, do: File.cd!(root)

      remove_args =
        if force?,
          do: ["worktree", "remove", "--force", worktree_dir],
          else: ["worktree", "remove", worktree_dir]

      with {:ok, _} <- Git.cmd(remove_args, cd: bare_dir),
           :ok <- delete_branch(bare_dir, branch, force?) do
        if inside? do
          # Return path to HEAD branch so shell wrapper can cd there
          case Project.head_branch(root) do
            {:ok, head} ->
              IO.write(:stderr, "removed '#{branch}', switching to '#{head}'\n")
              {:ok, Project.worktree_path(root, head)}

            _ ->
              {:ok, root}
          end
        else
          IO.write(:stderr, "removed '#{branch}'\n")
          {:ok, ""}
        end
      end
    end
  end

  defp delete_branch(bare_dir, branch, force?) do
    flag = if force?, do: "-D", else: "-d"

    case Git.cmd(["branch", flag, branch], cd: bare_dir) do
      {:ok, _} ->
        :ok

      {:error, msg} ->
        IO.write(:stderr, "warning: could not delete branch '#{branch}': #{msg}\n")
        :ok
    end
  end
end
