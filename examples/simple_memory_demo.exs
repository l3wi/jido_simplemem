Code.require_file("simple_memory_agent.ex", __DIR__)

alias Jido.SimpleMem.Examples.SimpleMemoryAgent

ensure_embedding_config! = fn ->
  model = System.get_env("JIDO_SIMPLEMEM_EMBEDDING_MODEL")

  if is_nil(model) or model == "" do
    raise """
    Missing JIDO_SIMPLEMEM_EMBEDDING_MODEL.

    Example:
      export JIDO_SIMPLEMEM_EMBEDDING_MODEL="openai:text-embedding-3-small"
      export OPENAI_API_KEY="..."
    """
  end

  {:ok, model_struct} = ReqLLM.Embedding.validate_model(model)
  env_var = ReqLLM.Keys.env_var_name(model_struct.provider)

  case System.get_env(env_var) do
    value when is_binary(value) and value != "" ->
      :ok

    _ ->
      raise """
      Missing provider API key env var for embeddings: #{env_var}

      Example:
        export JIDO_SIMPLEMEM_EMBEDDING_MODEL="#{model}"
        export #{env_var}="..."
      """
  end
end

ensure_embedding_config!.()

agent = SimpleMemoryAgent.new(id: "demo-memory-agent")

IO.puts("\n== Remember facts ==")

{:ok, agent, alice_id} =
  SimpleMemoryAgent.remember(agent, "Alice prefers concise answers and lives in Portland", %{
    persons: ["Alice"],
    topic: "profile"
  })

IO.puts("Stored Alice memory: #{alice_id}")

{:ok, agent, bob_id} =
  SimpleMemoryAgent.remember(agent, "Bob prefers detailed reports and lives in Austin", %{
    persons: ["Bob"],
    topic: "profile"
  })

IO.puts("Stored Bob memory: #{bob_id}")

IO.puts("\n== Retrieve ==")

{:ok, agent, records} = SimpleMemoryAgent.query(agent, "What does Alice prefer?")

Enum.each(records, fn record ->
  IO.puts("- #{record.id}: #{record.text}")
end)

IO.puts("\n== Answer ==")

{:ok, agent, answer} = SimpleMemoryAgent.answer_from_memory(agent, "What does Bob prefer?")
IO.puts(answer || "<no answer>")

IO.puts("\n== Forget Alice ==")

{:ok, agent, deleted?} = SimpleMemoryAgent.forget(agent, alice_id)
IO.puts("Deleted Alice memory? #{deleted?}")

IO.puts("\n== Retrieve After Forget ==")

{:ok, _agent, after_forget} = SimpleMemoryAgent.query(agent, "What does Alice prefer?")

if after_forget == [] do
  IO.puts("No Alice memory found.")
else
  Enum.each(after_forget, fn record ->
    IO.puts("- #{record.id}: #{record.text}")
  end)
end
