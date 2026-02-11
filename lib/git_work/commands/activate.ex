defmodule GitWork.Commands.Activate do
  @moduledoc """
  Print shell integration code for the given shell.
  Pipe the output into your shell's eval/source mechanism.
  """

  alias GitWork.ShellHook

  def help do
    shells = Enum.join(ShellHook.supported_shells(), ", ")

    """
    usage: git-work activate <shell>

    Print the shell wrapper function for the given shell.
    Supported shells: #{shells}

    Examples:
      # bash / zsh (in .bashrc or .zshrc)
      eval "$(git-work activate bash)"

      # fish (in config.fish)
      git-work activate fish | source
    """
  end

  def run([shell]) do
    case ShellHook.generate(shell) do
      {:error, _} = err -> err
      code when is_binary(code) -> {:ok, code}
    end
  end

  def run([]) do
    {:error,
     "activate requires a shell argument (#{Enum.join(ShellHook.supported_shells(), ", ")})"}
  end

  def run(_args) do
    {:error, "activate takes exactly one argument: the shell name"}
  end
end
