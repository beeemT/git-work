defmodule GitWork.Commands.Init do
  @moduledoc """
  Convert an existing normal git repository into the worktree-based layout.
  """

  alias GitWork.{Git, Project}

  def help do
    """
    usage: git-work init

    Convert the current git repository into the worktree-based layout.

    Run this from inside a normal git repo (with a .git/ directory).
    The command will:
      1. Move .git/ to .bare/
      2. Write a .git pointer file
      3. Move working files into a subdirectory named after the current branch
      4. Set up worktree linkage so git recognizes the layout

    Uncommitted changes are stashed and restored automatically.

    Examples:
      cd ~/projects/my-repo && git-work init
    """
  end

  def run(_args) do
    cwd = File.cwd!()
    do_init(cwd)
  end

  defp do_init(dir) do
    git_dir = Path.join(dir, ".git")
    bare_dir = Path.join(dir, ".bare")

    cond do
      File.dir?(bare_dir) ->
        {:error, "already initialized (found .bare/)"}

      not File.dir?(git_dir) ->
        {:error, "not a git repository (no .git/ directory)"}

      true ->
        with {:ok, branch} <- current_branch(dir),
             {:ok, stashed?} <- stash_changes(dir),
             :ok <- move_git_to_bare(git_dir, bare_dir),
             :ok <- write_gitdir_pointer(dir),
             :ok <- configure_bare(bare_dir),
             :ok <- move_files_to_worktree(dir, branch),
             :ok <- setup_worktree_linkage(dir, branch),
             :ok <- maybe_pop_stash(dir, branch, stashed?) do
          {:ok, Path.join(dir, branch)}
        else
          {:error, msg} -> {:error, msg}
        end
    end
  end

  defp current_branch(dir) do
    case Git.cmd(["rev-parse", "--abbrev-ref", "HEAD"], cd: dir) do
      {:ok, branch} -> {:ok, branch}
      {:error, _} -> {:error, "could not determine current branch"}
    end
  end

  defp stash_changes(dir) do
    case Git.cmd(["status", "--porcelain"], cd: dir) do
      {:ok, ""} ->
        {:ok, false}

      {:ok, _changes} ->
        case Git.cmd(["stash", "push", "-m", "git-work init"], cd: dir) do
          {:ok, _} -> {:ok, true}
          {:error, msg} -> {:error, "failed to stash changes: #{msg}"}
        end

      {:error, msg} ->
        {:error, "git status failed: #{msg}"}
    end
  end

  defp move_git_to_bare(git_dir, bare_dir) do
    case File.rename(git_dir, bare_dir) do
      :ok -> :ok
      {:error, reason} -> {:error, "failed to move .git to .bare: #{reason}"}
    end
  end

  defp write_gitdir_pointer(dir) do
    case File.write(Path.join(dir, ".git"), "gitdir: ./.bare\n") do
      :ok -> :ok
      {:error, reason} -> {:error, "failed to write .git pointer: #{reason}"}
    end
  end

  defp configure_bare(bare_dir) do
    with {:ok, _} <- Git.cmd(["config", "core.bare", "false"], cd: bare_dir) do
      # Only set fetch refspec if remote origin exists
      case Git.cmd(["remote", "get-url", "origin"], cd: bare_dir) do
        {:ok, _} ->
          Git.cmd(
            ["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"],
            cd: bare_dir
          )
          |> case do
            {:ok, _} -> :ok
            {:error, msg} -> {:error, "failed to configure fetch: #{msg}"}
          end

        {:error, _} ->
          IO.write(:stderr, "warning: no remote 'origin' configured\n")
          :ok
      end
    end
  end

  defp move_files_to_worktree(dir, branch) do
    worktree_dir = Path.join(dir, branch)

    case File.mkdir(worktree_dir) do
      :ok ->
        entries = File.ls!(dir)

        Enum.each(entries, fn entry ->
          if entry not in [".bare", ".git", branch] do
            src = Path.join(dir, entry)
            dst = Path.join(worktree_dir, entry)
            File.rename!(src, dst)
          end
        end)

        :ok

      {:error, reason} ->
        {:error, "failed to create worktree directory: #{reason}"}
    end
  end

  defp setup_worktree_linkage(dir, branch) do
    bare_dir = Project.bare_path(dir)
    worktree_dir = Path.join(dir, branch)
    worktree_meta = Path.join([bare_dir, "worktrees", branch])

    # Create worktree metadata directory
    File.mkdir_p!(worktree_meta)

    # Write the gitdir file pointing from bare to worktree
    File.write!(Path.join(worktree_meta, "gitdir"), Path.join(worktree_dir, ".git") <> "\n")

    # Write commondir for the worktree to find the bare repo
    File.write!(Path.join(worktree_meta, "commondir"), "../../\n")

    # Write HEAD for the worktree
    File.write!(Path.join(worktree_meta, "HEAD"), "ref: refs/heads/#{branch}\n")

    # Write .git file in worktree pointing to bare's worktrees/<branch>
    File.write!(Path.join(worktree_dir, ".git"), "gitdir: #{worktree_meta}\n")

    :ok
  end

  defp maybe_pop_stash(dir, branch, true) do
    worktree_dir = Path.join(dir, branch)

    case Git.cmd(["stash", "pop"], cd: worktree_dir) do
      {:ok, _} ->
        :ok

      {:error, msg} ->
        IO.write(:stderr, "warning: failed to pop stash: #{msg}\n")
        :ok
    end
  end

  defp maybe_pop_stash(_dir, _branch, false), do: :ok
end
