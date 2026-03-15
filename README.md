# Jido.SimpleMem

`jido_simplemem` is a LanceDB-backed, LLM-first memory system for Jido agents.
It is designed to track upstream core SimpleMem behavior more closely than the
earlier CRUD-style plugin shape:

- dialogue is buffered by session instead of written immediately
- overlapping windows are compressed into standalone memory units
- retrieval is planned by an LLM and executed as hybrid search
- reflection can issue follow-up queries when the first pass is insufficient
- answers are synthesized from retrieved memory context
- LanceDB is the only storage and indexing backend

## Public API

`Jido.SimpleMem` exposes the buffered lifecycle directly:

- `add_dialogue/4`
- `add_dialogues/3`
- `finalize/2`
- `ask/3`
- `get_all_memories/2`
- `delete_memory/3`
- `explain/3`

The old compatibility facade methods were removed.

## Runtime Model

The default runtime is buffered and LLM-first.

1. `post_turn` or `add_dialogue/4` appends dialogue events to a persisted
   session buffer.
2. Once a window fills, `MemoryBuilder` sends that window to the configured
   LLM extraction prompt.
3. The LLM emits one or more structured memory entries with resolved
   coreference, standalone restatements, and explicit metadata.
4. A second LLM synthesis pass consolidates related entries while preserving
   complete coverage.
5. `Extractor` normalizes the synthesized entries into memory units.
6. LanceDB persists the resulting memory entries and indexes them for semantic,
   keyword, and symbolic retrieval.
7. `ask/3` uses LLM-planned hybrid retrieval plus optional reflection rounds.
8. `Answerer` synthesizes a grounded answer from the selected records.

## Core API Example

```elixir
{:ok, _} =
  Jido.SimpleMem.add_dialogues(agent, [
    %{speaker: "user", content: "My name is Alice Chen"},
    %{speaker: "assistant", content: "Nice to meet you, Alice."},
    %{speaker: "user", content: "I live in Portland and prefer concise answers"}
  ])

{:ok, _} = Jido.SimpleMem.finalize(agent)

{:ok, answer} = Jido.SimpleMem.ask(agent, "Where does Alice Chen live?")
{:ok, memories} = Jido.SimpleMem.get_all_memories(agent)
```

`add_dialogues/3` buffers. It may return `memory_count: 0` until the configured
window fills or `finalize/2` is called.

## Jido Plugin Workflow

Mount the plugin on a Jido agent:

```elixir
plugins: [
  {Jido.SimpleMem.Plugin,
   %{
     window_size: 6,
     overlap_size: 2
   }}
]
```

Recommended hook pattern:

1. Call `pre_turn` with the incoming user message.
2. Add the returned memory context to the model prompt.
3. Generate the assistant response.
4. Call `post_turn` with `user_input` and `assistant_response`.
5. Call `finalize` when you want to flush an incomplete trailing window.

`post_turn` appends dialogue to the active session buffer. Memory admission is
decided by the LLM-backed builder, not by regex heuristics.

Signal auto-capture runs through the same runtime path as direct ingestion. If
auto-capture fails, the plugin now logs the failure, emits telemetry, and
returns a typed plugin error instead of silently continuing.

`finalize` remains caller-controlled. `Jido.SimpleMem.Plugin` does not hook
into Jido server shutdown directly because that would cross the plugin boundary
into runtime lifecycle management. In practice, call `finalize`:

- at chat or session end
- before shutdown or checkpoint
- before switching `session_id` or namespace
- on idle-time flush boundaries

The plugin can reduce the need for explicit flushes with
`tokens_before_finalize`, which auto-finalizes when the buffered tail crosses a
percentage of `context_token_budget`, but explicit session-end `finalize`
should still be part of the application flow.

This matches upstream SimpleMem core more closely: core usage expects the
caller to invoke `finalize()` explicitly after dialogue ingestion, while the
cross-session layer handles finalization during session-stop orchestration.

## Storage

LanceDB is the only backend.

The package runs a small local Python worker over `Port` because there is no
official Elixir LanceDB SDK. That worker uses the official Python LanceDB SDK
for:

- durable memory entry storage
- durable session buffer storage
- semantic vector search
- Tantivy-backed FTS keyword search
- structured metadata filtering

