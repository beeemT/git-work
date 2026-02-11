defmodule GitWork.Fuzzy do
  @moduledoc """
  Fuzzy matching for worktree/branch names.
  Priority: exact match > substring match > Jaro-Winkler similarity.
  """

  @jaro_threshold 0.85

  @doc """
  Match `input` against a list of `candidates`.

  Returns:
    - {:exact, name} — exact match found
    - {:match, name} — single fuzzy match
    - {:ambiguous, [names]} — multiple candidates above threshold
    - :no_match — nothing matched
  """
  def match(input, candidates) do
    cond do
      input in candidates ->
        {:exact, input}

      true ->
        case substring_matches(input, candidates) do
          [single] ->
            {:match, single}

          [_ | _] = multiple ->
            {:ambiguous, multiple}

          [] ->
            jaro_match(input, candidates)
        end
    end
  end

  defp substring_matches(input, candidates) do
    Enum.filter(candidates, fn candidate ->
      String.contains?(candidate, input)
    end)
  end

  defp jaro_match(input, candidates) do
    scores =
      candidates
      |> Enum.map(fn candidate -> {candidate, String.jaro_distance(input, candidate)} end)
      |> Enum.filter(fn {_candidate, score} -> score >= @jaro_threshold end)
      |> Enum.sort_by(fn {_candidate, score} -> score end, :desc)

    case scores do
      [] ->
        :no_match

      [{name, _score}] ->
        {:match, name}

      [{best, best_score}, {_second, second_score} | _] when best_score > second_score ->
        {:match, best}

      multiple ->
        {:ambiguous, Enum.map(multiple, fn {name, _} -> name end)}
    end
  end
end
