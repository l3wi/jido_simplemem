defmodule Jido.SimpleMem.PluginTest do
  use ExUnit.Case, async: true

  alias Jido.SimpleMem.Actions.{Answer, PostTurn, PreTurn, Remember, Retrieve}
  alias Jido.SimpleMem.Plugin
  alias Jido.SimpleMem.Store.{InMemory, SQLite}

  setup do
    table = String.to_atom("jido_simplemem_plugin_#{System.unique_integer([:positive])}")
    assert :ok = InMemory.ensure_ready(table: table)
    %{table: table}
  end

  test "mount resolves per-agent namespace and store", %{table: table} do
    assert {:ok, state} =
             Plugin.mount(%{id: "agent-1"}, %{
               store: {InMemory, [table: table]},
               store_opts: [table: table]
             })

    assert state.namespace == "agent:agent-1"
    assert state.store == {InMemory, [table: table]}
  end

  test "mount defaults to local sqlite when no store is configured" do
    assert {:ok, state} = Plugin.mount(%{id: "agent-default"}, %{})

    assert state.namespace == "agent:agent-default"
    assert {SQLite, opts} = state.store
    assert is_binary(opts[:path])
    assert state.embedding_client == Jido.SimpleMem.EmbeddingClient.ReqLLM
  end

  test "signal routes expose explicit plugin actions" do
    routes = Plugin.signal_routes(%{})
    assert {"remember", Remember} in routes
    assert {"retrieve", Retrieve} in routes
    assert {"answer", Answer} in routes
  end

  test "handle_signal auto-captures configured patterns", %{table: table} do
    {:ok, plugin_state} =
      Plugin.mount(%{id: "agent-cap"}, %{
        store: {InMemory, [table: table]},
        store_opts: [table: table],
        embedding_client: Jido.SimpleMem.TestSupport.FakeEmbeddingClient,
        capture_signal_patterns: ["ai.react.query"]
      })

    agent = %{id: "agent-cap", state: %{__simplemem__: plugin_state}}
    context = %{agent: agent}
    signal = Jido.Signal.new!("ai.react.query", %{query: "what happened?"}, source: "/ai")

    assert {:ok, :continue} = Plugin.handle_signal(signal, context)
    assert {:ok, records} = Jido.SimpleMem.retrieve(agent, "what happened?")
    assert Enum.any?(records, &(&1.kind == :query))
  end

  test "pre_turn and post_turn actions work with plugin-mounted state", %{table: table} do
    {:ok, plugin_state} =
      Plugin.mount(%{id: "agent-actions"}, %{
        store: {InMemory, [table: table]},
        store_opts: [table: table],
        embedding_client: Jido.SimpleMem.TestSupport.FakeEmbeddingClient
      })

    agent = %{id: "agent-actions", state: %{__simplemem__: plugin_state}}

    assert {:ok, %{last_memory_id: _}} =
             PostTurn.run(
               %{text: "Alice prefers bullet points", tags: ["persona:style"]},
               agent
             )

    assert {:ok, %{simplemem_context: context_text, memory_results: records}} =
             PreTurn.run(%{question: "What does Alice prefer?"}, agent)

    assert context_text =~ "Alice"
    assert length(records) >= 1
  end
end
