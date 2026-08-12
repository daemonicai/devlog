## Why

The four-role OpenSpec agent workflow (orchestrator/architect, worker(s), reviewer, supervisor) talks
through `DEVLOG.md`, a Markdown file every role edits by hand. The format asks for two contradictory
disciplines in one file — an append-only thread *plus* a pinned `## NEXT` block that must be rewritten in
full on every write — and nothing enforces either. In a real four-section change `## NEXT` grew to 14 KB
of hand-maintained state (per-block verdict grids, numbered notes, blocking decisions, deferred items)
and got mangled. That same change invented `D1–D3`, `N1–N14`, `S1–S7` and `F1–F3` identifier namespaces
and a vocabulary of *closed* / *settled* / *deferred* / *superseded* entirely in prose, because informal
work items had no explicit way to be resolved. The file reached 240 KB across 51 posts, so any agent
reading for context ingests all of it.

`devlog` replaces the hand-edited file with a small tool the agents invoke, so structure is enforced at
the point of writing and doing the right thing is the path of least resistance.

## What Changes

- **Introduce a `devlog` tool** that agents invoke to write and read a change's working channel. It
  replaces hand-editing of `DEVLOG.md`.
- **The log becomes append-only in fact, not by instruction.** Every write is a new record. Nothing is
  ever edited in place, so nothing can be mangled by rewriting.
- **`## NEXT` stops being authored state.** A NEXT record is a short narrative (resume point, what's
  next); the tool renders it together with the currently open items. The grids and lists that used to be
  retyped on every write are derived, so they cannot drift.
- **Informal work items become first-class**, with tool-assigned quotable IDs, a kind, an addressee, an
  orthogonal `blocking` flag, and an explicit resolution recorded as its own `close` record carrying a
  comment and an author.
- **External identifiers become structured references** (`namespace:id`) rather than substrings in prose.
  The example change made 198 mentions of `D*` and `S*` identifiers it could not query.
- **Targeted reads replace whole-file reads.** An agent starting cold fetches the open items addressed to
  it and the current NEXT; everything else is reachable by reference or search.
- **The on-disk record changes from `DEVLOG.md` to `DEVLOG.jsonl`** — precisely specified, stamped with a
  format/tool version, committed, and travelling into the OpenSpec archive with the change. It is the
  only state the tool keeps; everything else is derived per invocation and discarded.
- **BREAKING** for the existing `devlog` skill: roles post through the tool instead of editing Markdown,
  and the committed artifact is no longer Markdown.

## Capabilities

### New Capabilities

- `append-only-log`: the record model — record kinds, authorship and role attribution, section/block
  references, and Markdown bodies supplied on stdin and stored verbatim.
- `work-items`: item lifecycle — kinds, tool-assigned IDs, blocking flag, addressee, `close` records,
  state derived from open + close, and the orchestrator-only close guardrail.
- `next-state`: NEXT as a repeated append-only narrative record whose latest instance is current,
  rendered together with the open items.
- `external-references`: generic `namespace:id` references, attachable to records and queryable.
- `log-retrieval`: what agents can read — the cold-start read, lookup by reference or ID, and targeted
  search scoped to a single change.
- `durable-format`: `DEVLOG.jsonl` as the source of truth and the tool's only state, format and tool
  versioning, and single-writer locking.

### Modified Capabilities

None — this is the project's first change.

## Impact

- **New repository**: this is a greenfield project with no existing code.
- **Licensing**: MPL 2.0, source-available, "I use this, PRs welcome, fork it if you want" — built
  primarily for the Product Owner, with no support burden implied.
- **Consumers**: the `dmons` `devlog` skill and the `worker` / `reviewer` / `supervisor` agent
  definitions that currently instruct roles to edit `DEVLOG.md` by hand. They live in the `dmon-dev`
  repository and are **not** edited by this change; it delivers a handoff prompt to be run there instead,
  by an agent with that project's history and memories.
- **Repository hygiene**: `DEVLOG.jsonl` is committed. The tool creates no other files.
- **Deployment**: a single self-contained binary with nothing to install and fast start-up, because
  agents shell out to it constantly.

## Technology decisions

All decisions deferred at discovery have now been made and are recorded in `design.md ## Decisions`
(D1–D12), with the three load-bearing ones promoted to ADRs:

- [`ADR-0001`](../../../docs/adrs/ADR-0001-zig-as-implementation-language.md) — Zig 0.16.
- [`ADR-0002`](../../../docs/adrs/ADR-0002-no-database.md) — no database; the JSONL is read and indexed
  in memory on each invocation. This withdraws the Product Owner's original `DEVLOG.db` constraint.
- [`ADR-0003`](../../../docs/adrs/ADR-0003-cli-not-mcp.md) — a CLI, not an MCP server.

Also settled in `design.md`: one append-only stream of eight record kinds with `item` as a kind (D6),
typed verdicts so the status grid is generated (D7), `brief` as a record kind completing the resume read
(D8), neutral `#n` item identifiers that cannot collide with external namespaces (D9), and lexical search
with embeddings deferred until evidence justifies them (D3).

## Out of Scope

- Search across archived changes (search is scoped to a single change).
- Any human-editing path — no human edits these files.
- Concurrent agents. Agents run in series today; write locking anticipates that changing without
  supporting it as a use case.

## Later Phases

- A self-contained HTML page that renders `DEVLOG.jsonl` in a human-friendly format, openable locally or
  published to GitHub Pages.

## Success

The tool has carried one complete, real-world OpenSpec change in a real project, end to end.
