defmodule Jido.SimpleMem.BufferedLifecycleTest do
  use ExUnit.Case, async: true

  alias Jido.SimpleMem
  alias Jido.SimpleMem.TestSupport.Factory

  defmodule PreviousEntryAwareLLMClient do
    @behaviour Jido.SimpleMem.LLMClient

    alias Jido.Memory.Record
    alias Jido.SimpleMem.TestSupport.FakeLLMClient

    @impl true
    def extract_window(dialogues, previous_entries, opts) do
      send(self(), {:extract_previous_entries, Enum.map(previous_entries, & &1.restatement)})
      FakeLLMClient.extract_window(dialogues, previous_entries, opts)
    end

    @impl true
    def synthesize(entries, previous_entries, opts) do
      FakeLLMClient.synthesize(entries, previous_entries, opts)
    end

    @impl true
    def plan(query, opts), do: FakeLLMClient.plan(query, opts)

    @impl true
    def reflect(query, records, plan, opts), do: FakeLLMClient.reflect(query, records, plan, opts)

    @impl true
    def answer(question, records, opts) when is_list(records) do
      case records do
        [%Record{} | _] -> FakeLLMClient.answer(question, records, opts)
        _ -> FakeLLMClient.answer(question, records, opts)
      end
    end
  end

  test "buffers incomplete turns, flushes on window completion, and finalizes trailing dialogue" do
    target = Factory.target("buffered-agent", window_size: 2, overlap_size: 1)

    assert {:ok, %{memory_count: 0, buffer_remaining: 1}} =
             SimpleMem.add_dialogue(target, "user", "My name is Alice Chen")

    assert {:ok, []} = SimpleMem.get_all_memories(target)

    assert {:ok, %{memory_count: 2, buffer_remaining: 1}} =
             SimpleMem.add_dialogue(target, "user", "I live in Portland")

    assert {:ok, records} = SimpleMem.get_all_memories(target)
    assert Enum.any?(records, &(&1.text == "The user's name is Alice Chen."))
    assert Enum.any?(records, &(&1.text == "The user lives in Portland."))

    assert {:ok, %{memory_count: 0, buffer_remaining: 0, finalized?: true}} =
             SimpleMem.finalize(target)
  end

  test "unfinished buffered dialogue survives reopen because the buffer is store-backed" do
    path = Factory.unique_path("reopen")
    first = Factory.target("reopen-agent", path: path, window_size: 3, overlap_size: 1)

    assert {:ok, %{buffer_remaining: 1}} =
             SimpleMem.add_dialogue(first, "user", "My name is Priya Sharma")

    reopened = Factory.target("reopen-agent", path: path, window_size: 3, overlap_size: 1)

    assert {:ok, %{memory_count: 3, buffer_remaining: 1}} =
             SimpleMem.add_dialogues(reopened, [
               %{speaker: "user", content: "I live in Berlin"},
               %{speaker: "user", content: "I prefer structured updates"}
             ])

    assert {:ok, records} = SimpleMem.get_all_memories(reopened)
    assert Enum.any?(records, &String.contains?(&1.text || "", "Priya Sharma"))
    assert Enum.any?(records, &String.contains?(&1.text || "", "Berlin"))
  end

  test "reopened sessions reuse persisted previous synthesized entries across finalize boundaries" do
    path = Factory.unique_path("previous_entries")

    first =
      Factory.target("previous-entry-agent",
        path: path,
        llm_client: PreviousEntryAwareLLMClient,
        window_size: 2,
        overlap_size: 1
      )

    assert {:ok, %{memory_count: 2, buffer_remaining: 1}} =
             SimpleMem.add_dialogues(first, [
               %{speaker: "user", content: "Alex Carter prefers green tea"},
               %{speaker: "user", content: "Alex Carter lives in Dublin"},
               %{speaker: "assistant", content: "Noted."}
             ])

    flush_previous_entry_messages()

    reopened =
      Factory.target("previous-entry-agent",
        path: path,
        llm_client: PreviousEntryAwareLLMClient,
        window_size: 2,
        overlap_size: 1
      )

    assert {:ok, %{finalized?: true}} = SimpleMem.finalize(reopened)
    assert_receive {:extract_previous_entries, previous_entries}
    assert Enum.any?(previous_entries, &String.contains?(&1, "Alex Carter prefers green tea"))
  end

  defp flush_previous_entry_messages do
    receive do
      {:extract_previous_entries, _entries} -> flush_previous_entry_messages()
    after
      0 -> :ok
    end
  end
end
