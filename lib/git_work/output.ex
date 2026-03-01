defmodule GitWork.Output do
  @moduledoc """
  Output formatting for CLI commands.

  Supports both human-readable and JSON output formats.
  All JSON output is written to stderr, keeping stdout for machine-readable paths.
  """

  @type t :: %__MODULE__{
          path: String.t() | nil,
          data: map() | nil,
          messages: [message()]
        }

  @type message :: %{
          level: :info | :warning | :error,
          text: String.t()
        }

  defstruct [:path, :data, messages: []]

  @doc """
  Create a new output with a path result.

  The path is printed to stdout for shell wrapper consumption.
  """
  def path(path) when is_binary(path) do
    %__MODULE__{path: path}
  end

  @doc """
  Create a new output with structured data.
  """
  def data(data) when is_map(data) do
    %__MODULE__{data: data}
  end

  @doc """
  Create an empty output (success with no path).
  """
  def empty do
    %__MODULE__{}
  end

  @doc """
  Add an info message to the output.
  """
  def info(%__MODULE__{} = output, text) when is_binary(text) do
    add_message(output, :info, text)
  end

  @doc """
  Add a warning message to the output.
  """
  def warning(%__MODULE__{} = output, text) when is_binary(text) do
    add_message(output, :warning, text)
  end

  @doc """
  Add an error message to the output.
  """
  def error(%__MODULE__{} = output, text) when is_binary(text) do
    add_message(output, :error, text)
  end

  defp add_message(%__MODULE__{messages: messages} = output, level, text) do
    %{output | messages: messages ++ [%{level: level, text: text}]}
  end

  @doc """
  Print output to stdout/stderr in the specified format.

  ## Formats

  - `:text` - Human-readable format (default)
  - `:json` - JSON format (all output to stderr)

  For text format:
  - Path is printed to stdout (for shell wrapper cd)
  - Messages are printed to stderr

  For JSON format:
  - Everything is printed to stderr as JSON
  - Stdout remains empty
  """
  def print(%__MODULE__{path: nil, data: nil, messages: []}, :text) do
    :ok
  end

  def print(%__MODULE__{path: nil, data: nil, messages: messages}, :text) do
    Enum.each(messages, fn msg ->
      IO.write(:stderr, format_message(msg))
    end)
  end

  def print(%__MODULE__{path: path, data: nil, messages: messages}, :text) when is_binary(path) do
    Enum.each(messages, fn msg ->
      IO.write(:stderr, format_message(msg))
    end)

    IO.puts(path)
  end

  def print(%__MODULE__{path: nil, data: data, messages: messages}, :text) when is_map(data) do
    Enum.each(messages, fn msg ->
      IO.write(:stderr, format_message(msg))
    end)

    # For text format, data commands just print their messages
    # Commands like 'list' should handle their own formatting
    :ok
  end

  def print(%__MODULE__{} = output, :json) do
    json = to_json(output)
    IO.write(:stderr, json <> "\n")
  end

  @doc """
  Convert output to JSON string.
  """
  def to_json(%__MODULE__{path: path, data: data, messages: messages}) do
    result =
      %{}
      |> maybe_put(:path, path)
      |> maybe_put(:data, data)
      |> Map.put(:messages, Enum.map(messages, &message_to_json/1))

    # Remove data key if nil to keep output clean
    result = if data == nil, do: Map.delete(result, :data), else: result

    JSON.encode!(result)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp message_to_json(%{level: level, text: text}) do
    %{level: level, text: text}
  end

  defp format_message(%{level: :info, text: text}), do: text
  defp format_message(%{level: :warning, text: text}), do: "warning: #{text}"
  defp format_message(%{level: :error, text: text}), do: "error: #{text}"

  @doc """
  Create an error output suitable for returning from commands.
  This returns {:error, message} for compatibility with existing code.
  """
  def error_result(message) when is_binary(message) do
    {:error, message}
  end

  @doc """
  Print an error in the specified format.
  """
  def print_error(message, :text) when is_binary(message) do
    IO.write(:stderr, "git-work: #{message}\n")
  end

  def print_error(message, :json) when is_binary(message) do
    json =
      JSON.encode!(%{
        error: message,
        messages: [%{level: :error, text: message}]
      })

    IO.write(:stderr, json <> "\n")
  end
end
