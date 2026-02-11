defmodule GitWork.Commands.List do
  @moduledoc """
  List all worktrees in a formatted table.
  """

  alias GitWork.{Git, Project}

  def help do
    """
    usage: git-work list

    List all worktrees and their branches.

    Displays a formatted table of worktrees with directory name and branch.
    The current worktree (based on working directory) is marked with *.

    Examples:
      git-work list
    """
  end

  def run(_args) do
    with {:ok, root} <- Project.find_root() do
      bare_dir = Project.bare_path(root)

      case Git.cmd(["worktree", "list", "--porcelain"], cd: bare_dir) do
        {:ok, output} ->
          entries =
            output
            |> parse_porcelain(root)
            |> Enum.reject(fn e -> String.starts_with?(e.dir, ".") end)

          formatted = format_table(entries, File.cwd!())
          IO.write(:stderr, formatted)
          {:ok, ""}

        {:error, msg} ->
          {:error, "worktree list failed: #{msg}"}
      end
    end
  end

  @doc false
  def parse_porcelain(output, project_root) do
    output
    |> String.split("\n\n", trim: true)
    |> Enum.map(&parse_entry/1)
    |> Enum.reject(fn entry -> entry.bare end)
    |> Enum.map(fn entry ->
      dir_name = Path.relative_to(entry.path, project_root)
      %{entry | dir: dir_name}
    end)
  end

  defp parse_entry(block) do
    lines = String.split(block, "\n", trim: true)

    Enum.reduce(lines, %{path: nil, branch: nil, bare: false, dir: nil}, fn line, acc ->
      cond do
        String.starts_with?(line, "worktree ") ->
          %{acc | path: String.trim_leading(line, "worktree ")}

        line == "bare" ->
          %{acc | bare: true}

        String.starts_with?(line, "branch ") ->
          ref = String.trim_leading(line, "branch ")
          branch = String.replace_prefix(ref, "refs/heads/", "")
          %{acc | branch: branch}

        true ->
          acc
      end
    end)
  end

  defp format_table([], _cwd), do: "  (no worktrees)\n"

  defp format_table(entries, cwd) do
    max_dir =
      entries
      |> Enum.map(fn e -> String.length(e.dir) end)
      |> Enum.max()

    entries
    |> Enum.map(fn entry ->
      marker = if entry.path == cwd, do: "*", else: " "
      padded_dir = String.pad_trailing(entry.dir, max_dir)
      branch_label = entry.branch || "(detached)"
      "#{marker} #{padded_dir}  #{branch_label}\n"
    end)
    |> Enum.join()
  end
end
