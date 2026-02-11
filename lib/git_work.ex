defmodule GitWork do
  @moduledoc """
  git-work: a CLI tool wrapping git worktree for branch-per-directory workflows.
  """

  def main(args) do
    GitWork.CLI.run(args)
  end
end
