# The `DEVLOG.jsonl` record format

This document is normative. It specifies `devlog`'s on-disk log format precisely enough that a
competent implementer can write a byte-compatible writer and reader from this document alone, without
reading `src/` or `design.md`. Where this document and the shipped binary (`src/`) disagree, the binary
is authoritative — file an issue.

Ground truth for this document is `src/record.zig` (the record model and JSON codec) and `src/log.zig`
(locking, atomic replace, and header identity), cross-checked against `design.md`'s "Record schema"
section.

## 1. The container

- `DEVLOG.jsonl` is a text file, UTF-8 encoded, of **one JSON object per line**, each line terminated
  by a single `\n`. There is no enclosing array and no trailing comma between lines.
- The log is **append-only**. No command ever rewrites, truncates, or deletes an existing line. Every
  state change — including a correction — is a new line appended after everything already there.
- Every line carries an integer `seq`, assigned **under an exclusive lock on the log file**, at write
  time. `seq` is **strictly increasing and contiguous** across the whole file: the first record is
  `seq: 1`, and each record after it is exactly one more than the previous. A reader that finds a gap or
  a repeat has found a corrupt log, not a legal one to reason about further.
- Every line carries a string `ts`: an **ISO 8601 timestamp in UTC** (e.g.
  `"2026-08-12T09:00:00Z"`), the moment the record was written.
- The **first line of the file is always a `header` record** (§3, §6). A log with no header is not
  a legal `devlog` log; every other kind of record requires one to already exist.

## 2. Universal and attributed fields

Three fields are carried by **every** record, of every kind, with no exception:

| Field | Type | Notes |
|---|---|---|
| `kind` | string | one of the eight kinds in §3 below; determines which further fields are legal |
| `seq` | integer | see §1 — assigned under lock, strictly increasing, contiguous |
| `ts` | string | ISO 8601 UTC |

A further six fields — the **attributed** fields — are carried by every kind **except** `header`:

| Field | Type | Required? | Notes |
|---|---|---|---|
| `role` | string | required | the writer's role; must be one of the roles declared in the log's **latest** `header` (§6) |
| `section` | string | optional | the `tasks.md` section this record concerns, e.g. `"4"` |
| `block` | string | optional | the task range this record concerns, e.g. `"4.1-4.3"` |
| `to` | string | optional | an addressed role; when present, must also be one of the roles declared in the latest `header` |
| `refs` | array of `{"ns": string, "id": string}` | optional, omitted when empty | structured external references; any `ns` is accepted, unvalidated (e.g. `[{"ns":"D","id":"2"}]`) |
| `body` | string | required (may be `""` on the wire — see below) | Markdown, stored verbatim, never parsed or reformatted |

**`header` carries none of the six attributed fields — including no `role` of its own.** A `header`
record is provenance and a declaration, not a post from someone to someone about something; it has no
writer role to carry. This is enforced structurally in the implementation (the `header` variant embeds
no `Attributed` substructure at all), not by a runtime check that could be forgotten.

`body: ""` is syntactically legal on the wire — a record with an empty string there parses without
complaint — but is **never produced by `devlog` itself**: the write-side body reader refuses an empty or
whitespace-only body before a record is ever built (§4, D5). A reader must accept `body: ""` from
historical or foreign data; a writer must never emit it.

## 3. The eight kinds

`kind` is one of exactly eight closed values: `header`, `section`, `brief`, `post`, `item`, `close`,
`verdict`, `next`. Each kind's additional fields, beyond §1's three universal fields and (for every kind
but `header`) §2's six attributed fields:

| `kind` | Additional fields | Notes |
|---|---|---|
| `header` | `format` int, `tool` string, `change` string, `roles` array of string, `closers` array of string | see §6 |
| `section` | `title` string, `base` string | `title`: one line naming what the section delivers. `base`: a commit sha, stored verbatim and never validated — `devlog` never runs `git`. |
| `brief` | — | the architect's block brief; carries no fields beyond the attributed set |
| `post` | — | general working-channel traffic; carries no fields beyond the attributed set |
| `item` | `item` int, `type` string, `blocking` bool | `item` is the raised item's identifier (§7). `type` ∈ `question`, `finding`, `decision`, `note`, `task`. `blocking` is independent of `type`. |
| `close` | `item` int, `state` string | `item` identifies the item being closed. `state` ∈ `resolved`, `deferred`, `superseded`. `body` is the mandatory reason for the closure — not optional prose the way it is for other kinds. |
| `verdict` | `outcome` string, `commit` string | `outcome` ∈ `approve`, `approve-with-nits`, `request-changes`. `commit`: stored verbatim, never validated. |
| `next` | — | the current NEXT narrative; the most recently appended `next` record is the current one, earlier ones remain as history |

