defmodule Jido.Memory.Record do
  @moduledoc """
  Canonical data model for a memory record.

  This local module keeps the SimpleMem runtime publishable on Hex without
  depending on the unpublished `jido_memory` package.
  """

  @canonical_classes [:episodic, :semantic, :procedural, :working]
  @default_version 1

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(description: "Stable memory record id"),
              namespace: Zoi.string(description: "Logical memory namespace"),
              class: Zoi.atom(description: "Memory class taxonomy"),
              kind: Zoi.any(description: "Open memory kind value") |> Zoi.default(:event),
              text: Zoi.string(description: "Primary searchable text") |> Zoi.optional(),
              content: Zoi.any(description: "Structured memory payload") |> Zoi.default(%{}),
              tags: Zoi.list(Zoi.string(), description: "Normalized tag list") |> Zoi.default([]),
              source: Zoi.string(description: "Event source") |> Zoi.optional(),
              observed_at: Zoi.integer(description: "Observation timestamp in milliseconds"),
              expires_at:
                Zoi.integer(description: "Expiration timestamp in milliseconds") |> Zoi.optional(),
              embedding: Zoi.any(description: "Optional embedding payload") |> Zoi.optional(),
              metadata: Zoi.map(description: "Arbitrary metadata") |> Zoi.default(%{}),
              version:
                Zoi.integer(description: "Record schema version") |> Zoi.default(@default_version)
            },
            coerce: true
          )

  @type class :: :episodic | :semantic | :procedural | :working
  @type kind :: atom() | String.t()
  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec canonical_classes() :: [class()]
  def canonical_classes, do: @canonical_classes

  @spec new(map() | keyword(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs, opts \\ [])

  def new(attrs, opts) when is_list(attrs), do: new(Map.new(attrs), opts)

  def new(attrs, opts) when is_map(attrs) do
    now = Keyword.get(opts, :now, System.system_time(:millisecond))

    with {:ok, namespace} <- normalize_namespace(get_attr(attrs, :namespace)),
         {:ok, class} <- normalize_class(get_attr(attrs, :class, :episodic)),
         {:ok, kind} <- normalize_kind(get_attr(attrs, :kind, :event)),
         {:ok, tags} <- normalize_tags(get_attr(attrs, :tags, [])),
         {:ok, observed_at} <- normalize_timestamp(get_attr(attrs, :observed_at, now), now),
         {:ok, expires_at} <- normalize_optional_timestamp(get_attr(attrs, :expires_at), now),
         {:ok, source} <- normalize_optional_string(get_attr(attrs, :source)),
         {:ok, metadata} <- normalize_map(get_attr(attrs, :metadata, %{})),
         {:ok, text} <- normalize_optional_text(get_attr(attrs, :text)),
         {:ok, id} <- normalize_id(get_attr(attrs, :id)) do
      content = get_attr(attrs, :content, %{})
      embedding = get_attr(attrs, :embedding)
      version = normalize_version(get_attr(attrs, :version, @default_version))

      base = %{
        id: id,
        namespace: namespace,
        class: class,
        kind: kind,
        text: text,
        content: content,
        tags: tags,
        source: source,
        observed_at: observed_at,
        expires_at: expires_at,
        embedding: embedding,
        metadata: metadata,
        version: version
      }

      final = if id == nil, do: Map.put(base, :id, stable_id(base)), else: base

      {:ok, struct!(__MODULE__, final)}
    end
  end

  def new(_attrs, _opts), do: {:error, :invalid_attrs}

  @spec new!(map() | keyword(), keyword()) :: t()
  def new!(attrs, opts \\ []) do
    case new(attrs, opts) do
      {:ok, record} -> record
      {:error, reason} -> raise ArgumentError, "invalid memory record: #{inspect(reason)}"
    end
  end

  @spec stable_id(map()) :: String.t()
  def stable_id(normalized_attrs) when is_map(normalized_attrs) do
    payload =
      normalized_attrs
      |> Map.drop([:id, "id"])
      |> :erlang.term_to_binary()

    digest =
      :crypto.hash(:sha256, payload)
      |> Base.encode16(case: :lower)

    "mem_" <> String.slice(digest, 0, 24)
  end

  @spec normalize_class(term()) :: {:ok, class()} | {:error, term()}
  def normalize_class(class) when is_atom(class) and class in @canonical_classes, do: {:ok, class}

  def normalize_class(class) when is_binary(class) do
    class
    |> String.trim()
    |> String.downcase()
    |> case do
      "episodic" -> {:ok, :episodic}
      "semantic" -> {:ok, :semantic}
      "procedural" -> {:ok, :procedural}
      "working" -> {:ok, :working}
      _ -> {:error, {:invalid_class, class}}
    end
  end

  def normalize_class(class), do: {:error, {:invalid_class, class}}

  @spec normalize_kind(term()) :: {:ok, kind()} | {:error, term()}
  def normalize_kind(kind) when is_atom(kind), do: {:ok, kind}

  def normalize_kind(kind) when is_binary(kind) do
    trimmed = String.trim(kind)
    if trimmed == "", do: {:error, {:invalid_kind, kind}}, else: {:ok, trimmed}
  end

  def normalize_kind(kind), do: {:error, {:invalid_kind, kind}}

  @spec kind_key(term()) :: String.t()
  def kind_key(kind) when is_atom(kind), do: Atom.to_string(kind)
  def kind_key(kind) when is_binary(kind), do: kind
  def kind_key(kind), do: inspect(kind)

  @spec normalize_tags(term()) :: {:ok, [String.t()]} | {:error, term()}
  def normalize_tags(tags) when is_list(tags) do
    tags
    |> Enum.reduce_while([], fn tag, acc ->
      case normalize_tag(tag) do
        {:ok, normalized} ->
          if normalized in acc, do: {:cont, acc}, else: {:cont, acc ++ [normalized]}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, _} = error -> error
      normalized -> {:ok, normalized}
    end
  end

  def normalize_tags(nil), do: {:ok, []}
  def normalize_tags(other), do: {:error, {:invalid_tags, other}}

  defp normalize_namespace(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: {:error, :namespace_required}, else: {:ok, trimmed}
  end

  defp normalize_namespace(value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  defp normalize_namespace(nil), do: {:error, :namespace_required}
  defp normalize_namespace(other), do: {:error, {:invalid_namespace, other}}

  defp normalize_id(nil), do: {:ok, nil}

  defp normalize_id(id) when is_binary(id) do
    trimmed = String.trim(id)
    if trimmed == "", do: {:error, :invalid_id}, else: {:ok, trimmed}
  end

  defp normalize_id(other), do: {:error, {:invalid_id, other}}

  defp normalize_timestamp(nil, now), do: {:ok, now}
  defp normalize_timestamp(value, _now), do: to_timestamp(value)

  defp normalize_optional_timestamp(nil, _now), do: {:ok, nil}
  defp normalize_optional_timestamp(value, _now), do: to_timestamp(value)

  defp to_timestamp(value) when is_integer(value), do: {:ok, value}
  defp to_timestamp(%DateTime{} = value), do: {:ok, DateTime.to_unix(value, :millisecond)}

  defp to_timestamp(%NaiveDateTime{} = value) do
    value
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:millisecond)
    |> then(&{:ok, &1})
  end

  defp to_timestamp(other), do: {:error, {:invalid_timestamp, other}}

  defp normalize_optional_string(nil), do: {:ok, nil}

  defp normalize_optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: {:ok, nil}, else: {:ok, trimmed}
  end

  defp normalize_optional_string(other), do: {:error, {:invalid_string, other}}

  defp normalize_optional_text(nil), do: {:ok, nil}

  defp normalize_optional_text(text) when is_binary(text) do
    if String.trim(text) == "", do: {:ok, nil}, else: {:ok, text}
  end

  defp normalize_optional_text(other), do: {:ok, inspect(other)}

  defp normalize_map(%{} = map), do: {:ok, map}
  defp normalize_map(nil), do: {:ok, %{}}
  defp normalize_map(other), do: {:error, {:invalid_map, other}}

  defp normalize_version(version) when is_integer(version) and version > 0, do: version
  defp normalize_version(_), do: @default_version

  defp normalize_tag(tag) when is_binary(tag) do
    trimmed = String.trim(tag)
    if trimmed == "", do: {:error, :empty_tag}, else: {:ok, trimmed}
  end

  defp normalize_tag(tag) when is_atom(tag), do: {:ok, Atom.to_string(tag)}
  defp normalize_tag(other), do: {:error, {:invalid_tag, other}}

  defp get_attr(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
