defmodule Jido.SimpleMem.ConfigTest do
  use ExUnit.Case, async: false

  alias Jido.SimpleMem.Config
  alias Jido.SimpleMem.Store.{SQLite, Turso}

  setup do
    env_keys = [
      "TURSO_DATABASE_URL",
      "TURSO_AUTH_TOKEN",
      "JIDO_SIMPLEMEM_LOCAL_DB_PATH",
      "JIDO_SIMPLEMEM_EMBEDDING_MODEL"
    ]

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

  test "defaults choose local sqlite store when Turso env is absent" do
    defaults = Config.defaults()

    assert {SQLite, opts} = defaults.store
    assert is_binary(opts[:path])
    assert String.ends_with?(opts[:path], "simplemem.sqlite3")
    assert defaults.embedding_client == Jido.SimpleMem.EmbeddingClient.ReqLLM
    assert defaults.embedding_client_opts == []
    assert defaults.memory_policy.capture_explicit_memories
    refute defaults.memory_policy.capture_queries
  end

  test "defaults choose Turso store when url and token are present" do
    System.put_env("TURSO_DATABASE_URL", "libsql://demo.turso.io")
    System.put_env("TURSO_AUTH_TOKEN", "secret")

    defaults = Config.defaults()

    assert {Turso, opts} = defaults.store
    assert opts[:url] == "libsql://demo.turso.io"
    assert opts[:auth_token] == "secret"
  end

  test "defaults read embedding model from env" do
    System.put_env("JIDO_SIMPLEMEM_EMBEDDING_MODEL", "openai:text-embedding-3-small")

    defaults = Config.defaults()

    assert defaults.embedding_client_opts == [model: "openai:text-embedding-3-small"]
  end
end