`type`, `state`, and `outcome` are each one of a **closed enumeration**. A value outside the
enumeration is a refused write on the write side; a reader that encounters one from foreign or future
data should treat it as a parse fault for that field, not guess at its meaning.

**Field order on the wire**, as the shipped writer emits it (not itself a compatibility requirement — a
reader must not depend on key order in JSON — but recorded here so a `git diff` on the log stays legible
across implementations): `kind`, `seq`, then the kind's own fields in the table order above interleaved
with the attributed fields as `ts`, `role`, `section?`, `block?`, kind-specific fields, `to?`, `refs?`,
`body`. The one exception is `item`, where `to?` is emitted between `type` and `blocking` rather than
after every kind-specific field, so that `item`'s own JSON reads `type` next to `blocking` rather than
splitting them across `to`.

Optional common fields (`section`, `block`, `to`, `refs`) that are unset or empty are **omitted from the
line entirely** — never written as an explicit `null` or an empty array. A reader must treat an absent
key and an explicit `null` (where a foreign writer emits one) identically: both mean "not set".

## 4. Field-level UTF-8 validation (all string fields, not just `body`)

Every record must be valid UTF-8 in **every string field it carries**, not only `body`. This is a
byte-compatibility requirement beyond `design.md`'s narrower framing (which speaks only of `body`): the
implementation validates every string field a record carries, because every one of them can arrive from
uncontrolled input (`argv`, in `devlog`'s own case) and every one of them carries the same hazard —
`std.json`-style stringifiers cannot round-trip an invalid-UTF-8 string, so a record containing one would
be unreadable forever in a format with no repair path (D14: "the tool never writes a record it cannot
read back").

The full set of fields validated, by kind, as implemented:

- Every kind but `header`: `ts`, `role`, `section` (if present), `block` (if present), `to` (if
  present), each `refs[].ns` and `refs[].id`, `body`.
- `header`: `ts`, `tool`, `change`, each element of `roles[]`, each element of `closers[]`.
- `section` additionally: `title`, `base`.
- `verdict` additionally: `commit`.

A reimplementer who validates only `body` reintroduces the exact hazard D14 exists to close, most
concretely through `--to` (or any other field an agent-composed command line can populate with
attacker- or accident-controlled bytes) — a write with a malformed `--to` would otherwise land in the
log and be unreadable forever. Validate every string field listed above before writing a line, and
refuse the whole write — not a partial one — the moment any field fails.

## 5. The temp-file / rename write protocol

**Do not delete the log to implement this. Read this section before writing any code that deletes a
file.**

Every write follows this exact sequence:

1. Open the log file, taking an **exclusive lock** on it (creating the file first if the write is a
   `header` write and no file exists yet; every other kind of write against a missing log is refused
   outright, never creates one).
2. Confirm the lock is not **stale**: re-stat the path and compare its inode against the one the open
   file handle refers to. A `rename` (step 6) replaces a directory entry, not the inode an
   already-open handle points at, so a writer that opened the file before a concurrent writer's
   `rename` completed — and was granted the lock after — would otherwise hold a lock on an orphaned
   inode, and an append there would never be seen by anyone. On a stale lock, release it and retry the
   whole open-and-lock sequence against whatever the path names now, bounded so it cannot spin forever.
3. Read the entire current file content and parse it, to learn the next `seq` and the current latest
   `header`. If the existing content fails to parse, stop here and report the failure — never attempt a
   write on top of content that cannot be trusted.
4. Build the **complete new file content in memory**: the bytes just read, plus the new record
   serialised as one JSON line with a trailing `\n`, concatenated.
5. Stage that complete content in a **fresh temporary file in the log's own directory** (so the
   `rename` in the next step is guaranteed atomic — same filesystem, same directory). The temporary
   file's name is recognisably this tool's own (a dotfile of the shape `.<log-basename>.tmp-<32 hex
   chars>`, the hex from 128 bits of randomness) so that a reader, or a later run of this tool, can tell
   it apart from the log itself and from any other file. The temporary file is created exclusively
   (never overwrites a same-named leftover; a name collision is retried, not clobbered), its content is
   written and then `fsync`ed (the new bytes must be durable on disk **before** the name that will point
   to them changes), and the file handle is closed.
6. **On success**: `rename` the temporary file over the log's own path, then `fsync` the containing
   directory (the `rename` itself — the metadata change — must also be durable). `rename` on the same
   filesystem is atomic, so any concurrent reader observes either the log's entire previous content or
   the log's entire new content — never a torn or partial record. Once the `rename` succeeds, the
   temporary file no longer exists as a separate name: **it has become the log.** There is nothing left
   to delete.
7. **On any failure** between the temporary file's creation (step 5) and a successful `rename` (step
   6) — a write error, an interrupted process, an `fsync` failure, a `rename` failure — the temporary
   file is removed (`unlink`ed) by the failing writer before the error is reported. The log file itself
   is never touched by this cleanup: only the temporary file, which at that point has never been
   `rename`d into place, is removed.
