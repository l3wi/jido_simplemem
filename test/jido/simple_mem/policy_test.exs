defmodule Jido.SimpleMem.PolicyTest do
  use ExUnit.Case, async: true

  alias Jido.SimpleMem.Policy

  test "turn_memories rewrites first-person durable facts into standalone memories" do
    assert {:ok, memories} =
             Policy.turn_memories(
               %{
                 user_input: "Remember that my name is Alice Chen and I prefer aisle seats."
               },
               Policy.default_options()
             )

    assert Enum.any?(memories, &(&1.text == "The user's name is Alice Chen."))
    assert Enum.any?(memories, &(&1.text == "The user prefers aisle seats."))
  end

  test "turn_memories ignores ordinary ephemeral requests" do
    assert {:skip, :not_durable} =
             Policy.turn_memories(
               %{user_input: "Can you summarize this bug report for me?"},
               Policy.default_options()
             )
  end
end
