# ADR-0002 — No database; the JSONL is read and indexed in memory

- **Status:** Accepted
- **Date:** 2026-08-12
- **Change:** `add-devlog-core`
- **Deciders:** Product Owner, Architect

## Context

The Product Owner's initial shape for `devlog` was a binary embedding SQLite and sqlite-vec, keeping a
git-ignored `DEVLOG.db` as a working cache alongside the committed `DEVLOG.jsonl`, with vector search so
that agents could query the log without ingesting all of it.

Two facts examined during architecture undercut that shape.

**Measurement.** Against the real 240 KB / 51-post log, a full parse into records, construction of role
and reference indexes, and a scan of every body cost **0.31 ms median — in JavaScript**. A synthetic
2.4 MB / 510-record log parsed in 2.7 ms. Zig is materially faster again. A database exists to avoid
re-reading data; at this size there is nothing worth avoiding.

**The token argument does not require one.** Reducing context consumption was the motivation, but context
is spent on what enters the *agent's* window, not on what the binary reads. A tool that reads the whole
log internally and prints three matching records has already delivered the entire saving.

The cost side is not small: SQLite plus sqlite-vec pulls in the embedding stack (llama.cpp, a GGUF model
download, a model cache), a C interop surface, and roughly 5 MB of binary — to serve semantic recall over
a corpus of 50–200 records.

## Decision

**Ship no database.** On each invocation, read `DEVLOG.jsonl`, build the required indexes in memory,
answer, and exit. There is no `DEVLOG.db`, no C dependency, and nothing to link statically.

The parameter identifying what to operate on is the path to the change's **log file**.

## Consequences

- The binary stays around 1 MB with no third-party linking, and there is no C-interop hazard surface.
- The "is the cache really disposable?" tension disappears rather than being managed: with no embeddings
  there is no expensive derived data to persist.
- Cold start on a fresh clone is identical to steady state — there is nothing to build.
- Every invocation reads the whole file. At current and projected sizes this is sub-millisecond; a log
  reaching tens of MB would need revisiting, which the reversal path below covers.
- Semantic search is not available. See ADR-0003's sibling decision D3 in `design.md`: lexical BM25 plus
  exact filters, revisited on evidence.

**Reversal is cheap and was a condition of accepting this.** The JSONL is the source of truth and every
index is derived, so introducing a database later is purely additive — no format change, no migration,
no rewrite of stored data.

## Alternatives considered

**SQLite + sqlite-vec as a git-ignored cache** (the Product Owner's original proposal). Rejected as
unjustified at this corpus size, and because it drags the entire embedding stack in with it. The
Architect argued against it; the Product Owner accepted the argument and withdrew the `DEVLOG.db`
constraint.

**SQLite without sqlite-vec**, purely for FTS5 and structured querying. Rejected: it still costs the C
dependency and the binary size, to replace an in-memory index that measures at 0.31 ms.
