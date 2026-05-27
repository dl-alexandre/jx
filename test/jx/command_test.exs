defmodule JX.CommandTest do
  use ExUnit.Case, async: true

  alias JX.Command

  test "run returns command output before timeout" do
    assert {:ok, {"ok\n", 0}} =
             Command.run("sh", ["-c", "printf 'ok\\n'"], timeout_ms: 1_000)
  end

  test "run returns timeout evidence for hung commands" do
    assert {:error, {:command_timeout, "sh", ["-c", "sleep 2"], 25}} =
             Command.run("sh", ["-c", "sleep 2"], timeout_ms: 25)
  end
end
