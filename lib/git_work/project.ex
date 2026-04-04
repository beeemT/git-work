defmodule GitWork.Project do
  @moduledoc """
  Project root discovery, path helpers, branch name sanitization,
  and shared configuration for bare repos and worktrees.
  """

  alias GitWork.Git

  @doc """
  Find the project root by walking up from `start_dir` looking for `.bare/`.
  Returns {:ok, path} or {:error, message}.
  """
  def find_root(start_dir \\ File.cwd!()) do
    find_root_up(Path.expand(start_dir))
  end

  defp find_root_up("/"), do: {:error, "not a git-work project (no .bare/ found)"}

  defp find_root_up(dir) do
    if File.dir?(Path.join(dir, ".bare")) do
      {:ok, dir}
    else
      find_root_up(Path.dirname(dir))
    end
  end

  @doc """
  Sanitize a branch name into a valid directory name.
  Replaces `/` with `-`.
  """
  def sanitize_branch(name) do
    String.replace(name, "/", "-")
  end

  @doc """
  Return the absolute path to a worktree directory for a given branch.
  """
  def worktree_path(project_root, branch) do
    Path.join(project_root, sanitize_branch(branch))
  end

  @doc """
  Return the path to the bare repo.
  """
  def bare_path(project_root) do
    Path.join(project_root, ".bare")
  end

  @doc """
  List existing worktree directory names (not full paths) in the project root.
  Excludes `.bare`, `.git`, and hidden files.
  """
  def worktree_dirs(project_root) do
    project_root
    |> File.ls!()
    |> Enum.filter(fn entry ->
      full_path = Path.join(project_root, entry)
      File.dir?(full_path) and not String.starts_with?(entry, ".")
    end)
  end

  @doc """
  Derive a directory name from a clone URL, same logic as `git clone`.
  """
  def dir_from_url(url) do
    url
    |> String.split("/")
    |> List.last()
    |> String.replace_suffix(".git", "")
    |> String.replace_suffix("/", "")
  end

  @doc """
  Determine the HEAD branch of the bare repo (usually main or master).
  """
  def head_branch(project_root) do
    case GitWork.Git.cmd(["symbolic-ref", "--short", "HEAD"], cd: bare_path(project_root)) do
      {:ok, branch} -> {:ok, branch}
      {:error, _} -> {:error, "could not determine HEAD branch"}
    end
  end

  @doc """
  Configure the bare repo: mark as bare, enable push.autoSetupRemote,
  and set the fetch refspec for origin (if origin exists).
  """
  def configure_bare(bare_dir) do
    with {:ok, _} <- Git.cmd(["config", "core.bare", "true"], cd: bare_dir),
         {:ok, _} <- Git.cmd(["config", "push.autoSetupRemote", "true"], cd: bare_dir) do
      # Only set fetch refspec if remote origin exists
      case Git.cmd(["remote", "get-url", "origin"], cd: bare_dir) do
        {:ok, _} ->
          case Git.cmd(
                 ["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"],
                 cd: bare_dir
               ) do
            {:ok, _} -> :ok
            {:error, msg} -> {:error, "failed to configure fetch: #{msg}"}
          end

        {:error, _} ->
          IO.write(:stderr, "warning: no remote 'origin' configured\n")
          :ok
      end
    end
  end

  @doc """
  Set upstream tracking for a branch if its remote counterpart exists.
  No-ops when the branch has no remote ref (e.g. brand-new, not yet pushed).
  """
  def ensure_upstream(worktree_dir, branch) do
    case Git.cmd(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
           cd: worktree_dir
         ) do
      {:ok, _} ->
        # Already has upstream tracking
        :ok

      {:error, _} ->
        case Git.cmd(["show-ref", "--verify", "--quiet", "refs/remotes/origin/#{branch}"],
               cd: worktree_dir
             ) do
          {:ok, _} ->
            case Git.cmd(["branch", "--set-upstream-to=origin/#{branch}", branch],
                   cd: worktree_dir
                 ) do
              {:ok, _} ->
                :ok

              {:error, msg} ->
                IO.write(:stderr, "warning: failed to set upstream for #{branch}: #{msg}\n")
                :ok
            end

          {:error, _} ->
            # No remote ref — nothing to track (will be set on first push via autoSetupRemote)
            :ok
        end
    end
  end
end
