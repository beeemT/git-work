defmodule GitWork.Commands.Sync do
  @moduledoc """
  Fetch from remote and prune worktrees whose remote tracking branch is gone.
  """

  alias GitWork.{Git, Project}

  def help do
    """
    usage: git-work sync [--dry-run] [--force]

    Fetch from remote and prune stale worktrees.

    Runs 'git fetch --all --prune', then removes any local worktrees whose
    remote tracking branch no longer exists. The HEAD branch is never pruned.

    Options:
      -n, --dry-run    Show what would be pruned without removing
      -f, --force      Use 'git branch -D' for branches with unmerged changes

    Examples:
      git-work sync              # fetch and prune stale worktrees
      git-work sync --dry-run    # preview what would be pruned
      git-work sync --force      # force-delete unmerged branches too
    """
  end

  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [dry_run: :boolean, force: :boolean],
        aliases: [n: :dry_run, f: :force]
      )

    dry_run? = Keyword.get(opts, :dry_run, false)
    force? = Keyword.get(opts, :force, false)

    with {:ok, root} <- Project.find_root() do
      do_sync(root, dry_run?, force?)
    end
  end

  defp do_sync(root, dry_run?, force?) do
    bare_dir = Project.bare_path(root)

    # Fetch and prune remote refs
    IO.write(:stderr, "fetching...\n")

    case Git.cmd(["fetch", "--all", "--prune"], cd: bare_dir) do
      {:ok, _} -> :ok
      {:error, msg} -> IO.write(:stderr, "warning: fetch failed: #{msg}\n")
    end

    # Get HEAD branch to protect it
    head_branch =
      case Project.head_branch(root) do
        {:ok, h} -> h
        _ -> "main"
      end

    # Parse worktree list
    worktrees = parse_worktrees(bare_dir)

    # Find stale worktrees
    stale =
      worktrees
      |> Enum.filter(fn {branch, _path} ->
        branch != head_branch and branch != nil and remote_gone?(bare_dir, branch)
      end)

    if stale == [] do
      IO.write(:stderr, "nothing to prune\n")
      {:ok, ""}
    else
      if dry_run? do
        IO.write(:stderr, "would prune:\n")

        Enum.each(stale, fn {branch, _path} ->
          IO.write(:stderr, "  #{branch}\n")
        end)

        {:ok, ""}
      else
        prune_worktrees(bare_dir, stale, force?)
      end
    end
  end

  defp parse_worktrees(bare_dir) do
    case Git.cmd(["worktree", "list", "--porcelain"], cd: bare_dir) do
      {:ok, output} ->
        output
        |> String.split("\n\n", trim: true)
        |> Enum.flat_map(fn block ->
          lines = String.split(block, "\n", trim: true)

          path =
            Enum.find_value(lines, fn
              "worktree " <> p -> p
              _ -> nil
            end)

          branch =
            Enum.find_value(lines, fn
              "branch refs/heads/" <> b -> b
              _ -> nil
            end)

          if path && branch, do: [{branch, path}], else: []
        end)

      {:error, _} ->
        []
    end
  end

  defp remote_gone?(bare_dir, branch) do
    case Git.cmd(["branch", "-r", "--list", "origin/#{branch}"], cd: bare_dir) do
      {:ok, ""} -> true
      {:ok, _} -> false
      {:error, _} -> false
    end
  end

  defp prune_worktrees(bare_dir, stale, force?) do
    {pruned, failed} =
      Enum.reduce(stale, {0, 0}, fn {branch, path}, {p, f} ->
        remove_args =
          if force?,
            do: ["worktree", "remove", "--force", path],
            else: ["worktree", "remove", path]

        case Git.cmd(remove_args, cd: bare_dir) do
          {:ok, _} ->
            delete_flag = if force?, do: "-D", else: "-d"

            case Git.cmd(["branch", delete_flag, branch], cd: bare_dir) do
              {:ok, _} ->
                :ok

              {:error, msg} ->
                IO.write(:stderr, "warning: branch '#{branch}' not deleted: #{msg}\n")
            end

            {p + 1, f}

          {:error, msg} ->
            IO.write(:stderr, "warning: could not remove '#{branch}': #{msg}\n")
            {p, f + 1}
        end
      end)

    # Clean up any stale metadata
    Git.cmd(["worktree", "prune"], cd: bare_dir)

    IO.write(:stderr, "pruned #{pruned} worktree(s)")

    if failed > 0 do
      IO.write(:stderr, ", #{failed} failed")
    end

    IO.write(:stderr, "\n")

    {:ok, ""}
  end
end
