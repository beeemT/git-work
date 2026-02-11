defmodule GitWork.Commands.ListTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias GitWork.Commands.{List, Checkout}

  setup do
    old_cwd = File.cwd!()
    tmp = Path.join(System.tmp_dir!(), "gw_list_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    on_exit(fn ->
      File.cd!(old_cwd)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  test "lists worktrees in formatted table", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)

    File.cd!(Path.join(project, "main"))

    {:ok, _} = Checkout.run(["-b", "feature-list-test"])

    stderr =
      capture_io(:stderr, fn ->
        assert {:ok, ""} = List.run([])
      end)

    assert stderr =~ "main"
    assert stderr =~ "feature-list-test"
    # Each entry should be on its own line
    lines = String.split(stderr, "\n", trim: true)
    assert length(lines) == 2
  end

  test "marks current worktree with asterisk", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)

    File.cd!(Path.join(project, "main"))

    {:ok, _} = Checkout.run(["-b", "other-branch"])

    # cd into main — main should be marked
    File.cd!(Path.join(project, "main"))

    stderr =
      capture_io(:stderr, fn ->
        assert {:ok, ""} = List.run([])
      end)

    lines = String.split(stderr, "\n", trim: true)
    main_line = Enum.find(lines, &(&1 =~ "main"))
    other_line = Enum.find(lines, &(&1 =~ "other-branch"))

    assert String.starts_with?(main_line, "*")
    assert String.starts_with?(other_line, " ")
  end

  test "shows branch name for each worktree", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)

    File.cd!(Path.join(project, "main"))

    stderr =
      capture_io(:stderr, fn ->
        assert {:ok, ""} = List.run([])
      end)

    # The main worktree should show branch "main"
    assert stderr =~ ~r/main\s+main/
  end
end
