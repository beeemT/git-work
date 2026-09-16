defmodule GitWork.Project do
  @moduledoc """
  Project root discovery, path helpers, branch name sanitization,
  and shared configuration for bare repos and worktrees.
  """

  alias GitWork.Git
  @max_symlink_depth 40

  @doc """
  Find the project root by walking up from `start_dir` looking for `.bare/`.
  Returns {:ok, path} or {:error, message}.
  """
  def find_root(start_dir \\ File.cwd!()) do
    find_root_up(Path.expand(start_dir))
  end

  defp find_root_up("/"), do: {:error, "not a git-work project (no .bare/ found)"}

  defp find_root_up(dir) do
    if bare_directory?(Path.join(dir, ".bare")) do
      {:ok, dir}
    else
      find_root_up(Path.dirname(dir))
    end
  end

  defp bare_directory?(path) do
    match?({:ok, %File.Stat{type: :directory}}, File.lstat(path))
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
  List registered direct-child worktree directory names in the project root.

  This is derived from Git's worktree registry instead of the filesystem, so
  ordinary directories and symlinks are never treated as worktrees.
  """
  def worktree_dirs(project_root) do
    with {:ok, project_root} <- canonical_directory_path(project_root),
         {:ok, worktrees} <- registered_worktrees(project_root) do
      worktrees
      |> Enum.filter(fn worktree ->
        case canonical_directory_path(worktree.path) do
          {:ok, worktree_path} ->
            not worktree.bare? and
              is_binary(worktree.branch) and
              Path.dirname(worktree_path) == project_root and
              match?({:ok, %File.Stat{type: :directory}}, File.lstat(worktree.path))

          {:error, _reason} ->
            false
        end
      end)
      |> Enum.map(&Path.basename(&1.path))
    else
      _ -> []
    end
  end

  @doc """
  Resolve a directory path to an absolute path with symlinks resolved.
  """
  def canonical_directory_path(path), do: canonical_directory_path(Path.expand(path), 0)

  defp canonical_directory_path("/", _depth), do: {:ok, "/"}

  defp canonical_directory_path(_path, depth) when depth >= @max_symlink_depth,
    do: {:error, :eloop}

  defp canonical_directory_path(path, depth) do
    case :file.read_link(path) do
      {:ok, target} ->
        target = to_string(target)

        target =
          if Path.type(target) == :absolute do
            Path.expand(target)
          else
            Path.expand(target, Path.dirname(path))
          end

        canonical_directory_path(target, depth + 1)

      {:error, :einval} ->
        with {:ok, canonical_parent} <-
               canonical_directory_path(Path.dirname(path), depth) do
          {:ok, Path.join(canonical_parent, Path.basename(path))}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Return Git's registered worktrees for the project.

  Each entry contains `:path`, `:branch`, `:bare?`, `:detached?`, `:locked?`,
  and `:prunable?`. A malformed registry is returned as an error instead of
  being silently interpreted as filesystem state.
  """
  def registered_worktrees(project_root) do
    bare_dir = bare_path(project_root)

    case File.lstat(bare_dir) do
      {:ok, %File.Stat{type: :directory}} ->
        case Git.cmd(["worktree", "list", "--porcelain", "-z"], cd: bare_dir) do
          {:ok, output} -> parse_registered_worktrees(output)
          {:error, message} -> {:error, "failed to list registered worktrees: #{message}"}
        end

      {:ok, %File.Stat{type: type}} ->
        {:error, "repository metadata path '#{bare_dir}' is #{type}, not a directory"}

      {:error, reason} ->
        {:error, "failed to inspect repository metadata path '#{bare_dir}': #{reason}"}
    end
  end

  defp parse_registered_worktrees(output) do
    records = :binary.split(output, <<0, 0>>, [:global])

    case List.pop_at(records, -1) do
      {"", records} when records != [] ->
        records
        |> Enum.with_index(1)
        |> Enum.reduce_while({:ok, []}, fn {record, index}, {:ok, entries} ->
          case parse_worktree_record(record, index) do
            {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
            {:error, _} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, entries} ->
            entries = Enum.reverse(entries)
            validate_registered_worktrees(entries)

          {:error, _} = error ->
            error
        end

      _ ->
        {:error, "malformed worktree registry output"}
    end
  end

  defp parse_worktree_record(record, index) do
    fields = :binary.split(record, <<0>>, [:global])

    case fields do
      [<<"worktree ", path::binary>> | attributes] when path != "" ->
        state = %{
          path: Path.expand(path),
          head: nil,
          branch: nil,
          bare?: false,
          detached?: false,
          locked?: false,
          prunable?: false
        }

        Enum.reduce_while(attributes, {:ok, state}, fn field, {:ok, current} ->
          case field do
            <<"HEAD ", oid::binary>> ->
              if valid_object_id?(oid) do
                case put_once(current, :head, oid, "HEAD") do
                  {:ok, updated} -> {:cont, {:ok, updated}}
                  {:error, message} -> {:halt, {:error, "record #{index} #{message}"}}
                end
              else
                {:halt, {:error, "record #{index} contains an invalid HEAD object id"}}
              end

            <<"branch refs/heads/", branch::binary>> when branch != "" ->
              case put_once(current, :branch, branch, "branch") do
                {:ok, updated} -> {:cont, {:ok, updated}}
                {:error, message} -> {:halt, {:error, "record #{index} #{message}"}}
              end

            "bare" ->
              case put_flag_once(current, :bare?, "bare") do
                {:ok, updated} -> {:cont, {:ok, updated}}
                {:error, message} -> {:halt, {:error, "record #{index} #{message}"}}
              end

            "detached" ->
              case put_flag_once(current, :detached?, "detached") do
                {:ok, updated} -> {:cont, {:ok, updated}}
                {:error, message} -> {:halt, {:error, "record #{index} #{message}"}}
              end

            "locked" ->
              case put_flag_once(current, :locked?, "locked") do
                {:ok, updated} -> {:cont, {:ok, updated}}
                {:error, message} -> {:halt, {:error, "record #{index} #{message}"}}
              end

            <<"locked ", reason::binary>> when reason != "" ->
              case put_flag_once(current, :locked?, "locked") do
                {:ok, updated} -> {:cont, {:ok, updated}}
                {:error, message} -> {:halt, {:error, "record #{index} #{message}"}}
              end

            "prunable" ->
              case put_flag_once(current, :prunable?, "prunable") do
                {:ok, updated} -> {:cont, {:ok, updated}}
                {:error, message} -> {:halt, {:error, "record #{index} #{message}"}}
              end

            <<"prunable ", reason::binary>> when reason != "" ->
              case put_flag_once(current, :prunable?, "prunable") do
                {:ok, updated} -> {:cont, {:ok, updated}}
                {:error, message} -> {:halt, {:error, "record #{index} #{message}"}}
              end

            "" ->
              {:cont, {:ok, current}}

            _unknown ->
              {:halt, {:error, "record #{index} contains an unknown field"}}
          end
        end)
        |> finalize_worktree_record(index)

      _ ->
        {:error, "record #{index} is missing a worktree path"}
    end
  end

  defp put_once(state, key, value, label) do
    if Map.fetch!(state, key) == nil do
      {:ok, Map.put(state, key, value)}
    else
      {:error, "contains duplicate #{label} field"}
    end
  end

  defp put_flag_once(state, key, label) do
    if Map.fetch!(state, key) do
      {:error, "contains duplicate #{label} field"}
    else
      {:ok, Map.put(state, key, true)}
    end
  end

  defp valid_object_id?(oid) do
    byte_size(oid) in [40, 64] and
      String.match?(oid, ~r/\A[0-9a-fA-F]+\z/)
  end

  defp finalize_worktree_record({:ok, entry}, _index) do
    cond do
      entry.bare? and
          (not is_nil(entry.head) or not is_nil(entry.branch) or entry.detached?) ->
        {:error, "bare worktree record contains checkout state"}

      not entry.bare? and is_nil(entry.branch) and not entry.detached? ->
        {:error, "linked worktree record has no branch or detached state"}

      true ->
        {:ok, entry}
    end
  end

  defp finalize_worktree_record({:error, _} = error, _index), do: error

  defp validate_registered_worktrees(worktrees) do
    paths = Enum.map(worktrees, & &1.path)
    branches = worktrees |> Enum.map(& &1.branch) |> Enum.reject(&is_nil/1)

    cond do
      length(paths) != length(Enum.uniq(paths)) ->
        {:error, "worktree registry contains duplicate paths"}

      length(branches) != length(Enum.uniq(branches)) ->
        {:error, "worktree registry contains duplicate branches"}

      true ->
        {:ok, worktrees}
    end
  end

  @doc """
  Derive a directory name from a clone URL, same logic as `git clone`.
  Trailing POSIX or Windows path separators are ignored before extracting the basename.
  """
  def dir_from_url(url) do
    url
    |> String.trim()
    |> String.replace(~r{[\\/]+\z}, "")
    |> String.split(~r{[\\/]}, trim: true)
    |> List.last()
    |> case do
      nil ->
        ""

      basename ->
        basename = String.split(basename, ":") |> List.last()
        String.replace_suffix(basename, ".git", "")
    end
  end

  @doc """
  Determine the HEAD branch of the bare repo (usually main or master).
  """
  def head_branch(project_root) do
    case Git.current_branch(bare_path(project_root)) do
      {:ok, branch} -> {:ok, branch}
      {:error, _} -> {:error, "could not determine HEAD branch"}
    end
  end

  @doc """
  Configure the bare repo: mark as bare, enable push.autoSetupRemote,
  and ensure each configured remote has the standard heads fetch refspec.
  """
  def configure_bare(bare_dir) do
    with :ok <- set_config(bare_dir, "core.bare", "true"),
         :ok <- set_config(bare_dir, "push.autoSetupRemote", "true"),
         :ok <- configure_remote_fetch(bare_dir) do
      :ok
    end
  end

  defp set_config(bare_dir, key, value) do
    case Git.cmd(["config", key, value], cd: bare_dir) do
      {:ok, _output} -> :ok
      {:error, message} -> {:error, "failed to configure #{key}: #{message}"}
    end
  end

  defp configure_remote_fetch(bare_dir) do
    case Git.cmd(["remote"], cd: bare_dir) do
      {:ok, output} ->
        remotes = String.split(output, "\n", trim: true)

        Enum.reduce_while(remotes, :ok, fn remote, :ok ->
          case ensure_remote_fetch(bare_dir, remote) do
            :ok -> {:cont, :ok}
            {:error, message} -> {:halt, {:error, message}}
          end
        end)

      {:error, message} ->
        {:error, "failed to inspect configured remotes: #{message}"}
    end
  end

  defp ensure_remote_fetch(bare_dir, remote) do
    key = "remote.#{remote}.fetch"
    required = "+refs/heads/*:refs/remotes/#{remote}/*"

    case Git.cmd(["config", "--null", "--get-all", key], cd: bare_dir) do
      {:ok, output} ->
        if required in String.split(output, <<0>>, trim: true) do
          :ok
        else
          add_config(bare_dir, key, required)
        end

      {:error, ""} ->
        add_config(bare_dir, key, required)

      {:error, message} ->
        {:error, "failed to inspect fetch mappings for remote '#{remote}': #{message}"}
    end
  end

  defp add_config(bare_dir, key, value) do
    case Git.cmd(["config", "--add", key, value], cd: bare_dir) do
      {:ok, _output} -> :ok
      {:error, message} -> {:error, "failed to configure #{key}: #{message}"}
    end
  end

  @doc """
  Set upstream tracking for a branch if exactly one configured remote has a
  matching remote-tracking ref. Existing upstreams are preserved; local-only
  branches and ambiguous remote matches are never guessed.
  """
  def ensure_upstream(worktree_dir, branch) do
    case Git.cmd(["rev-parse", "--symbolic-full-name", "@{u}"],
           cd: worktree_dir
         ) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        case matching_remote_refs(worktree_dir, branch) do
          {:ok, []} ->
            :ok

          {:ok, [{remote, remote_branch}]} ->
            upstream = "refs/remotes/#{remote}/#{remote_branch}"

            case Git.cmd(
                   ["branch", "--set-upstream-to=#{upstream}", "--", branch],
                   cd: worktree_dir
                 ) do
              {:ok, _} ->
                :ok

              {:error, message} ->
                {:error, "failed to set upstream for #{branch}: #{message}"}
            end

          {:ok, matches} ->
            formatted =
              Enum.map_join(matches, ", ", fn {remote, remote_branch} ->
                "#{remote}/#{remote_branch}"
              end)

            {:error,
             "cannot choose an upstream for #{branch}; matching remote branches: #{formatted}"}

          {:error, message} ->
            {:error, message}
        end
    end
  end

  defp matching_remote_refs(worktree_dir, branch) do
    with {:ok, remote_output} <- Git.cmd(["remote"], cd: worktree_dir),
         {:ok, ref_output} <-
           Git.cmd(["for-each-ref", "--format=%(refname)", "refs/remotes"],
             cd: worktree_dir
           ) do
      refs =
        ref_output
        |> String.split("\n", trim: true)
        |> MapSet.new()

      matches =
        remote_output
        |> String.split("\n", trim: true)
        |> Enum.sort()
        |> Enum.flat_map(fn remote ->
          full_ref = "refs/remotes/#{remote}/#{branch}"

          if branch != "HEAD" and MapSet.member?(refs, full_ref) do
            [{remote, branch}]
          else
            []
          end
        end)

      {:ok, matches}
    else
      {:error, message} ->
        {:error, "failed to enumerate remote branches: #{message}"}
    end
  end
end
