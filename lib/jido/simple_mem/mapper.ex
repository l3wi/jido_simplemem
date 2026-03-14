defmodule Jido.SimpleMem.Mapper do
  @moduledoc false

  alias Jido.Memory.Record
  alias Jido.SimpleMem.MemoryUnit

  @spec to_record(MemoryUnit.t()) :: Record.t()
  def to_record(%MemoryUnit{} = unit) do
    Record.new!(%{
      id: unit.id,
      namespace: unit.namespace,
      class: unit.class,
      kind: unit.kind,
      text: unit.restatement,
      content: unit.content,
      tags: unit.tags,
      source: unit.source,
      observed_at: unit.observed_at,
      expires_at: unit.expires_at,
      embedding: unit.embedding,
      metadata:
        %{
          "simplemem" => %{
            "timestamp" => unit.timestamp,
            "persons" => unit.persons,
            "entities" => unit.entities,
            "location" => unit.location,
            "topic" => unit.topic,
            "keywords" => unit.keywords,
            "original_text" => unit.original_text
          }
        }
        |> Map.merge(unit.metadata || %{})
    })
  end
end
