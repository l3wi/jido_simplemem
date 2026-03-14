defmodule Jido.SimpleMem.SynthesizerTest do
  use ExUnit.Case, async: true

  alias Jido.SimpleMem.{Extractor, Store.InMemory, Synthesizer}

  setup do
    table = String.to_atom("jido_simplemem_synth_#{System.unique_integer([:positive])}")
    assert :ok = InMemory.ensure_ready(table: table)

    runtime = %{
      namespace: "agent:synth",
      store_mod: InMemory,
      store_opts: [table: table],
      llm_client: Jido.SimpleMem.LLMClient.Noop,
      llm_opts: [],
      embedding_client: Jido.SimpleMem.TestSupport.FakeEmbeddingClient,
      embedding_opts: [],
      now: System.system_time(:millisecond)
    }

    %{runtime: runtime, table: table}
  end

  test "does not merge different people with similar profile language", %{runtime: runtime} do
    assert {:ok, left} =
             Extractor.extract(
               %{
                 text: "Alice Johnson lives in Portland and prefers espresso",
                 persons: ["Alice Johnson"],
                 topic: "profile"
               },
               runtime
             )

    assert {:ok, stored_left} = runtime.store_mod.put(left, runtime.store_opts)

    assert {:ok, right} =
             Extractor.extract(
               %{
                 text: "Alice Smith lives in Austin and prefers green tea",
                 persons: ["Alice Smith"],
                 topic: "profile"
               },
               runtime
             )

    assert {:ok, result} = Synthesizer.synthesize(right, runtime)
    assert result.id != stored_left.id
    assert result.persons == ["Alice Smith"]
  end
end
