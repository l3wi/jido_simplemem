defmodule Jido.SimpleMem.Config do
  @moduledoc false

  alias Jido.SimpleMem.EmbeddingClient.ReqLLM
  alias Jido.SimpleMem.LLMClient.Noop
  alias Jido.SimpleMem.Store.{SQLite, Turso}

  @plugin_state_key :__simplemem__

  @spec defaults() :: map()
  def defaults do
    %{
      namespace: nil,
      store: default_store(),
      llm_client: Noop,
      llm_client_opts: [],
      embedding_client: ReqLLM,
      embedding_client_opts: default_embedding_client_opts(),
      retrieval_limit: 10,
      context_token_budget: 1_200,
      reflection_enabled: true,
      max_reflection_rounds: 2
    }
  end

  @spec plugin_state_key() :: atom()
  def plugin_state_key, do: @plugin_state_key

  @spec normalize_store(module() | {module(), keyword()} | nil) ::
          {:ok, {module(), keyword()}} | {:error, term()}
  def normalize_store({mod, opts}) when is_atom(mod) and is_list(opts), do: {:ok, {mod, opts}}
  def normalize_store(mod) when is_atom(mod), do: {:ok, {mod, []}}
  def normalize_store(nil), do: {:error, :missing_store}
  def normalize_store(other), do: {:error, {:invalid_store, other}}

  @spec default_store() :: {module(), keyword()}
  def default_store do
    case {System.get_env("TURSO_DATABASE_URL"), System.get_env("TURSO_AUTH_TOKEN")} do
      {url, token} when is_binary(url) and url != "" and is_binary(token) and token != "" ->
        {Turso, [url: url, auth_token: token]}

      _ ->
        {SQLite, [path: local_db_path()]}
    end
  end

  @spec local_db_path() :: String.t()
  def local_db_path do
    case System.get_env("JIDO_SIMPLEMEM_LOCAL_DB_PATH") do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        Path.expand(".jido/simplemem.sqlite3", File.cwd!())
    end
  end

  @spec default_embedding_client_opts() :: keyword()
  def default_embedding_client_opts do
    case System.get_env("JIDO_SIMPLEMEM_EMBEDDING_MODEL") do
      value when is_binary(value) and value != "" -> [model: value]
      _ -> []
    end
  end
end
