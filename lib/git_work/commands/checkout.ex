defmodule GitWork.Commands.Checkout do
  @moduledoc """
  Switch to a branch worktree, or create a new one with -b.
  Supports fuzzy matching against existing worktrees.
  """

  alias GitWork.{Git, Project, Fuzzy, Hooks}

  def help do
    """
    usage: git-work checkout <branch>
           git-work checkout -
           git-work checkout -b <branch> [<base>]

    Switch to a branch by navigating to its worktree directory.

    Without -b, matches an existing worktree (exact or fuzzy) and prints its
    path. If no worktree matches but a remote branch with that exact name
    exists, a new worktree is automatically created tracking the remote branch.
    Returns an error only if neither a worktree nor a remote branch is found.

    With -b, creates a new worktree for the given branch. An optional <base>
    ref sets the starting point; if omitted, the current worktree's HEAD is
    used (falling back to the default branch when run from the project root).
    Returns an error if a worktree for that branch already exists.

    Supports fuzzy matching against existing worktrees:
      - Substring: 'login' matches 'feature-login'
      - Typos: 'featur-login' matches 'feature-login'
      - Ambiguous matches exit non-zero and list candidates

    Must be run from within a git-work project (any worktree or the root).

    Examples:
      git-work checkout feature-login    # switch to existing worktree
      git-work checkout -                # switch to previous branch
      git-work checkout login            # fuzzy match existing worktree
      git-work checkout feature/remote   # auto-create from remote branch
      git-work checkout -b feature/new              # new worktree from current HEAD
      git-work checkout -b feature/new origin/main  # new worktree based on origin/main
    """
  end

  def run(args, _format) do
    case args do
      ["-b", branch] ->
        with {:ok, root} <- Project.find_root() do
          source = current_worktree(root, File.cwd!())
          base = resolve_default_base(root, source)

          do_create(root, branch, base)
          |> track_checkout(root, source)
        end

      ["-"] ->
        with {:ok, root} <- Project.find_root(),
             {:ok, branch} <- previous_worktree(root) do
          source = current_worktree(root, File.cwd!())

          do_checkout(root, branch)
          |> track_checkout(root, source)
        end

      [branch] ->
        with {:ok, root} <- Project.find_root() do
          source = current_worktree(root, File.cwd!())

          do_checkout(root, branch)
          |> track_checkout(root, source)
        end

      ["-b", branch, base] ->
        with {:ok, root} <- Project.find_root() do
          source = current_worktree(root, File.cwd!())

          if branch_exists?(root, branch) do
            {:error,
             "branch '#{branch}' already exists; omit base ref '#{base}' to check it out"}
          else
            do_create(root, branch, base)
            |> track_checkout(root, source)
          end
        end

      _ ->
        {:error, "usage: git-work checkout [-b] <branch> [<base>]"}
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

  defp previous_worktree(root) do
    case config_get(root, "git-work.last-worktree") do
      nil ->
        {:error, "no previous worktree found"}

      name ->
        if name in Project.worktree_dirs(root) do
          {:ok, name}
        else
          {:error, "previous worktree '#{name}' no longer exists"}
        end
    end
  end

  defp current_worktree(root, cwd) do
    root = Path.expand(root)
    cwd = Path.expand(cwd)
    prefix = root <> "/"

    cond do
      cwd == root ->
        nil

      String.starts_with?(cwd, prefix) ->
        relative = String.replace_prefix(cwd, prefix, "")
        [name | _] = String.split(relative, "/")

        if name in Project.worktree_dirs(root) do
          name
        else
          nil
        end

      true ->
        nil
    end
  end

  defp track_checkout({:ok, path} = result, root, source) do
    target = Path.basename(path)
    source = source || config_get(root, "git-work.current-worktree")

    if source != target do
      config_set(root, "git-work.last-worktree", source)
      config_set(root, "git-work.current-worktree", target)
    end

    result
  end

  defp track_checkout(result, _root, _source), do: result

  defp config_get(root, key) do
    bare_dir = Project.bare_path(root)

    case Git.cmd(["config", "--get", key], cd: bare_dir) do
      {:ok, ""} -> nil
      {:ok, value} -> value
      {:error, _} -> nil
    end
  end

  defp config_set(_root, _key, nil), do: :ok

  defp config_set(root, key, value) do
    bare_dir = Project.bare_path(root)

    case Git.cmd(["config", key, value], cd: bare_dir) do
      {:ok, _} ->
        :ok

      {:error, msg} ->
        IO.write(:stderr, "warning: failed to persist checkout state: #{msg}\n")
        :ok
    end
  end

  defp do_create(root, input, base) do
    existing = Project.worktree_dirs(root)
    sanitized = Project.sanitize_branch(input)

    if sanitized in existing do
      {:error, "worktree '#{sanitized}' already exists"}
    else
      create_worktree(root, input, sanitized, base)
    end
  end

  defp create_worktree(root, branch, dir_name, base \\ nil) do
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
            # Brand new branch — append base when provided; nil lets git use bare HEAD
            git_cmd = ["worktree", "add", "-b", branch, worktree_dir]
            git_cmd = if base, do: git_cmd ++ [base], else: git_cmd

            case Git.cmd(git_cmd, cd: bare_dir) do
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

  # Returns the HEAD SHA of the given worktree to use as the default base for
  # a new branch. Returns nil when source is nil (running from the project root
  # or outside a worktree), which causes git to fall back to the bare repo HEAD
  # (the default branch, typically main).
  defp resolve_default_base(_root, nil), do: nil

  defp resolve_default_base(root, source) do
    case Git.cmd(["rev-parse", "HEAD"], cd: Path.join(root, source)) do
      {:ok, sha} -> sha
      {:error, _} -> nil
    end
  end

  # Returns true when a branch already exists locally or on origin. Used to
  # guard against silently ignoring an explicit base ref: if the branch exists,
  # git would check it out and ignore the base — error instead.
  defp branch_exists?(root, branch) do
    bare_dir = Project.bare_path(root)

    remote =
      case Git.cmd(["branch", "-r", "--list", "origin/#{branch}"], cd: bare_dir) do
        {:ok, ""} -> false
        {:ok, _} -> true
        {:error, _} -> false
      end

    local =
      case Git.cmd(["show-ref", "--verify", "refs/heads/#{branch}"], cd: bare_dir) do
        {:ok, _} -> true
        {:error, _} -> false
      end

    remote || local
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
