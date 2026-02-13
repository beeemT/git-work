defmodule GitWork.Hooks do
  @moduledoc """
  Hook runner for worktree lifecycle events.
  """

  alias GitWork.{Git, Project}

  def run(:post_worktree_create, ctx) do
    run_mise_hook(ctx)
  end

  def run(:post_checkout, _ctx), do: :ok

  def run(_event, _ctx), do: :ok

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

  defp maybe_trust_mise(true, %{source_worktree: nil}), do: :ok

  defp maybe_trust_mise(true, %{source_worktree: source, worktree_dir: worktree_dir}) do
    case cmd("mise", ["trust", "--show"], cd: source) do
      {:ok, output} when output != "" ->
        case cmd("mise", ["trust"], cd: worktree_dir) do
          {:ok, _} -> :ok
          {:error, msg} -> {:error, "mise trust failed: #{msg}"}
        end

      {:ok, _} ->
        :ok

      {:error, msg} ->
        {:error, "mise trust --show failed: #{msg}"}
    end
  end

  defp maybe_run_task(nil, _worktree_dir), do: :ok

  defp maybe_run_task(task, worktree_dir) do
    case cmd("mise", ["run", task], cd: worktree_dir) do
      {:ok, _} ->
        :ok

      {:error, msg} ->
        if missing_mise_task?(msg) do
          IO.write(:stderr, "hook: mise task #{task} not defined; skipping\n")
          :ok
        else
          {:error, "mise run #{task} failed: #{msg}"}
        end
    end
  end

  defp missing_mise_task?(msg) do
    String.match?(msg, ~r/(no task named|task .* not found|unknown task|task .* missing)/i)
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
      :unset -> "worktree:setup"
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
