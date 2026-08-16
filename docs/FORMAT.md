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
- Every line carries a string `ts`: an **ISO 8601 timestamp in UTC**, the moment the record was
  written. The emitted shape is fixed and second-precision — `YYYY-MM-DDTHH:MM:SSZ`, e.g.
  `"2026-08-12T09:00:00Z"` — always four-digit year, always two-digit month/day/hour/minute/second,
  always the literal `Z` offset, never fractional seconds and never a `+HH:MM` offset. A reader must
  accept any valid ISO 8601 UTC timestamp (this is a read-side tolerance, not a promise of a wider
  writer), but a byte-compatible writer emits exactly this shape.
- The **first line of the file is always a `header` record** (§3, §6). A log with no header is not
  a legal `devlog` log; every other kind of record requires one to already exist.

## 2. Universal and attributed fields

Three fields are carried by **every** record, of every kind, with no exception:

| Field | Type | Notes |
|---|---|---|
| `kind` | string | one of the eight kinds in §3 below; determines which further fields are legal |
| `seq` | integer | see §1 — assigned under lock, strictly increasing, contiguous |
| `ts` | string | `YYYY-MM-DDTHH:MM:SSZ`, second-precision, UTC — see §1 |

A further six fields — the **attributed** fields — are carried by every kind **except** `header`:

| Field | Type | Required? | Notes |
|---|---|---|---|
| `role` | string | required | the writer's role; must be one of the roles declared in the log's **latest** `header` (§6) |
| `section` | string | optional in general; **required for `brief`, `verdict`, and `section`** — see §3's per-kind table | the `tasks.md` section this record concerns, e.g. `"4"` |
| `block` | string | optional in general; **required for `brief` and `verdict`** — see §3 | the task range this record concerns, e.g. `"4.1-4.3"` |
| `to` | string | optional in general; **required for `brief`** — see §3 | an addressed role; when present, must also be one of the roles declared in the latest `header` |
| `refs` | array of `{"ns": string, "id": string}` | optional, omitted when empty | structured external references; any `ns` is accepted, unvalidated (e.g. `[{"ns":"D","id":"2"}]`) |
| `body` | string | required (may be `""` on the wire — see below) | Markdown, stored verbatim, never parsed or reformatted |

"Optional" above means: legal to omit for *some* kind. Three kinds narrow that per §3's table below, and two
of those three narrowings are **read-side fatal**, not merely a write-side convenience — see "Per-kind
field requiredness" after §3.

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
| `header` | `format` int, `tool` string, `change` string, `roles` array of string, `closers` array of string | `format` is currently `1` — the only value this build ever writes; see §6 |
| `section` | `title` string, `base` string | `title`: one line naming what the section delivers. `base`: a commit sha, stored verbatim and never validated — `devlog` never runs `git`. **Also requires its own attributed `section` field** (e.g. a `section`-kind record with `section: "4"` announces section 4) — write-side only, not a read-side fatal fault; see "Per-kind field requiredness" below. |
| `brief` | — | the architect's block brief; carries no fields beyond the attributed set, but **requires `section`, `block`, and `to`** from that set — see "Per-kind field requiredness" below |
| `post` | — | general working-channel traffic; carries no fields beyond the attributed set |
| `item` | `item` int, `type` string, `blocking` bool | `item` is the raised item's identifier (see "Item identity", below). `type` ∈ `question`, `finding`, `decision`, `note`, `task`. `blocking` is independent of `type`. |
| `close` | `item` int, `state` string | `item` identifies the item being closed. `state` ∈ `resolved`, `deferred`, `superseded`. `body` is the mandatory reason for the closure — not optional prose the way it is for other kinds. `item` must name an item raised **earlier** in the log — see "Cross-record integrity" below. |
| `verdict` | `outcome` string, `commit` string | `outcome` ∈ `approve`, `approve-with-nits`, `request-changes`. `commit`: stored verbatim, never validated. **Also requires `section` and `block`** from the attributed set — see "Per-kind field requiredness" below. |
| `next` | — | the current NEXT narrative; the most recently appended `next` record is the current one, earlier ones remain as history |

