defmodule Jido.SimpleMem.TestSupport.Factory do
  alias Jido.SimpleMem.Store.Lance
  alias Jido.SimpleMem.TestSupport.{FakeEmbeddingClient, FakeLanceClient, FakeLLMClient}

  def unique_path(label) do
    Path.expand(".tmp/#{label}_#{System.unique_integer([:positive])}.lance", File.cwd!())
  end

  def target(agent_id, opts \\ []) do
    path = Keyword.get(opts, :path, unique_path(agent_id))
    namespace = Keyword.get(opts, :namespace, "agent:#{agent_id}")
    session_id = Keyword.get(opts, :session_id, agent_id)
    llm_client = Keyword.get(opts, :llm_client, FakeLLMClient)
    llm_client_opts = Keyword.get(opts, :llm_client_opts, [])
    embedding_client = Keyword.get(opts, :embedding_client, FakeEmbeddingClient)
    embedding_client_opts = Keyword.get(opts, :embedding_client_opts, [])
    store_opts = [path: path, client: FakeLanceClient]

    %{
      id: agent_id,
      state: %{
        __simplemem__: %{
          namespace: namespace,
          session_id: session_id,
          store: {Lance, store_opts},
          store_opts: store_opts,
          llm_client: llm_client,
          llm_client_opts: llm_client_opts,
          embedding_client: embedding_client,
          embedding_client_opts: embedding_client_opts,
          window_size: Keyword.get(opts, :window_size, 2),
          overlap_size: Keyword.get(opts, :overlap_size, 1),
          enable_parallel_processing: false,
          max_parallel_workers: 2,
          enable_parallel_retrieval: false,
          max_retrieval_workers: 2,
          enable_planning: true,
          retrieval_limit: Keyword.get(opts, :retrieval_limit, 5),
          context_token_budget: 1200,
          reflection_enabled: Keyword.get(opts, :reflection_enabled, true),
          max_reflection_rounds: Keyword.get(opts, :max_reflection_rounds, 2)
        }
      }
    }
  end
end
