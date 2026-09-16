defmodule GitWork.Commands.Rm do
  @moduledoc """
  Remove a worktree and optionally delete its branch.
  """

  alias GitWork.Commands.List, as: WorktreeList
  alias GitWork.{Fuzzy, Git, Output, Project}

  @usage "usage: git-work rm [--force] [--yes] <branch>"
  @current_key "git-work.current-worktree"
  @last_key "git-work.last-worktree"

  def help do
    """
    usage: git-work rm [--force] [--yes] <branch>

    Remove a worktree and delete its branch with confirmation.

    Removes the worktree directory and runs 'git branch -d' to delete the
    branch. Refuses to remove the HEAD branch (usually main) unless --force
    is given. The branch argument supports fuzzy matching against existing
    worktree directories.

    If you are inside the worktree being removed, the command prints the
    path to a surviving registered worktree so the shell wrapper can cd there.

    Options:
      --force, -f    Use 'git branch -D' and allow removing the HEAD branch
      --yes, -y      Skip confirmation prompt

    Examples:
      git-work rm feature-login
      git-work rm login
      git-work rm --yes feature-login
      git-work rm --force old-branch
    """
  end

  def run(args, _format) do
    with {:ok, force?, yes?, input} <- parse_args(args),
         {:ok, root} <- Project.find_root(),
         {:ok, target, worktrees} <- resolve_target(root, input) do
      do_rm(root, target, worktrees, force?, yes?)
    end
  end

  defp parse_args(args) do
    parsed =
      Enum.reduce_while(args, {false, false, []}, fn
        "--force", {_force?, yes?, positional} ->
          {:cont, {true, yes?, positional}}

        "-f", {_force?, yes?, positional} ->
          {:cont, {true, yes?, positional}}

        "--yes", {force?, _yes?, positional} ->
          {:cont, {force?, true, positional}}

        "-y", {force?, _yes?, positional} ->
          {:cont, {force?, true, positional}}

        argument, _acc when argument == "" ->
          {:halt, :invalid}

        <<"-", _rest::binary>>, _acc ->
          {:halt, :invalid}

        argument, {force?, yes?, positional} ->
          {:cont, {force?, yes?, [argument | positional]}}
      end)

    case parsed do
      {force?, yes?, [input]} -> {:ok, force?, yes?, input}
      _invalid -> {:error, @usage}
    end
  end

  defp do_rm(root, target, worktrees, force?, yes?) do
    bare_dir = Project.bare_path(root)
    cwd = Path.expand(File.cwd!())

    with {:ok, head} <- Project.head_branch(root),
         :ok <- ensure_head_removal_allowed(target.branch, head, force?),
         {:ok, target} <- preflight_target(root, bare_dir, target),
         :ok <- ensure_safely_deletable(bare_dir, target, force?),
         {:ok, config_before} <- read_config_state(bare_dir),
         {:ok, fallback} <-
           select_fallback(root, bare_dir, worktrees, target, cwd, config_before, head),
         :ok <- ensure_required_fallback(target.branch, head, force?, fallback),
         :ok <- maybe_confirm(target, yes?) do
      inside? = path_contains?(target.path, cwd)

      config_after =
        desired_config_state(worktrees, target, fallback, cwd, inside?, config_before)

      transaction = %{
        root: root,
        bare_dir: bare_dir,
        target: target,
        fallback: fallback,
        original_cwd: cwd,
        inside?: inside?,
        force?: force?,
        old_head: head,
        head_changed?: force? and target.branch == head,
        config_before: config_before,
        config_after: config_after
      }

      execute_transaction(transaction)
    end
  end

  defp ensure_head_removal_allowed(branch, head, false) when branch == head do
    {:error, "refusing to remove HEAD branch '#{branch}' (use --force)"}
  end

  defp ensure_head_removal_allowed(_branch, _head, _force?), do: :ok

  defp resolve_target(root, input) do
    with {:ok, worktrees} <- worktree_entries(root) do
      managed_worktrees = Enum.filter(worktrees, &Map.fetch!(&1, :managed?))

      case Enum.filter(worktrees, &(&1.branch == input)) do
        [] ->
          with {:ok, target, ^managed_worktrees} <-
                 resolve_directory_target(managed_worktrees, input),
               :ok <- ensure_unique_branch_registration(worktrees, target) do
            {:ok, target, managed_worktrees}
          end

        [target] ->
          if Map.fetch!(target, :managed?) do
            {:ok, target, managed_worktrees}
          else
            {:error,
             "branch '#{input}' is registered at '#{target.path}', which is not a managed " <>
               "direct-child worktree of '#{Path.expand(root)}'"}
          end

        duplicates ->
          duplicate_branch_error(input, duplicates)
      end
    end
  end

  defp ensure_unique_branch_registration(worktrees, target) do
    duplicates = Enum.filter(worktrees, &(&1.branch == target.branch))

    case duplicates do
      [_target] -> :ok
      _duplicates -> duplicate_branch_error(target.branch, duplicates)
    end
  end

  defp duplicate_branch_error(branch, worktrees) do
    paths = Enum.map_join(worktrees, "\n", &"  #{&1.path}")

    {:error,
     "refusing to remove branch '#{branch}': it is registered in multiple worktrees:\n#{paths}"}
  end

  defp resolve_directory_target(worktrees, input) do
    candidates = Enum.map(worktrees, & &1.dir_name)
    sanitized = Project.sanitize_branch(input)

    case Fuzzy.match(sanitized, candidates) do
      {:exact, dir_name} ->
        select_worktree(worktrees, dir_name)

      {:match, dir_name} ->
        Output.notify(:info, "fuzzy match: '#{input}' -> '#{dir_name}'")
        select_worktree(worktrees, dir_name)

      {:ambiguous, candidates} ->
        formatted = Enum.map_join(candidates, "\n", &"  #{&1}")
        {:error, "ambiguous match for '#{input}':\n#{formatted}"}

      :no_match ->
        {:error, "worktree '#{input}' does not exist"}
    end
  end

  defp worktree_entries(root) do
    bare_dir = Project.bare_path(root)
    expanded_root = Path.expand(root)

    case Git.cmd(["worktree", "list", "--porcelain", "-z"], cd: bare_dir) do
      {:ok, output} ->
        worktrees =
          output
          |> WorktreeList.parse_porcelain(root)
          |> Enum.flat_map(fn
            %{path: path, branch: branch} when is_binary(path) and is_binary(branch) ->
              absolute_path = Path.expand(path)

              [
                %{
                  path: absolute_path,
                  branch: branch,
                  dir_name: Path.basename(absolute_path),
                  managed?: Path.dirname(absolute_path) == expanded_root
                }
              ]

            _entry ->
              []
          end)

        {:ok, worktrees}

      {:error, msg} ->
        {:error, "worktree list failed: #{msg}"}
    end
  end

  defp select_worktree(worktrees, dir_name) do
    case Enum.find(worktrees, &(&1.dir_name == dir_name)) do
      nil -> {:error, "worktree '#{dir_name}' does not exist"}
      target -> {:ok, target, worktrees}
    end
  end

  defp preflight_target(root, bare_dir, target) do
    with :ok <- validate_registered_worktree(root, bare_dir, target),
         {:ok, oid} <- branch_oid(bare_dir, target.branch),
         :ok <- ensure_clean(target) do
      {:ok, Map.put(target, :oid, oid)}
    end
  end

  defp validate_registered_worktree(root, bare_dir, target) do
    expected_root = Path.expand(root)
    expected_path = Path.expand(target.path)
    expected_bare = Path.expand(bare_dir)

    cond do
      Path.dirname(expected_path) != expected_root ->
        {:error, "worktree '#{target.branch}' is not a direct child of '#{expected_root}'"}

      not File.dir?(expected_path) ->
        {:error, "registered worktree '#{target.branch}' does not exist at '#{expected_path}'"}

      true ->
        with {:ok, top_level} <-
               git_identity(
                 ["rev-parse", "--show-toplevel"],
                 expected_path,
                 target,
                 "top-level path"
               ),
             :ok <- ensure_same_path(top_level, expected_path, target, "top-level path"),
             {:ok, common_dir} <-
               git_identity(
                 ["rev-parse", "--git-common-dir"],
                 expected_path,
                 target,
                 "common Git directory"
               ),
             :ok <-
               ensure_same_path(
                 expand_from(common_dir, expected_path),
                 expected_bare,
                 target,
                 "common Git directory"
               ),
             {:ok, actual_branch} <-
               git_identity(
                 ["symbolic-ref", "--quiet", "--short", "HEAD"],
                 expected_path,
                 target,
                 "checked-out branch"
               ),
             :ok <- ensure_same_branch(actual_branch, target) do
          ensure_branch_ref_exists(bare_dir, target.branch)
        end
    end
  end

  defp git_identity(args, path, target, identity) do
    case Git.cmd(args, cd: path) do
      {:ok, value} ->
        {:ok, value}

      {:error, msg} ->
        {:error,
         "could not verify #{identity} for branch '#{target.branch}' at '#{target.path}': #{msg}"}
    end
  end

  defp ensure_same_path(actual, expected, target, identity) do
    if is_binary(actual) and Path.expand(actual) == expected do
      :ok
    else
      {:error,
       "registered worktree '#{target.branch}' at '#{target.path}' has unexpected #{identity} " <>
         "'#{actual}' (expected '#{expected}')"}
    end
  end

  defp ensure_same_branch(actual_branch, %{branch: actual_branch}), do: :ok

  defp ensure_same_branch(actual_branch, target) do
    {:error,
     "registered worktree at '#{target.path}' is on branch '#{actual_branch}', " <>
       "not '#{target.branch}'"}
  end

  defp ensure_branch_ref_exists(bare_dir, branch) do
    case Git.cmd(["show-ref", "--verify", "--quiet", "refs/heads/#{branch}"], cd: bare_dir) do
      {:ok, _output} ->
        :ok

      {:error, msg} ->
        {:error, "branch '#{branch}' is not available in the bare repository: #{msg}"}
    end
  end

  defp expand_from(path, base) do
    case Path.type(path) do
      :absolute -> Path.expand(path)
      _relative -> Path.expand(path, base)
    end
  end

  defp branch_oid(bare_dir, branch) do
    case Git.cmd(["rev-parse", "--verify", "refs/heads/#{branch}^{commit}"], cd: bare_dir) do
      {:ok, oid} -> {:ok, oid}
      {:error, msg} -> {:error, "could not resolve branch '#{branch}': #{msg}"}
    end
  end

  defp ensure_clean(target) do
    args = [
      "status",
      "--porcelain=v1",
      "--untracked-files=all",
      "--ignored",
      "--ignore-submodules=none"
    ]

    case Git.cmd(args, cd: target.path) do
      {:ok, ""} ->
        :ok

      {:ok, status} ->
        {:error,
         "refusing to remove branch '#{target.branch}' at '#{target.path}': " <>
           "worktree contains staged, unstaged, untracked, or ignored files:\n#{status}"}

      {:error, msg} ->
        {:error,
         "could not inspect worktree state for branch '#{target.branch}' at '#{target.path}': #{msg}"}
    end
  end

  defp ensure_safely_deletable(_bare_dir, _target, true), do: :ok

  defp ensure_safely_deletable(bare_dir, target, false) do
    with {:ok, upstream} <- branch_upstream(bare_dir, target.branch),
         comparison = if(upstream == "", do: "HEAD", else: upstream),
         {:ok, comparison_oid} <- resolve_merge_target(bare_dir, comparison) do
      case Git.cmd(["merge-base", "--is-ancestor", target.oid, comparison_oid],
             cd: bare_dir
           ) do
        {:ok, _output} ->
          :ok

        {:error, ""} ->
          {:error,
           "branch '#{target.branch}' is not fully merged into '#{comparison}' (use --force)"}

        {:error, msg} ->
          {:error,
           "could not verify whether branch '#{target.branch}' is merged into " <>
             "'#{comparison}': #{msg}"}
      end
    else
      {:error, {:merge_target, comparison, msg}} ->
        {:error,
         "could not resolve merge target '#{comparison}' for branch '#{target.branch}': #{msg}"}

      {:error, _msg} = error ->
        error
    end
  end

  defp resolve_merge_target(bare_dir, comparison) do
    case Git.cmd(["rev-parse", "--verify", "#{comparison}^{commit}"], cd: bare_dir) do
      {:ok, comparison_oid} ->
        {:ok, comparison_oid}

      {:error, msg} when comparison != "HEAD" ->
        if missing_ref?(bare_dir, comparison) do
          resolve_merge_target(bare_dir, "HEAD")
        else
          {:error, {:merge_target, comparison, msg}}
        end

      {:error, msg} ->
        {:error, {:merge_target, comparison, msg}}
    end
  end

  defp missing_ref?(bare_dir, ref) do
    case Git.cmd(["show-ref", "--verify", "--quiet", ref], cd: bare_dir) do
      {:ok, _output} -> false
      {:error, ""} -> true
      {:error, _msg} -> false
    end
  end

  defp branch_upstream(bare_dir, branch) do
    case Git.cmd(
           ["for-each-ref", "--format=%(upstream)", "refs/heads/#{branch}"],
           cd: bare_dir
         ) do
      {:ok, upstream} -> {:ok, upstream}
      {:error, msg} -> {:error, "could not inspect upstream for branch '#{branch}': #{msg}"}
    end
  end

  defp read_config_state(bare_dir) do
    with {:ok, current} <- read_config_value(bare_dir, @current_key),
         {:ok, last} <- read_config_value(bare_dir, @last_key) do
      {:ok, %{current: current, last: last}}
    end
  end

  defp read_config_value(bare_dir, key) do
    case Git.cmd(["config", "--get", key], cd: bare_dir) do
      {:ok, ""} -> {:ok, nil}
      {:ok, value} -> {:ok, value}
      {:error, ""} -> {:ok, nil}
      {:error, msg} -> {:error, "failed to read #{key}: #{msg}"}
    end
  end

  defp select_fallback(root, bare_dir, worktrees, target, cwd, config, head) do
    candidates =
      worktrees
      |> Enum.reject(&(&1.path == target.path or &1.branch == target.branch))

    current = current_worktree(candidates, cwd)

    preferred = [
      current,
      worktree_for_config(candidates, config.current),
      worktree_for_config(candidates, config.last),
      Enum.find(candidates, &(&1.branch == head))
    ]

    candidates =
      (preferred ++ candidates)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.path)

    fallback =
      Enum.find(candidates, fn candidate ->
        validate_registered_worktree(root, bare_dir, candidate) == :ok
      end)

    {:ok, fallback}
  end

  defp ensure_required_fallback(branch, head, true, nil) when branch == head do
    {:error,
     "refusing to remove HEAD branch '#{branch}': no other valid registered direct-child " <>
       "branch worktree is available as a fallback"}
  end

  defp ensure_required_fallback(_branch, _head, _force?, _fallback), do: :ok

  defp current_worktree(worktrees, cwd) do
    worktrees
    |> Enum.filter(&path_contains?(&1.path, cwd))
    |> Enum.max_by(&String.length(&1.path), fn -> nil end)
  end

  defp worktree_for_config(_worktrees, nil), do: nil

  defp worktree_for_config(worktrees, name) do
    Enum.find(worktrees, &(Path.basename(&1.path) == name))
  end

  defp desired_config_state(worktrees, target, fallback, cwd, inside?, config_before) do
    survivors =
      worktrees
      |> Enum.reject(&(&1.path == target.path or &1.branch == target.branch))
      |> Enum.filter(&File.dir?(&1.path))

    survivor_names = survivors |> Enum.map(&Path.basename(&1.path)) |> MapSet.new()
    fallback_name = if fallback, do: Path.basename(fallback.path), else: nil

    current =
      cond do
        inside? -> fallback_name
        fallback && path_contains?(fallback.path, cwd) -> fallback_name
        MapSet.member?(survivor_names, config_before.current) -> config_before.current
        true -> fallback_name
      end

    last =
      [config_before.last, config_before.current, fallback_name | MapSet.to_list(survivor_names)]
      |> Enum.find(fn name ->
        is_binary(name) and name != current and MapSet.member?(survivor_names, name)
      end)

    %{current: current, last: last}
  end

  defp maybe_confirm(_target, true), do: :ok

  defp maybe_confirm(target, false) do
    Output.confirm(
      "delete branch '#{target.branch}' and registered worktree at '#{target.path}'? [y/N]: "
    )
  end

  defp execute_transaction(transaction) do
    case update_head(transaction) do
      :ok ->
        execute_after_head_update(transaction)

      {:error, msg} ->
        details = restore_head_details(transaction)
        {:error, append_rollback(msg, details)}
    end
  end

  defp update_head(%{head_changed?: false}), do: :ok

  defp update_head(transaction) do
    case Git.cmd(
           ["symbolic-ref", "HEAD", "refs/heads/#{transaction.fallback.branch}"],
           cd: transaction.bare_dir
         ) do
      {:ok, _output} ->
        :ok

      {:error, msg} ->
        {:error,
         "failed to move bare HEAD from '#{transaction.old_head}' to " <>
           "'#{transaction.fallback.branch}': #{msg}"}
    end
  end

  defp execute_after_head_update(transaction) do
    case apply_config_state(transaction) do
      :ok ->
        execute_after_metadata_update(transaction)

      {:error, msg} ->
        details = restore_head_details(transaction)
        {:error, append_rollback(msg, details)}
    end
  end

  defp apply_config_state(transaction) do
    changes = [
      {@current_key, transaction.config_before.current, transaction.config_after.current},
      {@last_key, transaction.config_before.last, transaction.config_after.last}
    ]

    Enum.reduce_while(changes, :ok, fn
      {_key, value, value}, :ok ->
        {:cont, :ok}

      {key, _old_value, new_value}, :ok ->
        case write_config_value(transaction.bare_dir, key, new_value) do
          :ok ->
            {:cont, :ok}

          {:error, msg} ->
            details = restore_config_details(transaction)

            {:halt,
             {:error,
              append_rollback("failed to update checkout state '#{key}': #{msg}", details)}}
        end
    end)
  end

  defp write_config_value(bare_dir, key, nil) do
    result = Git.cmd(["config", "--unset-all", key], cd: bare_dir)

    case result do
      {:ok, _output} -> verify_config_value(bare_dir, key, nil)
      {:error, ""} -> verify_config_value(bare_dir, key, nil)
      {:error, msg} -> {:error, msg}
    end
  end

  defp write_config_value(bare_dir, key, value) do
    case Git.cmd(["config", key, value], cd: bare_dir) do
      {:ok, _output} -> verify_config_value(bare_dir, key, value)
      {:error, msg} -> {:error, msg}
    end
  end

  defp verify_config_value(bare_dir, key, expected) do
    case read_config_value(bare_dir, key) do
      {:ok, ^expected} -> :ok
      {:ok, actual} -> {:error, "expected #{inspect(expected)}, got #{inspect(actual)}"}
      {:error, msg} -> {:error, msg}
    end
  end

  defp execute_after_metadata_update(transaction) do
    case leave_target_worktree(transaction) do
      :ok ->
        remove_registered_worktree(transaction)

      {:error, msg} ->
        details = restore_metadata_details(transaction) ++ restore_cwd_details(transaction)
        {:error, append_rollback(msg, details)}
    end
  end

  defp leave_target_worktree(%{inside?: false}), do: :ok

  defp leave_target_worktree(transaction) do
    case File.cd(transaction.root) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "could not leave target worktree: #{:file.format_error(reason)}"}
    end
  end

  defp remove_registered_worktree(transaction) do
    # --force is intentionally limited to branch/HEAD protection. Passing it to
    # worktree remove could discard data written after the clean preflight.
    args = ["worktree", "remove", transaction.target.path]

    case Git.cmd(args, cd: transaction.bare_dir) do
      {:ok, _output} ->
        delete_branch(transaction)

      {:error, msg} ->
        details = rollback_after_git_failure(transaction)

        {:error,
         append_rollback(
           "worktree removal failed for '#{transaction.target.path}': #{msg}",
           details
         )}
    end
  end

  defp delete_branch(transaction) do
    flag = if transaction.force?, do: "-D", else: "-d"

    case Git.cmd(["branch", flag, transaction.target.branch], cd: transaction.bare_dir) do
      {:ok, _output} ->
        removal_success(transaction)

      {:error, msg} ->
        details = rollback_after_git_failure(transaction)

        {:error,
         append_rollback(
           "branch deletion failed for '#{transaction.target.branch}': #{msg}",
           details
         )}
    end
  end

  defp removal_success(transaction) do
    target = transaction.target

    if transaction.inside? do
      destination =
        case transaction.fallback do
          %{path: path} when path != target.path ->
            if File.dir?(path), do: path, else: transaction.root

          _other ->
            transaction.root
        end

      Output.notify(
        :info,
        "removed branch '#{target.branch}' and worktree '#{target.path}', " <>
          "switching to '#{destination}'"
      )

      {:ok, destination}
    else
      Output.notify(:info, "removed branch '#{target.branch}' and worktree '#{target.path}'")
      {:ok, ""}
    end
  end

  defp rollback_after_git_failure(transaction) do
    [restore_worktree_detail(transaction)] ++
      restore_metadata_details(transaction) ++ restore_cwd_details(transaction)
  end

  defp restore_worktree_detail(transaction) do
    case validate_registered_worktree(transaction.root, transaction.bare_dir, transaction.target) do
      :ok ->
        {:ok, "worktree remains registered at '#{transaction.target.path}'"}

      {:error, validation_error} ->
        if path_exists?(transaction.target.path) do
          {:error,
           "could not recreate worktree at '#{transaction.target.path}' because the path exists " <>
             "but is not the registered target (#{validation_error})"}
        else
          recreate_worktree(transaction)
        end
    end
  end

  defp recreate_worktree(transaction) do
    with :ok <- ensure_branch_for_rollback(transaction),
         {:ok, _output} <-
           Git.cmd(
             ["worktree", "add", "--", transaction.target.path, transaction.target.branch],
             cd: transaction.bare_dir
           ),
         :ok <-
           validate_registered_worktree(
             transaction.root,
             transaction.bare_dir,
             transaction.target
           ) do
      {:ok, "recreated worktree at '#{transaction.target.path}'"}
    else
      {:error, msg} ->
        {:error, "could not recreate worktree at '#{transaction.target.path}': #{msg}"}
    end
  end

  defp ensure_branch_for_rollback(transaction) do
    ref = "refs/heads/#{transaction.target.branch}"

    case Git.cmd(["show-ref", "--verify", "--quiet", ref], cd: transaction.bare_dir) do
      {:ok, _output} ->
        :ok

      {:error, ""} ->
        case Git.cmd(["update-ref", ref, transaction.target.oid], cd: transaction.bare_dir) do
          {:ok, _output} -> :ok
          {:error, msg} -> {:error, "could not restore branch ref '#{ref}': #{msg}"}
        end

      {:error, msg} ->
        {:error, "could not inspect branch ref '#{ref}': #{msg}"}
    end
  end

  defp restore_metadata_details(transaction) do
    restore_config_details(transaction) ++ restore_head_details(transaction)
  end

  defp restore_config_details(transaction) do
    if transaction.config_before == transaction.config_after do
      []
    else
      failures =
        [
          {@current_key, transaction.config_before.current},
          {@last_key, transaction.config_before.last}
        ]
        |> Enum.flat_map(fn {key, value} ->
          case write_config_value(transaction.bare_dir, key, value) do
            :ok -> []
            {:error, msg} -> ["could not restore checkout state '#{key}': #{msg}"]
          end
        end)

      case failures do
        [] -> [{:ok, "restored checkout state"}]
        failures -> Enum.map(failures, &{:error, &1})
      end
    end
  end

  defp restore_head_details(%{head_changed?: false}), do: []

  defp restore_head_details(transaction) do
    case Git.cmd(
           ["symbolic-ref", "HEAD", "refs/heads/#{transaction.old_head}"],
           cd: transaction.bare_dir
         ) do
      {:ok, _output} ->
        [{:ok, "restored bare HEAD to '#{transaction.old_head}'"}]

      {:error, msg} ->
        [{:error, "could not restore bare HEAD to '#{transaction.old_head}': #{msg}"}]
    end
  end

  defp restore_cwd_details(%{inside?: false}), do: []

  defp restore_cwd_details(transaction) do
    if Path.expand(File.cwd!()) == transaction.original_cwd do
      []
    else
      case File.cd(transaction.original_cwd) do
        :ok ->
          [{:ok, "restored process directory to '#{transaction.original_cwd}'"}]

        {:error, reason} ->
          [
            {:error,
             "could not restore process directory to '#{transaction.original_cwd}': " <>
               to_string(:file.format_error(reason))}
          ]
      end
    end
  end

  defp append_rollback(message, []), do: message

  defp append_rollback(message, details) do
    formatted =
      Enum.map_join(details, "\n", fn
        {:ok, detail} -> "rollback: #{detail}"
        {:error, detail} -> "rollback failed: #{detail}"
      end)

    message <> "\n" <> formatted
  end

  defp path_contains?(worktree_path, candidate_path) do
    relative = Path.relative_to(Path.expand(candidate_path), Path.expand(worktree_path))

    relative == "." or
      (Path.type(relative) == :relative and relative != ".." and
         not String.starts_with?(relative, "../"))
  end

  defp path_exists?(path), do: match?({:ok, _stat}, File.lstat(path))
end
