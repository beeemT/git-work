defmodule GitWork.Commands.ListTest do
  use ExUnit.Case

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

  test "lists worktrees", %{tmp: tmp} do
    project = GitWork.TestHelper.create_gw_project(tmp)

    File.cd!(Path.join(project, "main"))

    {:ok, _} = Checkout.run(["feature-list-test"])

    assert {:ok, output} = List.run([])
    assert output =~ "main"
    assert output =~ "feature-list-test"
  end
end
