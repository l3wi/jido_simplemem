defmodule Jido.SimpleMem.EmbeddingClient.ReqLLMTest do
  use ExUnit.Case, async: false

  alias Jido.SimpleMem.EmbeddingClient.ReqLLM

  setup do
    env_keys = ["JIDO_SIMPLEMEM_EMBEDDING_MODEL", "OPENAI_API_KEY"]
    previous = Map.new(env_keys, &{&1, System.get_env(&1)})

    Enum.each(env_keys, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "fails when embedding model is not specified" do
    assert {:error, error} = ReqLLM.embed("hello world", [])
    assert Exception.message(error) =~ "embedding model required"
  end

  test "fails when provider API key env var is missing" do
    assert {:error, error} =
             ReqLLM.embed("hello world", model: "openai:text-embedding-3-small")

    assert Exception.message(error) =~ "provider API key required for embeddings"
    assert Exception.message(error) =~ "OPENAI_API_KEY"
  end
end
