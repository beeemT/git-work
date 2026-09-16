defmodule GitWork.Commands.List do
  @moduledoc """
  List all worktrees in a formatted table.
  """

  alias GitWork.{Git, Output, Project}

  @usage "usage: git-work list"

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

  def run([], format) do
    with {:ok, root} <- Project.find_root() do
      bare_dir = Project.bare_path(root)

      case Git.cmd(["worktree", "list", "--porcelain", "-z"], cd: bare_dir) do
        {:ok, output} ->
          entries =
            output
            |> parse_porcelain(root)
            |> Enum.reject(fn entry -> String.starts_with?(entry.dir, ".") end)

          current_path = current_worktree_path(entries, File.cwd!())
          output_result = output_for_list(entries, current_path)

          case format do
            :json ->
              {:ok, output_result}

            :text ->
              Output.notify(:info, format_table(entries, current_path))
              {:ok, ""}
          end

        {:error, msg} ->
          {:error, "worktree list failed: #{msg}"}
      end
    end
  end

  def run(_args, _format), do: {:error, @usage}

  defp output_for_list(entries, current_path) do
    %GitWork.Output{
      data: %{
        worktrees:
          Enum.map(entries, fn entry ->
            %{
              dir: entry.dir,
              branch: entry.branch,
              current: entry.path == current_path
            }
          end)
      },
      messages: []
    }
  end

  @doc false
  def parse_porcelain(output, project_root) do
    entries =
      if :binary.match(output, <<0>>) == :nomatch do
        parse_line_porcelain(output)
      else
        parse_nul_porcelain(output)
      end

    root = Path.expand(project_root)

    entries
    |> Enum.reject(& &1.bare)
    |> Enum.flat_map(fn
      %{path: path} = entry when is_binary(path) ->
        absolute_path = Path.expand(path)
        dir_name = Path.relative_to(absolute_path, root)
        [%{entry | path: absolute_path, dir: dir_name}]

      _entry ->
        []
    end)
  end

  defp parse_nul_porcelain(output) do
    {entries, current} =
      output
      |> :binary.split(<<0>>, [:global])
      |> Enum.reduce({[], nil}, fn field, {entries, current} ->
        case field do
          <<"worktree ", path::binary>> ->
            {add_entry(entries, current), new_entry(path)}

          "bare" when not is_nil(current) ->
            {entries, %{current | bare: true}}

          <<"branch refs/heads/", branch::binary>> when not is_nil(current) ->
            {entries, %{current | branch: branch}}

          _other ->
            {entries, current}
        end
      end)

    entries
    |> add_entry(current)
    |> Enum.reverse()
  end

  defp parse_line_porcelain(output) do
    output
    |> String.split("\n\n", trim: true)
    |> Enum.map(fn block ->
      block
      |> String.split("\n", trim: true)
      |> Enum.reduce(new_entry(nil), fn line, entry ->
        case line do
          <<"worktree ", path::binary>> ->
            %{entry | path: path}

          "bare" ->
            %{entry | bare: true}

          <<"branch refs/heads/", branch::binary>> ->
            %{entry | branch: branch}

          _other ->
            entry
        end
      end)
    end)
  end

  defp new_entry(path), do: %{path: path, branch: nil, bare: false, dir: nil}

  defp add_entry(entries, %{path: path} = entry) when is_binary(path), do: [entry | entries]
  defp add_entry(entries, _entry), do: entries

  defp current_worktree_path(entries, cwd) do
    cwd = Path.expand(cwd)

    entries
    |> Enum.filter(&path_contains?(&1.path, cwd))
    |> Enum.max_by(&String.length(&1.path), fn -> nil end)
    |> case do
      nil -> nil
      entry -> entry.path
    end
  end

  defp path_contains?(worktree_path, candidate_path) do
    relative = Path.relative_to(Path.expand(candidate_path), Path.expand(worktree_path))

    relative == "." or
      (Path.type(relative) == :relative and relative != ".." and
         not String.starts_with?(relative, "../"))
  end

  defp format_table([], _current_path), do: "  (no worktrees)\n"

  defp format_table(entries, current_path) do
    max_dir =
      entries
      |> Enum.map(fn entry -> String.length(entry.dir) end)
      |> Enum.max()

    entries
    |> Enum.map(fn entry ->
      marker = if entry.path == current_path, do: "*", else: " "
      padded_dir = String.pad_trailing(entry.dir, max_dir)
      branch_label = entry.branch || "(detached)"
      "#{marker} #{padded_dir}  #{branch_label}\n"
    end)
    |> Enum.join()
  end
end
