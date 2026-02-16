defmodule GitWork.Commands.Rm do
  @moduledoc """
  Remove a worktree and optionally delete its branch.
  """

  alias GitWork.{Git, Project, Fuzzy}

  def help do
    """
    usage: git-work rm [--force] [--yes] <branch>

    Remove a worktree and delete its branch with confirmation.

    Removes the worktree directory and runs 'git branch -d' to delete the
    branch. Refuses to remove the HEAD branch (usually main) unless --force
    is given. The branch argument supports fuzzy matching against existing
    worktree directories.

    If you are inside the worktree being removed, the command prints the
    path to the HEAD branch worktree so the shell wrapper can cd there.

    Options:
      --force    Use 'git branch -D' and allow removing the HEAD branch
      --yes      Skip confirmation prompt

    Examples:
      git-work rm feature-login
      git-work rm login
      git-work rm --yes feature-login
      git-work rm --force old-branch
    """
  end

  def run(args) do
    {opts, rest, _} = OptionParser.parse(args, strict: [force: :boolean, yes: :boolean])
    force? = Keyword.get(opts, :force, false)
    yes? = Keyword.get(opts, :yes, false)

    case rest do
      [input] ->
        with {:ok, root} <- Project.find_root(),
             {:ok, target} <- resolve_target(root, input) do
          do_rm(root, target, force?, yes?)
        end

      _ ->
        {:error, "usage: git-work rm [--force] [--yes] <branch>"}
    end
  end

  defp do_rm(root, %{branch: branch, dir_name: dir_name} = target, force?, yes?) do
    worktree_dir = Path.join(root, dir_name)
    bare_dir = Project.bare_path(root)

    # Check if this is the HEAD branch
    case Project.head_branch(root) do
      {:ok, head} when head == branch ->
        if force? do
          with :ok <- maybe_confirm(target, yes?) do
            remove_worktree(root, branch, dir_name, worktree_dir, bare_dir, force?)
          end
        else
          {:error, "refusing to remove HEAD branch '#{branch}' (use --force)"}
        end

      _ ->
        with :ok <- maybe_confirm(target, yes?) do
          remove_worktree(root, branch, dir_name, worktree_dir, bare_dir, force?)
        end
    end
  end

  defp resolve_target(root, input) do
    with {:ok, worktrees} <- worktree_entries(root) do
      candidates = Enum.map(worktrees, & &1.dir_name)
      sanitized = Project.sanitize_branch(input)

      case Fuzzy.match(sanitized, candidates) do
        {:exact, dir_name} ->
          select_worktree(worktrees, dir_name)

        {:match, dir_name} ->
          IO.write(:stderr, "fuzzy match: '#{input}' -> '#{dir_name}'\n")
          select_worktree(worktrees, dir_name)

        {:ambiguous, candidates} ->
          formatted = Enum.map_join(candidates, "\n", &"  #{&1}")
          {:error, "ambiguous match for '#{input}':\n#{formatted}"}

        :no_match ->
          {:error, "worktree '#{input}' does not exist"}
      end
    end
  end

  defp worktree_entries(root) do
    bare_dir = Project.bare_path(root)

    case Git.cmd(["worktree", "list", "--porcelain"], cd: bare_dir) do
      {:ok, output} ->
        entries =
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

            if path && branch do
              [%{dir_name: Path.basename(path), branch: branch}]
            else
              []
            end
          end)

        {:ok, entries}

      {:error, msg} ->
        {:error, "worktree list failed: #{msg}"}
    end
  end

  defp select_worktree(worktrees, dir_name) do
    case Enum.find(worktrees, &(&1.dir_name == dir_name)) do
      %{branch: branch} -> {:ok, %{dir_name: dir_name, branch: branch}}
      nil -> {:error, "worktree '#{dir_name}' does not exist"}
    end
  end

  defp maybe_confirm(_target, true), do: :ok

  defp maybe_confirm(%{dir_name: dir_name, branch: branch}, false) do
    label =
      if dir_name == branch do
        "'#{branch}'"
      else
        "'#{dir_name}' (branch '#{branch}')"
      end

    IO.write(:stderr, "delete worktree #{label}? [y/N]: ")

    case IO.gets("") do
      input when is_binary(input) ->
        case input |> String.trim() |> String.downcase() do
          "y" -> :ok
          "yes" -> :ok
          _ -> {:error, "aborted"}
        end

      _ ->
        {:error, "aborted"}
    end
  end

  defp remove_worktree(root, branch, dir_name, worktree_dir, bare_dir, force?) do
    if not File.dir?(worktree_dir) do
      {:error, "worktree '#{dir_name}' does not exist"}
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
