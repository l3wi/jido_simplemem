# Changelog

## Unreleased

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
- Updated docs, examples, and env configuration for Lance-only operation.
