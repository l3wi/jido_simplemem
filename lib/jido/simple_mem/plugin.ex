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

  alias Jido.Signal
  alias Jido.SimpleMem.Actions.{Ask, DeleteMemory, Finalize, GetAllMemories, PostTurn, PreTurn}
  alias Jido.SimpleMem.Config

  @default_capture_patterns ["ai.react.query", "ai.llm.response", "ai.tool.result"]

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
                  capture_rules: Zoi.map() |> Zoi.default(%{}),
                  window_size: Zoi.integer() |> Zoi.default(6),
                  overlap_size: Zoi.integer() |> Zoi.default(2),
                  enable_parallel_processing: Zoi.boolean() |> Zoi.default(true),
                  max_parallel_workers: Zoi.integer() |> Zoi.default(4),
                  enable_parallel_retrieval: Zoi.boolean() |> Zoi.default(true),
                  max_retrieval_workers: Zoi.integer() |> Zoi.default(4),
                  enable_planning: Zoi.boolean() |> Zoi.default(true),
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
                   capture_rules: Zoi.map() |> Zoi.default(%{}),
                   window_size: Zoi.integer() |> Zoi.default(6),
                   overlap_size: Zoi.integer() |> Zoi.default(2),
                   enable_parallel_processing: Zoi.boolean() |> Zoi.default(true),
                   max_parallel_workers: Zoi.integer() |> Zoi.default(4),
                   enable_parallel_retrieval: Zoi.boolean() |> Zoi.default(true),
                   max_retrieval_workers: Zoi.integer() |> Zoi.default(4),
                   enable_planning: Zoi.boolean() |> Zoi.default(true),
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
    defaults = Config.defaults()
    namespace = resolve_namespace(agent, config)

    {:ok,
     %{
       namespace: namespace,
       store: config[:store] || defaults.store,
       store_opts: config[:store_opts] || [],
       llm_client: config[:llm_client] || defaults.llm_client,
       llm_client_opts: config[:llm_client_opts] || defaults.llm_client_opts,
       embedding_client: config[:embedding_client] || defaults.embedding_client,
       embedding_client_opts: config[:embedding_client_opts] || defaults.embedding_client_opts,
       session_id: config[:session_id] || agent_id!(agent),
       auto_capture: Map.get(config, :auto_capture, true),
       capture_signal_patterns: config[:capture_signal_patterns] || @default_capture_patterns,
       capture_rules: config[:capture_rules] || %{},
       window_size: config[:window_size] || defaults.window_size,
       overlap_size: config[:overlap_size] || defaults.overlap_size,
       enable_parallel_processing:
         Map.get(config, :enable_parallel_processing, defaults.enable_parallel_processing),
       max_parallel_workers: config[:max_parallel_workers] || defaults.max_parallel_workers,
       enable_parallel_retrieval:
         Map.get(config, :enable_parallel_retrieval, defaults.enable_parallel_retrieval),
       max_retrieval_workers: config[:max_retrieval_workers] || defaults.max_retrieval_workers,
       enable_planning: Map.get(config, :enable_planning, defaults.enable_planning),
       retrieval_limit: config[:retrieval_limit] || defaults.retrieval_limit,
       context_token_budget: config[:context_token_budget] || defaults.context_token_budget,
       tokens_before_finalize:
         Map.get(config, :tokens_before_finalize, defaults.tokens_before_finalize),
       reflection_enabled: Map.get(config, :reflection_enabled, defaults.reflection_enabled),
       max_reflection_rounds: config[:max_reflection_rounds] || defaults.max_reflection_rounds
     }}
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
    state =
      context
      |> Map.get(:agent, %{})
      |> Map.get(:state, %{})
      |> Map.get(:__simplemem__, %{})

    should_capture =
      Map.get(state, :auto_capture, true) and
        signal_matches_any?(
          signal.type,
          Map.get(state, :capture_signal_patterns, @default_capture_patterns)
        )

    if should_capture do
      maybe_capture_signal(signal, context, state)
    end

    {:ok, :continue}
  rescue
    _ -> {:ok, :continue}
  end

  @impl Jido.Plugin
  def on_checkpoint(_plugin_state, _context), do: :keep

  @impl Jido.Plugin
  def on_restore(pointer, _context) when is_map(pointer), do: {:ok, pointer}
  def on_restore(_pointer, _context), do: {:ok, nil}

  defp maybe_capture_signal(%Signal{} = signal, context, state) do
    dialogue =
      case signal.type do
        "ai.react.query" ->
          %{
            speaker: "user",
            content: signal.data[:query] || signal.data["query"] || inspect(signal.data)
          }

        "ai.llm.response" ->
          %{
            speaker: "assistant",
            content: signal.data[:text] || signal.data["text"] || inspect(signal.data)
          }

        "ai.tool.result" ->
          %{
            speaker: "tool",
            content: signal.data[:result] || signal.data["result"] || inspect(signal.data)
          }

        _ ->
          nil
      end

    if is_map(dialogue) do
      _ =
        Jido.SimpleMem.enqueue_add_dialogues(
          Map.get(context, :agent, %{}),
          [Map.put(dialogue, :metadata, %{"signal_type" => signal.type})],
          session_id: state[:session_id]
        )
    end
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

  defp resolve_namespace(agent, config) do
    config[:namespace] ||
      case config[:namespace_mode] do
        :shared -> "shared:" <> (config[:shared_namespace] || "default")
        _ -> "agent:" <> agent_id!(agent)
      end
  end

  defp agent_id!(agent) do
    case Map.get(agent, :id) do
      id when is_binary(id) and id != "" -> id
      _ -> raise ArgumentError, "agent id required for per_agent namespace"
    end
  end
end
