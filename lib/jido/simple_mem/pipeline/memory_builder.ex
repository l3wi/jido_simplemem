defmodule Jido.SimpleMem.MemoryBuilder do
  @moduledoc false

  alias Jido.SimpleMem.{Dialogue, Extractor, Mapper, Synthesizer}

  @allowed_attr_keys %{
    "id" => :id,
    "restatement" => :restatement,
    "text" => :text,
    "keywords" => :keywords,
    "timestamp" => :timestamp,
    "location" => :location,
    "persons" => :persons,
    "entities" => :entities,
    "topic" => :topic,
    "metadata" => :metadata,
    "content" => :content,
    "observed_at" => :observed_at,
    "kind" => :kind,
    "class" => :class,
    "tags" => :tags,
    "source" => :source,
    "expires_at" => :expires_at
  }

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

    with {:ok, result} <-
           process_complete_windows(buffered, buffer_state.recent_entries || [], runtime) do
      maybe_auto_finalize(result, runtime)
    end
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
           finalized?: false,
           auto_finalized?: false
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
         finalized?: false,
         auto_finalized?: false
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
           auto_finalized?: false,
           recent_entries: recent_entries,
           processed_cursor: processed_cursor
         }}
    end
  end

  defp maybe_auto_finalize(%{} = result, runtime) do
    if should_auto_finalize?(result, runtime) do
      with {:ok, finalized} <- finalize(runtime) do
        {:ok, merge_results(result, finalized)}
      end
    else
      {:ok, result}
    end
  end

  defp should_auto_finalize?(%{buffer_remaining: remaining}, _runtime) when remaining in [0, nil],
    do: false

  defp should_auto_finalize?(%{finalized?: true}, _runtime), do: false

  defp should_auto_finalize?(%{} = _result, %{tokens_before_finalize: threshold} = runtime) do
    threshold_ratio = normalize_threshold(threshold)

    cond do
      threshold_ratio <= 0.0 ->
        false

      runtime.context_token_budget in [nil, 0] ->
        false

      true ->
        {:ok, buffer_state} =
          runtime.store_mod.load_buffer(runtime.namespace, runtime.session_id, runtime.store_opts)

        estimated_tokens = estimate_dialogue_tokens(buffer_state.dialogues || [])
        estimated_tokens >= runtime.context_token_budget * threshold_ratio
    end
  end

  defp merge_results(initial, finalized) do
    combined_records = (initial[:stored_records] || []) ++ (finalized[:stored_records] || [])

    Map.merge(initial, %{
      stored_records: combined_records,
      memory_ids: Enum.map(combined_records, & &1.id),
      memory_count: length(combined_records),
      last_memory_id: combined_records |> List.last() |> then(&if(&1, do: &1.id, else: nil)),
      buffer_remaining: finalized[:buffer_remaining] || 0,
      finalized?: true,
      auto_finalized?: true,
      recent_entries: finalized[:recent_entries] || initial[:recent_entries],
      processed_cursor: finalized[:processed_cursor] || initial[:processed_cursor]
    })
  end

  defp normalize_threshold(value) when is_integer(value) and value > 1, do: value / 100.0
  defp normalize_threshold(value) when is_integer(value), do: value * 1.0
  defp normalize_threshold(value) when is_float(value) and value > 1.0, do: value / 100.0
  defp normalize_threshold(value) when is_float(value), do: value
  defp normalize_threshold(_), do: 0.0

  defp estimate_dialogue_tokens(dialogues) when is_list(dialogues) do
    dialogues
    |> Enum.map(fn dialogue ->
      [
        dialogue["speaker"] || dialogue[:speaker] || "",
        dialogue["content"] || dialogue[:content] || ""
      ]
      |> Enum.join(": ")
      |> estimate_text_tokens()
    end)
    |> Enum.sum()
  end

  defp estimate_text_tokens(text) when is_binary(text) do
    text
    |> String.trim()
    |> String.length()
    |> Kernel./(4)
    |> Float.ceil()
    |> trunc()
  end

  defp estimate_text_tokens(_), do: 0

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
           maybe_synthesize_attrs(attrs_list, previous_entries, runtime),
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
          |> normalize_external_attrs()
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

  defp normalize_external_attrs(%{} = attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, value}, acc when is_atom(key) ->
        Map.put(acc, key, value)

      {key, value}, acc when is_binary(key) ->
        case Map.fetch(@allowed_attr_keys, key) do
          {:ok, atom_key} -> Map.put(acc, atom_key, value)
          :error -> acc
        end
    end)
  end

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

  # Custom OpenAI-compatible endpoints can be much slower on synthesis than on
  # extraction. If a fresh window already contains clearly distinct entries, we
  # keep the extracted output instead of paying for a redundant merge step.
  defp maybe_synthesize_attrs(entries, previous_entries, runtime) do
    if skip_synthesis?(entries, previous_entries, runtime) do
      {:ok, entries}
    else
      runtime.llm_client.synthesize(entries, previous_entries, runtime.llm_opts)
    end
  end

  defp skip_synthesis?(entries, previous_entries, runtime)
       when is_list(entries) and is_list(previous_entries) do
    previous_entries == [] and entries != [] and custom_endpoint?(runtime) and
      distinct_entry_set?(entries)
  end

  defp skip_synthesis?(_entries, _previous_entries, _runtime), do: false

  defp custom_endpoint?(runtime) do
    endpoint_model?(runtime.llm_opts[:synthesis_model] || runtime.llm_opts[:model])
  end

  defp endpoint_model?(%{base_url: base_url}) when is_binary(base_url) and base_url != "",
    do: true

  defp endpoint_model?(_model), do: false

  defp distinct_entry_set?(entries) when length(entries) <= 1, do: true

  defp distinct_entry_set?(entries) do
    signatures =
      Enum.map(entries, fn entry ->
        normalized = normalize_attrs(entry)
        {primary_identity(normalized), normalized_restatement(normalized)}
      end)

    unique_signatures = MapSet.new(signatures)

    distinct_identities =
      signatures |> Enum.map(&elem(&1, 0)) |> Enum.reject(&is_nil/1) |> MapSet.new()

    MapSet.size(unique_signatures) == length(signatures) and
      MapSet.size(distinct_identities) == length(signatures)
  end

  defp normalize_attrs(%{} = attrs), do: normalize_external_attrs(attrs)
  defp normalize_attrs(_attrs), do: %{}

  defp primary_identity(attrs) do
    attrs
    |> person_list()
    |> List.first()
    |> case do
      value when is_binary(value) and value != "" -> String.downcase(value)
      _ -> normalized_restatement(attrs)
    end
  end

  defp person_list(attrs) do
    case attrs[:persons] do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      value when is_binary(value) -> [value]
      _ -> []
    end
  end

  defp normalized_restatement(attrs) do
    attrs
    |> Map.get(:restatement, "")
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

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
