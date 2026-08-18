# Handoff: point `dmon-dev` at the `devlog` binary

You are an agent working **in the `dmon-dev` repository**. This document is a self-contained brief for
you, written by the `devlog` project (a sibling repo). It tells you what must change in `dmon-dev` and
why, and what breaks if you get it wrong. It does not tell you the exact wording of your own prompts or
skills — you know that repo; we don't. Make every change **in `dmon-dev`**, not here.

## The bootstrap this closes

`devlog` exists to replace the hand-edited `DEVLOG.md` working channel that the OpenSpec four-role agent
workflow (Analyst/Architect, worker, reviewer, supervisor) uses to talk to itself. Every role currently
maintains that shared narrative by editing a Markdown file directly. `devlog` replaces the file with an
append-only `DEVLOG.jsonl` and a CLI that writes to it, so posting becomes a command instead of an edit.

This is the change that lets `dmon-dev` stop hand-editing. Your job is not to learn what `devlog` does in
the abstract — it is to change every place in `dmon-dev` that currently assumes "posting to the DEVLOG is
a file edit" so that it instead assumes "posting to the DEVLOG is a `devlog` invocation." Get the guard
hook wrong in particular and you either break the workflow outright or silently remove a boundary it
depends on — see below.

## What you must change, and why

Inspect these paths yourself; do not take line counts here as gospel — verify against your own working
tree.

1. **`plugins/dmons/skills/devlog/SKILL.md`** — the skill that currently maintains `DEVLOG.md` by reading
   and editing it as a file. It must become a skill that shells out to the `devlog` binary: `header` once
   per project (declaring the role set — see D13 below), `section`/`brief`/`post`/`item`/`close`/
   `verdict`/`next` to write, and `resume`/`show`/`list`/`refs`/`status`/`search` to read. The skill no
   longer needs to know Markdown section-heading or `## NEXT` conventions — those are now `devlog`'s
   problem, derived from the log on every read.

2. **`plugins/dmons/skills/scaffold/templates/worker.md.template`,
   `reviewer.md.template`, `supervisor.md.template`, `CLAUDE.md.template`** — every role prompt that
   currently tells an agent "post to `DEVLOG.md`" or gives Markdown-editing instructions for doing so.
   Each needs to instead tell the agent to invoke `devlog <command>` with the body on stdin (see the
   stdin section below) — this is the highest-leverage part of the rewrite, since these four templates are
   what every scaffolded project's agents actually read.

3. **`plugins/dmons/skills/scaffold/templates/dmons-guard.sh.template`** — **the one with real
   consequences.** Today this hook confines the `reviewer` and `supervisor` roles to writing `DEVLOG.md`
   and nothing else, and it can do that cheaply because *posting is a file edit* — the guard just checks
   which file an edit targets. Under `devlog`, posting is a **Bash invocation** (`devlog ... post < ...`),
   not a file edit. A guard that continues to block Bash writes wholesale now blocks the reviewer from
   reviewing — the workflow breaks. A guard that is loosened to "just allow Bash" removes the confinement
   entirely — the boundary silently disappears. Whoever changes this template must make it recognise and
   permit `devlog` *write* subcommands specifically (`header`, `section`, `brief`, `post`, `item`,
   `close`, `verdict`, `next` — see the command list below) while continuing to block: git writes, edits
   to `tasks.md`, edits to the `Makefile`, edits to `CLAUDE.md`/`.claude/`, and attempts to spawn another
   agent. State plainly in your own commit/notes whichever of these two failure modes you might be
   introducing, so a future reviewer of *your* change knows what to check.

