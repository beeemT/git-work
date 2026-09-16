defmodule GitWork.Commands.Sync do
  @moduledoc """
  Fetch from remote and prune worktrees whose remote tracking branch is gone.
  """

  alias GitWork.{Git, Output, Project}

  @usage "usage: git-work sync [--dry-run] [--force]"
  @accepted_arguments ["--dry-run", "-n", "--force", "-f"]
  @navigation_keys ["git-work.current-worktree", "git-work.last-worktree"]

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

  def run(args, _format) when is_list(args) do
    if Enum.all?(args, &(&1 in @accepted_arguments)) do
      dry_run? = "--dry-run" in args or "-n" in args
      force? = "--force" in args or "-f" in args

      with {:ok, root} <- Project.find_root() do
        do_sync(root, dry_run?, force?)
      end
    else
      {:error, @usage}
    end
  end

  def run(_args, _format), do: {:error, @usage}

  defp do_sync(root, dry_run?, force?) do
    bare_dir = Project.bare_path(root)

    Output.notify(:info, "fetching...")

    with :ok <- fetch_remotes(bare_dir, dry_run?),
         {:ok, head_branch} <- Project.head_branch(root),
         {:ok, worktrees} <- registered_worktrees(bare_dir),
         {:ok, tracked_worktrees} <-
           configured_remote_worktrees(
             bare_dir,
             eligible_worktrees(worktrees, root, head_branch)
           ),
         {:ok, stale} <- stale_worktrees(bare_dir, tracked_worktrees, dry_run?) do
      finish_sync(root, bare_dir, stale, dry_run?, force?)
    end
  end

  defp fetch_remotes(bare_dir, dry_run?) do
    args =
      if dry_run? do
        ["fetch", "--all", "--prune", "--dry-run"]
      else
        ["fetch", "--all", "--prune"]
      end

    case Git.cmd(args, cd: bare_dir) do
      {:ok, _} -> :ok
      {:error, msg} -> {:error, git_error("fetch failed", msg)}
    end
  end

  defp finish_sync(_root, _bare_dir, [], _dry_run?, _force?) do
    Output.notify(:info, "nothing to prune")
    {:ok, ""}
  end

  defp finish_sync(_root, bare_dir, stale, true, force?) do
    with :ok <- preflight_stale_worktrees(bare_dir, stale, force?) do
      Output.notify(:info, "would prune:")

      Enum.each(stale, fn candidate ->
        Output.notify(:info, "  #{candidate.branch} -> #{candidate.upstream_ref}")
      end)

      {:ok, ""}
    end
  end

  defp finish_sync(root, bare_dir, stale, false, force?) do
    with :ok <- preflight_stale_worktrees(bare_dir, stale, force?) do
      prune_worktrees(root, bare_dir, stale, force?)
    end
  end

  defp registered_worktrees(bare_dir) do
    case Git.cmd(["worktree", "list", "--porcelain", "-z"], cd: bare_dir) do
      {:ok, output} ->
        case parse_registered_worktrees(output) do
          {:ok, worktrees} -> {:ok, worktrees}
          {:error, msg} -> {:error, "failed to parse registered worktrees: #{msg}"}
        end

      {:error, msg} ->
        {:error, git_error("failed to list registered worktrees", msg)}
    end
  end

  defp parse_registered_worktrees(output) when is_binary(output) do
    if byte_size(output) < 2 or
         binary_part(output, byte_size(output) - 2, 2) != <<0, 0>> do
      {:error, "porcelain output is not terminated by a NUL record separator"}
    else
      parts = :binary.split(output, <<0, 0>>, [:global])
      {last, records} = List.pop_at(parts, -1)

      cond do
        last != "" ->
          {:error, "porcelain output has trailing data"}

        records == [] ->
          {:error, "porcelain output contains no worktree records"}

        Enum.any?(records, &(&1 == "")) ->
          {:error, "porcelain output contains an empty worktree record"}

        true ->
          records
          |> Enum.with_index(1)
          |> Enum.reduce_while({:ok, []}, fn {record, index}, {:ok, worktrees} ->
            case parse_worktree_record(record, index) do
              {:ok, worktree} -> {:cont, {:ok, [worktree | worktrees]}}
              {:error, _} = error -> {:halt, error}
            end
          end)
          |> case do
            {:ok, worktrees} ->
              worktrees = Enum.reverse(worktrees)

              case validate_unique_worktrees(worktrees) do
                :ok -> {:ok, worktrees}
                {:error, _} = error -> error
              end

            {:error, _} = error ->
              error
          end
      end
    end
  end

  defp parse_worktree_record(record, index) do
    case :binary.split(record, <<0>>, [:global]) do
      [<<"worktree ", path::binary>> | attributes] when byte_size(path) > 0 ->
        state = %{
          path: path,
          head: nil,
          branch: nil,
          detached?: false,
          bare?: false,
          locked?: false,
          prunable?: false
        }

        attributes
        |> Enum.reduce_while({:ok, state}, fn attribute, {:ok, current} ->
          case parse_worktree_attribute(attribute, current) do
            {:ok, updated} -> {:cont, {:ok, updated}}
            {:error, msg} -> {:halt, {:error, "record #{index}: #{msg}"}}
          end
        end)
        |> case do
          {:ok, parsed} -> finalize_worktree_record(parsed, index)
          {:error, _} = error -> error
        end

      _ ->
        {:error, "record #{index}: missing or invalid worktree path field"}
    end
  end

  defp parse_worktree_attribute(<<"HEAD ", oid::binary>>, state) when byte_size(oid) > 0,
    do: put_once(state, :head, oid, "HEAD")

  defp parse_worktree_attribute(<<"branch refs/heads/", branch::binary>>, state)
       when byte_size(branch) > 0,
       do: put_once(state, :branch, branch, "branch")

  defp parse_worktree_attribute("detached", state),
    do: put_flag_once(state, :detached?, "detached")

  defp parse_worktree_attribute("bare", state),
    do: put_flag_once(state, :bare?, "bare")

  defp parse_worktree_attribute("locked", state),
    do: put_flag_once(state, :locked?, "locked")

  defp parse_worktree_attribute(<<"locked ", reason::binary>>, state)
       when byte_size(reason) > 0,
       do: put_flag_once(state, :locked?, "locked")

  defp parse_worktree_attribute("prunable", state),
    do: put_flag_once(state, :prunable?, "prunable")

  defp parse_worktree_attribute(<<"prunable ", reason::binary>>, state)
       when byte_size(reason) > 0,
       do: put_flag_once(state, :prunable?, "prunable")

  defp parse_worktree_attribute(attribute, _state),
    do: {:error, "unknown or malformed field #{inspect(attribute)}"}

  defp put_once(state, key, value, label) do
    if Map.fetch!(state, key) == nil do
      {:ok, Map.put(state, key, value)}
    else
      {:error, "duplicate #{label} field"}
    end
  end

  defp put_flag_once(state, key, label) do
    if Map.fetch!(state, key) do
      {:error, "duplicate #{label} field"}
    else
      {:ok, Map.put(state, key, true)}
    end
  end

  defp finalize_worktree_record(state, index) do
    cond do
      Path.type(state.path) != :absolute ->
        {:error, "record #{index}: worktree path is not absolute"}

      state.bare? and
          (state.head != nil or state.branch != nil or state.detached?) ->
        {:error, "record #{index}: bare worktree has checkout fields"}

      state.bare? ->
        {:ok, state}

      state.head == nil ->
        {:error, "record #{index}: linked worktree is missing HEAD"}

      state.branch != nil and state.detached? ->
        {:error, "record #{index}: worktree is both attached and detached"}

      state.branch == nil and not state.detached? ->
        {:error, "record #{index}: worktree is missing branch or detached marker"}

      true ->
        {:ok, state}
    end
  end

  defp validate_unique_worktrees(worktrees) do
    paths = Enum.map(worktrees, & &1.path)
    branches = worktrees |> Enum.map(& &1.branch) |> Enum.reject(&is_nil/1)

    cond do
      length(paths) != length(Enum.uniq(paths)) ->
        {:error, "porcelain output contains duplicate worktree paths"}

      length(branches) != length(Enum.uniq(branches)) ->
        {:error, "porcelain output contains duplicate attached branches"}

      true ->
        :ok
    end
  end

  defp eligible_worktrees(worktrees, root, head_branch) do
    root = Path.expand(root)
    bare_path = Path.expand(Project.bare_path(root))
    default_worktree_path = Path.expand(Project.worktree_path(root, head_branch))

    Enum.filter(worktrees, fn worktree ->
      path = Path.expand(worktree.path)

      not worktree.bare? and
        not worktree.detached? and
        is_binary(worktree.branch) and
        worktree.branch != head_branch and
        path != bare_path and
        path != default_worktree_path and
        Path.dirname(path) == root
    end)
  end

  defp configured_remote_worktrees(bare_dir, worktrees) do
    worktrees
    |> Enum.reduce_while({:ok, []}, fn worktree, {:ok, tracked} ->
      case configured_upstream(bare_dir, worktree.branch) do
        {:ok, :none} ->
          {:cont, {:ok, tracked}}

        {:ok, :local} ->
          {:cont, {:ok, tracked}}

        {:ok, {:remote, upstream_ref, remote, remote_ref}} ->
          candidate =
            worktree
            |> Map.put(:dir_name, Path.basename(worktree.path))
            |> Map.put(:upstream_ref, upstream_ref)
            |> Map.put(:remote, remote)
            |> Map.put(:remote_ref, remote_ref)

          {:cont, {:ok, [candidate | tracked]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, tracked} -> {:ok, Enum.reverse(tracked)}
      {:error, _} = error -> error
    end
  end

  defp configured_upstream(bare_dir, branch) do
    remote_key = "branch.#{branch}.remote"
    merge_key = "branch.#{branch}.merge"

    with {:ok, remotes} <- read_config_values(bare_dir, remote_key),
         {:ok, merges} <- read_config_values(bare_dir, merge_key) do
      case {remotes, merges} do
        {[], []} ->
          {:ok, :none}

        {[remote], [merge]} when remote != "" and merge != "" ->
          with :ok <- validate_merge_ref(bare_dir, branch, merge),
               {:ok, upstream_ref, resolved_remote, remote_ref} <-
                 resolve_configured_upstream(bare_dir, branch) do
            if resolved_remote == remote and remote_ref == merge do
              if remote == "." do
                {:ok, :local}
              else
                {:ok, {:remote, upstream_ref, remote, remote_ref}}
              end
            else
              {:error,
               "malformed upstream config for branch '#{branch}': configured " <>
                 "#{remote}:#{merge}, resolved #{resolved_remote}:#{remote_ref}"}
            end
          end

        _ ->
          {:error,
           "malformed upstream config for branch '#{branch}': expected exactly one " <>
             "branch remote and merge ref"}
      end
    else
      {:error, msg} ->
        {:error, "failed to read upstream config for branch '#{branch}': #{msg}"}
    end
  end

  defp validate_merge_ref(bare_dir, branch, merge) do
    if String.starts_with?(merge, "refs/heads/") do
      case Git.cmd(["check-ref-format", merge], cd: bare_dir) do
        {:ok, _} ->
          :ok

        {:error, msg} ->
          {:error,
           git_error("malformed upstream merge ref '#{merge}' for branch '#{branch}'", msg)}
      end
    else
      {:error,
       "malformed upstream merge ref '#{merge}' for branch '#{branch}': " <>
         "expected refs/heads/<branch>"}
    end
  end

  defp resolve_configured_upstream(bare_dir, branch) do
    local_ref = "refs/heads/#{branch}"

    format =
      "%(refname)%09%(upstream)%09%(upstream:remotename)%09" <>
        "%(upstream:remoteref)%09END"

    case Git.cmd(["for-each-ref", "--format=#{format}", local_ref], cd: bare_dir) do
      {:ok, output} ->
        with {:ok, rows} <- parse_upstream_rows(output),
             [row] <- Enum.filter(rows, &(&1.local_ref == local_ref)),
             true <- row.upstream_ref != "",
             true <- row.remote != "",
             true <- row.remote_ref != "" do
          {:ok, row.upstream_ref, row.remote, row.remote_ref}
        else
          [] ->
            {:error,
             "malformed upstream config for branch '#{branch}': local branch was not found"}

          [_ | _] ->
            {:error,
             "malformed upstream config for branch '#{branch}': duplicate local branch rows"}

          false ->
            {:error,
             "malformed upstream config for branch '#{branch}': upstream could not be resolved"}

          {:error, msg} ->
            {:error, "failed to parse upstream for branch '#{branch}': #{msg}"}
        end

      {:error, msg} ->
        {:error, git_error("failed to resolve upstream for branch '#{branch}'", msg)}
    end
  end

  defp parse_upstream_rows(""), do: {:ok, []}

  defp parse_upstream_rows(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, rows} ->
      case :binary.split(line, <<9>>, [:global]) do
        [local_ref, upstream_ref, remote, remote_ref, "END"] ->
          row = %{
            local_ref: local_ref,
            upstream_ref: upstream_ref,
            remote: remote,
            remote_ref: remote_ref
          }

          {:cont, {:ok, [row | rows]}}

        _ ->
          {:halt, {:error, "unexpected for-each-ref row #{inspect(line)}"}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      {:error, _} = error -> error
    end
  end

  defp read_config_values(bare_dir, key) do
    case Git.cmd(["config", "--null", "--get-all", key], cd: bare_dir) do
      {:ok, output} -> parse_nul_values(output)
      {:error, ""} -> {:ok, []}
      {:error, msg} -> {:error, git_error("git config --get-all #{key} failed", msg)}
    end
  end

  defp parse_nul_values(""), do: {:ok, [""]}

  defp parse_nul_values(output) do
    if :binary.last(output) == 0 do
      body = binary_part(output, 0, byte_size(output) - 1)
      {:ok, :binary.split(body, <<0>>, [:global])}
    else
      {:error, "git config returned malformed NUL-delimited output"}
    end
  end

  defp stale_worktrees(_bare_dir, [], _dry_run?), do: {:ok, []}

  defp stale_worktrees(bare_dir, tracked_worktrees, false) do
    case Git.cmd(["for-each-ref", "--format=%(refname)"], cd: bare_dir) do
      {:ok, output} ->
        refs = output |> String.split("\n", trim: true) |> MapSet.new()
        {:ok, Enum.reject(tracked_worktrees, &MapSet.member?(refs, &1.upstream_ref))}

      {:error, msg} ->
        {:error, git_error("failed to enumerate refs after fetch", msg)}
    end
  end

  defp stale_worktrees(bare_dir, tracked_worktrees, true) do
    remotes = tracked_worktrees |> Enum.map(& &1.remote) |> Enum.uniq() |> Enum.sort()

    with {:ok, remote_refs} <- remote_refs(bare_dir, remotes) do
      stale =
        Enum.reject(tracked_worktrees, fn worktree ->
          remote_refs
          |> Map.fetch!(worktree.remote)
          |> MapSet.member?(worktree.remote_ref)
        end)

      {:ok, stale}
    end
  end

  defp remote_refs(bare_dir, remotes) do
    Enum.reduce_while(remotes, {:ok, %{}}, fn remote, {:ok, refs_by_remote} ->
      case Git.cmd(["ls-remote", "--refs", remote], cd: bare_dir) do
        {:ok, output} ->
          case parse_ls_remote(output, remote) do
            {:ok, refs} -> {:cont, {:ok, Map.put(refs_by_remote, remote, refs)}}
            {:error, _} = error -> {:halt, error}
          end

        {:error, msg} ->
          {:halt, {:error, git_error("failed to inspect remote '#{remote}'", msg)}}
      end
    end)
  end

  defp parse_ls_remote("", _remote), do: {:ok, MapSet.new()}

  defp parse_ls_remote(output, remote) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, MapSet.new()}, fn line, {:ok, refs} ->
      case :binary.split(line, <<9>>, [:global]) do
        [oid, ref] when byte_size(oid) > 0 and byte_size(ref) > 0 ->
          {:cont, {:ok, MapSet.put(refs, ref)}}

        _ ->
          {:halt, {:error, "failed to parse refs from remote '#{remote}': #{inspect(line)}"}}
      end
    end)
  end

  defp preflight_stale_worktrees(bare_dir, stale, force?) do
    with :ok <- ensure_cwd_outside_candidates(stale),
         :ok <- ensure_candidates_clean(stale),
         :ok <- ensure_candidates_merged(bare_dir, stale, force?) do
      :ok
    end
  end

  defp ensure_cwd_outside_candidates(stale) do
    cwd = File.cwd!()
    inside = Enum.filter(stale, &path_contains?(&1.path, cwd))

    case inside do
      [] ->
        :ok

      candidates ->
        names = Enum.map_join(candidates, ", ", &"'#{&1.dir_name}'")
        {:error, "refusing to prune while the current directory is inside #{names}"}
    end
  end

  defp path_contains?(worktree_path, path) do
    relative = Path.relative_to(Path.expand(path), Path.expand(worktree_path))

    relative == "." or
      (Path.type(relative) == :relative and relative != ".." and
         not String.starts_with?(relative, "../"))
  end

  defp ensure_candidates_clean(stale) do
    Enum.reduce_while(stale, :ok, fn candidate, :ok ->
      cond do
        not File.exists?(candidate.path) or
            not match?({:ok, %File.Stat{type: :directory}}, File.lstat(candidate.path)) ->
          {:halt,
           {:error,
            "refusing to prune '#{candidate.branch}': worktree directory " <>
              "'#{candidate.path}' does not exist"}}

        true ->
          case Git.cmd(
                 [
                   "status",
                   "--porcelain=v1",
                   "--untracked-files=all",
                   "--ignored=matching",
                   "--ignore-submodules=none"
                 ],
                 cd: candidate.path
               ) do
            {:ok, ""} ->
              {:cont, :ok}

            {:ok, _changes} ->
              {:halt,
               {:error,
                "refusing to prune '#{candidate.branch}': worktree has staged, " <>
                  "unstaged, or untracked changes"}}

            {:error, msg} ->
              {:halt,
               {:error, git_error("failed to inspect worktree '#{candidate.branch}'", msg)}}
          end
      end
    end)
  end

  defp ensure_candidates_merged(_bare_dir, _stale, true), do: :ok

  defp ensure_candidates_merged(bare_dir, stale, false) do
    case Git.cmd(
           ["for-each-ref", "--merged=HEAD", "--format=%(refname)", "refs/heads"],
           cd: bare_dir
         ) do
      {:ok, output} ->
        merged_refs = output |> String.split("\n", trim: true) |> MapSet.new()

        unmerged =
          Enum.reject(stale, fn candidate ->
            MapSet.member?(merged_refs, "refs/heads/#{candidate.branch}")
          end)

        case unmerged do
          [] ->
            :ok

          candidates ->
            branches = Enum.map_join(candidates, ", ", &"'#{&1.branch}'")

            {:error,
             "refusing to prune unmerged branches #{branches}; use --force to bypass " <>
               "branch merge protection"}
        end

      {:error, msg} ->
        {:error, git_error("failed to check whether stale branches are merged", msg)}
    end
  end

  defp prune_worktrees(_root, bare_dir, stale, force?) do
    {successful, removed_names, action_error} = remove_candidates(bare_dir, stale, force?)
    config_errors = clear_removed_navigation_config(bare_dir, removed_names)

    errors =
      List.wrap(action_error) ++
        config_errors

    case errors do
      [] ->
        Output.notify(:info, "pruned #{length(successful)} worktree(s)")
        {:ok, ""}

      errors ->
        prefix =
          case successful do
            [] -> []
            _ -> ["pruned #{length(successful)} worktree(s) before sync failed"]
          end

        {:error, Enum.join(prefix ++ errors, "\n")}
    end
  end

  defp remove_candidates(bare_dir, stale, force?) do
    {successful, removed_names, error} =
      Enum.reduce_while(stale, {[], [], nil}, fn candidate, {successful, removed_names, nil} ->
        case remove_candidate(bare_dir, candidate, force?) do
          :ok ->
            {:cont, {[candidate | successful], [candidate.dir_name | removed_names], nil}}

          {:error, msg, removed?} ->
            removed_names =
              if removed?, do: [candidate.dir_name | removed_names], else: removed_names

            {:halt, {successful, removed_names, msg}}
        end
      end)

    {Enum.reverse(successful), Enum.reverse(removed_names), error}
  end

  defp remove_candidate(bare_dir, candidate, force?) do
    case Git.cmd(["worktree", "remove", "--", candidate.path], cd: bare_dir) do
      {:ok, _} ->
        delete_flag = if force?, do: "-D", else: "-d"

        case Git.cmd(["branch", delete_flag, "--", candidate.branch], cd: bare_dir) do
          {:ok, _} ->
            :ok

          {:error, delete_msg} ->
            rollback_deleted_worktree(bare_dir, candidate, delete_msg)
        end

      {:error, msg} ->
        {:error, git_error("failed to remove worktree '#{candidate.branch}'", msg), false}
    end
  end

  defp rollback_deleted_worktree(bare_dir, candidate, delete_msg) do
    delete_error = git_error("failed to delete branch '#{candidate.branch}'", delete_msg)

    case Git.cmd(["worktree", "add", "--", candidate.path, candidate.branch], cd: bare_dir) do
      {:ok, _} ->
        {:error, "#{delete_error}; recreated worktree '#{candidate.dir_name}'", false}

      {:error, rollback_msg} ->
        {:error,
         "#{delete_error}\n" <>
           git_error(
             "rollback failed to recreate worktree '#{candidate.dir_name}'",
             rollback_msg
           ), true}
    end
  end

  defp clear_removed_navigation_config(_bare_dir, []), do: []

  defp clear_removed_navigation_config(bare_dir, removed_names) do
    removed_names = MapSet.new(removed_names)

    Enum.flat_map(@navigation_keys, fn key ->
      case read_config_values(bare_dir, key) do
        {:ok, values} ->
          values
          |> Enum.filter(&MapSet.member?(removed_names, &1))
          |> Enum.uniq()
          |> Enum.flat_map(fn value ->
            case Git.cmd(
                   ["config", "--fixed-value", "--unset-all", key, value],
                   cd: bare_dir
                 ) do
              {:ok, _} ->
                []

              {:error, msg} ->
                [git_error("failed to clear #{key} value '#{value}'", msg)]
            end
          end)

        {:error, msg} ->
          ["failed to read #{key} while clearing removed worktrees: #{msg}"]
      end
    end)
  end

  defp git_error(prefix, ""), do: prefix
  defp git_error(prefix, message), do: "#{prefix}: #{message}"
end
