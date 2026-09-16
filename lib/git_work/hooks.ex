defmodule GitWork.Hooks do
  @moduledoc """
  Hook runner for worktree lifecycle events.
  """

  alias GitWork.{Git, Output, Project}

  def run(:post_worktree_create, ctx) do
    run_mise_hook(ctx)
  end

  # Applied after `init` completes. Only propagates trust — does not run the
  # worktree-setup task, which is for newly-created worktrees from checkout.
  # Failure is non-fatal: init.ex demotes the error to a stderr warning.
  def run(:post_init, %{root: root, worktree_dir: worktree_dir, was_trusted: was_trusted}) do
    case System.find_executable("mise") do
      nil ->
        :ok

      _path ->
        if was_trusted and mise_trust_enabled?(root) do
          trust_dir(worktree_dir)
        else
          :ok
        end
    end
  end

  def run(:post_checkout, _ctx), do: :ok

  def run(_event, _ctx), do: :ok

  @doc """
  Returns true if the given directory is currently mise-trusted.
  Intended to be called before files are moved (e.g. during `init`),
  so the trust status of the original location can be captured before
  `.mise.toml` migrates to the new worktree directory.
  """
  def source_trusted?(dir) do
    case System.find_executable("mise") do
      nil ->
        false

      _path ->
        match?({:ok, :trusted}, trust_status(dir))
    end
  end

  defp run_mise_hook(%{root: root, worktree_dir: worktree_dir} = ctx) do
    case System.find_executable("mise") do
      nil ->
        Output.notify(:info, "hook: mise not found; skipping trust and task")
        :ok

      _path ->
        trust_enabled = mise_trust_enabled?(root)
        task = mise_task(root)

        with :ok <- maybe_trust_mise(trust_enabled, ctx),
             :ok <- maybe_run_task(task, worktree_dir, Map.get(ctx, :automatic_task?, true)) do
          :ok
        end
    end
  end

  defp maybe_trust_mise(false, _ctx), do: :ok

  # Checkout owns trust provenance. A nil source means that no exact registered
  # source worktree was established, so the hook must not infer one.
  defp maybe_trust_mise(true, %{source_worktree: nil}), do: :ok

  defp maybe_trust_mise(
         true,
         %{
           source_worktree: source,
           source_branch: branch,
           worktree_dir: worktree_dir
         }
       )
       when is_binary(source) and is_binary(branch) do
    if File.dir?(source) and worktree_branch?(source, branch) do
      trust_from_source(source, worktree_dir)
    else
      :ok
    end
  end

  defp maybe_trust_mise(true, _ctx), do: :ok

  defp worktree_branch?(worktree, expected_branch) do
    case Git.cmd(["branch", "--show-current"], cd: worktree) do
      {:ok, ^expected_branch} -> true
      _ -> false
    end
  end

  defp trust_from_source(source, worktree_dir) do
    case trust_status(source) do
      {:ok, :trusted} ->
        trust_dir(worktree_dir)

      {:ok, _status} ->
        :ok

      {:error, msg} ->
        {:error, "mise trust --show failed: #{msg}"}
    end
  end

  # Pass the target directory explicitly. A no-argument `mise trust` can select
  # an untrusted config from a parent directory instead of the new worktree.
  defp trust_dir(worktree_dir) do
    case cmd("mise", ["trust", worktree_dir], cd: worktree_dir) do
      {:ok, _} -> :ok
      {:error, msg} -> {:error, "mise trust failed: #{msg}"}
    end
  end

  defp trust_status(dir) do
    case cmd("mise", ["trust", "--show"], cd: dir) do
      {:ok, output} -> {:ok, trust_status_from_output(output, dir)}
      {:error, msg} -> {:error, msg}
    end
  end

  # `mise trust --show` may report several config roots (the current directory
  # and parents). Only the status for this worktree is relevant; an unrelated
  # untrusted parent must not make a trusted worktree appear untrusted.
  defp trust_status_from_output(output, dir) do
    expected = normalize_trust_path(dir, dir)

    statuses =
      output
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case Regex.run(~r/^(.*):\s+(trusted|untrusted)\s*$/, String.trim(line)) do
          [_, path, value] ->
            normalized = normalize_trust_path(path, dir)

            if trust_path_in_dir?(normalized, expected) do
              [if(value == "trusted", do: :trusted, else: :untrusted)]
            else
              []
            end

          _ ->
            []
        end
      end)

    cond do
      :untrusted in statuses -> :untrusted
      :trusted in statuses -> :trusted
      true -> legacy_trust_status(output)
    end
  end

  defp trust_path_in_dir?(path, dir) do
    path == dir or String.starts_with?(path, dir <> "/")
  end

  # Keep compatibility with older mise versions and the lightweight command
  # wrappers used by consumers, which may print only `trusted` or `untrusted`.
  defp legacy_trust_status(output) do
    case String.trim(output) do
      "trusted" -> :trusted
      "untrusted" -> :untrusted
      _ -> :unknown
    end
  end

  defp normalize_trust_path(path, relative_to) do
    path = String.trim(path)
    home = System.get_env("HOME")

    expanded =
      cond do
        path == "~" and is_binary(home) ->
          home

        String.starts_with?(path, "~/") and is_binary(home) ->
          Path.join(home, String.trim_leading(path, "~/"))

        true ->
          path
      end

    Path.expand(expanded, relative_to)
  end

  defp maybe_run_task(nil, _worktree_dir, _automatic_task?), do: :ok

  defp maybe_run_task(_task, _worktree_dir, false) do
    Output.notify(
      :warning,
      "hook: skipping automatic mise task for a remote-backed or explicitly based worktree; " <>
        "review the target configuration before running it"
    )

    :ok
  end

  defp maybe_run_task(task, worktree_dir, true) do
    case mise_task_exists?(task, worktree_dir) do
      {:ok, true} ->
        case cmd("mise", ["run", task], cd: worktree_dir) do
          {:ok, _} -> :ok
          {:error, msg} -> {:error, "mise run #{task} failed: #{msg}"}
        end

      {:ok, false} ->
        Output.notify(:info, "hook: mise task #{task} not defined; skipping")
        :ok

      {:error, message} ->
        {:error, "failed to inspect mise tasks: #{message}"}
    end
  end

  defp mise_task_exists?(task, worktree_dir) do
    case cmd("mise", ["tasks", "--json"], cd: worktree_dir) do
      {:ok, json} ->
        try do
          case :json.decode(json) do
            tasks when is_list(tasks) ->
              {:ok, Enum.any?(tasks, fn t -> is_map(t) and t["name"] == task end)}

            _ ->
              {:error, "mise returned a JSON value that is not a task list"}
          end
        rescue
          exception ->
            {:error, "mise returned malformed task JSON: #{Exception.message(exception)}"}
        end

      {:error, message} ->
        {:error, "mise tasks --json failed: #{message}"}
    end
  end

  defp mise_trust_enabled?(root) do
    case config_get_bool(root, "git-work.hooks.mise.trust") do
      {:ok, value} -> value
      :unset -> true
    end
  end

  defp mise_task(root) do
    case config_get_string(root, "git-work.hooks.mise.task") do
      {:ok, ""} -> nil
      {:ok, value} -> value
      :unset -> "worktree-setup"
    end
  end

  defp config_get_bool(root, key) do
    bare_dir = Project.bare_path(root)

    case Git.cmd(["config", "--get", "--bool", key], cd: bare_dir) do
      {:ok, "true"} -> {:ok, true}
      {:ok, "false"} -> {:ok, false}
      {:ok, value} -> {:ok, value == "true"}
      {:error, _} -> :unset
    end
  end

  defp config_get_string(root, key) do
    bare_dir = Project.bare_path(root)

    case Git.cmd(["config", "--get", key], cd: bare_dir) do
      {:ok, value} -> {:ok, value}
      {:error, _} -> :unset
    end
  end

  defp cmd(bin, args, opts) do
    cmd_opts = [stderr_to_stdout: true]

    cmd_opts =
      case Keyword.get(opts, :cd) do
        nil -> cmd_opts
        dir -> Keyword.put(cmd_opts, :cd, dir)
      end

    case System.cmd(bin, args, cmd_opts) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _code} -> {:error, String.trim(output)}
    end
  end
end