4. **`plugins/dmons/skills/update-scaffold/migrations/`** — this directory versions the scaffold's
   migrations (you'll see a sequence like `0.3.0` … `0.5.1` in your own tree). Adopting `devlog` changes
   the scaffold (new skill behaviour, new templates, a changed guard), so it needs a new migration entry
   so that repos already scaffolded with an earlier version can move forward. **Do not invent the version
   number** — read the existing migrations to find the current latest and pick the next one by your own
   project's convention.

## Ground truth: read `docs/FORMAT.md` in this repo, not this document

`docs/FORMAT.md` (in the `devlog` repo, not `dmon-dev`) is the normative record-format specification. It
is written to be reimplementable from itself alone — you do not need to read `devlog`'s `src/` to build a
correct integration. This document restates only what's needed to scope your change; treat `FORMAT.md`
as the source of truth for exact field shapes, the `--json` contract, and the write protocol.

## 1. The command surface

Fourteen subcommands, eight of which write (they take a role, most take a body on stdin, and each
appends at most one record under an exclusive lock) and six of which read (no body, no lock, safe to run
freely):

**Write commands:**

| command | required flags | notes |
|---|---|---|
| `header` | `--change <name>`, `--role <r>` (repeatable, ≥1), `--closer <r>` (repeatable, ≥1) | Declares the role set (D13). Idempotent: writes nothing if identity is unchanged — see below. |
| `section` | `--section <s>`, `--title <t>`, `--base <sha>` | Opens a `tasks.md` section, records its base commit. |
| `brief` | `--section <s>`, `--block <b>`, `--to <role>` | Architect's brief to a worker. `--to` required. |
| `post` | none required (`--section`, `--block`, `--to` all optional) | General working-channel traffic. |
| `item` | `--type <question\|finding\|decision\|note\|task>` | Raises a work item; prints `#<n>` on stdout and nothing else. |
| `close` | `--item <n>`, `--state <resolved\|deferred\|superseded>` | Only a declared closer role may succeed (see D13/`work-items` below). |
| `verdict` | `--section <s>`, `--block <b>`, `--outcome <approve\|approve-with-nits\|request-changes>`, `--commit <sha>` | Typed review verdict. |
| `next` | none | Appends the current NEXT narrative; most recent wins, history preserved. |

All eight also accept `--ref <ns:id>` (repeatable) and all require `--log <path>` and `--role <role>`
globally. All except `header` read the body from stdin.

**Read commands:**

| command | required flags | notes |
|---|---|---|
| `resume` | `--role <r>` | What a role needs to pick up cold: current NEXT, its open items, its latest brief. |
| `show` | exactly one of `--item <n>` / `--seq <n>` | One item (with derived state + full close history) or one raw record. |
| `list` | none | Filterable by `--section`, `--block`, `--role`, `--kind`, `--state`, `--to`, `--blocking`. |
| `refs` | `--ref <ns:id>` | Every record carrying that exact structured reference. |
| `status` | none | Current NEXT plus every open item, unfiltered. |
| `search` | one positional `<query>` | Ranked lexical (BM25) search; see the limit warning below. |

All six accept `--json`. Run `devlog <command> --help` for the exact usage text — it is generated from
the same source this table was checked against.

## 2. The record format — `docs/FORMAT.md` is normative

Do not restate the wire format in your own skill or templates beyond what you need for the invocation
shape. Point your own documentation at `docs/FORMAT.md` in the `devlog` repo instead of copying it — it
is designed to be read on its own, and copying invites drift the moment either repo changes.

## 3. Bodies arrive on stdin (D5) — this changes how every role posts

Every write command except `header` reads its body **verbatim from stdin**, never from a flag, and never
by composing it inline in a shell heredoc. The documented pattern (see `README.md` in the `devlog` repo)
is: write the body to a file in your own scratch directory first, then redirect it in —

```
devlog --log DEVLOG.jsonl --role architect post --section 4 < "$SCRATCH/body.md"
```

Heredocs are discouraged deliberately, not stylistically: bodies are Markdown and routinely contain
fenced code blocks, and composing that inline in a heredoc is a quoting accident waiting to happen in the
one tool whose whole point is preventing format accidents.

Two refusals matter for every role prompt you rewrite:

- **stdin is a terminal** → refused immediately, before reading anything. `devlog` never blocks waiting
  on interactive input.
- **the body is empty or whitespace-only** → refused after reading to EOF. This catches an accidentally
  empty heredoc (which arrives as a lone `"\n"`), but note it is **not** trimming: a body that *is*
  accepted is stored exactly as given, untrimmed.

This is the single most behaviour-affecting item for your skill rewrite — every role that currently
"edits `DEVLOG.md`" instead needs a scratch-file-then-redirect step before it invokes `devlog`.

## 4. The `--json` contract

All six read commands accept `--json` and emit the same derived answer as the rendered text form, as
JSON instead — though `search`'s underlying shape differs slightly from the other five, as explained
below. There are **seven** distinct
top-level shapes across the read surface (`show --seq`, `show --item`, `resume`, `status`, `list`,
`refs`, `search` — `list` and `refs` are each one shape but vary between bare-record-array and
item-array depending on filters). Full shapes are in `docs/FORMAT.md` §8; the property to build your
parser on:

**Every `--json` payload, of all seven shapes, is exactly one line.** No pretty-printing, no embedded
literal newlines in the JSON structure. The newline that follows, if any, is the caller's to add — the
tool's own stdout write does not append one. A downstream parser may assume one JSON value per line of
`devlog ... --json` output, with no shape-specific exception.

## 5. Three warnings — from this repo's own `## NEXT`, phrased as things that will bite

- **Do not reproduce the temp-name pattern as if it were free of consequences.** `devlog` stages every
  write in a temp file (`.<log-basename>.tmp-<32 hex chars>`) beside the log and `rename`s it into place;
  a killed write leaves that temp file behind (this repo mitigates the fallout with a `.gitignore` entry
  for the pattern). If `dmon-dev`'s scaffold templates or tooling ever touch the log's directory
  themselves, they inherit the same orphan-file risk with **none** of this repo's mitigation — nothing in
  `dmon-dev` currently `.gitignore`s that pattern, and it should before anything there could leave one
  behind.
- **`search` is bounded by default; `list --json` is not, deliberately.** `search --json` truncates to
  `--limit` (default 10; `--limit 0` means no bound, reported as `"limit":null`). `list --json` and
  `refs --json` are **never** truncated — they answer a closed question where a partial answer would be
  wrong. Code that assumes uniform bounding across the read surface will either silently lose results
  from an unbounded `list`, or needlessly paginate a `search` that already bounded itself.
- **`--limit` takes bare, non-negative decimal digits only.** No sign, no digit-group separator, and no
  leading zero beyond the literal digit `0`. If your integration formats the value with a zero-padding
  formatter (e.g. `%02d` emitting `"05"`), it will hit a loud refusal, not a silent reinterpretation as
  `5`. Emit bare digits.

## 6. Roles are declared per project, not built in (D13)

`dmon-dev`'s four roles (architect, worker, reviewer, supervisor — or whatever your scaffold currently
names them) are **not** known to `devlog` in advance. Your scaffold's setup step must run `devlog header
--change <name> --role <r> ... --closer <r> ...` to declare them before any other command can succeed —
an undeclared role used as `--role`, `--to`, or in a `close` is refused. Every declared `--closer` must
also be declared as a `--role` in the same write, or the write is refused as a typo.

`header` is idempotent by design: a write compares the new declaration against the current latest
`header` on exactly three things (tool version, role set, closer set — `change` itself is deliberately
excluded from the comparison). If none of those three differ, the write appends nothing at all — so your
scaffold can safely call `header` on every setup run without growing the log.

**`close` is a guardrail, not enforcement.** Only a role declared as a closer may succeed — but the
calling role is self-declared and unverified by `devlog`, so this makes the correct path the easy one; it
does not stop a determined caller from naming a different role. Do not describe it in your own docs as a
security boundary.

## 7. Install reality — state this honestly in whatever you write

There is **no published release of `devlog` yet.** `v0.1.0` has not shipped and the release workflow has
never run. Do not write or imply anything in `dmon-dev` that assumes `brew install devlog`,
`curl .../devlog | sh`, or any other downloadable-binary path exists today — it does not.

When a release does eventually exist: on macOS, a **browser-downloaded** tarball is killed by Gatekeeper
with **no error message** (exit 137, empty stdout/stderr) — the fix is either fetching with `curl`
(which does not attach `com.apple.quarantine`) or running `xattr -d com.apple.quarantine <path>` on an
already-quarantined binary. The minimum supported macOS version is **13 (Ventura)**. Bake this into
whatever install instructions `dmon-dev` eventually carries, once a release actually exists to point at.

## What this document deliberately does not do

It does not restate `docs/FORMAT.md`, it does not speculate about `dmon-dev`'s internals beyond the four
paths named above, and it does not prescribe the exact wording of `dmon-dev`'s own skill or role prompts.
You know that repo; make the calls it needs.
