# Buffered SimpleMem Lifecycle

`jido_simplemem` now defaults to a buffered, LLM-first runtime. The package no
longer relies on heuristic turn filtering or immediate record writes. Instead,
it follows a SimpleMem-style lifecycle built around dialogue windows, semantic
compression, LanceDB indexing, hybrid retrieval, and grounded answer synthesis.

## Write Path

The write path is session-oriented:

1. `add_dialogue/4` or `post_turn` appends dialogue events to a session buffer
   persisted in LanceDB.
2. When the buffered dialogue reaches `window_size`, the builder processes an
   overlapping window.
3. The configured LLM extracts one or more durable, standalone memory entries.
4. The configured LLM then runs a synthesis pass over those entries plus recent
   window history to consolidate related fragments without dropping facts.
5. `Extractor` normalizes those entries into memory units with:
   - `restatement`
   - `timestamp`
   - `location`
   - `persons`
   - `entities`
   - `topic`
   - provenance metadata
6. LanceDB persists the final memory units and builds local FTS on the search
   text for keyword retrieval.

If a session ends before the buffer fills, `finalize/2` flushes the remaining
dialogue through the same path.

## Why Buffering Matters

Immediate per-message writes lose context and create low-value memories. The
buffered approach improves parity with upstream SimpleMem because the LLM sees a
complete local window of dialogue and can:

- resolve pronouns and coreference
- convert relative time into absolute timestamps
- preserve multi-fact turns
- avoid storing raw transcript fragments
- use prior window outputs to reduce duplication across overlaps

## Retrieval Path

`ask/3` and `explain/3` use the same retrieval core:

1. `Planner` asks the configured LLM for a retrieval plan.
2. The plan emits targeted semantic subqueries plus lexical and symbolic hints.
3. `Retriever` executes hybrid retrieval across LanceDB:
   - semantic vector search
   - lexical FTS/Tantivy search
   - symbolic metadata filters
4. Candidate sets are merged and deduplicated by `entry_id`.
5. If reflection is enabled and the first pass is insufficient, the LLM can
   request additional follow-up queries.
6. Results are ordered with upstream-style source priority:
   structured, semantic, then keyword.
7. `Answerer` synthesizes a grounded answer from the selected records.

## Jido Hook Mapping

The recommended hook pattern is:

1. `pre_turn` before generation
2. model call with the returned memory context
3. `post_turn` after generation
4. `finalize` when you want to flush incomplete trailing windows

`pre_turn` uses `ask/3`-compatible retrieval to build context for the incoming
user message. `post_turn` appends the turn to the active session. It does not
run the old durable-fact regex gate.

## Namespace and Session Scope

Namespaces isolate memory ownership. Sessions isolate buffered dialogue state.

- namespace: which memory collection is queried and written
- session_id: which in-flight dialogue window is being accumulated

This allows one agent to serve multiple users safely as long as each request is
scoped to the right namespace and session id.

## Current Scope

This package targets core SimpleMem parity. It does not implement the separate
cross-session SQLite layer from upstream `SimpleMem-Cross`.