`kind` itself is one such closed enumeration (the eight values above); `type`, `state`, and `outcome` are
each a further closed enumeration on top of that. A value outside any of these four enumerations is a
refused write on the write side; a reader that encounters one from foreign or future data must treat it,
and the whole line it appears on, as a parse fault — not guess at its meaning, and not merely skip that one
field. `devlog`'s own reader does not parse a log partially: an unparseable line anywhere in the file (this
includes invalid JSON, a line that isn't a JSON object, a required field missing or wrong-typed, and all
four closed enumerations above) fails `parseLog` for the **entire file**, the same "corrupt log, not a
legal one to reason about further" consequence §1 already states for a broken `seq` sequence.

### Per-kind field requiredness

Beyond §2's general table, three kinds require specific attributed fields that are otherwise optional:

- **`brief`** requires `section`, `block`, and `to`. **Absence of `section` or `block` is a read-side
  fatal fault** — state derivation for the whole log fails (`error.BriefMissingKey`) the moment it
  reaches a `brief` record missing either. `to`'s absence is refused on the write side (every `brief`
  `devlog` itself writes carries it) but is **not** separately checked at read time — nothing in state
  derivation keys on a `brief`'s `to`, so a foreign `brief` record with no `to` still derives, unlike one
  missing `section` or `block`.
- **`verdict`** requires `section` and `block`. Same consequence: absence of either is a read-side fatal
  fault (`error.VerdictMissingKey`), not a tolerated omission — `resume`, `status`, `show --item`, and
  `list --state` all fail to derive state for the **entire log**, not just skip the offending record.
- **`section`** requires its own attributed `section` field (distinct from its kind-specific `title`/
  `base`). This is a **write-side-only** requirement, in the same category as §6's empty-`roles`/
  empty-`closers` rule: nothing in state derivation reads a `section`-kind record's own `section` field,
  so a foreign or historical `section` record without one still derives without error. A reimplementation
  that omits it on write produces a record `devlog` can still read, but not one `devlog` itself would ever
  write.

A reimplementer who builds a writer from §2's general table alone — treating `section`/`block`/`to` as
uniformly optional — produces `brief` and `verdict` records this tool cannot derive state from at all, in
an append-only format with no repair path.

### Cross-record integrity

Two further rules hold across records, not within one, and both are corrupt-log conditions on read —
alongside §1's `seq` rule, which they mirror in shape:

- **A `close` record's `item` must name an item raised *earlier* in the log** — an `item` record with
  that same number must already have appeared at a lower `seq`. A `close` naming a number no `item` record
  has ever carried, or one that only appears *later*, is refused on the write side and is a fatal
  derivation fault on read (`error.CloseTargetMissing`) — the whole log fails to derive, not just that
  record. This is unrelated to, and does not conflict with, the deliberate non-rule already stated under
  "Item-state derivation": **closing an already-closed item is legal** — only a target that never
  precedes the `close` is refused.
- **An `item` record's own `item` field must equal its positional ordinal** — the *n*th `item` record in
  the log must carry `item: n` (see "Item identity" below). A mismatch is refused on the write side and is
  a fatal derivation fault on read (`error.ItemNumberMismatch`), the same "whole log, not just this
  record" consequence as every other fault on this list.

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

### Item identity (D9)

The integer in an `item` record's own `item` field is that item's identifier: the *n*th `item` record
to appear in the log, in `seq` order, is item `#n`. It is assigned under the same write lock that
assigns `seq`, at write time — never renumbered, never reused, and independent of gaps or retries
elsewhere in the log. The sequence counts `item` records only: `header`, `section`, `brief`, `post`,
`close`, `verdict`, and `next` records do not consume a slot, so an item's number and its `seq` are
unrelated numbers that both happen to increase over the same log. A `close` record's own `item` field
names this same identifier — the item it closes.

The identifier is deliberately bare — never a `D`/`N`/`S`/`F`-style prefix. `#n` is `devlog`'s own
identifier namespace, not one of the external reference namespaces a `refs[].ns` entry names (design
elements, notes, specs, findings, …); giving item numbers a prefix of their own would make them
indistinguishable from — and liable to collide with — those external namespaces.

### What `closers` means

