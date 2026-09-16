defmodule GitWork.Commands.Clone do
  @moduledoc """
  Clone a repository into the worktree-based layout.
  """

  alias GitWork.{Git, Project}

  @usage "usage: git-work clone <url> [<directory>]"
  @gitdir_pointer "gitdir: ./.bare\n"
  @owner_marker ".git-work-clone-owner"

  def help do
    """
    usage: git-work clone <url> [<directory>]

    Clone a repository into the worktree-based layout.

    Creates a bare clone in <directory>/.bare, writes a .git pointer file,
    and sets up the initial worktree for the HEAD branch (usually main).

    If <directory> is omitted, it is derived from the URL (same as git clone).

    Examples:
      git-work clone git@github.com:org/repo.git
      git-work clone https://github.com/org/repo.git my-project
    """
  end

  def run([url], _format) when is_binary(url) do
    with :ok <- validate_nonempty(url, "clone URL"),
         :ok <- validate_not_option_like(url, "clone URL"),
         {:ok, dir} <- derive_destination(url) do
      do_clone(url, dir)
    end
  end

  def run([url, dir], _format) when is_binary(url) and is_binary(dir) do
    with :ok <- validate_nonempty(url, "clone URL"),
         :ok <- validate_not_option_like(url, "clone URL"),
         :ok <- validate_nonempty(dir, "destination directory") do
      do_clone(url, dir)
    end
  end

  def run(_args, _format), do: {:error, @usage}

  defp validate_nonempty(value, label) do
    if String.trim(value) == "" do
      {:error, "#{label} must not be empty"}
    else
      :ok
    end
  end

  defp validate_not_option_like(value, label) do
    if String.starts_with?(value, "-") do
      {:error, "#{label} must not start with '-'"}
    else
      :ok
    end
  end

  defp derive_destination(url) do
    case Project.dir_from_url(url) do
      name when name in ["", ".", ".."] ->
        {:error, "could not derive a valid destination directory from clone URL"}

      name ->
        {:ok, name}
    end
  end

  defp do_clone(url, dir) do
    with {:ok, destination} <- prepare_destination(dir),
         :ok <- ensure_destination_absent(destination),
         {:ok, staging_dir, owner_token} <- create_staging_directory(destination) do
      build_and_publish(url, staging_dir, destination, owner_token)
    end
  end

  defp prepare_destination(dir) do
    destination = Path.expand(dir)
    parent = Path.dirname(destination)

    case File.mkdir_p(parent) do
      :ok ->
        case Project.canonical_directory_path(parent) do
          {:ok, canonical_parent} ->
            {:ok, Path.join(canonical_parent, Path.basename(destination))}

          {:error, reason} ->
            {:error, "failed to resolve destination parent '#{parent}': #{format_reason(reason)}"}
        end

      {:error, reason} ->
        {:error, "failed to create destination parent '#{parent}': #{format_reason(reason)}"}
    end
  end

  defp build_and_publish(url, staging_dir, destination, owner_token) do
    try do
      case build_staged_clone(url, staging_dir) do
        {:ok, branch} ->
          publish_staged_clone(staging_dir, destination, branch, owner_token)

        {:error, message} ->
          fail_with_cleanup(message, staging_dir, owner_token)
      end
    rescue
      exception ->
        fail_with_cleanups(
          "clone failed unexpectedly: #{Exception.message(exception)}",
          [staging_dir, destination],
          owner_token
        )
    catch
      kind, reason ->
        fail_with_cleanups(
          "clone aborted unexpectedly (#{kind}): #{inspect(reason)}",
          [staging_dir, destination],
          owner_token
        )
    end
  end

  defp build_staged_clone(url, dir) do
    bare_dir = Project.bare_path(dir)

    with :ok <- clone_bare(url, bare_dir),
         {:ok, branch} <- detect_head_branch(bare_dir),
         :ok <- fix_head(bare_dir, branch),
         :ok <- write_gitdir_pointer(dir),
         :ok <- configure_bare(bare_dir),
         :ok <- fetch_refs(bare_dir),
         :ok <- add_main_worktree(dir, branch),
         :ok <- ensure_upstream(dir, branch),
         :ok <- validate_layout(dir, branch) do
      {:ok, branch}
    end
  end

  defp publish_staged_clone(staging_dir, destination, branch, owner_token) do
    with :ok <- prepare_worktree_metadata(staging_dir, destination, branch) do
      case reserve_destination(destination, owner_token) do
        :ok ->
          publish_into_reserved_destination(
            staging_dir,
            destination,
            branch,
            owner_token
          )

        {:error, message} ->
          fail_with_cleanup(message, staging_dir, owner_token)
      end
    else
      {:error, message} -> fail_with_cleanup(message, staging_dir, owner_token)
    end
  end

  defp publish_into_reserved_destination(staging_dir, destination, branch, owner_token) do
    result =
      with :ok <- move_staged_entries(staging_dir, destination, branch),
           :ok <- validate_layout(destination, branch),
           :ok <- remove_staging_directory(staging_dir, owner_token),
           :ok <- remove_owner_marker(destination, owner_token) do
        {:ok, Project.worktree_path(destination, branch)}
      end

    case result do
      {:ok, worktree_dir} ->
        {:ok, worktree_dir}

      {:error, message} ->
        fail_with_cleanups(message, [destination, staging_dir], owner_token)
    end
  end

  defp ensure_destination_absent(destination) do
    case File.lstat(destination) do
      {:error, :enoent} ->
        :ok

      {:ok, _stat} ->
        {:error, "destination '#{destination}' already exists"}

      {:error, reason} ->
        {:error, "failed to inspect destination '#{destination}': #{format_reason(reason)}"}
    end
  end

  defp create_staging_directory(destination) do
    owner_token = owner_token()
    staging_dir = Path.join(Path.dirname(destination), ".git-work-clone-#{owner_token}")

    case File.mkdir(staging_dir) do
      :ok ->
        case write_owner_marker(staging_dir, owner_token) do
          :ok ->
            {:ok, staging_dir, owner_token}

          {:error, message} ->
            fail_created_directory(message, staging_dir)
        end

      {:error, :eexist} ->
        create_staging_directory(destination)

      {:error, reason} ->
        {:error,
         "failed to create clone staging directory beside '#{destination}': #{format_reason(reason)}"}
    end
  end

  defp reserve_destination(destination, owner_token) do
    case File.mkdir(destination) do
      :ok ->
        case write_owner_marker(destination, owner_token) do
          :ok -> :ok
          {:error, message} -> fail_created_directory(message, destination)
        end

      {:error, :eexist} ->
        {:error, "destination '#{destination}' already exists"}

      {:error, reason} ->
        {:error, "failed to create destination '#{destination}': #{format_reason(reason)}"}
    end
  end

  defp write_owner_marker(dir, owner_token) do
    case File.write(Path.join(dir, @owner_marker), owner_token, [:exclusive]) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "failed to mark invocation-owned directory '#{dir}': #{format_reason(reason)}"}
    end
  end

  defp owner_token do
    "#{:os.getpid()}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp fail_created_directory(message, dir) do
    marker = Path.join(dir, @owner_marker)

    marker_error =
      case File.rm(marker) do
        :ok -> nil
        {:error, :enoent} -> nil
        {:error, reason} -> "could not remove marker '#{marker}': #{format_reason(reason)}"
      end

    directory_error =
      case File.rmdir(dir) do
        :ok -> nil
        {:error, reason} -> "could not remove '#{dir}': #{format_reason(reason)}"
      end

    case Enum.reject([marker_error, directory_error], &is_nil/1) do
      [] -> {:error, message}
      errors -> {:error, "#{message}; cleanup failed: #{Enum.join(errors, "; ")}"}
    end
  end

  defp clone_bare(url, bare_dir) do
    case Git.cmd(["clone", "--bare", "--", url, bare_dir]) do
      {:ok, _output} -> :ok
      {:error, message} -> {:error, "clone failed: #{message}"}
    end
  end

  defp write_gitdir_pointer(dir) do
    case File.write(Path.join(dir, ".git"), @gitdir_pointer, [:exclusive]) do
      :ok -> :ok
      {:error, reason} -> {:error, "failed to write .git pointer: #{format_reason(reason)}"}
    end
  end

  defp configure_bare(bare_dir) do
    case Project.configure_bare(bare_dir) do
      :ok -> :ok
      {:error, message} -> {:error, "bare repository configuration failed: #{message}"}
    end
  end

  defp fetch_refs(bare_dir) do
    case Git.cmd(["fetch", "--all"], cd: bare_dir) do
      {:ok, _output} -> :ok
      {:error, message} -> {:error, "fetch failed: #{message}"}
    end
  end

  defp fix_head(bare_dir, branch) do
    case Git.cmd(["symbolic-ref", "HEAD", "refs/heads/#{branch}"], cd: bare_dir) do
      {:ok, _output} -> :ok
      {:error, message} -> {:error, "failed to set HEAD: #{message}"}
    end
  end

  defp detect_head_branch(bare_dir) do
    head =
      case Git.cmd(["symbolic-ref", "--short", "HEAD"], cd: bare_dir) do
        {:ok, branch} -> branch
        {:error, _message} -> nil
      end

    if head && branch_exists?(bare_dir, head) do
      {:ok, head}
    else
      first_available_branch(bare_dir)
    end
  end

  defp first_available_branch(bare_dir) do
    case Git.cmd(["branch", "--list", "--format=%(refname:short)"], cd: bare_dir) do
      {:ok, output} ->
        case String.split(output, "\n", trim: true) do
          [] ->
            {:error, "empty or unborn remotes are unsupported"}

          [branch | _rest] ->
            {:ok, branch}
        end

      {:error, message} ->
        {:error, "could not determine the remote HEAD branch: #{message}"}
    end
  end

  defp branch_exists?(bare_dir, branch) do
    case Git.cmd(["show-ref", "--verify", "refs/heads/#{branch}"], cd: bare_dir) do
      {:ok, _output} -> true
      {:error, _message} -> false
    end
  end

  defp add_main_worktree(dir, branch) do
    bare_dir = Project.bare_path(dir)
    worktree_dir = Project.worktree_path(dir, branch)

    case Git.cmd(["worktree", "add", "--", worktree_dir, branch], cd: bare_dir) do
      {:ok, _output} -> :ok
      {:error, message} -> {:error, "worktree add failed: #{message}"}
    end
  end

  defp ensure_upstream(dir, branch) do
    worktree_dir = Project.worktree_path(dir, branch)

    case Project.ensure_upstream(worktree_dir, branch) do
      :ok -> :ok
      {:error, message} -> {:error, "upstream setup failed: #{message}"}
    end
  end

  defp prepare_worktree_metadata(staging_dir, destination, branch) do
    staging_worktree = Project.worktree_path(staging_dir, branch)
    staging_git_file = Path.join(staging_worktree, ".git")

    with {:ok, metadata_dir} <- read_worktree_gitdir(staging_git_file),
         :ok <- validate_metadata_directory(staging_dir, metadata_dir),
         :ok <- validate_metadata_backlink(metadata_dir, staging_git_file),
         :ok <- rewrite_metadata_paths(metadata_dir, staging_git_file, destination, branch) do
      :ok
    end
  end

  defp read_worktree_gitdir(git_file) do
    case File.read(git_file) do
      {:ok, "gitdir: " <> path} ->
        path = String.trim(path)

        if path == "" do
          {:error, "worktree metadata pointer is empty"}
        else
          {:ok, Path.expand(path, Path.dirname(git_file))}
        end

      {:ok, _contents} ->
        {:error, "worktree .git file has unexpected contents"}

      {:error, reason} ->
        {:error, "failed to read worktree .git file: #{format_reason(reason)}"}
    end
  end

  defp validate_metadata_directory(staging_dir, metadata_dir) do
    worktrees_dir = Path.join(Project.bare_path(staging_dir), "worktrees")

    if same_filesystem_entry?(Path.dirname(metadata_dir), worktrees_dir) &&
         match?({:ok, %File.Stat{type: :directory}}, File.lstat(metadata_dir)) do
      :ok
    else
      {:error, "worktree metadata points outside the staged bare repository"}
    end
  end

  defp validate_metadata_backlink(metadata_dir, staging_git_file) do
    backlink = Path.join(metadata_dir, "gitdir")

    case File.read(backlink) do
      {:ok, path} ->
        if same_filesystem_entry?(
             Path.expand(String.trim(path), metadata_dir),
             staging_git_file
           ) do
          :ok
        else
          {:error, "worktree metadata backlink points outside the staged worktree"}
        end

      {:error, reason} ->
        {:error, "failed to read worktree metadata backlink: #{format_reason(reason)}"}
    end
  end

  defp rewrite_metadata_paths(metadata_dir, staging_git_file, destination, branch) do
    metadata_name = Path.basename(metadata_dir)
    destination_worktree = Project.worktree_path(destination, branch)
    destination_git_file = Path.join(destination_worktree, ".git")
    destination_metadata = Path.join([Project.bare_path(destination), "worktrees", metadata_name])

    with :ok <-
           write_metadata_file(Path.join(metadata_dir, "gitdir"), destination_git_file <> "\n"),
         :ok <- write_metadata_file(staging_git_file, "gitdir: #{destination_metadata}\n") do
      :ok
    end
  end

  defp write_metadata_file(path, contents) do
    case File.write(path, contents) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "failed to prepare worktree metadata: #{format_reason(reason)}"}
    end
  end

  defp move_staged_entries(staging_dir, destination, branch) do
    expected_entries =
      MapSet.new([
        @owner_marker,
        ".bare",
        ".git",
        Path.basename(Project.worktree_path(staging_dir, branch))
      ])

    case File.ls(staging_dir) do
      {:ok, entries} ->
        unexpected = Enum.reject(entries, &MapSet.member?(expected_entries, &1))

        if unexpected != [] do
          {:error,
           "refusing to publish unexpected staging entries #{inspect(unexpected)}; " <>
             "the clone staging directory was preserved"}
        else
          entries
          |> Enum.reject(&(&1 == @owner_marker))
          |> Enum.sort_by(&entry_move_order/1)
          |> Enum.reduce_while(:ok, fn entry, :ok ->
            source = Path.join(staging_dir, entry)
            target = Path.join(destination, entry)

            case File.lstat(target) do
              {:error, :enoent} ->
                case File.rename(source, target) do
                  :ok ->
                    {:cont, :ok}

                  {:error, reason} ->
                    {:halt,
                     {:error,
                      "failed to publish '#{entry}' in destination: #{format_reason(reason)}"}}
                end

              {:ok, _stat} ->
                {:halt, {:error, "refusing to overwrite destination entry '#{target}'"}}

              {:error, reason} ->
                {:halt,
                 {:error,
                  "failed to inspect destination entry '#{target}': #{format_reason(reason)}"}}
            end
          end)
        end

      {:error, reason} ->
        {:error, "failed to list clone staging directory: #{format_reason(reason)}"}
    end
  end

  defp entry_move_order(".bare"), do: 0
  defp entry_move_order(".git"), do: 2
  defp entry_move_order(_entry), do: 1

  defp remove_staging_directory(staging_dir, owner_token) do
    case cleanup_owned_directory(staging_dir, owner_token) do
      :ok -> :ok
      {:error, message} -> {:error, "failed to remove clone staging directory: #{message}"}
    end
  end

  defp validate_layout(dir, branch) do
    bare_dir = Project.bare_path(dir)
    worktree_dir = Project.worktree_path(dir, branch)

    with :ok <- validate_directory(bare_dir, "bare repository"),
         :ok <- validate_directory(worktree_dir, "initial worktree"),
         :ok <- validate_root_pointer(dir),
         :ok <- validate_bare_repository(bare_dir),
         :ok <- validate_auto_setup_remote(bare_dir),
         :ok <- validate_worktree_branch(worktree_dir, branch),
         :ok <- validate_common_directory(worktree_dir, bare_dir),
         :ok <- validate_worktree_registration(bare_dir, worktree_dir, branch),
         :ok <- validate_upstream(worktree_dir, branch) do
      :ok
    end
  end

  defp validate_directory(path, label) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:ok, %File.Stat{type: type}} ->
        {:error, "clone verification failed: #{label} is a #{type}, not a directory"}

      {:error, reason} ->
        {:error,
         "clone verification failed: could not inspect #{label} '#{path}': #{format_reason(reason)}"}
    end
  end

  defp validate_root_pointer(dir) do
    git_file = Path.join(dir, ".git")

    case File.read(git_file) do
      {:ok, @gitdir_pointer} ->
        :ok

      {:ok, _contents} ->
        {:error, "clone verification failed: root .git pointer has unexpected contents"}

      {:error, reason} ->
        {:error,
         "clone verification failed: could not read root .git pointer: #{format_reason(reason)}"}
    end
  end

  defp validate_bare_repository(bare_dir) do
    case Git.cmd(["rev-parse", "--is-bare-repository"], cd: bare_dir) do
      {:ok, "true"} ->
        :ok

      {:ok, value} ->
        {:error, "clone verification failed: expected a bare repository, got #{value}"}

      {:error, message} ->
        {:error, "clone verification failed: #{message}"}
    end
  end

  defp validate_auto_setup_remote(bare_dir) do
    case Git.cmd(["config", "--bool", "push.autoSetupRemote"], cd: bare_dir) do
      {:ok, "true"} ->
        :ok

      {:ok, value} ->
        {:error,
         "clone verification failed: push.autoSetupRemote is #{inspect(value)}, expected true"}

      {:error, message} ->
        {:error, "clone verification failed: could not read push.autoSetupRemote: #{message}"}
    end
  end

  defp validate_worktree_branch(worktree_dir, branch) do
    case Git.cmd(["symbolic-ref", "--short", "HEAD"], cd: worktree_dir) do
      {:ok, ^branch} ->
        :ok

      {:ok, actual_branch} ->
        {:error, "clone verification failed: worktree is on #{actual_branch}, expected #{branch}"}

      {:error, message} ->
        {:error, "clone verification failed: could not read worktree HEAD: #{message}"}
    end
  end

  defp validate_common_directory(worktree_dir, bare_dir) do
    case Git.cmd(["rev-parse", "--git-common-dir"], cd: worktree_dir) do
      {:ok, common_dir} ->
        if same_filesystem_entry?(Path.expand(common_dir, worktree_dir), bare_dir) do
          :ok
        else
          {:error,
           "clone verification failed: worktree points to an unexpected common repository"}
        end

      {:error, message} ->
        {:error, "clone verification failed: could not resolve worktree metadata: #{message}"}
    end
  end

  defp validate_worktree_registration(bare_dir, worktree_dir, branch) do
    case Git.cmd(["worktree", "list", "--porcelain", "-z"], cd: bare_dir) do
      {:ok, output} ->
        if registration_present?(output, worktree_dir, branch) do
          :ok
        else
          {:error, "clone verification failed: initial worktree registration is missing"}
        end

      {:error, message} ->
        {:error, "clone verification failed: could not list worktrees: #{message}"}
    end
  end

  defp registration_present?(output, worktree_dir, branch) do
    expected_branch = "refs/heads/#{branch}"

    {found?, path_matches?, branch_matches?} =
      output
      |> String.split(<<0>>, trim: false)
      |> Enum.reduce({false, false, false}, fn field, {found?, path_matches?, branch_matches?} ->
        case field do
          "worktree " <> path ->
            path_matches? = same_filesystem_entry?(path, worktree_dir)
            {found? || (path_matches? && branch_matches?), path_matches?, false}

          "branch " <> registered_branch ->
            {found?, path_matches?, registered_branch == expected_branch}

          "" ->
            {found? || (path_matches? && branch_matches?), false, false}

          _other ->
            {found?, path_matches?, branch_matches?}
        end
      end)

    found? || (path_matches? && branch_matches?)
  end

  defp validate_upstream(worktree_dir, branch) do
    case Git.cmd(
           ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
           cd: worktree_dir
         ) do
      {:ok, "origin/" <> ^branch} ->
        :ok

      {:ok, upstream} ->
        {:error,
         "clone verification failed: worktree upstream is #{upstream}, expected origin/#{branch}"}

      {:error, message} ->
        {:error, "clone verification failed: worktree upstream is not configured: #{message}"}
    end
  end

  defp remove_owner_marker(dir, owner_token) do
    marker = Path.join(dir, @owner_marker)

    case File.read(marker) do
      {:ok, ^owner_token} ->
        case File.rm(marker) do
          :ok ->
            :ok

          {:error, reason} ->
            {:error, "failed to remove clone ownership marker: #{format_reason(reason)}"}
        end

      {:ok, _other_token} ->
        {:error, "clone ownership marker changed before publication completed"}

      {:error, reason} ->
        {:error, "could not verify clone ownership marker: #{format_reason(reason)}"}
    end
  end

  defp fail_with_cleanup(message, owned_dir, owner_token) do
    fail_with_cleanups(message, [owned_dir], owner_token)
  end

  defp fail_with_cleanups(message, owned_dirs, owner_token) do
    cleanup_errors =
      owned_dirs
      |> Enum.uniq()
      |> Enum.reduce([], fn dir, errors ->
        case cleanup_owned_directory(dir, owner_token) do
          :ok -> errors
          {:error, cleanup_message} -> [cleanup_message | errors]
        end
      end)
      |> Enum.reverse()

    case cleanup_errors do
      [] -> {:error, message}
      errors -> {:error, "#{message}; cleanup failed: #{Enum.join(errors, "; ")}"}
    end
  end

  defp cleanup_owned_directory(dir, owner_token) do
    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory}} ->
        cleanup_owned_directory_contents(dir, owner_token)

      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: type}} ->
        {:error, "refusing to remove '#{dir}' because it is #{type}, not an owned directory"}

      {:error, reason} ->
        {:error, "could not inspect '#{dir}': #{format_reason(reason)}"}
    end
  end

  defp cleanup_owned_directory_contents(dir, owner_token) do
    marker = Path.join(dir, @owner_marker)

    case File.read(marker) do
      {:ok, ^owner_token} ->
        case File.ls(dir) do
          {:ok, [@owner_marker]} ->
            case File.rm(marker) do
              :ok ->
                case File.rmdir(dir) do
                  :ok ->
                    :ok

                  {:error, reason} ->
                    {:error,
                     "could not remove empty owned directory '#{dir}': #{format_reason(reason)}"}
                end

              {:error, reason} ->
                {:error,
                 "could not remove ownership marker '#{marker}': #{format_reason(reason)}"}
            end

          {:ok, entries} ->
            {:error,
             "refusing to recursively remove owned directory '#{dir}'; " <>
               "preserving entries #{inspect(entries)}"}

          {:error, reason} ->
            {:error, "could not inspect owned directory '#{dir}': #{format_reason(reason)}"}
        end

      {:ok, _other_token} ->
        {:error, "refusing to remove '#{dir}' because its ownership marker changed"}

      {:error, :enoent} ->
        case File.lstat(dir) do
          {:error, :enoent} ->
            :ok

          {:ok, _stat} ->
            {:error, "refusing to remove '#{dir}' because its ownership marker is missing"}

          {:error, reason} ->
            {:error, "could not inspect '#{dir}': #{format_reason(reason)}"}
        end

      {:error, reason} ->
        {:error, "could not read ownership marker in '#{dir}': #{format_reason(reason)}"}
    end
  end

  defp same_filesystem_entry?(left, right) do
    case {File.stat(left), File.stat(right)} do
      {{:ok, left_stat}, {:ok, right_stat}} ->
        same_expanded_path? = Path.expand(left) == Path.expand(right)

        same_file_identity? =
          left_stat.inode != 0 and
            left_stat.inode == right_stat.inode and
            left_stat.major_device == right_stat.major_device and
            left_stat.minor_device == right_stat.minor_device

        same_expanded_path? or same_file_identity?

      _other ->
        false
    end
  end

  defp format_reason(reason), do: reason |> :file.format_error() |> IO.iodata_to_binary()
end
