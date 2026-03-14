# Examples

This folder contains a minimal Jido agent that uses `Jido.SimpleMem.Plugin` to:

- remember facts
- query/retrieve them
- answer questions from memory
- forget stored items

## Requirements

Embeddings are required. Before running the demo, set:

```bash
export JIDO_SIMPLEMEM_EMBEDDING_MODEL="openai:text-embedding-3-small"
export OPENAI_API_KEY="..."
```

Storage defaults:

- local SQLite: used automatically when Turso env vars are not set
- Turso/libSQL: used automatically when both are set

```bash
export TURSO_DATABASE_URL="libsql://your-db.turso.io"
export TURSO_AUTH_TOKEN="..."
```

## Run The Demo

From the project root:

```bash
mix run examples/simple_memory_demo.exs
```

The script will:

1. create a simple memory agent
2. remember a few facts
3. retrieve and answer from memory
4. forget one record
5. show the retrieval result after deletion

## Files

- [simple_memory_agent.ex](/Users/lewi/Documents/ai/jido-workspace/jido-simplemem/examples/simple_memory_agent.ex)
- [simple_memory_demo.exs](/Users/lewi/Documents/ai/jido-workspace/jido-simplemem/examples/simple_memory_demo.exs)