8. The lock taken in step 1 is released once the whole operation — success or failure — completes.

**The load-bearing distinction, stated as plainly as possible:** the temporary file is *removed* only on
the **failure** path, before any `rename` has happened. On the **success** path it is *renamed*, not
removed — by the time the command exits, the file that was staged as the temporary file **is** the log,
under the log's own name. A reader who takes "the temporary file is removed before the command exits" to
mean "the temporary file is `unlink`ed after a successful `rename`" will delete the log itself, because
by that point the temporary file's inode and the log's are the same thing under the log's name; there is
no separate temp file left over to unlink, and nothing else at that path should be touched.

The temporary file is the **one exception** to "no state exists outside the log file": it lives only for
the duration of a single write, in the log's own directory, and — per the rule above — is gone (either
renamed into the log or removed on failure) before the writing command exits. It is a write mechanism,
not persisted state, and no command ever reads a temporary file back.

A **read** command (§8) never creates a temporary file, takes no lock, and inherently ignores any
temporary file left beside the log by a killed writer process: it opens the log by its own exact name,
and a temporary file's name is never that name.

## 6. Header identity (D13, D15)

- The **latest `header` record in the file** (by `seq`, i.e. the last one when scanning the file in
  order) is the log's **current** declaration: current role set, current closers, current tool version.
  Earlier `header` records remain in the log as history but do not govern current behaviour.
- `roles` and `closers` are each a **set**, not an ordered list. Reordering the same roles across two
  `header` writes is not a change and appends nothing. A `header` write that names the same role twice
  in one declaration is **refused** outright, not silently deduplicated and stored.
- Every declared `closer` must **also** be declared as a `role` in the same write. A `closer` naming a
  role that is not also a declared `role` is refused as a typo, not honoured as a grant of closing
  authority to an undeclared role.
- A new `header` write is compared against the current latest `header` on exactly three things: the
  writing tool's version string, the role set (as a set), and the closer set (as a set).
  - If **all three are unchanged**, the write appends **nothing at all** — not even a no-op record.
  - If **any of the three differs**, a new `header` record is appended, becoming the new latest.
- **`change` is deliberately excluded from this identity comparison.** Two `header` writes with the same
  tool version, role set, and closer set but different `change` values are considered *unchanged* for
  the purposes of this rule, and the second write appends nothing. A reimplementer who folds `change`
  into the comparison will append a `header` record in a case where the shipped implementation appends
  none — a byte-incompatible divergence, not a cosmetic one.
- A `header` record's `format` field is the only format version this tool ever writes; see §7.

## 7. Forward compatibility

- A reader must **ignore any JSON object key it does not recognise**, on any record of any kind — the
  format may grow fields over time, and an unrecognised key is not an error.
- A reader must **refuse** a `header` record whose `format` value is **higher** than the version this
  reader understands, with a clear message naming the mismatch — never guess at how to interpret data in
  a format version it doesn't know. A `format` value the reader *does* understand is processed normally;
  there is no requirement to support reading multiple format versions simultaneously beyond what a given
  implementation chooses to support.

## 8. The `--json` output contract

`devlog`'s read commands accept a `--json` flag that emits the same derived answer the command's
human-rendered text form shows, as JSON instead — one derivation, two renderings, never two derivations
that could disagree. There are **seven** distinct top-level JSON shapes across the read surface:

1. **`show --seq <n> --json`** — a **bare record**: the JSON object for that one line of the log,
   exactly as it appears on disk (same fields, same kind).
2. **`show --item <n> --json`** — an object `{"number": n, "state": s, "item": {...}, "closes":
   [...]}`: the item's identifier, its currently derived state, the `item` record that raised it, and
   the array of every `close` record that has ever closed it (oldest first) — an item can be closed more
   than once; the array is the full history, not just the one that currently governs the derived state.
3. **`resume --role <r> --json`** — an object `{"next": ..., "items": [...], "brief": ...}`: the
   current NEXT record (or `null` if none has ever been posted), the array of currently open items
   addressed to that role, and the latest `brief` record addressed to that role's current block (or
   `null` if none exists — the key `brief` is still present, its value is `null`).
