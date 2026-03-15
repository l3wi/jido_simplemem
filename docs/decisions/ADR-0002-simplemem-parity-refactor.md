# ADR-0002: SimpleMem Parity Refactor

## Status

Accepted

## Context

The first version of `jido_simplemem` borrowed selected SimpleMem ideas, but it
still behaved like a heuristic memory plugin:

- immediate turn-level writes
- regex-based durable fact extraction
- partial retrieval planning
- heuristic answer synthesis

That shape was useful, but it was not behaviorally close enough to upstream
SimpleMem.

## Decision

Refactor the runtime to make LLM-first, buffered semantic compression the
default behavior.

The new architecture:

- buffers dialogue by namespace and session id
- processes overlapping windows via `MemoryBuilder`
- uses the configured LLM for extraction, planning, reflection, and answering
- uses LanceDB as the sole storage and indexing backend
- preserves Jido integration through `pre_turn`, `post_turn`, and `finalize`
  actions

Compatibility methods are removed. The buffered lifecycle API is now the only
integration model.

## Consequences

Positive:

- behavior is materially closer to upstream SimpleMem
- better support for multi-fact turns and coreference resolution
- retrieval can adapt through reflection rounds
- the plugin maps more naturally onto a passive chat workflow
- local indexing now matches upstream more closely through LanceDB + Tantivy

Tradeoffs:

- runtime now depends on configured LLM models, not just embeddings
- the package now depends on a local Python worker for LanceDB access
- the buffered session state is more complex than direct writes
