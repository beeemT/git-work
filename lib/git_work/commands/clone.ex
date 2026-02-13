defmodule GitWork.Commands.Clone do
  @moduledoc """
  Clone a repository into the worktree-based layout.
  """

  alias GitWork.{Git, Project}

  def help do
    """
    usage: git-work clone <url> [<directory>]

    Clone a repository into the worktree-based layout.

    Creates a bare clone in <directory>/.bare, writes a .git pointer file,
    and sets up the initial worktree for the HEAD branch (usually main).

    If <directory> is omitted, it is derived from the URL (same as git clone).

    Examples:
      git-work clone git@github.com:org/repo.git
      git-work clone https://github.com/org/repo.git my-project
    """
  end

  def run(args) do
    case args do
      [url] ->
        dir = Project.dir_from_url(url)
        do_clone(url, dir)

      [url, dir] ->
        do_clone(url, dir)

      _ ->
        {:error, "usage: git-work clone <url> [<directory>]"}
    end
  end

  defp do_clone(url, dir) do
    dir = Path.expand(dir)
    bare_dir = Path.join(dir, ".bare")

    if File.exists?(dir) do
      {:error, "directory '#{dir}' already exists"}
    else
      with :ok <- clone_bare(url, bare_dir),
           :ok <- write_gitdir_pointer(dir),
           {:ok, branch} <- detect_head_branch(bare_dir),
           :ok <- fix_head(bare_dir, branch),
           :ok <- add_main_worktree(dir, branch),
           :ok <- configure_bare(bare_dir),
           :ok <- fetch_refs(bare_dir) do
        {:ok, Path.join(dir, branch)}
      end
    end
  end

  defp clone_bare(url, bare_dir) do
    case Git.cmd(["clone", "--bare", url, bare_dir]) do
      {:ok, _} -> :ok
      {:error, msg} -> {:error, "clone failed: #{msg}"}
    end
  end

  defp write_gitdir_pointer(dir) do
    File.write(Path.join(dir, ".git"), "gitdir: ./.bare\n")
  end

  defp configure_bare(bare_dir) do
    with {:ok, _} <- Git.cmd(["config", "core.bare", "true"], cd: bare_dir),
         {:ok, _} <-
           Git.cmd(
             ["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"],
             cd: bare_dir
           ) do
      :ok
    end
  end

  defp fetch_refs(bare_dir) do
    case Git.cmd(["fetch", "--all"], cd: bare_dir) do
      {:ok, _} -> :ok
      {:error, msg} -> {:error, "fetch failed: #{msg}"}
    end
  end

  defp fix_head(bare_dir, branch) do
    # Ensure HEAD points to the actual branch (bare clones from repos where
    # the default branch differs from the server's HEAD may have a stale ref)
    case Git.cmd(["symbolic-ref", "HEAD", "refs/heads/#{branch}"], cd: bare_dir) do
      {:ok, _} -> :ok
      {:error, msg} -> {:error, "failed to set HEAD: #{msg}"}
    end
  end

  defp detect_head_branch(bare_dir) do
    head =
      case Git.cmd(["symbolic-ref", "--short", "HEAD"], cd: bare_dir) do
        {:ok, branch} -> branch
        {:error, _} -> nil
      end

    # Verify the HEAD branch actually exists as a real ref
    if head && branch_exists?(bare_dir, head) do
      {:ok, head}
    else
      # HEAD points to a nonexistent branch — find the first real branch
      case Git.cmd(["branch", "--list", "--format=%(refname:short)"], cd: bare_dir) do
        {:ok, output} ->
          case output |> String.split("\n", trim: true) |> List.first() do
            nil -> {:ok, "main"}
            branch -> {:ok, branch}
          end

        {:error, _} ->
          {:ok, "main"}
      end
    end
  end

  defp branch_exists?(bare_dir, branch) do
    case Git.cmd(["show-ref", "--verify", "refs/heads/#{branch}"], cd: bare_dir) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp add_main_worktree(dir, branch) do
    worktree_dir = Path.join(dir, branch)

    case Git.cmd(["worktree", "add", worktree_dir, branch], cd: Path.join(dir, ".bare")) do
      {:ok, _} -> :ok
      {:error, msg} -> {:error, "worktree add failed: #{msg}"}
    end
  end
end
