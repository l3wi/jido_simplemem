Code.require_file("simple_memory_agent.ex", __DIR__)

alias Jido.SimpleMem
alias Jido.SimpleMem.Examples.SimpleMemoryAgent

ensure_embedding_config! = fn ->
  llm_model = System.get_env("JIDO_SIMPLEMEM_LLM_MODEL")
  embedding_model = System.get_env("JIDO_SIMPLEMEM_EMBEDDING_MODEL")

  if is_nil(llm_model) or llm_model == "" do
    raise """
    Missing JIDO_SIMPLEMEM_LLM_MODEL.

    Example:
      export JIDO_SIMPLEMEM_LLM_MODEL="openai:gpt-4.1-mini"
      export JIDO_SIMPLEMEM_EMBEDDING_MODEL="openai:text-embedding-3-small"
      export OPENAI_API_KEY="..."
    """
  end

  if is_nil(embedding_model) or embedding_model == "" do
    raise """
    Missing JIDO_SIMPLEMEM_EMBEDDING_MODEL.

    Example:
      export JIDO_SIMPLEMEM_LLM_MODEL="openai:gpt-4.1-mini"
      export JIDO_SIMPLEMEM_EMBEDDING_MODEL="openai:text-embedding-3-small"
      export OPENAI_API_KEY="..."
    """
  end

  {:ok, llm_model_struct} = ReqLLM.model(llm_model)
  {:ok, embedding_model_struct} = ReqLLM.Embedding.validate_model(embedding_model)
  llm_env_var = ReqLLM.Keys.env_var_name(llm_model_struct.provider)
  embedding_env_var = ReqLLM.Keys.env_var_name(embedding_model_struct.provider)

  case System.get_env(llm_env_var) do
    value when is_binary(value) and value != "" -> :ok
    _ -> raise "Missing provider API key env var for LLM model: #{llm_env_var}"
  end

  case System.get_env(embedding_env_var) do
    value when is_binary(value) and value != "" -> :ok
    _ -> raise "Missing provider API key env var for embedding model: #{embedding_env_var}"
  end
end

ensure_embedding_config!.()

agent = SimpleMemoryAgent.new(id: "demo-memory-agent")

IO.puts("\n== Buffered Chat ==")

{:ok, agent, response} =
  SimpleMemoryAgent.chat(
    agent,
    "My name is Alice Chen and I live in Portland and I prefer concise answers."
  )

IO.puts("User: My name is Alice Chen and I live in Portland and I prefer concise answers.")
IO.puts("Agent: #{response}")

{:ok, agent, response} = SimpleMemoryAgent.chat(agent, "Remember that I am allergic to peanuts.")
IO.puts("\nUser: Remember that I am allergic to peanuts.")
IO.puts("Agent: #{response}")

IO.puts("\n== Finalize Buffered Memory ==")

{:ok, agent, flushed_count} = SimpleMemoryAgent.finalize_memory(agent)
IO.puts("Finalized #{flushed_count} buffered memories.")

{:ok, agent, response} = SimpleMemoryAgent.chat(agent, "Where do I live?")
IO.puts("\nUser: Where do I live?")
IO.puts("Agent: #{response}")

{:ok, agent, response} = SimpleMemoryAgent.chat(agent, "What do I prefer?")
IO.puts("\nUser: What do I prefer?")
IO.puts("Agent: #{response}")

{:ok, agent, response} = SimpleMemoryAgent.chat(agent, "What am I allergic to?")
IO.puts("\nUser: What am I allergic to?")
IO.puts("Agent: #{response}")

IO.puts("\n== Inspect Memory ==")

{:ok, records} = SimpleMem.get_all_memories(agent)

Enum.each(records, fn record ->
  IO.puts("- #{record.id}: #{record.text}")
end)

alice_location_record =
  Enum.find(records, fn record ->
    String.contains?(record.text || "", "Portland")
  end)

IO.puts("\n== Delete One Memory ==")

if alice_location_record do
  {:ok, deleted?} = SimpleMem.delete_memory(agent, alice_location_record.id)
  IO.puts("Deleted location memory? #{deleted?}")
else
  IO.puts("No location memory found to delete.")
end

IO.puts("\n== Ask Again After Delete ==")

{:ok, _agent, response} = SimpleMemoryAgent.chat(agent, "Where do I live?")
IO.puts("User: Where do I live?")
IO.puts("Agent: #{response}")
