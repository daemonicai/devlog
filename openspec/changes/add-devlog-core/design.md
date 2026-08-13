## Context

The four-role OpenSpec agent workflow talks through `DEVLOG.md`, a Markdown file every role edits by
hand. A real four-section change produced 240 KB across 51 posts, and its `## NEXT` grew into 14 KB of
hand-maintained state that the format required be rewritten in full on every write. It got mangled. The
same change invented four identifier namespaces (`D1–D3`, `N1–N14`, `S1–S7`, `F1–F3`) and a lifecycle
vocabulary entirely in prose, because informal items had no way to be resolved.

`devlog` replaces hand-editing with a tool the agents invoke. The requirements are captured in
`proposal.md` and the six spec files; this document records the technology decisions made against them.

Measurement that shaped these decisions: parsing the full 244 KB log, building role and reference
indexes, and scanning every body took **0.31 ms median in JavaScript**; a 2.4 MB / 510-record log parsed
in 2.7 ms. Zig is materially faster again.

Precedent consulted: `memlite` (same author) — Zig 0.16, statically linking SQLite, sqlite-vec,
llama.cpp and md4c into a 6.0 MB binary with no dynamic third-party dependencies, shipped as static
tarballs for macOS arm64 and Linux x86_64/arm64.

## Goals / Non-Goals

**Goals:**

- Structure enforced at the point of writing, so agents fall into doing the right thing.
- `## NEXT` cannot be corrupted, because nothing is ever rewritten.
- Informal items have an explicit, attributable resolution.
- An agent resuming work reads what is open, not the whole history.
- The committed artifact is precisely specified and reconstructible.
- A single binary, nothing to install, start-up indistinguishable from zero.

**Non-Goals:**

- Semantic search in v1 (see D3).
- Any human-editing path — no human edits these files.
- Concurrency as a use case. Locking exists so that future parallelism cannot corrupt a log.
- Search across archived changes.
- The HTML viewer, which is a later phase.

## Decisions

### D1 — Zig 0.16 as the implementation language

The requirement is a single self-contained binary, nothing to install, instant start, invoked dozens of
times per block. `memlite` demonstrates Zig 0.16 meeting exactly this profile at 6.0 MB *including*
llama.cpp; without it this binary should land near 1 MB, linking nothing third-party.

**Rejected — .NET 10**, which is the author's standing default for back-end work and is therefore worth
recording as a deliberate departure. NativeAOT does produce a single file, but it lands in the tens of MB
and carries measurable start-up cost in a process invoked this often. **Rejected — Go**: viable, and
easier to staff, but there is no team to staff; it forfeits the memlite precedent and buys nothing back.
**Rejected — Rust**: the strongest alternative, technically equivalent for this problem, rejected only
because it duplicates what Zig already gives this author at the cost of the existing build knowledge.

**Known risk:** Zig 0.16 is pre-1.0 and its build API breaks between releases. This cost has already been
paid once on memlite, so it is a known quantity rather than a discovery.

### D2 — No database. The JSONL is read and indexed in memory on each invocation

The Product Owner's initial shape was an embedded database (SQLite + sqlite-vec) as a git-ignored cache.
Measurement does not support it: a full parse, index build and scan of the real log costs 0.31 ms. A
database exists to avoid re-reading data, and there is nothing here worth avoiding.

The token argument — the actual motivation — is also satisfied without one. Context is consumed by what
enters the *agent's* window, not by what the binary reads. A tool that reads 244 KB internally and prints
three records has already achieved the entire saving.

So: read `DEVLOG.jsonl`, build the indexes in memory, answer, exit. No `DEVLOG.db`, no C interop, no
third-party linking.

**Rejected — SQLite + sqlite-vec as a cache**: unjustified at this corpus size, and it would drag in the
embedding stack, a model download, a model cache, and roughly 5 MB of binary for semantic recall over
~50 records.

**This decision is deliberately cheap to reverse.** Because the JSONL is the source of truth and every
index is derived, adding a database later is purely additive — no format change and no migration.

**Product Owner note:** this overrides their stated constraint that `DEVLOG.db` be a git-ignored cache.
They accepted the argument; the constraint is withdrawn rather than forgotten.

### D3 — Lexical search now; embeddings only on evidence

BM25 over bodies, plus exact filters on role, section, block, kind, state and reference. No embeddings,
no llama.cpp, no GGUF download.

What this gives up is real: lexical search does not match paraphrase, so "abandoned requests" will not
find a post that only says "cancellation". Three things blunt it. The corpus is 50–200 records, far below
where embeddings earn their cost. External identifiers are now first-class structured references, which
covers the highest-value recall case exactly — the example log made 198 such mentions. And a single
change's log has narrow, repetitive vocabulary by nature.

Revisit only if lexical search demonstrably fails on a real change. Follows D2 and inherits its
reversibility.

### D4 — A CLI, not an MCP server

Commands invoked from the shell. Works in any agent harness, needs no per-project configuration, and
costs an agent no context until actually used.

**Rejected — MCP stdio**, which is what memlite chose, so this is a deliberate divergence. MCP tool
schemas occupy every agent's context permanently, and these subagents already have shell access. An MCP
surface can be added later over the same core if a harness ever needs it.

