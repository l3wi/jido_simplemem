require Jido.SimpleMem.Actions.Ask
require Jido.SimpleMem.Actions.DeleteMemory
require Jido.SimpleMem.Actions.Finalize
require Jido.SimpleMem.Actions.GetAllMemories
require Jido.SimpleMem.Actions.PostTurn
require Jido.SimpleMem.Actions.PreTurn

defmodule Jido.SimpleMem.Plugin do
  @moduledoc """
  Single-tier, buffered SimpleMem plugin for Jido agents.
  """

  require Logger

  alias Jido.Signal
  alias Jido.SimpleMem.Actions.{Ask, DeleteMemory, Finalize, GetAllMemories, PostTurn, PreTurn}
  alias Jido.SimpleMem.Runtime

  @default_capture_patterns ["ai.react.query", "ai.llm.response", "ai.tool.result"]
  @auto_capture_event [:jido, :simple_mem, :plugin, :auto_capture, :stop]

  @state_schema Zoi.object(%{
                  namespace: Zoi.string() |> Zoi.optional(),
                  store: Zoi.any(),
                  store_opts: Zoi.list(Zoi.any()) |> Zoi.default([]),
                  llm_client: Zoi.any(),
                  llm_client_opts: Zoi.list(Zoi.any()) |> Zoi.default([]),
                  embedding_client: Zoi.any(),
                  embedding_client_opts: Zoi.list(Zoi.any()) |> Zoi.default([]),
                  session_id: Zoi.string() |> Zoi.optional(),
                  auto_capture: Zoi.boolean() |> Zoi.default(true),
                  capture_signal_patterns:
                    Zoi.list(Zoi.string()) |> Zoi.default(@default_capture_patterns),
                  window_size: Zoi.integer() |> Zoi.default(6),
                  overlap_size: Zoi.integer() |> Zoi.default(2),
                  enable_parallel_retrieval: Zoi.boolean() |> Zoi.default(true),
                  max_retrieval_workers: Zoi.integer() |> Zoi.default(4),
                  retrieval_limit: Zoi.integer() |> Zoi.default(10),
                  context_token_budget: Zoi.integer() |> Zoi.default(1200),
                  tokens_before_finalize: Zoi.integer() |> Zoi.default(60),
                  reflection_enabled: Zoi.boolean() |> Zoi.default(true),
                  max_reflection_rounds: Zoi.integer() |> Zoi.default(2)
                })

  @config_schema Zoi.object(%{
                   namespace: Zoi.string() |> Zoi.optional(),
                   namespace_mode: Zoi.atom() |> Zoi.default(:per_agent),
                   shared_namespace: Zoi.string() |> Zoi.optional(),
                   store: Zoi.any() |> Zoi.optional(),
                   store_opts: Zoi.list(Zoi.any()) |> Zoi.default([]),
                   llm_client: Zoi.any() |> Zoi.default(Jido.SimpleMem.LLMClient.ReqLLM),
                   llm_client_opts: Zoi.list(Zoi.any()) |> Zoi.default([]),
                   embedding_client:
                     Zoi.any() |> Zoi.default(Jido.SimpleMem.EmbeddingClient.ReqLLM),
                   embedding_client_opts: Zoi.list(Zoi.any()) |> Zoi.default([]),
                   session_id: Zoi.string() |> Zoi.optional(),
                   auto_capture: Zoi.boolean() |> Zoi.default(true),
                   capture_signal_patterns:
                     Zoi.list(Zoi.string()) |> Zoi.default(@default_capture_patterns),
                   window_size: Zoi.integer() |> Zoi.default(6),
                   overlap_size: Zoi.integer() |> Zoi.default(2),
                   enable_parallel_retrieval: Zoi.boolean() |> Zoi.default(true),
                   max_retrieval_workers: Zoi.integer() |> Zoi.default(4),
                   retrieval_limit: Zoi.integer() |> Zoi.default(10),
                   context_token_budget: Zoi.integer() |> Zoi.default(1200),
                   tokens_before_finalize: Zoi.integer() |> Zoi.default(60),
                   reflection_enabled: Zoi.boolean() |> Zoi.default(true),
                   max_reflection_rounds: Zoi.integer() |> Zoi.default(2)
                 })

  use Jido.Plugin,
    name: "simplemem",
    state_key: :__simplemem__,
    actions: [PreTurn, PostTurn, Finalize, Ask, GetAllMemories, DeleteMemory],
    signal_routes: [
      {"pre_turn", PreTurn},
      {"post_turn", PostTurn},
      {"finalize", Finalize},
      {"ask", Ask},
      {"get_all_memories", GetAllMemories},
      {"delete_memory", DeleteMemory}
    ],
    schema: @state_schema,
    config_schema: @config_schema,
    singleton: true,
    description: "Single-tier SimpleMem memory plugin for Jido",
    capabilities: [:simplemem, :memory]

  @impl Jido.Plugin
  def mount(agent, config) do
    Runtime.build_plugin_state(agent, config)
  end

  @impl Jido.Plugin
  def signal_routes(_config) do
    [
      {"pre_turn", PreTurn},
      {"post_turn", PostTurn},
      {"finalize", Finalize},
      {"ask", Ask},
      {"get_all_memories", GetAllMemories},
      {"delete_memory", DeleteMemory}
    ]
  end

  @impl Jido.Plugin
  def handle_signal(%Signal{} = signal, context) do
    state = Runtime.plugin_state(Map.get(context, :agent, %{}))

    should_capture =
      Map.get(state, :auto_capture, true) and
        signal_matches_any?(
          signal.type,
          Map.get(state, :capture_signal_patterns, @default_capture_patterns)
        )

    case maybe_capture_signal(signal, context, state, should_capture) do
      {:ok, _status} -> {:ok, :continue}
      {:error, reason} -> {:error, {:auto_capture_failed, reason}}
    end
  end

  @impl Jido.Plugin
  def on_checkpoint(_plugin_state, _context), do: :keep

  @impl Jido.Plugin
  def on_restore(pointer, _context) when is_map(pointer), do: {:ok, pointer}
  def on_restore(_pointer, _context), do: {:ok, nil}

  defp maybe_capture_signal(_signal, _context, _state, false), do: {:ok, :ignored}

  defp maybe_capture_signal(%Signal{} = signal, context, state, true) do
    case build_capture_dialogue(signal) do
      nil ->
        emit_auto_capture(:ignored, signal, state)
        {:ok, :ignored}

      dialogue ->
        opts = [session_id: state[:session_id]]

        case Jido.SimpleMem.add_dialogues(
               Map.get(context, :agent, %{}),
               [Map.put(dialogue, :metadata, %{"signal_type" => signal.type})],
               opts
             ) do
          {:ok, _result} = ok ->
            emit_auto_capture(:ok, signal, state)
            ok

          {:error, reason} = error ->
            Logger.warning("SimpleMem auto-capture failed for #{signal.type}: #{inspect(reason)}")
            emit_auto_capture(:error, signal, state, reason)
            error
        end
    end
  end

  defp build_capture_dialogue(%Signal{} = signal) do
    data = normalize_signal_data(signal.data)

    case signal.type do
      "ai.react.query" ->
        %{
          speaker: "user",
          content: Runtime.map_value(data, :query) || inspect(signal.data)
        }

      "ai.llm.response" ->
        %{
          speaker: "assistant",
          content: Runtime.map_value(data, :text) || inspect(signal.data)
        }

      "ai.tool.result" ->
        %{
          speaker: "tool",
          content: Runtime.map_value(data, :result) || inspect(signal.data)
        }

      _ ->
        nil
    end
  end

  defp emit_auto_capture(status, signal, state, reason \\ nil) do
    metadata =
      %{
        status: status,
        signal_type: signal.type,
        session_id: state[:session_id],
        namespace: state[:namespace]
      }
      |> maybe_put(:reason, reason)

    :telemetry.execute(@auto_capture_event, %{count: 1}, metadata)
  end

  defp signal_matches_any?(_type, []), do: false

  defp signal_matches_any?(type, patterns) do
    Enum.any?(patterns, fn pattern ->
      cond do
        pattern == "*" ->
          true

        type == pattern ->
          true

        String.ends_with?(pattern, ".*") ->
          String.starts_with?(type, String.trim_trailing(pattern, ".*") <> ".")

        String.contains?(pattern, "*") ->
          regex = pattern |> Regex.escape() |> String.replace("\\*", "[^.]*")
          Regex.match?(~r/^#{regex}$/, type)

        true ->
          false
      end
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_signal_data(%{} = data), do: data
  defp normalize_signal_data(nil), do: %{}
  defp normalize_signal_data(other), do: %{value: other}
end
