defmodule GitWork.CLI do
  @moduledoc """
  Argument parsing and command dispatch.
  """

  alias GitWork.Commands.{Activate, Clone, Init, Checkout, Rm, Sync, List}

  @commands %{
    "activate" => Activate,
    "clone" => Clone,
    "cl" => Clone,
    "init" => Init,
    "checkout" => Checkout,
    "co" => Checkout,
    "rm" => Rm,
    "sync" => Sync,
    "s" => Sync,
    "list" => List,
    "ls" => List
  }

  def run(args) do
    {format, args} = extract_format(args)

    case args do
      ["--help"] ->
        print_help()

      ["-h"] ->
        print_help()

      ["help"] ->
        print_help()

      ["help", command] ->
        print_command_help(command)

      [command | rest] ->
        if "--help" in rest or "-h" in rest do
          print_command_help(command)
        else
          dispatch(command, rest, format)
        end

      [] ->
        print_help()
    end
  end

  defp extract_format(args) do
    case Enum.split_with(args, &(&1 == "--format=json")) do
      {format_args, rest} when format_args != [] ->
        {:json, rest}

      _ ->
        {:text, args}
    end
  end

  defp dispatch(command, args, format) do
    case Map.get(@commands, command) do
      nil ->
        GitWork.Output.print_error("unknown command '#{command}'", format)
        print_help()
        System.halt(1)

      module ->
        result =
          try do
            module.run(args, format)
          rescue
            e ->
              {:error, "unexpected error: #{Exception.message(e)}"}
          end

        handle_result(result, format)
    end
  end

  defp handle_result({:ok, %GitWork.Output{} = output}, format) do
    GitWork.Output.print(output, format)
  end

  defp handle_result({:ok, output}, format) when is_binary(output) and output != "" do
    case format do
      :json ->
        json = JSON.encode!(%{path: output, messages: []})
        IO.write(:stderr, json <> "\n")

      :text ->
        IO.puts(output)
    end
  end

  defp handle_result({:ok, _}, _format), do: :ok

  defp handle_result({:error, message}, format) do
    GitWork.Output.print_error(message, format)
    System.halt(1)
  end

  defp print_command_help(command) do
    case Map.get(@commands, command) do
      nil ->
        IO.write(:stderr, "git-work: unknown command '#{command}'\n")
        System.halt(1)

      module ->
        IO.write(:stderr, module.help())
    end
  end

  defp print_help do
    IO.write(:stderr, """
    usage: git-work [--format=json] <command> [<args>]

    Commands:
      activate <shell>       Print shell integration (bash, zsh, fish)
      clone (cl) <url> [<dir>]    Clone a repo into worktree-based layout
      init                        Convert current repo to worktree-based layout
      checkout (co) <branch>      Switch to branch worktree (fuzzy match supported)
      rm [--force] [--yes] <branch>  Remove a worktree and its branch
      sync (s) [--dry-run]        Fetch and prune stale worktrees
      list (ls)                   List all worktrees

    Global options:
      --format=json    Output results as JSON to stderr
      --help           Show this help

    Run 'git-work <command> --help' for more information on a specific command.
    """)
  end
end
