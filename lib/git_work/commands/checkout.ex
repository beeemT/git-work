defmodule GitWork.Commands.Checkout do
  @moduledoc """
  Switch to a branch worktree, or create a new one with -b.
  Supports fuzzy matching against existing worktrees.
  """

  alias GitWork.{Fuzzy, Git, Hooks, Output, Project}

  def help do
    """
    usage: git-work checkout <branch>
           git-work checkout -
           git-work checkout -b <branch> [<base>]

    Switch to a branch by navigating to its worktree directory.

    Without -b, matches an existing worktree (exact or fuzzy) and prints its
    path. If no worktree matches, an exact local branch is attached. Otherwise,
    if exactly one remote has a branch with that name, a new tracking worktree
    is created. Returns an error if no branch is found or the remote is ambiguous.

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
          {source, trust_source} = source_context(root, nil, false)
          base = resolve_default_base(root, source)

          do_create(root, branch, base, trust_source, false)
          |> track_checkout(root, source)
        end

      ["-"] ->
        with {:ok, root} <- Project.find_root(),
             {:ok, branch} <- previous_worktree(root) do
          {source, trust_source} = source_context(root, nil, false)

          do_checkout(root, branch, trust_source)
          |> track_checkout(root, source)
        end

      [branch] ->
        with {:ok, root} <- Project.find_root() do
          {source, trust_source} = source_context(root, nil, false)

          do_checkout(root, branch, trust_source)
          |> track_checkout(root, source)
        end

      ["-b", branch, base] ->
        with {:ok, root} <- Project.find_root(),
             :ok <- validate_base_ref(base) do
          {source, trust_source} = source_context(root, base, true)

          do_create(root, branch, base, trust_source, true)
          |> track_checkout(root, source)
        end

      _ ->
        {:error, "usage: git-work checkout [-b] <branch> [<base>]"}
    end
  end

  defp do_checkout(root, input, trust_source) do
    with {:ok, worktrees} <- registered_worktrees(root) do
      case worktree_for_branch(project_worktrees(root, worktrees), input) do
        nil -> resolve_checkout(root, input, trust_source, worktrees)
        worktree -> {:ok, worktree.path}
      end
    end
  end

  defp resolve_checkout(root, branch, trust_source, worktrees) do
    case resolve_branch(root, branch) do
      {:ok, :local} ->
        Output.notify(:info, "creating worktree from local branch: '#{branch}'")
        create_worktree(root, branch, :local, nil, trust_source, false)

      {:ok, {:remote, remote_ref}} ->
        Output.notify(:info, "creating worktree from remote branch: '#{remote_ref}'")
        create_worktree(root, branch, {:remote, remote_ref}, nil, trust_source, false)

      {:ok, :missing} ->
        fuzzy_checkout(root, branch, worktrees)

      {:error, _} = error ->
        error
    end
  end

  defp fuzzy_checkout(root, input, worktrees) do
    worktrees = project_worktrees(root, worktrees)
    names = Enum.map(worktrees, &Path.basename(&1.path))
    sanitized = Project.sanitize_branch(input)

    case Fuzzy.match(sanitized, names) do
      {:exact, name} ->
        return_registered_worktree(worktrees, name, input)

      {:match, name} ->
        Output.notify(:info, "fuzzy match: '#{input}' -> '#{name}'")
        return_registered_worktree(worktrees, name, input)

      {:ambiguous, candidates} ->
        formatted = Enum.map_join(candidates, "\n", &"  #{&1}")
        {:error, "ambiguous match for '#{input}':\n#{formatted}"}

      :no_match ->
        {:error, "no worktree found for '#{input}' (use -b to create one)"}
    end
  end

  defp return_registered_worktree(worktrees, name, input) do
    case Enum.find(worktrees, &(Path.basename(&1.path) == name)) do
      nil ->
        {:error, "worktree directory '#{name}' is not registered for '#{input}'"}

      worktree ->
        {:ok, worktree.path}
    end
  end

  defp previous_worktree(root) do
    case config_get(root, "git-work.last-worktree") do
      nil ->
        {:error, "no previous worktree found"}

      name ->
        path = Path.expand(Path.join(root, name))

        with {:ok, worktrees} <- registered_worktrees(root) do
          case Enum.find(
                 worktrees,
                 &(&1.path == path and is_binary(&1.branch) and
                     match?({:ok, %File.Stat{type: :directory}}, File.lstat(&1.path)))
               ) do
            nil -> {:error, "previous worktree '#{name}' no longer exists"}
            worktree -> {:ok, worktree.branch}
          end
        end
    end
  end

  defp source_context(root, base, explicit_base?) do
    cwd = File.cwd!()
    source = current_worktree(root, cwd)
    trust_source = resolve_trust_source(root, cwd, source, base, explicit_base?)
    {source, trust_source}
  end

  defp current_worktree(root, cwd) do
    cwd = Path.expand(cwd)

    case registered_worktrees(root) do
      {:ok, worktrees} ->
        worktrees
        |> Enum.filter(fn worktree ->
          not worktree.bare? and path_contains?(worktree.path, cwd)
        end)
        |> Enum.max_by(&String.length(&1.path), fn -> nil end)

      {:error, _} ->
        nil
    end
  end

  defp path_contains?(worktree_path, cwd) do
    relative = Path.relative_to(cwd, worktree_path)

    relative == "." or
      (Path.type(relative) == :relative and relative != ".." and
         not String.starts_with?(relative, "../"))
  end

  defp resolve_trust_source(
         _root,
         _cwd,
         %{path: _path, branch: _branch} = source,
         _base,
         _explicit_base?
       ),
       do: source

  defp resolve_trust_source(root, cwd, nil, base, explicit_base?) do
    if Path.expand(cwd) == Path.expand(root) do
      if explicit_base? do
        if local_branch_exists?(root, base) do
          registered_worktree_for_branch(root, base)
        end
      else
        case default_branch_from_bare(root) do
          nil -> nil
          branch -> registered_worktree_for_branch(root, branch)
        end
      end
    end
  end

  defp track_checkout({:ok, path} = result, root, source) do
    target = Path.basename(path)

    source =
      case source do
        %{path: source_path} -> Path.basename(source_path)
        nil -> config_get(root, "git-work.current-worktree")
      end

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
        Output.notify(:warning, "failed to persist checkout state: #{msg}")
        :ok
    end
  end

  defp do_create(root, branch, base, trust_source, explicit_base?) do
    case resolve_branch(root, branch) do
      {:ok, :local} when explicit_base? ->
        existing_branch_error(branch, base)

      {:ok, {:remote, _remote_ref}} when explicit_base? ->
        existing_branch_error(branch, base)

      {:ok, :local} ->
        Output.notify(:info, "creating worktree from local branch: '#{branch}'")
        create_worktree(root, branch, :local, base, trust_source, explicit_base?)

      {:ok, {:remote, remote_ref}} ->
        Output.notify(:info, "creating worktree from remote branch: '#{remote_ref}'")
        create_worktree(root, branch, {:remote, remote_ref}, base, trust_source, explicit_base?)

      {:ok, :missing} ->
        create_worktree(root, branch, :new, base, trust_source, explicit_base?)

      {:error, _} = error ->
        error
    end
  end

  defp existing_branch_error(branch, base) do
    {:error, "branch '#{branch}' already exists; omit base ref '#{base}' to check it out"}
  end

  defp create_worktree(root, branch, strategy, base, trust_source, explicit_base?) do
    bare_dir = Project.bare_path(root)
    worktree_dir = Path.join(root, Project.sanitize_branch(branch))
    automatic_task? = not explicit_base? and not match?({:remote, _remote_ref}, strategy)

    with :ok <- validate_branch_name(bare_dir, branch),
         {:ok, worktrees} <- registered_worktrees(root),
         :ok <- ensure_worktree_directory_available(worktrees, worktree_dir, branch) do
      {git_cmd, created_branch?} = worktree_add_command(strategy, branch, worktree_dir, base)

      case Git.cmd(git_cmd, cd: bare_dir) do
        {:ok, _} ->
          transaction = %{
            root: root,
            worktree_dir: worktree_dir,
            branch: branch,
            created_branch?: created_branch?,
            automatic_task?: automatic_task?
          }

          run_hooks(transaction, trust_source)

        {:error, msg} ->
          {:error, "worktree add failed: #{msg}"}
      end
    end
  end

  defp validate_base_ref(base) do
    if String.starts_with?(base, "-") do
      {:error, "base ref must not start with '-'"}
    else
      :ok
    end
  end

  defp validate_branch_name(bare_dir, branch) do
    case Git.cmd(["check-ref-format", "--branch", branch], cd: bare_dir) do
      {:ok, ^branch} ->
        :ok

      {:ok, expanded} ->
        {:error,
         "branch shorthand '#{branch}' resolves to '#{expanded}'; use the exact branch name"}

      {:error, msg} ->
        {:error, "invalid branch name '#{branch}': #{msg}"}
    end
  end

  defp ensure_worktree_directory_available(worktrees, worktree_dir, branch) do
    worktree_dir = Path.expand(worktree_dir)

    case Enum.find(worktrees, &(&1.path == worktree_dir)) do
      %{branch: ^branch} ->
        {:error, "worktree '#{Path.basename(worktree_dir)}' already exists"}

      %{branch: actual_branch} ->
        {:error,
         "worktree directory '#{Path.basename(worktree_dir)}' is registered for branch " <>
           "'#{actual_branch}' and collides with requested branch '#{branch}'"}

      nil ->
        if path_exists?(worktree_dir) do
          {:error,
           "worktree directory '#{Path.basename(worktree_dir)}' already exists but is not a " <>
             "registered worktree for branch '#{branch}'"}
        else
          :ok
        end
    end
  end

  defp path_exists?(path), do: match?({:ok, _}, File.lstat(path))

  defp worktree_add_command(:local, branch, worktree_dir, _base) do
    {["worktree", "add", "--", worktree_dir, branch], false}
  end

  defp worktree_add_command({:remote, remote_ref}, branch, worktree_dir, _base) do
    {["worktree", "add", "--track", "-b", branch, "--", worktree_dir, remote_ref], true}
  end

  defp worktree_add_command(:new, branch, worktree_dir, base) do
    command = ["worktree", "add", "-b", branch, "--", worktree_dir]
    command = if base, do: command ++ [base], else: command
    {command, true}
  end

  defp resolve_branch(root, branch) do
    if local_branch_exists?(root, branch) do
      {:ok, :local}
    else
      case exact_remote_branches(root, branch) do
        {:ok, []} ->
          {:ok, :missing}

        {:ok, [%{ref: remote_ref}]} ->
          {:ok, {:remote, remote_ref}}

        {:ok, matches} ->
          remotes = Enum.map_join(matches, "\n", &"  #{&1.remote}")
          {:error, "remote branch '#{branch}' is ambiguous; found on remotes:\n#{remotes}"}

        {:error, _} = error ->
          error
      end
    end
  end

  defp local_branch_exists?(root, branch) do
    bare_dir = Project.bare_path(root)

    match?(
      {:ok, _},
      Git.cmd(["show-ref", "--verify", "--quiet", "refs/heads/#{branch}"], cd: bare_dir)
    )
  end

  defp exact_remote_branches(root, branch) do
    bare_dir = Project.bare_path(root)

    with {:ok, remote_output} <- Git.cmd(["remote"], cd: bare_dir),
         {:ok, ref_output} <-
           Git.cmd(["for-each-ref", "--format=%(refname)", "refs/remotes"], cd: bare_dir) do
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

          if MapSet.member?(refs, full_ref) do
            [%{remote: remote, ref: full_ref}]
          else
            []
          end
        end)

      {:ok, matches}
    else
      {:error, msg} -> {:error, "failed to enumerate remote branches: #{msg}"}
    end
  end

  # Returns the HEAD SHA of the exact registered source worktree. A nil source
  # lets git use the bare repository HEAD.
  defp resolve_default_base(_root, nil), do: nil

  defp resolve_default_base(_root, %{path: source_path}) do
    case Git.cmd(["rev-parse", "HEAD"], cd: source_path) do
      {:ok, sha} -> sha
      {:error, _} -> nil
    end
  end

  defp run_hooks(transaction, trust_source) do
    ctx = %{
      root: transaction.root,
      worktree_dir: transaction.worktree_dir,
      branch: transaction.branch,
      source_worktree: source_path(trust_source),
      source_branch: source_branch(trust_source),
      automatic_task?: transaction.automatic_task?
    }

    case Hooks.run(:post_worktree_create, ctx) do
      :ok ->
        case ensure_branch_upstream(transaction) do
          :ok ->
            {:ok, transaction.worktree_dir}

          {:error, msg} ->
            rollback_worktree(transaction, msg)
        end

      {:error, msg} ->
        rollback_worktree(transaction, msg)
    end
  end

  defp ensure_branch_upstream(transaction) do
    case Project.ensure_upstream(transaction.worktree_dir, transaction.branch) do
      :ok ->
        :ok

      {:error, message} ->
        {:error, "failed to configure upstream for #{transaction.branch}: #{message}"}
    end
  end

  defp registered_worktree_for_branch(root, branch) do
    case registered_worktrees(root) do
      {:ok, worktrees} -> worktree_for_branch(project_worktrees(root, worktrees), branch)
      {:error, _} -> nil
    end
  end

  defp source_path(nil), do: nil
  defp source_path(%{path: path}), do: path

  defp source_branch(nil), do: nil
  defp source_branch(%{branch: branch}), do: branch

  defp default_branch_from_bare(root) do
    case Project.head_branch(root) do
      {:ok, branch} -> branch
      {:error, _} -> nil
    end
  end

  defp registered_worktrees(root) do
    bare_dir = Project.bare_path(root)

    case Git.cmd(["worktree", "list", "--porcelain", "-z"], cd: bare_dir) do
      {:ok, output} -> {:ok, parse_registered_worktrees(output)}
      {:error, msg} -> {:error, "failed to list registered worktrees: #{msg}"}
    end
  end

  defp parse_registered_worktrees(output) do
    {worktrees, current} =
      output
      |> String.split(<<0>>, trim: true)
      |> Enum.reduce({[], nil}, fn field, {worktrees, current} ->
        cond do
          String.starts_with?(field, "worktree ") ->
            worktrees = add_registered_worktree(worktrees, current)
            path = String.replace_prefix(field, "worktree ", "")
            {worktrees, %{path: path, head: nil, branch: nil, detached?: false, bare?: false}}

          current && String.starts_with?(field, "HEAD ") ->
            head = String.replace_prefix(field, "HEAD ", "")
            {worktrees, %{current | head: head}}

          current && String.starts_with?(field, "branch refs/heads/") ->
            branch = String.replace_prefix(field, "branch refs/heads/", "")
            {worktrees, %{current | branch: branch}}

          current && field == "detached" ->
            {worktrees, %{current | detached?: true}}

          current && field == "bare" ->
            {worktrees, %{current | bare?: true}}

          true ->
            {worktrees, current}
        end
      end)

    worktrees
    |> add_registered_worktree(current)
    |> Enum.reverse()
  end

  defp add_registered_worktree(worktrees, %{
         path: path,
         head: head,
         branch: branch,
         detached?: detached?,
         bare?: bare?
       })
       when is_binary(path) do
    [
      %{
        path: Path.expand(path),
        head: head,
        branch: branch,
        detached?: detached?,
        bare?: bare?
      }
      | worktrees
    ]
  end

  defp add_registered_worktree(worktrees, _current), do: worktrees

  defp worktree_for_branch(worktrees, branch) do
    Enum.find(
      worktrees,
      &(&1.branch == branch and
          match?({:ok, %File.Stat{type: :directory}}, File.lstat(&1.path)))
    )
  end

  defp project_worktrees(root, worktrees) do
    root = Path.expand(root)

    Enum.filter(worktrees, fn worktree ->
      is_binary(worktree.branch) and
        not worktree.bare? and
        Path.dirname(worktree.path) == root and
        match?({:ok, %File.Stat{type: :directory}}, File.lstat(worktree.path))
    end)
  end

  defp rollback_worktree(transaction, reason) do
    bare_dir = Project.bare_path(transaction.root)

    failures =
      case Git.cmd(
             ["worktree", "remove", "--force", transaction.worktree_dir],
             cd: bare_dir
           ) do
        {:ok, _} -> []
        {:error, msg} -> ["worktree remove failed: #{msg}"]
      end

    failures =
      if transaction.created_branch? do
        case Git.cmd(["branch", "-D", "--", transaction.branch], cd: bare_dir) do
          {:ok, _} -> failures
          {:error, msg} -> failures ++ ["branch delete failed: #{msg}"]
        end
      else
        failures
      end

    case failures do
      [] ->
        {:error, reason}

      failures ->
        cleanup = Enum.map_join(failures, "\n", &"  #{&1}")
        {:error, "#{reason}\nrollback cleanup failed:\n#{cleanup}"}
    end
  end
end
