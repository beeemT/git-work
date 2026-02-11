defmodule GitWork.ShellHook do
  @moduledoc """
  Generates the shell wrapper function for eval.
  Supports bash, zsh, and fish.
  """

  @supported_shells ~w(bash zsh fish)

  def supported_shells, do: @supported_shells

  def generate("bash"), do: generate_posix()
  def generate("zsh"), do: generate_posix()

  def generate("fish") do
    """
    function gw
        set -l output (command git-work $argv)
        set -l exit_code $status

        if test $exit_code -eq 0; and test -d "$output"
            cd $output
        else if test $exit_code -eq 0; and test -n "$output"
            echo $output
        else if test -n "$output"
            echo $output >&2
            return $exit_code
        else
            return $exit_code
        end
    end
    """
  end

  def generate(shell) do
    {:error, "unsupported shell '#{shell}' (supported: #{Enum.join(@supported_shells, ", ")})"}
  end

  defp generate_posix do
    """
    gw() {
      local output
      output=$(command git-work "$@")
      local exit_code=$?

      if [ $exit_code -eq 0 ] && [ -d "$output" ]; then
        cd "$output" || return
      elif [ $exit_code -eq 0 ] && [ -n "$output" ]; then
        echo "$output"
      elif [ -n "$output" ]; then
        echo "$output" >&2
        return $exit_code
      else
        return $exit_code
      fi
    }
    """
  end
end