### D5 — Bodies arrive on stdin; the tool writes and deletes nothing but the log

Bodies are Markdown containing fenced code blocks, so composing them inline in a shell heredoc is a
quoting accident waiting to happen — in a tool whose purpose is preventing format accidents. Agents write
the body to a file in their own ephemeral scratch directory and redirect it in.

The tool **never** deletes or writes any file other than `DEVLOG.jsonl`. A tool that deletes files it did
not create is a footgun: one mistyped path destroys real work, and there is no good answer to whether it
should also delete on failure.

**Guard against hanging:** if stdin is a terminal, or empty, the tool fails immediately with a clear
message. A hung invocation is worse than an error in an agent harness — it burns the turn with no
diagnostic.

**Rejected — `--body-file <path>` with the tool deleting the file afterwards** (the Product Owner's
initial suggestion): unsafe for the reason above. **Rejected — a `devlog draft` / `--draft` handshake**
where the tool owns and therefore may delete the file: correct but costs a second round-trip and a new
concept; reconsider only if scratch-file litter becomes a real problem.

### D6 — One append-only stream; an item is a record kind

Eight record kinds in a single stream: `header`, `section`, `brief`, `post`, `item`, `close`, `verdict`,
`next`. An `item` record *is* the raising of the item and carries its own body, so there is no
post-plus-item duplication and no second entity to keep in sync. `close` records target an item by
number.

**Consequence, accepted deliberately:** a supervisor that today writes one post containing three findings
writes three `item` records instead, because each finding needs its own lifecycle. More calls; that is
the point.

**Rejected — item as a flag on a post**: fewer concepts, but it conflates "a thing said" with "a thing
tracked", and makes an item's lifecycle ambiguous when it is discussed across many posts — which the
example log does extensively.

### D7 — Verdicts are typed records

A `verdict` carries the block, an outcome (`approve`, `approve-with-nits`, `request-changes` — all three
occur in the example log) and the commit. The per-block status grid is then a fold over verdict records
rather than the largest hand-maintained table in `NEXT`.

**Rejected — verdicts as prose in a post**: less ceremony per review, but leaves the grid manual, which
is one of the two things this project exists to eliminate.

### D8 — `brief` is a record kind, and `resume` returns three things

The architect's block brief is neither an item nor NEXT, so an agent resuming cold could not reach it.
Making it a record kind addressed to a role closes the gap. `devlog resume --role <r>` returns the current
NEXT narrative, the open items addressed to that role, and the latest brief for its block — bounded by
what is open rather than by history.

### D9 — Item identifiers are a neutral `#n` sequence

Prefixing by kind (`Q1`, `F1`, `D1`, `N1`) collides head-on with the external namespaces already in use:
`D1–D3` means design decisions and `N1–N14` means architect's notes, referenced 202 times between them in
the example log. `#12` can never be confused with `D2`.

Numbering is derivable — the *n*th `item` record is `#n` — so a rebuild reproduces identical numbers with
no counter to persist. It is stored explicitly regardless, so the file stays self-describing.

### D10 — `refs` may appear on every record kind

Including `close`, since a closure's reasoning frequently cites the decision that settled it. Uniform
across kinds; no per-kind exceptions to remember.

### D11 — Locked, atomic appends

A write takes an exclusive lock on the log for its duration, assigns `seq` under that lock, and appends
the complete line or nothing. An interrupted write must never leave a partial record. Agents run in
series today; this exists so that ceasing to does not corrupt a log.

### D12 — MPL 2.0, static tarballs, no support burden

MPL 2.0. Distribution mirrors memlite: statically linked tarballs attached to tagged GitHub releases for
macOS arm64 and Linux x86_64/arm64. Posture is "I use this, here's the source, PRs welcome, fork it if
you want" — no support commitment implied or offered.

### D13 — Roles are declared per project, in the header

The tool fixes no role vocabulary. A project declares the roles its workflow actually has, and the
declaration lives in the log's own `header` record, so the log carries its vocabulary with it and an agent
reading it cold needs nothing external to interpret attribution. `devlog header` writes that record: it
creates the log, and re-declaring later appends a new header, exactly as a tool-version change already
does. The latest header wins.

A write whose `role` is not in the declared set is **rejected**, naming the declared roles. The
flexibility is in what a project may declare, not in whether a writer may invent a role mid-stream: an
undeclared role is far more often `reviewr` than a genuine new participant, and a typo that silently
fragments attribution is exactly the class of accident this tool exists to prevent. Adding a participant
is a deliberate act — one `devlog header` call — rather than a side effect of a misspelling.

**Rejected — a fixed enum of `architect`/`worker`/`worker-<stack>`/`reviewer`/`supervisor`.** It encodes
one workflow's roster into the format. The four-role split is `dmons`' convention, not a property of
keeping an append-only log, and a project with a different shape should not have to fork the tool.

**Rejected — accept any non-empty string, with the declared set as documentation.** Maximum permissiveness
at the point of writing, but it makes attribution silently unreliable: nothing catches the typo, and the
derived per-role views (`resume --role`, the addressee index) quietly split in two.

