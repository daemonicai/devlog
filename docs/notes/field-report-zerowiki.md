# Field report — a 24,922-line `DEVLOG.md` from ZeroWiki

Written 2026-08-16 from `emmz/ZeroWiki`, whose `git-backed-content-core` change has been running the
four-role workflow by hand in Markdown for twelve sections. Every number below was measured from that
file, not estimated. It is offered as source material of a size the design may not have been tested
against — the change is still open, so this is a log mid-flight, not a tidy finished one.

## The measurements

| | |
|---|---|
| Total | **24,922 lines / 1,946,639 bytes** |
| Attributed posts | **410** |
| Posts by role | architect **197**, worker **84**, reviewer **84**, supervisor **23** |
| Post length | mean **61** lines, median **48**, p90 **122**, p99 **184**, **max 1,066** |
| Posts over 100 lines | **82** (20%) |
| Sections | 12, from **263** lines (§10) to **6,096** (§6) |
| `## NEXT` pin | **1,083 lines / 90,992 bytes** |
| Handoffs (`→ @`) | **231** |
| Questions (`❓`) | **30** |
| Verdict lines | **81** |
| "for `## NEXT`" posts | **28** |
| Section base commits | **11** — for 12 sections |
| Code fences | **140** |
| Table rows | **217** |
| Longest line | **506** chars |
| Lines containing non-ASCII | **7,218** |
| Commits touching the file | **75** |

## What this validates

- **Bodies on stdin, never a flag.** 140 fenced blocks and 217 table rows across 410 posts. Composing
  those inline would have been a quoting accident per block.
- **`next` as an appended record rather than a rewritten section.** The Markdown pin was rewritten
  across 75 commits and every earlier version is gone except through `git log -p`. Several of those
  rewrites silently dropped things; one carried a hand-arithmetic task count that was wrong and rode
  along through two blocks before anyone recomputed it.
- **`section --base` as a required field.** 12 sections, **11** base commits. The missing one is not
  hypothetical — the repo's own `CLAUDE.md` carries a recovery procedure for exactly this ("if it never
  got a `Base:` post, reconstruct the range from `git log` and say so"), which exists because it
  happened. A structurally required field removes the failure and its recovery procedure together.
- **Reading the whole log per invocation.** 1.9 MB is nothing to parse. The cost that actually hurts is
  *rendering* it into an agent's context, which is a read-command concern rather than a storage one —
  see below.

## Seven suggestions, each from something that went wrong

### 1. `list` should default to one line per record

This is the one I'd rank first. The dominant cost of a log this size is not parsing it, it is **putting
it into an agent's context window**. `list` is documented as deliberately unbounded because it answers a
closed question — which is right — but "everything matching these filters" at mean 61 lines per record
means an unfiltered `list` renders the entire 1.9 MB file.

Suggest: `list` renders **one header line per record** by default — `seq`, `ts`, `kind`, `role`,
`section`/`block`, `to`, and the body's first line — with `--full` to expand bodies. The closed question
is still answered completely; only the rendering changes. `--json` can keep emitting whole records,
since a machine consumer pays no context cost.

The same applies to `resume` for a section like §6 (6,096 lines): it must summarise, never replay.

### 2. A verdict needs the state it certifies, and often there is no commit yet

`verdict` carries `commit`. In practice a block is reviewed **before** it is committed — the reviewer
audits the working tree, the architect commits only after the verdict — so at verdict time there is no
sha to record, and `commit` gets the *parent*, or nothing.

That gap is not theoretical. In one change an `Approve` was given, code landed after it, and the block
committed carrying a verdict that never saw the final state. It happened **twice**, and a supervisor
caught it both times. Both times the code was fine — the defect was in the record, which is the artefact
the whole tool exists to protect.

Suggest: either document `commit` as "the state reviewed, by any stable identifier" and show a
working-tree fingerprint in the example, or add an optional `state` field alongside it. What ZeroWiki now
uses:

```sh
{ git diff HEAD; git ls-files --others --exclude-standard | while read -r f; do printf '%s\n' "$f"; cat "$f"; done; } | shasum | cut -c1-12
```

