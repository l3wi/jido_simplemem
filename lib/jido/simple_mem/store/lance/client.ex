defmodule Jido.SimpleMem.Store.Lance.Client do
  @moduledoc false

  @callback ensure_ready(keyword()) :: :ok | {:error, term()}
  @callback put(map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback get(String.t(), String.t(), keyword()) :: {:ok, map()} | :not_found | {:error, term()}
  @callback delete(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  @callback list(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback search(String.t(), map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback load_buffer(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback replace_buffer(String.t(), String.t(), map(), keyword()) :: :ok | {:error, term()}
  @callback delete_buffer(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
end
