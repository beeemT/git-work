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

  @format_key {__MODULE__, :format}
  @messages_key {__MODULE__, :messages}

  @doc """
  Execute a command with an output context.

  Text notifications are written immediately to stderr. JSON notifications are
  collected and returned with the command result so the CLI can emit one
  structured document.
  """
  def with_context(format, fun) when format in [:text, :json] and is_function(fun, 0) do
    previous_format = Process.get(@format_key, :unset)
    previous_messages = Process.get(@messages_key, :unset)

    Process.put(@format_key, format)
    Process.put(@messages_key, [])

    try do
      {fun.(), Process.get(@messages_key, [])}
    after
      restore_context(@format_key, previous_format)
      restore_context(@messages_key, previous_messages)
    end
  end

  @doc """
  Add a user-facing notification.

  Notifications are collected for JSON command execution and printed to stderr
  for text execution. Direct command calls default to text behavior.
  """
  def notify(level, text)
      when level in [:info, :warning, :error] and is_binary(text) do
    message = %{level: level, text: text}

    if Process.get(@format_key) == :json do
      messages = Process.get(@messages_key, [])
      Process.put(@messages_key, messages ++ [message])
    else
      write_message(message)
    end

    :ok
  end

  @doc """
  Return whether the active command context is JSON output.
  """
  def json?, do: Process.get(@format_key) == :json

  @doc """
  Read a confirmation response without emitting a second JSON stream.
  """
  def confirm(prompt) when is_binary(prompt) do
    if json?() do
      {:error, "confirmation is required; rerun with --yes when using --format=json"}
    else
      IO.write(:stderr, prompt)

      case IO.gets("") do
        input when is_binary(input) ->
          case String.trim(input) |> String.downcase() do
            "y" -> :ok
            "yes" -> :ok
            _other -> {:error, "aborted"}
          end

        _other ->
          {:error, "aborted"}
      end
    end
  end

  defp restore_context(key, :unset), do: Process.delete(key)
  defp restore_context(key, value), do: Process.put(key, value)

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
  Prepend notifications collected by the CLI to an output value.
  """
  def with_messages(%__MODULE__{messages: existing} = output, messages)
      when is_list(messages) do
    %{output | messages: messages ++ existing}
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
      write_message(msg)
    end)
  end

  def print(%__MODULE__{path: path, data: nil, messages: messages}, :text) when is_binary(path) do
    Enum.each(messages, fn msg ->
      write_message(msg)
    end)

    IO.puts(path)
  end

  def print(%__MODULE__{path: nil, data: data, messages: messages}, :text) when is_map(data) do
    Enum.each(messages, fn msg ->
      write_message(msg)
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

  defp write_message(message) do
    text = format_message(message)
    suffix = if String.ends_with?(text, "\n"), do: "", else: "\n"
    IO.write(:stderr, text <> suffix)
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
  def print_error(message, format), do: print_error(message, format, [])

  def print_error(message, :text, _messages) when is_binary(message) do
    IO.write(:stderr, "git-work: #{message}\n")
  end

  def print_error(message, :json, messages) when is_binary(message) and is_list(messages) do
    error_message = %{level: :error, text: message}

    json =
      JSON.encode!(%{
        error: message,
        messages: Enum.map(messages ++ [error_message], &message_to_json/1)
      })

    IO.write(:stderr, json <> "\n")
  end
end
