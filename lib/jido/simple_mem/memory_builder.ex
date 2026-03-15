defmodule Jido.SimpleMem.MemoryBuilder do
  @moduledoc false

  alias Jido.SimpleMem.{Dialogue, Extractor, Mapper, Synthesizer}

  @spec add_dialogues([Dialogue.t()], map()) :: {:ok, map()} | {:error, term()}
  def add_dialogues(dialogues, runtime) when is_list(dialogues) do
    {:ok, buffer_state} =
      runtime.store_mod.load_buffer(runtime.namespace, runtime.session_id, runtime.store_opts)

    existing = buffer_state.dialogues || []
    buffered = existing ++ Enum.map(dialogues, &dialogue_to_map/1)

    :ok =
      runtime.store_mod.replace_buffer(
        runtime.namespace,
        runtime.session_id,
        %{
          dialogues: buffered,
          recent_entries: buffer_state.recent_entries || [],
          processed_cursor: buffer_state.processed_cursor || 0
        },
        runtime.store_opts
      )

    process_complete_windows(buffered, buffer_state.recent_entries || [], runtime)
  end

  @spec finalize(map()) :: {:ok, map()} | {:error, term()}
  def finalize(runtime) do
    {:ok, buffer_state} =
      runtime.store_mod.load_buffer(runtime.namespace, runtime.session_id, runtime.store_opts)

    buffered = buffer_state.dialogues || []

    case buffered do
      [] ->
        {:ok,
         %{
           stored_records: [],
           memory_ids: [],
           memory_count: 0,
           last_memory_id: nil,
           buffer_remaining: 0,
           finalized?: false
         }}

      _ ->
        process_windows(buffered, buffer_state.recent_entries || [], runtime, finalize?: true)
    end
  end

  defp process_complete_windows(buffered, previous_entries, runtime) do
    if length(buffered) >= runtime.window_size do
      process_windows(buffered, previous_entries, runtime, finalize?: false)
    else
      {:ok,
       %{
         stored_records: [],
         memory_ids: [],
         memory_count: 0,
         last_memory_id: nil,
         buffer_remaining: length(buffered),
         finalized?: false
       }}
    end
  end

  defp process_windows(buffered, previous_entries, runtime, opts) do
    finalize? = Keyword.get(opts, :finalize?, false)

    case do_process(buffered, [], previous_entries, runtime, finalize?, 0) do
      {:error, _reason} = error ->
        error

      {remaining, records, recent_entries, processed_cursor} ->
        :ok =
          runtime.store_mod.replace_buffer(
            runtime.namespace,
            runtime.session_id,
            %{
              dialogues: remaining,
              recent_entries: recent_entries,
              processed_cursor: processed_cursor
            },
            runtime.store_opts
          )

        ordered_records = Enum.reverse(records)

        {:ok,
         %{
           stored_records: ordered_records,
           memory_ids: Enum.map(ordered_records, & &1.id),
           memory_count: length(ordered_records),
           last_memory_id: ordered_records |> List.last() |> then(&if(&1, do: &1.id, else: nil)),
           buffer_remaining: length(remaining),
           finalized?: finalize?,
           recent_entries: recent_entries,
           processed_cursor: processed_cursor
         }}
    end
  end

  defp do_process(buffered, records, previous_entries, runtime, finalize?, processed_cursor) do
    cond do
      length(buffered) >= runtime.window_size ->
        {window, rest} = split_window(buffered, runtime.window_size, runtime.step_size)

        case process_window(window, previous_entries, runtime) do
          {:ok, new_records, new_entries} ->
            carried_entries = if new_entries == [], do: previous_entries, else: new_entries

            do_process(
              rest,
              Enum.reverse(new_records) ++ records,
              carried_entries,
              runtime,
              finalize?,
              processed_cursor + runtime.step_size
            )

          {:error, reason} ->
            {:error, reason}
        end

      finalize? and buffered != [] ->
        case process_window(buffered, previous_entries, runtime) do
          {:ok, new_records, new_entries} ->
            carried_entries = if new_entries == [], do: previous_entries, else: new_entries

            {[], Enum.reverse(new_records) ++ records, carried_entries,
             processed_cursor + length(buffered)}

          {:error, reason} ->
            {:error, reason}
        end

      true ->
        {buffered, records, previous_entries, processed_cursor}
    end
  end

  defp split_window(buffered, window_size, step_size) do
    {Enum.take(buffered, window_size), Enum.drop(buffered, step_size)}
  end

  defp process_window(dialogues, previous_entries, runtime) do
    normalized_dialogues = Enum.map(dialogues, &normalize_dialogue/1)

    with {:ok, attrs_list} <-
           runtime.llm_client.extract_window(
             Enum.map(normalized_dialogues, &map_to_dialogue/1),
             previous_entries,
             runtime.llm_opts
           ),
         :ok <- validate_extraction(attrs_list, normalized_dialogues, previous_entries),
         {:ok, synthesized_attrs} <-
           runtime.llm_client.synthesize(attrs_list, previous_entries, runtime.llm_opts),
         :ok <- validate_synthesis(attrs_list, synthesized_attrs),
         {:ok, units} <- build_units(synthesized_attrs, normalized_dialogues, runtime),
         {:ok, stored_units} <- Synthesizer.synthesize_batch(units, runtime) do
      records = Enum.map(stored_units, &Mapper.to_record/1)
      {:ok, records, stored_units}
    end
  end

  defp build_units(attrs_list, dialogues, runtime) do
    results =
      Enum.map(attrs_list, fn attrs ->
        attrs =
          attrs
          |> Map.new(fn {key, value} -> {normalize_key(key), value} end)
          |> Map.put_new(:content, %{
            "dialogues" => Enum.map(dialogues, &dialogue_to_map/1)
          })
          |> Map.update(:metadata, %{}, fn metadata ->
            metadata =
              if is_map(metadata), do: metadata, else: %{}

            Map.merge(metadata, %{
              "session_id" => runtime.session_id,
              "dialogue_ids" => Enum.map(dialogues, &dialogue_id/1)
            })
          end)
          |> Map.put_new(:observed_at, runtime.now)
          |> Map.put_new(:kind, :memory)
          |> Map.put_new(:class, :semantic)

        Extractor.extract(attrs, runtime)
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      {:error, reason} ->
        {:error, reason}

      nil ->
        {:ok, Enum.map(results, fn {:ok, unit} -> unit end)}
    end
  end

  defp dialogue_to_map(%Dialogue{} = dialogue) do
    %{
      "dialogue_id" => dialogue.dialogue_id,
      "speaker" => dialogue.speaker,
      "content" => dialogue.content,
      "timestamp" => dialogue.timestamp,
      "metadata" => dialogue.metadata
    }
  end

  defp dialogue_to_map(%{} = dialogue), do: normalize_dialogue(dialogue)

  defp map_to_dialogue(%{} = dialogue) do
    {:ok, built} = Dialogue.new(dialogue)
    built
  end

  defp normalize_dialogue(%Dialogue{} = dialogue), do: dialogue_to_map(dialogue)

  defp normalize_dialogue(%{} = dialogue) do
    %{
      "dialogue_id" => dialogue["dialogue_id"] || dialogue[:dialogue_id],
      "speaker" => dialogue["speaker"] || dialogue[:speaker],
      "content" => dialogue["content"] || dialogue[:content],
      "timestamp" => dialogue["timestamp"] || dialogue[:timestamp],
      "metadata" => dialogue["metadata"] || dialogue[:metadata] || %{}
    }
  end

  defp dialogue_id(%Dialogue{} = dialogue), do: dialogue.dialogue_id
  defp dialogue_id(%{} = dialogue), do: dialogue["dialogue_id"] || dialogue[:dialogue_id]

  defp normalize_key(key) when is_binary(key), do: String.to_atom(key)
  defp normalize_key(key), do: key

  defp validate_extraction([], dialogues, previous_entries) do
    if previous_entries == [] and memory_worthy_window?(dialogues) do
      {:error, {:empty_extraction, dialogues}}
    else
      :ok
    end
  end

  defp validate_extraction(entries, _dialogues, _previous_entries) when is_list(entries), do: :ok

  defp validate_synthesis(entries, []) when entries != [],
    do: {:error, {:empty_synthesis, entries}}

  defp validate_synthesis(_entries, synthesized) when is_list(synthesized), do: :ok

  defp memory_worthy_window?(dialogues) do
    Enum.any?(dialogues, fn dialogue ->
      speaker = dialogue["speaker"] || dialogue[:speaker] || ""
      content = String.trim(dialogue["content"] || dialogue[:content] || "")

      content != "" and speaker in ["user", "tool"] and
        String.match?(
          content,
          ~r/\b(remember|store|note|my name is|i live in|i am based in|i prefer|i like|i love|i am allergic to|i work at|i work in|lives in|prefers|favorite)\b/i
        )
    end)
  end
end
