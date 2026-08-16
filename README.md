# devlog

`devlog` is a single-binary CLI that replaces a hand-edited `DEVLOG.md` working channel with an
append-only, structured log. It is built for the OpenSpec four-role agent workflow — an
Analyst/Architect, one or more workers, a reviewer, and a supervisor — who all read and post to the same
change's log as they build it, the way a thread in a chat room works: attributed posts, in-thread
questions and answers, handoffs, review verdicts.

`DEVLOG.jsonl` — one JSON record per line — is the tool's **only state**. There is no database and no
persisted index (ADR-0002): every invocation reads the whole log, parses it, and derives whatever the
command needs (open items, the current NEXT, a role's resume brief, a search index) entirely in memory,
then discards it on exit. `devlog` is a single self-contained binary with **no third-party dependencies**
(ADR-0001) and **no server** to run — it is a CLI an agent shells out to, not an MCP endpoint or a daemon
(ADR-0003). See `docs/adrs/` for the reasoning behind each of those three decisions.

## Install

Download the release tarball for your platform from this repo's GitHub releases —
`devlog-<version>-aarch64-macos.tar.gz`, `devlog-<version>-x86_64-linux-musl.tar.gz`, or
`devlog-<version>-aarch64-linux-musl.tar.gz` — verify it against the release's `SHA256SUMS`, extract
it, and put the `devlog` binary on your `PATH`. There is nothing else to install — no runtime, no
library, no config file.

The two Linux builds are genuinely static (musl, statically linked): `ldd` reports "not a dynamic
executable". The macOS build is not, and cannot be — Apple does not support statically linking
libSystem — so `otool -L` on it will always show exactly one entry, `/usr/lib/libSystem.B.dylib`. That
is the honest floor on macOS, not a third-party dependency: no other linkage of any kind is present on
either platform.

## Build from source

Requires Zig **0.16.0** exactly (the build API is pre-1.0 and not stable across versions).

```
zig build
```

produces `zig-out/bin/devlog`. This repo's own `make build` / `make test` / `make format` / `make
validate` wrap the toolchain for local development; see the `Makefile`.

## The command surface

Every command needs `--log <path>` to name the `DEVLOG.jsonl` it operates on. Full detail for any
command is `devlog <command> --help`; `devlog --help` lists all fourteen.

### Write commands (append a record)

Every write command but `header` also needs `--role <role>`, and reads its record's body **verbatim
from stdin** — never as a flag (see "Bodies on stdin" below). A write appends exactly one line, under an
exclusive lock, or nothing at all.

| Command | Purpose |
|---|---|
| `header` | Declare the project's role set and which roles may close items. Creates the log, or appends a new header when the declaration changes; writes nothing when it doesn't. |
| `section` | Open a `tasks.md` section and record its base commit — the range a later review diffs against. |
| `brief` | Post the architect's block brief, addressed to a worker. |
| `post` | Post general working-channel traffic — progress, answers, handoffs. |
| `item` | Raise a work item (a question, finding, decision, note, or task) and print its `#n` identifier. |
| `close` | Close a work item with a reason. Restricted to declared closers — see below. |
| `verdict` | Record a typed review verdict (`approve` / `approve-with-nits` / `request-changes`) for a block. |
| `next` | Append the current NEXT narrative. The latest one is current; earlier ones remain as history. |

### Read commands (derive an answer; never modify the log)

Every read command accepts `--json` to emit the same derived answer as machine-readable JSON instead of
rendered text — one derivation, two renderings, so the two forms can never disagree.

| Command | Purpose |
|---|---|
| `resume` | What a role needs to pick up work cold: the current NEXT, its open items, and its latest brief. |
| `show` | One item (with derived state and full close history) or one record, by identifier. |
| `list` | List records, or items, filtered by section, block, role, kind, state, or addressee. Unbounded. |
| `refs` | Every record carrying a given external reference (exact `ns:id` match). Unbounded. |
| `status` | The rendered current state: NEXT plus every currently open item. |
| `search` | Search record bodies, ranked by relevance (lexical BM25, no embeddings), narrowed by `list`'s own filters. Bounded to the 10 best matches by default; `--limit 0` asks for every match. |

`list`/`refs` answer a closed question — "everything matching these filters" — so they are never
truncated. `search` answers an open one where a long tail is noise by construction, so it is the one
bounded read. `--json` output is always exactly one line per invocation; see `docs/FORMAT.md` §8 for the
seven distinct JSON shapes across the read surface and the exact contract a consumer can rely on.

## Two things worth knowing before you use it

**Closing an item is a guardrail, not enforcement.** `header` declares which roles may close items
(`--closer`). `close` refuses a caller whose `--role` isn't in that set — but the calling role is
self-declared and unverified, so this only makes the correct path the easy one; it stops nobody
determined to name a different role. A `--closer` that isn't also declared as a `--role` in the same
`header` write is refused outright, as a typo, not silently accepted as a grant of authority to an
undeclared role.

**Bodies always arrive on stdin, never as a flag.** Redirect the body from a file:

```
devlog --log DEVLOG.jsonl --role architect post --section 4 < "$SCRATCH/body.md"
```

Write the body to a file in your own scratch directory first, then redirect it in, rather than composing
it inline in a shell heredoc. Bodies are Markdown and routinely contain fenced code blocks; composing
that inline in a heredoc is a quoting accident waiting to happen in the one tool that exists to prevent
format accidents. `devlog` refuses immediately, before reading anything, if stdin is a terminal — it
never blocks waiting for interactive input — and refuses after reading if the body turns out empty or
whitespace-only (an accidentally empty heredoc arrives as a lone newline). That refusal is not trimming:
a body `devlog` does accept is stored exactly as given, untrimmed. There is no `--body-file` flag,
because `devlog` writes and removes no file other than `DEVLOG.jsonl` itself and the one temporary file
each write stages and renames it through — it will not delete a file you hand it.

## The record format

`DEVLOG.jsonl` is one JSON object per line: a `header` first, then append-only attributed records of
seven other kinds (`section`, `brief`, `post`, `item`, `close`, `verdict`, `next`), each carrying a
writer role, optional section/block/addressee/references, and a body. Writes are locked and atomic —
every write assigns its `seq` under an exclusive lock and stages the new content in a temporary file
that's renamed into place, so a reader always sees either the log's previous content or its complete new
content, never a torn line.

That's the shape; **`docs/FORMAT.md`** is the normative specification — precise enough to reimplement a
byte-compatible reader and writer from it alone, including the exact write protocol, every field's
validation rule, and the full `--json` output contract.

## Licence

MPL 2.0 — see `LICENSE`. I use this myself; the source is here, PRs are welcome, and you're welcome to
fork it if you want something different. There's no support commitment implied or offered.
