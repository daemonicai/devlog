## 1. Project skeleton

- [x] 1.1 Initialise the Zig 0.16 project — `build.zig`, `build.zig.zon`, `src/main.zig` — producing a
      single binary with no third-party dependencies (ADR-0001, ADR-0002)
- [x] 1.2 Add the MPL 2.0 `LICENSE` and per-file licence headers (D12)
- [x] 1.3 Add `zig build test` wiring and one trivial passing test, so every later section has a harness
- [x] 1.4 Implement subcommand dispatch and global flags (`--log <path>`, `--role`, `--help`,
      `--version`), with `--help` output for the top level and each subcommand (ADR-0003)
- [x] 1.5 Implement the error-reporting convention — non-zero exit, message on stderr, nothing partial
      written

## 2. Record model and the log file

- [x] 2.1 Define the eight record kinds and their fields as Zig types (`design.md ## Record schema`)
- [x] 2.2 Implement serialisation of a record to one JSON line, with bodies stored verbatim
- [x] 2.3 Implement parsing of a log file into records, ignoring unknown fields and refusing an
      unrecognised `format` with a clear message (`durable-format`)
- [x] 2.4 Implement `seq` assignment — strictly increasing, contiguous, establishing total order
      (`append-only-log`)
- [x] 2.5 Implement exclusive locking and atomic append: the complete line or nothing, `seq` assigned
      under the lock (D11)
- [x] 2.6 Implement the `header` record — carrying `format`, `tool`, `change`, the declared `roles` and
      `closers` (D13), and no `role` of its own; written on file creation, and appended again whenever the
      writing tool version or the declaration differs from the last header
- [x] 2.7 Round-trip test: write a log of every record kind, re-read it, assert every field and the
      ordering survive

## 3. Body input

- [x] 3.1 Read the body from stdin to EOF and store it byte-for-byte (`append-only-log`)
- [x] 3.2 Refuse immediately when stdin is a terminal, with a message pointing at file redirection —
      never block (D5)
- [x] 3.3 Refuse an empty body
- [x] 3.4 Test that a body containing fenced code blocks, tables, and text resembling commands or
      identifiers round-trips unchanged and changes no behaviour

## 4. Write commands

- [x] 4.1 `devlog section --section --title --base` — opens a section and records its base commit
- [x] 4.2 `devlog brief --section --block --to` — the architect's block brief (D8)
- [x] 4.3 `devlog post --section --block [--to]` — general thread traffic
- [x] 4.4 `devlog item --type --to --blocking` — raises an item, assigns the next `#n`, prints the
      identifier (D6, D9)
- [x] 4.5 `devlog close --item --state` — requires a body as the reason; refuses a close from any role
      the header did not declare as a closer, with a message naming the guardrail (`work-items`)
- [x] 4.6 `devlog verdict --section --block --outcome --commit` — typed review verdicts (D7)
- [x] 4.7 `devlog next` — appends the narrative record (`next-state`)
- [x] 4.8 `--ref ns:id` accepted and stored on every write command, repeatable, unvalidated (D10,
      `external-references`)
- [x] 4.9 Reject writes that omit the author role, and validate enum values (`type`, `state`, `outcome`)
      against their permitted sets
- [x] 4.10 `devlog header --change --role <r>` (repeatable) `--closer <r>` (repeatable) — declares the
      project's role set and which roles may close items, creating the log or appending a new header when
      the declaration changes; the `header` record itself carries no role (D13)
- [x] 4.11 Reject a write whose `--role` is not in the latest header's declared set, reporting which
      roles are declared (D13, `append-only-log`)

## 5. Derived state

- [x] 5.1 Derive item state from the opening record plus any close records — open, resolved, deferred,
      superseded (`work-items`)
- [x] 5.2 Derive item numbering positionally, so the *n*th `item` record is `#n`, and assert it matches
      the stored value (D9)
- [x] 5.3 Derive the current NEXT as the most recently appended `next` record (`next-state`)
- [x] 5.4 Derive the per-block status grid by folding `verdict` records by section and block (D7)
- [x] 5.5 Build the in-memory indexes — by role, section, block, kind, state, addressee, and reference
      (ADR-0002)
- [x] 5.6 Test that deriving state twice from the same file gives identical results, and that closing an
      item changes only what is derived

## 6. Read commands

- [x] 6.1 `devlog resume --role <r>` — current NEXT narrative, open items addressed to that role, and the
      latest brief for its block; bounded by what is open, not by history (D8, `log-retrieval`)
- [x] 6.2 `devlog show --item <n>` and `devlog show --seq <n>` — retrieve one item or record with its
      current state and closure
- [x] 6.3 `devlog list` with filters for section, block, role, kind, state, addressee, and blocking
      (`log-retrieval`)
- [x] 6.4 `devlog refs --ref ns:id` — every record carrying that reference, exact match only, never a
      prose scan (`external-references`)
- [x] 6.5 `devlog status` — the rendered current state: NEXT narrative plus open items, with blocking
      items distinguishable (`next-state`)
- [x] 6.6 Report plainly when the log file does not exist on a read, and never create it silently
      (`durable-format`)

## 7. Search

- [x] 7.1 Implement tokenisation and a BM25 index over record bodies, built in memory per invocation (D3)
- [x] 7.2 `devlog search <query>` returning ranked matching records, scoped to the one log file
- [x] 7.3 Combine search with the filters from 6.3, so a query can be narrowed before ranking
- [x] 7.4 Test that search returns matching records rather than the whole log, and that results are
      deterministic for a given file

## 8. Documentation and release

- [ ] 8.1 Write `README.md` — what it is, the command surface, the record format, and the
      "I use this, PRs welcome, fork it" posture (D12)
- [ ] 8.2 Document the close guardrail explicitly: roles are self-declared, the restriction is a
      convention agents are trusted to honour, not enforcement (`work-items`)
- [ ] 8.3 Document the body-on-stdin convention, including the write-to-scratch-file-then-redirect
      pattern and why heredocs are discouraged (D5)
- [ ] 8.4 Specify the record format in prose precisely enough to be reimplemented from the document alone
      (`durable-format`)
- [ ] 8.5 Add the release build: statically linked tarballs for macOS arm64 and Linux x86_64/arm64,
      following the `memlite` pattern (D12)

## 9. End-to-end validation

- [ ] 9.1 Replay the archived example thread through the tool, producing a log covering every record kind
- [ ] 9.2 Assert the generated status grid matches the verdicts recorded, with no hand-maintained table
- [ ] 9.3 Assert `resume` for each role returns only what that role needs, and stays small as history grows
- [ ] 9.4 Write a self-contained handoff prompt to `docs/handoff/dmon-dev-integration.md` for an agent to
      run **in the `dmon-dev` repo** — covering the final command surface, the record format, the
      body-on-stdin convention, and what the `devlog` skill plus the worker/reviewer/supervisor agent
      definitions need to change. Make no edits to `dmon-dev` from this repo: that agent has the
      project's history and memories, and this one does not.
