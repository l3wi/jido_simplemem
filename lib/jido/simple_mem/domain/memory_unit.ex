defmodule Jido.SimpleMem.MemoryUnit do
  @moduledoc false

  defstruct [
    :id,
    :namespace,
    :restatement,
    :original_text,
    :content,
    :class,
    :kind,
    :tags,
    :source,
    :observed_at,
    :expires_at,
    :timestamp,
    :persons,
    :entities,
    :location,
    :topic,
    :keywords,
    :metadata,
    :embedding
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          namespace: String.t(),
          restatement: String.t(),
          original_text: String.t() | nil,
          content: map(),
          class: atom(),
          kind: atom() | String.t(),
          tags: [String.t()],
          source: String.t() | nil,
          observed_at: integer(),
          expires_at: integer() | nil,
          timestamp: String.t() | nil,
          persons: [String.t()],
          entities: [String.t()],
          location: String.t() | nil,
          topic: String.t() | nil,
          keywords: [String.t()],
          metadata: map(),
          embedding: [float()]
        }

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    restatement = Map.get(attrs, :restatement)
    namespace = Map.get(attrs, :namespace)
    observed_at = Map.get(attrs, :observed_at, System.system_time(:millisecond))

    cond do
      not is_binary(namespace) or String.trim(namespace) == "" ->
        {:error, :namespace_required}

      not is_binary(restatement) or String.trim(restatement) == "" ->
        {:error, :restatement_required}

      true ->
        base = %__MODULE__{
          id: Map.get(attrs, :id) || stable_id(attrs),
          namespace: namespace,
          restatement: String.trim(restatement),
          original_text: Map.get(attrs, :original_text),
          content: Map.get(attrs, :content, %{}),
          class: Map.get(attrs, :class, :episodic),
          kind: Map.get(attrs, :kind, :event),
          tags: uniq_strings(Map.get(attrs, :tags, [])),
          source: Map.get(attrs, :source),
          observed_at: observed_at,
          expires_at: Map.get(attrs, :expires_at),
          timestamp: Map.get(attrs, :timestamp),
          persons: uniq_strings(Map.get(attrs, :persons, [])),
          entities: uniq_strings(Map.get(attrs, :entities, [])),
          location: Map.get(attrs, :location),
          topic: Map.get(attrs, :topic),
          keywords: uniq_strings(Map.get(attrs, :keywords, [])),
          metadata: Map.get(attrs, :metadata, %{}),
          embedding: Map.get(attrs, :embedding, [])
        }

        {:ok, base}
    end
  end

  @spec stable_id(map()) :: String.t()
  def stable_id(attrs) do
    attrs
    |> Map.drop([:id])
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 24)
    |> then(&("smem_" <> &1))
  end

  defp uniq_strings(list) when is_list(list) do
    list
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end
end