4. **`status --json`** — an object `{"next": ..., "items": [...]}`: the current NEXT record (or
   `null`) and every currently open item, with no role narrowing. Unlike `resume`'s shape, `status`'s
   object carries no `brief` key at all — not `brief: null`, the key is simply absent.
5. **`list --json`** — a **bare JSON array**. Its elements are full records when no state-deriving
   filter narrows the result, or item objects (the same derived-item shape used by `show --item`'s
   `"item"` field, plus its derived `state`) when `--state` or `--blocking` is given — those two flags
   narrow the result from records to items, because only an item has a state or a blocking flag.
6. **`refs --ref <ns:id> --json`** — a **bare JSON array** of full records: every record carrying the
   given `(ns, id)` pair as a structured reference, an exact match on both parts, never a prefix and
   never a scan of body prose.
7. **`search <query> --json`** — an object `{"total": N, "limit": L, "records": [...]}`: `total` is
   how many records matched before any limit was applied, `limit` is the cap that was actually in
   force, and `records` is the matching records (the same shape `list` emits for a record) in rank
   order, truncated to at most `limit` of them. `records.len < total` is how truncation is expressed —
   there is no separate boolean for it. **`limit` is JSON `null`, not the integer `0`,** when the
   caller passed `--limit 0` (the input idiom for "no cap at all"): the field always reports what
   actually bounded the result, and a literal `0` would misread as "zero results allowed" beside a full
   list of matches.

**Every `--json` payload, of all seven shapes, is exactly one line — no pretty-printing, no embedded
literal newlines in the JSON structure itself (a `body` field's own `\n` characters are JSON-escaped as
part of the string, not literal newlines in the output).** The newline that follows the JSON, if any, is
the caller's to add — the tool's own stdout write does not append one. This is the single most
load-bearing part of this contract for a downstream consumer that parses stdout line-by-line: it may
assume one JSON value per line of `devlog ... --json` output, with no shape-specific exception.

## 9. Read-side role validation: latest header vs. header history

This rule has no other spec home; this document is it.

`--role` and `--to` filters on the read surface are validated against the log's declared role set, but
**which** declaration differs by command family:

- **`resume --role <r>`** validates `<r>` against the roles declared in the **latest** `header` record
  only — the project's *current* identity. A role retired from a later `header` is no longer a valid
  value for `resume --role`, even though its historical records remain in the log.
- **`list --role <r>` / `list --to <r>`**, and the same two flags on **`search`**, validate against the
  **union of every role ever declared across every `header` record in the log** — the project's whole
  history. A role the project has since retired (e.g. this project's own `orchestrator` → `architect`
  retirement) still authored records that remain in the log, and `list`/`search` exist to query that
  whole history, not just the project's current shape; validating against only the latest header would
  make the tool refuse to search its own past.

Both checks refuse a value that was **never** declared in any header, in the same message shape as the
write-side refusal for an undeclared `--role`/`--to`. A retired role is a legal filter value for
`list`/`search`; an unknown one is refused exactly as it would be on the write side.

`--kind`, `--state`, and `--blocking` filters are validated against the fixed, tool-defined enumerations
in §3 and are not affected by this section — those sets are not per-project declarations.

## Also worth knowing (non-normative notes, not part of the wire format)

- **`--state`/`--blocking` narrow `list`'s result from records to items, but never narrow `search`'s.**
  `search` always returns records, under every combination of flags; `list` returns items instead of
  records the moment either of those two flags is given. This asymmetry is deliberate, not an oversight.
- **`search` is the one bounded read.** `list --json` and `refs --json` are never truncated — they
  answer a closed question ("everything matching these filters") where a partial answer would be wrong.
  `search --json` truncates to `limit` (default 10) because relevance ranking answers an open question
  where a long tail is noise by construction. A consumer that assumes uniform bounding across the read
  surface will either silently lose results from an unbounded `list`, or needlessly paginate a `search`
  that has already bounded itself.
- **`--limit` accepts plain, non-negative decimal digits only** — no leading `+`/`-` sign, no `_`
  digit-group separators, and no leading zero beyond the literal digit `0` itself. `--limit 05` is
  refused, loudly, not silently reinterpreted as `5`; a caller that formats the value with a zero-padding
  formatter (e.g. `%02d`) will hit this refusal and must emit bare digits instead.
- **Exit codes**: `0` on success, `1` on any refusal, with the message on stderr prefixed `devlog: ` and
  terminated with one newline. Piping a `--json` payload into a command that closes its end of the pipe
  early (e.g. `devlog ... list --json | head -c 40`) surfaces as `devlog: WriteFailed` at exit `1` — a
  write-side failure from the closed pipe, not a bug in the command that ran.
