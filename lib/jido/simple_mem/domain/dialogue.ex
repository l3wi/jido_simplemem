defmodule Jido.SimpleMem.Dialogue do
  @moduledoc """
  Normalized dialogue entry used by the buffered ingestion pipeline.
  """

  defstruct [:dialogue_id, :speaker, :content, :timestamp, :metadata]

  @type t :: %__MODULE__{
          dialogue_id: String.t(),
          speaker: String.t(),
          content: String.t(),
          timestamp: String.t(),
          metadata: map()
        }

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    speaker = attrs[:speaker] || attrs["speaker"] || "user"
    content = attrs[:content] || attrs["content"] || attrs[:text] || attrs["text"]

    timestamp =
      normalize_timestamp(attrs[:timestamp] || attrs["timestamp"] || attrs[:observed_at])

    cond do
      not is_binary(content) or String.trim(content) == "" ->
        {:error, :content_required}

      true ->
        {:ok,
         %__MODULE__{
           dialogue_id:
             attrs[:dialogue_id] || attrs["dialogue_id"] || attrs[:id] || generated_dialogue_id(),
           speaker: to_string(speaker),
           content: String.trim(content),
           timestamp: timestamp,
           metadata: normalize_metadata(attrs[:metadata] || attrs["metadata"])
         }}
    end
  end

  @spec to_prompt_line(t()) :: String.t()
  def to_prompt_line(%__MODULE__{} = dialogue) do
    "[#{dialogue.timestamp}] #{dialogue.speaker}: #{dialogue.content}"
  end

  defp generated_dialogue_id do
    "dlg_" <> Integer.to_string(System.unique_integer([:positive]))
  end

  defp normalize_timestamp(nil), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp normalize_timestamp(value) when is_integer(value) do
    value
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_iso8601()
  end

  defp normalize_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_iso8601(datetime)
      _ -> DateTime.utc_now() |> DateTime.to_iso8601()
    end
  end

  defp normalize_timestamp(_), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp normalize_metadata(nil), do: %{}
  defp normalize_metadata(%{} = metadata), do: metadata
  defp normalize_metadata(list) when is_list(list), do: Map.new(list)
  defp normalize_metadata(_), do: %{}
end
