defmodule Jido.SimpleMem.ConfusableFixtureE2ETest do
  use ExUnit.Case, async: true

  alias Jido.SimpleMem
  alias Jido.SimpleMem.TestSupport.Factory

  test "confusable people remain separated through synthesis and retrieval" do
    target = Factory.target("fixture-agent", window_size: 4, overlap_size: 1)

    assert {:ok, _result} =
             SimpleMem.add_dialogues(target, [
               %{
                 speaker: "user",
                 content: "Alice Johnson lives in Portland and prefers espresso"
               },
               %{speaker: "user", content: "Alice Johnston lives in Seattle and prefers chai"},
               %{speaker: "user", content: "Morgan Lee works on billing and prefers coffee"},
               %{speaker: "user", content: "Morgan Reed works on growth and prefers tea"}
             ])

    assert {:ok, alice} = SimpleMem.ask(target, "What does Alice Johnson prefer?")
    assert alice.answer =~ "Alice Johnson"
    assert alice.answer =~ "espresso"

    assert {:ok, johnston} = SimpleMem.ask(target, "Where does Alice Johnston live?")
    assert johnston.answer =~ "Seattle"

    assert {:ok, reed} = SimpleMem.ask(target, "What does Morgan Reed prefer?")
    assert reed.answer =~ "tea"
  end

  test "delete_memory removes only the selected confusable memory" do
    target = Factory.target("delete-agent", window_size: 4, overlap_size: 1)

    assert {:ok, _result} =
             SimpleMem.add_dialogues(target, [
               %{speaker: "user", content: "Morgan Lee prefers coffee"},
               %{speaker: "user", content: "Morgan Reed prefers tea"},
               %{speaker: "assistant", content: "Stored."},
               %{speaker: "user", content: "Both names are easy to confuse"}
             ])

    assert {:ok, records} = SimpleMem.get_all_memories(target)
    lee = Enum.find(records, &String.contains?(&1.text || "", "Morgan Lee"))

    assert {:ok, true} = SimpleMem.delete_memory(target, lee.id)

    assert {:ok, lee_result} = SimpleMem.ask(target, "What does Morgan Lee prefer?")
    assert lee_result.answer == "No relevant information found"

    assert {:ok, reed_result} = SimpleMem.ask(target, "What does Morgan Reed prefer?")
    assert reed_result.answer =~ "tea"
  end
end
