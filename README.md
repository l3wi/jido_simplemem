# Jido.SimpleMem

`jido_simplemem` is a developer-focused SimpleMem-style memory plugin and
runtime for [Jido](https://github.com/agentjido/jido) agents.

It is built around the same core ideas as upstream
[SimpleMem](https://github.com/aiming-lab/SimpleMem): buffered dialogue
ingestion, semantic compression, synthesis, and intent-aware retrieval. This
package adapts that model to the Jido plugin/action lifecycle and to an Elixir
runtime backed by [LanceDB](https://github.com/lancedb/lancedb). The default
runtime path uses
[jido_action](https://github.com/agentjido/jido_action),
[ReqLLM](https://github.com/agentjido/req_llm).

At a glance:

- `Jido.SimpleMem.Plugin` gives Jido agents passive memory hooks
- `Jido.SimpleMem` exposes the buffered lifecycle directly
- LanceDB is the only storage and indexing backend
- retrieval is hybrid and LLM-planned

## What This Package Is

Use this package when you want a Jido agent to:

- accumulate dialogue in windows instead of writing every turn immediately
- compress overlapping turns into standalone long-term memories
- ask grounded follow-up questions against stored memory
- inspect, explain, and delete stored memories directly

This package is not a generic multi-backend memory abstraction. It is a
single-tier, LanceDB-backed runtime with a SimpleMem-style workflow.

## Quick Start

The main integration path is the plugin.

```elixir
defmodule MyApp.MemoryAgent do
  alias Jido.SimpleMem.Actions.{Finalize, PostTurn, PreTurn}

  use Jido.Agent,
    name: "memory_agent",
    plugins: [
      {Jido.SimpleMem.Plugin,
       %{
         window_size: 4,
         overlap_size: 1
       }}
    ]

  def chat(agent, user_input) do
    {agent, _} =
      cmd(agent, {PreTurn, %{user_input: user_input, context_result_key: :memory_context}})

    response = build_response(user_input, agent.state.memory_context)

    {agent, _} =
      cmd(agent, {PostTurn, %{user_input: user_input, assistant_response: response}})

    {:ok, agent, response}
  end

  def flush(agent) do
    {agent, _} = cmd(agent, {Finalize, %{}})
    {:ok, agent}
  end

  defp build_response(_user_input, memory_context) do
    if is_binary(memory_context) and memory_context != "" do
      "I found relevant memory context."
    else
      "I don't have anything in memory yet."
    end
  end
end
```

Required environment:

```bash
export JIDO_SIMPLEMEM_LLM_MODEL="openai:gpt-5-mini"
export JIDO_SIMPLEMEM_EMBEDDING_MODEL="openai:text-embedding-3-small"
export OPENAI_API_KEY="..."
```

Embedding dimensions are inferred. Keep one embedding size per Lance store. If
you switch to an embedding model with a different vector size, clear the store
or re-embed the existing data first.

If you want a runnable example, see
[examples/simple_memory_agent.ex](examples/simple_memory_agent.ex)
and
[examples/simple_memory_demo.exs](examples/simple_memory_demo.exs).

## Public Surfaces

### Plugin

`Jido.SimpleMem.Plugin` exposes these actions:

- `pre_turn`
- `post_turn`
- `finalize`
- `ask`
- `get_all_memories`
- `delete_memory`

Recommended flow:

1. Call `pre_turn` before generating a response.
2. Add the returned memory context to your model prompt.
3. Generate the assistant response.
4. Call `post_turn` with the user input and assistant response.
5. Call `finalize` at session end or before switching `session_id`.

### Direct Runtime API

`Jido.SimpleMem` exposes the same lifecycle without going through a plugin:

- `add_dialogue/4`
- `add_dialogues/3`
- `finalize/2`
- `ask/3`
- `get_all_memories/2`
- `delete_memory/3`
- `explain/3`

Example:

```elixir
{:ok, _} =
  Jido.SimpleMem.add_dialogues(agent, [
    %{speaker: "user", content: "My name is Alice Chen"},
    %{speaker: "user", content: "I live in Portland"},
    %{speaker: "user", content: "I prefer concise answers"}
  ])

{:ok, _} = Jido.SimpleMem.finalize(agent)
{:ok, result} = Jido.SimpleMem.ask(agent, "Where does Alice Chen live?")
```

## How The Package Works

The default runtime is buffered and LLM-first:

1. Dialogue is appended to a persisted session buffer.
2. Once a window fills, the builder sends that window to the configured LLM.
3. The LLM extracts structured memory candidates.
4. A synthesis pass consolidates overlapping facts within the current session.
5. Extracted entries are normalized into `MemoryUnit` structs.
6. LanceDB persists those units and indexes them for semantic, lexical, and structured retrieval.
7. `ask/3` plans retrieval with the LLM, executes hybrid search, and can run reflection rounds.
8. `Answerer` produces a grounded answer from the selected records.

Important behavior:

- writes are buffered, not immediate
- `finalize` is still caller-controlled
- `tokens_before_finalize` is a helper, not a replacement for explicit flushes
- plugin auto-capture uses the same ingestion path as direct writes
- auto-capture failures are logged, emitted via telemetry, and returned as typed plugin errors

## Repository Layout

The repository is organized by subsystem:

- `lib/jido/simple_mem/domain`: core data structures such as `Dialogue`,
  `MemoryUnit`, and embedding helpers
- `lib/jido/simple_mem/pipeline`: extraction, synthesis, planning, retrieval,
  explanation, and answer generation
- `lib/jido/simple_mem/runtime`: shared runtime/config resolution,
  supervision, and job handling
- `lib/jido/simple_mem/plugin`: plugin integration and Jido actions
- `lib/jido/simple_mem/store`: LanceDB storage adapter and Python worker bridge
- `test/support`: test fixtures, fake clients, and target builders
- `examples`: minimal agent/demo flows

## Storage And Runtime Notes

LanceDB is the only backend.

Because there is no official Elixir LanceDB SDK, the package runs a supervised
Python worker over `Port`. That worker is responsible for:

- durable memory storage
- durable session buffer storage
- vector search
- Tantivy-backed keyword search
- structured metadata filtering

Default store path:

```bash
export JIDO_SIMPLEMEM_LANCE_PATH=".jido/simplemem.lance"
```

The embedding dimension is pinned per store. You can switch embedding models,
but not between models with different vector sizes against the same Lance store
without clearing or re-embedding that store.

## Configuration

Common runtime settings:

- `window_size`
- `overlap_size`
- `enable_parallel_retrieval`
- `max_retrieval_workers`
- `retrieval_limit`
- `context_token_budget`
- `tokens_before_finalize`
- `reflection_enabled`
- `max_reflection_rounds`
- `session_id`
- `namespace`
- `store` and `store_opts`
- `llm_client` and `llm_client_opts`
- `embedding_client` and `embedding_client_opts`

Required environment variables:

- `JIDO_SIMPLEMEM_LLM_MODEL`
- `JIDO_SIMPLEMEM_EMBEDDING_MODEL`
- provider API key env vars for the configured models, such as `OPENAI_API_KEY`

Optional environment variables:

- `JIDO_SIMPLEMEM_EXTRACTION_MODEL`
- `JIDO_SIMPLEMEM_PLANNING_MODEL`
- `JIDO_SIMPLEMEM_SYNTHESIS_MODEL`
- `JIDO_SIMPLEMEM_ANSWER_MODEL`
- `JIDO_SIMPLEMEM_BASE_URL`
- `JIDO_SIMPLEMEM_API_KEY`
- `JIDO_SIMPLEMEM_RECEIVE_TIMEOUT_MS`
- `JIDO_SIMPLEMEM_POOL_TIMEOUT_MS`
- `JIDO_SIMPLEMEM_LANCE_PATH`
- `JIDO_SIMPLEMEM_PYTHON_EXECUTABLE`
- `JIDO_SIMPLEMEM_UV_EXECUTABLE`
- `JIDO_SIMPLEMEM_WORKER_START_TIMEOUT_MS`
- `JIDO_SIMPLEMEM_ENABLE_LIVE_LANCE_TESTS`

If stage-specific models are not set, they fall back to
`JIDO_SIMPLEMEM_LLM_MODEL`.

For a custom OpenAI-compatible endpoint:

```bash
export JIDO_SIMPLEMEM_BASE_URL="https://your-endpoint.example.com/v1"
export JIDO_SIMPLEMEM_API_KEY="..."
export JIDO_SIMPLEMEM_LLM_MODEL="openai/gpt-5-mini"
export JIDO_SIMPLEMEM_EMBEDDING_MODEL="openai/text-embedding-3-small"
```

## Development And Testing

Run the default suite:

```bash
mix test
```

`mix test` excludes `:integration` by default.

Run live integration tests explicitly:

```bash
JIDO_SIMPLEMEM_ENABLE_LIVE_LANCE_TESTS=1 mix test --include integration
```

Useful checks:

```bash
mix format
mix test
mix release.check
mix xref callers Jido.SimpleMem.Runtime
```

## Additional Docs

- [Buffered SimpleMem Lifecycle](docs/explanations/default-memory-policy.md)
- [Lance Worker Architecture](docs/architecture/lance-worker.md)
- [ADR-0001: Single-Tier SimpleMem](docs/decisions/ADR-0001-single-tier-simplemem.md)
- [ADR-0002: SimpleMem Parity Refactor](docs/decisions/ADR-0002-simplemem-parity-refactor.md)
- [Releasing](RELEASING.md)