A `header` record's `closers` array names the **roles permitted to write a `close` record**: a `close`
whose writer (`role`) is not a member of the **latest** header's `closers` set is refused. This is a
**self-declared guardrail, not enforcement** (D13) — the writer's `role` is supplied by the caller and
never independently verified against anything outside the log, so `closers` makes the correct path the
easy one without stopping a determined caller from naming any role it likes on the command line. §6,
below, covers the write-side rules that constrain how `closers` may be *declared* (it must also be
declared as a `role` in the same write, it has set semantics, and it participates in header-identity
comparison); this paragraph is what the field *means* once declared.

### Item-state derivation

An item's **state** — the derived value behind `show --item`'s `"state"` key, `resume`'s and
`status`'s item arrays, and `list`'s `--state`/`--blocking` narrowing (§8, shapes 2 and 5) — is never
stored directly. It is computed as:

- **`open`** — no `close` record names this item.
- otherwise, the `state` of the **last** `close` record that names this item, in `seq` order. An item
  can be closed more than once (§8 shape 2's `closes` array is the full history); only the most recent
  closure governs the item's current derived state.

The item-state enumeration — `open`, `resolved`, `deferred`, `superseded` — is **one member wider**
than `close.state`'s enumeration in the table above (`resolved`, `deferred`, `superseded`, no `open`):
`open` is never written to a `close` record, because it means "no closure exists" and a `close` record
by definition represents one. It is a purely derived value with no write-side counterpart. A
reimplementer who reads the `close.state` list above as the complete set of item states will be unable
to represent an item that has never been closed.

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
- A `header` write with an empty `roles` array or an empty `closers` array is refused outright — every
  `header` this tool ever writes declares at least one role and at least one closer. This is a write-side
  requirement, not a wire-format one: a reader must still accept a foreign or historical `header` record
  whose `roles` or `closers` array is empty (nothing in the container rules of §1–§2 forbids it), it is
  just something `devlog` itself never produces — the same relationship §2 describes for `body: ""`.
- A `header` record's `tool` field is the literal string `"devlog <semver>"` — the tool's own name, a
  single space, then its version with no `v` prefix (e.g. `"devlog 0.1.0"`). It is generated by the
  writer at write time from its own build version; it is never supplied by the caller. This matters
  beyond documentation completeness: it is one of the three fields identity comparison (next bullet)
  compares verbatim, so a reimplementation that formats this string differently (a `v` prefix, a
  different separator, extra whitespace) will compare unequal to a real `devlog` header on every write
  and append a new `header` record where the shipped tool appends none.
- A new `header` write is compared against the current latest `header` on exactly three things: the
  writing tool's version string, the role set (as a set), and the closer set (as a set).
  - If **all three are unchanged**, the write appends **nothing at all** — not even a no-op record.
  - If **any of the three differs**, a new `header` record is appended, becoming the new latest.
- **`change` is deliberately excluded from this identity comparison.** Two `header` writes with the same
  tool version, role set, and closer set but different `change` values are considered *unchanged* for
  the purposes of this rule, and the second write appends nothing. A reimplementer who folds `change`
  into the comparison will append a `header` record in a case where the shipped implementation appends
  none — a byte-incompatible divergence, not a cosmetic one.
- A `header` record's `format` field is the only format version this tool ever writes, and **its
  value is the integer `1`.** A byte-compatible writer emits `"format": 1` on every `header` record it
  produces — there is currently no other legal value to write. See §7 for what a reader does when it
  encounters a different value.

## 7. Forward compatibility

- A reader must **ignore any JSON object key it does not recognise**, on any record of any kind — the
  format may grow fields over time, and an unrecognised key is not an error.
- A reader must **refuse** a `header` record whose `format` value is anything **other than** a version
  this reader understands, with a clear message naming both the value found and the value(s) understood
  — never guess at how to interpret data in a format version it doesn't know. This is not scoped to
  "higher": a lower or otherwise different unrecognised value is refused identically, because a reader
  that only understands `format: 1` has no more grounds to guess at `format: 0` than at `format: 2`.
  This build understands exactly one version, `1` (§6); it refuses every other value, on either side of
  it. A `format` value the reader *does* understand is processed normally; there is no requirement to
  support reading multiple format versions simultaneously beyond what a given implementation chooses to
  support.

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

This rule is also a requirement in `specs/log-retrieval/spec.md` (the OpenSpec change's spec for the
read surface) — it is a *retrieval* property, not a property of the on-disk format itself. It is
restated here in full, not just cross-referenced, because this document must stay reimplementable from
itself alone.

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
