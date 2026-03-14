# ADR-0001: Single-Tier SimpleMem Architecture

## Status

Accepted

## Context

The package needs to provide a SimpleMem-inspired memory system for Jido agents
without inheriting the tiered control-plane design from `jido_memory_os`.

The desired behavior is:

- native Elixir implementation
- compatibility at the `Jido.Memory.Record` boundary
- plugin-driven turn hooks
- explainable retrieval
- one memory system instead of `short` / `mid` / `long` tiers

## Decision

Implement `jido_simplemem` as a standalone single-tier package that uses
`jido_memory` as the compatibility boundary but owns its own internal pipeline.

The package keeps:

- Jido plugin and action patterns
- explicit `pre_turn` and `post_turn` integration
- explainability surfaces for debugging retrieval decisions

The package does not depend on `jido_memory_os` for orchestration.

## Consequences

- Simpler runtime model with one persistence and retrieval path
- Easier integration for agents that want SimpleMem semantics directly
- Internal freedom to enrich stored memories beyond plain `Jido.Memory.Record`
- Lower compatibility with MemoryOS tier orchestration, by design
- Postgres remains the main durable backend for v1, while tests and local runs
  can use the in-memory store
