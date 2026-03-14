# Changelog

## Unreleased

- Added `Jido.SimpleMem` facade APIs for `remember/3`, `retrieve/3`, `answer/3`,
  `forget/3`, and `explain/3`.
- Added `Jido.SimpleMem.Plugin` and action modules for `remember`, `retrieve`,
  `answer`, `forget`, `pre_turn`, and `post_turn`.
- Added a SimpleMem-style pipeline with extractor, synthesizer, planner,
  retriever, ranker, answerer, and explainer components.
- Added `Jido.SimpleMem.MemoryUnit` and mapper support for
  `Jido.Memory.Record` interoperability.
- Added in-memory and Postgres store implementations.
- Added Turso/libSQL storage with native vector indexing, FTS5 lexical search,
  and symbolic metadata retrieval.
- Added a default local SQLite store and env-based switching to Turso when
  `TURSO_DATABASE_URL` and `TURSO_AUTH_TOKEN` are present.
- Replaced the local hash embedding fallback with a strict `ReqLLM` embedding
  client that fails when no embedding model or provider API key env var is set.
- Added a default durable-memory policy that powers `post_turn`, filters
  auto-captured signals, and rewrites first-person user facts into standalone
  memory units.
- Added test coverage for extraction, mapping, retrieval, explanations, plugin
  behavior, and Postgres integration.
