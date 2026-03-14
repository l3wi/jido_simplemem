defmodule Jido.SimpleMem.Integration.LiveEmbeddingFlowTest do
  use ExUnit.Case, async: false

  alias Jido.SimpleMem.{EmbeddingClient, Store.SQLite}

  @embedding_model System.get_env("JIDO_SIMPLEMEM_EMBEDDING_MODEL")

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "jido_simplemem_live_#{System.unique_integer([:positive])}.sqlite3"
      )

    on_exit(fn -> File.rm(path) end)

    target = %{
      id: "live-embedding-agent",
      state: %{
        __simplemem__: %{
          namespace: "agent:live-embedding-agent",
          store: {SQLite, [path: path]},
          store_opts: [path: path],
          llm_client: Jido.SimpleMem.LLMClient.Noop,
          llm_client_opts: [],
          embedding_client: EmbeddingClient.ReqLLM,
          embedding_client_opts: [model: @embedding_model],
          retrieval_limit: 5,
          context_token_budget: 1200,
          reflection_enabled: true,
          max_reflection_rounds: 2
        }
      }
    }

    %{target: target, path: path, live_embedding_ready?: live_embedding_ready?()}
  end

  test "embeds, retrieves, disambiguates, and forgets with a live provider", %{
    target: target,
    live_embedding_ready?: ready?
  } do
    if ready? do
      {:ok, lee} =
        Jido.SimpleMem.remember(target, %{
          class: :semantic,
          kind: :profile,
          text:
            "Morgan Lee is a backend engineer in Denver who prefers coffee and leads the billing service",
          persons: ["Morgan Lee"],
          topic: "profile"
        })

      {:ok, reed} =
        Jido.SimpleMem.remember(target, %{
          class: :semantic,
          kind: :profile,
          text:
            "Morgan Reed is a product manager in Seattle who prefers tea and owns roadmap reviews",
          persons: ["Morgan Reed"],
          topic: "profile"
        })

      {:ok, _stone} =
        Jido.SimpleMem.remember(target, %{
          class: :semantic,
          kind: :profile,
          text:
            "Morgana Stone is a designer in Denver who prefers sparkling water and runs brand workshops",
          persons: ["Morgana Stone"],
          topic: "profile"
        })

      assert {:ok, where_explain} =
               Jido.SimpleMem.explain(target, "Where does Morgan Reed work from?")

      [where_top | _] = where_explain.records
      assert where_top.text =~ "Morgan Reed"
      assert where_top.text =~ "Seattle"
      refute where_top.text =~ "Morgan Lee"

      assert {:ok, answer} = Jido.SimpleMem.answer(target, "What does Morgan Lee prefer?")
      assert answer.answer =~ "Morgan Lee"
      assert answer.answer =~ "coffee"
      refute answer.answer =~ "tea"

      assert {:ok, true} = Jido.SimpleMem.forget(target, lee.id)

      assert {:ok, after_forget} = Jido.SimpleMem.retrieve(target, "What does Morgan Lee prefer?")
      refute Enum.any?(after_forget, &(&1.id == lee.id))

      assert {:ok, remaining} = Jido.SimpleMem.retrieve(target, "What does Morgan Reed prefer?")
      assert Enum.any?(remaining, &(&1.id == reed.id))
    else
      IO.puts(
        "Skipping live embedding integration: requires JIDO_SIMPLEMEM_EMBEDDING_MODEL and the provider API key env var"
      )

      assert true
    end
  end

  defp live_embedding_ready? do
    case @embedding_model do
      model when is_binary(model) and model != "" ->
        with {:ok, model_struct} <- ReqLLM.Embedding.validate_model(model),
             env_var when is_binary(env_var) <- ReqLLM.Keys.env_var_name(model_struct.provider),
             value when is_binary(value) and value != "" <- System.get_env(env_var) do
          true
        else
          _ -> false
        end

      _ ->
        false
    end
  end
end
