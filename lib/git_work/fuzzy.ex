defmodule GitWork.Fuzzy do
  @moduledoc """
  Fuzzy matching for worktree/branch names.
  Priority: exact match > substring match > Jaro-Winkler similarity.
  Matching is case-insensitive by default; case-sensitivity is used only to
  disambiguate when multiple candidates match.
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
            disambiguate_substring(input, multiple)

          [] ->
            jaro_match(input, candidates)
        end
    end
  end

  defp substring_matches(input, candidates) do
    down_input = String.downcase(input)

    Enum.filter(candidates, fn candidate ->
      String.contains?(String.downcase(candidate), down_input)
    end)
  end

  defp disambiguate_substring(input, matches) do
    case Enum.filter(matches, &String.contains?(&1, input)) do
      [single] -> {:match, single}
      _ -> {:ambiguous, matches}
    end
  end

  defp jaro_match(input, candidates) do
    down_input = String.downcase(input)

    scores =
      candidates
      |> Enum.map(fn candidate -> {candidate, String.jaro_distance(down_input, String.downcase(candidate))} end)
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
        disambiguate_jaro(input, multiple)
    end
  end

  defp disambiguate_jaro(input, tied_matches) do
    names = Enum.map(tied_matches, fn {name, _} -> name end)

    cs_scores =
      tied_matches
      |> Enum.map(fn {name, _} -> {name, String.jaro_distance(input, name)} end)
      |> Enum.sort_by(fn {_, score} -> score end, :desc)

    case cs_scores do
      [{best, best_score}, {_second, second_score} | _] when best_score > second_score ->
        {:match, best}

      _ ->
        {:ambiguous, names}
    end
  end
end
