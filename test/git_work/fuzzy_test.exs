defmodule GitWork.FuzzyTest do
  use ExUnit.Case, async: true

  alias GitWork.Fuzzy

  describe "match/2" do
    test "exact match takes priority" do
      assert Fuzzy.match("main", ["main", "maintain"]) == {:exact, "main"}
    end

    test "single substring match" do
      assert Fuzzy.match("login", ["feature-login", "fix-typo"]) == {:match, "feature-login"}
    end

    test "multiple substring matches are ambiguous" do
      result = Fuzzy.match("feat", ["feature-login", "feature-signup"])
      assert {:ambiguous, candidates} = result
      assert "feature-login" in candidates
      assert "feature-signup" in candidates
    end

    test "jaro-winkler catches typos" do
      result = Fuzzy.match("featur-login", ["feature-login", "fix-typo"])
      assert {:match, "feature-login"} = result
    end

    test "no match returns :no_match" do
      assert Fuzzy.match("zzz", ["main", "develop"]) == :no_match
    end

    test "empty candidates returns :no_match" do
      assert Fuzzy.match("anything", []) == :no_match
    end

    test "jaro-winkler with clear winner picks best" do
      result = Fuzzy.match("feature-logi", ["feature-login", "fix-typo"])
      assert {:match, "feature-login"} = result
    end
  end
end
