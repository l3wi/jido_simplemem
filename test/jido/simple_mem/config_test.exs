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
  end

  test "llm client opts reuse the shared model and include synthesis model" do
    System.put_env("JIDO_SIMPLEMEM_LLM_MODEL", "openai:gpt-4.1-mini")
    System.delete_env("JIDO_SIMPLEMEM_SYNTHESIS_MODEL")
    System.delete_env("JIDO_SIMPLEMEM_GATEWAY_BASE_URL")
    System.delete_env("AI_GATEWAY_API_KEY")
    System.delete_env("VERCEL_API_KEY")

    opts = Config.default_llm_client_opts()

    assert opts[:model] == "openai:gpt-4.1-mini"
    assert opts[:extraction_model] == "openai:gpt-4.1-mini"
    assert opts[:synthesis_model] == "openai:gpt-4.1-mini"
    assert opts[:planning_model] == "openai:gpt-4.1-mini"
    assert opts[:answer_model] == "openai:gpt-4.1-mini"
  end

  test "gateway env builds openai-compatible model specs and passes vercel api key" do
    System.put_env("JIDO_SIMPLEMEM_GATEWAY_BASE_URL", "https://gateway.ai.vercel.com/v1")
    System.put_env("JIDO_SIMPLEMEM_LLM_MODEL", "alibaba/qwen3.5-plus")
    System.put_env("JIDO_SIMPLEMEM_EMBEDDING_MODEL", "alibaba/qwen3-embedding-4b")
    System.put_env("AI_GATEWAY_API_KEY", "test-gateway-key")
    System.put_env("JIDO_SIMPLEMEM_GATEWAY_RECEIVE_TIMEOUT_MS", "300000")
    System.put_env("JIDO_SIMPLEMEM_GATEWAY_POOL_TIMEOUT_MS", "300000")
    System.put_env("JIDO_SIMPLEMEM_GATEWAY_CONNECT_TIMEOUT_MS", "60000")

    llm_opts = Config.default_llm_client_opts()
    embedding_opts = Config.default_embedding_client_opts()

    assert llm_opts[:api_key] == "test-gateway-key"
    assert embedding_opts[:api_key] == "test-gateway-key"
    assert llm_opts[:receive_timeout] == 300_000
    assert llm_opts[:req_http_options][:pool_timeout] == 300_000
    assert llm_opts[:req_http_options][:connect_options][:timeout] == 60_000
    assert llm_opts[:model] == %{provider: :openai, id: "alibaba/qwen3.5-plus", base_url: "https://gateway.ai.vercel.com/v1"}
    assert embedding_opts[:model] == %{provider: :openai, id: "alibaba/qwen3-embedding-4b", base_url: "https://gateway.ai.vercel.com/v1"}
  end

  test "default store includes worker opts from env" do
    System.put_env("JIDO_SIMPLEMEM_LANCE_PATH", "/tmp/simplemem.lance")
    System.put_env("JIDO_SIMPLEMEM_UV_EXECUTABLE", "/opt/homebrew/bin/uv")
    System.put_env("JIDO_SIMPLEMEM_PYTHON_EXECUTABLE", "/usr/bin/python3")
    System.put_env("JIDO_SIMPLEMEM_WORKER_START_TIMEOUT_MS", "90000")

    {Lance, opts} = Config.default_store()

    assert opts[:path] == "/tmp/simplemem.lance"
    assert opts[:uv_executable] == "/opt/homebrew/bin/uv"
    assert opts[:python_executable] == "/usr/bin/python3"
    assert opts[:worker_start_timeout_ms] == 90_000
  end
end
