defmodule Jido.SimpleMem.Integration.LivePrepushParityTest do
  use ExUnit.Case, async: false

  alias Jido.SimpleMem
  alias Jido.SimpleMem.Config
  alias Jido.SimpleMem.Store.Lance

  @moduletag :integration
  @moduletag :prepush
  @moduletag timeout: 600_000

  test "runs the multi-agent multi-namespace parity flow and prints usage telemetry" do
    unless live_env_ready?() do
      IO.puts("""
      skipping live pre-push parity test
      set JIDO_SIMPLEMEM_ENABLE_LIVE_LANCE_TESTS=1, JIDO_SIMPLEMEM_LLM_MODEL,
      JIDO_SIMPLEMEM_EMBEDDING_MODEL, and the matching provider API key to enable it
      """)

      assert true
    else
      path =
        Path.expand(".tmp/live_prepush_#{System.unique_integer([:positive])}.lance", File.cwd!())

      usage_recorder = self()

      alice_writer =
        live_target("alice-writer",
          path: path,
          namespace: "tenant:acme:user:alice",
          session_id: "alice-primary",
          usage_recorder: usage_recorder
        )

      alice_reader =
        live_target("alice-reader",
          path: path,
          namespace: "tenant:acme:user:alice",
          session_id: "alice-secondary",
          usage_recorder: usage_recorder
        )

      bob_agent =
        live_target("bob-agent",
          path: path,
          namespace: "tenant:acme:user:bob",
          session_id: "bob-primary",
          usage_recorder: usage_recorder
        )

      assert {:ok, _} =
               SimpleMem.add_dialogues(alice_writer, [
                 %{
                   speaker: "user",
                   content:
                     "Remember this: Morgan Lee is Alice Chen's brother, lives in Denver, and prefers pour-over coffee."
                 },
                 %{
                   speaker: "user",
                   content: "Remember this: Morgan Lee is allergic to peanuts."
                 },
                 %{
                   speaker: "user",
                   content:
                     "Remember this: Megan Lee works at Northwind and her design review is on April 12, 2026 at 3:00 PM in Austin."
                 },
                 %{
                   speaker: "user",
                   content: "Remember this: Megan Lee prefers black tea."
                 }
               ])

      assert {:ok, %{finalized?: true}} = SimpleMem.finalize(alice_writer)

      assert {:ok, _} =
               SimpleMem.add_dialogues(alice_reader, [
                 %{
                   speaker: "user",
                   content:
                     "Remember this: Priya Sharma manages the Berlin office and prefers concise status updates."
                 },
                 %{
                   speaker: "assistant",
                   content: "Understood."
                 }
               ])

      assert {:ok, %{finalized?: true}} = SimpleMem.finalize(alice_reader)

      assert {:ok, _} =
               SimpleMem.add_dialogues(bob_agent, [
                 %{
                   speaker: "user",
                   content: "Remember this: Morgan Lee lives in Portland and prefers espresso."
                 },
                 %{
                   speaker: "user",
                   content: "Remember this: Megan Lee lives in Denver and prefers green tea."
                 },
                 %{
                   speaker: "user",
                   content: "Remember this: Priya Sharma manages the Lisbon office."
                 }
               ])

      assert {:ok, %{finalized?: true}} = SimpleMem.finalize(bob_agent)

      assert {:ok, alice_preference} = SimpleMem.ask(alice_reader, "What does Morgan Lee prefer?")

      assert contains_text?(alice_preference.answer, "pour-over") or
               contains_text?(alice_preference.answer, "coffee")

      refute contains_text?(alice_preference.answer, "espresso")
      refute contains_text?(alice_preference.answer, "black tea")

      assert {:ok, alice_review} =
               SimpleMem.ask(alice_reader, "When and where is Megan Lee's design review?")

      assert contains_text?(alice_review.answer, "Austin")
      assert contains_any?(alice_review.answer, ["2026", "April 12", "3:00 PM", "3 PM"])

      assert {:ok, alice_manager} = SimpleMem.ask(alice_reader, "Who manages the Berlin office?")
      assert contains_text?(alice_manager.answer, "Priya Sharma")
      assert contains_text?(alice_manager.answer, "Berlin")

      assert {:ok, bob_morgan} = SimpleMem.ask(bob_agent, "Where does Morgan Lee live?")
      assert contains_text?(bob_morgan.answer, "Portland")

      assert {:ok, alice_memories} = SimpleMem.get_all_memories(alice_reader)
      assert Enum.any?(alice_memories, &contains_text?(&1.text, "peanut"))
      assert Enum.any?(alice_memories, &contains_text?(&1.text, "concise status updates"))

      assert {:ok, bob_memories} = SimpleMem.get_all_memories(bob_agent)
      assert Enum.any?(bob_memories, &contains_text?(&1.text, "green tea"))
      refute Enum.any?(bob_memories, &contains_text?(&1.text, "black tea"))

      morgan_preference_record =
        Enum.find(alice_memories, fn record ->
          contains_text?(record.text, "Morgan Lee") and
            (contains_text?(record.text, "pour-over") or contains_text?(record.text, "coffee"))
        end)

      assert morgan_preference_record
      assert {:ok, true} = SimpleMem.delete_memory(alice_reader, morgan_preference_record.id)

      assert {:ok, after_delete} = SimpleMem.get_all_memories(alice_reader)
      refute Enum.any?(after_delete, &(&1.id == morgan_preference_record.id))

      usage_events = drain_usage_events([])
      print_usage_summary(usage_events)
      assert usage_events != []
    end
  end

  defp live_target(agent_id, opts) do
    llm_opts =
      Config.default_llm_client_opts()
      |> Keyword.put(:usage_recorder, Keyword.fetch!(opts, :usage_recorder))

    embedding_opts =
      Config.default_embedding_client_opts()
      |> Keyword.put(:usage_recorder, Keyword.fetch!(opts, :usage_recorder))

    %{
      id: agent_id,
      state: %{
        __simplemem__: %{
          namespace: Keyword.fetch!(opts, :namespace),
          session_id: Keyword.fetch!(opts, :session_id),
          store: {Lance, [path: Keyword.fetch!(opts, :path)] ++ Config.default_worker_opts()},
          store_opts: [path: Keyword.fetch!(opts, :path)] ++ Config.default_worker_opts(),
          llm_client: Jido.SimpleMem.LLMClient.ReqLLM,
          llm_client_opts: llm_opts,
          embedding_client: Jido.SimpleMem.EmbeddingClient.ReqLLM,
          embedding_client_opts: embedding_opts,
          window_size: 12,
          overlap_size: 0,
          enable_parallel_processing: false,
          max_parallel_workers: 2,
          enable_parallel_retrieval: false,
          max_retrieval_workers: 2,
          enable_planning: true,
          retrieval_limit: 8,
          context_token_budget: 2_400,
          tokens_before_finalize: 0,
          reflection_enabled: false,
          max_reflection_rounds: 0
        }
      }
    }
  end

  defp drain_usage_events(events) do
    receive do
      {:simplemem_usage, event} ->
        drain_usage_events([event | events])
    after
      50 ->
        Enum.reverse(events)
    end
  end

  defp print_usage_summary(events) do
    summary =
      Enum.reduce(
        events,
        %{
          calls: 0,
          input: 0,
          output: 0,
          total: 0,
          reasoning: 0,
          cost: 0.0,
          priced_calls: 0,
          by_stage: %{}
        },
        fn event, acc ->
          usage = event[:usage] || %{}
          stage = event[:stage] || :unknown
          input = usage[:input_tokens] || usage["input_tokens"] || 0
          output = usage[:output_tokens] || usage["output_tokens"] || 0
          total = usage[:total_tokens] || usage["total_tokens"] || input + output
          reasoning = usage[:reasoning_tokens] || usage["reasoning_tokens"] || 0
          cost = usage[:total_cost] || usage["total_cost"] || usage[:cost] || usage["cost"]

          %{
            calls: acc.calls + 1,
            input: acc.input + input,
            output: acc.output + output,
            total: acc.total + total,
            reasoning: acc.reasoning + reasoning,
            cost: acc.cost + if(is_number(cost), do: cost, else: 0.0),
            priced_calls: acc.priced_calls + if(is_number(cost), do: 1, else: 0),
            by_stage: Map.update(acc.by_stage, stage, 1, &(&1 + 1))
          }
        end
      )

    IO.puts("\nSimpleMem pre-push usage summary")
    IO.puts("calls: #{summary.calls}")
    IO.puts("input tokens: #{summary.input}")
    IO.puts("output tokens: #{summary.output}")
    IO.puts("total tokens: #{summary.total}")
    IO.puts("reasoning tokens: #{summary.reasoning}")

    if summary.priced_calls > 0 do
      IO.puts("reported cost: $" <> :erlang.float_to_binary(summary.cost, decimals: 6))
    else
      IO.puts("reported cost: not provided by provider")
    end

    IO.puts(
      "calls by stage: " <>
        (summary.by_stage
         |> Enum.sort_by(fn {stage, _count} -> Atom.to_string(stage) end)
         |> Enum.map_join(", ", fn {stage, count} -> "#{stage}=#{count}" end))
    )
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

  defp contains_any?(value, fragments) when is_binary(value) and is_list(fragments) do
    Enum.any?(fragments, &contains_text?(value, &1))
  end

  defp contains_any?(_, _), do: false
end
