# Examples

This folder contains a minimal Jido agent that uses `Jido.SimpleMem.Plugin` to:

- chat with passive `pre_turn` / `post_turn` hooks
- buffer dialogue and finalize memory windows
- answer questions from memory
- inspect stored memory
- delete stored items by id

In normal agent usage, the plugin is intended to run `pre_turn` before
responding and `post_turn` after a turn so it can retrieve context and append
dialogue to the current memory buffer. Use `finalize` to flush incomplete
windows.

The surrounding app or session manager should own that `finalize` call. A good
default is to call it at session end, before shutdown, before switching
`session_id`, or on an idle timeout. The plugin also supports
`tokens_before_finalize` for automatic flushes when the buffered tail grows too
large, but that is a helper, not a replacement for a real session-end flush.

## Required Env

LLM and embedding models are required. Before running the demo, set:

```bash
export JIDO_SIMPLEMEM_LLM_MODEL="openai:gpt-5-mini"
export JIDO_SIMPLEMEM_EMBEDDING_MODEL="openai:text-embedding-3-small"
export JIDO_SIMPLEMEM_EMBEDDING_DIMENSIONS="1536"
export OPENAI_API_KEY="..."
```

## Optional Env

LanceDB is the only backend. The default local path is `.jido/simplemem.lance`.
Override it if you want the demo to write elsewhere:

```bash
export JIDO_SIMPLEMEM_LANCE_PATH="/tmp/simplemem-demo.lance"
```

## Run The Demo

From the project root:

```bash
mix run examples/simple_memory_demo.exs
```

The script will:

1. create a simple memory agent
2. chat with the user using passive memory hooks
3. flush buffered dialogue with `finalize`
4. answer follow-up questions from memory
5. inspect stored memory
6. delete one record
7. show the effect of deletion on a later turn

## Files

- [simple_memory_agent.ex](/Users/lewi/Documents/ai/jido-workspace/jido-simplemem/examples/simple_memory_agent.ex)
- [simple_memory_demo.exs](/Users/lewi/Documents/ai/jido-workspace/jido-simplemem/examples/simple_memory_demo.exs)