The `ls-files --others` half matters: `git diff HEAD` alone is **blind to untracked files**, and a
brand-new source or test file is the normal shape of a block that adds one. Verified by adding an
untracked file and watching the hash change.

### 3. Derive the dangling handoff

`→ @` appears **231 times** — handoff is by far the most common structured act in the thread, seven
times more common than a question. The recurring failure is a **dangling handoff**: a `→ @reviewer` with
no verdict beneath it, which is precisely the symptom of the uncertified-state bug above.

The log already has everything needed to derive this: a `post` with `to: reviewer` for a block, and no
later `verdict` for that block. Suggest surfacing it in `status` — "awaiting: reviewer on 4.1–4.3 since
seq 812" — and/or as a `doctor`-style check. It is a derived answer, which is what the tool is good at,
and no human reliably notices it in a 24,922-line file.

### 4. NEXT will still grow unboundedly, because it is narrative

Making `next` an appended record fixes *history loss*, but not *size*: the latest `next` body is still
hand-written prose, and ours reached **1,083 lines** — longer than five of the twelve sections, and
longer than the thing it is meant to let you skip reading.

The growth mechanism is specific and worth designing against: **28 posts titled "for `## NEXT`"**, some
of them 690 and 284 lines, written by reviewers and supervisors as prose and then merged into the pin
*whole* rather than distilled. The tool removes the manual merge — good — but if a supervisor writes a
690-line "for NEXT" body, someone still copies it forward.

Two suggestions, in order of confidence:

- **Guidance, in the docs and in `next --help`:** NEXT carries only what open items cannot express —
  orientation, live hazards, the resume point. Anything with a state belongs as an `item`, which
  `status` and `resume` already compose alongside it.
- **A soft nudge, not a refusal:** `next` prints a warning above some threshold ("this NEXT is 1,083
  lines; you have 12 open items — consider whether some of this is an item"). A hard limit would be
  wrong; people will hit it mid-handover and pad elsewhere.

### 5. Bodies should start their headings at `###`

Markdown-specific and it survives the migration, because bodies stay Markdown and get rendered. In our
file, agents emitted **`## Verdict: Approve`**, `## Checked clean`, `## For \`## NEXT\`` and similar
inside their posts — around 40 of them. In `DEVLOG.md` these were structurally indistinguishable from
`## 6. Commit-on-save` and broke the file's own organisation; the file now has to be grepped rather than
read by its structure.

In JSONL the *structure* problem disappears, but any read command that renders several bodies together
inherits the *visual* one. Suggest documenting `###`-and-below for bodies, and/or demoting body headings
when rendering more than one record.

### 6. The architect writes half the log

architect **197** of 410 posts — 48%, more than worker and reviewer combined. Whatever `resume` does for
the architect is the hot path, and the architect is the role that needs the *widest* view (every
section, every open item, every dangling handoff) rather than the deepest. Worth checking that
`resume --role architect` isn't tuned for the same shape as `resume --role worker`.

### 7. `item` types will be used unevenly — check the closed set against real traffic

Ours, translated into your enumeration: **30** questions, **81** verdict-ish lines, and a large mass of
findings. Two things we recorded constantly that don't map cleanly onto `question|finding|decision|
note|task`:

- **"Checked clean — recorded so it is not re-litigated."** Whole posts (one of 249 lines) exist purely
  to record what was examined and found fine, so a later round doesn't redo it. It's not a finding, not
  a note in the incidental sense — it's negative evidence, and it is some of the most-reused content in
  the log.
- **An accepted risk / deliberate non-fix.** "Recorded and deliberately not fixed" — closest to
  `decision`, but what makes it valuable is that it is *closed and must not be reopened*. `close` with
  `state: deferred` may already cover it; worth a documented example either way.

## One thing I could not check

Everything above is derived from a Markdown log written by agents following a `CLAUDE.md`, not from
`devlog` in use. Where a suggestion assumes how a command renders, I read `README.md` and
`docs/FORMAT.md` rather than running the binary — so treat the rendering claims as questions rather than
findings.