By default the local LanceDB directory is `.jido/simplemem.lance`. Override it
with `JIDO_SIMPLEMEM_LANCE_PATH`.

The store uses one pinned embedding dimension for the entire index. Set
`JIDO_SIMPLEMEM_EMBEDDING_DIMENSIONS` and keep it stable for both writes and
queries. If you change embedding dimensions later, use a fresh Lance path or
re-embed the existing store.

## Configuration

Important runtime settings:

- `window_size`
- `overlap_size`
- `enable_parallel_retrieval`
- `max_retrieval_workers`
- `reflection_enabled`
- `max_reflection_rounds`
- `retrieval_limit`
- `context_token_budget`
- `tokens_before_finalize`
- `session_id`
- `namespace`
- `store` and `store_opts`
- `llm_client` and `llm_client_opts`
- `embedding_client` and `embedding_client_opts`

The default clients are strict `ReqLLM` adapters. Runtime startup fails when
the required models or provider API keys are missing.

### Environment Variables

Required:

- `JIDO_SIMPLEMEM_LLM_MODEL`
- `JIDO_SIMPLEMEM_EMBEDDING_MODEL`
- `JIDO_SIMPLEMEM_EMBEDDING_DIMENSIONS`
- provider API key env vars for those models, for example:
  - `OPENAI_API_KEY`
  - `ANTHROPIC_API_KEY`
  - `GOOGLE_API_KEY`

Optional:

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

If the extraction, planning, synthesis, or answer models are omitted, the
package falls back to `JIDO_SIMPLEMEM_LLM_MODEL`.

### Direct OpenAI Example

```bash
export JIDO_SIMPLEMEM_LLM_MODEL="openai:gpt-5-mini"
export JIDO_SIMPLEMEM_EMBEDDING_MODEL="openai:text-embedding-3-small"
export JIDO_SIMPLEMEM_EMBEDDING_DIMENSIONS="1536"
export OPENAI_API_KEY="..."
```

### OpenAI-Compatible Endpoint Example

If you want to route requests through a custom OpenAI-compatible endpoint, set:

```bash
export JIDO_SIMPLEMEM_BASE_URL="https://your-endpoint.example.com/v1"
export JIDO_SIMPLEMEM_API_KEY="..."
export JIDO_SIMPLEMEM_LLM_MODEL="openai/gpt-5-mini"
export JIDO_SIMPLEMEM_EMBEDDING_MODEL="openai/text-embedding-3-small"
export JIDO_SIMPLEMEM_EMBEDDING_DIMENSIONS="1536"
export JIDO_SIMPLEMEM_RECEIVE_TIMEOUT_MS="300000"
export JIDO_SIMPLEMEM_POOL_TIMEOUT_MS="300000"
```

When `JIDO_SIMPLEMEM_BASE_URL` is set, the default `ReqLLM` adapters build
OpenAI-compatible model specs with that base URL and pass
`JIDO_SIMPLEMEM_API_KEY` as the explicit request `api_key`. The optional
transport timeouts are applied only for that custom endpoint path.

## Documentation

- [Buffered SimpleMem Lifecycle](/Users/lewi/Documents/ai/jido-workspace/jido-simplemem/docs/explanations/default-memory-policy.md)
- [Lance Worker Architecture](/Users/lewi/Documents/ai/jido-workspace/jido-simplemem/docs/architecture/lance-worker.md)
- [ADR-0001: Single-Tier SimpleMem](/Users/lewi/Documents/ai/jido-workspace/jido-simplemem/docs/decisions/ADR-0001-single-tier-simplemem.md)
- [ADR-0002: SimpleMem Parity Refactor](/Users/lewi/Documents/ai/jido-workspace/jido-simplemem/docs/decisions/ADR-0002-simplemem-parity-refactor.md)

## Testing

Run the full suite:

```bash
mix test
```

The suite includes:

- Lance store contract tests
- buffered lifecycle tests
- reopen/persistence tests against store-backed buffers
- reflection and explainability tests
- confusable-person parity tests
- optional live LLM + embedding + LanceDB integration tests gated by env vars

Run the live integration test explicitly:

```bash
JIDO_SIMPLEMEM_ENABLE_LIVE_LANCE_TESTS=1 mix test --include integration
```
