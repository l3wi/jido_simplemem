defmodule Jido.SimpleMem.Integration.LiveLanceFlowTest do
  use ExUnit.Case, async: false

  alias Jido.SimpleMem
  alias Jido.SimpleMem.Config
  alias Jido.SimpleMem.Store.Lance

  @moduletag :integration
  @moduletag timeout: 180_000

  test "runs the full LLM + embedding + Lance flow with recall, disambiguation, and delete" do
    unless live_env_ready?() do
      IO.puts("""
      skipping live Lance integration test
      set JIDO_SIMPLEMEM_ENABLE_LIVE_LANCE_TESTS=1, JIDO_SIMPLEMEM_LLM_MODEL,
      JIDO_SIMPLEMEM_EMBEDDING_MODEL, and the matching provider API key to enable it
      """)

      assert true
    else
      path = Path.expand(".tmp/live_#{System.unique_integer([:positive])}.lance", File.cwd!())

      target = %{
        id: "live-lance-agent",
        state: %{
          __simplemem__: %{
            namespace: "agent:live-lance-agent:#{System.unique_integer([:positive])}",
            session_id: "live-lance-agent",
            store: {Lance, [path: path] ++ Config.default_worker_opts()},
            store_opts: [path: path] ++ Config.default_worker_opts(),
            llm_client: Jido.SimpleMem.LLMClient.ReqLLM,
            llm_client_opts: Config.default_llm_client_opts(),
            embedding_client: Jido.SimpleMem.EmbeddingClient.ReqLLM,
            embedding_client_opts: Config.default_embedding_client_opts(),
            window_size: 2,
            overlap_size: 1,
            enable_parallel_processing: false,
            max_parallel_workers: 2,
            enable_parallel_retrieval: false,
            max_retrieval_workers: 2,
            enable_planning: true,
            retrieval_limit: 6,
            context_token_budget: 1_200,
            reflection_enabled: true,
            max_reflection_rounds: 2
          }
        }
      }

      assert {:ok, _result} =
               SimpleMem.add_dialogues(target, [
                 %{
                   speaker: "user",
                   content:
                     "Remember this durable fact: Morgan Lee lives in Denver and prefers pour-over coffee."
                 },
                 %{
                   speaker: "user",
                   content:
                     "Remember this durable fact: Megan Lee lives in Austin and prefers black tea."
                 }
               ])

      assert {:ok, _finalized} = SimpleMem.finalize(target)

      assert {:ok, result} = SimpleMem.ask(target, "What does Morgan Lee prefer?")
      assert contains_text?(result.answer, "pour-over") or contains_text?(result.answer, "coffee")
      refute contains_text?(result.answer, "black tea")
      assert length(result.records) >= 1

      assert {:ok, result} = SimpleMem.ask(target, "Where does Megan Lee live?")
      assert contains_text?(result.answer, "Austin")
      refute contains_text?(result.answer, "Denver")

      combined_records =
        Enum.uniq_by(
          result.records ++
            case SimpleMem.ask(target, "What does Morgan Lee prefer?") do
              {:ok, response} -> response.records
              _ -> []
            end,
          & &1.id
        )

      morgan_record =
        Enum.find(combined_records, fn record ->
          contains_text?(record.text, "Morgan Lee") and contains_text?(record.text, "coffee")
        end)

      assert morgan_record
      assert {:ok, true} = SimpleMem.delete_memory(target, morgan_record.id)

      assert {:ok, after_delete} = SimpleMem.ask(target, "What does Morgan Lee prefer?")
      refute Enum.any?(after_delete.records, &(&1.id == morgan_record.id))
    end
  end

  defp live_env_ready? do
    llm_opts = Config.default_llm_client_opts()
    embedding_opts = Config.default_embedding_client_opts()

    with "1" <- System.get_env("JIDO_SIMPLEMEM_ENABLE_LIVE_LANCE_TESTS"),
         llm_model when not is_nil(llm_model) <- llm_opts[:model],
         embedding_model when not is_nil(embedding_model) <- embedding_opts[:model],
         {:ok, validated_llm_model} <- ReqLLM.model(llm_model),
         {:ok, validated_embedding_model} <- ReqLLM.Embedding.validate_model(embedding_model),
         true <- auth_present?(validated_llm_model.provider, llm_opts),
         true <- auth_present?(validated_embedding_model.provider, embedding_opts),
         uv when is_binary(uv) <- System.find_executable("uv") do
      File.exists?(uv)
    else
      _ -> false
    end
  end

  defp auth_present?(provider, opts) do
    case Keyword.get(opts, :api_key) do
      value when is_binary(value) and value != "" ->
        true

      _ ->
        case System.get_env(ReqLLM.Keys.env_var_name(provider)) do
          value when is_binary(value) and value != "" -> true
          _ -> false
        end
    end
  end

  defp contains_text?(value, fragment)
       when is_binary(value) and is_binary(fragment) do
    String.contains?(String.downcase(value), String.downcase(fragment))
  end

  defp contains_text?(_, _), do: false
end
