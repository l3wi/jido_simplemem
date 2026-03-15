defmodule Jido.SimpleMem.ConfigTest do
  use ExUnit.Case, async: false

  alias Jido.SimpleMem.Config
  alias Jido.SimpleMem.Store.Lance

  setup do
    original = System.get_env()

    on_exit(fn ->
      Enum.each(System.get_env(), fn {key, _value} -> System.delete_env(key) end)
      Enum.each(original, fn {key, value} -> System.put_env(key, value) end)
    end)
  end

  test "defaults choose the Lance store and local lance path" do
    System.delete_env("JIDO_SIMPLEMEM_LANCE_PATH")

    defaults = Config.defaults()

    assert {Lance, opts} = defaults.store
    assert is_binary(opts[:path])
    assert String.ends_with?(opts[:path], ".jido/simplemem.lance")
    assert defaults.tokens_before_finalize == 60
  end

  test "llm client opts reuse the shared model and include synthesis model" do
    System.put_env("JIDO_SIMPLEMEM_LLM_MODEL", "openai:gpt-4.1-mini")
    System.delete_env("JIDO_SIMPLEMEM_SYNTHESIS_MODEL")
    System.delete_env("JIDO_SIMPLEMEM_BASE_URL")
    System.put_env("JIDO_SIMPLEMEM_API_KEY", "endpoint-key-should-not-be-used")

    opts = Config.default_llm_client_opts()

    assert opts[:model] == "openai:gpt-4.1-mini"
    assert opts[:extraction_model] == "openai:gpt-4.1-mini"
    assert opts[:synthesis_model] == "openai:gpt-4.1-mini"
    assert opts[:planning_model] == "openai:gpt-4.1-mini"
    assert opts[:answer_model] == "openai:gpt-4.1-mini"
    refute Keyword.has_key?(opts, :api_key)
  end

  test "custom base url env builds openai-compatible model specs and passes explicit api key" do
    System.put_env("JIDO_SIMPLEMEM_BASE_URL", "https://custom.example.com/v1")
    System.put_env("JIDO_SIMPLEMEM_LLM_MODEL", "openai/gpt-5-mini")
    System.put_env("JIDO_SIMPLEMEM_EMBEDDING_MODEL", "openai/text-embedding-3-small")
    System.put_env("JIDO_SIMPLEMEM_EMBEDDING_DIMENSIONS", "1024")
    System.put_env("JIDO_SIMPLEMEM_API_KEY", "test-endpoint-key")
    System.put_env("JIDO_SIMPLEMEM_RECEIVE_TIMEOUT_MS", "300000")
    System.put_env("JIDO_SIMPLEMEM_POOL_TIMEOUT_MS", "300000")

    llm_opts = Config.default_llm_client_opts()
    embedding_opts = Config.default_embedding_client_opts()

    assert llm_opts[:api_key] == "test-endpoint-key"
    assert embedding_opts[:api_key] == "test-endpoint-key"
    assert embedding_opts[:dimensions] == 1024
    assert llm_opts[:receive_timeout] == 300_000
    assert llm_opts[:req_http_options][:pool_timeout] == 300_000

    assert llm_opts[:model] == %{
             provider: :openai,
             id: "openai/gpt-5-mini",
             base_url: "https://custom.example.com/v1"
           }

    assert embedding_opts[:model] == %{
             provider: :openai,
             id: "openai/text-embedding-3-small",
             base_url: "https://custom.example.com/v1"
           }
  end

  test "default store includes worker opts from env" do
    System.put_env("JIDO_SIMPLEMEM_LANCE_PATH", "/tmp/simplemem.lance")
    System.put_env("JIDO_SIMPLEMEM_UV_EXECUTABLE", "/opt/homebrew/bin/uv")
    System.put_env("JIDO_SIMPLEMEM_PYTHON_EXECUTABLE", "/usr/bin/python3")
    System.put_env("JIDO_SIMPLEMEM_WORKER_START_TIMEOUT_MS", "90000")
    System.put_env("JIDO_SIMPLEMEM_EMBEDDING_DIMENSIONS", "1536")

    {Lance, opts} = Config.default_store()

    assert opts[:path] == "/tmp/simplemem.lance"
    assert opts[:uv_executable] == "/opt/homebrew/bin/uv"
    assert opts[:python_executable] == "/usr/bin/python3"
    assert opts[:worker_start_timeout_ms] == 90_000
    assert opts[:vector_dimensions] == 1536
  end
end
