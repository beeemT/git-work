defmodule GitWork.Git do
  @moduledoc """
  Thin wrapper around System.cmd("git", ...).
  All git interaction goes through this module.
  """

  @doc """
  Run a git command and return {:ok, output} or {:error, message}.
  The `opts` keyword list supports:
    - :cd - directory to run the command in
  """
  def cmd(args, opts \\ []) do
    cmd_opts = [stderr_to_stdout: true]

    cmd_opts =
      case Keyword.get(opts, :cd) do
        nil -> cmd_opts
        dir -> Keyword.put(cmd_opts, :cd, dir)
      end

    case System.cmd("git", args, cmd_opts) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  @doc """
  Run a git command. Raises on failure.
  """
  def cmd!(args, opts \\ []) do
    case cmd(args, opts) do
      {:ok, output} -> output
      {:error, message} -> raise "git #{Enum.join(args, " ")} failed: #{message}"
    end
  end
end
