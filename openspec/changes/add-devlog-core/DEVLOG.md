# DEVLOG — add-devlog-core

> **Bootstrap note.** This change builds the tool that replaces this very file. Until `devlog` ships and
> `dmon-dev` is repointed at it (task 9.4), the change is carried in hand-edited Markdown — including the
> `## NEXT

**[architect]** Section 1 is **code-complete**, base `331878d`. Both blocks have landed: **1.1–1.3**
(skeleton, MPL licence, test harness) and **1.4–1.5** (dispatch, global flags, error convention). All five
boxes ticked, gates green (`BUILD_EXIT:0 TEST_EXIT:0 FORMAT_EXIT:0 VALIDATE_EXIT:0 GATES_EXIT:0`), 22
tests passing.

**The section is not closed until the `supervisor` approves it** over `331878d..HEAD`. That is the next
action — not section 2.

Standing facts for whoever picks this up cold:

- Workflow is `dmons` 0.4.0: gates run through `make`, reports quote `LABEL_EXIT:<n>`. Gates run
  **in-sandbox** — `~/.cache/zig` is on the write allowlist. A `manifest_create PermissionDenied` or
  `unable to load 'std.zig'` means that entry went missing, not a broken toolchain.
- **Version is single-source.** `build.zig.zon`'s `.version` is the one copy; `build.zig` defaults
  `-Dversion` to `manifest.version`; the test asserts the two agree. The manifest reaches the test module
  via an anonymous import (`build.zig:22`) because Zig 0.16 refuses a direct `@import("../build.zig.zon")`.
  The exe is byte-identical with and without it (1 872 872 bytes), so ADR-0002 holds.
- **Zig 0.16 changed `main`'s signature** — `pub fn main(init: std.process.Init) !void` is required to
  read argv or write stdout/stderr; `std.process.argsAlloc` and `std.io.getStdOut` are gone. Verified twice
  against a fresh `zig init` on the pinned toolchain. Write against 0.16's API, never a remembered one.
- **Parse-ambiguity beats `--help`/`--version`** — see the ❓ answered decision above. Any new error
  condition in section 4 must be placed on the correct side of that line.

Carried forward, all non-blocking:

- **For 8.5 (release tooling).** `zig build test -Dversion=X` fails — a legitimate use of the override
  makes `build_options.version` and `manifest.version` disagree and the test reads it as skew. Nothing runs
  tests with `-Dversion` today, but 8.5 is where the override is meant to be used.
- **For 4.8/4.9's brief.** The precedence rule is legible in `run()` but not enforced by structure: a new
  ambiguity condition (e.g. 4.8's `--ref ns:id` shape check) could be added below the boundary comment and
  still compile and format clean. The reviewer suggests a named `Parsed.isAmbiguous()` predicate rather
  than three ordered `if`s relying on comment discipline.
- **For 4.10's brief.** The task as written spells `devlog header --change --role <r>`, introducing
  `--change` alongside the established global `--log <path>`. Settle the flag naming when briefing it
  rather than letting two conventions drift.
- **Untested by name.** `devlog frobnicate --help` (unknown command plus help/version) behaves correctly
  but has no test of its own.
- **Self-reported test counts have been wrong twice**, both times by exactly 4 — the suite is real and
  passing, but check a quoted count rather than repeating it. Actual: 22.

After the supervisor closes section 1, resume at **section 2** (record model and the log file), opening it
with its own `Base:` post.
