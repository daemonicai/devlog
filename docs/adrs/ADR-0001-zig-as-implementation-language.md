# ADR-0001 — Zig 0.16 as the implementation language

- **Status:** Accepted
- **Date:** 2026-08-12
- **Change:** `add-devlog-core`
- **Deciders:** Product Owner, Architect

## Context

`devlog` is invoked by agents from the shell, many times per block of work, as part of an interactive
agent loop. The requirements fix two properties that bound the language choice: a **single
self-contained binary with nothing to install**, and **start-up cost indistinguishable from zero**.

The Product Owner's own `memlite` project is direct evidence for a candidate: Zig 0.16, statically
linking SQLite, sqlite-vec, llama.cpp and md4c into a **6.0 MB** binary with no dynamic third-party
dependencies (`otool -L` reports only `libSystem` on macOS), shipped as static tarballs for macOS arm64
and Linux x86_64/arm64.

The Product Owner's standing default for back-end work is .NET 10, so choosing otherwise is a deliberate
departure and is recorded as such.

## Decision

Implement `devlog` in **Zig 0.16**.

Given ADR-0002 removes all C dependencies, the binary should land near 1 MB, linking nothing
third-party.

## Consequences

- Start-up is process creation, with no runtime to initialise — appropriate for a tool on the hot path of
  an agent loop.
- Distribution is a static tarball per platform; users drop a file onto `PATH`.
- The build pattern, cross-compilation targets and release workflow are already proven in `memlite` and
  can be followed rather than discovered.
- **Zig 0.16 is pre-1.0 and its build API breaks between releases.** This is ongoing maintenance cost.
  It has already been paid once on `memlite`, so it is a known quantity.
- The pool of people who could contribute is smaller than for Go or Rust. Accepted: the project is
  explicitly built for its author, source-available with no support commitment.

## Alternatives considered

**.NET 10 (the house default).** NativeAOT does produce a single file, but output lands in the tens of MB
and start-up, while good, is not free in a process invoked this often. Rejected on binary size and
per-invocation cost.

**Go.** Genuinely viable — single static binary, fast start, far gentler learning curve, larger
contributor pool. Rejected because there is no team to benefit from the hiring argument, and it forfeits
the `memlite` precedent without buying anything back.

**Rust.** The strongest technical alternative and essentially equivalent for this problem. Rejected only
because it duplicates what Zig already provides this author, at the cost of existing build knowledge.
