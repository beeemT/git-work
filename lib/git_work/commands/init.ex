defmodule GitWork.Commands.Init do
  @moduledoc """
  Convert an existing normal git repository into the worktree-based layout.
  """

  alias GitWork.{Git, Hooks, Project}

  def help do
    """
    usage: git-work init [--force]

    Convert the current git repository into the worktree-based layout.

    Run this from inside a normal git repo (with a .git/ directory).
    The command will:
      1. Move .git/ to .bare/
      2. Write a .git pointer file
      3. Move working files into a subdirectory named after the current branch
      4. Set up worktree linkage so git recognizes the layout

    Uncommitted changes are stashed and restored automatically.

    If the repository is already initialized (`.bare/` exists), this command
    runs a repair pass that verifies and fixes the git-work metadata,
    resets a stale index, and ensures the worktree is properly registered.
    Use --force to bypass the guard when `.git/` exists as a directory
    (e.g. corrupt state) or when re-registering a missing worktree
    (this is potentially destructive — it removes the worktree directory
    and recreates it from the committed state).

    Examples:
      cd ~/projects/my-repo && git-work init
      git-work init --force  # repair even with corrupt .git/
    """
  end

  def run(args, _format) do
    force? = "--force" in args
    cwd = File.cwd!()
    do_init(cwd, force?)
  end

  defp do_init(dir, force?) do
    git_dir = Path.join(dir, ".git")
    bare_dir = Path.join(dir, ".bare")

    cond do
      File.dir?(bare_dir) ->
        do_repair(dir, git_dir, bare_dir, force?)

      not File.dir?(git_dir) ->
        {:error, "not a git repository (no .git/ directory)"}

      true ->
        with {:ok, branch} <- current_branch(dir),
             {:ok, stashed?} <- stash_changes(dir) do
          # Capture trust before move_files_to_worktree relocates .mise.toml
          was_trusted = Hooks.source_trusted?(dir)

          case do_init_steps(dir, branch, stashed?, git_dir, bare_dir) do
            :ok ->
              worktree_dir = Path.join(dir, branch)
              maybe_propagate_trust(dir, worktree_dir, was_trusted)
              {:ok, worktree_dir}

            {:error, msg} ->
              rollback_init(dir, branch, stashed?)
              {:error, msg}
          end
        else
          {:error, msg} -> {:error, msg}
        end
    end
  end

  # do_init_steps chains all the steps for a fresh init, including
  # reset_worktree_index and ensure_upstream. do_repair chains the subset
  # that is safe to re-run on an already-initialized repo (some steps
  # like move_git_to_bare are not idempotent). We intentionally do NOT
  # stash/pop here — repair is a read-only correction of metadata; the user
  # can stash manually before running init if they have dirty files.
  defp do_repair(dir, git_dir, bare_dir, force?) do
    with :ok <- ensure_gitdir_pointer(dir, git_dir, force?),
         :ok <- Project.configure_bare(bare_dir),
         {:ok, branch} <- Project.head_branch(dir),
         :ok <- ensure_worktree_dir(dir, branch),
         :ok <- validate_and_fix_worktree_registration(dir, branch, bare_dir, force?),
         :ok <- reset_worktree_index(dir, branch),
         :ok <- Project.ensure_upstream(Path.join(dir, branch), branch) do
      {:ok, Project.worktree_path(dir, branch)}
    end
  end

  # Check whether the worktree is registered in the bare repo. If not,
  # require --force to re-register (which is destructive) or return an error.
  defp validate_and_fix_worktree_registration(dir, branch, bare_dir, force?) do
    worktree_dir = Path.join(dir, branch)
    needle = "worktree " <> worktree_dir

    case Git.cmd(["worktree", "list", "--porcelain"], cd: bare_dir) do
      {:ok, output} ->
        if String.contains?(output, needle) do
          :ok
        else
          if force? do
            # Worktree not registered — first validate that git will accept
            # the path, then clean up broken metadata and worktree directory,
            # then recreate. This is destructive; validation prevents
            # permanently losing user work if git rejects the path.
            case validate_worktree_path(worktree_dir, bare_dir) do
              :ok ->
                worktree_meta = Path.join([bare_dir, "worktrees", branch])
                _ = File.rm_rf(worktree_meta)
                _ = File.rm_rf(worktree_dir)

                case Git.cmd(["worktree", "add", worktree_dir, branch], cd: bare_dir) do
                  {:ok, _} -> :ok
                  {:error, msg} -> {:error, "failed to re-register worktree: #{msg}"}
                end

              {:error, reason} ->
                {:error, "cannot re-register worktree: #{reason}"}
            end
          else
            {:error, "worktree is not registered; use --force to re-register (this will remove the worktree directory)"}
          end
        end

      {:error, msg} ->
        {:error, "failed to list worktrees: #{msg}"}
    end
  end

  defp ensure_gitdir_pointer(dir, git_dir, force?) do
    cond do
      File.dir?(git_dir) and not force? ->
        {:error, "found .git directory; not a git-work root"}

      File.dir?(git_dir) and force? ->
        # .git exists as a directory but --force was given — write the pointer
        # to a temp file first, then atomically replace .git so we never leave
        # the repo in a broken state if the write fails.
        _ = File.rm_rf!(git_dir)
        write_gitdir_pointer!(dir)

      File.regular?(git_dir) ->
        case File.read(git_dir) do
          {:ok, "gitdir: ./.bare\n"} ->
            :ok

          {:ok, _} ->
            write_gitdir_pointer(dir)

          {:error, reason} ->
            {:error, "failed to read .git pointer: #{reason}"}
        end

      true ->
        write_gitdir_pointer(dir)
    end
  end

  defp ensure_worktree_dir(dir, branch) do
    worktree_dir = Project.worktree_path(dir, branch)

    if File.dir?(worktree_dir) do
      :ok
    else
      bare_dir = Project.bare_path(dir)

      case Git.cmd(["worktree", "add", worktree_dir, branch], cd: bare_dir) do
        {:ok, _} ->
          :ok

        {:error, _msg} ->
          _ = Git.cmd(["worktree", "prune"], cd: bare_dir)

          case Git.cmd(["worktree", "add", worktree_dir, branch], cd: bare_dir) do
            {:ok, _} -> :ok
            {:error, msg2} -> {:error, "failed to recreate worktree: #{msg2}"}
          end
      end
    end
  end

  # Validate that git will accept the worktree path before we delete any user data.
  # git worktree add refuses paths that are already registered worktrees, and paths
  # that contain a nested git repo (a .git directory, not a .git file). We check
  # for those preconditions here so we never delete user data if git would refuse.
  defp validate_worktree_path(worktree_dir, bare_dir) do
    nested_git = Path.join(worktree_dir, ".git")

    if File.dir?(nested_git) do
      {:error, "path contains a nested .git directory"}
    else
      case Git.cmd(["worktree", "list", "--porcelain"], cd: bare_dir) do
        {:ok, output} ->
          if String.contains?(output, "worktree " <> worktree_dir) do
            {:error, "path is already a registered worktree"}
          else
            :ok
          end

        {:error, _} ->
          :ok
      end
    end
  end

  defp do_init_steps(dir, branch, stashed?, git_dir, bare_dir) do
    with :ok <- move_git_to_bare(git_dir, bare_dir),
         :ok <- Project.configure_bare(bare_dir),
         :ok <- move_files_to_worktree(dir, branch),
         :ok <- setup_worktree_linkage(dir, branch),
         :ok <- write_gitdir_pointer(dir),
         :ok <- reset_worktree_index(dir, branch),
         :ok <- Project.ensure_upstream(Path.join(dir, branch), branch),
         :ok <- validate_init(dir, branch, bare_dir),
         :ok <- maybe_pop_stash(dir, branch, stashed?) do
      :ok
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
    case write_gitdir_pointer!(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_gitdir_pointer!(dir) do
    git_path = Path.join(dir, ".git")
    tmp_path = Path.join(dir, ".git.tmp.#{:os.getpid()}")

    with :ok <- File.write(tmp_path, "gitdir: ./.bare\n"),
         :ok <- File.rename(tmp_path, git_path) do
      :ok
    else
      {:error, reason} ->
        # Clean up the temp file if rename didn't happen
        _ = File.rm(tmp_path)
        {:error, "failed to write .git pointer: #{reason}"}
    end
  end

  defp move_files_to_worktree(dir, branch) do
    worktree_dir = Path.join(dir, branch)

    with :ok <- File.mkdir(worktree_dir),
         {:ok, entries} <- File.ls(dir) do
      entries
      |> Enum.reject(&(&1 in [".bare", ".git", branch]))
      |> Enum.reduce_while(:ok, fn entry, :ok ->
        src = Path.join(dir, entry)
        dst = Path.join(worktree_dir, entry)

        case File.rename(src, dst) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, "failed to move '#{entry}': #{reason}"}}
        end
      end)
    else
      {:error, reason} ->
        {:error, "failed to create worktree directory: #{reason}"}
    end
  end

  defp setup_worktree_linkage(dir, branch) do
    bare_dir = Path.join(dir, ".bare")
    worktree_dir = Path.join(dir, branch)
    worktree_meta = Path.join([bare_dir, "worktrees", branch])

    with :ok <- mkdir_p(worktree_meta),
         :ok <-
           write_file(Path.join(worktree_meta, "gitdir"), Path.join(worktree_dir, ".git") <> "\n"),
         :ok <- write_file(Path.join(worktree_meta, "commondir"), "../../\n"),
         :ok <- write_file(Path.join(worktree_meta, "HEAD"), "ref: refs/heads/#{branch}\n"),
         :ok <- write_file(Path.join(worktree_dir, ".git"), "gitdir: #{worktree_meta}\n") do
      :ok
    end
  end

  defp mkdir_p(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, "failed to create directory '#{path}': #{reason}"}
    end
  end

  defp write_file(path, content) do
    case File.write(path, content) do
      :ok -> :ok
      {:error, reason} -> {:error, "failed to write '#{path}': #{reason}"}
    end
  end

  # Restore the worktree to a clean state: first reset the index to HEAD
  # (clearing any stale "deleted" entries from the index), then restore
  # working tree files from the clean index. This handles the case where
  # files were deleted from the worktree and git status showed them as deleted.
  defp reset_worktree_index(dir, branch) do
    worktree_dir = Path.join(dir, branch)

    with :ok <- reset_index(worktree_dir),
         :ok <- checkout_index(worktree_dir) do
      :ok
    end
  end

  defp reset_index(worktree_dir) do
    case Git.cmd(["reset", "HEAD"], cd: worktree_dir) do
      {:ok, _} -> :ok
      {:error, msg} -> {:error, "failed to reset worktree index: #{msg}"}
    end
  end

  defp checkout_index(worktree_dir) do
    case Git.cmd(["checkout-index", "-a", "-f"], cd: worktree_dir) do
      {:ok, _} -> :ok
      {:error, msg} -> {:error, "failed to restore worktree files: #{msg}"}
    end
  end


  defp validate_init(dir, branch, bare_dir) do
    worktree_dir = Path.join(dir, branch)

    with {:ok, "true"} <- Git.cmd(["rev-parse", "--is-inside-work-tree"], cd: worktree_dir),
         {:ok, output} <- Git.cmd(["worktree", "list", "--porcelain"], cd: bare_dir),
         true <- String.contains?(output, "worktree " <> worktree_dir) do
      :ok
    else
      {:error, msg} -> {:error, "init verification failed: #{msg}"}
      _ -> {:error, "init verification failed: worktree not registered"}
    end
  end

  defp rollback_init(dir, branch, stashed?) do
    bare_dir = Path.join(dir, ".bare")
    git_dir = Path.join(dir, ".git")
    worktree_dir = if branch, do: Path.join(dir, branch), else: nil

    if worktree_dir && File.dir?(worktree_dir) do
      move_result =
        case File.ls(worktree_dir) do
          {:ok, entries} ->
            entries
            |> Enum.reject(&(&1 == ".git"))
            |> Enum.reduce(:ok, fn entry, acc ->
              src = Path.join(worktree_dir, entry)
              dst = Path.join(dir, entry)

              case File.rename(src, dst) do
                :ok -> acc
                {:error, _} -> :error
              end
            end)

          {:error, _} ->
            :error
        end

      if move_result == :ok do
        _ = File.rm_rf(worktree_dir)
      else
        IO.write(:stderr, "warning: rollback incomplete (worktree left at #{worktree_dir})\n")
      end
    end

    if File.regular?(git_dir) do
      _ = File.rm(git_dir)
    end

    if File.dir?(bare_dir) do
      if branch do
        _ = File.rm_rf(Path.join([bare_dir, "worktrees", branch]))
      end

      case File.rename(bare_dir, git_dir) do
        :ok -> :ok
        {:error, reason} -> IO.write(:stderr, "warning: failed to restore .git: #{reason}\n")
      end
    end

    if stashed? do
      case Git.cmd(["stash", "pop"], cd: dir) do
        {:ok, _} ->
          :ok

        {:error, msg} ->
          IO.write(:stderr, "warning: failed to pop stash after rollback: #{msg}\n")
      end
    end

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

  # Non-fatal: a failure to propagate trust is a warning, not a reason to
  # undo an otherwise successful init. The user can always run `mise trust`
  # manually inside the new worktree.
  defp maybe_propagate_trust(root, worktree_dir, was_trusted) do
    ctx = %{root: root, worktree_dir: worktree_dir, was_trusted: was_trusted}

    case Hooks.run(:post_init, ctx) do
      :ok ->
        :ok

      {:error, msg} ->
        IO.write(:stderr, "warning: #{msg}\n")
        :ok
    end
  end
end
