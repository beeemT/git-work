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
        print_help(format)

      ["-h"] ->
        print_help(format)

      ["help"] ->
        print_help(format)

      ["help", command] ->
        print_command_help(command, format)

      [command | rest] ->
        if "--help" in rest or "-h" in rest do
          print_command_help(command, format)
        else
          dispatch(command, rest, format)
        end

      [] ->
        print_help(format)
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

        if format == :text do
          print_help(format)
        end

        System.halt(1)

      module ->
        {result, messages} =
          GitWork.Output.with_context(format, fn ->
            try do
              module.run(args, format)
            rescue
              e ->
                {:error, "unexpected error: #{Exception.message(e)}"}
            end
          end)

        handle_result(result, format, messages)
    end
  end

  defp handle_result({:ok, %GitWork.Output{} = output}, format, messages) do
    GitWork.Output.print(GitWork.Output.with_messages(output, messages), format)
  end

  defp handle_result({:ok, output}, :json, messages) when is_binary(output) do
    output = if output == "", do: GitWork.Output.empty(), else: GitWork.Output.path(output)
    GitWork.Output.print(GitWork.Output.with_messages(output, messages), :json)
  end

  defp handle_result({:ok, output}, :text, _messages)
       when is_binary(output) and output != "" do
    IO.puts(output)
  end

  defp handle_result({:ok, _output}, :text, _messages), do: :ok

  defp handle_result({:ok, _output}, :json, messages) do
    GitWork.Output.print(GitWork.Output.with_messages(GitWork.Output.empty(), messages), :json)
  end

  defp handle_result({:error, message}, format, messages) do
    GitWork.Output.print_error(message, format, messages)
    System.halt(1)
  end

  defp print_command_help(command, format) do
    case Map.get(@commands, command) do
      nil ->
        GitWork.Output.print_error("unknown command '#{command}'", format)
        System.halt(1)

      module ->
        render_help(module.help(), format)
    end
  end

  defp print_help(format) do
    render_help(
      """
      usage: git-work [--format=json] <command> [<args>]

      Commands:
        activate <shell>       Print shell integration (bash, zsh, fish)
        clone (cl) <url> [<dir>]    Clone a repo into worktree-based layout
        init [--force]              Convert current repo to worktree-based layout
        checkout (co) <branch>      Switch to branch worktree (fuzzy match supported)
        rm [--force] [--yes] <branch>  Remove a worktree and its branch
        sync (s) [--dry-run]        Fetch and prune stale worktrees
        list (ls)                   List all worktrees

      Global options:
        --format=json    Output results as JSON to stderr
        --help           Show this help

      Run 'git-work <command> --help' for more information on a specific command.
      """,
      format
    )
  end

  defp render_help(help, :text), do: IO.write(:stderr, help)

  defp render_help(help, :json) do
    GitWork.Output.print(GitWork.Output.data(%{help: help}), :json)
  end
end
