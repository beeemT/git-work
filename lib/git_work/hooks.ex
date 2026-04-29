defmodule GitWork.Hooks do
  @moduledoc """
  Hook runner for worktree lifecycle events.
  """

  alias GitWork.{Git, Project}

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
          case cmd("mise", ["trust"], cd: worktree_dir) do
            {:ok, _} -> :ok
            {:error, msg} -> {:error, "mise trust failed: #{msg}"}
          end
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
        case cmd("mise", ["trust", "--show"], cd: dir) do
          # mise trust --show always emits "path: trusted" or "path: untrusted"
          # (non-empty in both cases), so we must check the content, not just
          # presence. "untrusted" is a superstring of "trusted", so the negative
          # guard is required.
          {:ok, output} ->
            String.contains?(output, "trusted") and not String.contains?(output, "untrusted")
        end
    end
  end

  defp run_mise_hook(%{root: root, worktree_dir: worktree_dir} = ctx) do
    case System.find_executable("mise") do
      nil ->
        IO.write(:stderr, "hook: mise not found; skipping trust and task\n")
        :ok

      _path ->
        trust_enabled = mise_trust_enabled?(root)
        task = mise_task(root)

        with :ok <- maybe_trust_mise(trust_enabled, ctx),
             :ok <- maybe_run_task(task, worktree_dir) do
          :ok
        end
    end
  end

  defp maybe_trust_mise(false, _ctx), do: :ok

  # When source_worktree is nil (running from project root), use the project
  # root itself as the trust source — it is the main branch's worktree.
  defp maybe_trust_mise(true, %{source_worktree: nil, source_branch: nil, root: root, worktree_dir: worktree_dir}) do
    trust_from_source(root, worktree_dir)
  end

  defp maybe_trust_mise(true, %{source_worktree: nil, source_branch: branch, root: root, worktree_dir: worktree_dir}) do
    source = Path.join(root, branch)

    if File.dir?(source) do
      trust_from_source(source, worktree_dir)
    else
      :ok
    end
  end

  defp maybe_trust_mise(true, %{source_worktree: source, worktree_dir: worktree_dir}) do
    trust_from_source(source, worktree_dir)
  end

  defp trust_from_source(source, worktree_dir) do
    case cmd("mise", ["trust", "--show"], cd: source) do
      {:ok, output} ->
        if String.contains?(output, "trusted") and not String.contains?(output, "untrusted") do
          case cmd("mise", ["trust"], cd: worktree_dir) do
            {:ok, _} -> :ok
            {:error, msg} -> {:error, "mise trust failed: #{msg}"}
          end
        else
          :ok
        end

      {:error, msg} ->
        {:error, "mise trust --show failed: #{msg}"}
    end
  end

  defp maybe_run_task(nil, _worktree_dir), do: :ok

  defp maybe_run_task(task, worktree_dir) do
    if mise_task_exists?(task, worktree_dir) do
      case cmd("mise", ["run", task], cd: worktree_dir) do
        {:ok, _} -> :ok
        {:error, msg} -> {:error, "mise run #{task} failed: #{msg}"}
      end
    else
      IO.write(:stderr, "hook: mise task #{task} not defined; skipping\n")
      :ok
    end
  end

  defp mise_task_exists?(task, worktree_dir) do
    case cmd("mise", ["tasks", "--json"], cd: worktree_dir) do
      {:ok, json} ->
        try do
          case :json.decode(json) do
            tasks when is_list(tasks) ->
              Enum.any?(tasks, fn t -> is_map(t) and t["name"] == task end)

            _ ->
              false
          end
        rescue
          _ -> false
        end

      {:error, _} ->
        false
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
