# Default Memory Policy

`jido_simplemem` ships with a default memory policy so the plugin is useful as
soon as it is enabled. The goal is to mimic the SimpleMem write pattern:
capture interaction boundaries, convert only durable information into
standalone memory units, and retrieve that context before the next turn.

## What The Plugin Does By Default

When `Jido.SimpleMem.Plugin` is enabled:

1. `pre_turn` retrieves relevant memories for the current namespace and builds a
   compact context pack.
2. `post_turn` inspects the completed turn and only stores durable facts.
3. auto-captured signals are filtered through the same policy instead of being
   stored verbatim.

This keeps the default behavior closer to SimpleMem than transcript storage.

## What Counts As Durable

The default policy stores:

- explicit memory instructions such as `Remember that I prefer aisle seats`
- user profile facts such as name, location, or workplace
- stable preferences such as response style or favorite items
- durable constraints such as allergies or food restrictions
- tool results captured through `ai.tool.result`

The default policy skips:

- ordinary questions
- most assistant responses
- generic task chatter
- ephemeral turn summaries with no durable user fact

## Why First-Person Rewriting Matters

SimpleMem works best when memories are self-contained. For that reason the
default policy rewrites first-person user statements into standalone form:

- `My name is Alice Chen` becomes `The user's name is Alice Chen.`
- `I live in Portland` becomes `The user lives in Portland.`
- `I prefer concise answers` becomes `The user prefers concise answers.`

This avoids storing memories that depend on unresolved conversational context.

## How A Turn Is Stored

The default `post_turn` action:

1. inspects `user_input` first
2. splits obvious multi-fact inputs into separate memory candidates
3. rewrites durable first-person facts into standalone statements
4. stores only the resulting memory units

If no durable fact is found, `post_turn` returns a skipped result instead of
writing a low-quality memory.

## Namespacing

The policy assumes memory isolation by namespace. For multi-user agents, pass a
namespace such as `tenant:<tenant_id>:user:<user_id>` on each interaction.

## Configuration

The plugin state includes a `memory_policy` map. Current default options are:

- `capture_explicit_memories: true`
- `capture_queries: false`
- `capture_responses: false`
- `capture_tool_results: true`
- `max_memories_per_turn: 6`

These defaults prioritize memory quality over storage of every event.
