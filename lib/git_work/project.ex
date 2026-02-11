defmodule GitWork.Project do
  @moduledoc """
  Project root discovery, path helpers, and branch name sanitization.
  """

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
end
