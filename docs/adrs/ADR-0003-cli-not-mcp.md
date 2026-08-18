# ADR-0003 — A CLI, not an MCP server

- **Status:** Accepted
- **Date:** 2026-08-12
- **Change:** `add-devlog-core`
- **Deciders:** Product Owner, Architect

## Context

`devlog` is written to and read by agents: an orchestrator/architect, one or more workers, a reviewer and
a supervisor. Two interface shapes were credible.

A **CLI** the agents shell out to, which is what the Product Owner described from the outset ("specific
commands").

An **MCP server**, which is what the author's own `memlite` chose — MCP stdio with newline-delimited
JSON-RPC. MCP has real advantages for this use: tool schemas are typed, validated, and self-documenting
in the agent's context, which speaks directly to the project's central goal of making agents "do the
right thing" by construction.

## Decision

Ship a **CLI**. Do not ship an MCP server in v1.

Bodies arrive on **stdin**; everything the tool reasons about is passed as explicit flags.

## Consequences

- Works in any agent harness with shell access, with no per-project configuration and no server lifecycle.
- Costs an agent **no context until it is actually used** — where MCP tool schemas occupy every agent's
  context for the whole session, whether or not the tool is called.
- Discoverability rests on `--help` and on the instructions in the calling skill, rather than on schemas
  the model always sees. This is the main thing given up, and it is why the command surface must be small
  and the help text must be good.
- Validation happens at invocation and is reported as an error, rather than being enforced by a schema
  before the call is made.
- An MCP surface can be added later over the same core if a harness ever requires it. The record format
  and the core logic are interface-agnostic.

**This is a deliberate divergence from `memlite`**, which chose MCP for the same author in an adjacent
problem. The difference is audience: `memlite` serves arbitrary MCP hosts including Claude Desktop, while
`devlog` serves subagents that already have shell access inside a coding harness.

## Alternatives considered

**MCP stdio** (the `memlite` pattern). Rejected for v1 on permanent context cost and configuration
burden, not on capability. Revisit if `devlog` ever needs to serve a host without shell access.

**Both surfaces from one binary, in v1.** Rejected as premature: it doubles the surface to specify, test
and document before a single real change has been carried end to end.
