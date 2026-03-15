# Lance Worker Architecture

`jido_simplemem` uses LanceDB as its only storage and indexing backend. Because
there is no official Elixir LanceDB SDK, the package delegates database work to
a small local Python worker started through `Port`.

## Why This Boundary Exists

The goal is behavioral parity with upstream core SimpleMem:

- LanceDB is the canonical upstream storage/index layer
- local Tantivy FTS is part of the expected retrieval behavior
- semantic, lexical, and symbolic retrieval should operate over the same entry set

Using the official Python LanceDB SDK keeps those semantics close to upstream
without reimplementing Lance internals in Elixir.

## Responsibilities

Elixir handles:

- agent/plugin integration
- buffered dialogue lifecycle
- LLM extraction, planning, synthesis, reflection, and answering
- embedding generation
- retrieval orchestration and explainability

The Python worker handles:

- LanceDB connection and table initialization
- memory entry persistence
- session buffer persistence
- semantic vector search
- Tantivy-backed FTS search
- structured metadata filtering

## Communication Model

The Elixir side starts a supervised worker process and talks to it with
JSON-over-stdin/stdout.

Each request contains:

- an operation name
- operation payload
- Lance configuration such as path and table names

Each response returns either:

- `{"ok": true, "result": ...}`
- or `{"ok": false, "error": ...}`

## Persisted Tables

The runtime uses two Lance tables:

- `memory_entries`
  - finalized memory units
  - includes vectors, text, metadata, and provenance
- `session_buffers`
  - unfinalized dialogue windows keyed by namespace and session id

Persisting the session buffer in LanceDB means unfinished windows survive agent
restart or process replacement without introducing a separate SQLite layer.
