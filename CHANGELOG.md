# Changelog

## Unreleased

## 0.1.0 - 2026-03-15

- Replaced the old multi-backend storage layer with a LanceDB-only runtime.
- Added a supervised Python LanceDB worker using the official SDK plus Tantivy
  FTS for local hybrid retrieval.
- Persisted both finalized memories and buffered dialogue windows in LanceDB.
- Removed the compatibility facade methods `remember/3`, `retrieve/3`,
  `answer/3`, and `forget/3`.
- Standardized the public API on `add_dialogue/4`, `add_dialogues/3`,
  `finalize/2`, `ask/3`, `get_all_memories/2`, `delete_memory/3`, and `explain/3`.
- Reworked the Jido plugin to expose only parity-oriented actions:
  `pre_turn`, `post_turn`, `finalize`, `ask`, `get_all_memories`, and
  `delete_memory`.
- Replaced heuristic write admission with an LLM-first builder and explicit LLM
  synthesis stage.
- Aligned retrieval around planned hybrid search, source-priority merging, and
  reflection rounds.
- Removed dead plugin/runtime knobs and the unused `Jido.SimpleMem.Ranker`
  module.
- Centralized runtime resolution behind a shared internal runtime builder used
  by both the public API and plugin mount path.
- Hardened LLM and Lance worker boundaries by rejecting unknown external enum
  values and dropping unknown extracted keys without atom creation.
- Changed plugin auto-capture to surface failures through logs, telemetry, and
  typed plugin errors instead of silently swallowing them.
- Added bounded completed-job retention in `Jido.SimpleMem.JobRunner`.
- Updated docs, examples, and env configuration for Lance-only operation.
- Added Hex package metadata, release docs, and a tag-driven GitHub Actions
  release workflow.
