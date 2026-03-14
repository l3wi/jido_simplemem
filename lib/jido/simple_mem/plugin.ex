require Jido.SimpleMem.Actions.Answer
require Jido.SimpleMem.Actions.Forget
require Jido.SimpleMem.Actions.PostTurn
require Jido.SimpleMem.Actions.PreTurn
require Jido.SimpleMem.Actions.Remember
require Jido.SimpleMem.Actions.Retrieve

defmodule Jido.SimpleMem.Plugin do
  @moduledoc """
  Single-tier SimpleMem-inspired plugin for Jido agents.
  """

  alias Jido.Signal
  alias Jido.SimpleMem.Actions.{Answer, Forget, PostTurn, PreTurn, Remember, Retrieve}
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
                  auto_capture: Zoi.boolean() |> Zoi.default(true),
                  capture_signal_patterns:
                    Zoi.list(Zoi.string()) |> Zoi.default(@default_capture_patterns),
                  capture_rules: Zoi.map() |> Zoi.default(%{}),
                  retrieval_limit: Zoi.integer() |> Zoi.default(10),
                  context_token_budget: Zoi.integer() |> Zoi.default(1200),
                  reflection_enabled: Zoi.boolean() |> Zoi.default(true),
                  max_reflection_rounds: Zoi.integer() |> Zoi.default(2)
                })

  @config_schema Zoi.object(%{
                   namespace: Zoi.string() |> Zoi.optional(),
                   namespace_mode: Zoi.atom() |> Zoi.default(:per_agent),
                   shared_namespace: Zoi.string() |> Zoi.optional(),
                   store: Zoi.any() |> Zoi.optional(),
                   store_opts: Zoi.list(Zoi.any()) |> Zoi.default([]),
                   llm_client: Zoi.any() |> Zoi.default(Jido.SimpleMem.LLMClient.Noop),
                   llm_client_opts: Zoi.list(Zoi.any()) |> Zoi.default([]),
                   embedding_client:
                     Zoi.any() |> Zoi.default(Jido.SimpleMem.EmbeddingClient.ReqLLM),
                   embedding_client_opts: Zoi.list(Zoi.any()) |> Zoi.default([]),
                   auto_capture: Zoi.boolean() |> Zoi.default(true),
                   capture_signal_patterns:
                     Zoi.list(Zoi.string()) |> Zoi.default(@default_capture_patterns),
                   capture_rules: Zoi.map() |> Zoi.default(%{}),
                   retrieval_limit: Zoi.integer() |> Zoi.default(10),
                   context_token_budget: Zoi.integer() |> Zoi.default(1200),
                   reflection_enabled: Zoi.boolean() |> Zoi.default(true),
                   max_reflection_rounds: Zoi.integer() |> Zoi.default(2)
                 })

  use Jido.Plugin,
    name: "simplemem",
    state_key: :__simplemem__,
    actions: [Remember, Retrieve, Answer, Forget, PreTurn, PostTurn],
    signal_routes: [
      {"remember", Remember},
      {"retrieve", Retrieve},
      {"answer", Answer},
      {"forget", Forget},
      {"pre_turn", PreTurn},
      {"post_turn", PostTurn}
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
       auto_capture: Map.get(config, :auto_capture, true),
       capture_signal_patterns: config[:capture_signal_patterns] || @default_capture_patterns,
       capture_rules: config[:capture_rules] || %{},
       retrieval_limit: config[:retrieval_limit] || defaults.retrieval_limit,
       context_token_budget: config[:context_token_budget] || defaults.context_token_budget,
       reflection_enabled: Map.get(config, :reflection_enabled, defaults.reflection_enabled),
       max_reflection_rounds: config[:max_reflection_rounds] || defaults.max_reflection_rounds
     }}
  end

  @impl Jido.Plugin
  def signal_routes(_config) do
    [
      {"remember", Remember},
      {"retrieve", Retrieve},
      {"answer", Answer},
      {"forget", Forget},
      {"pre_turn", PreTurn},
      {"post_turn", PostTurn}
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
      attrs = build_capture_attrs(signal, state)
      _ = Jido.SimpleMem.remember(Map.get(context, :agent, %{}), attrs, [])
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

  defp build_capture_attrs(%Signal{} = signal, state) do
    data = normalize_data(signal.data)
    text = data[:query] || data[:text] || data[:content] || inspect(data)
    rule = Map.get(state[:capture_rules] || %{}, signal.type, %{})

    %{
      class: Map.get(rule, :class, :episodic),
      kind: Map.get(rule, :kind, infer_kind(signal.type)),
      text: Map.get(rule, :text, text),
      content: data,
      tags: Enum.uniq((Map.get(rule, :tags, []) |> List.wrap()) ++ ["signal:#{signal.type}"]),
      source: Map.get(rule, :source, signal.source),
      metadata:
        Map.merge(
          %{
            "signal_id" => signal.id,
            "signal_type" => signal.type
          },
          Map.get(rule, :metadata, %{})
        ),
      observed_at: signal_time_ms(signal.time)
    }
  end

  defp infer_kind(type) do
    cond do
      String.ends_with?(type, ".query") -> :query
      String.ends_with?(type, ".response") -> :response
      String.ends_with?(type, ".result") -> :result
      true -> :event
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

  defp signal_time_ms(nil), do: System.system_time(:millisecond)

  defp signal_time_ms(time) when is_binary(time) do
    case DateTime.from_iso8601(time) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
      _ -> System.system_time(:millisecond)
    end
  end

  defp normalize_data(%{} = data), do: data

  defp normalize_data(list) when is_list(list) do
    if Keyword.keyword?(list) do
      Map.new(list)
    else
      %{items: list}
    end
  end

  defp normalize_data(nil), do: %{}
  defp normalize_data(other), do: %{value: other}

  defp resolve_namespace(agent, config) do
    config[:namespace] ||
      case config[:namespace_mode] do
        :shared -> "shared:" <> (config[:shared_namespace] || "default")
        _ -> "agent:" <> agent_id!(agent)
      end
  end

  defp agent_id!(agent) do
    case agent[:id] do
      id when is_binary(id) and id != "" -> id
      _ -> raise ArgumentError, "agent id required for per_agent namespace"
    end
  end
end
