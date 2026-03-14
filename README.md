# Jido.SimpleMem

`jido_simplemem` is a single-tier memory plugin for Jido agents. It keeps the
`Jido.Memory.Record` boundary from `jido_memory`, but replaces plain CRUD memory
with a SimpleMem-style pipeline for extraction, synthesis, retrieval, ranking,
answering, and turn hooks.

## What It Includes

- `Jido.SimpleMem.Plugin` for Jido plugin integration
- `Jido.SimpleMem` facade functions for remember, retrieve, answer, forget, and explain
- heuristic write-time extraction and deduplication
- hybrid retrieval over semantic, lexical, and symbolic signals
- explainable retrieval plans and ranking output
- `pre_turn` and `post_turn` actions for agent context injection and capture
- in-memory storage for tests and local development
- Postgres-backed storage for v1 persistence
- Turso/libSQL storage with FTS5 and native vector indexing
- a default durable-memory policy for out-of-the-box agent behavior

## Architecture

The package is intentionally single-tier. Every memory goes through the same
pipeline:

1. `Extractor` normalizes raw input into an enriched memory unit.
2. `Synthesizer` deduplicates or merges related units before persistence.
3. `Store` persists memory units and serves retrieval candidates.
4. `Planner`, `Retriever`, and `Ranker` turn a natural-language request into a ranked record set.
5. `Answerer` and `Explainer` expose answer synthesis and retrieval diagnostics.

The external contract stays compatible with `Jido.Memory.Record`; the richer
internal representation lives in `Jido.SimpleMem.MemoryUnit`.

## Default Behavior

With `Jido.SimpleMem.Plugin` enabled, the package defaults to a SimpleMem-style
memory policy:

- `pre_turn` retrieves relevant memory and builds a compact context pack
- `post_turn` stores only durable facts instead of raw turn transcripts
- explicit user memory instructions such as `remember that...` are stored
- first-person durable facts are rewritten into standalone memory units
- generic questions and most assistant chatter are skipped by default

This is the intended out-of-the-box behavior. The plugin is opinionated about
memory quality and defaults to storing fewer, better memories.

## Usage

Add the dependency to your project:

```elixir
def deps do
  [
    {:jido_simplemem, path: "../jido-simplemem"}
  ]
end
```

Mount the plugin on a Jido agent:

```elixir
plugins: [
  {Jido.SimpleMem.Plugin,
   %{
     capture_signal_patterns: ["ai.react.query", "ai.llm.response"]
   }}
]
```

For the default batteries-included behavior, call `pre_turn` before the agent
responds and `post_turn` after the agent finishes a turn. `post_turn` will
store durable user facts such as profile details, preferences, and constraints,
and skip ordinary chatter.

By default the plugin uses a local SQLite database at `.jido/simplemem.sqlite3`.
You can override that path with `JIDO_SIMPLEMEM_LOCAL_DB_PATH`.

If both `TURSO_DATABASE_URL` and `TURSO_AUTH_TOKEN` are present, the default
store switches to Turso automatically.

To pin Turso explicitly:

```elixir
plugins: [
  {Jido.SimpleMem.Plugin,
   %{
     store:
       {Jido.SimpleMem.Store.Turso,
        [
          url: System.fetch_env!("TURSO_DATABASE_URL"),
          auth_token: System.fetch_env!("TURSO_AUTH_TOKEN")
        ]}
   }}
]
```

Or call the facade directly with agent state that already includes
`__simplemem__`:

```elixir
{:ok, %{last_memory_id: id}} =
  Jido.SimpleMem.remember(agent, %{
    text: "Alice prefers bullet points",
    tags: ["persona:style"]
  })

{:ok, records} = Jido.SimpleMem.retrieve(agent, "What does Alice prefer?")
{:ok, answer} = Jido.SimpleMem.answer(agent, "What does Alice prefer?")
{:ok, explain} = Jido.SimpleMem.explain(agent, "What does Alice prefer?")
```

## Configuration

Plugin config supports:

- `store` and `store_opts`
- `llm_client` and `llm_client_opts`
- `embedding_client` and `embedding_client_opts`
- `memory_policy`
- `retrieval_limit`
- `context_token_budget`
- `reflection_enabled`
- `max_reflection_rounds`
- `capture_signal_patterns`
- `capture_rules`

See [docs/explanations/default-memory-policy.md](docs/explanations/default-memory-policy.md)
for the default heuristics and the durable-memory rules the plugin applies
automatically.

The default implementation ships with a noop LLM client and a strict
`ReqLLM` embedding client. Embeddings are required: the package now fails if no
embedding model is configured or if the provider API key env var is missing.

### Environment Variables

Required:

- `JIDO_SIMPLEMEM_EMBEDDING_MODEL`: embedding model spec, for example `openai:text-embedding-3-small`
- provider API key env var for that model, for example:
  - `OPENAI_API_KEY`
  - `ANTHROPIC_API_KEY`
  - `GOOGLE_API_KEY`

Optional:

- `JIDO_SIMPLEMEM_LOCAL_DB_PATH`: path override for the local SQLite database
- `TURSO_DATABASE_URL`: remote libSQL/Turso URL; when set together with `TURSO_AUTH_TOKEN`, it becomes the default store
- `TURSO_AUTH_TOKEN`: Turso auth token used with `TURSO_DATABASE_URL`

## Turso Notes

The Turso adapter stores enriched memory units in a regular libSQL table and
adds:

- an `fts5` index over restatement and derived search text
- a native libSQL vector index over embeddings
- exact-match symbolic retrieval over JSON metadata such as `persons`,
  `entities`, `tags`, `location`, and `timestamp`

Search uses three retrieval passes, then merges the candidate sets before the
shared ranker runs:

1. lexical candidates from `fts5` + `bm25`
2. semantic candidates from `vector_top_k`
3. symbolic candidates from exact metadata matches

That is the main mechanism used to stay close to upstream SimpleMem-style
hybrid retrieval without depending on LanceDB or Tantivy.

## Testing

Run the suite with:

```bash
mix test
```

Postgres tests are conditional and only run when the required connection
environment is present.
