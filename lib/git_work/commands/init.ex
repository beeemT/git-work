defmodule GitWork.Commands.Init do
  @moduledoc """
  Convert an existing normal git repository into the worktree-based layout.
  """

  alias GitWork.{Git, Hooks, Output, Project}

  @gitdir_pointer "gitdir: ./.bare\n"
  @regenerated_metadata_entries ~w(HEAD commondir gitdir)
  @in_progress_metadata_entries ~w(
    AUTO_MERGE
    BISECT_ANCESTORS_OK
    BISECT_EXPECTED_REV
    BISECT_LOG
    BISECT_NAMES
    BISECT_RUN
    BISECT_START
    BISECT_TERMS
    CHERRY_PICK_HEAD
    MERGE_HEAD
    MERGE_MODE
    MERGE_MSG
    MERGE_RR
    REBASE_HEAD
    REVERT_HEAD
    SQUASH_MSG
    locked
    rebase-apply
    rebase-merge
    sequencer
  )

  def help do
    """
    usage: git-work init [--force]

    Convert the current git repository into the worktree-based layout.

    Run this from inside a normal git repo (with a .git/ directory).
    The command will:
      1. Move .git/ to .bare/
      2. Write a .git pointer file
      3. Move working files into a subdirectory for the current branch
      4. Register that directory as a Git worktree

    Tracked changes are stashed and restored automatically. Untracked and
    ignored files are moved directly into the new worktree.

    If the repository is already initialized (`.bare/` exists), this command
    validates and repairs git-work metadata without resetting the index or
    overwriting worktree files. Use --force to rebuild missing worktree
    registration. Existing worktree content is moved to a sibling backup
    during that operation and restored if registration fails.

    Examples:
      cd ~/projects/my-repo && git-work init
      git-work init --force  # repair corrupt metadata without discarding files
    """
  end

  def run([], _format), do: do_init(File.cwd!(), false)
  def run(["--force"], _format), do: do_init(File.cwd!(), true)

  def run(_args, _format) do
    {:error, "usage: git-work init [--force]"}
  end

  defp do_init(dir, force?) do
    git_dir = Path.join(dir, ".git")
    bare_dir = Project.bare_path(dir)

    case path_kind(bare_dir) do
      :directory ->
        do_repair(dir, git_dir, bare_dir, force?)

      :missing ->
        case path_kind(git_dir) do
          :directory ->
            do_fresh_init(dir, git_dir, bare_dir)

          :missing ->
            {:error, "not a git repository (no .git/ directory)"}

          {:other, type} ->
            {:error, "not a git repository (.git is #{type}, not a directory)"}

          {:error, reason} ->
            {:error, "failed to inspect .git path '#{git_dir}': #{reason}"}
        end

      {:other, type} ->
        {:error, "repository metadata path '#{bare_dir}' is #{type}, not a directory"}

      {:error, reason} ->
        {:error, "failed to inspect repository metadata path '#{bare_dir}': #{reason}"}
    end
  end

  defp do_fresh_init(dir, git_dir, bare_dir) do
    with {:ok, branch} <- current_branch(dir),
         :ok <- ensure_fresh_worktree_path_available(dir, branch),
         {:ok, config_snapshot} <- capture_config(git_dir),
         worktree_dir = Project.worktree_path(dir, branch),
         {:ok, backup_dir} <- unique_sibling_backup(worktree_dir, "init-backup") do
      # Trust must be captured while .mise.toml is still at the source path and
      # before stashing can replace a tracked, locally-modified copy.
      was_trusted = Hooks.source_trusted?(dir)

      with {:ok, stash} <- stash_changes(dir) do
        case do_init_steps(dir, branch, git_dir, bare_dir, worktree_dir, backup_dir) do
          :ok ->
            case restore_stash(worktree_dir, stash) do
              :ok ->
                maybe_propagate_trust(dir, worktree_dir, was_trusted)
                {:ok, worktree_dir}

              {:error, message} ->
                {:error,
                 "#{message}. The git-work layout is valid at #{worktree_dir}, and the " <>
                   "created stash was preserved; resolve any partial application there and " <>
                   "re-apply that exact stash if needed"}
            end

          {:error, message} ->
            case rollback_init(dir, branch, backup_dir, config_snapshot, stash) do
              :ok ->
                {:error, message}

              {:error, rollback_message} ->
                {:error, "#{message}; rollback incomplete: #{rollback_message}"}
            end
        end
      end
    end
  end

  # Repair is transactional across the root pointer, shared configuration, and
  # any registration migration. Each mutating registration path returns an undo
  # record that stays live until upstream setup and final validation succeed.
  defp do_repair(dir, git_dir, bare_dir, force?) do
    with {:ok, branch} <- Project.head_branch(dir),
         :ok <- preflight_forced_repair_ownership(dir, branch, bare_dir, force?),
         {:ok, config_snapshot} <- capture_config(bare_dir),
         {:ok, root_snapshot} <- capture_root_git_snapshot(git_dir) do
      case ensure_gitdir_pointer(dir, git_dir, force?) do
        {:ok, pointer_state} ->
          case Project.configure_bare(bare_dir) do
            :ok ->
              continue_repair(
                dir,
                branch,
                bare_dir,
                force?,
                git_dir,
                root_snapshot,
                config_snapshot,
                pointer_state
              )

            {:error, message} ->
              repair_failure(
                message,
                git_dir,
                bare_dir,
                root_snapshot,
                config_snapshot,
                pointer_state,
                nil
              )
          end

        {:error, message} ->
          {:error, message}
      end
    end
  end

  defp continue_repair(
         dir,
         branch,
         bare_dir,
         force?,
         git_dir,
         root_snapshot,
         config_snapshot,
         pointer_state
       ) do
    case ensure_worktree_registration(dir, branch, bare_dir, force?) do
      {:ok, registration_state} ->
        worktree_dir = Project.worktree_path(dir, branch)

        case Project.ensure_upstream(worktree_dir, branch) do
          :ok ->
            case validate_init(dir, branch, bare_dir) do
              :ok ->
                commit_repair_registration(registration_state)
                {:ok, worktree_dir}

              {:error, message} ->
                repair_failure(
                  message,
                  git_dir,
                  bare_dir,
                  root_snapshot,
                  config_snapshot,
                  pointer_state,
                  registration_state
                )
            end

          {:error, message} ->
            repair_failure(
              message,
              git_dir,
              bare_dir,
              root_snapshot,
              config_snapshot,
              pointer_state,
              registration_state
            )
        end

      {:error, message} ->
        repair_failure(
          message,
          git_dir,
          bare_dir,
          root_snapshot,
          config_snapshot,
          pointer_state,
          nil
        )
    end
  end

  defp repair_failure(
         message,
         git_dir,
         bare_dir,
         root_snapshot,
         config_snapshot,
         pointer_state,
         registration_state
       ) do
    case rollback_repair(
           git_dir,
           bare_dir,
           root_snapshot,
           config_snapshot,
           pointer_state,
           registration_state
         ) do
      :ok ->
        {:error, message}

      {:error, rollback_message} ->
        {:error, "#{message}; rollback incomplete: #{rollback_message}"}
    end
  end

  defp capture_root_git_snapshot(git_dir) do
    case File.lstat(git_dir) do
      {:error, :enoent} ->
        {:ok, :missing}

      {:ok, %File.Stat{type: :regular}} ->
        case File.read(git_dir) do
          {:ok, content} -> {:ok, {:regular, content}}
          {:error, reason} -> {:error, "failed to capture .git pointer: #{reason}"}
        end

      {:ok, %File.Stat{type: :directory}} ->
        {:ok, :directory}

      {:ok, %File.Stat{type: type}} ->
        {:error, "refusing to repair unexpected .git #{type}"}

      {:error, reason} ->
        {:error, "failed to inspect .git path '#{git_dir}': #{reason}"}
    end
  end

  defp commit_repair_registration(nil), do: :ok

  defp commit_repair_registration({:repaired, state}) do
    cleanup_repair_backup(state.metadata_backup)
    :ok
  end

  defp commit_repair_registration({:created, _worktree_dir, _bare_dir}), do: :ok

  defp commit_repair_registration(
         {:recreated_missing, _worktree_dir, _bare_dir, _metadata_dir, metadata_backup}
       ) do
    retain_metadata_backup(metadata_backup)
  end

  defp commit_repair_registration(
         {:reregistered, _worktree_dir, worktree_backup, _bare_dir, _old_metadata_dir,
          metadata_backup}
       ) do
    cleanup_reregistration_backups(worktree_backup, metadata_backup)
    :ok
  end

  defp rollback_repair(
         git_dir,
         bare_dir,
         root_snapshot,
         config_snapshot,
         pointer_state,
         registration_state
       ) do
    registration_result = rollback_registration(registration_state)
    config_result = restore_config_snapshot(bare_dir, config_snapshot)
    root_result = rollback_root_git(git_dir, root_snapshot, pointer_state)

    combine_rollback_results(
      registration_result,
      combine_rollback_results(config_result, root_result)
    )
  end

  defp rollback_registration(nil), do: :ok

  defp rollback_registration({:created, worktree_dir, bare_dir}) do
    discard_generated_worktree(worktree_dir, bare_dir)
  end

  defp rollback_registration(
         {:recreated_missing, worktree_dir, bare_dir, metadata_dir, metadata_backup}
       ) do
    rollback_missing_worktree(worktree_dir, bare_dir, metadata_dir, metadata_backup)
  end

  defp rollback_registration({:repaired, repair_state}) do
    rollback_repaired_state(repair_state)
  end

  defp rollback_registration(
         {:reregistered, worktree_dir, worktree_backup, bare_dir, old_metadata_dir,
          metadata_backup}
       ) do
    rollback_reregistration(
      worktree_dir,
      worktree_backup,
      bare_dir,
      old_metadata_dir,
      metadata_backup
    )
  end

  defp rollback_root_git(_git_dir, _root_snapshot, :unchanged), do: :ok

  defp rollback_root_git(git_dir, _root_snapshot, {:replaced_directory, backup_dir}) do
    with :ok <- remove_generated_root_pointer(git_dir) do
      case File.rename(backup_dir, git_dir) do
        :ok -> :ok
        {:error, reason} -> {:error, "failed to restore original .git directory: #{reason}"}
      end
    end
  end

  defp rollback_root_git(git_dir, root_snapshot, _pointer_state) do
    restore_root_git_snapshot(git_dir, root_snapshot)
  end

  defp restore_root_git_snapshot(git_dir, root_snapshot) do
    with :ok <- remove_generated_root_pointer(git_dir) do
      case root_snapshot do
        :missing ->
          :ok

        {:regular, content} ->
          case File.write(git_dir, content) do
            :ok -> :ok
            {:error, reason} -> {:error, "failed to restore original .git pointer: #{reason}"}
          end

        :directory ->
          {:error, "original .git directory cannot be restored from a file snapshot"}
      end
    end
  end

  defp remove_generated_root_pointer(git_dir) do
    case File.lstat(git_dir) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :regular}} ->
        case File.read(git_dir) do
          {:ok, @gitdir_pointer} ->
            case File.rm(git_dir) do
              :ok -> :ok
              {:error, reason} -> {:error, "failed to remove generated .git pointer: #{reason}"}
            end

          {:ok, _other} ->
            {:error, "refusing to remove an unexpected .git file during rollback"}

          {:error, reason} ->
            {:error, "failed to inspect .git during rollback: #{reason}"}
        end

      {:ok, %File.Stat{type: type}} ->
        {:error, "refusing to replace unexpected .git #{type} during rollback"}

      {:error, reason} ->
        {:error, "failed to inspect .git during rollback: #{reason}"}
    end
  end

  defp validate_forced_worktree_identity(worktree_dir, branch, bare_dir) do
    with {:ok, records} <- worktree_records(bare_dir),
         :ok <- validate_registration_records(records, worktree_dir, branch),
         {:ok, pointer_metadata_dir} <- validate_reregistration_source(worktree_dir, bare_dir),
         {:ok, registered_metadata_dir} <-
           optional_metadata_dir_for_worktree(bare_dir, worktree_dir),
         {:ok, metadata_dir} <-
           reconcile_metadata_sources(pointer_metadata_dir, registered_metadata_dir) do
      cond do
        is_nil(metadata_dir) ->
          {:error,
           "refusing to re-register '#{worktree_dir}': existing files are not proven to belong to this repository"}

        true ->
          validate_old_metadata_for_migration(metadata_dir, branch, bare_dir)
      end
    end
  end

  defp preflight_forced_repair_ownership(_dir, _branch, _bare_dir, false), do: :ok

  defp preflight_forced_repair_ownership(dir, branch, bare_dir, true) do
    worktree_dir = Project.worktree_path(dir, branch)

    case path_kind(worktree_dir) do
      :missing ->
        :ok

      :directory ->
        validate_forced_worktree_identity(worktree_dir, branch, bare_dir)

      {:other, type} ->
        {:error, "worktree path is not a directory (#{type}): #{worktree_dir}"}

      {:error, reason} ->
        {:error, "failed to inspect worktree path '#{worktree_dir}': #{reason}"}
    end
  end

  defp ensure_fresh_worktree_path_available(dir, branch) do
    worktree_dir = Project.worktree_path(dir, branch)

    case File.lstat(worktree_dir) do
      {:error, :enoent} ->
        case worktree_records(dir) do
          {:ok, records} ->
            case record_for_path(records, worktree_dir) do
              nil ->
                :ok

              %{branch: nil} ->
                {:error,
                 "failed to create worktree directory: path is already registered at #{worktree_dir}"}

              %{branch: registered_branch} ->
                {:error,
                 "failed to create worktree directory: path is already registered for #{registered_branch} at #{worktree_dir}"}
            end

          {:error, message} ->
            {:error, message}
        end

      {:ok, _stat} ->
        {:error, "failed to create worktree directory: path already exists at #{worktree_dir}"}

      {:error, reason} ->
        {:error, "failed to inspect worktree directory '#{worktree_dir}': #{reason}"}
    end
  end

  defp validate_root_git_directory_ownership(dir) do
    bare_dir = Project.bare_path(dir)

    case Git.cmd(["rev-parse", "--git-common-dir"], cd: dir) do
      {:ok, common_dir} ->
        if resolve_git_path(common_dir, dir) == normalize_path(bare_dir) do
          :ok
        else
          {:error,
           "refusing to replace .git directory that is not proven to belong to '#{bare_dir}'"}
        end

      {:error, message} ->
        {:error,
         "refusing to replace .git directory whose repository identity cannot be verified: #{message}"}
    end
  end

  defp ensure_gitdir_pointer(dir, git_dir, force?) do
    case path_kind(git_dir) do
      :directory when not force? ->
        {:error, "found .git directory; not a git-work root"}

      :directory ->
        with :ok <- validate_root_git_directory_ownership(dir) do
          replace_git_directory_with_pointer(dir, git_dir)
        end

      :missing ->
        case write_gitdir_pointer(dir) do
          :ok -> {:ok, :created}
          {:error, _} = error -> error
        end

      {:other, :regular} ->
        case File.read(git_dir) do
          {:ok, @gitdir_pointer} ->
            {:ok, :unchanged}

          {:ok, content} ->
            case repair_root_git_pointer(dir, content) do
              :ok -> {:ok, :rewritten}
              {:error, _} = error -> error
            end

          {:error, reason} ->
            {:error, "failed to read .git pointer: #{reason}"}
        end

      {:other, type} ->
        {:error, "refusing to replace unexpected .git #{type}"}

      {:error, reason} ->
        {:error, "failed to inspect .git path '#{git_dir}': #{reason}"}
    end
  end

  defp repair_root_git_pointer(dir, content) do
    bare_dir = Project.bare_path(dir)

    case parse_gitdir_pointer(content) do
      {:ok, gitdir_path} ->
        resolved = resolve_git_path(gitdir_path, dir)

        case directories_same?(resolved, bare_dir) do
          {:ok, true} ->
            write_gitdir_pointer(dir)

          {:ok, false} ->
            {:error, "refusing to replace .git pointer owned by another repository"}

          {:error, message} ->
            {:error, "cannot verify existing .git pointer ownership: #{message}"}
        end

      {:error, _malformed} ->
        {:error, "refusing to replace malformed .git pointer; original contents were preserved"}
    end
  end

  defp replace_git_directory_with_pointer(dir, git_dir) do
    with {:ok, backup_dir} <- unique_sibling_backup(git_dir, "metadata-backup") do
      case File.rename(git_dir, backup_dir) do
        :ok ->
          case write_gitdir_pointer(dir) do
            :ok ->
              Output.notify(
                :warning,
                "preserved replaced .git directory at #{backup_dir}; remove it after verification"
              )

              {:ok, {:replaced_directory, backup_dir}}

            {:error, message} ->
              _ = remove_generated_root_pointer(Path.join(dir, ".git"))

              case File.rename(backup_dir, git_dir) do
                :ok ->
                  {:error, message}

                {:error, reason} ->
                  {:error,
                   "#{message}; failed to restore original .git directory from #{backup_dir}: #{reason}"}
              end
          end

        {:error, reason} ->
          {:error, "failed to preserve existing .git directory: #{reason}"}
      end
    end
  end

  defp ensure_worktree_registration(dir, branch, bare_dir, force?) do
    worktree_dir = Project.worktree_path(dir, branch)

    with {:ok, records} <- worktree_records(bare_dir),
         :ok <- validate_registration_records(records, worktree_dir, branch) do
      target_record = record_for_path(records, worktree_dir)

      case path_kind(worktree_dir) do
        :missing ->
          if target_record do
            recreate_missing_registered_worktree(worktree_dir, branch, bare_dir)
          else
            add_missing_worktree(worktree_dir, branch, bare_dir)
          end

        :directory ->
          repair_existing_worktree(worktree_dir, branch, bare_dir, target_record, force?)

        {:other, type} ->
          {:error, "worktree path is not a directory (#{type}): #{worktree_dir}"}

        {:error, reason} ->
          {:error, "failed to inspect worktree path '#{worktree_dir}': #{reason}"}
      end
    end
  end

  defp repair_existing_worktree(_worktree_dir, _branch, _bare_dir, nil, false) do
    {:error,
     "worktree is not registered; use --force to rebuild registration without discarding files"}
  end

  defp repair_existing_worktree(worktree_dir, branch, bare_dir, nil, true) do
    force_reregister_worktree(worktree_dir, branch, bare_dir)
  end

  defp repair_existing_worktree(worktree_dir, branch, bare_dir, _record, force?) do
    case validate_worktree_access(worktree_dir, bare_dir) do
      :ok ->
        {:ok, nil}

      {:error, first_error} ->
        with :ok <- validate_repair_source_ownership(worktree_dir, bare_dir),
             :ok <- preflight_forced_repair_source(worktree_dir, branch, bare_dir, force?),
             {:ok, repair_state} <- prepare_repair_snapshot(worktree_dir, branch, bare_dir) do
          repair_result = Git.cmd(["worktree", "repair", "--", worktree_dir], cd: bare_dir)

          case validate_worktree_access(worktree_dir, bare_dir) do
            :ok ->
              {:ok, {:repaired, repair_state}}

            {:error, _second_error} when force? ->
              repair_detail =
                case repair_result do
                  {:ok, _output} -> first_error
                  {:error, message} -> "#{first_error}; git worktree repair failed: #{message}"
                end

              case rollback_repaired_state(repair_state) do
                :ok ->
                  force_reregister_worktree(worktree_dir, branch, bare_dir)

                {:error, rollback_message} ->
                  {:error, "#{repair_detail}; rollback incomplete: #{rollback_message}"}
              end

            {:error, second_error} ->
              repair_detail =
                case repair_result do
                  {:ok, _output} -> second_error
                  {:error, message} -> "#{first_error}; git worktree repair failed: #{message}"
                end

              case rollback_repaired_state(repair_state) do
                :ok ->
                  {:error,
                   "registered worktree metadata is invalid (#{repair_detail}); use --force to rebuild it"}

                {:error, rollback_message} ->
                  {:error,
                   "registered worktree metadata is invalid (#{repair_detail}); rollback incomplete: #{rollback_message}"}
              end
          end
        end
    end
  end

  defp prepare_repair_snapshot(worktree_dir, branch, bare_dir) do
    with {:ok, pointer_snapshot} <- capture_worktree_git_snapshot(worktree_dir),
         {:ok, metadata_dir} <- repair_metadata_dir(worktree_dir, bare_dir) do
      case metadata_dir do
        nil ->
          {:error,
           "cannot safely snapshot registered worktree metadata; use --force to rebuild it"}

        metadata_dir when is_binary(metadata_dir) ->
          with :ok <- validate_old_metadata_for_migration(metadata_dir, branch, bare_dir),
               {:ok, metadata_backup} <- backup_metadata_directory(metadata_dir, bare_dir) do
            {:ok,
             %{
               worktree_dir: worktree_dir,
               metadata_dir: metadata_dir,
               metadata_backup: metadata_backup,
               pointer_snapshot: pointer_snapshot
             }}
          end
      end
    end
  end

  defp capture_worktree_git_snapshot(worktree_dir) do
    git_entry = Path.join(worktree_dir, ".git")

    case File.lstat(git_entry) do
      {:error, :enoent} ->
        {:ok, :missing}

      {:ok, %File.Stat{type: :regular}} ->
        case File.read(git_entry) do
          {:ok, content} -> {:ok, {:regular, content}}
          {:error, reason} -> {:error, "failed to capture worktree .git pointer: #{reason}"}
        end

      {:ok, %File.Stat{type: type}} ->
        {:error, "refusing to repair worktree .git #{type}"}

      {:error, reason} ->
        {:error, "failed to inspect worktree .git pointer: #{reason}"}
    end
  end

  defp repair_metadata_dir(worktree_dir, bare_dir) do
    with {:ok, pointer_metadata_dir} <- validate_reregistration_source(worktree_dir, bare_dir),
         {:ok, registered_metadata_dir} <-
           optional_metadata_dir_for_worktree(bare_dir, worktree_dir),
         {:ok, metadata_dir} <-
           reconcile_metadata_sources(pointer_metadata_dir, registered_metadata_dir) do
      {:ok, metadata_dir}
    end
  end

  defp backup_metadata_directory(nil, _bare_dir), do: {:ok, nil}

  defp backup_metadata_directory(metadata_dir, bare_dir) do
    with {:ok, metadata_backup} <-
           unique_child_path(bare_dir, ".git-work-repair-metadata-backup"),
         :ok <- make_directory(metadata_backup) do
      case copy_metadata_tree(metadata_dir, metadata_backup) do
        :ok ->
          {:ok, metadata_backup}

        {:error, reason} ->
          _ = remove_path(metadata_backup)
          {:error, "failed to preserve worktree metadata for repair: #{reason}"}
      end
    else
      {:error, reason} ->
        {:error, "failed to preserve worktree metadata for repair: #{reason}"}
    end
  end

  defp copy_metadata_tree(source_metadata, destination_metadata) do
    case File.ls(source_metadata) do
      {:ok, entries} ->
        Enum.reduce_while(entries, :ok, fn entry, :ok ->
          source = Path.join(source_metadata, entry)
          destination = Path.join(destination_metadata, entry)

          case copy_metadata_entry(source, destination, entry) do
            :ok -> {:cont, :ok}
            {:error, message} -> {:halt, {:error, message}}
          end
        end)

      {:error, reason} ->
        {:error, "failed to inspect worktree metadata: #{reason}"}
    end
  end

  defp rollback_repaired_state(state) do
    metadata_result =
      restore_metadata_snapshot(state.metadata_dir, state.metadata_backup)

    pointer_result =
      restore_worktree_git_snapshot(state.worktree_dir, state.pointer_snapshot)

    combine_rollback_results(metadata_result, pointer_result)
  end

  defp restore_metadata_snapshot(nil, nil), do: :ok

  defp restore_metadata_snapshot(metadata_dir, metadata_backup) do
    with :ok <- remove_path(metadata_dir),
         :ok <- rename_backup(metadata_backup, metadata_dir) do
      :ok
    end
  end

  defp restore_worktree_git_snapshot(worktree_dir, snapshot) do
    git_entry = Path.join(worktree_dir, ".git")

    with :ok <- remove_generated_worktree_pointer(git_entry) do
      case snapshot do
        :missing ->
          :ok

        {:regular, content} ->
          case File.write(git_entry, content) do
            :ok ->
              :ok

            {:error, reason} ->
              {:error, "failed to restore original worktree .git pointer: #{reason}"}
          end
      end
    end
  end

  defp remove_generated_worktree_pointer(git_entry) do
    case File.lstat(git_entry) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :regular}} ->
        case File.rm(git_entry) do
          :ok ->
            :ok

          {:error, reason} ->
            {:error, "failed to remove repaired worktree .git pointer: #{reason}"}
        end

      {:ok, %File.Stat{type: type}} ->
        {:error, "refusing to replace unexpected worktree .git #{type}"}

      {:error, reason} ->
        {:error, "failed to inspect worktree .git during rollback: #{reason}"}
    end
  end

  defp cleanup_repair_backup(nil), do: :ok

  defp cleanup_repair_backup(metadata_backup) do
    case remove_path(metadata_backup) do
      :ok ->
        :ok

      {:error, message} ->
        Output.notify(
          :warning,
          "preserved repair metadata backup at #{metadata_backup}: #{message}"
        )

        :ok
    end
  end

  defp validate_repair_source_ownership(worktree_dir, bare_dir) do
    case validate_reregistration_source(worktree_dir, bare_dir) do
      {:ok, _metadata_dir} -> :ok
      {:error, message} -> {:error, message}
    end
  end

  defp preflight_forced_repair_source(_worktree_dir, _branch, _bare_dir, false), do: :ok

  defp preflight_forced_repair_source(worktree_dir, branch, bare_dir, true) do
    case preflight_reregistration(worktree_dir, branch, bare_dir) do
      {:ok, _metadata_dir} -> :ok
      {:error, message} -> {:error, message}
    end
  end

  # There is no existing directory here, so a normal checkout cannot overwrite
  # user content. Registration records were checked before this is called.
  defp add_missing_worktree(worktree_dir, branch, bare_dir) do
    with :ok <- verify_branch_exists(bare_dir, branch) do
      case Git.cmd(["worktree", "add", "--", worktree_dir, branch], cd: bare_dir) do
        {:ok, _output} ->
          case validate_created_registration(worktree_dir, branch, bare_dir) do
            :ok ->
              {:ok, {:created, worktree_dir, bare_dir}}

            {:error, reason} ->
              _ = discard_generated_worktree(worktree_dir, bare_dir)
              {:error, "failed to validate recreated worktree: #{reason}"}
          end

        {:error, message} ->
          {:error, "failed to recreate worktree: #{message}"}
      end
    end
  end

  # A missing worktree can still have staged and worktree-specific metadata
  # state. Move that metadata aside, let Git create a fresh registration, copy
  # every safely migratable entry, and retain the original metadata backup.
  defp recreate_missing_registered_worktree(worktree_dir, branch, bare_dir) do
    with :ok <- verify_branch_exists(bare_dir, branch),
         {:ok, metadata_dir} <- metadata_dir_for_worktree(bare_dir, worktree_dir),
         :ok <- validate_old_metadata_for_migration(metadata_dir, branch, bare_dir),
         {:ok, metadata_backup} <- unique_child_path(bare_dir, ".git-work-metadata-backup") do
      case File.rename(metadata_dir, metadata_backup) do
        :ok ->
          result =
            with :ok <- add_empty_worktree(worktree_dir, branch, bare_dir),
                 :ok <-
                   initialize_reregistered_index(worktree_dir, metadata_backup, bare_dir),
                 :ok <- checkout_index_into_empty_worktree(worktree_dir),
                 :ok <- validate_created_registration(worktree_dir, branch, bare_dir) do
              :ok
            end

          case result do
            :ok ->
              {:ok, {:recreated_missing, worktree_dir, bare_dir, metadata_dir, metadata_backup}}

            {:error, message} ->
              case rollback_missing_worktree(
                     worktree_dir,
                     bare_dir,
                     metadata_dir,
                     metadata_backup
                   ) do
                :ok ->
                  {:error, "failed to recreate registered worktree: #{message}"}

                {:error, rollback_message} ->
                  {:error,
                   "failed to recreate registered worktree: #{message}; rollback incomplete: #{rollback_message}"}
              end
          end

        {:error, reason} ->
          {:error, "failed to preserve stale worktree metadata: #{reason}"}
      end
    end
  end

  defp rollback_missing_worktree(worktree_dir, bare_dir, metadata_dir, metadata_backup) do
    discard_result = discard_generated_worktree(worktree_dir, bare_dir)
    restore_result = restore_old_metadata(metadata_dir, metadata_backup)

    combine_rollback_results(discard_result, restore_result)
  end

  defp force_reregister_worktree(worktree_dir, branch, bare_dir) do
    with {:ok, old_metadata_dir} <- preflight_reregistration(worktree_dir, branch, bare_dir),
         {:ok, worktree_backup} <- unique_sibling_backup(worktree_dir, "registration-backup"),
         {:ok, metadata_backup} <- metadata_backup_path(bare_dir, old_metadata_dir) do
      case File.rename(worktree_dir, worktree_backup) do
        :ok ->
          case preserve_old_metadata(old_metadata_dir, metadata_backup) do
            :ok ->
              finish_reregistration(
                worktree_dir,
                worktree_backup,
                branch,
                bare_dir,
                old_metadata_dir,
                metadata_backup
              )

            {:error, message} ->
              case File.rename(worktree_backup, worktree_dir) do
                :ok ->
                  {:error, message}

                {:error, reason} ->
                  {:error,
                   "#{message}; worktree files remain preserved at #{worktree_backup}, " <>
                     "but could not be restored: #{reason}"}
              end
          end

        {:error, reason} ->
          {:error, "failed to preserve worktree before re-registration: #{reason}"}
      end
    end
  end

  defp metadata_backup_path(_bare_dir, nil), do: {:ok, nil}

  defp metadata_backup_path(bare_dir, _metadata_dir) do
    unique_child_path(bare_dir, ".git-work-metadata-backup")
  end

  defp preflight_reregistration(worktree_dir, branch, bare_dir) do
    with {:ok, records} <- worktree_records(bare_dir),
         :ok <- validate_registration_records(records, worktree_dir, branch),
         :ok <- verify_branch_exists(bare_dir, branch),
         {:ok, pointer_metadata_dir} <-
           validate_reregistration_source(worktree_dir, bare_dir),
         {:ok, registered_metadata_dir} <-
           optional_metadata_dir_for_worktree(bare_dir, worktree_dir),
         {:ok, metadata_dir} <-
           reconcile_metadata_sources(pointer_metadata_dir, registered_metadata_dir) do
      cond do
        is_nil(metadata_dir) ->
          {:error,
           "worktree metadata could not be located or proven to belong to this repository; refusing to remove or replace files"}

        true ->
          case validate_old_metadata_for_migration(metadata_dir, branch, bare_dir) do
            :ok -> {:ok, metadata_dir}
            {:error, message} -> {:error, message}
          end
      end
    end
  end

  defp validate_reregistration_source(worktree_dir, bare_dir) do
    with {:ok, %File.Stat{type: :directory}} <- File.lstat(worktree_dir) do
      git_entry = Path.join(worktree_dir, ".git")

      case File.lstat(git_entry) do
        {:error, :enoent} ->
          {:ok, nil}

        {:ok, %File.Stat{type: :regular}} ->
          validate_worktree_git_pointer(git_entry, bare_dir)

        {:ok, %File.Stat{type: type}} ->
          {:error,
           "cannot re-register worktree: #{git_entry} is #{type}, not a metadata pointer file"}

        {:error, reason} ->
          {:error, "cannot inspect existing worktree metadata pointer: #{reason}"}
      end
    else
      {:ok, %File.Stat{type: type}} ->
        {:error, "cannot re-register non-directory worktree path (#{type})"}

      {:error, reason} ->
        {:error, "cannot inspect worktree before re-registration: #{reason}"}
    end
  end

  defp validate_worktree_git_pointer(git_entry, bare_dir) do
    case File.read(git_entry) do
      {:ok, content} ->
        with {:ok, gitdir_path} <- parse_gitdir_pointer(content),
             metadata_dir = resolve_git_path(gitdir_path, Path.dirname(git_entry)),
             :ok <- validate_linked_metadata_location(metadata_dir, bare_dir),
             :ok <- validate_metadata_ownership(metadata_dir, bare_dir) do
          {:ok, metadata_dir}
        end

      {:error, reason} ->
        {:error, "cannot read existing worktree .git pointer: #{reason}"}
    end
  end

  defp parse_gitdir_pointer(content) do
    with {:ok, line} <- parse_single_line(content, "worktree .git pointer") do
      case line do
        "gitdir: " <> path when path != "" ->
          {:ok, path}

        _other ->
          {:error,
           "cannot re-register worktree: malformed .git pointer (expected exactly 'gitdir: <path>')"}
      end
    end
  end

  defp validate_linked_metadata_location(metadata_dir, bare_dir) do
    metadata_root = Path.join(bare_dir, "worktrees")

    case File.lstat(metadata_dir) do
      {:ok, %File.Stat{type: :directory}} ->
        ensure_same_directory(
          Path.dirname(metadata_dir),
          metadata_root,
          "cannot re-register worktree: .git points outside this repository's worktree metadata"
        )

      {:ok, %File.Stat{type: type}} ->
        {:error, "cannot re-register worktree: .git points to #{type}, not a metadata directory"}

      {:error, reason} ->
        {:error,
         "cannot re-register worktree: .git metadata directory cannot be inspected: #{reason}"}
    end
  end

  defp validate_metadata_ownership(metadata_dir, bare_dir) do
    commondir_file = Path.join(metadata_dir, "commondir")

    case File.lstat(commondir_file) do
      {:ok, %File.Stat{type: :regular}} ->
        case File.read(commondir_file) do
          {:ok, content} ->
            with {:ok, common_path} <- parse_single_line(content, "worktree commondir"),
                 common_dir = resolve_git_path(common_path, metadata_dir),
                 :ok <-
                   ensure_same_directory(
                     common_dir,
                     bare_dir,
                     "cannot re-register worktree: existing .git pointer belongs to a different repository"
                   ) do
              :ok
            end

          {:error, reason} ->
            {:error, "cannot read existing worktree commondir: #{reason}"}
        end

      {:error, :enoent} ->
        {:error,
         "cannot re-register worktree: existing .git pointer has no commondir and cannot be proven to belong to this repository"}

      {:ok, %File.Stat{type: type}} ->
        {:error, "cannot re-register worktree: commondir is #{type}, not a regular metadata file"}

      {:error, reason} ->
        {:error, "cannot inspect existing worktree commondir: #{reason}"}
    end
  end

  defp reconcile_metadata_sources(nil, nil), do: {:ok, nil}
  defp reconcile_metadata_sources(metadata_dir, nil), do: {:ok, metadata_dir}
  defp reconcile_metadata_sources(nil, metadata_dir), do: {:ok, metadata_dir}

  defp reconcile_metadata_sources(pointer_metadata_dir, registered_metadata_dir) do
    case directories_same?(pointer_metadata_dir, registered_metadata_dir) do
      {:ok, true} ->
        {:ok, pointer_metadata_dir}

      {:ok, false} ->
        {:error,
         "worktree .git pointer and repository registration identify different metadata directories; refusing to move files"}

      {:error, message} ->
        {:error, "cannot reconcile existing worktree metadata: #{message}"}
    end
  end

  defp validate_old_metadata_for_migration(nil, _branch, _bare_dir), do: :ok

  defp validate_old_metadata_for_migration(metadata_dir, branch, bare_dir) do
    with :ok <- validate_linked_metadata_location(metadata_dir, bare_dir),
         :ok <- validate_metadata_ownership(metadata_dir, bare_dir),
         :ok <- validate_metadata_head(metadata_dir, branch),
         :ok <- validate_metadata_tree(metadata_dir) do
      :ok
    end
  end

  defp validate_metadata_head(metadata_dir, branch) do
    head_file = Path.join(metadata_dir, "HEAD")
    expected_head = "ref: refs/heads/#{branch}"

    case File.lstat(head_file) do
      {:ok, %File.Stat{type: :regular}} ->
        case File.read(head_file) do
          {:ok, content} ->
            case parse_single_line(content, "worktree HEAD") do
              {:ok, ^expected_head} ->
                :ok

              {:ok, _other} ->
                {:error,
                 "cannot re-register worktree: preserved metadata HEAD does not match branch #{branch}"}

              {:error, message} ->
                {:error, message}
            end

          {:error, reason} ->
            {:error, "cannot read existing worktree HEAD: #{reason}"}
        end

      {:error, :enoent} ->
        {:error, "cannot re-register worktree: existing metadata has no HEAD file"}

      {:ok, %File.Stat{type: type}} ->
        {:error, "cannot re-register worktree: metadata HEAD is #{type}, not a regular file"}

      {:error, reason} ->
        {:error, "cannot inspect existing worktree HEAD: #{reason}"}
    end
  end

  defp validate_metadata_tree(metadata_dir) do
    case File.ls(metadata_dir) do
      {:ok, entries} ->
        Enum.reduce_while(entries, :ok, fn entry, :ok ->
          case validate_metadata_tree_entry(metadata_dir, entry) do
            :ok -> {:cont, :ok}
            {:error, message} -> {:halt, {:error, message}}
          end
        end)

      {:error, reason} ->
        {:error, "cannot inspect existing worktree metadata: #{reason}"}
    end
  end

  defp validate_metadata_tree_entry(metadata_dir, relative_path) do
    path = Path.join(metadata_dir, relative_path)

    cond do
      unsafe_metadata_state?(relative_path) ->
        {:error,
         "cannot re-register worktree while in-progress or locked metadata state '#{relative_path}' is present; finish or abort that operation first"}

      true ->
        case File.lstat(path) do
          {:ok, %File.Stat{type: :regular}} ->
            :ok

          {:ok, %File.Stat{type: :directory}} ->
            case File.ls(path) do
              {:ok, entries} ->
                Enum.reduce_while(entries, :ok, fn entry, :ok ->
                  child = Path.join(relative_path, entry)

                  case validate_metadata_tree_entry(metadata_dir, child) do
                    :ok -> {:cont, :ok}
                    {:error, message} -> {:halt, {:error, message}}
                  end
                end)

              {:error, reason} ->
                {:error, "cannot inspect metadata directory '#{relative_path}': #{reason}"}
            end

          {:ok, %File.Stat{type: type}} ->
            {:error,
             "cannot faithfully migrate metadata entry '#{relative_path}' because it is #{type}"}

          {:error, reason} ->
            {:error, "cannot inspect metadata entry '#{relative_path}': #{reason}"}
        end
    end
  end

  defp unsafe_metadata_state?(relative_path) do
    parts = Path.split(relative_path)
    top_level = List.first(parts)
    basename = Path.basename(relative_path)

    top_level in @in_progress_metadata_entries or
      String.ends_with?(basename, ".lock") or
      bisect_metadata_path?(parts)
  end

  defp bisect_metadata_path?(["refs", "bisect" | _rest]), do: true
  defp bisect_metadata_path?(["logs", "refs", "bisect" | _rest]), do: true
  defp bisect_metadata_path?(_parts), do: false

  defp parse_single_line(content, description) do
    line = strip_single_line_ending(content)

    cond do
      not String.valid?(line) ->
        {:error, "cannot re-register worktree: #{description} is not valid text"}

      line == "" ->
        {:error, "cannot re-register worktree: #{description} is empty"}

      String.contains?(line, ["\n", "\r", <<0>>]) ->
        {:error, "cannot re-register worktree: #{description} contains extra or invalid data"}

      true ->
        {:ok, line}
    end
  end

  defp strip_single_line_ending(content) do
    size = byte_size(content)

    cond do
      String.ends_with?(content, "\r\n") -> binary_part(content, 0, size - 2)
      String.ends_with?(content, "\n") -> binary_part(content, 0, size - 1)
      true -> content
    end
  end

  defp ensure_same_directory(actual, expected, mismatch_message) do
    case directories_same?(actual, expected) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, mismatch_message}
      {:error, message} -> {:error, "#{mismatch_message}; #{message}"}
    end
  end

  defp directories_same?(left, right) do
    with {:ok, left_stat} <- stat_directory(left),
         {:ok, right_stat} <- stat_directory(right) do
      same_expanded_path? = normalize_path(left) == normalize_path(right)

      same_file_identity? =
        left_stat.inode != 0 and
          left_stat.inode == right_stat.inode and
          left_stat.major_device == right_stat.major_device and
          left_stat.minor_device == right_stat.minor_device

      {:ok, same_expanded_path? or same_file_identity?}
    end
  end

  defp stat_directory(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        {:ok, stat}

      {:ok, %File.Stat{type: type}} ->
        {:error, "'#{path}' is #{type}, not a directory"}

      {:error, reason} ->
        {:error, "cannot inspect directory '#{path}': #{reason}"}
    end
  end

  defp preserve_old_metadata(nil, nil), do: :ok

  defp preserve_old_metadata(metadata_dir, metadata_backup) do
    case File.rename(metadata_dir, metadata_backup) do
      :ok -> :ok
      {:error, reason} -> {:error, "failed to preserve existing worktree metadata: #{reason}"}
    end
  end

  defp finish_reregistration(
         worktree_dir,
         worktree_backup,
         branch,
         bare_dir,
         old_metadata_dir,
         metadata_backup
       ) do
    result =
      with :ok <- add_empty_worktree(worktree_dir, branch, bare_dir),
           :ok <- initialize_reregistered_index(worktree_dir, metadata_backup, bare_dir),
           :ok <- move_entries(worktree_backup, worktree_dir, [".git"]),
           :ok <- validate_created_registration(worktree_dir, branch, bare_dir) do
        :ok
      end

    case result do
      :ok ->
        {:ok,
         {:reregistered, worktree_dir, worktree_backup, bare_dir, old_metadata_dir,
          metadata_backup}}

      {:error, message} ->
        case rollback_reregistration(
               worktree_dir,
               worktree_backup,
               bare_dir,
               old_metadata_dir,
               metadata_backup
             ) do
          :ok ->
            {:error, "failed to re-register worktree: #{message}"}

          {:error, rollback_message} ->
            {:error,
             "failed to re-register worktree: #{message}; rollback incomplete: #{rollback_message}"}
        end
    end
  end

  defp add_empty_worktree(worktree_dir, branch, bare_dir) do
    case Git.cmd(["worktree", "add", "--no-checkout", "--", worktree_dir, branch], cd: bare_dir) do
      {:ok, _output} -> :ok
      {:error, message} -> {:error, "git worktree add failed: #{message}"}
    end
  end

  defp initialize_reregistered_index(worktree_dir, nil, _bare_dir) do
    initialize_clean_index(worktree_dir)
  end

  defp initialize_reregistered_index(worktree_dir, metadata_backup, bare_dir) do
    with {:ok, new_metadata_dir} <- metadata_dir_for_worktree(bare_dir, worktree_dir),
         :ok <- copy_preserved_metadata(metadata_backup, new_metadata_dir),
         :ok <- ensure_reregistered_index(worktree_dir, metadata_backup) do
      :ok
    end
  end

  defp copy_preserved_metadata(source_metadata, destination_metadata) do
    case File.ls(source_metadata) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(&1 in @regenerated_metadata_entries))
        |> Enum.reduce_while(:ok, fn entry, :ok ->
          source = Path.join(source_metadata, entry)
          destination = Path.join(destination_metadata, entry)

          case copy_metadata_entry(source, destination, entry) do
            :ok -> {:cont, :ok}
            {:error, message} -> {:halt, {:error, message}}
          end
        end)

      {:error, reason} ->
        {:error, "failed to inspect preserved worktree metadata: #{reason}"}
    end
  end

  defp copy_metadata_entry(source, destination, relative_path) do
    case File.lstat(source) do
      {:ok, %File.Stat{type: :regular}} ->
        case File.cp(source, destination) do
          :ok ->
            :ok

          {:error, reason} ->
            {:error, "failed to preserve metadata file '#{relative_path}': #{reason}"}
        end

      {:ok, %File.Stat{type: :directory}} ->
        with :ok <- File.mkdir_p(destination),
             {:ok, entries} <- File.ls(source) do
          Enum.reduce_while(entries, :ok, fn entry, :ok ->
            child_source = Path.join(source, entry)
            child_destination = Path.join(destination, entry)
            child_relative_path = Path.join(relative_path, entry)

            case copy_metadata_entry(child_source, child_destination, child_relative_path) do
              :ok -> {:cont, :ok}
              {:error, message} -> {:halt, {:error, message}}
            end
          end)
        else
          {:error, reason} ->
            {:error, "failed to preserve metadata directory '#{relative_path}': #{reason}"}
        end

      {:ok, %File.Stat{type: type}} ->
        {:error, "cannot preserve metadata entry '#{relative_path}' because it is #{type}"}

      {:error, reason} ->
        {:error, "failed to inspect preserved metadata entry '#{relative_path}': #{reason}"}
    end
  end

  defp ensure_reregistered_index(worktree_dir, metadata_backup) do
    old_index = Path.join(metadata_backup, "index")

    case File.lstat(old_index) do
      {:ok, %File.Stat{type: :regular}} ->
        :ok

      {:error, :enoent} ->
        initialize_clean_index(worktree_dir)

      {:ok, %File.Stat{type: type}} ->
        {:error, "cannot restore worktree index because preserved index is #{type}"}

      {:error, reason} ->
        {:error, "failed to inspect preserved worktree index: #{reason}"}
    end
  end

  defp initialize_clean_index(worktree_dir) do
    case Git.cmd(["read-tree", "HEAD"], cd: worktree_dir) do
      {:ok, _output} -> :ok
      {:error, message} -> {:error, "failed to initialize worktree index: #{message}"}
    end
  end

  defp checkout_index_into_empty_worktree(worktree_dir) do
    case Git.cmd(["checkout-index", "--all"], cd: worktree_dir) do
      {:ok, _output} -> :ok
      {:error, message} -> {:error, "failed to restore files from preserved index: #{message}"}
    end
  end

  defp rollback_reregistration(
         worktree_dir,
         worktree_backup,
         bare_dir,
         old_metadata_dir,
         metadata_backup
       ) do
    with :ok <- collect_generated_worktree_files(worktree_dir, worktree_backup),
         :ok <- discard_generated_worktree(worktree_dir, bare_dir),
         :ok <- restore_old_metadata(old_metadata_dir, metadata_backup),
         :ok <- rename_backup(worktree_backup, worktree_dir) do
      :ok
    end
  end

  defp collect_generated_worktree_files(worktree_dir, worktree_backup) do
    case path_kind(worktree_dir) do
      :missing -> :ok
      :directory -> move_entries(worktree_dir, worktree_backup, [".git"])
      {:other, type} -> {:error, "generated worktree path became #{type}"}
      {:error, reason} -> {:error, "cannot inspect generated worktree: #{reason}"}
    end
  end

  defp restore_old_metadata(nil, nil), do: :ok

  defp restore_old_metadata(old_metadata_dir, metadata_backup) do
    case File.rename(metadata_backup, old_metadata_dir) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "old metadata remains preserved at #{metadata_backup}: #{reason}"}
    end
  end

  defp rename_backup(backup, destination) do
    case File.rename(backup, destination) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "worktree files remain preserved at #{backup}: #{reason}"}
    end
  end

  defp cleanup_reregistration_backups(worktree_backup, metadata_backup) do
    cleanup_worktree_backup(worktree_backup)
    retain_metadata_backup(metadata_backup)
  end

  defp retain_metadata_backup(nil), do: :ok

  defp retain_metadata_backup(metadata_backup) do
    Output.notify(
      :warning,
      "preserved previous worktree metadata at #{metadata_backup}; " <>
        "remove it only after verifying the repaired worktree state"
    )

    :ok
  end

  defp cleanup_worktree_backup(worktree_backup) do
    stale_git = Path.join(worktree_backup, ".git")

    case File.lstat(stale_git) do
      {:ok, %File.Stat{type: :regular}} ->
        _ = File.rm(stale_git)

      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: type}} ->
        Output.notify(
          :warning,
          "preserved unexpected #{type} metadata entry at #{stale_git}"
        )

      {:error, reason} ->
        Output.notify(:warning, "could not inspect stale metadata at #{stale_git}: #{reason}")
    end

    case File.ls(worktree_backup) do
      {:ok, []} ->
        case File.rmdir(worktree_backup) do
          :ok ->
            :ok

          {:error, reason} ->
            Output.notify(:warning, "preserved backup directory #{worktree_backup}: #{reason}")
        end

      {:ok, _entries} ->
        Output.notify(:warning, "preserved non-empty worktree backup at #{worktree_backup}")

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Output.notify(:warning, "could not inspect backup #{worktree_backup}: #{reason}")
    end
  end

  defp verify_branch_exists(bare_dir, branch) do
    case Git.cmd(["show-ref", "--verify", "--quiet", "refs/heads/#{branch}"], cd: bare_dir) do
      {:ok, _output} -> :ok
      {:error, _message} -> {:error, "branch does not exist: #{branch}"}
    end
  end

  defp validate_created_registration(worktree_dir, branch, bare_dir) do
    with :ok <- validate_worktree_access(worktree_dir, bare_dir),
         {:ok, records} <- worktree_records(bare_dir),
         :ok <- validate_registration_records(records, worktree_dir, branch),
         true <- registration_exact?(records, worktree_dir, branch) do
      :ok
    else
      false -> {:error, "worktree registration did not match the requested path and branch"}
      {:error, message} -> {:error, message}
    end
  end

  defp validate_registration_records(records, worktree_dir, branch) do
    expected_ref = "refs/heads/#{branch}"
    expected_path = normalize_path(worktree_dir)

    branch_elsewhere =
      Enum.find(records, fn record ->
        record.branch == expected_ref and record.path != expected_path
      end)

    wrong_branch_at_path =
      Enum.find(records, fn record ->
        record.path == expected_path and record.branch != expected_ref
      end)

    exact_count =
      Enum.count(records, fn record ->
        record.path == expected_path and record.branch == expected_ref
      end)

    cond do
      branch_elsewhere ->
        {:error,
         "branch #{branch} is already registered at #{branch_elsewhere.path}; refusing to alter #{worktree_dir}"}

      wrong_branch_at_path ->
        registered = wrong_branch_at_path.branch || "a detached or bare worktree"

        {:error,
         "worktree path #{worktree_dir} is already registered for #{registered}; refusing to replace it"}

      exact_count > 1 ->
        {:error, "duplicate worktree registrations found for #{worktree_dir}"}

      true ->
        :ok
    end
  end

  defp registration_exact?(records, worktree_dir, branch) do
    expected_path = normalize_path(worktree_dir)
    expected_ref = "refs/heads/#{branch}"

    Enum.any?(records, fn record ->
      record.path == expected_path and record.branch == expected_ref
    end)
  end

  defp record_for_path(records, worktree_dir) do
    expected_path = normalize_path(worktree_dir)
    Enum.find(records, &(&1.path == expected_path))
  end

  defp worktree_records(bare_dir) do
    case Git.cmd(["worktree", "list", "--porcelain", "-z"], cd: bare_dir) do
      {:ok, output} -> {:ok, parse_worktree_records(output)}
      {:error, message} -> {:error, "failed to list worktrees: #{message}"}
    end
  end

  defp parse_worktree_records(""), do: []

  defp parse_worktree_records(output) do
    fields = String.split(output, <<0>>, trim: false)

    {records, current} =
      Enum.reduce(fields, {[], nil}, fn field, {records, current} ->
        case field do
          "" ->
            flush_worktree_record(records, current)

          "worktree " <> path ->
            {records, _current} = flush_worktree_record(records, current)
            {records, %{path: normalize_path(path), branch: nil}}

          "branch " <> branch when not is_nil(current) ->
            {records, %{current | branch: branch}}

          _other ->
            {records, current}
        end
      end)

    {records, _current} = flush_worktree_record(records, current)
    Enum.reverse(records)
  end

  defp flush_worktree_record(records, %{path: path} = current) when not is_nil(path) do
    {[current | records], nil}
  end

  defp flush_worktree_record(records, _current), do: {records, nil}

  defp metadata_dir_for_worktree(bare_dir, worktree_dir) do
    with {:ok, matches} <- metadata_dirs_for_worktree(bare_dir, worktree_dir) do
      case matches do
        [metadata_dir] -> {:ok, metadata_dir}
        [] -> {:error, "could not locate exact metadata for worktree #{worktree_dir}"}
        _multiple -> {:error, "multiple metadata records point to worktree #{worktree_dir}"}
      end
    end
  end

  defp optional_metadata_dir_for_worktree(bare_dir, worktree_dir) do
    with {:ok, matches} <- metadata_dirs_for_worktree(bare_dir, worktree_dir) do
      case matches do
        [metadata_dir] -> {:ok, metadata_dir}
        [] -> {:ok, nil}
        _multiple -> {:error, "multiple metadata records point to worktree #{worktree_dir}"}
      end
    end
  end

  defp metadata_dirs_for_worktree(bare_dir, worktree_dir) do
    metadata_root = Path.join(bare_dir, "worktrees")
    expected_gitdir = normalize_path(Path.join(worktree_dir, ".git"))

    case File.ls(metadata_root) do
      {:ok, entries} ->
        matches =
          Enum.flat_map(entries, fn entry ->
            metadata_dir = Path.join(metadata_root, entry)
            gitdir_file = Path.join(metadata_dir, "gitdir")

            case File.read(gitdir_file) do
              {:ok, gitdir} ->
                if resolve_git_path(gitdir, metadata_dir) == expected_gitdir do
                  [metadata_dir]
                else
                  []
                end

              {:error, _reason} ->
                []
            end
          end)

        {:ok, matches}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, "failed to inspect worktree metadata: #{reason}"}
    end
  end

  defp validate_worktree_access(worktree_dir, bare_dir) do
    with {:ok, "true"} <- Git.cmd(["rev-parse", "--is-inside-work-tree"], cd: worktree_dir),
         {:ok, top_level} <- Git.cmd(["rev-parse", "--show-toplevel"], cd: worktree_dir),
         true <- normalize_path(top_level) == normalize_path(worktree_dir),
         {:ok, common_dir_output} <-
           Git.cmd(["rev-parse", "--git-common-dir"], cd: worktree_dir),
         true <-
           resolve_git_path(common_dir_output, worktree_dir) == normalize_path(bare_dir) do
      :ok
    else
      {:error, message} -> {:error, message}
      _other -> {:error, "worktree resolves to the wrong repository or path"}
    end
  end

  defp do_init_steps(dir, branch, git_dir, bare_dir, worktree_dir, backup_dir) do
    with :ok <- move_git_to_bare(git_dir, bare_dir),
         :ok <- Project.configure_bare(bare_dir),
         :ok <- move_root_files_to_backup(dir, bare_dir, backup_dir),
         :ok <- add_empty_worktree(worktree_dir, branch, bare_dir),
         :ok <- initialize_clean_index(worktree_dir),
         :ok <- move_entries(backup_dir, worktree_dir, []),
         :ok <- write_gitdir_pointer(dir),
         :ok <- Project.ensure_upstream(worktree_dir, branch),
         :ok <- validate_init(dir, branch, bare_dir),
         :ok <- remove_empty_backup(backup_dir) do
      :ok
    end
  end

  defp current_branch(dir) do
    case Git.cmd(["symbolic-ref", "--quiet", "--short", "HEAD"], cd: dir) do
      {:ok, branch} when branch != "" ->
        {:ok, branch}

      {:error, _message} ->
        case Git.cmd(["rev-parse", "--verify", "HEAD"], cd: dir) do
          {:ok, _commit} ->
            {:error, "cannot initialize from detached HEAD; check out a branch first"}

          {:error, _reason} ->
            {:error, "could not determine current branch"}
        end
    end
  end

  # Only tracked changes need a stash. Untracked and ignored files are moved
  # directly, so an untracked-only status can never select an older stash.
  defp stash_changes(dir) do
    case Git.cmd(["status", "--porcelain", "--untracked-files=no"], cd: dir) do
      {:ok, ""} ->
        {:ok, nil}

      {:ok, _tracked_changes} ->
        create_tracked_stash(dir)

      {:error, message} ->
        {:error, "git status failed: #{message}"}
    end
  end

  defp create_tracked_stash(dir) do
    marker =
      "git-work-init-#{:os.getpid()}-#{System.unique_integer([:positive, :monotonic])}"

    with {:ok, before_entries} <- stash_entries(dir) do
      result = Git.cmd(["stash", "push", "-m", marker], cd: dir)

      case identify_created_stash(dir, marker, before_entries) do
        {:ok, stash} ->
          case result do
            {:ok, _output} ->
              {:ok, stash}

            {:error, message} ->
              case restore_stash(dir, stash) do
                :ok ->
                  {:error, "failed to stash tracked changes: #{message}; changes were restored"}

                {:error, restore_message} ->
                  {:error,
                   "failed to stash tracked changes: #{message}; #{restore_message}; " <>
                     "the exact stash #{stash.oid} was preserved"}
              end
          end

        {:error, identify_message} ->
          case result do
            {:ok, _output} ->
              {:error,
               "git created an init stash but it could not be identified safely " <>
                 "(#{identify_message}); tracked changes may be preserved in the stash named #{marker} and no stash was applied or dropped"}

            {:error, message} ->
              {:error, "failed to stash tracked changes: #{message}"}
          end
      end
    end
  end

  defp identify_created_stash(dir, marker, before_entries) do
    before_oids = MapSet.new(before_entries, & &1.oid)

    case stash_entries(dir) do
      {:ok, after_entries} ->
        matches =
          Enum.filter(after_entries, fn entry ->
            String.ends_with?(entry.subject, marker) and
              not MapSet.member?(before_oids, entry.oid)
          end)

        case matches do
          [%{oid: oid}] -> {:ok, %{oid: oid, marker: marker}}
          [] -> identify_stash_head(dir, marker, before_oids)
          _multiple -> {:error, "multiple new stashes matched the unique init marker"}
        end

      {:error, _message} ->
        identify_stash_head(dir, marker, before_oids)
    end
  end

  defp identify_stash_head(dir, marker, before_oids) do
    with {:ok, oid} <- Git.cmd(["rev-parse", "--verify", "refs/stash"], cd: dir),
         false <- MapSet.member?(before_oids, oid),
         {:ok, subject} <- Git.cmd(["show", "-s", "--format=%s", oid], cd: dir),
         true <- String.ends_with?(subject, marker) do
      {:ok, %{oid: oid, marker: marker}}
    else
      true -> {:error, "the stash ref did not change"}
      false -> {:error, "the stash ref did not point to the invocation's unique marker"}
      {:error, message} -> {:error, message}
    end
  end

  defp stash_entries(dir) do
    case Git.cmd(["stash", "list", "--format=%H%x09%gd%x09%gs"], cd: dir) do
      {:ok, ""} ->
        {:ok, []}

      {:ok, output} ->
        entries =
          output
          |> String.split("\n", trim: true)
          |> Enum.reduce_while([], fn line, entries ->
            case String.split(line, "\t", parts: 3) do
              [oid, selector, subject] ->
                {:cont, [%{oid: oid, selector: selector, subject: subject} | entries]}

              _malformed ->
                {:halt, :malformed}
            end
          end)

        case entries do
          :malformed -> {:error, "git returned a malformed stash list"}
          parsed -> {:ok, Enum.reverse(parsed)}
        end

      {:error, message} ->
        {:error, "failed to inspect stashes: #{message}"}
    end
  end

  defp restore_stash(_dir, nil), do: :ok

  defp restore_stash(dir, %{oid: oid}) do
    case Git.cmd(["stash", "apply", "--index", oid], cd: dir) do
      {:ok, _output} ->
        Output.notify(
          :warning,
          "restored changes from init stash #{oid}; left that stash intact because " <>
            "Git has no atomic OID-safe stash removal"
        )

        :ok

      {:error, message} ->
        {:error, "failed to restore changes from the init stash #{oid}: #{message}"}
    end
  end

  defp capture_config(git_dir) do
    config_path = Path.join(git_dir, "config")

    case File.read(config_path) do
      {:ok, content} -> {:ok, {:present, content}}
      {:error, :enoent} -> {:ok, :missing}
      {:error, reason} -> {:error, "failed to capture repository configuration: #{reason}"}
    end
  end

  defp restore_config_snapshot(repo_dir, {:present, content}) do
    config_path = Path.join(repo_dir, "config")

    case File.write(config_path, content) do
      :ok -> :ok
      {:error, reason} -> {:error, "failed to restore repository configuration: #{reason}"}
    end
  end

  defp restore_config_snapshot(repo_dir, :missing) do
    case File.rm(Path.join(repo_dir, "config")) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, "failed to remove generated repository configuration: #{reason}"}
    end
  end

  defp move_git_to_bare(git_dir, bare_dir) do
    case File.rename(git_dir, bare_dir) do
      :ok -> :ok
      {:error, reason} -> {:error, "failed to move .git to .bare: #{reason}"}
    end
  end

  defp write_gitdir_pointer(dir) do
    git_path = Path.join(dir, ".git")
    tmp_path = Path.join(dir, ".git.tmp.#{:os.getpid()}")

    with :ok <- File.write(tmp_path, @gitdir_pointer),
         :ok <- File.rename(tmp_path, git_path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp_path)
        {:error, "failed to write .git pointer: #{reason}"}
    end
  end

  defp move_root_files_to_backup(dir, bare_dir, backup_dir) do
    with :ok <- make_directory(backup_dir),
         {:ok, entries} <- File.ls(dir) do
      excluded = [Path.basename(bare_dir), ".git", Path.basename(backup_dir)]

      entries
      |> Enum.reject(&(&1 in excluded))
      |> move_named_entries(dir, backup_dir)
    else
      {:error, reason} ->
        {:error, "failed to prepare worktree file backup: #{reason}"}
    end
  end

  defp make_directory(path) do
    case File.mkdir(path) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp move_entries(source_dir, destination_dir, excluded) do
    case File.ls(source_dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(&1 in excluded))
        |> move_named_entries(source_dir, destination_dir)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, "failed to list '#{source_dir}': #{reason}"}
    end
  end

  defp move_named_entries(entries, source_dir, destination_dir) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      source = Path.join(source_dir, entry)
      destination = Path.join(destination_dir, entry)

      case File.lstat(destination) do
        {:error, :enoent} ->
          case File.rename(source, destination) do
            :ok ->
              {:cont, :ok}

            {:error, reason} ->
              {:halt, {:error, "failed to move '#{source}' to '#{destination}': #{reason}"}}
          end

        {:ok, _stat} ->
          {:halt, {:error, "refusing to overwrite existing path '#{destination}'"}}

        {:error, reason} ->
          {:halt, {:error, "failed to inspect destination '#{destination}': #{reason}"}}
      end
    end)
  end

  defp remove_empty_backup(backup_dir) do
    case File.rmdir(backup_dir) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, "failed to remove temporary backup '#{backup_dir}': #{reason}"}
    end
  end

  defp validate_init(dir, branch, bare_dir) do
    worktree_dir = Project.worktree_path(dir, branch)

    case validate_created_registration(worktree_dir, branch, bare_dir) do
      :ok -> :ok
      {:error, message} -> {:error, "init verification failed: #{message}"}
    end
  end

  defp rollback_init(dir, branch, backup_dir, config_snapshot, stash) do
    bare_dir = Project.bare_path(dir)
    git_dir = Path.join(dir, ".git")
    worktree_dir = Project.worktree_path(dir, branch)

    {content_restored?, errors} = rollback_init_content(dir, worktree_dir, backup_dir, bare_dir)
    {repo_restored?, errors} = rollback_repository(git_dir, bare_dir, config_snapshot, errors)

    errors =
      cond do
        content_restored? and repo_restored? ->
          case restore_stash(dir, stash) do
            :ok -> errors
            {:error, message} -> ["#{message}; the exact stash was preserved" | errors]
          end

        is_nil(stash) ->
          errors

        true ->
          [
            "the exact init stash #{stash.oid} was preserved because repository rollback was incomplete"
            | errors
          ]
      end

    case Enum.reverse(errors) do
      [] -> :ok
      messages -> {:error, Enum.join(messages, "; ")}
    end
  end

  defp rollback_init_content(dir, worktree_dir, backup_dir, bare_dir) do
    case collect_fresh_init_files(worktree_dir, backup_dir) do
      :ok ->
        errors =
          case discard_generated_worktree(worktree_dir, bare_dir) do
            :ok -> []
            {:error, message} -> [message]
          end

        case move_entries(backup_dir, dir, []) do
          :ok ->
            case remove_empty_backup(backup_dir) do
              :ok -> {true, errors}
              {:error, message} -> {false, [message | errors]}
            end

          {:error, message} ->
            {false, ["worktree files remain preserved at #{backup_dir}: #{message}" | errors]}
        end

      {:error, message} ->
        {false, ["could not collect worktree files into #{backup_dir}: #{message}"]}
    end
  end

  defp rollback_repository(git_dir, bare_dir, config_snapshot, errors) do
    config_repo_dir =
      cond do
        path_kind(bare_dir) == :directory -> bare_dir
        path_kind(git_dir) == :directory -> git_dir
        true -> nil
      end

    errors =
      if config_repo_dir do
        case restore_config_snapshot(config_repo_dir, config_snapshot) do
          :ok -> errors
          {:error, message} -> [message | errors]
        end
      else
        ["could not locate repository metadata to restore configuration" | errors]
      end

    case restore_git_directory(git_dir, bare_dir) do
      :ok -> {true, errors}
      {:error, message} -> {false, [message | errors]}
    end
  end

  defp restore_git_directory(git_dir, bare_dir) do
    with :ok <- remove_generated_git_pointer(git_dir),
         :ok <- rename_bare_to_git(git_dir, bare_dir),
         true <- path_kind(git_dir) == :directory do
      :ok
    else
      false -> {:error, "failed to restore .git directory"}
      {:error, message} -> {:error, message}
    end
  end

  defp remove_generated_git_pointer(git_dir) do
    case File.lstat(git_dir) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:ok, %File.Stat{type: :regular}} ->
        case File.read(git_dir) do
          {:ok, @gitdir_pointer} ->
            case File.rm(git_dir) do
              :ok -> :ok
              {:error, reason} -> {:error, "failed to remove generated .git pointer: #{reason}"}
            end

          {:ok, _other} ->
            {:error, "refusing to remove an unexpected .git file during rollback"}

          {:error, reason} ->
            {:error, "failed to inspect .git during rollback: #{reason}"}
        end

      {:ok, %File.Stat{type: type}} ->
        {:error, "refusing to replace unexpected .git #{type} during rollback"}

      {:error, reason} ->
        {:error, "failed to inspect .git during rollback: #{reason}"}
    end
  end

  defp rename_bare_to_git(git_dir, bare_dir) do
    case {path_kind(bare_dir), path_kind(git_dir)} do
      {:directory, :directory} ->
        {:error, "both .git and .bare directories exist; repository metadata was left untouched"}

      {:directory, :missing} ->
        case File.rename(bare_dir, git_dir) do
          :ok -> :ok
          {:error, reason} -> {:error, "failed to restore .git directory: #{reason}"}
        end

      {:missing, :directory} ->
        :ok

      _other ->
        {:error, "neither .git nor .bare repository metadata is available"}
    end
  end

  defp collect_fresh_init_files(worktree_dir, backup_dir) do
    case path_kind(worktree_dir) do
      :missing ->
        :ok

      :directory ->
        with :ok <- ensure_directory_exists(backup_dir),
             :ok <- move_entries(worktree_dir, backup_dir, [".git"]) do
          :ok
        end

      {:other, type} ->
        {:error, "generated worktree path became #{type}"}

      {:error, reason} ->
        {:error, "failed to inspect generated worktree: #{reason}"}
    end
  end

  defp ensure_directory_exists(path) do
    case File.mkdir(path) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, "failed to create rollback backup '#{path}': #{reason}"}
    end
  end

  defp discard_generated_worktree(worktree_dir, bare_dir) do
    metadata_dir =
      case optional_metadata_dir_for_worktree(bare_dir, worktree_dir) do
        {:ok, path} -> path
        {:error, _message} -> nil
      end

    if path_kind(bare_dir) == :directory do
      _ = Git.cmd(["worktree", "remove", "--force", worktree_dir], cd: bare_dir)
    end

    with :ok <- remove_path(worktree_dir),
         :ok <- remove_optional_path(metadata_dir) do
      :ok
    end
  end

  defp remove_optional_path(nil), do: :ok
  defp remove_optional_path(path), do: remove_path(path)

  defp remove_path(path) do
    case File.rm_rf(path) do
      {:ok, _removed} ->
        :ok

      {:error, reason, failed_path} ->
        {:error, "failed to remove generated path '#{failed_path}': #{reason}"}
    end
  end

  defp combine_rollback_results(:ok, :ok), do: :ok
  defp combine_rollback_results({:error, first}, :ok), do: {:error, first}
  defp combine_rollback_results(:ok, {:error, second}), do: {:error, second}

  defp combine_rollback_results({:error, first}, {:error, second}) do
    {:error, "#{first}; #{second}"}
  end

  defp path_kind(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :missing
      {:ok, %File.Stat{type: :directory}} -> :directory
      {:ok, %File.Stat{type: type}} -> {:other, type}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_git_path(path, relative_to) do
    path = trim_git_path(path)

    case Path.type(path) do
      :absolute -> normalize_path(path)
      _relative -> normalize_path(Path.expand(path, relative_to))
    end
  end

  defp trim_git_path(path) do
    path
    |> String.trim_trailing("\n")
    |> String.trim_trailing("\r")
  end

  defp normalize_path(path), do: Path.expand(path)

  defp unique_sibling_backup(path, label) do
    prefix = ".#{Path.basename(path)}.git-work-#{label}"
    unique_child_path(Path.dirname(path), prefix)
  end

  defp unique_child_path(parent, prefix) do
    token = "#{:os.getpid()}-#{System.unique_integer([:positive, :monotonic])}"
    candidate = Path.join(parent, "#{prefix}-#{token}")

    case File.lstat(candidate) do
      {:error, :enoent} ->
        {:ok, candidate}

      {:ok, _stat} ->
        unique_child_path(parent, prefix)

      {:error, reason} ->
        {:error, "failed to inspect unique path '#{candidate}': #{reason}"}
    end
  end

  # Non-fatal: a failure to propagate trust is a warning, not a reason to undo
  # an otherwise successful init. The user can run `mise trust` manually.
  defp maybe_propagate_trust(root, worktree_dir, was_trusted) do
    context = %{root: root, worktree_dir: worktree_dir, was_trusted: was_trusted}

    case Hooks.run(:post_init, context) do
      :ok ->
        :ok

      {:error, message} ->
        Output.notify(:warning, message)
        :ok
    end
  end
end