**Rejected — accept with a warning on stderr.** Costs the tool a third outcome between success and
failure. Agents parse exit codes reliably and prose unreliably, so a warning is a rejection that doesn't
work.

## Record schema

One JSON object per line. Fields common to all kinds:

| Field | Type | Notes |
|---|---|---|
| `kind` | string | one of the eight kinds; determines the remaining fields |
| `seq` | int | assigned under lock, strictly increasing, contiguous — the total order |
| `ts` | string | ISO 8601 UTC |
| `role` | string | must be one of the roles declared in the log's latest `header`; absent on `header` itself (D13) |
| `section` | string | optional — the `tasks.md` section, e.g. `"3"` |
| `block` | string | optional — task range, e.g. `"3.1-3.3"` |
| `to` | string | optional — addressed role |
| `refs` | array | optional — `[{"ns":"D","id":"2"}]`, any namespace, unvalidated |
| `body` | string | Markdown, verbatim, from stdin |

Per-kind fields:

| `kind` | Additional fields | Purpose |
|---|---|---|
| `header` | `format` int, `tool` string, `change` string, `roles` array of string, `closers` array of string | provenance, the project's declared role set, and which of those roles may close items; carries no `role` of its own; first line, and appended again whenever a different tool version writes or the declaration changes (D13) |
| `section` | `title`, `base` (commit sha) | opens a section and fixes the supervisor's diff range |
| `brief` | — | the architect's block brief, addressed to a worker |
| `post` | — | thread traffic: progress, answers, handoffs |
| `item` | `item` int, `type`, `blocking` bool | `type` ∈ question, finding, decision, note, task |
| `close` | `item` int, `state` | `state` ∈ resolved, deferred, superseded; `body` is the mandatory reason |
| `verdict` | `outcome`, `commit` | `outcome` ∈ approve, approve-with-nits, request-changes |
| `next` | — | the narrative; latest wins |

Example:

```jsonl
{"kind":"header","seq":1,"ts":"2026-08-12T09:00:00Z","format":1,"tool":"devlog 0.1.0","change":"add-devlog-core","roles":["analyst","architect","worker-frontend","reviewer","supervisor"],"closers":["architect"]}
{"kind":"section","seq":2,"ts":"2026-08-12T09:01:00Z","role":"architect","section":"3","title":"Submission form","base":"a1b2c3d","body":"Submission form, validation, and the submit pipeline."}
{"kind":"brief","seq":3,"ts":"2026-08-12T09:02:00Z","role":"architect","section":"3","block":"3.1-3.3","to":"worker-frontend","refs":[{"ns":"D","id":"2"}],"body":"Build the form + validation.\n\n**Decision:** debounce on submit, not keystroke."}
{"kind":"item","seq":5,"ts":"2026-08-12T10:15:00Z","role":"worker-frontend","section":"3","block":"3.1-3.3","item":1,"type":"question","to":"architect","blocking":true,"refs":[{"ns":"S","id":"4"}],"body":"Spec says 300ms, design says 500ms. Which wins?"}
{"kind":"close","seq":6,"ts":"2026-08-12T10:20:00Z","role":"architect","item":1,"state":"resolved","refs":[{"ns":"D","id":"2"}],"body":"500ms — design wins. The spec is stale; I'll flag it separately."}
{"kind":"verdict","seq":11,"ts":"2026-08-12T11:55:00Z","role":"reviewer","section":"3","block":"3.1-3.3","outcome":"approve","commit":"c9d0e1f","body":"Approve."}
{"kind":"next","seq":14,"ts":"2026-08-12T14:25:00Z","role":"architect","body":"Section 3 closed and approved. Resume at 4.1 — open the section with its base commit first."}
```

Forward compatibility: readers ignore unknown *fields*; a `format` value higher than the binary
understands is refused with a clear message rather than guessed at.

## Risks / Trade-offs

- **`git diff` on the JSONL is close to unreadable.** JSON escapes newlines, so a 46-line post is one very
  long line. This is the direct cost of the chosen format and is what the later-phase HTML viewer repays.
  Append-only softens it: diffs are almost always pure additions.
- **Lexical search will miss paraphrase.** Accepted under D3, with structured references covering the
  highest-value case. Revisit on evidence from a real change.
- **More calls per block than the Markdown file required.** Three findings become three invocations
  (D6), and reviews now emit a typed verdict (D7). The trade is deliberate: ceremony at write time buys
  state that cannot drift.
- **Reviewer approval does not close the finding.** Only a declared closing role closes, so an approval is a
  signal and the close is a separate step. In the example log that is 41 verdicts and 7 request-changes
  worth of extra traffic. Kept because the Product Owner set the guardrail explicitly.
- **The close guardrail is not enforcement.** Roles are self-declared; the tool refuses a close from a
  role the header did not declare as a closer, but nothing prevents an agent claiming that role.
  Documented as a guardrail, and a
  spec scenario asserts the documentation says so.
- **Zig 0.16 is pre-1.0.** Build API churn between releases is expected maintenance.
