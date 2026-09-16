defmodule GitWork.OutputTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias GitWork.Output

  test "restores text notifications after a JSON context" do
    assert {:ok, [%{level: :info, text: "json message"}]} =
             Output.with_context(:json, fn ->
               Output.notify(:info, "json message")
               :ok
             end)

    stderr =
      capture_io(:stderr, fn ->
        assert :ok = Output.notify(:warning, "text message")
      end)

    assert stderr == "warning: text message\n"
  end

  test "restores text notifications when a JSON context raises" do
    assert_raise RuntimeError, "boom", fn ->
      Output.with_context(:json, fn ->
        raise "boom"
      end)
    end

    stderr =
      capture_io(:stderr, fn ->
        assert :ok = Output.notify(:info, "after failure")
      end)

    assert stderr == "after failure\n"
  end

  test "restores the enclosing text context after a nested JSON context" do
    stderr =
      capture_io(:stderr, fn ->
        assert {:outer, []} =
                 Output.with_context(:text, fn ->
                   assert {:inner, [%{level: :info, text: "inner message"}]} =
                            Output.with_context(:json, fn ->
                              Output.notify(:info, "inner message")
                              :inner
                            end)

                   Output.notify(:warning, "outer message")
                   :outer
                 end)
      end)

    assert stderr == "warning: outer message\n"
  end
end
