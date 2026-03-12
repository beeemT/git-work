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

  describe "case-insensitive matching" do
    test "substring match is case-insensitive" do
      assert Fuzzy.match("Login", ["feature-login", "fix-typo"]) == {:match, "feature-login"}
    end

    test "uppercase input matches lowercase candidate" do
      assert Fuzzy.match("LOGIN", ["feature-login", "fix-typo"]) == {:match, "feature-login"}
    end

    test "lowercase input matches uppercase candidate" do
      assert Fuzzy.match("login", ["Feature-Login", "fix-typo"]) == {:match, "Feature-Login"}
    end

    test "case-sensitive disambiguation picks exact case match" do
      result = Fuzzy.match("Login", ["feature-login", "feature-Login"])
      assert {:match, "feature-Login"} = result
    end

    test "ambiguous when case-sensitive does not narrow to one" do
      result = Fuzzy.match("Feat", ["Feature-login", "Feature-signup"])
      assert {:ambiguous, candidates} = result
      assert "Feature-login" in candidates
      assert "Feature-signup" in candidates
    end

    test "jaro-winkler is case-insensitive" do
      result = Fuzzy.match("FEATUR-LOGIN", ["feature-login", "fix-typo"])
      assert {:match, "feature-login"} = result
    end

    test "exact match is still case-sensitive" do
      refute Fuzzy.match("Main", ["main", "develop"]) == {:exact, "Main"}
      assert Fuzzy.match("Main", ["main", "develop"]) == {:match, "main"}
    end
  end
end
