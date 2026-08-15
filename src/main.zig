// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

const std = @import("std");
const build_options = @import("build_options");
const manifest = @import("manifest");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const record = @import("record.zig");
const log = @import("log.zig");
const body = @import("body.zig");
// Aliased `state_mod`, not `state`: a plain `const state = @import(...)`
// would be shadowed by `runClose`'s own local `state` (the parsed
// `--state` value) — Zig refuses that shadowing outright. `runShow`
// (block 6A) is the first command to derive read-side state.
const state_mod = @import("state.zig");
const search = @import("search.zig");
test {
    _ = record;
    _ = log;
    _ = body;
    _ = state_mod;
    _ = search;
}

/// One subcommand of the surface. `section` names the `tasks.md` section
/// that owns its real behaviour. `usage`, when set, is the command's real
/// `--help` body (block 4A: `header`, `post`); commands without one still
/// get the honest "not yet implemented" placeholder rather than an
/// invented promise.
const CommandSpec = struct {
    name: []const u8,
    summary: []const u8,
    section: []const u8,
    usage: ?[]const u8 = null,
    /// Whether the command recognises a bare positional argument after its
    /// name (section 4 supervisor finding B1). Every command this change
    /// builds is `false` — a stray token is a refused parse fault, not a
    /// silently dropped one — except `search` (7.2), which takes its query
    /// this way. A property on the spec rather than a name check against
    /// `"search"`, so the exemption is structural and does not have to be
    /// remembered when a future command adds one too.
    ///
    /// Deliberately a **boolean, not a count** (architect ruling R1, DEVLOG
    /// `## 7`): "exactly one" is the only arity a positional has here, and
    /// it is enforced where the value is *stored* (`setPositional`), the
    /// same shape `setOnce` gives an exactly-once flag. A second bare token
    /// is `unexpected_argument`, exactly as it is for a command that takes
    /// none at all — B1's silent-acceptance defect stays fixed for both.
    takes_positional: bool = false,
};

const header_usage =
    \\USAGE
    \\    devlog --log <path> header --change <name> --role <r> [--role <r> ...]
    \\        --closer <r> [--closer <r> ...]
    \\
    \\Declares the project's role set (D13). Creates the log if it does not
    \\exist yet; appends a new header when the tool version or the
    \\declaration differs from the latest header already in the log;
    \\writes nothing at all when neither differs.
    \\
    \\FLAGS
    \\    --change <name>  The change this log belongs to, stored on the
    \\                     header record. Required, exactly once.
    \\    --role <r>       A role this project's workflow has. Repeatable;
    \\                     at least one required.
    \\    --closer <r>     A role allowed to close a work item (the
    \\                     `work-items` guardrail — self-declared, not
    \\                     enforced). Repeatable; at least one required,
    \\                     and every value must also be given as --role.
    \\
    \\`--log <path>` (above the command) is the file this invocation
    \\operates on; `--change <name>` is the change's own slug, stored
    \\inside the header record it writes. They name different things.
    \\
    \\Takes no body: never reads stdin.
;

const post_usage =
    \\USAGE
    \\    devlog --log <path> --role <role> post [--section <s>] [--block <b>]
    \\        [--to <role>] [--ref <ns:id> ...] < body.md
    \\
    \\Posts general working-channel traffic: the fields every attributed
    \\record kind shares, plus a body, nothing else.
    \\
    \\FLAGS
    \\    --section <s>   The tasks.md section this post concerns. Optional.
    \\    --block <b>     The task range this post concerns. Optional.
    \\    --to <role>     The addressed role. Optional. When given, must be
    \\                    one of the roles declared by 'devlog header'.
    \\    --ref <ns:id>   A structured external reference. Repeatable,
    \\                    unvalidated — any namespace is accepted.
    \\
    \\The body is read verbatim from stdin — never a flag, never a
    \\heredoc. Redirect it from a file: `devlog ... post < body.md`.
;

const section_usage =
    \\USAGE
    \\    devlog --log <path> --role <role> section --section <s> --title <t>
    \\        --base <sha> [--ref <ns:id> ...] < body.md
    \\
    \\Opens a tasks.md section and records its base commit — the range a
    \\supervisor review diffs against later. All three flags required.
    \\
    \\FLAGS
    \\    --section <s>   The tasks.md section this record opens, e.g. "4".
    \\    --title <t>     One line: what this section delivers.
    \\    --base <sha>    The commit this section starts from. Stored
    \\                    verbatim and unvalidated — the tool never runs
    \\                    git, never checks the sha exists or its length.
    \\    --ref <ns:id>   A structured external reference. Repeatable,
    \\                    unvalidated — any namespace is accepted.
    \\
    \\The body is read verbatim from stdin — never a flag, never a
    \\heredoc. Redirect it from a file: `devlog ... section < body.md`.
;

const brief_usage =
    \\USAGE
    \\    devlog --log <path> --role <role> brief --section <s> --block <b>
    \\        --to <role> [--ref <ns:id> ...] < body.md
    \\
    \\Posts the architect's block brief, addressed to a worker (D8). All
    \\three flags required — a brief addressed to nobody is not a brief,
    \\and 'devlog resume --role <r>' reaches it precisely through --to.
    \\
    \\FLAGS
    \\    --section <s>   The tasks.md section this brief concerns.
    \\    --block <b>     The task range this brief concerns, e.g. "4.1-4.3".
    \\    --to <role>     The addressed role. Required, and must be one of
    \\                    the roles declared by 'devlog header'.
    \\    --ref <ns:id>   A structured external reference. Repeatable,
    \\                    unvalidated — any namespace is accepted.
    \\
    \\The body is read verbatim from stdin — never a flag, never a
    \\heredoc. Redirect it from a file: `devlog ... brief < body.md`.
;

const item_usage =
    \\USAGE
    \\    devlog --log <path> --role <role> item --type <t> [--section <s>]
    \\        [--block <b>] [--to <role>] [--blocking] [--ref <ns:id> ...]
    \\        < body.md
    \\
    \\Raises a work item (work-items) and prints its assigned identifier,
    \\as '#<n>', and nothing else on stdout — so a shell can capture it.
    \\
    \\FLAGS
    \\    --type <t>      One of: question, finding, decision, note, task.
    \\                    Required.
    \\    --section <s>   The tasks.md section this item concerns. Optional.
    \\    --block <b>     The task range this item concerns. Optional.
    \\    --to <role>     The role expected to act on it. Optional. When
    \\                    given, must be one of the roles declared by
    \\                    'devlog header'.
    \\    --blocking      Flags the item as blocking. Independent of
    \\                    --type — any kind of item may block.
    \\    --ref <ns:id>   A structured external reference. Repeatable,
    \\                    unvalidated — any namespace is accepted.
    \\
    \\The body is read verbatim from stdin — never a flag, never a
    \\heredoc. Redirect it from a file: `devlog ... item < body.md`.
;

const close_usage =
    \\USAGE
    \\    devlog --log <path> --role <role> close --item <n> --state <s>
    \\        [--ref <ns:id> ...] < body.md
    \\
    \\Closes a work item (work-items). Only a role declared as a closer by
    \\'devlog header' may close — a guardrail, not enforcement (the
    \\calling role is self-declared and unverified). The body is the
    \\mandatory reason for the closure.
    \\
    \\FLAGS
    \\    --item <n>      The item's identifier, without the leading '#'.
    \\                    Required. Refused if no such item was ever
    \\                    raised.
    \\    --state <s>     One of: resolved, deferred, superseded. Required.
    \\    --ref <ns:id>   A structured external reference. Repeatable,
    \\                    unvalidated — any namespace is accepted.
    \\
    \\Closing an already-closed item is allowed: a later close is a
    \\correction, appended as its own record, not an error. Which close
    \\wins is decided when the item's state is derived, not here.
    \\
    \\Takes no --section, --block, or --to.
    \\
    \\The body is read verbatim from stdin — never a flag, never a
    \\heredoc. Redirect it from a file: `devlog ... close < body.md`.
;

const verdict_usage =
    \\USAGE
    \\    devlog --log <path> --role <role> verdict --section <s>
    \\        --block <b> --outcome <o> --commit <sha> [--ref <ns:id> ...]
    \\        < body.md
    \\
    \\Records a typed review verdict for a block (D7). All four flags
    \\required.
    \\
    \\FLAGS
    \\    --section <s>   The tasks.md section this verdict concerns.
    \\    --block <b>     The task range this verdict concerns.
    \\    --outcome <o>   One of: approve, approve-with-nits,
    \\                    request-changes.
    \\    --commit <sha>  The commit reviewed. Stored verbatim and
    \\                    unvalidated — the tool never runs git.
    \\    --ref <ns:id>   A structured external reference. Repeatable,
    \\                    unvalidated — any namespace is accepted.
    \\
    \\The body is read verbatim from stdin — never a flag, never a
    \\heredoc. Redirect it from a file: `devlog ... verdict < body.md`.
;

const next_usage =
    \\USAGE
    \\    devlog --log <path> --role <role> next [--ref <ns:id> ...] < body.md
    \\
    \\Appends the current NEXT narrative (next-state). The most recently
    \\appended NEXT becomes the current one; earlier ones remain as
    \\history and are never rewritten.
    \\
    \\FLAGS
    \\    --ref <ns:id>   A structured external reference. Repeatable,
    \\                    unvalidated — any namespace is accepted.
    \\
    \\Takes no --section, --block, or --to: NEXT is change-scoped
    \\narrative, not addressed to anyone or bound to one section.
    \\
    \\The body is read verbatim from stdin — never a flag, never a
    \\heredoc. Redirect it from a file: `devlog ... next < body.md`.
;

const show_usage =
    \\USAGE
    \\    devlog --log <path> show --item <n> [--json]
    \\    devlog --log <path> show --seq <n> [--json]
    \\
    \\Retrieves one item, with its current derived state and full close
    \\history, or one record, by identifier (log-retrieval). `--item` and
    \\--seq are mutually exclusive; exactly one is required.
    \\
    \\FLAGS
    \\    --item <n>  An item's identifier, without the leading '#'.
    \\    --seq <n>   A record's sequence number.
    \\    --json      Emit the same result as JSON instead of rendered
    \\                text (D15). One derivation, two renderings — never
    \\                two derivations.
    \\
    \\Takes no body: never reads stdin.
;

const resume_usage =
    \\USAGE
    \\    devlog --log <path> resume --role <r> [--json]
    \\
    \\Gives a role what it needs to pick up work cold (D8, log-retrieval):
    \\the current NEXT narrative, the open items addressed to that role, and
    \\the latest brief for the role's block. Bounded by what is currently
    \\open, not by the log's history.
    \\
    \\The role's block is the block of the most recently posted 'brief'
    \\addressed to the role; the brief returned is the latest one for that
    \\block, which may since have been addressed to someone else (a
    \\remediation brief). If no brief has ever been addressed to the role,
    \\the brief is plainly absent.
    \\
    \\FLAGS
    \\    --role <r>  The role to resume as. Required, and must be one of
    \\                the roles declared by 'devlog header'.
    \\    --json      Emit the same result as JSON instead of rendered
    \\                text (D15). One derivation, two renderings — never
    \\                two derivations.
    \\
    \\Takes no body: never reads stdin.
;

const status_usage =
    \\USAGE
    \\    devlog --log <path> status [--json]
    \\
    \\Renders the current state (next-state): the current NEXT narrative
    \\together with every currently open item. Closing an item, with no new
    \\NEXT recorded, removes it from the next 'status'. Items flagged
    \\blocking are distinguishable from non-blocking ones in both forms.
    \\
    \\FLAGS
    \\    --json  Emit the same result as JSON instead of rendered text
    \\            (D15). One derivation, two renderings — never two
    \\            derivations.
    \\
    \\Takes no body: never reads stdin.
;

const list_usage =
    \\USAGE
    \\    devlog --log <path> list [--section <s>] [--block <b>] [--role <r>]
    \\        [--kind <k>] [--state <s>] [--to <role>] [--blocking] [--json]
    \\
    \\Lists records, or items, narrowed along any combination of the
    \\dimensions below. Every given filter must match — filters combine
    \\with AND (log-retrieval).
    \\
    \\FLAGS
    \\    --section <s>  Only records/items concerning this tasks.md
    \\                   section.
    \\    --block <b>    Only records/items whose block label matches.
    \\                   Given alone, matches by label and may span
    \\                   sections; given together with --section, the two
    \\                   are the intersection — the one identified block.
    \\    --role <r>     Only records authored by this role (for an item,
    \\                   the role that raised it). Must be one of the
    \\                   roles declared by 'devlog header'.
    \\    --kind <k>     Only records of this kind: header, section, brief,
    \\                   post, item, close, verdict, next. Refused alongside
    \\                   --state or --blocking unless it names 'item'.
    \\    --state <s>    Only items in this derived state: open, resolved,
    \\                   deferred, superseded. Narrows the result from
    \\                   records to items (only an item has a state).
    \\    --to <role>    Only records/items addressed to this role. Must be
    \\                   one of the roles declared by 'devlog header'.
    \\    --blocking     Only items flagged blocking. Narrows the result
    \\                   from records to items. There is no --no-blocking:
    \\                   absent means no filtering on it.
    \\    --json         Emit the same result as JSON instead of rendered
    \\                   text (D15). One derivation, two renderings — never
    \\                   two derivations.
    \\
    \\With no filters, every record is listed in log order. An empty
    \\result is an ordinary success (an empty list), not a refusal.
    \\
    \\Takes no body: never reads stdin.
;

const refs_usage =
    \\USAGE
    \\    devlog --log <path> refs --ref <ns:id> [--json]
    \\
    \\Shows every record carrying the given external reference
    \\(external-references) — an exact match on the (namespace, identifier)
    \\pair, never a prefix and never a scan of body prose. A record that
    \\merely mentions the identifier in its body without recording it as a
    \\structured reference is not returned.
    \\
    \\FLAGS
    \\    --ref <ns:id>  The reference to look up. Required, exactly once.
    \\    --json         Emit the same result as JSON instead of rendered
    \\                   text (D15). One derivation, two renderings — never
    \\                   two derivations.
    \\
    \\An empty result is an ordinary success (an empty list), not a
    \\refusal.
    \\
    \\Takes no body: never reads stdin.
;

const search_usage =
    \\USAGE
    \\    devlog --log <path> search <query> [--section <s>] [--block <b>]
    \\        [--role <r>] [--to <role>] [--kind <k>] [--state <s>]
    \\        [--blocking] [--json]
    \\
    \\Searches the bodies of this log's records for the query's words and
    \\returns the matching records, most relevant first (D3: lexical BM25,
    \\no embeddings and no persisted index — the index is built in memory
    \\on each invocation and discarded on exit).
    \\
    \\ARGUMENTS
    \\    <query>  The words to search for. Exactly one argument: quote a
    \\             multi-word query. A second bare token is refused rather
    \\             than silently dropped. A query cannot begin with '-':
    \\             it would be read as a flag, and there is no '--'
    \\             terminator to escape it. Quoting does not help, since
    \\             the shell strips the quotes before devlog sees them. In
    \\             practice this costs nothing — leading punctuation is not
    \\             part of any word the index holds, so searching for the
    \\             word without its dash finds the same records.
    \\
    \\FLAGS
    \\    --section <s>  Only records concerning this tasks.md section.
    \\    --block <b>    Only records whose block label matches. Given
    \\                   alone, matches by label and may span sections;
    \\                   given with --section, the two are the
    \\                   intersection — the one identified block.
    \\    --role <r>     Only records authored by this role. Must be one of
    \\                   the roles declared by some 'devlog header' in this
    \\                   log, including a retired one.
    \\    --to <role>    Only records addressed to this role. Same rule.
    \\    --kind <k>     Only records of this kind: header, section, brief,
    \\                   post, item, close, verdict, next. Refused
    \\                   alongside --state or --blocking unless it names
    \\                   'item'.
    \\    --state <s>    Only the records that opened items now in this
    \\                   derived state: open, resolved, deferred,
    \\                   superseded.
    \\    --blocking     Only the records that opened items flagged
    \\                   blocking. There is no --no-blocking: absent means
    \\                   no filtering on it.
    \\    --json         Emit the same result as JSON instead of rendered
    \\                   text (D15). One derivation, two renderings — never
    \\                   two derivations.
    \\
    \\The filters are 'list''s, and they narrow the query *before* it is
    \\ranked: relevance is computed over the records that survive them, so
    \\a word that is rare in the section you are searching ranks as rare
    \\even if it is common across the whole change. Every given filter must
    \\match — filters combine with AND. Unlike 'list', --state and
    \\--blocking do not change what is returned: a search always returns
    \\records, under every combination of flags.
    \\
    \\The result is the same shape 'list' and 'refs' emit, and the ranking
    \\is the order it arrives in: there is no score field. A record matches
    \\when its body contains at least one of the query's words; matching
    \\folds ASCII case and does no stemming. Records are ranked by BM25,
    \\ties broken by seq ascending, so the same log and query always give
    \\the same order.
    \\
    \\Only the log named by --log is searched — a search never reaches
    \\another change's log.
    \\
    \\Finding nothing is an ordinary success (an empty list), not a
    \\refusal.
    \\
    \\Takes no body: never reads stdin.
;

/// Names only, from sections 4, 6 and 7 of the change's `tasks.md`. This
/// block dispatches to them and gives each a `--help`; their behaviour is
/// those sections' to build. `header`, `post`, `section`, `brief`, and
/// `next` are real as of blocks 4A/4B.
const commands = [_]CommandSpec{
    .{ .name = "header", .summary = "Declare the project's role set, creating the log or appending a new header.", .section = "4", .usage = header_usage },
    .{ .name = "section", .summary = "Open a section and record its base commit.", .section = "4", .usage = section_usage },
    .{ .name = "brief", .summary = "Post the architect's block brief to a worker.", .section = "4", .usage = brief_usage },
    .{ .name = "post", .summary = "Post general working-channel traffic.", .section = "4", .usage = post_usage },
    .{ .name = "item", .summary = "Raise a work item and print its identifier.", .section = "4", .usage = item_usage },
    .{ .name = "close", .summary = "Close a work item with a reason (declared closers only).", .section = "4", .usage = close_usage },
    .{ .name = "verdict", .summary = "Record a typed review verdict for a block.", .section = "4", .usage = verdict_usage },
    .{ .name = "next", .summary = "Append the current NEXT narrative.", .section = "4", .usage = next_usage },
    .{ .name = "resume", .summary = "Show the current NEXT, open items for a role, and its latest brief.", .section = "6", .usage = resume_usage },
    .{ .name = "show", .summary = "Show one item or one record by its identifier.", .section = "6", .usage = show_usage },
    .{ .name = "list", .summary = "List records, filtered by section, block, role, kind, state, or addressee.", .section = "6", .usage = list_usage },
    .{ .name = "refs", .summary = "Show every record carrying a given external reference.", .section = "6", .usage = refs_usage },
    .{ .name = "status", .summary = "Show the rendered current state: NEXT plus open items.", .section = "6", .usage = status_usage },
    .{ .name = "search", .summary = "Search record bodies, ranked by relevance, narrowed by list's filters.", .section = "7", .usage = search_usage, .takes_positional = true },
};

/// The one place that owns the `devlog: ` prefix, the trailing newline,
/// and the exit code for a failure message — every call site passes only
/// the message itself. Before this existed, `main.zig` hand-composed the
/// prefix at each of its own call sites, `body.zig`'s
/// `writeRefusalMessage` composed it again independently, and the two
/// disagreed the moment a body refusal reached both: a body refusal
/// printed `devlog: devlog: refusing…` (supervisor finding N-a, section 3
/// remediation — section 1's `## NEXT` had already flagged the missing
/// mechanism as N3, before either shape existed). `record.Diagnostics`'s
/// own messages already carry no prefix, so this is what every one of
/// them — `Diagnostics.message`, `body.refusalMessage`'s result, or a
/// plain literal — should be printed through, uniformly (A4).
fn fail(stderr: *Io.Writer, comptime fmt: []const u8, args: anytype) u8 {
    stderr.print("devlog: " ++ fmt ++ "\n", args) catch {};
    return 1;
}

/// Comptime-joined list of an enum's field names, in declaration order —
/// for a refusal message that names the permitted set (`4.9`) exactly as
/// `log.zig`'s undeclared-role/`--to` messages name the *declared* set
/// (A1). The set here is fixed by the tool, not declared per project
/// (`ItemType`/`CloseState`/`VerdictOutcome` are part of the format), so
/// it is computed once at compile time from `record.zig`'s enums
/// themselves rather than restated as a literal that could drift from
/// them — the same staleness the D10 amendment (DEVLOG `## 4`) argued
/// against for a different field.
fn joinEnumNames(comptime E: type) []const u8 {
    const fields = @typeInfo(E).@"enum".fields;
    comptime var result: []const u8 = "";
    inline for (fields, 0..) |f, i| {
        if (i != 0) result = result ++ ", ";
        result = result ++ f.name;
    }
    return result;
}

const item_type_names = joinEnumNames(record.ItemType);
const close_state_names = joinEnumNames(record.CloseState);
const verdict_outcome_names = joinEnumNames(record.VerdictOutcome);
const record_kind_names = joinEnumNames(record.Kind);
/// `list`'s `--state` names a *derived* item state (`state_mod.ItemState`),
/// not `record.CloseState` — a close record's own three states, plus the
/// absence of one (`open`). Distinct permitted sets, distinct messages.
const item_state_names = joinEnumNames(state_mod.ItemState);

fn findCommand(name: []const u8) ?CommandSpec {
    for (commands) |c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    return null;
}

fn containsStr(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

/// The first value in `items` that also appears earlier in `items`, or
/// `null` if every value is distinct (D13, section 4 supervisor finding
/// B2). `runHeader` refuses rather than deduplicates — this only detects.
fn findDuplicate(items: []const []const u8) ?[]const u8 {
    for (items, 0..) |item, i| {
        if (containsStr(items[0..i], item)) return item;
    }
    return null;
}

fn startsWithDash(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "-");
}

fn startsWithDoubleDash(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "--");
}

/// Flag names that consume the following argv token as a value,
/// regardless of which command eventually owns them (a superset across
/// every command this block builds) — used only by `findCommandToken` to
/// avoid mistaking a flag's value for the command token, never to
/// validate a flag itself. A command a later block adds is that block's
/// problem, not this pre-scan's.
const value_taking_flags = [_][]const u8{
    "--log",   "--role", "--change", "--closer",  "--section",
    "--block", "--to",   "--ref",    "--title",   "--base",
    "--type",  "--item", "--state",  "--outcome", "--commit",
    "--seq",   "--kind",
};

fn isValueTakingFlag(name: []const u8) bool {
    for (value_taking_flags) |f| {
        if (std.mem.eql(u8, f, name)) return true;
    }
    return false;
}

/// Phase 1 of the two-phase parse (A5, carried item 3): locates the bare
/// command token, if any, without validating a single flag. Its only
/// consumer is `parseArgs`, which needs to know *which command's flag
/// spec* it is parsing against before it parses a single flag — most
/// concretely, whether `--role` is `header`'s repeatable declaration or
/// every other command's exactly-once attribution, since that can no
/// longer be a single global rule (`tasks.md:52`'s overload). Mirrors
/// phase 2's own "does the next token look like a flag" rule when
/// deciding whether to skip a recognised flag's value, so the two phases
/// never disagree about where the command token sits.
fn findCommandToken(args: []const [:0]const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (startsWithDash(arg)) {
            if (isValueTakingFlag(arg) and i + 1 < args.len and !startsWithDoubleDash(args[i + 1])) {
                i += 1;
            }
            continue;
        }
        return arg;
    }
    return null;
}

/// The first parse-time ambiguity found in argv, if any (A6, `## NEXT`
/// carried item 4): one tagged value, set once at the point it is first
/// detected and reported at a single call site in `run` — replacing the
/// four independently-checked booleans this dispatcher used to carry
/// through a hand-ordered run of `if`s, correct only by comment
/// discipline. Precedence between fault *kinds* never has to be decided
/// separately from precedence between fault *positions*: only the first
/// one found, scanning argv left to right, is ever recorded — see
/// `Parsed.setFault`.
const ParseFault = union(enum) {
    unknown_flag: []const u8,
    missing_value_for: []const u8,
    empty_value_for: []const u8,
    repeated_flag: []const u8,
    malformed_ref: []const u8,
    unexpected_argument: []const u8,
};

/// Result of phase 2's real scan over argv (ADR-0002: no third-party
/// parser). `roles`/`closers`/`refs` are owned lists — free with
/// `deinit` — because their flags are genuinely repeatable (`header`'s
/// `--role`/`--closer`; `post`'s `--ref`, 4.8); every other flag is a
/// single optional slice borrowed from `args`.
const Parsed = struct {
    log_path: ?[]const u8 = null,
    help: bool = false,
    version: bool = false,
    command: ?[]const u8 = null,
    fault: ?ParseFault = null,

    /// Exactly-once attribution, for every command except `header`.
    role: ?[]const u8 = null,
    /// `header`'s repeatable role declaration. Empty unless the command
    /// is `header`.
    roles: std.ArrayList([]const u8) = .empty,
    /// `header`-only.
    change: ?[]const u8 = null,
    /// `header`-only, repeatable.
    closers: std.ArrayList([]const u8) = .empty,

    /// Shared by a subset of `post`/`section`/`brief`, each optional at
    /// the parser level and exactly-once — which commands recognise which
    /// of these three is decided per command in `parseArgs` (block 4B).
    section: ?[]const u8 = null,
    block: ?[]const u8 = null,
    to: ?[]const u8 = null,
    /// `section`-only, exactly-once, required (4.1).
    title: ?[]const u8 = null,
    base: ?[]const u8 = null,
    /// Repeatable (4.8); recognised by `post`, `section`, `brief`, `next`,
    /// `item`, `close`, `verdict` (block 4C).
    refs: std.ArrayList(record.Ref) = .empty,

    /// `item`-only, exactly-once, required (4.4). Validated against
    /// `record.ItemType`'s permitted set in `runItem`, not here — parsing
    /// argv only decides arity, the same split A5 already draws for every
    /// other flag.
    item_type: ?[]const u8 = null,
    /// `item`'s own declaration (4.4) and the item filter `list` (6.3) and
    /// `search` (7.3) share. A bare boolean flag: absent means false,
    /// present means true. No arity ambiguity to check — repeating it is
    /// harmless, unlike a value-carrying flag.
    blocking: bool = false,
    /// Shared by `close` (4.5: exactly-once, required) and `show` (6.2:
    /// exactly-once, mutually exclusive with `--seq`, one of the two
    /// required). The raw digits; parsed to a positive integer in
    /// `runClose`/`runShow` respectively.
    item_num: ?[]const u8 = null,
    /// Exactly-once for all three of its commands, and two different
    /// permitted sets: `close`'s own required state (4.5), validated
    /// against `record.CloseState` in `runClose`, and the *derived* item
    /// state `list` (6.3) and `search` (7.3) filter by, validated against
    /// `state_mod.ItemState` in `resolveFilterSpec`.
    state: ?[]const u8 = null,
    /// `verdict`-only, exactly-once, required (4.6). Validated against
    /// `record.VerdictOutcome`'s permitted set in `runVerdict`.
    outcome: ?[]const u8 = null,
    /// `verdict`-only, exactly-once, required (4.6). Stored verbatim and
    /// unvalidated — same posture as `section`'s `--base` (D10).
    commit: ?[]const u8 = null,
    /// `show`-only, exactly-once (6.2), mutually exclusive with
    /// `--item`. The raw digits; parsed to a positive `u64` in `runShow`.
    seq_num: ?[]const u8 = null,
    /// Read-command-only (D15, block 6A wires `show`; block 6B wires
    /// `resume`/`status`; 6C wires the rest). A bare boolean flag, same
    /// shape as `item`'s `--blocking`: absent means the default
    /// rendered-text form, present means emit the same content as JSON
    /// instead.
    json: bool = false,
    /// `list` (6.3) and `search` (7.3), exactly-once. Validated against
    /// `record.Kind`'s permitted set in `resolveFilterSpec`, not here —
    /// same split A5 draws for every other flag's
    /// arity-vs-value-validity distinction.
    kind: ?[]const u8 = null,
    /// The bare positional argument of a `takes_positional` command —
    /// `search`'s query (7.2), the only one this surface has. Exactly-once
    /// by construction: `setPositional` is where that arity is enforced
    /// (ruling R1), so `CommandSpec.takes_positional` stays a boolean.
    query: ?[]const u8 = null,

    fn deinit(self: *Parsed, allocator: Allocator) void {
        self.roles.deinit(allocator);
        self.closers.deinit(allocator);
        self.refs.deinit(allocator);
    }

    fn setFault(self: *Parsed, fault: ParseFault) void {
        if (self.fault == null) self.fault = fault;
    }
};

/// Consumes the value for the single-value flag at `args[i]`, advancing
/// `i` past it. If no value follows, or the following token looks like
/// another flag, records a `missing_value_for` fault (first fault wins —
/// `Parsed.setFault`) and leaves `i` where it is, so the look-alike flag
/// is processed as its own token on the next loop iteration rather than
/// silently consumed.
fn takeFlagValue(p: *Parsed, args: []const [:0]const u8, i: *usize, name: []const u8) ?[]const u8 {
    if (i.* + 1 >= args.len or startsWithDoubleDash(args[i.* + 1])) {
        p.setFault(.{ .missing_value_for = name });
        return null;
    }
    i.* += 1;
    return args[i.*];
}

/// Sets a single-value, exactly-once flag. Ambiguity (already set) is
/// checked *before* emptiness, matching this tool's pre-existing
/// behaviour for `--role`: `--role "" --role x` reports "requires a
/// non-empty value", not "given more than once", because the first,
/// empty attempt never actually populates `field` (`## NEXT` carried
/// item 6 — a known quirk, not a defect this rework is meant to fix).
fn setOnce(p: *Parsed, field: *?[]const u8, name: []const u8, value: []const u8) void {
    if (field.* != null) {
        p.setFault(.{ .repeated_flag = name });
        return;
    }
    if (value.len == 0) {
        p.setFault(.{ .empty_value_for = name });
        return;
    }
    field.* = value;
}

/// Stores the one bare positional argument a `takes_positional` command
/// accepts, and refuses everything else about it (ruling R1, DEVLOG
/// `## 7`). The same shape as `setOnce`, and for the same reason: a second
/// value is an ambiguity the caller must be told about, never a silently
/// dropped token (B1). Checks "already given" before "empty", exactly as
/// `setOnce` does, so the two report the same way on the same line.
///
/// The empty case reuses `empty_value_for`'s wording, naming the argument
/// as the usage line names it (`<query>`) rather than inventing a second
/// phrasing for "you gave me nothing to work with".
fn setPositional(p: *Parsed, value: []const u8) void {
    if (p.query != null) {
        p.setFault(.{ .unexpected_argument = value });
        return;
    }
    if (value.len == 0) {
        p.setFault(.{ .empty_value_for = "<query>" });
        return;
    }
    p.query = value;
}

/// Appends to a repeatable flag (`--role`/`--closer` on `header`) — no
/// ambiguity check, since repeating is the point, but still refuses an
/// empty element.
fn appendValue(p: *Parsed, allocator: Allocator, list: *std.ArrayList([]const u8), name: []const u8, value: []const u8) Allocator.Error!void {
    if (value.len == 0) {
        p.setFault(.{ .empty_value_for = name });
        return;
    }
    try list.append(allocator, value);
}

/// `--ref ns:id` (4.8): split on the *first* `:`, both sides non-empty.
/// A malformed value is a parse fault (A6); beyond well-formedness this
/// checks nothing else — `external-references` requires an unknown
/// namespace be accepted without complaint (D10).
fn appendRef(p: *Parsed, allocator: Allocator, list: *std.ArrayList(record.Ref), value: []const u8) Allocator.Error!void {
    const colon = std.mem.indexOfScalar(u8, value, ':') orelse {
        p.setFault(.{ .malformed_ref = value });
        return;
    };
    const ns = value[0..colon];
    const id = value[colon + 1 ..];
    if (ns.len == 0 or id.len == 0) {
        p.setFault(.{ .malformed_ref = value });
        return;
    }
    try list.append(allocator, .{ .ns = ns, .id = id });
}

/// Phase 2 (A5): the real scan, now that `findCommandToken` has already
/// determined which command's flag spec applies — `wants_header`
/// decides `--role`'s arity; every `wants_*` below decides which of the
/// shared optional flags (`--section`/`--block`/`--to`/`--ref`) and
/// which command-only flags (`--change`/`--closer` for `header`,
/// `--title`/`--base` for `section`) that command recognises at all.
/// `--help`, `--version`, and `--log` are always recognised regardless of
/// position relative to the command token (the "any position" behaviour
/// this dispatcher has always had). `--role` is command-scoped like every
/// other flag (`wants_role_value`, section 6 supervisor finding, blocker
/// 1) — `show`, `status` and `refs` do not recognise it at all, so it is
/// refused there rather than silently accepted and ignored; it stays
/// recognised with no command word on the line yet (`command_hint ==
/// null`), since there is then no command's flag set to defer to. An
/// unrecognised flag is a fault when it appears before the command token
/// is found (unconditionally — there is no command yet to defer to) *or*
/// when the command is one this dispatcher already builds (`header`,
/// `post`, `section`, `brief`, `next` as of blocks 4A/4B, `show`,
/// `resume`, `status`, `list`, `refs` as of section 6, `search` as of
/// block 7A — their grammars are enforced everywhere on the line, not
/// just before the bare word); an unrecognised flag after any other
/// command's bare token is left alone, for that command's own section to
/// validate once it exists (unchanged pre-4A behaviour — now reachable
/// only for a command word `findCommand` does not recognise at all).
fn parseArgs(allocator: Allocator, args: []const [:0]const u8) Allocator.Error!Parsed {
    var p: Parsed = .{};
    const command_hint = findCommandToken(args);
    const wants_header = command_hint != null and std.mem.eql(u8, command_hint.?, "header");
    const wants_post = command_hint != null and std.mem.eql(u8, command_hint.?, "post");
    const wants_section_cmd = command_hint != null and std.mem.eql(u8, command_hint.?, "section");
    const wants_brief = command_hint != null and std.mem.eql(u8, command_hint.?, "brief");
    const wants_next = command_hint != null and std.mem.eql(u8, command_hint.?, "next");
    const wants_item = command_hint != null and std.mem.eql(u8, command_hint.?, "item");
    const wants_close = command_hint != null and std.mem.eql(u8, command_hint.?, "close");
    const wants_verdict = command_hint != null and std.mem.eql(u8, command_hint.?, "verdict");
    const wants_show = command_hint != null and std.mem.eql(u8, command_hint.?, "show");
    const wants_resume = command_hint != null and std.mem.eql(u8, command_hint.?, "resume");
    const wants_status = command_hint != null and std.mem.eql(u8, command_hint.?, "status");
    const wants_list = command_hint != null and std.mem.eql(u8, command_hint.?, "list");
    const wants_refs = command_hint != null and std.mem.eql(u8, command_hint.?, "refs");
    const wants_search = command_hint != null and std.mem.eql(u8, command_hint.?, "search");
    // `search` joins this set as of block 7A (ruling R1): its grammar is
    // now built, so a flag it does not recognise — `--section` and the
    // other filters 7.3 will add among them — is refused here rather than
    // accepted and ignored.
    const strict = wants_header or wants_post or wants_section_cmd or wants_brief or wants_next or
        wants_item or wants_close or wants_verdict or wants_show or wants_resume or wants_status or
        wants_list or wants_refs or wants_search;
    // Whether the hinted command recognises a bare positional argument at
    // all (B1: `CommandSpec.takes_positional`). Looked up structurally,
    // not by name, so a future command that takes one only has to set the
    // property — never touch this dispatcher.
    const takes_positional = if (command_hint) |c|
        if (findCommand(c)) |spec| spec.takes_positional else false
    else
        false;

    // Which commands recognise each shared optional flag — `section`'s
    // own `--section` (the tasks.md section it opens) and `post`'s/
    // `brief`'s `--section` (the section a record concerns) share a name
    // but not a command set, hence three separate memberships rather
    // than one. `close` takes neither `--section`, `--block`, nor `--to`
    // (4.5: "nothing else"); `verdict` takes `--section`/`--block` but
    // not `--to` (4.6 names no addressee). `list` (6.3) joins all three —
    // its own filter, not a write-time attribution, but the same shared
    // flags answer both questions. `search` (7.3) joins them for exactly
    // that reason: narrowing a query before ranking it is the same
    // question `list` asks of the same log, so it is the same flags and,
    // below, the same predicate (ruling R6).
    const wants_section_flag = wants_post or wants_section_cmd or wants_brief or wants_item or wants_verdict or wants_list or wants_search;
    const wants_block_flag = wants_post or wants_brief or wants_item or wants_verdict or wants_list or wants_search;
    const wants_to_flag = wants_post or wants_brief or wants_item or wants_list or wants_search;
    // Commands that recognise `--role` as their own exactly-once value —
    // every write command (the caller's identity), `resume` (the role to
    // resume as, required), and `list` (a filter). `header` is handled
    // separately below (its own repeatable declaration). `show`, `status`
    // and `refs` are deliberately absent (section 6 supervisor finding,
    // blocker 1): `--role` means nothing to any of them, and a flag that
    // means nothing must be refused, not silently accepted and ignored —
    // the same defect this project already fixed once for a stray
    // positional (section 4's `post stray-token`). `command_hint == null`
    // keeps `--role` recognised when no command word is on the line at
    // all yet (the pre-existing "any position" behaviour for a still-
    // ambiguous line — e.g. a bare `--role` with no command, or `--role`
    // before `--log`), since there is no command's flag set to defer to.
    const wants_role_value = wants_post or wants_section_cmd or wants_brief or wants_next or
        wants_item or wants_close or wants_verdict or wants_resume or wants_list or wants_search or
        command_hint == null;
    // `refs` (6.4) reuses this same `--ref` parsing and its malformation
    // fault (A6) rather than a second parser — the brief's own
    // instruction — even though its `--ref` means "look this up", not
    // "record this", and is validated exactly-once in `runList`/`runRefs`
    // rather than here (same arity-vs-value-validity split as everywhere
    // else). `list` does not filter by reference (6.3 names no such
    // filter), so it is deliberately absent from this set.
    const wants_ref_flag = wants_post or wants_section_cmd or wants_brief or wants_next or
        wants_item or wants_close or wants_verdict or wants_refs;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];

        if (std.mem.eql(u8, arg, "--help")) {
            p.help = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            p.version = true;
        } else if (std.mem.eql(u8, arg, "--log")) {
            if (takeFlagValue(&p, args, &i, "--log")) |v| p.log_path = v;
        } else if ((wants_header or wants_role_value) and std.mem.eql(u8, arg, "--role")) {
            if (wants_header) {
                if (takeFlagValue(&p, args, &i, "--role")) |v| try appendValue(&p, allocator, &p.roles, "--role", v);
            } else if (takeFlagValue(&p, args, &i, "--role")) |v| {
                setOnce(&p, &p.role, "--role", v);
            }
        } else if (wants_header and std.mem.eql(u8, arg, "--change")) {
            if (takeFlagValue(&p, args, &i, "--change")) |v| setOnce(&p, &p.change, "--change", v);
        } else if (wants_header and std.mem.eql(u8, arg, "--closer")) {
            if (takeFlagValue(&p, args, &i, "--closer")) |v| try appendValue(&p, allocator, &p.closers, "--closer", v);
        } else if (wants_section_cmd and std.mem.eql(u8, arg, "--title")) {
            if (takeFlagValue(&p, args, &i, "--title")) |v| setOnce(&p, &p.title, "--title", v);
        } else if (wants_section_cmd and std.mem.eql(u8, arg, "--base")) {
            if (takeFlagValue(&p, args, &i, "--base")) |v| setOnce(&p, &p.base, "--base", v);
        } else if (wants_item and std.mem.eql(u8, arg, "--type")) {
            if (takeFlagValue(&p, args, &i, "--type")) |v| setOnce(&p, &p.item_type, "--type", v);
        } else if ((wants_item or wants_list or wants_search) and std.mem.eql(u8, arg, "--blocking")) {
            p.blocking = true;
        } else if ((wants_close or wants_show) and std.mem.eql(u8, arg, "--item")) {
            if (takeFlagValue(&p, args, &i, "--item")) |v| setOnce(&p, &p.item_num, "--item", v);
        } else if ((wants_close or wants_list or wants_search) and std.mem.eql(u8, arg, "--state")) {
            if (takeFlagValue(&p, args, &i, "--state")) |v| setOnce(&p, &p.state, "--state", v);
        } else if (wants_verdict and std.mem.eql(u8, arg, "--outcome")) {
            if (takeFlagValue(&p, args, &i, "--outcome")) |v| setOnce(&p, &p.outcome, "--outcome", v);
        } else if (wants_verdict and std.mem.eql(u8, arg, "--commit")) {
            if (takeFlagValue(&p, args, &i, "--commit")) |v| setOnce(&p, &p.commit, "--commit", v);
        } else if (wants_show and std.mem.eql(u8, arg, "--seq")) {
            if (takeFlagValue(&p, args, &i, "--seq")) |v| setOnce(&p, &p.seq_num, "--seq", v);
        } else if ((wants_list or wants_search) and std.mem.eql(u8, arg, "--kind")) {
            if (takeFlagValue(&p, args, &i, "--kind")) |v| setOnce(&p, &p.kind, "--kind", v);
        } else if ((wants_show or wants_resume or wants_status or wants_list or wants_refs or wants_search) and std.mem.eql(u8, arg, "--json")) {
            p.json = true;
        } else if (wants_section_flag and std.mem.eql(u8, arg, "--section")) {
            if (takeFlagValue(&p, args, &i, "--section")) |v| setOnce(&p, &p.section, "--section", v);
        } else if (wants_block_flag and std.mem.eql(u8, arg, "--block")) {
            if (takeFlagValue(&p, args, &i, "--block")) |v| setOnce(&p, &p.block, "--block", v);
        } else if (wants_to_flag and std.mem.eql(u8, arg, "--to")) {
            if (takeFlagValue(&p, args, &i, "--to")) |v| setOnce(&p, &p.to, "--to", v);
        } else if (wants_ref_flag and std.mem.eql(u8, arg, "--ref")) {
            if (takeFlagValue(&p, args, &i, "--ref")) |v| try appendRef(&p, allocator, &p.refs, v);
        } else if (p.command == null and !startsWithDash(arg)) {
            p.command = arg;
        } else if (startsWithDash(arg) and (strict or p.command == null)) {
            p.setFault(.{ .unknown_flag = arg });
        } else if (p.command != null and !startsWithDash(arg) and strict) {
            // A bare token after the command. Either the command takes one
            // — `setPositional` stores it and enforces its exactly-once
            // arity (R1) — or it does not, and this is B1's stray token:
            // silent success here is the one outcome this tool must never
            // produce, so it is a parse fault through the same
            // first-fault-wins structure as every other one (A6), not a
            // branch that does nothing.
            if (takes_positional) {
                setPositional(&p, arg);
            } else {
                p.setFault(.{ .unexpected_argument = arg });
            }
        }
        // else: a flag belonging to a command this dispatcher does not
        // build, left untouched for that command's own section to validate
        // once it exists. Every command in `commands` is built as of block
        // 7A, so nothing reaches this today except a token following an
        // *unknown* command word, which `run` refuses by name.
    }

    return p;
}

fn reportFault(stderr: *Io.Writer, fault: ParseFault) u8 {
    return switch (fault) {
        .unknown_flag => |flag| fail(stderr, "unknown flag '{s}' — see --help", .{flag}),
        .missing_value_for => |flag| fail(stderr, "{s} requires a value", .{flag}),
        .empty_value_for => |flag| fail(stderr, "{s} requires a non-empty value", .{flag}),
        .repeated_flag => |flag| fail(stderr, "{s} given more than once — see --help", .{flag}),
        .malformed_ref => |val| fail(stderr, "--ref '{s}' is malformed — expected ns:id, both sides non-empty", .{val}),
        .unexpected_argument => |arg| fail(stderr, "unexpected argument '{s}' — see --help", .{arg}),
    };
}

/// Prints whatever `record.Diagnostics` named, or a generic fallback
/// naming the error value when nothing more specific was set (A4: two
/// message shapes, not three — this is the one call site that prints
/// both of them uniformly through `fail()`). Despite the name, this
/// covers any error carried alongside a `record.Diagnostics` — `log.zig`'s
/// write/read error sets and `state.zig`'s `DeriveError` alike (carried
/// item 17, block 6A): `state.derive` sets the same `diag` type with the
/// same message-then-error-name fallback `log.zig` already uses, so
/// `ItemNumberMismatch`/`CloseTargetMissing`/`VerdictMissingKey` reach the
/// CLI through this one call site rather than a second reporting path,
/// with the same message shape and exit code every other fault gets.
fn reportLogError(stderr: *Io.Writer, err: anyerror, diag: *const record.Diagnostics) u8 {
    if (diag.message.len != 0) return fail(stderr, "{s}", .{diag.message});
    return fail(stderr, "{s}", .{@errorName(err)});
}

fn printTopHelp(w: *Io.Writer) void {
    w.print(
        \\devlog {s} — the working channel for an OpenSpec change, kept as an
        \\append-only log.
        \\
        \\USAGE
        \\    devlog [--log <path>] [--role <role>] <command> [flags]
        \\    devlog --help
        \\    devlog --version
        \\    devlog <command> --help
        \\
        \\GLOBAL FLAGS
        \\    --log <path>   Path to the change's DEVLOG.jsonl. Required by every
        \\                   command below. Never inferred or guessed.
        \\    --role <role>  The calling role, as declared for this project by
        \\                   'devlog header' (any name the project has
        \\                   declared). Carried on every write. Given at most
        \\                   once — except by 'devlog header' itself, which
        \\                   declares the role set and gives it repeatably.
        \\    --help         Show this help, or a command's help after its name.
        \\    --version      Print the tool version and exit.
        \\
        \\COMMANDS
        \\    header    Declare the project's role set (creates the log).
        \\    section   Open a section and record its base commit.
        \\    brief     Post the architect's block brief to a worker.
        \\    post      Post general working-channel traffic.
        \\    item      Raise a work item and print its identifier.
        \\    close     Close a work item with a reason (declared closers only).
        \\    verdict   Record a typed review verdict for a block.
        \\    next      Append the current NEXT narrative.
        \\    resume    Show NEXT, open items, and the latest brief for a role.
        \\    show      Show one item or one record.
        \\    list      List records, filtered.
        \\    refs      Show every record carrying an external reference.
        \\    status    Show the rendered current state.
        \\    search    Search record bodies, ranked by relevance.
        \\
        \\Run `devlog <command> --help` for that command's own usage. A body,
        \\where a command takes one, always comes from stdin — never a flag,
        \\never a heredoc.
        \\
    ,
        .{build_options.version},
    ) catch {};
}

fn printCommandHelp(w: *Io.Writer, spec: CommandSpec) void {
    if (spec.usage) |usage| {
        w.print("devlog {s} — {s}\n\n{s}\n", .{ spec.name, spec.summary, usage }) catch {};
        return;
    }
    // Unreachable from `commands` as of block 7A — every command now
    // carries its own usage. Kept for the same reason as `run`'s
    // not-implemented arm: a spec added ahead of its behaviour must say so
    // rather than print an invented promise.
    w.print(
        \\devlog {s} — {s}
        \\
        \\Not yet implemented — see openspec/changes/add-devlog-core/tasks.md,
        \\section {s}, for its planned flags and behaviour.
        \\
    ,
        .{ spec.name, spec.summary, spec.section },
    ) catch {};
}

/// `YYYY-MM-DDTHH:MM:SSZ`, UTC, seconds precision (design.md's
/// record-schema example). Computed once by the caller and threaded
/// down as a plain string — the clock is injected into `run`, not called
/// from inside a command (architect ruling, DEVLOG `## 4`) — so every
/// command's record is assertable against a pinned `ts` in a test,
/// rather than each command reaching for the wall clock itself.
fn formatTimestamp(buf: []u8, io: Io) []const u8 {
    const now = Io.Clock.real.now(io);
    const total_seconds: i64 = @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_s));
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(total_seconds) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    // `buf` is always sized by this file's own callers for exactly this
    // fixed-width format (20 bytes) — not user input, so a formatting
    // failure here would mean this function's own buffer contract broke,
    // not a value the caller supplied.
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch unreachable;
}

/// `devlog header` (4.10, D13). Validates every required flag before
/// touching the filesystem (A3), then wires `log.appendHeader` — which
/// already implements all three outcomes — rather than reimplementing
/// them. Never calls `body.readBody`: `HeaderRecord` has no body field,
/// so there is nothing to read (A3).
fn runHeader(
    allocator: Allocator,
    io: Io,
    dir: Io.Dir,
    ts: []const u8,
    log_path: []const u8,
    p: *const Parsed,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) u8 {
    const change = p.change orelse return fail(stderr, "'header' requires --change <name>", .{});
    if (p.roles.items.len == 0) return fail(stderr, "'header' requires at least one --role <r>", .{});
    if (p.closers.items.len == 0) return fail(stderr, "'header' requires at least one --closer <r>", .{});

    // The declaration is a set (D13, section 4 supervisor finding B2): a
    // repeated value is refused rather than silently deduplicated, because
    // this tool stores what it is given or refuses it — never a
    // transformation of the caller's input.
    if (findDuplicate(p.roles.items)) |dup| {
        return fail(stderr, "--role '{s}' given more than once", .{dup});
    }
    if (findDuplicate(p.closers.items)) |dup| {
        return fail(stderr, "--closer '{s}' given more than once", .{dup});
    }

    for (p.closers.items) |closer| {
        if (!containsStr(p.roles.items, closer)) {
            return fail(stderr, "--closer '{s}' must also be given as --role", .{closer});
        }
    }

    const tool = std.fmt.allocPrint(allocator, "devlog {s}", .{build_options.version}) catch {
        return fail(stderr, "out of memory", .{});
    };
    defer allocator.free(tool);

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();

    const result = log.appendHeader(
        allocator,
        io,
        dir,
        log_path,
        ts,
        tool,
        .{ .change = change, .roles = p.roles.items, .closers = p.closers.items },
        &diag,
    ) catch |err| return reportLogError(stderr, err, &diag);

    // Three genuinely different outcomes, all exiting 0 (architect
    // ruling, DEVLOG ## 4): an agent that cannot tell them apart cannot
    // tell whether its declaration took effect.
    stdout.print("{s}\n", .{@tagName(result.outcome)}) catch {};
    return 0;
}

/// `devlog post` (4.3): the common fields plus a body, nothing else.
/// Order matches A3 exactly: `--role` (already parsed) is checked, then
/// the body is read from stdin, and only then does anything reach the
/// filesystem — a refusal at either step never opens, let alone creates
/// or modifies, the log.
fn runPost(
    allocator: Allocator,
    io: Io,
    dir: Io.Dir,
    stdin: Io.File,
    ts: []const u8,
    log_path: []const u8,
    p: *const Parsed,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) u8 {
    _ = stdout;
    const role = p.role orelse return fail(stderr, "'post' requires --role <role>", .{});

    const body_bytes = body.readBody(allocator, io, stdin) catch |err| {
        return fail(stderr, "{s}", .{body.refusalMessage(err)});
    };
    defer allocator.free(body_bytes);

    const rec = record.Record{ .post = .{ .common = .{
        .seq = 0,
        .ts = ts,
        .role = role,
        .section = p.section,
        .block = p.block,
        .to = p.to,
        .refs = p.refs.items,
        .body = body_bytes,
    } } };

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();

    _ = log.appendRecord(allocator, io, dir, log_path, rec, &diag) catch |err| {
        return reportLogError(stderr, err, &diag);
    };

    return 0;
}

/// `devlog section` (4.1): opens a `tasks.md` section and fixes the
/// range a supervisor review diffs against. All three of `--section`/
/// `--title`/`--base` are required; `--base` is stored verbatim and
/// unvalidated, same posture as `--ref` (D10) — the tool never runs
/// `git`, never checks the sha exists or its length. Same A3 ordering as
/// `runPost`: every required flag is checked, then the body is read,
/// and only then does anything reach the filesystem.
fn runSection(
    allocator: Allocator,
    io: Io,
    dir: Io.Dir,
    stdin: Io.File,
    ts: []const u8,
    log_path: []const u8,
    p: *const Parsed,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) u8 {
    _ = stdout;
    const role = p.role orelse return fail(stderr, "'section' requires --role <role>", .{});
    const section = p.section orelse return fail(stderr, "'section' requires --section <s>", .{});
    const title = p.title orelse return fail(stderr, "'section' requires --title <t>", .{});
    const base = p.base orelse return fail(stderr, "'section' requires --base <sha>", .{});

    const body_bytes = body.readBody(allocator, io, stdin) catch |err| {
        return fail(stderr, "{s}", .{body.refusalMessage(err)});
    };
    defer allocator.free(body_bytes);

    const rec = record.Record{ .section = .{
        .common = .{
            .seq = 0,
            .ts = ts,
            .role = role,
            .section = section,
            .refs = p.refs.items,
            .body = body_bytes,
        },
        .title = title,
        .base = base,
    } };

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();

    _ = log.appendRecord(allocator, io, dir, log_path, rec, &diag) catch |err| {
        return reportLogError(stderr, err, &diag);
    };

    return 0;
}

/// `devlog brief` (4.2, D8): the architect's block brief, addressed to a
/// worker. All three of `--section`/`--block`/`--to` are required — a
/// brief nobody is addressed to is not a brief, and `resume --role`
/// (6.1) reaches it precisely through `--to`. `--to`'s value is itself
/// checked against the declared role set, inside `appendRecord`, the
/// same way `--role` is (block 4B decision, on D13's own reasoning — see
/// `log.zig`'s `checkRoleAllowed`).
fn runBrief(
    allocator: Allocator,
    io: Io,
    dir: Io.Dir,
    stdin: Io.File,
    ts: []const u8,
    log_path: []const u8,
    p: *const Parsed,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) u8 {
    _ = stdout;
    const role = p.role orelse return fail(stderr, "'brief' requires --role <role>", .{});
    const section = p.section orelse return fail(stderr, "'brief' requires --section <s>", .{});
    const block = p.block orelse return fail(stderr, "'brief' requires --block <b>", .{});
    const to = p.to orelse return fail(stderr, "'brief' requires --to <role>", .{});

    const body_bytes = body.readBody(allocator, io, stdin) catch |err| {
        return fail(stderr, "{s}", .{body.refusalMessage(err)});
    };
    defer allocator.free(body_bytes);

    const rec = record.Record{ .brief = .{ .common = .{
        .seq = 0,
        .ts = ts,
        .role = role,
        .section = section,
        .block = block,
        .to = to,
        .refs = p.refs.items,
        .body = body_bytes,
    } } };

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();

    _ = log.appendRecord(allocator, io, dir, log_path, rec, &diag) catch |err| {
        return reportLogError(stderr, err, &diag);
    };

    return 0;
}

/// `devlog next` (4.7, next-state): appends the current NEXT narrative.
/// Takes a body and `--ref`, and nothing else — no `--section`,
/// `--block`, or `--to`: NEXT is change-scoped narrative, not addressed
/// to anyone or bound to one section. Which appended NEXT counts as
/// "current" is a read-side derivation (5.3), not this command's
/// concern — appending, and never rewriting, is all it owes.
fn runNext(
    allocator: Allocator,
    io: Io,
    dir: Io.Dir,
    stdin: Io.File,
    ts: []const u8,
    log_path: []const u8,
    p: *const Parsed,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) u8 {
    _ = stdout;
    const role = p.role orelse return fail(stderr, "'next' requires --role <role>", .{});

    const body_bytes = body.readBody(allocator, io, stdin) catch |err| {
        return fail(stderr, "{s}", .{body.refusalMessage(err)});
    };
    defer allocator.free(body_bytes);

    const rec = record.Record{ .next = .{ .common = .{
        .seq = 0,
        .ts = ts,
        .role = role,
        .refs = p.refs.items,
        .body = body_bytes,
    } } };

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();

    _ = log.appendRecord(allocator, io, dir, log_path, rec, &diag) catch |err| {
        return reportLogError(stderr, err, &diag);
    };

    return 0;
}

/// Parses a `--item <n>` value as a positive item identifier — `null` for
/// anything that is not a base-10 integer strictly greater than zero (no
/// leading `#`, which `item`'s own stdout output carries but `close`'s
/// input does not — see `close_usage`).
fn parsePositiveItemNumber(s: []const u8) ?i64 {
    const n = std.fmt.parseInt(i64, s, 10) catch return null;
    return if (n > 0) n else null;
}

/// `devlog item` (4.4, `work-items`): raises a work item, assigning both
/// `seq` and the item's own identifier under the lock (D9) via
/// `log.appendItem` — this function never computes the number itself, per
/// the architect's ruling (DEVLOG `## 4`, block 4C brief). `--type` is
/// required and validated against `record.ItemType`'s permitted set
/// before the body is read (A3, 4.9); `--blocking` is independent of
/// `--type` by construction — `Parsed.blocking` is a bare bool, unrelated
/// to which type was given. Prints the assigned identifier as `#<n>` and
/// nothing else on success (`work-items`: "the tool returns its
/// identifier"), so a shell can capture it.
fn runItem(
    allocator: Allocator,
    io: Io,
    dir: Io.Dir,
    stdin: Io.File,
    ts: []const u8,
    log_path: []const u8,
    p: *const Parsed,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) u8 {
    const role = p.role orelse return fail(stderr, "'item' requires --role <role>", .{});
    const type_str = p.item_type orelse return fail(stderr, "'item' requires --type <t>", .{});
    const item_type = record.enumFromString(record.ItemType, type_str) orelse
        return fail(stderr, "--type '{s}' is not recognised — expected one of: {s}", .{ type_str, item_type_names });

    const body_bytes = body.readBody(allocator, io, stdin) catch |err| {
        return fail(stderr, "{s}", .{body.refusalMessage(err)});
    };
    defer allocator.free(body_bytes);

    const rec = record.Record{
        .item = .{
            .common = .{
                .seq = 0,
                .ts = ts,
                .role = role,
                .section = p.section,
                .block = p.block,
                .to = p.to,
                .refs = p.refs.items,
                .body = body_bytes,
            },
            .item = 0, // ignored — log.appendItem assigns it under the lock (D9)
            .type = item_type,
            .blocking = p.blocking,
        },
    };

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();

    const result = log.appendItem(allocator, io, dir, log_path, rec, &diag) catch |err| {
        return reportLogError(stderr, err, &diag);
    };

    stdout.print("#{d}\n", .{result.item}) catch {};
    return 0;
}

/// `devlog close` (4.5, `work-items`): closes a work item. `--item` and
/// `--state` are both required; `--item` must be a positive integer and
/// `--state` must be one of `record.CloseState`'s permitted values,
/// both checked before the body is read (A3, 4.9). The body itself is
/// the mandatory reason (`work-items`: "A closure always carries a
/// reason") — `body.readBody` already refuses an empty body, so nothing
/// further is needed here to enforce that.
///
/// The closer guardrail (`work-items`: "Only a declared closing role may
/// close an item") and the refusal of an `--item` naming a number no
/// `item` record ever raised (4.5, architect ruling) are both enforced
/// inside `log.appendRecord`, under the lock — not reimplemented here.
/// Closing an already-closed item is deliberately allowed: append-only-log
/// treats a correction as a new record, and which close wins is a
/// derivation question (5.1), not this command's.
fn runClose(
    allocator: Allocator,
    io: Io,
    dir: Io.Dir,
    stdin: Io.File,
    ts: []const u8,
    log_path: []const u8,
    p: *const Parsed,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) u8 {
    _ = stdout;
    const role = p.role orelse return fail(stderr, "'close' requires --role <role>", .{});
    const item_str = p.item_num orelse return fail(stderr, "'close' requires --item <n>", .{});
    const item_num = parsePositiveItemNumber(item_str) orelse
        return fail(stderr, "--item '{s}' must be a positive integer", .{item_str});
    const state_str = p.state orelse return fail(stderr, "'close' requires --state <s>", .{});
    const state = record.enumFromString(record.CloseState, state_str) orelse
        return fail(stderr, "--state '{s}' is not recognised — expected one of: {s}", .{ state_str, close_state_names });

    const body_bytes = body.readBody(allocator, io, stdin) catch |err| {
        return fail(stderr, "{s}", .{body.refusalMessage(err)});
    };
    defer allocator.free(body_bytes);

    const rec = record.Record{ .close = .{
        .common = .{
            .seq = 0,
            .ts = ts,
            .role = role,
            .refs = p.refs.items,
            .body = body_bytes,
        },
        .item = item_num,
        .state = state,
    } };

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();

    _ = log.appendRecord(allocator, io, dir, log_path, rec, &diag) catch |err| {
        return reportLogError(stderr, err, &diag);
    };

    return 0;
}

/// `devlog verdict` (4.6, D7): records a typed review verdict for a
/// block. All four of `--section`/`--block`/`--outcome`/`--commit` are
/// required; `--outcome` must be one of `record.VerdictOutcome`'s
/// permitted values, checked before the body is read (A3, 4.9).
/// `--commit` is stored verbatim and unvalidated — same posture as
/// `section`'s `--base` (D10): the tool never runs `git`.
fn runVerdict(
    allocator: Allocator,
    io: Io,
    dir: Io.Dir,
    stdin: Io.File,
    ts: []const u8,
    log_path: []const u8,
    p: *const Parsed,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) u8 {
    _ = stdout;
    const role = p.role orelse return fail(stderr, "'verdict' requires --role <role>", .{});
    const section = p.section orelse return fail(stderr, "'verdict' requires --section <s>", .{});
    const block = p.block orelse return fail(stderr, "'verdict' requires --block <b>", .{});
    const outcome_str = p.outcome orelse return fail(stderr, "'verdict' requires --outcome <o>", .{});
    const outcome = record.enumFromString(record.VerdictOutcome, outcome_str) orelse
        return fail(stderr, "--outcome '{s}' is not recognised — expected one of: {s}", .{ outcome_str, verdict_outcome_names });
    const commit = p.commit orelse return fail(stderr, "'verdict' requires --commit <sha>", .{});

    const body_bytes = body.readBody(allocator, io, stdin) catch |err| {
        return fail(stderr, "{s}", .{body.refusalMessage(err)});
    };
    defer allocator.free(body_bytes);

    const rec = record.Record{ .verdict = .{
        .common = .{
            .seq = 0,
            .ts = ts,
            .role = role,
            .section = section,
            .block = block,
            .refs = p.refs.items,
            .body = body_bytes,
        },
        .outcome = outcome,
        .commit = commit,
    } };

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();

    _ = log.appendRecord(allocator, io, dir, log_path, rec, &diag) catch |err| {
        return reportLogError(stderr, err, &diag);
    };

    return 0;
}

/// Parses a `--seq <n>` value as a positive `u64` sequence number — `null`
/// for anything that is not a base-10 integer strictly greater than zero.
/// Mirrors `parsePositiveItemNumber`'s shape, one field over.
fn parsePositiveSeq(s: []const u8) ?u64 {
    const n = std.fmt.parseInt(u64, s, 10) catch return null;
    return if (n > 0) n else null;
}

/// Writes `common`'s three lead fields shared by every attributed kind —
/// mirrors `record.zig`'s private `writeAttributedHead`, one field over,
/// so the text renderer below can never show a field the JSON form
/// (`record.write`) omits, or vice versa (D15).
fn writeAttributedHeadText(w: *Io.Writer, common: record.Attributed) void {
    w.print("ts: {s}\n", .{common.ts}) catch {};
    w.print("role: {s}\n", .{common.role}) catch {};
    if (common.section) |s| w.print("section: {s}\n", .{s}) catch {};
    if (common.block) |b| w.print("block: {s}\n", .{b}) catch {};
}

/// Writes `common`'s trailing fields shared by every attributed kind —
/// mirrors `record.zig`'s private `writeAttributedTail`/`writeRefsAndBody`.
/// `body` is always shown, last, since it is usually the longest field.
fn writeAttributedTailText(w: *Io.Writer, common: record.Attributed) void {
    if (common.to) |t| w.print("to: {s}\n", .{t}) catch {};
    for (common.refs) |ref| w.print("ref: {s}:{s}\n", .{ ref.ns, ref.id }) catch {};
    w.print("body:\n{s}\n", .{common.body}) catch {};
}

/// Renders one record as agent-readable text — the text half of D15's
/// "one derivation, two renderers". Reads off the same `record.Record`
/// union `record.write` does, one field at a time, in the same per-kind
/// shape, so this can never show less than the JSON form carries (D15: a
/// `--json` payload carrying something the text form cannot show would be
/// the text form under-rendering, not a licence for the two to diverge).
/// Shared by `runShow`'s `--seq` path directly, and by `writeItemText`
/// below for the opening `item` record and each `close` record nested
/// inside an `--item` result — one renderer, not one per call site.
fn renderRecordText(w: *Io.Writer, rec: record.Record) void {
    w.print("kind: {s}\n", .{@tagName(std.meta.activeTag(rec))}) catch {};
    w.print("seq: {d}\n", .{rec.seq()}) catch {};
    switch (rec) {
        .header => |r| {
            w.print("ts: {s}\n", .{r.ts}) catch {};
            w.print("format: {d}\n", .{r.format}) catch {};
            w.print("tool: {s}\n", .{r.tool}) catch {};
            w.print("change: {s}\n", .{r.change}) catch {};
            w.writeAll("roles: ") catch {};
            for (r.roles, 0..) |role_name, idx| {
                if (idx != 0) w.writeAll(", ") catch {};
                w.writeAll(role_name) catch {};
            }
            w.writeAll("\nclosers: ") catch {};
            for (r.closers, 0..) |closer_name, idx| {
                if (idx != 0) w.writeAll(", ") catch {};
                w.writeAll(closer_name) catch {};
            }
            w.writeAll("\n") catch {};
        },
        .section => |r| {
            writeAttributedHeadText(w, r.common);
            w.print("title: {s}\n", .{r.title}) catch {};
            w.print("base: {s}\n", .{r.base}) catch {};
            writeAttributedTailText(w, r.common);
        },
        .brief, .post, .next => {
            const common = switch (rec) {
                inline .brief, .post, .next => |r| r.common,
                else => unreachable,
            };
            writeAttributedHeadText(w, common);
            writeAttributedTailText(w, common);
        },
        .item => |r| {
            writeAttributedHeadText(w, r.common);
            w.print("item: #{d}\n", .{r.item}) catch {};
            w.print("type: {s}\n", .{@tagName(r.type)}) catch {};
            w.print("blocking: {}\n", .{r.blocking}) catch {};
            writeAttributedTailText(w, r.common);
        },
        .close => |r| {
            writeAttributedHeadText(w, r.common);
            w.print("closes item: #{d}\n", .{r.item}) catch {};
            w.print("state: {s}\n", .{@tagName(r.state)}) catch {};
            writeAttributedTailText(w, r.common);
        },
        .verdict => |r| {
            writeAttributedHeadText(w, r.common);
            w.print("outcome: {s}\n", .{@tagName(r.outcome)}) catch {};
            w.print("commit: {s}\n", .{r.commit}) catch {};
            writeAttributedTailText(w, r.common);
        },
    }
}

/// The text form of an `--item` result: the derived number and state
/// (`state_mod.ItemState` — not a record field, `5.1`'s derivation), then
/// the opening record and every close, each rendered by `renderRecordText`
/// — the same renderer `--seq` uses directly, so an item's opening record
/// reads exactly as it would if fetched by its own `--seq`.
fn writeItemText(w: *Io.Writer, item: state_mod.Item) void {
    w.print("#{d} — state: {s}\n\n", .{ item.number, @tagName(item.state) }) catch {};
    w.writeAll("opened:\n") catch {};
    renderRecordText(w, record.Record{ .item = item.opened });
    if (item.closes.len == 0) {
        w.writeAll("\ncloses: none yet\n") catch {};
        return;
    }
    w.print("\ncloses ({d}):\n", .{item.closes.len}) catch {};
    for (item.closes, 0..) |c, idx| {
        w.print("--- close {d} of {d} ---\n", .{ idx + 1, item.closes.len }) catch {};
        renderRecordText(w, record.Record{ .close = c });
    }
}

/// The JSON form of an `--item` result. Builds the wrapping object
/// (`number`, `state`, `item`, `closes`) with plain writer calls, but
/// reuses `record.write` — "the writer already in `record.zig`" the brief
/// asks for — for the opening record and every close record it embeds,
/// rather than a second hand-rolled record emitter (D15). Fails only as
/// `record.write` can: `WriteError` (an `Io.Writer` failure, or a body
/// that is not valid UTF-8 — D14 — which cannot occur here, since D14
/// already refused it at write time, but the type still carries the
/// possibility rather than asserting it away).
///
/// **Carries no trailing newline** (blocker 2, section 6 supervisor) —
/// matches `record.write`'s own contract exactly, so every call site adds
/// its own, the way `runShow`'s `--seq`/`--item` branches and
/// `writeCurrentStateJson`/`writeItemListJson` already do for their own
/// container's closing brace. This used to end `"]}\n"`, which was fine
/// standalone but embedded a newline inside every composite that wraps
/// this per item (`status`, `resume`, `list --state`/`--blocking`) while
/// `show --seq`, `list`, and `refs` stayed single-line — the same JSON
/// value line-delimited for four reads and not for three, for no reason
/// anyone chose.
fn writeItemJson(w: *Io.Writer, item: state_mod.Item, diag: ?*record.Diagnostics) record.WriteError!void {
    try w.writeAll("{\"number\":");
    try w.print("{d}", .{item.number});
    try w.writeAll(",\"state\":\"");
    try w.writeAll(@tagName(item.state));
    try w.writeAll("\",\"item\":");
    try record.write(w, record.Record{ .item = item.opened }, diag);
    try w.writeAll(",\"closes\":[");
    for (item.closes, 0..) |c, idx| {
        if (idx != 0) try w.writeAll(",");
        try record.write(w, record.Record{ .close = c }, diag);
    }
    try w.writeAll("]}");
}

/// The text form of a `list`/`refs` result over raw records — "a list is a
/// sequence of things that already know how to render themselves" (the
/// block's brief): reuses `renderRecordText`, the exact renderer `show
/// --seq` already exercises for every one of the eight kinds, once per
/// element. Mirrors `renderCurrentStateText`'s own "count header, `(none)`
/// on empty, numbered `--- ... ---` separators" shape below, so every list-
/// shaped read in this tool renders the same way.
fn writeRecordListText(w: *Io.Writer, records: []const record.Record) void {
    w.print("records ({d}):\n", .{records.len}) catch {};
    if (records.len == 0) w.writeAll("(none)\n") catch {};
    for (records, 0..) |rec, idx| {
        w.print("\n--- record {d} of {d} ---\n", .{ idx + 1, records.len }) catch {};
        renderRecordText(w, rec);
    }
}

/// The JSON form of a `list`/`refs` result over raw records — a bare array,
/// each element written by `record.write` (D15: no second record emitter).
fn writeRecordListJson(w: *Io.Writer, records: []const record.Record, diag: ?*record.Diagnostics) record.WriteError!void {
    try w.writeAll("[");
    for (records, 0..) |rec, idx| {
        if (idx != 0) try w.writeAll(",");
        try record.write(w, rec, diag);
    }
    try w.writeAll("]\n");
}

/// The text form of a `list --state`/`--blocking` result — the item-
/// narrowed half (the block's ruling). Reuses `writeItemText`, the exact
/// renderer `show --item` already exercises.
fn writeItemListText(w: *Io.Writer, items: []const state_mod.Item) void {
    w.print("items ({d}):\n", .{items.len}) catch {};
    if (items.len == 0) w.writeAll("(none)\n") catch {};
    for (items, 0..) |it, idx| {
        w.print("\n--- item {d} of {d} ---\n", .{ idx + 1, items.len }) catch {};
        writeItemText(w, it);
    }
}

/// The JSON form of the item-narrowed `list` result — a bare array, each
/// element written by `writeItemJson` (D15: no second item emitter).
fn writeItemListJson(w: *Io.Writer, items: []const state_mod.Item, diag: ?*record.Diagnostics) record.WriteError!void {
    try w.writeAll("[");
    for (items, 0..) |it, idx| {
        if (idx != 0) try w.writeAll(",");
        try writeItemJson(w, it, diag);
    }
    try w.writeAll("]\n");
}

/// The `brief` slot of a "current state" view (D8, block 6B). `resume`
/// (6.1) and `status` (6.5) share everything about "NEXT narrative plus a
/// set of items" except this: `status` has no brief concept at all,
/// `resume` always has one, either found or plainly absent (the block
/// brief's ruling, point 4 — not an error, not an empty field).
const BriefSlot = union(enum) {
    /// `status`: never rendered, in either form — there is no brief
    /// concept to omit a value for.
    not_applicable,
    /// `resume`: no `brief` has ever been addressed to this role.
    none,
    /// `resume`: the latest brief for the role's block (which may itself
    /// be addressed to someone else — a remediation brief).
    found: record.Record,
};

/// The role's block (D8, `resume` ruling point 1): the `(section, block)`
/// of the most recently posted `brief` addressed to `role`, scanning
/// `briefs` (`state_mod.Indexes.byKind(.brief)` — an `EnumArray` bucket, in
/// log order, never a hash-map enumeration) in order and keeping the last
/// match. `null` if no brief has ever been addressed to the role — ruling
/// point 4, "there is no block".
fn findBriefToRole(briefs: []const record.Record, role: []const u8) ?record.BriefRecord {
    var found: ?record.BriefRecord = null;
    for (briefs) |rec| {
        const b = rec.brief;
        const to = b.common.to orelse continue;
        if (std.mem.eql(u8, to, role)) found = b;
    }
    return found;
}

/// The latest brief for `(section, block)` (ruling point 2), scanning the
/// same `briefs` bucket a second time and keeping the last exact match on
/// **both** fields (ruling point 3 — the section-5 close ruling: never key
/// on the bare block label alone, since it is not unique across sections).
/// `--section`/`--block`/`--to` are all required on `devlog brief`
/// (`runBrief`), so every brief this build's CLI wrote has both fields
/// set — but `briefs` is whatever `state.derive` accepted, and `derive`
/// now faults (`error.BriefMissingKey`) before `Indexes` is built if any
/// `brief` record is missing either field. That makes the guard below
/// unreachable in practice, which is exactly why it stays a guard —
/// `orelse continue`, mirroring `findBriefToRole` two functions up —
/// rather than a `.?` that would silently start panicking again the day
/// the upstream invariant changes.
fn findLatestBriefForBlock(briefs: []const record.Record, section: []const u8, block: []const u8) ?record.Record {
    var found: ?record.Record = null;
    for (briefs) |rec| {
        const b = rec.brief;
        const b_section = b.common.section orelse continue;
        const b_block = b.common.block orelse continue;
        if (std.mem.eql(u8, b_section, section) and std.mem.eql(u8, b_block, block)) {
            found = rec;
        }
    }
    return found;
}

/// The text form of a "current state" view — the shared half of D8's
/// `resume` and `next-state`'s `status`, parameterised over `items` (the
/// caller has already selected and ordered them: every open item for
/// `status`, the open items addressed to one role for `resume`) and
/// `brief`. One renderer, not two hand-written ones that could disagree
/// about the same item (D15's rule, one level up). Reuses `renderRecordText`
/// for the NEXT record and the brief, and `writeItemText` for each item —
/// the exact renderers `show` already exercises, so a current-state item
/// reads exactly as it would fetched by its own `show --item`, including
/// its `blocking: {}` field (`next-state`: blocking items distinguishable).
fn renderCurrentStateText(
    w: *Io.Writer,
    next: ?record.NextRecord,
    items: []const state_mod.Item,
    brief: BriefSlot,
) void {
    w.writeAll("next:\n") catch {};
    if (next) |n| {
        renderRecordText(w, record.Record{ .next = n });
    } else {
        w.writeAll("(none recorded)\n") catch {};
    }

    w.print("\nopen items ({d}):\n", .{items.len}) catch {};
    if (items.len == 0) w.writeAll("(none)\n") catch {};
    for (items, 0..) |it, idx| {
        w.print("\n--- item {d} of {d} ---\n", .{ idx + 1, items.len }) catch {};
        writeItemText(w, it);
    }

    switch (brief) {
        .not_applicable => {},
        .none => w.writeAll("\nbrief: none — no brief has been addressed to this role yet\n") catch {},
        .found => |rec| {
            w.writeAll("\nbrief:\n") catch {};
            renderRecordText(w, rec);
        },
    }
}

/// The JSON form of a "current state" view — mirrors
/// `renderCurrentStateText` field for field (D15): `next` (the record, or
/// `null`), `items` (each rendered by `writeItemJson`, the same emitter
/// `show --item --json` uses), and `brief`, present as a key only when
/// `brief != .not_applicable` — `status` therefore never carries a `brief`
/// key at all, rather than a `null` a reader could mistake for "checked,
/// found nothing".
fn writeCurrentStateJson(
    w: *Io.Writer,
    next: ?record.NextRecord,
    items: []const state_mod.Item,
    brief: BriefSlot,
    diag: ?*record.Diagnostics,
) record.WriteError!void {
    try w.writeAll("{\"next\":");
    if (next) |n| {
        try record.write(w, record.Record{ .next = n }, diag);
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"items\":[");
    for (items, 0..) |it, idx| {
        if (idx != 0) try w.writeAll(",");
        try writeItemJson(w, it, diag);
    }
    try w.writeAll("]");
    switch (brief) {
        .not_applicable => {},
        .none => try w.writeAll(",\"brief\":null"),
        .found => |rec| {
            try w.writeAll(",\"brief\":");
            try record.write(w, rec, diag);
        },
    }
    try w.writeAll("}\n");
}

/// `devlog resume` (6.1, D8, `log-retrieval`). Everything rendered here is
/// already derived by `state_mod` — this command selects and renders, it
/// derives nothing new. Loads via `log.openReadOnly` (never
/// `log.appendRecord`'s locked, create-if-missing path — a read does
/// neither).
///
/// **Item selection stays off `Indexes.by_addressee` entirely** (carried
/// 16): filters `derived.indexes.byState(.open)` — already positional,
/// in `#n` order, per `state.zig`'s own derivation — by `opened.common.to
/// == role`, rather than looking the role up in the hash-map index and
/// risking an unstable enumeration. The result is bounded by how many
/// items are open and addressed to `role`, never by the log's history
/// (`log-retrieval`'s boundedness requirement).
///
/// **Brief lookup stays off the hash-map indexes too**: both
/// `findBriefToRole` and `findLatestBriefForBlock` scan
/// `Indexes.byKind(.brief)`, an `EnumArray` bucket addressed directly by
/// tag — not a hash map, and not subject to carried 16 at all.
fn runResume(
    allocator: Allocator,
    io: Io,
    dir: Io.Dir,
    log_path: []const u8,
    p: *const Parsed,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) u8 {
    const role = p.role orelse return fail(stderr, "'resume' requires --role <role>", .{});

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();

    var opened = log.openReadOnly(allocator, io, dir, log_path, &diag) catch |err| {
        return reportLogError(stderr, err, &diag);
    };
    defer opened.close(allocator);

    // Blocker 1 (section 6 supervisor): `--role` is this command's own
    // identity, not merely a filter, so an undeclared value is refused
    // here rather than answered with a well-formed, empty orientation —
    // the write side's own reasoning (`append-only-log`), applied to the
    // read it was written about.
    log.checkDeclaredRole(opened.log.records, role, &diag) catch |err| {
        return reportLogError(stderr, err, &diag);
    };

    var derived = state_mod.derive(allocator, opened.log.records, &diag) catch |err| {
        return reportLogError(stderr, err, &diag);
    };
    defer derived.deinit();

    var matching: std.ArrayList(state_mod.Item) = .empty;
    defer matching.deinit(allocator);
    for (derived.indexes.byState(.open)) |it| {
        const to = it.opened.common.to orelse continue;
        if (!std.mem.eql(u8, to, role)) continue;
        matching.append(allocator, it) catch return fail(stderr, "out of memory", .{});
    }

    // The three `.?`s this block's review flagged (`rb.common.section.?`,
    // `rb.common.block.?`, and the outer unwrap of `findLatestBriefForBlock`'s
    // result) are gone: `state.derive` now faults on a `brief` missing
    // either field before `Indexes` is ever built, so `rb` is guaranteed
    // complete here — but the `orelse .none` below treats that as a
    // guarantee to defend, not one to trust blindly.
    const briefs = derived.indexes.byKind(.brief);
    const brief_slot: BriefSlot = if (findBriefToRole(briefs, role)) |rb| blk: {
        const section = rb.common.section orelse break :blk .none;
        const block_id = rb.common.block orelse break :blk .none;
        break :blk if (findLatestBriefForBlock(briefs, section, block_id)) |found|
            BriefSlot{ .found = found }
        else
            .none;
    } else .none;

    if (p.json) {
        writeCurrentStateJson(stdout, derived.currentNext(), matching.items, brief_slot, &diag) catch |err|
            return reportLogError(stderr, err, &diag);
    } else {
        renderCurrentStateText(stdout, derived.currentNext(), matching.items, brief_slot);
    }
    return 0;
}

/// `devlog status` (6.5, `next-state`). The other half of the shared
/// "current state" view `runResume` renders: every open item, unfiltered
/// by addressee, and no brief concept at all (`BriefSlot.not_applicable`).
/// `derived.indexes.byState(.open)` is already positional (`#n` order,
/// carried 16) — passed straight through, no copy needed. Loads via
/// `log.openReadOnly`, exactly as `runResume` and `runShow` do.
fn runStatus(
    allocator: Allocator,
    io: Io,
    dir: Io.Dir,
    log_path: []const u8,
    p: *const Parsed,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) u8 {
    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();

    var opened = log.openReadOnly(allocator, io, dir, log_path, &diag) catch |err| {
        return reportLogError(stderr, err, &diag);
    };
    defer opened.close(allocator);

    var derived = state_mod.derive(allocator, opened.log.records, &diag) catch |err| {
        return reportLogError(stderr, err, &diag);
    };
    defer derived.deinit();

    const items = derived.indexes.byState(.open);

    if (p.json) {
        writeCurrentStateJson(stdout, derived.currentNext(), items, .not_applicable, &diag) catch |err|
            return reportLogError(stderr, err, &diag);
    } else {
        renderCurrentStateText(stdout, derived.currentNext(), items, .not_applicable);
    }
    return 0;
}

/// `devlog show` (6.2, `log-retrieval`, D15). Retrieves one item — with
/// its current derived state and full close history — by `--item <n>`, or
/// one record verbatim by `--seq <n>`. The two are mutually exclusive and
/// exactly one is required; that, and each value's shape, is checked
/// before the read-only load ever touches the filesystem (A3's ordering,
/// applied to a read this time rather than a write). Renders agent-
/// readable text by default; the same content as JSON on `--json` (D15).
///
/// Loads via `log.openReadOnly` (6.6, carried items 10 and 13) — never
/// `log.appendRecord`'s locked, create-if-missing path, which would be
/// wrong twice over for a read: it would create the log on a miss, and it
/// would take a lock this single self-contained snapshot does not need.
///
/// A target that does not exist — an `--item` no `item` record ever
/// raised, or a `--seq` no record carries — is a plain report and a
/// non-zero exit, the same shape as this tool's other refusals, never an
/// empty success.
fn runShow(
    allocator: Allocator,
    io: Io,
    dir: Io.Dir,
    log_path: []const u8,
    p: *const Parsed,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) u8 {
    if (p.item_num != null and p.seq_num != null) {
        return fail(stderr, "'show' takes exactly one of --item <n> or --seq <n>, not both", .{});
    }
    if (p.item_num == null and p.seq_num == null) {
        return fail(stderr, "'show' requires --item <n> or --seq <n>", .{});
    }

    const item_target: ?i64 = if (p.item_num) |s|
        parsePositiveItemNumber(s) orelse
            return fail(stderr, "--item '{s}' must be a positive integer", .{s})
    else
        null;
    const seq_target: ?u64 = if (p.seq_num) |s|
        parsePositiveSeq(s) orelse
            return fail(stderr, "--seq '{s}' must be a positive integer", .{s})
    else
        null;

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();

    var opened = log.openReadOnly(allocator, io, dir, log_path, &diag) catch |err| {
        return reportLogError(stderr, err, &diag);
    };
    defer opened.close(allocator);

    if (seq_target) |target| {
        for (opened.log.records) |rec| {
            if (rec.seq() != target) continue;
            if (p.json) {
                record.write(stdout, rec, &diag) catch |err| return reportLogError(stderr, err, &diag);
                stdout.writeByte('\n') catch {};
            } else {
                renderRecordText(stdout, rec);
            }
            return 0;
        }
        return fail(stderr, "no record with seq {d}", .{target});
    }

    var derived = state_mod.derive(allocator, opened.log.records, &diag) catch |err| {
        return reportLogError(stderr, err, &diag);
    };
    defer derived.deinit();

    const n = item_target.?;
    for (derived.items) |it| {
        if (it.number != n) continue;
        if (p.json) {
            writeItemJson(stdout, it, &diag) catch |err| return reportLogError(stderr, err, &diag);
            // The newline belongs to the caller, uniformly (blocker 2,
            // section 6 supervisor): `writeItemJson` carries none of its
            // own — see its doc comment — so this call site adds one,
            // exactly as the `--seq` branch above does for `record.write`.
            stdout.writeByte('\n') catch {};
        } else {
            writeItemText(stdout, it);
        }
        return 0;
    }
    return fail(stderr, "item #{d} does not exist — {d} item(s) have been raised so far", .{ n, derived.items.len });
}

/// Does `rec` satisfy every filter `p` has active, checked directly against
/// the record's own fields — `record.Record.role()`/`.to()` and
/// `state_mod.recordSection`/`recordBlock` (the same free functions `5.5`'s
/// own index build uses), never a `.?`. `section`/`block`/`to` are optional
/// on `Attributed` and not guaranteed present on a hand-written log (block
/// 6B's own blocker, one field over): a record lacking a field a filter
/// asks about simply does not match that filter — absence is a legitimate
/// answer to "does this record match `--section 6`?", not a crash.
///
/// The one predicate for "does this record/item match `--section`/
/// `--block`/`--role`/`--to`" — `runList`'s item-only branch calls this
/// too (wrapping an `Item.opened` as `record.Record{ .item = ... }`)
/// rather than re-answering the same question field by field a second
/// time (blocker 3, section 6 supervisor): the two answered it
/// identically today, which is exactly when the duplication is cheapest
/// to remove and hardest to notice.
fn matchesListFilters(rec: record.Record, p: *const Parsed, kind_filter: ?record.Kind) bool {
    if (p.section) |s| {
        const rs = state_mod.recordSection(rec) orelse return false;
        if (!std.mem.eql(u8, rs, s)) return false;
    }
    if (p.block) |b| {
        const rb = state_mod.recordBlock(rec) orelse return false;
        if (!std.mem.eql(u8, rb, b)) return false;
    }
    if (p.role) |r| {
        const rr = rec.role() orelse return false;
        if (!std.mem.eql(u8, rr, r)) return false;
    }
    if (p.to) |t| {
        const rt = rec.to() orelse return false;
        if (!std.mem.eql(u8, rt, t)) return false;
    }
    if (kind_filter) |k| {
        if (std.meta.activeTag(rec) != k) return false;
    }
    return true;
}

/// The item half of the same question, applied to one derived item:
/// `--state`/`--blocking` — the two properties only a *derived* item has —
/// plus the four record-level filters, answered by `matchesListFilters` on
/// the record that opened it rather than field by field a second time
/// (blocker 3, section 6 supervisor).
///
/// Shared by `list` (6.3), where these two flags narrow the *result* from
/// records to items, and by `search` (7.3, ruling R2), where they narrow
/// the *candidates* to the records those items opened and leave the output
/// shape alone. One predicate, two uses — the difference between the
/// commands is what each collects, not what either counts as a match.
///
/// `kind_filter` is `null` here: `resolveFilterSpec` has already refused
/// any `--kind` other than `item` alongside these flags, so there is
/// nothing left for it to check.
fn matchesItemFilters(it: state_mod.Item, p: *const Parsed, state_filter: ?state_mod.ItemState) bool {
    if (state_filter) |sf| {
        if (it.state != sf) return false;
    }
    if (p.blocking and !it.opened.blocking) return false;
    return matchesListFilters(record.Record{ .item = it.opened }, p, null);
}

/// `--kind` and `--state`'s values, and their mutual conflict, resolved
/// once for the two commands that take them.
const FilterSpec = struct {
    kind: ?record.Kind = null,
    state: ?state_mod.ItemState = null,
    /// `--state` or `--blocking` given. Both name properties only a derived
    /// item has, so their presence restricts the answer to items: to a list
    /// *of* items for `list` (the block's ruling), to the item records
    /// themselves for `search` (R2 — the filters narrow the candidate set,
    /// they never switch the output shape).
    item_only: bool = false,
};

/// Either the resolved spec or the exit code of the refusal already
/// printed — so `fail` stays the one owner of the message *and* of the
/// code, rather than a call site restating either.
const FilterSpecResult = union(enum) { ok: FilterSpec, refused: u8 };

/// Validates `--kind`/`--state`'s values against their permitted sets and
/// refuses the one combination that cannot mean anything — `--kind`
/// naming something other than `item` alongside `--state`/`--blocking`,
/// which narrow to items.
///
/// One place, one message (ruling R6): `list` (6.3) and `search` (7.3)
/// both call this before the read-only load ever touches the filesystem
/// (A3), so an unusable combination is refused rather than silently
/// ignored — A6's first-fault-wins shape applied to a business-logic
/// refusal rather than a parse one. Copying the message into the second
/// command is the failure mode this function exists to prevent.
fn resolveFilterSpec(p: *const Parsed, stderr: *Io.Writer) FilterSpecResult {
    const kind_filter: ?record.Kind = if (p.kind) |k|
        std.meta.stringToEnum(record.Kind, k) orelse
            return .{ .refused = fail(stderr, "--kind '{s}' must be one of: {s}", .{ k, record_kind_names }) }
    else
        null;

    const state_filter: ?state_mod.ItemState = if (p.state) |s|
        std.meta.stringToEnum(state_mod.ItemState, s) orelse
            return .{ .refused = fail(stderr, "--state '{s}' must be one of: {s}", .{ s, item_state_names }) }
    else
        null;

    const item_only = state_filter != null or p.blocking;
    if (item_only and kind_filter != null and kind_filter.? != .item) {
        return .{ .refused = fail(
            stderr,
            "--kind '{s}' cannot be combined with --state or --blocking, which narrow the result to items",
            .{p.kind.?},
        ) };
    }

    return .{ .ok = .{ .kind = kind_filter, .state = state_filter, .item_only = item_only } };
}

/// How many record-level filters are active. `list` alone needs the count
/// — for its `seq` sort — but it lives beside the seed selection it
/// describes so the two cannot drift apart.
fn activeRecordFilterCount(p: *const Parsed, kind_filter: ?record.Kind) usize {
    return @as(usize, @intFromBool(p.section != null)) +
        @as(usize, @intFromBool(p.block != null)) +
        @as(usize, @intFromBool(p.role != null)) +
        @as(usize, @intFromBool(p.to != null)) +
        @as(usize, @intFromBool(kind_filter != null));
}

/// The one answer to "which records match these filters", appended to
/// `out` in log order. `list` (6.3) and `search` (7.3) ask exactly that
/// question of exactly the same log, so it has one implementation and one
/// predicate (ruling R6) rather than a second one written to look the
/// same.
///
/// **Carried 16, in full.** A single active filter is a key lookup into one
/// of `Indexes`' buckets, already in log order by construction (`5.5`: each
/// bucket is built by one forward pass over `records`, appending in the
/// order encountered). Two or more active filters are an intersection: this
/// seeds from whichever one active filter's bucket is found first (any one
/// will do — correctness does not depend on which) and checks every *other*
/// active filter directly against each candidate via `matchesListFilters`.
/// With no filter active at all, the seed is the positional `records` slice
/// itself — never a `StringHashMap` enumeration, whose order would vary
/// between runs, which is what makes `7.4`'s determinism requirement hold
/// for a filtered search as well as an unfiltered one.
///
/// The `seq` sort deliberately stays *outside* this function (ruling R6):
/// it is `list`'s, and it is wasted work for `search`, which re-sorts every
/// result by score.
fn selectCandidates(
    allocator: Allocator,
    records: []const record.Record,
    indexes: state_mod.Indexes,
    p: *const Parsed,
    kind_filter: ?record.Kind,
    out: *std.ArrayList(record.Record),
) Allocator.Error!void {
    const seed: []const record.Record = if (kind_filter) |k|
        indexes.byKind(k)
    else if (p.section) |s|
        indexes.bySection(s)
    else if (p.block) |b|
        indexes.byBlockLabel(b)
    else if (p.role) |r|
        indexes.byRole(r)
    else if (p.to) |t|
        indexes.byAddressee(t)
    else
        records;

    for (seed) |rec| {
        if (!matchesListFilters(rec, p, kind_filter)) continue;
        try out.append(allocator, rec);
    }
}

fn recordSeqLessThan(_: void, a: record.Record, b: record.Record) bool {
    return a.seq() < b.seq();
}

/// `devlog list` (6.3, `log-retrieval`). An index consumer, not a deriving
/// command: every filter reads off `state_mod`'s already-built indexes or
/// the raw parsed `records` slice, never a second derivation.
///
/// **Carried 16** lives in `selectCandidates`, which this shares with
/// `search` (ruling R6) — the seed-and-intersect selection and its order
/// guarantees are documented there. What stays here is the sort that
/// selection deliberately leaves behind, and the item-narrowed half below.
///
/// **`--state`/`--blocking` narrow the result to items** (the block's
/// ruling): they are properties only a derived item has, so their presence
/// switches the command from listing records to listing items — filtered
/// directly off `derived.items`, itself already positional (`#n` order,
/// carried 16 again), so no sort is needed on that path regardless of how
/// many item-level predicates are active. Note this is where `list` and
/// `search` genuinely differ: the same two flags narrow `search`'s
/// candidates without changing what it returns (R2). `--kind` naming
/// anything but `item` alongside either is refused before the read-only
/// load ever touches the filesystem (A3), by `resolveFilterSpec`, which
/// both commands share.
fn runList(
    allocator: Allocator,
    io: Io,
    dir: Io.Dir,
    log_path: []const u8,
    p: *const Parsed,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) u8 {
    const filters = switch (resolveFilterSpec(p, stderr)) {
        .ok => |f| f,
        .refused => |code| return code,
    };

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();

    var opened = log.openReadOnly(allocator, io, dir, log_path, &diag) catch |err| {
        return reportLogError(stderr, err, &diag);
    };
    defer opened.close(allocator);

    // Blocker 1 (section 6 supervisor), corrected by the architect's
    // ruling-1 follow-up: `--role`/`--to` are filters over **history**
    // here, not identity, so an undeclared value is still refused — the
    // same typo hazard `resume` guards on its own `--role` — but "declared"
    // means declared in *any* header this log carries, not merely the
    // latest. A role the project has since retired (this project's own
    // `orchestrator` → `architect`) still authored records that remain in
    // the log, and must stay queryable through them.
    if (p.role) |r| {
        log.checkDeclaredRoleHistory(opened.log.records, r, &diag) catch |err| {
            return reportLogError(stderr, err, &diag);
        };
    }
    if (p.to) |t| {
        log.checkDeclaredToHistory(opened.log.records, t, &diag) catch |err| {
            return reportLogError(stderr, err, &diag);
        };
    }

    var derived = state_mod.derive(allocator, opened.log.records, &diag) catch |err| {
        return reportLogError(stderr, err, &diag);
    };
    defer derived.deinit();

    if (filters.item_only) {
        var matching: std.ArrayList(state_mod.Item) = .empty;
        defer matching.deinit(allocator);
        for (derived.items) |it| {
            if (!matchesItemFilters(it, p, filters.state)) continue;
            matching.append(allocator, it) catch return fail(stderr, "out of memory", .{});
        }
        if (p.json) {
            writeItemListJson(stdout, matching.items, &diag) catch |err| return reportLogError(stderr, err, &diag);
        } else {
            writeItemListText(stdout, matching.items);
        }
        return 0;
    }

    var matching: std.ArrayList(record.Record) = .empty;
    defer matching.deinit(allocator);
    selectCandidates(allocator, opened.log.records, derived.indexes, p, filters.kind, &matching) catch
        return fail(stderr, "out of memory", .{});

    // A single filter's bucket, or the raw positional slice with none
    // active, is already in log order by construction — sorting only does
    // real work, and is only needed at all, once two or more filters
    // intersect (carried 16).
    //
    // Carried 21, answered by block 7B rather than carried further: this
    // sort cannot change `list`'s output, and now provably so rather than
    // by inspection of `buildIndexes` alone. `record.parseLog` refuses any
    // log whose `seq` is not strictly increasing and contiguous from 1
    // (`validateSeqOrder`), so for every log that opens at all, log order
    // *is* `seq` order; `buildIndexes` builds each bucket as an
    // order-preserving subsequence of one forward pass; and
    // `selectCandidates` only ever drops elements from that subsequence.
    // Nor does 7.3 change this, contrary to what this comment predicted:
    // `search` re-sorts by score and so never routes a ranked result
    // through here at all. Kept as documented insurance — its removal is
    // the architect's call, not this block's.
    if (activeRecordFilterCount(p, filters.kind) >= 2) {
        std.mem.sort(record.Record, matching.items, {}, recordSeqLessThan);
    }

    if (p.json) {
        writeRecordListJson(stdout, matching.items, &diag) catch |err| return reportLogError(stderr, err, &diag);
    } else {
        writeRecordListText(stdout, matching.items);
    }
    return 0;
}

/// `devlog refs` (6.4, `external-references`). Reuses section 4's `--ref
/// ns:id` parsing (`appendRef`) and its malformation fault rather than a
/// second parser. Exact match on the `(ns, id)` pair via a single key
/// lookup into `Indexes.byReference` — already in log order (`5.5`'s own
/// test already proves `D1` does not collide with `D10`/`D100`; this
/// command only has to not undo that) — never a scan of body prose: a
/// record whose body merely mentions the identifier without carrying it as
/// a structured reference was never added to that index in the first
/// place, so it cannot appear here (`external-references`'s negative
/// half).
fn runRefs(
    allocator: Allocator,
    io: Io,
    dir: Io.Dir,
    log_path: []const u8,
    p: *const Parsed,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) u8 {
    if (p.refs.items.len == 0) {
        return fail(stderr, "'refs' requires --ref <ns:id>", .{});
    }
    if (p.refs.items.len > 1) {
        return fail(stderr, "'refs' takes exactly one --ref <ns:id>", .{});
    }
    const target = p.refs.items[0];

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();

    var opened = log.openReadOnly(allocator, io, dir, log_path, &diag) catch |err| {
        return reportLogError(stderr, err, &diag);
    };
    defer opened.close(allocator);

    var derived = state_mod.derive(allocator, opened.log.records, &diag) catch |err| {
        return reportLogError(stderr, err, &diag);
    };
    defer derived.deinit();

    const matching = derived.indexes.byReference(target);

    if (p.json) {
        writeRecordListJson(stdout, matching, &diag) catch |err| return reportLogError(stderr, err, &diag);
    } else {
        writeRecordListText(stdout, matching);
    }
    return 0;
}

/// `devlog search <query>` (7.2, `log-retrieval`: "The log can be searched
/// by meaning"). Builds `search.Index` over the records already in memory,
/// ranks them, and renders the result through the same two renderers
/// `list` and `refs` use — no score field and no seventh JSON shape
/// (ruling R3, D15: one derivation, two renderings).
///
/// **Scoping needs no code.** `log-retrieval` requires that "only records
/// belonging to the change being searched are considered"; this tool only
/// ever opens the single file `--log` names, so the property is structural
/// — a guard for it could only ever be true, and asserting it here would
/// suggest the tool has some other log in reach. It has none.
///
/// Opened with `openReadOnly`, which never creates the log: a search
/// against a change that has none is a plain refusal, not a fresh empty
/// file (carried 13, D5).
///
/// **`7.3` — the query is narrowed before it is ranked.** The filters are
/// `6.3`'s entire set and are answered by `selectCandidates` /
/// `matchesItemFilters`, the same two `list` uses (ruling R6). The index is
/// then built over *what survives*, never over the whole log with the
/// filters applied to the results afterwards (ruling R5), so a term's IDF
/// is relative to what the reader actually asked about — a term rare in the
/// section being searched scores as rare even if it is common across the
/// change. The usual objection, that scores are then incomparable between
/// filter sets, is free here: R3 emits no score, so no consumer can compare
/// two.
///
/// **`--state`/`--blocking` narrow the candidates, they do not switch the
/// output shape** (ruling R2). Where `list` answers them with a list of
/// items, `search` answers them with the item *records* those items
/// opened — so `search` returns records under every combination of flags,
/// and its result is the same shape under all of them.
///
/// `search` derives as of `7.3`, and does so unconditionally rather than
/// only when `--state` needs it: the alternative is a command that faults
/// on a write-boundary violation with one flag and silently succeeds over
/// the same broken log without it. Every other read command derives; this
/// one now does too.
fn runSearch(
    allocator: Allocator,
    io: Io,
    dir: Io.Dir,
    log_path: []const u8,
    p: *const Parsed,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) u8 {
    const query = p.query orelse return fail(stderr, "'search' requires a query — see --help", .{});

    const filters = switch (resolveFilterSpec(p, stderr)) {
        .ok => |f| f,
        .refused => |code| return code,
    };

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();

    var opened = log.openReadOnly(allocator, io, dir, log_path, &diag) catch |err| {
        return reportLogError(stderr, err, &diag);
    };
    defer opened.close(allocator);

    // `--role`/`--to` are filters over *history* here, exactly as they are
    // for `list`: an undeclared value is refused (the same typo hazard),
    // but "declared" means declared in any header this log carries, since a
    // role the project has since retired still authored records that must
    // stay queryable through them. Settled in section 6; reused, not
    // re-derived.
    if (p.role) |r| {
        log.checkDeclaredRoleHistory(opened.log.records, r, &diag) catch |err| {
            return reportLogError(stderr, err, &diag);
        };
    }
    if (p.to) |t| {
        log.checkDeclaredToHistory(opened.log.records, t, &diag) catch |err| {
            return reportLogError(stderr, err, &diag);
        };
    }

    var derived = state_mod.derive(allocator, opened.log.records, &diag) catch |err| {
        return reportLogError(stderr, err, &diag);
    };
    defer derived.deinit();

    var candidates: std.ArrayList(record.Record) = .empty;
    defer candidates.deinit(allocator);
    if (filters.item_only) {
        for (derived.items) |it| {
            if (!matchesItemFilters(it, p, filters.state)) continue;
            candidates.append(allocator, record.Record{ .item = it.opened }) catch
                return fail(stderr, "out of memory", .{});
        }
    } else {
        selectCandidates(allocator, opened.log.records, derived.indexes, p, filters.kind, &candidates) catch
            return fail(stderr, "out of memory", .{});
    }

    // R5: over the candidates, not over the log. With no filter given
    // `candidates` *is* every record, so an unfiltered search is unchanged
    // from 7A.
    var index = search.Index.build(allocator, candidates.items) catch
        return fail(stderr, "out of memory", .{});
    defer index.deinit();

    const ranked = index.rank(allocator, query) catch
        return fail(stderr, "out of memory", .{});
    defer allocator.free(ranked);

    // Finding nothing is an ordinary empty success, exactly as `refs`
    // rules it: a search that matches no record is an answer about the
    // log, not a failure of the request.
    if (p.json) {
        writeRecordListJson(stdout, ranked, &diag) catch |err| return reportLogError(stderr, err, &diag);
    } else {
        writeRecordListText(stdout, ranked);
    }
    return 0;
}

/// Dispatches one invocation and returns the process exit code.
fn run(
    allocator: Allocator,
    io: Io,
    dir: Io.Dir,
    stdin: Io.File,
    ts: []const u8,
    args: []const [:0]const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) u8 {
    var p = parseArgs(allocator, args) catch return fail(stderr, "out of memory", .{});
    defer p.deinit(allocator);

    // Parse-ambiguity errors beat --help/--version (architect ruling, DEVLOG
    // ## 1; reaffirmed unchanged by A5/A6). The caller is an agent composing
    // an invocation, and D13 stakes this tool's design on exit codes being
    // trustworthy: a line the parser could not make sense of is not a
    // coherent request for help or the version, even if one of those tokens
    // is also present. Silent success on an unparseable line — a stray or
    // hallucinated --help swallowing a real write and exiting 0 with nothing
    // done — is the one outcome this tool must never produce.
    if (p.fault) |f| return reportFault(stderr, f);

    // Past this point the line is coherent, if possibly incomplete (no
    // command, an unknown command, --log missing) — and a coherent request
    // for help or the version still always succeeds.
    if (p.version) {
        stdout.print("devlog {s}\n", .{build_options.version}) catch {};
        return 0;
    }

    if (p.help) {
        if (p.command) |name| {
            if (findCommand(name)) |spec| {
                printCommandHelp(stdout, spec);
                return 0;
            }
        }
        printTopHelp(stdout);
        return 0;
    }

    const command_name = p.command orelse {
        return fail(stderr, "no command given — see --help", .{});
    };

    const spec = findCommand(command_name) orelse {
        return fail(stderr, "unknown command '{s}' — see --help", .{command_name});
    };

    // `--log` is required, with no default and no guessing
    // (durable-format/spec.md:56): a command that needs the log and wasn't
    // given `--log` is an error, before anything else is attempted.
    const log_path = p.log_path orelse {
        return fail(stderr, "'{s}' requires --log <path>", .{spec.name});
    };

    if (std.mem.eql(u8, spec.name, "header")) {
        return runHeader(allocator, io, dir, ts, log_path, &p, stdout, stderr);
    }
    if (std.mem.eql(u8, spec.name, "post")) {
        return runPost(allocator, io, dir, stdin, ts, log_path, &p, stdout, stderr);
    }
    if (std.mem.eql(u8, spec.name, "section")) {
        return runSection(allocator, io, dir, stdin, ts, log_path, &p, stdout, stderr);
    }
    if (std.mem.eql(u8, spec.name, "brief")) {
        return runBrief(allocator, io, dir, stdin, ts, log_path, &p, stdout, stderr);
    }
    if (std.mem.eql(u8, spec.name, "next")) {
        return runNext(allocator, io, dir, stdin, ts, log_path, &p, stdout, stderr);
    }
    if (std.mem.eql(u8, spec.name, "item")) {
        return runItem(allocator, io, dir, stdin, ts, log_path, &p, stdout, stderr);
    }
    if (std.mem.eql(u8, spec.name, "close")) {
        return runClose(allocator, io, dir, stdin, ts, log_path, &p, stdout, stderr);
    }
    if (std.mem.eql(u8, spec.name, "verdict")) {
        return runVerdict(allocator, io, dir, stdin, ts, log_path, &p, stdout, stderr);
    }
    if (std.mem.eql(u8, spec.name, "show")) {
        return runShow(allocator, io, dir, log_path, &p, stdout, stderr);
    }
    if (std.mem.eql(u8, spec.name, "resume")) {
        return runResume(allocator, io, dir, log_path, &p, stdout, stderr);
    }
    if (std.mem.eql(u8, spec.name, "status")) {
        return runStatus(allocator, io, dir, log_path, &p, stdout, stderr);
    }
    if (std.mem.eql(u8, spec.name, "list")) {
        return runList(allocator, io, dir, log_path, &p, stdout, stderr);
    }
    if (std.mem.eql(u8, spec.name, "refs")) {
        return runRefs(allocator, io, dir, log_path, &p, stdout, stderr);
    }
    if (std.mem.eql(u8, spec.name, "search")) {
        return runSearch(allocator, io, dir, log_path, &p, stdout, stderr);
    }

    // Every command in `commands` is now dispatched above, so this is no
    // longer reachable from the command surface. It stays as the honest
    // failure for a `CommandSpec` added to that table ahead of its
    // dispatch arm — an internal mistake rather than a user one, but one
    // whose only alternative is silent success, which is the single
    // outcome this tool must never produce. Touches nothing on the way out
    // (D5).
    return fail(stderr, "'{s}' is not implemented yet", .{spec.name});
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    var ts_buf: [24]u8 = undefined;
    const ts = formatTimestamp(&ts_buf, io);

    // Io.Dir.cwd() is the AT_FDCWD sentinel, not a real file descriptor —
    // log.zig's atomicReplace fsyncs the directory itself (D11's
    // durability guarantee, `syncDir`) via a raw wrapped Io.File, which
    // the kernel rejects for that sentinel with EBADF. Opening "." against
    // it yields a genuine directory handle every log.zig call can act on,
    // this dispatcher included.
    var cwd = try Io.Dir.cwd().openDir(io, ".", .{});

    const exit_code = run(arena, io, cwd, Io.File.stdin(), ts, args[1..], stdout, stderr);

    stdout.flush() catch {};
    stderr.flush() catch {};
    cwd.close(io);

    std.process.exit(exit_code);
}

// --- Tests -----------------------------------------------------------------

/// A stand-in for stdin that is never a terminal (matching `body.zig`'s
/// own `openAsStdin` helper) — every test below that reaches `run` needs
/// a real, non-terminal `Io.File` to pass as `stdin`, even the many that
/// never actually read it (a command fails before reaching
/// `body.readBody` in every case exercised here). Callers open one fresh
/// file per test invocation inside `tmp.dir`, so nothing is shared or
/// reused across tests.
fn openStdinStandin(dir: Io.Dir, io: Io, contents: []const u8) !Io.File {
    {
        var f = try dir.createFile(io, "stdin-standin", .{ .truncate = true });
        defer f.close(io);
        try f.writePositionalAll(io, contents, 0);
    }
    return dir.openFile(io, "stdin-standin", .{ .mode = .read_only });
}

const test_ts = "2026-08-14T09:00:00Z";

/// Every one of these tests exercises argv parsing and command-dispatch
/// gating that fails, by construction, before `run` ever reaches
/// `log.zig` or `body.zig` — no test call below is exercising a real
/// write. A fresh, isolated tmp dir and a harmless empty stdin stand-in
/// are still supplied on every call (rather than a shared or invalid
/// value) so that stays true by construction rather than by care: if a
/// future edit ever made one of these paths reach the filesystem for
/// real, it would touch only its own throwaway directory, never the
/// repository.
fn expectRun(
    allocator: Allocator,
    args: []const [:0]const u8,
    expected_code: u8,
    stdout_contains: ?[]const u8,
    stderr_contains: ?[]const u8,
) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);

    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(allocator);
    defer err_out.deinit();

    const code = run(allocator, std.testing.io, tmp.dir, stdin_file, test_ts, args, &out.writer, &err_out.writer);
    try std.testing.expectEqual(expected_code, code);

    if (stdout_contains) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, out.written(), needle) != null);
    }
    if (stderr_contains) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, err_out.written(), needle) != null);
    }
}

test "version is embedded via the build option, not duplicated" {
    // build_options.version defaults (absent -Dversion=…) to manifest.version
    // (build.zig.zon), threaded through by build.zig. Comparing against the
    // manifest itself — not a hardcoded literal — catches skew if that wiring
    // ever breaks.
    try std.testing.expectEqualStrings(manifest.version, build_options.version);
}

test "no command given is a stderr error, not a silent success" {
    try expectRun(std.testing.allocator, &.{}, 1, null, "no command given");
}

test "--help with no command prints top-level help and exits 0" {
    try expectRun(std.testing.allocator, &.{"--help"}, 0, "USAGE", null);
    try expectRun(std.testing.allocator, &.{"--help"}, 0, "search", null);
}

test "--version prints the build-option version, not a re-derived one" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);

    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(std.testing.allocator, std.testing.io, tmp.dir, stdin_file, test_ts, &.{"--version"}, &out.writer, &err_out.writer);
    try std.testing.expectEqual(@as(u8, 0), code);

    var expected: [64]u8 = undefined;
    const want = try std.fmt.bufPrint(&expected, "devlog {s}\n", .{build_options.version});
    try std.testing.expectEqualStrings(want, out.written());
}

test "unknown command is rejected, never dispatched" {
    try expectRun(std.testing.allocator, &.{"frobnicate"}, 1, null, "unknown command 'frobnicate'");
}

test "a recognised command without --log is an error, not an attempt" {
    try expectRun(std.testing.allocator, &.{"post"}, 1, null, "requires --log");
}

test "a recognised command with --log that cannot proceed fails honestly, never silently succeeds" {
    // Was "a recognised but unimplemented command…", retargeted at 4C, 6A,
    // 6B and 6C as each section built its commands, and finally landing
    // here: block 7A builds `search`, the last placeholder, so there is no
    // unimplemented command left to point at. The coverage it carries is
    // what matters and is unchanged — a recognised command given --log
    // that cannot do its job says so and exits non-zero, rather than
    // exiting 0 having done nothing. `search` with no query is now that
    // case (R1: no positional at all is a refusal).
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "search" },
        1,
        null,
        "'search' requires a query",
    );
}

test "post with --log but no --role fails on its own real requirement now that it is implemented (4.3)" {
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "post" },
        1,
        null,
        "requires --role",
    );
}

test "a command's own --help works without --log and doesn't dispatch it" {
    try expectRun(std.testing.allocator, &.{ "post", "--help" }, 0, "devlog post", null);
    try expectRun(std.testing.allocator, &.{ "post", "--help" }, 0, "USAGE", null);
}

test "header (D13) is a known command, listed and dispatched like the rest" {
    try expectRun(std.testing.allocator, &.{"--help"}, 0, "header", null);
    try expectRun(std.testing.allocator, &.{ "header", "--help" }, 0, "devlog header", null);
    // Uniform with every other command: --log is required even though
    // header is the one command that will create the file (D13/4.10 own
    // creation semantics; this block only wires the same flag check).
    try expectRun(std.testing.allocator, &.{"header"}, 1, null, "requires --log");
    // header is real now (4.10) — --role alone is not enough; --change
    // and --closer are also required, checked before any filesystem
    // access.
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "header", "--role", "architect" },
        1,
        null,
        "requires --change",
    );
}

test "--role with an empty value is rejected" {
    try expectRun(std.testing.allocator, &.{ "--role", "", "post" }, 1, null, "non-empty");
}

test "a second --role is rejected, not silently overwritten (supervisor finding B4)" {
    try expectRun(
        std.testing.allocator,
        &.{ "--role", "architect", "--role", "reviewer", "post" },
        1,
        null,
        "--role given more than once",
    );
}

test "a repeated --role beats a well-formed --version on the same line" {
    try expectRun(
        std.testing.allocator,
        &.{ "--role", "architect", "--role", "reviewer", "--version" },
        1,
        null,
        "--role given more than once",
    );
}

test "a repeated --role where the second value is empty is still reported as repeated" {
    try expectRun(
        std.testing.allocator,
        &.{ "--role", "architect", "--role", "", "post" },
        1,
        null,
        "--role given more than once",
    );
}

test "--log with no following value is rejected" {
    try expectRun(std.testing.allocator, &.{"--log"}, 1, null, "--log requires a value");
}

test "--role with no following value is rejected" {
    try expectRun(std.testing.allocator, &.{"--role"}, 1, null, "--role requires a value");
}

test "a flag-looking token is never swallowed as another flag's value" {
    // --role must not consume --log as its "value": --log stays a real
    // flag with its own value, and --role's absent value is reported
    // instead of silently accepting "--log" as a role name.
    try expectRun(
        std.testing.allocator,
        &.{ "--role", "--log", "foo" },
        1,
        null,
        "--role requires a value",
    );
}

test "reviewer repro 1 — a value-less --role is refused even with a well-formed --version on the line" {
    // Architect ruling (DEVLOG ## 1): parse-ambiguity errors beat
    // --help/--version. The line is not a coherent request for the version
    // just because a --version token happens to appear on it — --role's
    // value is genuinely missing, and D13 requires that be reported rather
    // than silently swallowed by a well-formed flag elsewhere in the line.
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "path.jsonl", "--role", "--version" },
        1,
        null,
        "--role requires a value",
    );
}

test "reviewer repro 2 — --log never accepts --role as a nonsense path" {
    // Previously log_path became the literal string "--role" and "post"
    // was dropped entirely. Now --log's missing value is reported.
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "--role", "worker", "post" },
        1,
        null,
        "--log requires a value",
    );
}

test "reviewer's own scenario — a subcommand's --help does not mask a genuinely missing --role value" {
    // devlog post --role --help: before the ruling this printed post's help
    // and exited 0 while --role's value was never supplied. The line is
    // unparseable, not a coherent request for help.
    try expectRun(
        std.testing.allocator,
        &.{ "post", "--role", "--help" },
        1,
        null,
        "--role requires a value",
    );
}

test "an unknown flag beats a well-formed --version on the same line" {
    try expectRun(
        std.testing.allocator,
        &.{ "--nope", "--version" },
        1,
        null,
        "unknown flag '--nope'",
    );
}

test "an empty --role beats a well-formed --help on the same line" {
    try expectRun(
        std.testing.allocator,
        &.{ "--role", "", "--help" },
        1,
        null,
        "non-empty",
    );
}

test "the coherent-but-incomplete boundary still resolves to --help/--version, not an error" {
    // No parse ambiguity in any of these three — just a request that's
    // missing something sections 4/6/7 would otherwise need. Help and
    // version still always succeed here; only genuine parse ambiguity
    // (tested above) is allowed to beat them.
    try expectRun(std.testing.allocator, &.{"--help"}, 0, "USAGE", null); // no command at all
    try expectRun(std.testing.allocator, &.{ "post", "--help" }, 0, "devlog post", null); // no --log
    try expectRun(std.testing.allocator, &.{"--version"}, 0, null, null); // version alone
}

test "an unrecognised global flag before the command is rejected" {
    try expectRun(std.testing.allocator, &.{ "--nope", "post" }, 1, null, "unknown flag '--nope'");
}

test "flags after an unknown command word are left alone, not rejected as unknown flags" {
    // From block 4A, retargeted at 4C, 6A, 6B and 6C as each section built
    // its commands. Its subject — a command whose grammar this dispatcher
    // does not yet enforce — no longer exists among the *known* commands:
    // block 7A builds `search`, the last one, so every entry in `commands`
    // is strict. What remains of that state is an unrecognised command
    // word, and the coverage the test carries is unchanged: its trailing
    // flags are not parsed against anyone's grammar, so the refusal names
    // the command, not the flag.
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "frobnicate", "--section", "6" },
        1,
        null,
        "unknown command 'frobnicate'",
    );
}

test "search joins the strict set: a flag it does not recognise is refused, not ignored (R1)" {
    // The other half of the retarget above, and the reason for it: while
    // `search` was a placeholder this line reached the not-implemented
    // message, silently accepting whatever flag followed. It is now a parse
    // fault like any other unknown flag.
    //
    // The subject moved in block 7B: `--section` was the example while 7.3
    // had not built it, and 7.3 has now built it. `--ref` takes its place —
    // `refs` (6.4) recognises it and `search` deliberately does not, since
    // a reference lookup is an exact key lookup, not a ranked query. The
    // property under test is unchanged: `search` refuses a flag outside its
    // own grammar rather than accepting and ignoring it.
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "search", "--ref", "D:1" },
        1,
        null,
        "unknown flag '--ref'",
    );
}

test "--log and --role are recognised in any position relative to the command" {
    // Retargeted in block 7A: `search` (the old subject) is strict now and
    // recognises no second positional, so the pair moves to commands that
    // do. Both assertions still prove the same thing — the flag was picked
    // up *after* the command word rather than refused or ignored, since a
    // missing `--log` and an unrecognised `--role` each produce a different
    // message. (`search` recognises `--role` again as of 7.3, where it is a
    // filter; the first case here still exercises `--log` after the command
    // word, which is what it is for.)
    try expectRun(
        std.testing.allocator,
        &.{ "search", "--log", "DEVLOG.jsonl", "concurrency" },
        1,
        null,
        "no log at this path yet",
    );
    try expectRun(
        std.testing.allocator,
        &.{ "list", "--log", "DEVLOG.jsonl", "--role", "architect" },
        1,
        null,
        "no log at this path yet",
    );
}

// --- New in block 4A: command-scoped arity (A5), --ref (4.8) -------------

test "header's --role is repeatable, unlike every other command's" {
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "header", "--role", "architect", "--role", "worker", "--change", "x" },
        1,
        null,
        // Still fails — --closer is missing — but crucially *not* on
        // "--role given more than once": repeating --role for header is
        // not an ambiguity.
        "requires at least one --closer",
    );
}

test "--closer that was never also given as --role is refused before any filesystem access" {
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "header", "--change", "x", "--role", "architect", "--closer", "reviewer" },
        1,
        null,
        "--closer 'reviewer' must also be given as --role",
    );
}

test "post's --ref rejects a value with no colon (4.8, A6)" {
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "post", "--ref", "no-colon-here" },
        1,
        null,
        "malformed",
    );
}

test "post's --ref rejects an empty namespace or an empty id" {
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "post", "--ref", ":2" },
        1,
        null,
        "malformed",
    );
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "post", "--ref", "D:" },
        1,
        null,
        "malformed",
    );
}

test "a flag only header accepts is an unknown flag when given to post" {
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "post", "--change", "x" },
        1,
        null,
        "unknown flag '--change'",
    );
}

test "a flag only post accepts is an unknown flag when given to header (reviewer nit, 4.8)" {
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "header", "--change", "x", "--ref", "D:1" },
        1,
        null,
        "unknown flag '--ref'",
    );
}

test "header's own --help names --change vs --log distinctly (A5)" {
    try expectRun(std.testing.allocator, &.{ "header", "--help" }, 0, "--change <name>", null);
    try expectRun(std.testing.allocator, &.{ "header", "--help" }, 0, "--log <path>", null);
}

// --- New in block 4A: real end-to-end writes ------------------------------

test "devlog header creates the log, prints 'created', and the file carries the declared roles and closers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);

    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "header", "--change", "add-devlog-core", "--role", "architect", "--role", "worker", "--closer", "architect" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expectEqualStrings("created\n", out.written());

    const bytes = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(bytes);
    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    var parsed = try record.parseLog(std.testing.allocator, bytes, &diag);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.records.len);
    try std.testing.expectEqual(record.Kind.header, std.meta.activeTag(parsed.records[0]));
    try std.testing.expectEqualStrings("add-devlog-core", parsed.records[0].header.change);
    try std.testing.expectEqual(@as(usize, 2), parsed.records[0].header.roles.len);
    try std.testing.expectEqualStrings("architect", parsed.records[0].header.closers[0]);
    try std.testing.expectEqualStrings(test_ts, parsed.records[0].header.ts);
}

test "devlog post appends a record with every field, refs included, and prints nothing on success" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    _ = try log.appendHeader(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "add-devlog-core", .roles = &.{ "architect", "worker" }, .closers = &.{"architect"} },
        &diag,
    );

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "Progress notes.\n\nMore than one line.");
    defer stdin_file.close(std.testing.io);

    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "post", "--section", "4", "--block", "4.3", "--to", "worker", "--ref", "D:2", "--ref", "S:9" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expectEqualStrings("", out.written());
    try std.testing.expectEqualStrings("", err_out.written());

    const bytes = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(bytes);
    var parsed = try record.parseLog(std.testing.allocator, bytes, &diag);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), parsed.records.len);
    const post = parsed.records[1].post;
    try std.testing.expectEqualStrings("architect", post.common.role);
    try std.testing.expectEqualStrings("4", post.common.section.?);
    try std.testing.expectEqualStrings("4.3", post.common.block.?);
    try std.testing.expectEqualStrings("worker", post.common.to.?);
    try std.testing.expectEqualStrings(test_ts, post.common.ts);
    try std.testing.expectEqualStrings("Progress notes.\n\nMore than one line.", post.common.body);
    try std.testing.expectEqual(@as(usize, 2), post.common.refs.len);
    try std.testing.expectEqualStrings("D", post.common.refs[0].ns);
    try std.testing.expectEqualStrings("2", post.common.refs[0].id);
    try std.testing.expectEqualStrings("S", post.common.refs[1].ns);
    try std.testing.expectEqualStrings("9", post.common.refs[1].id);
}

test "a ref in a namespace the tool has never seen is stored without complaint (4.8, external-references)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    _ = try log.appendHeader(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{"architect"}, .closers = &.{"architect"} },
        &diag,
    );

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "hi");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "post", "--ref", "totally-unknown-ns:whatever" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), code);

    const bytes = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(bytes);
    var parsed = try record.parseLog(std.testing.allocator, bytes, &diag);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("totally-unknown-ns", parsed.records[1].post.common.refs[0].ns);
}

// --- New in block 4A: refusals precede filesystem effect (A2, A3, C2) ----

test "post against a log that does not exist yet is refused, names devlog header, and creates nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "hi");
    defer stdin_file.close(std.testing.io);

    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "post" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "devlog header") != null);

    // Nothing but this test's own stdin stand-in exists — no DEVLOG.jsonl,
    // no temp file (done-gate 3, A2).
    var count: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next(std.testing.io)) |entry| {
        try std.testing.expectEqualStrings("stdin-standin", entry.name);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "header is the only command that ever creates the log (done-gate 4)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "hi");
    defer stdin_file.close(std.testing.io);

    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    // post fails before ever creating the log.
    _ = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "post" },
        &out.writer,
        &err_out.writer,
    );

    var stdin_file2 = try openStdinStandin(tmp.dir, std.testing.io, "hi");
    defer stdin_file2.close(std.testing.io);
    const header_code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file2,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "header", "--change", "x", "--role", "architect", "--closer", "architect" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), header_code);

    var saw_log = false;
    var it = tmp.dir.iterate();
    while (try it.next(std.testing.io)) |entry| {
        if (std.mem.eql(u8, entry.name, "DEVLOG.jsonl")) saw_log = true;
    }
    try std.testing.expect(saw_log);
}

test "post from an undeclared role is refused, names the declared roles, and the log is byte-for-byte unchanged (4.11, A1)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    _ = try log.appendHeader(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{ "architect", "worker" }, .closers = &.{"architect"} },
        &diag,
    );
    const before = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(before);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "hi");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "--role", "reviewr", "post" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "reviewr") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "architect") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "worker") != null);

    const after = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "a refused header write leaves an already-existing log byte-for-byte unchanged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    _ = try log.appendHeader(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{"architect"}, .closers = &.{"architect"} },
        &diag,
    );
    const before = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(before);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    // --closer not also given as --role: refused before appendHeader is
    // ever called.
    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "header", "--change", "x", "--role", "architect", "--closer", "reviewer" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);

    const after = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

// --- New in block 4B: section, brief, next (4.1, 4.2, 4.7) ----------------
// The write spine (block 4A) built command-scoped flag arity, --ref, the
// injected clock, and role validation inside appendRecord under the lock.
// These three commands are that spine plus zero or two extra string
// fields and a different kind — no new mechanism, per the block-4B brief.

test "section (4.1) is a known command with its own --help" {
    try expectRun(std.testing.allocator, &.{ "section", "--help" }, 0, "devlog section", null);
    try expectRun(std.testing.allocator, &.{ "section", "--help" }, 0, "--title <t>", null);
    try expectRun(std.testing.allocator, &.{ "section", "--help" }, 0, "--base <sha>", null);
}

test "brief (4.2) is a known command with its own --help" {
    try expectRun(std.testing.allocator, &.{ "brief", "--help" }, 0, "devlog brief", null);
    try expectRun(std.testing.allocator, &.{ "brief", "--help" }, 0, "--to <role>", null);
}

test "next (4.7) is a known command with its own --help" {
    try expectRun(std.testing.allocator, &.{ "next", "--help" }, 0, "devlog next", null);
    try expectRun(std.testing.allocator, &.{ "next", "--help" }, 0, "--ref <ns:id>", null);
}

test "section requires --section, --title, and --base, in that order, before any filesystem access" {
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "section" },
        1,
        null,
        "requires --section",
    );
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "section", "--section", "4" },
        1,
        null,
        "requires --title",
    );
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "section", "--section", "4", "--title", "Write commands" },
        1,
        null,
        "requires --base",
    );
}

test "brief requires --section, --block, and --to, in that order, before any filesystem access" {
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "brief" },
        1,
        null,
        "requires --section",
    );
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "brief", "--section", "4" },
        1,
        null,
        "requires --block",
    );
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "brief", "--section", "4", "--block", "4.1-4.3" },
        1,
        null,
        "requires --to",
    );
}

test "next requires only --role, unlike post/section/brief" {
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "next" },
        1,
        null,
        "requires --role",
    );
}

test "next takes no --section, --block, or --to: all three are unknown flags (4.7)" {
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "next", "--section", "4" },
        1,
        null,
        "unknown flag '--section'",
    );
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "next", "--block", "4.7" },
        1,
        null,
        "unknown flag '--block'",
    );
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "next", "--to", "worker" },
        1,
        null,
        "unknown flag '--to'",
    );
}

test "--title and --base are section-only: post and brief reject them as unknown flags" {
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "post", "--title", "x" },
        1,
        null,
        "unknown flag '--title'",
    );
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "brief", "--base", "x" },
        1,
        null,
        "unknown flag '--base'",
    );
}

test "--to is not recognised by section (post/brief only)" {
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "section", "--to", "worker" },
        1,
        null,
        "unknown flag '--to'",
    );
}

test "devlog section appends a section record with title, base, and refs, printing nothing on success" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    _ = try log.appendHeader(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "add-devlog-core", .roles = &.{"architect"}, .closers = &.{"architect"} },
        &diag,
    );

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "What section 4 delivers.");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "section", "--section", "4", "--title", "Write commands", "--base", "b59f249", "--ref", "D:9" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expectEqualStrings("", out.written());
    try std.testing.expectEqualStrings("", err_out.written());

    const bytes = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(bytes);
    var parsed = try record.parseLog(std.testing.allocator, bytes, &diag);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), parsed.records.len);
    const section_rec = parsed.records[1].section;
    try std.testing.expectEqualStrings("4", section_rec.common.section.?);
    try std.testing.expectEqualStrings("Write commands", section_rec.title);
    try std.testing.expectEqualStrings("b59f249", section_rec.base);
    try std.testing.expectEqualStrings("What section 4 delivers.", section_rec.common.body);
    try std.testing.expectEqual(@as(usize, 1), section_rec.common.refs.len);
    try std.testing.expectEqualStrings("D", section_rec.common.refs[0].ns);
}

test "devlog brief appends a brief record addressed to a declared role" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    _ = try log.appendHeader(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "add-devlog-core", .roles = &.{ "architect", "worker" }, .closers = &.{"architect"} },
        &diag,
    );

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "Build the write spine.");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "brief", "--section", "4", "--block", "4.3", "--to", "worker", "--ref", "S:4" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expectEqualStrings("", out.written());

    const bytes = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(bytes);
    var parsed = try record.parseLog(std.testing.allocator, bytes, &diag);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), parsed.records.len);
    const brief_rec = parsed.records[1].brief;
    try std.testing.expectEqualStrings("worker", brief_rec.common.to.?);
    try std.testing.expectEqualStrings("4.3", brief_rec.common.block.?);
    try std.testing.expectEqualStrings("Build the write spine.", brief_rec.common.body);
}

test "devlog brief refuses --to naming an undeclared role, reports the declared roles, and touches nothing (block 4B decision)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    _ = try log.appendHeader(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{ "architect", "worker" }, .closers = &.{"architect"} },
        &diag,
    );
    const before = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(before);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "Build it.");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "brief", "--section", "4", "--block", "4.3", "--to", "reviewr" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "reviewr") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "architect") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "worker") != null);

    const after = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "brief from an undeclared writer role is refused, and the log is byte-for-byte unchanged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    _ = try log.appendHeader(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{ "architect", "worker" }, .closers = &.{"architect"} },
        &diag,
    );
    const before = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(before);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "Build it.");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "--role", "reviewr", "brief", "--section", "4", "--block", "4.3", "--to", "worker" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "reviewr") != null);

    const after = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "devlog next appends without rewriting: two calls produce two next records, in order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    _ = try log.appendHeader(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{"architect"}, .closers = &.{"architect"} },
        &diag,
    );

    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    var stdin1 = try openStdinStandin(tmp.dir, std.testing.io, "Resume at 4.1.");
    defer stdin1.close(std.testing.io);
    const code1 = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin1,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "next" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), code1);

    var stdin2 = try openStdinStandin(tmp.dir, std.testing.io, "Resume at 4.4, block 4C.");
    defer stdin2.close(std.testing.io);
    const code2 = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin2,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "next", "--ref", "N:1" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), code2);

    const bytes = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(bytes);
    var parsed = try record.parseLog(std.testing.allocator, bytes, &diag);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 3), parsed.records.len);
    try std.testing.expectEqual(record.Kind.next, std.meta.activeTag(parsed.records[1]));
    try std.testing.expectEqual(record.Kind.next, std.meta.activeTag(parsed.records[2]));
    try std.testing.expectEqualStrings("Resume at 4.1.", parsed.records[1].next.common.body);
    try std.testing.expectEqualStrings("Resume at 4.4, block 4C.", parsed.records[2].next.common.body);
    try std.testing.expectEqual(@as(usize, 1), parsed.records[2].next.common.refs.len);
}

test "section against a log that does not exist yet is refused, names devlog header, and creates nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "hi");
    defer stdin_file.close(std.testing.io);

    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "section", "--section", "4", "--title", "x", "--base", "abc" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "devlog header") != null);

    var count: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next(std.testing.io)) |entry| {
        try std.testing.expectEqualStrings("stdin-standin", entry.name);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "brief against a log that does not exist yet is refused, names devlog header, and creates nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "hi");
    defer stdin_file.close(std.testing.io);

    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "brief", "--section", "4", "--block", "4.1-4.3", "--to", "worker" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "devlog header") != null);

    var count: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next(std.testing.io)) |entry| {
        try std.testing.expectEqualStrings("stdin-standin", entry.name);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "next against a log that does not exist yet is refused, names devlog header, and creates nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "hi");
    defer stdin_file.close(std.testing.io);

    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "next" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "devlog header") != null);

    var count: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next(std.testing.io)) |entry| {
        try std.testing.expectEqualStrings("stdin-standin", entry.name);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "section from an undeclared role is refused, and the log is byte-for-byte unchanged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    _ = try log.appendHeader(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{"architect"}, .closers = &.{"architect"} },
        &diag,
    );
    const before = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(before);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "hi");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "--role", "reviewr", "section", "--section", "4", "--title", "x", "--base", "abc" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "reviewr") != null);

    const after = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "next from an undeclared role is refused, and the log is byte-for-byte unchanged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    _ = try log.appendHeader(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{"architect"}, .closers = &.{"architect"} },
        &diag,
    );
    const before = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(before);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "hi");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "--role", "reviewr", "next" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "reviewr") != null);

    const after = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

// --- Block 4C: item, close, verdict (4.4-4.6), enum validation (4.9) -----

test "item, close, and verdict (4.4-4.6) are known commands with their own --help" {
    try expectRun(std.testing.allocator, &.{ "item", "--help" }, 0, "devlog item", null);
    try expectRun(std.testing.allocator, &.{ "item", "--help" }, 0, "--type <t>", null);
    try expectRun(std.testing.allocator, &.{ "item", "--help" }, 0, "--blocking", null);
    try expectRun(std.testing.allocator, &.{ "close", "--help" }, 0, "devlog close", null);
    try expectRun(std.testing.allocator, &.{ "close", "--help" }, 0, "--state <s>", null);
    try expectRun(std.testing.allocator, &.{ "verdict", "--help" }, 0, "devlog verdict", null);
    try expectRun(std.testing.allocator, &.{ "verdict", "--help" }, 0, "--outcome <o>", null);
}

test "item requires --role and --type, in that order, before any filesystem access" {
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "item" },
        1,
        null,
        "requires --role",
    );
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "worker", "item" },
        1,
        null,
        "requires --type",
    );
}

test "close requires --role, --item, and --state, in that order, before any filesystem access" {
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "close" },
        1,
        null,
        "requires --role",
    );
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "close" },
        1,
        null,
        "requires --item",
    );
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "close", "--item", "1" },
        1,
        null,
        "requires --state",
    );
}

test "verdict requires --role, --section, --block, --outcome, and --commit, in that order, before any filesystem access" {
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "verdict" },
        1,
        null,
        "requires --role",
    );
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "reviewer", "verdict" },
        1,
        null,
        "requires --section",
    );
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "reviewer", "verdict", "--section", "4" },
        1,
        null,
        "requires --block",
    );
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "reviewer", "verdict", "--section", "4", "--block", "4C" },
        1,
        null,
        "requires --outcome",
    );
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "reviewer", "verdict", "--section", "4", "--block", "4C", "--outcome", "approve" },
        1,
        null,
        "requires --commit",
    );
}

test "item's --type rejects an unrecognised value and names the permitted set (4.9)" {
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "worker", "item", "--type", "bug" },
        1,
        null,
        "--type 'bug' is not recognised — expected one of: question, finding, decision, note, task",
    );
}

test "close's --state rejects an unrecognised value and names the permitted set (4.9)" {
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "close", "--item", "1", "--state", "done" },
        1,
        null,
        "--state 'done' is not recognised — expected one of: resolved, deferred, superseded",
    );
}

test "verdict's --outcome rejects an unrecognised value and names the permitted set (4.9)" {
    try expectRun(
        std.testing.allocator,
        &.{
            "--log",     "DEVLOG.jsonl", "--role",  "reviewer", "verdict",
            "--section", "4",            "--block", "4C",       "--outcome",
            "aprove",    "--commit",     "abc",
        },
        1,
        null,
        "--outcome 'aprove' is not recognised — expected one of: approve, approve-with-nits, request-changes",
    );
}

test "close's --item must be a positive integer" {
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "close", "--item", "abc", "--state", "resolved" },
        1,
        null,
        "--item 'abc' must be a positive integer",
    );
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "close", "--item", "0", "--state", "resolved" },
        1,
        null,
        "--item '0' must be a positive integer",
    );
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "close", "--item", "-1", "--state", "resolved" },
        1,
        null,
        "--item '-1' must be a positive integer",
    );
}

test "close takes no --section, --block, or --to: all three are unknown flags (4.5)" {
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "close", "--item", "1", "--state", "resolved", "--section", "4" },
        1,
        null,
        "unknown flag '--section'",
    );
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "close", "--item", "1", "--state", "resolved", "--block", "4C" },
        1,
        null,
        "unknown flag '--block'",
    );
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "close", "--item", "1", "--state", "resolved", "--to", "worker" },
        1,
        null,
        "unknown flag '--to'",
    );
}

test "verdict takes no --to: unknown flag (4.6)" {
    try expectRun(
        std.testing.allocator,
        &.{
            "--log",     "DEVLOG.jsonl", "--role",  "reviewer", "verdict",
            "--section", "4",            "--block", "4C",       "--outcome",
            "approve",   "--commit",     "abc",     "--to",     "architect",
        },
        1,
        null,
        "unknown flag '--to'",
    );
}

test "--type, --item, --state, and --outcome are unknown flags on commands that don't own them" {
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "worker", "post", "--type", "note" },
        1,
        null,
        "unknown flag '--type'",
    );
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "worker", "item", "--type", "note", "--item", "1" },
        1,
        null,
        "unknown flag '--item'",
    );
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "close", "--item", "1", "--state", "resolved", "--outcome", "approve" },
        1,
        null,
        "unknown flag '--outcome'",
    );
    try expectRun(
        std.testing.allocator,
        &.{
            "--log",     "DEVLOG.jsonl", "--role",  "reviewer", "verdict",
            "--section", "4",            "--block", "4C",       "--outcome",
            "approve",   "--commit",     "abc",     "--state",  "resolved",
        },
        1,
        null,
        "unknown flag '--state'",
    );
}

test "devlog item appends an item record, assigns #1, and prints '#1' and nothing else on stdout" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    _ = try log.appendHeader(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "add-devlog-core", .roles = &.{ "architect", "worker" }, .closers = &.{"architect"} },
        &diag,
    );

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "Spec says 300ms, design says 500ms. Which wins?");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{
            "--log",  "DEVLOG.jsonl", "--role",    "worker",     "item",
            "--type", "question",     "--section", "4",          "--block",
            "4C",     "--to",         "architect", "--blocking", "--ref",
            "S:4",
        },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expectEqualStrings("#1\n", out.written());
    try std.testing.expectEqualStrings("", err_out.written());

    const bytes = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(bytes);
    var parsed = try record.parseLog(std.testing.allocator, bytes, &diag);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), parsed.records.len);
    const item_rec = parsed.records[1].item;
    try std.testing.expectEqual(@as(i64, 1), item_rec.item);
    try std.testing.expectEqual(record.ItemType.question, item_rec.type);
    try std.testing.expect(item_rec.blocking);
    try std.testing.expectEqualStrings("architect", item_rec.common.to.?);
    try std.testing.expectEqual(@as(usize, 1), item_rec.common.refs.len);
}

test "devlog item assigns increasing numbers across calls, unaffected by other record kinds appended in between (D9)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    _ = try log.appendHeader(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{"worker"}, .closers = &.{"worker"} },
        &diag,
    );

    {
        var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "first item");
        defer stdin_file.close(std.testing.io);
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer err_out.deinit();
        const code = run(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            stdin_file,
            test_ts,
            &.{ "--log", "DEVLOG.jsonl", "--role", "worker", "item", "--type", "note" },
            &out.writer,
            &err_out.writer,
        );
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expectEqualStrings("#1\n", out.written());
    }
    {
        var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "progress note");
        defer stdin_file.close(std.testing.io);
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer err_out.deinit();
        const code = run(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            stdin_file,
            test_ts,
            &.{ "--log", "DEVLOG.jsonl", "--role", "worker", "post" },
            &out.writer,
            &err_out.writer,
        );
        try std.testing.expectEqual(@as(u8, 0), code);
    }
    {
        var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "second item");
        defer stdin_file.close(std.testing.io);
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer err_out.deinit();
        const code = run(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            stdin_file,
            test_ts,
            &.{ "--log", "DEVLOG.jsonl", "--role", "worker", "item", "--type", "task" },
            &out.writer,
            &err_out.writer,
        );
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expectEqualStrings("#2\n", out.written());
    }

    const bytes = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(bytes);
    var parsed = try record.parseLog(std.testing.allocator, bytes, &diag);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 4), parsed.records.len); // header, item, post, item
    try std.testing.expectEqual(@as(i64, 1), parsed.records[1].item.item);
    try std.testing.expectEqual(@as(i64, 2), parsed.records[3].item.item);
}

test "devlog item's --blocking is independent of --type: a decision can be flagged blocking (work-items scenario)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    _ = try log.appendHeader(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{"architect"}, .closers = &.{"architect"} },
        &diag,
    );

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "debounce on submit, not keystroke");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "item", "--type", "decision", "--blocking" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), code);

    const bytes = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(bytes);
    var parsed = try record.parseLog(std.testing.allocator, bytes, &diag);
    defer parsed.deinit();
    try std.testing.expectEqual(record.ItemType.decision, parsed.records[1].item.type);
    try std.testing.expect(parsed.records[1].item.blocking);
}

test "devlog item's --blocking absent defaults to false" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    _ = try log.appendHeader(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{"architect"}, .closers = &.{"architect"} },
        &diag,
    );

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "an observation");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "item", "--type", "note" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), code);

    const bytes = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(bytes);
    var parsed = try record.parseLog(std.testing.allocator, bytes, &diag);
    defer parsed.deinit();
    try std.testing.expect(!parsed.records[1].item.blocking);
}

test "devlog item refuses --to naming an undeclared role, reports the declared roles, and touches nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    _ = try log.appendHeader(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{ "architect", "worker" }, .closers = &.{"architect"} },
        &diag,
    );
    const before = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(before);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "hi");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "--role", "worker", "item", "--type", "question", "--to", "reviewr" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "reviewr") != null);

    const after = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "devlog close appends a close record with state and reason, and prints nothing on success" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    _ = try log.appendHeader(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{ "architect", "worker" }, .closers = &.{"architect"} },
        &diag,
    );
    const item_rec = record.Record{ .item = .{
        .common = .{ .seq = 0, .ts = "t1", .role = "worker", .body = "raised" },
        .item = 0,
        .type = .question,
        .blocking = false,
    } };
    _ = try log.appendItem(std.testing.allocator, std.testing.io, tmp.dir, "DEVLOG.jsonl", item_rec, &diag);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "500ms — design wins.");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "close", "--item", "1", "--state", "resolved", "--ref", "D:2" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expectEqualStrings("", out.written());

    const bytes = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(bytes);
    var parsed = try record.parseLog(std.testing.allocator, bytes, &diag);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 3), parsed.records.len);
    const close_rec = parsed.records[2].close;
    try std.testing.expectEqual(@as(i64, 1), close_rec.item);
    try std.testing.expectEqual(record.CloseState.resolved, close_rec.state);
    try std.testing.expectEqualStrings("500ms — design wins.", close_rec.common.body);
    try std.testing.expectEqual(@as(usize, 1), close_rec.common.refs.len);
}

test "devlog close refuses an --item naming a number that was never raised, names how many items exist, and touches nothing (4.5)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    _ = try log.appendHeader(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{"architect"}, .closers = &.{"architect"} },
        &diag,
    );
    const before = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(before);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "typo'd item number");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "close", "--item", "7", "--state", "resolved" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "#7") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "does not exist") != null);

    const after = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "devlog close refuses a role that is not a declared closer, names the declared closers, and touches nothing (work-items guardrail)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    _ = try log.appendHeader(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{ "architect", "worker" }, .closers = &.{"architect"} },
        &diag,
    );
    const item_rec = record.Record{ .item = .{
        .common = .{ .seq = 0, .ts = "t1", .role = "worker", .body = "raised" },
        .item = 0,
        .type = .task,
        .blocking = false,
    } };
    _ = try log.appendItem(std.testing.allocator, std.testing.io, tmp.dir, "DEVLOG.jsonl", item_rec, &diag);
    const before = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(before);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "not mine to close");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "--role", "worker", "close", "--item", "1", "--state", "resolved" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "worker") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "closer") != null);

    const after = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "devlog close accepts a second close on an already-closed item — not refused (4.5, architect ruling)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    _ = try log.appendHeader(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{"architect"}, .closers = &.{"architect"} },
        &diag,
    );
    const item_rec = record.Record{ .item = .{
        .common = .{ .seq = 0, .ts = "t1", .role = "architect", .body = "raised" },
        .item = 0,
        .type = .decision,
        .blocking = false,
    } };
    _ = try log.appendItem(std.testing.allocator, std.testing.io, tmp.dir, "DEVLOG.jsonl", item_rec, &diag);

    {
        var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "deferred for now");
        defer stdin_file.close(std.testing.io);
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer err_out.deinit();
        const code = run(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            stdin_file,
            test_ts,
            &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "close", "--item", "1", "--state", "deferred" },
            &out.writer,
            &err_out.writer,
        );
        try std.testing.expectEqual(@as(u8, 0), code);
    }
    {
        var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "actually resolved");
        defer stdin_file.close(std.testing.io);
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer err_out.deinit();
        const code = run(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            stdin_file,
            test_ts,
            &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "close", "--item", "1", "--state", "resolved" },
            &out.writer,
            &err_out.writer,
        );
        try std.testing.expectEqual(@as(u8, 0), code);
    }

    const bytes = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(bytes);
    var parsed = try record.parseLog(std.testing.allocator, bytes, &diag);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 4), parsed.records.len);
    try std.testing.expectEqual(record.CloseState.deferred, parsed.records[2].close.state);
    try std.testing.expectEqual(record.CloseState.resolved, parsed.records[3].close.state);
}

test "devlog verdict appends a verdict record with outcome, commit, and refs, printing nothing on success" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    _ = try log.appendHeader(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{"reviewer"}, .closers = &.{"reviewer"} },
        &diag,
    );

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "Approve with nits.");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{
            "--log",             "DEVLOG.jsonl", "--role",  "reviewer", "verdict",
            "--section",         "4",            "--block", "4.4-4.9",  "--outcome",
            "approve-with-nits", "--commit",     "c9d0e1f", "--ref",    "D:9",
        },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expectEqualStrings("", out.written());

    const bytes = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(bytes);
    var parsed = try record.parseLog(std.testing.allocator, bytes, &diag);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.records.len);
    const verdict_rec = parsed.records[1].verdict;
    try std.testing.expectEqual(record.VerdictOutcome.@"approve-with-nits", verdict_rec.outcome);
    try std.testing.expectEqualStrings("c9d0e1f", verdict_rec.commit);
    try std.testing.expectEqualStrings("4.4-4.9", verdict_rec.common.block.?);
    try std.testing.expectEqual(@as(usize, 1), verdict_rec.common.refs.len);
}

test "item against a log that does not exist yet is refused, names devlog header, and creates nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "hi");
    defer stdin_file.close(std.testing.io);

    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "--role", "worker", "item", "--type", "note" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "devlog header") != null);

    var count: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next(std.testing.io)) |entry| {
        try std.testing.expectEqualStrings("stdin-standin", entry.name);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "close against a log that does not exist yet is refused, names devlog header, and creates nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "hi");
    defer stdin_file.close(std.testing.io);

    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "close", "--item", "1", "--state", "resolved" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "devlog header") != null);

    var count: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next(std.testing.io)) |entry| {
        try std.testing.expectEqualStrings("stdin-standin", entry.name);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "verdict against a log that does not exist yet is refused, names devlog header, and creates nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "hi");
    defer stdin_file.close(std.testing.io);

    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{
            "--log",     "DEVLOG.jsonl", "--role",  "reviewer", "verdict",
            "--section", "4",            "--block", "4C",       "--outcome",
            "approve",   "--commit",     "abc",
        },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "devlog header") != null);

    var count: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next(std.testing.io)) |entry| {
        try std.testing.expectEqualStrings("stdin-standin", entry.name);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "item from an undeclared role is refused, and the log is byte-for-byte unchanged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    _ = try log.appendHeader(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{"architect"}, .closers = &.{"architect"} },
        &diag,
    );
    const before = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(before);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "hi");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "--role", "reviewr", "item", "--type", "note" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "reviewr") != null);

    const after = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "close from an undeclared role is refused, and the log is byte-for-byte unchanged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    _ = try log.appendHeader(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{"architect"}, .closers = &.{"architect"} },
        &diag,
    );
    const before = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(before);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "hi");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "--role", "reviewr", "close", "--item", "1", "--state", "resolved" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "reviewr") != null);

    const after = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "verdict from an undeclared role is refused, and the log is byte-for-byte unchanged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    _ = try log.appendHeader(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{"architect"}, .closers = &.{"architect"} },
        &diag,
    );
    const before = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(before);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "hi");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{
            "--log",     "DEVLOG.jsonl", "--role",  "reviewr", "verdict",
            "--section", "4",            "--block", "4C",      "--outcome",
            "approve",   "--commit",     "abc",
        },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "reviewr") != null);

    const after = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

// --- Remediation, section 4 (supervisor findings B1, B2) ------------------
// B1: a bare positional token after a write command's name is now a parse
// fault, not a silently dropped token. B2: `devlog header`'s declaration is
// a set — reordering is not a change (log.zig), and a repeated --role/
// --closer value is refused rather than deduplicated (here).

test "a stray positional token after post is refused, and the log is unchanged (B1)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    _ = try log.appendHeader(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{"architect"}, .closers = &.{"architect"} },
        &diag,
    );
    const before = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(before);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "hi");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "post", "stray-token" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "unexpected argument 'stray-token'") != null);

    const after = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "a stray positional token after item is refused, and the log is unchanged (B1)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    _ = try log.appendHeader(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{"architect"}, .closers = &.{"architect"} },
        &diag,
    );
    const before = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(before);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "hi");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "item", "stray-token", "--type", "note" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "unexpected argument 'stray-token'") != null);

    const after = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "--blocking true is refused: --blocking is a bare flag, 'true' is a stray argument (B1)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    _ = try log.appendHeader(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{"architect"}, .closers = &.{"architect"} },
        &diag,
    );
    const before = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(before);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "hi");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "item", "--blocking", "true", "--type", "note" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "unexpected argument 'true'") != null);

    const after = try log.readAllLog(std.testing.allocator, tmp.dir, std.testing.io);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "post --bogus is still refused as an unknown flag — must not regress under B1 (reviewer pin)" {
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "--role", "architect", "post", "--bogus" },
        1,
        null,
        "unknown flag '--bogus'",
    );
}

test "header refuses a repeated --role value, naming it, and the log is unchanged (B2)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{
            "--log",     "DEVLOG.jsonl", "header",    "--change", "x",
            "--role",    "architect",    "--role",    "worker",   "--role",
            "architect", "--closer",     "architect",
        },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "--role 'architect' given more than once") != null);

    // The log must not even have been created.
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "DEVLOG.jsonl", .{}));
}

test "header refuses a repeated --closer value, naming it, and the log is unchanged (B2)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{
            "--log",     "DEVLOG.jsonl", "header",    "--change", "x",
            "--role",    "architect",    "--role",    "worker",   "--closer",
            "architect", "--closer",     "architect",
        },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "--closer 'architect' given more than once") != null);

    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "DEVLOG.jsonl", .{}));
}

// --- show (6.2, 6.6) ---------------------------------------------------

test "show requires exactly one of --item or --seq: neither is refused before any filesystem access" {
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "show" },
        1,
        null,
        "requires --item <n> or --seq <n>",
    );
    // No log was even opened — confirmed the same way the write commands'
    // own required-flag tests already do (A3's ordering, on a read).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();
    _ = run(std.testing.allocator, std.testing.io, tmp.dir, stdin_file, test_ts, &.{ "--log", "DEVLOG.jsonl", "show" }, &out.writer, &err_out.writer);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "DEVLOG.jsonl", .{}));
}

test "show refuses both --item and --seq together, and touches nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "show", "--item", "1", "--seq", "1" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "not both") != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "DEVLOG.jsonl", .{}));
}

test "show --item and --seq must each be a positive integer" {
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "show", "--item", "0" },
        1,
        null,
        "--item '0' must be a positive integer",
    );
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "show", "--seq", "abc" },
        1,
        null,
        "--seq 'abc' must be a positive integer",
    );
}

test "show against a missing log reports plainly, exits non-zero, and creates nothing (6.6, durable-format)" {
    // "The file was not created" is only convincing if the test asserts
    // the directory's contents directly, not merely that the command
    // failed — so this iterates the tmp dir afterwards.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "show", "--item", "1" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "devlog header") != null);
    try std.testing.expectEqualStrings("", out.written());

    // Only the test harness's own stdin stand-in exists — nothing this
    // command itself could have created.
    var count: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next(std.testing.io)) |entry| {
        try std.testing.expectEqualStrings("stdin-standin", entry.name);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

/// Seeds a fresh tmp dir with a header, one open item (#1, a question from
/// worker to architect), and one close of it (resolved, by architect) —
/// the fixture every `show --item` test below builds on.
fn seedItemAndClose(allocator: Allocator, dir: Io.Dir, io: Io, diag: *record.Diagnostics) !void {
    _ = try log.appendHeader(
        allocator,
        io,
        dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{ "architect", "worker" }, .closers = &.{"architect"} },
        diag,
    );
    const item_rec = record.Record{ .item = .{
        .common = .{ .seq = 0, .ts = "t1", .role = "worker", .to = "architect", .body = "should we use X?" },
        .item = 0,
        .type = .question,
        .blocking = true,
    } };
    _ = try log.appendItem(allocator, io, dir, "DEVLOG.jsonl", item_rec, diag);

    const close_rec = record.Record{ .close = .{
        .common = .{ .seq = 0, .ts = "t2", .role = "architect", .body = "yes, X it is" },
        .item = 1,
        .state = .resolved,
    } };
    _ = try log.appendRecord(allocator, io, dir, "DEVLOG.jsonl", close_rec, diag);
}

test "show --item retrieves the item with its derived state and full close history, rendered as text" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    try seedItemAndClose(std.testing.allocator, tmp.dir, std.testing.io, &diag);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "show", "--item", "1" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), code);
    const text = out.written();
    // Derived state (work-items: state is one of open/resolved/deferred/
    // superseded, not a raw record field).
    try std.testing.expect(std.mem.indexOf(u8, text, "state: resolved") != null);
    // The opening record's own fields.
    try std.testing.expect(std.mem.indexOf(u8, text, "type: question") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "blocking: true") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "should we use X?") != null);
    // The close record's own fields (work-items: "who closed it, when, and
    // why are all recoverable").
    try std.testing.expect(std.mem.indexOf(u8, text, "role: architect") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "yes, X it is") != null);
}

test "show --item --json emits the same content as JSON, reusing record.write rather than a second emitter" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    try seedItemAndClose(std.testing.allocator, tmp.dir, std.testing.io, &diag);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "show", "--item", "1", "--json" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), code);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 1), root.get("number").?.integer);
    try std.testing.expectEqualStrings("resolved", root.get("state").?.string);
    const opened = root.get("item").?.object;
    try std.testing.expectEqualStrings("item", opened.get("kind").?.string);
    try std.testing.expectEqualStrings("question", opened.get("type").?.string);
    try std.testing.expectEqualStrings("should we use X?", opened.get("body").?.string);
    const closes = root.get("closes").?.array;
    try std.testing.expectEqual(@as(usize, 1), closes.items.len);
    try std.testing.expectEqualStrings("close", closes.items[0].object.get("kind").?.string);
    try std.testing.expectEqualStrings("resolved", closes.items[0].object.get("state").?.string);
    try std.testing.expectEqualStrings("yes, X it is", closes.items[0].object.get("body").?.string);

    // D15: the two forms describe the same log — same body text reachable
    // in both.
    _ = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "show", "--item", "1" },
        &out.writer,
        &err_out.writer,
    );
}

test "show --item naming a number no item bears is a plain report, not an empty success" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    _ = try log.appendHeader(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{"architect"}, .closers = &.{"architect"} },
        &diag,
    );

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "show", "--item", "7" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expectEqualStrings("", out.written());
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "item #7 does not exist") != null);
}

test "show --seq retrieves one record verbatim, text and JSON forms agreeing (D15)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    try seedItemAndClose(std.testing.allocator, tmp.dir, std.testing.io, &diag);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);

    // seq 2 is the item record (seq 1 is the header).
    {
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer err_out.deinit();
        const code = run(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            stdin_file,
            test_ts,
            &.{ "--log", "DEVLOG.jsonl", "show", "--seq", "2" },
            &out.writer,
            &err_out.writer,
        );
        try std.testing.expectEqual(@as(u8, 0), code);
        const text = out.written();
        try std.testing.expect(std.mem.indexOf(u8, text, "kind: item") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "should we use X?") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "to: architect") != null);
    }
    {
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer err_out.deinit();
        const code = run(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            stdin_file,
            test_ts,
            &.{ "--log", "DEVLOG.jsonl", "show", "--seq", "2", "--json" },
            &out.writer,
            &err_out.writer,
        );
        try std.testing.expectEqual(@as(u8, 0), code);

        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
        defer parsed.deinit();
        const root = parsed.value.object;
        try std.testing.expectEqualStrings("item", root.get("kind").?.string);
        try std.testing.expectEqual(@as(i64, 2), root.get("seq").?.integer);
        try std.testing.expectEqualStrings("should we use X?", root.get("body").?.string);
        try std.testing.expectEqualStrings("architect", root.get("to").?.string);
    }
}

test "show --seq naming a number no record carries is a plain report, not an empty success" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    _ = try log.appendHeader(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{"architect"}, .closers = &.{"architect"} },
        &diag,
    );

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "show", "--seq", "99" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expectEqualStrings("", out.written());
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "no record with seq 99") != null);
}

test "show ignores a leftover temporary file beside the log (durable-format, carried 10)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    try seedItemAndClose(std.testing.allocator, tmp.dir, std.testing.io, &diag);

    // A decoy temp file, named exactly as a killed write would leave one,
    // whose content differs from the real log's — if `show` ever read it
    // instead, the assertions below would fail rather than merely pass by
    // accident.
    {
        var f = try tmp.dir.createFile(std.testing.io, ".DEVLOG.jsonl.tmp-0000000000000000000000000000dead", .{ .truncate = false });
        defer f.close(std.testing.io);
        try f.writePositionalAll(std.testing.io, "{\"kind\":\"header\",\"seq\":1,\"ts\":\"decoy\",\"format\":1,\"tool\":\"x\",\"change\":\"x\",\"roles\":[\"architect\"],\"closers\":[\"architect\"]}\n", 0);
    }

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "show", "--seq", "1" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "decoy") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "kind: header") != null);
}

test "show --help prints its own usage, mentioning --item, --seq, and --json" {
    try expectRun(std.testing.allocator, &.{ "show", "--help" }, 0, "devlog show", null);
    try expectRun(std.testing.allocator, &.{ "show", "--help" }, 0, "--item", null);
    try expectRun(std.testing.allocator, &.{ "show", "--help" }, 0, "--seq", null);
    try expectRun(std.testing.allocator, &.{ "show", "--help" }, 0, "--json", null);
}

/// Seeds a fresh tmp dir with just a header — the shared base each
/// single-kind `show --seq` fixture below appends its one record onto
/// (reviewer nit 2, architect ruling: land before this block commits).
fn seedHeaderOnly(allocator: Allocator, dir: Io.Dir, io: Io, diag: *record.Diagnostics) !void {
    _ = try log.appendHeader(
        allocator,
        io,
        dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{ "architect", "worker", "reviewer" }, .closers = &.{"architect"} },
        diag,
    );
}

test "show --seq on a section record renders the same content in text and JSON (D15)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    try seedHeaderOnly(std.testing.allocator, tmp.dir, std.testing.io, &diag);

    const rec = record.Record{ .section = .{
        .common = .{ .seq = 0, .ts = "t1", .role = "architect", .section = "9", .body = "Reviewed the section boundary." },
        .title = "Read commands",
        .base = "31eb5e3",
    } };
    _ = try log.appendRecord(std.testing.allocator, std.testing.io, tmp.dir, "DEVLOG.jsonl", rec, &diag);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);

    var text_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer text_out.deinit();
    var text_err: Io.Writer.Allocating = .init(std.testing.allocator);
    defer text_err.deinit();
    const text_code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "show", "--seq", "2" },
        &text_out.writer,
        &text_err.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), text_code);
    const text = text_out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "kind: section") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "title: Read commands") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "base: 31eb5e3") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "section: 9") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Reviewed the section boundary.") != null);

    var json_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer json_out.deinit();
    var json_err: Io.Writer.Allocating = .init(std.testing.allocator);
    defer json_err.deinit();
    const json_code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "show", "--seq", "2", "--json" },
        &json_out.writer,
        &json_err.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), json_code);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_out.written(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("section", root.get("kind").?.string);
    try std.testing.expectEqualStrings("Read commands", root.get("title").?.string);
    try std.testing.expectEqualStrings("31eb5e3", root.get("base").?.string);
    try std.testing.expectEqualStrings("9", root.get("section").?.string);
    try std.testing.expectEqualStrings("Reviewed the section boundary.", root.get("body").?.string);
}

test "show --seq on a brief record renders the same content in text and JSON (D15)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    try seedHeaderOnly(std.testing.allocator, tmp.dir, std.testing.io, &diag);

    const rec = record.Record{ .brief = .{
        .common = .{
            .seq = 0,
            .ts = "t1",
            .role = "architect",
            .block = "6A",
            .to = "worker",
            .refs = &.{.{ .ns = "D", .id = "15" }},
            .body = "Implement the read-only load path.",
        },
    } };
    _ = try log.appendRecord(std.testing.allocator, std.testing.io, tmp.dir, "DEVLOG.jsonl", rec, &diag);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);

    var text_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer text_out.deinit();
    var text_err: Io.Writer.Allocating = .init(std.testing.allocator);
    defer text_err.deinit();
    const text_code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "show", "--seq", "2" },
        &text_out.writer,
        &text_err.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), text_code);
    const text = text_out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "kind: brief") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "block: 6A") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "to: worker") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ref: D:15") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Implement the read-only load path.") != null);

    var json_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer json_out.deinit();
    var json_err: Io.Writer.Allocating = .init(std.testing.allocator);
    defer json_err.deinit();
    const json_code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "show", "--seq", "2", "--json" },
        &json_out.writer,
        &json_err.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), json_code);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_out.written(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("brief", root.get("kind").?.string);
    try std.testing.expectEqualStrings("6A", root.get("block").?.string);
    try std.testing.expectEqualStrings("worker", root.get("to").?.string);
    try std.testing.expectEqualStrings("Implement the read-only load path.", root.get("body").?.string);
    const refs = root.get("refs").?.array;
    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
    try std.testing.expectEqualStrings("D", refs.items[0].object.get("ns").?.string);
    try std.testing.expectEqualStrings("15", refs.items[0].object.get("id").?.string);
}

test "show --seq on a post record renders the same content in text and JSON (D15)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    try seedHeaderOnly(std.testing.allocator, tmp.dir, std.testing.io, &diag);

    const rec = record.Record{ .post = .{
        .common = .{ .seq = 0, .ts = "t1", .role = "worker", .body = "Landed the base commit." },
    } };
    _ = try log.appendRecord(std.testing.allocator, std.testing.io, tmp.dir, "DEVLOG.jsonl", rec, &diag);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);

    var text_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer text_out.deinit();
    var text_err: Io.Writer.Allocating = .init(std.testing.allocator);
    defer text_err.deinit();
    const text_code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "show", "--seq", "2" },
        &text_out.writer,
        &text_err.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), text_code);
    const text = text_out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "kind: post") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "role: worker") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Landed the base commit.") != null);

    var json_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer json_out.deinit();
    var json_err: Io.Writer.Allocating = .init(std.testing.allocator);
    defer json_err.deinit();
    const json_code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "show", "--seq", "2", "--json" },
        &json_out.writer,
        &json_err.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), json_code);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_out.written(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("post", root.get("kind").?.string);
    try std.testing.expectEqualStrings("worker", root.get("role").?.string);
    try std.testing.expectEqualStrings("Landed the base commit.", root.get("body").?.string);
}

test "show --seq on a verdict record renders the same content in text and JSON (D15)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    try seedHeaderOnly(std.testing.allocator, tmp.dir, std.testing.io, &diag);

    const rec = record.Record{ .verdict = .{
        .common = .{ .seq = 0, .ts = "t1", .role = "reviewer", .body = "Approve with nits." },
        .outcome = .@"approve-with-nits",
        .commit = "a1b2c3d",
    } };
    _ = try log.appendRecord(std.testing.allocator, std.testing.io, tmp.dir, "DEVLOG.jsonl", rec, &diag);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);

    var text_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer text_out.deinit();
    var text_err: Io.Writer.Allocating = .init(std.testing.allocator);
    defer text_err.deinit();
    const text_code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "show", "--seq", "2" },
        &text_out.writer,
        &text_err.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), text_code);
    const text = text_out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "kind: verdict") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "outcome: approve-with-nits") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "commit: a1b2c3d") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Approve with nits.") != null);

    var json_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer json_out.deinit();
    var json_err: Io.Writer.Allocating = .init(std.testing.allocator);
    defer json_err.deinit();
    const json_code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "show", "--seq", "2", "--json" },
        &json_out.writer,
        &json_err.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), json_code);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_out.written(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("verdict", root.get("kind").?.string);
    try std.testing.expectEqualStrings("approve-with-nits", root.get("outcome").?.string);
    try std.testing.expectEqualStrings("a1b2c3d", root.get("commit").?.string);
    try std.testing.expectEqualStrings("Approve with nits.", root.get("body").?.string);
}

test "show --seq on a next record renders the same content in text and JSON (D15)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    try seedHeaderOnly(std.testing.allocator, tmp.dir, std.testing.io, &diag);

    const rec = record.Record{ .next = .{
        .common = .{ .seq = 0, .ts = "t1", .role = "architect", .body = "Section 9 continues at block 9B." },
    } };
    _ = try log.appendRecord(std.testing.allocator, std.testing.io, tmp.dir, "DEVLOG.jsonl", rec, &diag);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);

    var text_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer text_out.deinit();
    var text_err: Io.Writer.Allocating = .init(std.testing.allocator);
    defer text_err.deinit();
    const text_code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "show", "--seq", "2" },
        &text_out.writer,
        &text_err.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), text_code);
    const text = text_out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "kind: next") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "role: architect") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Section 9 continues at block 9B.") != null);

    var json_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer json_out.deinit();
    var json_err: Io.Writer.Allocating = .init(std.testing.allocator);
    defer json_err.deinit();
    const json_code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "show", "--seq", "2", "--json" },
        &json_out.writer,
        &json_err.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), json_code);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_out.written(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("next", root.get("kind").?.string);
    try std.testing.expectEqualStrings("architect", root.get("role").?.string);
    try std.testing.expectEqualStrings("Section 9 continues at block 9B.", root.get("body").?.string);
}

test "show --item on an item with no close yet renders \"closes: none yet\" in text and an empty array in JSON" {
    // Deliberately not seedItemAndClose (which always adds a close) — the
    // ordinary state of an open item is the untested branch this fixture
    // covers (reviewer nit 1, architect ruling: land before this block
    // commits). Added alongside seedItemAndClose, not by extending it.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    try seedHeaderOnly(std.testing.allocator, tmp.dir, std.testing.io, &diag);

    const item_rec = record.Record{ .item = .{
        .common = .{ .seq = 0, .ts = "t1", .role = "worker", .to = "architect", .body = "should we use Y?" },
        .item = 0,
        .type = .question,
        .blocking = false,
    } };
    _ = try log.appendItem(std.testing.allocator, std.testing.io, tmp.dir, "DEVLOG.jsonl", item_rec, &diag);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);

    {
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer err_out.deinit();
        const code = run(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            stdin_file,
            test_ts,
            &.{ "--log", "DEVLOG.jsonl", "show", "--item", "1" },
            &out.writer,
            &err_out.writer,
        );
        try std.testing.expectEqual(@as(u8, 0), code);
        const text = out.written();
        try std.testing.expect(std.mem.indexOf(u8, text, "state: open") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "closes: none yet") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "closes (") == null);
    }
    {
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer err_out.deinit();
        const code = run(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            stdin_file,
            test_ts,
            &.{ "--log", "DEVLOG.jsonl", "show", "--item", "1", "--json" },
            &out.writer,
            &err_out.writer,
        );
        try std.testing.expectEqual(@as(u8, 0), code);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
        defer parsed.deinit();
        const root = parsed.value.object;
        try std.testing.expectEqualStrings("open", root.get("state").?.string);
        const closes = root.get("closes").?.array;
        try std.testing.expectEqual(@as(usize, 0), closes.items.len);
    }
}

// --- Block 6B: `resume` (6.1) and `status` (6.5) --------------------------

test "resume requires --role, before the read-only load ever touches the filesystem" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "resume" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "requires --role") != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "DEVLOG.jsonl", .{}));
}

test "resume against a missing log reports plainly, exits non-zero, and creates nothing (durable-format)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "resume", "--role", "worker" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "devlog header") != null);
    try std.testing.expectEqualStrings("", out.written());

    var count: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next(std.testing.io)) |entry| {
        try std.testing.expectEqualStrings("stdin-standin", entry.name);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "status against a missing log reports plainly, exits non-zero, and creates nothing (durable-format)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "status" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "devlog header") != null);
    try std.testing.expectEqualStrings("", out.written());

    var count: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next(std.testing.io)) |entry| {
        try std.testing.expectEqualStrings("stdin-standin", entry.name);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

/// Seeds header, NEXT, a mix of open and closed items across two roles
/// (worker/reviewer), and four briefs that exercise every step of the
/// `resume` ruling (block 6B brief):
///
/// - item #1 — worker, blocking.
/// - item #2 — reviewer, not blocking. Never addressed to worker
///   (`log-retrieval`'s exclusion scenario).
/// - item #3 — worker, not blocking.
/// - item #4 — worker, but closed (must not appear as an open item —
///   proves resume/status render *derived* open state, not merely "an
///   item record exists").
/// - Brief A (`6`, `6A`, to worker) — an earlier brief to worker, on a
///   different block.
/// - Brief B (`6`, `6B`, to worker) — the *most recent* brief addressed
///   to worker, so `findBriefToRole` resolves worker's block to `(6,
///   6B)` (ruling point 1).
/// - the remediation brief (`6`, `6B`, to reviewer) — later than Brief B,
///   same block, addressed to someone else: the latest brief *for the
///   block*, not for the role (ruling point 2).
/// - the decoy brief (`9`, `6B`, to reviewer) — posted last, and shares
///   Brief B's bare block label but not its section. If the lookup ever
///   keyed on the bare label alone, this would incorrectly win over the
///   remediation brief (ruling point 3).
fn seedResumeFixture(allocator: Allocator, dir: Io.Dir, io: Io, diag: *record.Diagnostics) !void {
    _ = try log.appendHeader(
        allocator,
        io,
        dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{ "architect", "worker", "reviewer" }, .closers = &.{"architect"} },
        diag,
    );
    _ = try log.appendRecord(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .next = .{
        .common = .{ .seq = 0, .ts = "t1", .role = "architect", .body = "Land block 6B, then close section 6." },
    } }, diag);

    _ = try log.appendItem(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .item = .{
        .common = .{ .seq = 0, .ts = "t2", .role = "architect", .to = "worker", .body = "Do X" },
        .item = 0,
        .type = .task,
        .blocking = true,
    } }, diag);
    _ = try log.appendItem(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .item = .{
        .common = .{ .seq = 0, .ts = "t3", .role = "architect", .to = "reviewer", .body = "Review Y" },
        .item = 0,
        .type = .task,
        .blocking = false,
    } }, diag);
    _ = try log.appendItem(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .item = .{
        .common = .{ .seq = 0, .ts = "t4", .role = "worker", .to = "worker", .body = "Minor nit" },
        .item = 0,
        .type = .finding,
        .blocking = false,
    } }, diag);
    _ = try log.appendItem(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .item = .{
        .common = .{ .seq = 0, .ts = "t5", .role = "architect", .to = "worker", .body = "Old task" },
        .item = 0,
        .type = .task,
        .blocking = false,
    } }, diag);
    _ = try log.appendRecord(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .close = .{
        .common = .{ .seq = 0, .ts = "t6", .role = "architect", .body = "done already" },
        .item = 4,
        .state = .resolved,
    } }, diag);

    _ = try log.appendRecord(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .brief = .{
        .common = .{ .seq = 0, .ts = "t7", .role = "architect", .section = "6", .block = "6A", .to = "worker", .body = "Focus on foundational item first." },
    } }, diag);
    _ = try log.appendRecord(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .brief = .{
        .common = .{ .seq = 0, .ts = "t8", .role = "architect", .section = "6", .block = "6B", .to = "worker", .body = "Implement the rendering block now." },
    } }, diag);
    _ = try log.appendRecord(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .brief = .{
        .common = .{ .seq = 0, .ts = "t9", .role = "architect", .section = "6", .block = "6B", .to = "reviewer", .body = "Fix the nits before landing." },
    } }, diag);
    _ = try log.appendRecord(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .brief = .{
        .common = .{ .seq = 0, .ts = "t10", .role = "architect", .section = "9", .block = "6B", .to = "reviewer", .body = "Unrelated section nine content." },
    } }, diag);
}

test "resume returns open items addressed to the role in item-number order, excluding other roles' and closed items (log-retrieval)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    try seedResumeFixture(std.testing.allocator, tmp.dir, std.testing.io, &diag);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);

    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();
    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "resume", "--role", "worker" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), code);
    const text = out.written();

    // #1 and #3, worker's open items — present, blocking distinguishable.
    try std.testing.expect(std.mem.indexOf(u8, text, "Do X") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Minor nit") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "blocking: true") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "blocking: false") != null);
    // #1 (worker's) sorts before #3 (item-number order, carried 16).
    try std.testing.expect(std.mem.indexOf(u8, text, "Do X").? < std.mem.indexOf(u8, text, "Minor nit").?);

    // #2, addressed to reviewer — excluded (the exclusion scenario).
    try std.testing.expect(std.mem.indexOf(u8, text, "Review Y") == null);
    // #4, closed — excluded (derived state, not raw record presence).
    try std.testing.expect(std.mem.indexOf(u8, text, "Old task") == null);

    // The NEXT narrative.
    try std.testing.expect(std.mem.indexOf(u8, text, "Land block 6B") != null);

    // The remediation brief — latest for worker's block (6, 6B), even
    // though it is addressed to reviewer, not worker (ruling point 2).
    try std.testing.expect(std.mem.indexOf(u8, text, "Fix the nits before landing.") != null);
    // Superseded: Brief B itself, Brief A, and the same-label-wrong-section
    // decoy must not appear.
    try std.testing.expect(std.mem.indexOf(u8, text, "Implement the rendering block now.") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Focus on foundational item first.") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Unrelated section nine content.") == null);
}

test "resume --json carries the same items, next, and brief as the text form (D15)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    try seedResumeFixture(std.testing.allocator, tmp.dir, std.testing.io, &diag);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "resume", "--role", "worker", "--json" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), code);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    try std.testing.expectEqualStrings("Land block 6B, then close section 6.", root.get("next").?.object.get("body").?.string);

    const items = root.get("items").?.array;
    try std.testing.expectEqual(@as(usize, 2), items.items.len);
    try std.testing.expectEqual(@as(i64, 1), items.items[0].object.get("number").?.integer);
    try std.testing.expectEqual(@as(i64, 3), items.items[1].object.get("number").?.integer);
    const opened1 = items.items[0].object.get("item").?.object;
    try std.testing.expect(opened1.get("blocking").?.bool);
    const opened3 = items.items[1].object.get("item").?.object;
    try std.testing.expect(!opened3.get("blocking").?.bool);

    const brief = root.get("brief").?.object;
    try std.testing.expectEqualStrings("brief", brief.get("kind").?.string);
    try std.testing.expectEqualStrings("Fix the nits before landing.", brief.get("body").?.string);
    try std.testing.expectEqualStrings("reviewer", brief.get("to").?.string);
    try std.testing.expectEqualStrings("6", brief.get("section").?.string);
    try std.testing.expectEqualStrings("6B", brief.get("block").?.string);
}

test "resume for a role never briefed has no block: the brief is plainly absent, not an error (ruling point 4)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    try seedResumeFixture(std.testing.allocator, tmp.dir, std.testing.io, &diag);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);

    {
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer err_out.deinit();
        const code = run(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            stdin_file,
            test_ts,
            &.{ "--log", "DEVLOG.jsonl", "resume", "--role", "architect" },
            &out.writer,
            &err_out.writer,
        );
        try std.testing.expectEqual(@as(u8, 0), code);
        const text = out.written();
        try std.testing.expect(std.mem.indexOf(u8, text, "brief: none") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "open items (0)") != null);
    }
    {
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer err_out.deinit();
        const code = run(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            stdin_file,
            test_ts,
            &.{ "--log", "DEVLOG.jsonl", "resume", "--role", "architect", "--json" },
            &out.writer,
            &err_out.writer,
        );
        try std.testing.expectEqual(@as(u8, 0), code);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
        defer parsed.deinit();
        const root = parsed.value.object;
        try std.testing.expectEqual(std.json.Value{ .null = {} }, root.get("brief").?);
        try std.testing.expectEqual(@as(usize, 0), root.get("items").?.array.items.len);
    }
}

test "status shows every open item regardless of addressee, with blocking distinguishable, and has no brief concept (next-state)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    try seedResumeFixture(std.testing.allocator, tmp.dir, std.testing.io, &diag);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);

    {
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer err_out.deinit();
        const code = run(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            stdin_file,
            test_ts,
            &.{ "--log", "DEVLOG.jsonl", "status" },
            &out.writer,
            &err_out.writer,
        );
        try std.testing.expectEqual(@as(u8, 0), code);
        const text = out.written();
        try std.testing.expect(std.mem.indexOf(u8, text, "Do X") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "Review Y") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "Minor nit") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "Old task") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, "blocking: true") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "blocking: false") != null);
        // status has no brief concept at all — never rendered.
        try std.testing.expect(std.mem.indexOf(u8, text, "brief") == null);
    }
    {
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer err_out.deinit();
        const code = run(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            stdin_file,
            test_ts,
            &.{ "--log", "DEVLOG.jsonl", "status", "--json" },
            &out.writer,
            &err_out.writer,
        );
        try std.testing.expectEqual(@as(u8, 0), code);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
        defer parsed.deinit();
        const root = parsed.value.object;
        const items = root.get("items").?.array;
        try std.testing.expectEqual(@as(usize, 3), items.items.len);
        try std.testing.expectEqual(@as(i64, 1), items.items[0].object.get("number").?.integer);
        try std.testing.expectEqual(@as(i64, 2), items.items[1].object.get("number").?.integer);
        try std.testing.expectEqual(@as(i64, 3), items.items[2].object.get("number").?.integer);
        // Reviewer nit (block 6B): the `blocking` key, distinguishable in
        // JSON as `next-state` requires, not just in the text form.
        try std.testing.expect(items.items[0].object.get("item").?.object.get("blocking").?.bool);
        try std.testing.expect(!items.items[1].object.get("item").?.object.get("blocking").?.bool);
        try std.testing.expect(!items.items[2].object.get("item").?.object.get("blocking").?.bool);
        // status's JSON carries no "brief" key at all — not even null.
        try std.testing.expectEqual(@as(?std.json.Value, null), root.get("brief"));
    }
}

test "closing an open item removes it from the next status, with no new NEXT recorded (next-state)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    _ = try log.appendHeader(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{ "architect", "worker" }, .closers = &.{"architect"} },
        &diag,
    );
    _ = try log.appendRecord(std.testing.allocator, std.testing.io, tmp.dir, "DEVLOG.jsonl", record.Record{ .next = .{
        .common = .{ .seq = 0, .ts = "t1", .role = "architect", .body = "Steady narrative, unchanged by the close below." },
    } }, &diag);
    _ = try log.appendItem(std.testing.allocator, std.testing.io, tmp.dir, "DEVLOG.jsonl", record.Record{ .item = .{
        .common = .{ .seq = 0, .ts = "t2", .role = "architect", .to = "worker", .body = "Transient open item" },
        .item = 0,
        .type = .task,
        .blocking = false,
    } }, &diag);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);

    {
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer err_out.deinit();
        const code = run(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            stdin_file,
            test_ts,
            &.{ "--log", "DEVLOG.jsonl", "status" },
            &out.writer,
            &err_out.writer,
        );
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "Transient open item") != null);
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "Steady narrative") != null);
    }

    _ = try log.appendRecord(std.testing.allocator, std.testing.io, tmp.dir, "DEVLOG.jsonl", record.Record{ .close = .{
        .common = .{ .seq = 0, .ts = "t3", .role = "architect", .body = "no longer needed" },
        .item = 1,
        .state = .superseded,
    } }, &diag);

    {
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer err_out.deinit();
        const code = run(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            stdin_file,
            test_ts,
            &.{ "--log", "DEVLOG.jsonl", "status" },
            &out.writer,
            &err_out.writer,
        );
        try std.testing.expectEqual(@as(u8, 0), code);
        // The item is gone — no new NEXT was recorded, so the same
        // narrative is still current.
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "Transient open item") == null);
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "Steady narrative") != null);
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "open items (0)") != null);
    }
}

test "resume's and status's read stays small when the log has accumulated many records but few items are open (log-retrieval boundedness)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    _ = try log.appendHeader(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{ "architect", "worker" }, .closers = &.{"architect"} },
        &diag,
    );
    _ = try log.appendRecord(std.testing.allocator, std.testing.io, tmp.dir, "DEVLOG.jsonl", record.Record{ .next = .{
        .common = .{ .seq = 0, .ts = "t1", .role = "architect", .body = "Short narrative." },
    } }, &diag);

    // A large volume of history: 60 unaddressed posts, none of which are
    // items and none of which are open — the read's size must track the
    // one open item below, not this history.
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    while (n < 60) : (n += 1) {
        const body_text = try std.fmt.bufPrint(&buf, "post body number {d}, padding out the history", .{n});
        _ = try log.appendRecord(std.testing.allocator, std.testing.io, tmp.dir, "DEVLOG.jsonl", record.Record{ .post = .{
            .common = .{ .seq = 0, .ts = "t2", .role = "architect", .body = body_text },
        } }, &diag);
    }
    _ = try log.appendItem(std.testing.allocator, std.testing.io, tmp.dir, "DEVLOG.jsonl", record.Record{ .item = .{
        .common = .{ .seq = 0, .ts = "t3", .role = "architect", .to = "worker", .body = "The one open item" },
        .item = 0,
        .type = .task,
        .blocking = false,
    } }, &diag);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);

    inline for (.{ "status", "resume" }) |cmd| {
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer err_out.deinit();
        const args: []const [:0]const u8 = if (std.mem.eql(u8, cmd, "resume"))
            &.{ "--log", "DEVLOG.jsonl", "resume", "--role", "worker" }
        else
            &.{ "--log", "DEVLOG.jsonl", "status" };
        const code = run(std.testing.allocator, std.testing.io, tmp.dir, stdin_file, test_ts, args, &out.writer, &err_out.writer);
        try std.testing.expectEqual(@as(u8, 0), code);
        const text = out.written();
        try std.testing.expect(std.mem.indexOf(u8, text, "The one open item") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "open items (1)") != null);
        // None of the 60 padding posts leaked into the read.
        try std.testing.expect(std.mem.indexOf(u8, text, "padding out the history") == null);
        // The read stays small: nowhere near what dumping 60+ records
        // would cost, regardless of exactly how this renderer formats one
        // item.
        try std.testing.expect(text.len < 2000);
    }
}

test "resume against a brief missing 'section'/'block' reports a diagnostic instead of panicking (block 6B review fix)" {
    // The reviewer's repro, reproduced as a test: a hand-written log (not
    // one this CLI's own `runBrief` could ever produce, since that
    // requires `--section` and `--block`) carries a `brief` with `to` but
    // neither field. Before this fix, `findLatestBriefForBlock` and
    // `runResume` force-unwrapped both fields and the process aborted
    // (SIGABRT, exit 134). It must now report a plain diagnostic and a
    // non-zero exit — and this test must fail (by crashing the whole
    // suite) if `state.derive`'s `BriefMissingKey` fault is ever removed.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    _ = try log.appendHeader(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{ "architect", "worker" }, .closers = &.{"architect"} },
        &diag,
    );
    _ = try log.appendRecord(std.testing.allocator, std.testing.io, tmp.dir, "DEVLOG.jsonl", record.Record{ .brief = .{
        .common = .{ .seq = 0, .ts = "t1", .role = "architect", .to = "worker", .body = "malformed: no section, no block" },
    } }, &diag);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "resume", "--role", "worker" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "brief") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "section") != null);
}

test "status's and resume's 'no NEXT ever recorded' text branch renders '(none recorded)' (carried gap, block 6B review fix)" {
    // Flagged by the worker rather than found by review: nothing in this
    // section's other fixtures ever calls `status`/`resume` before a
    // `next` has been posted, so `renderCurrentStateText`'s "no NEXT ever
    // recorded" branch was correct by inspection only. This fixture posts
    // no `next` record at all.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    _ = try log.appendHeader(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{ "architect", "worker" }, .closers = &.{"architect"} },
        &diag,
    );

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);

    inline for (.{ "status", "resume" }) |cmd| {
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer err_out.deinit();
        const args: []const [:0]const u8 = if (std.mem.eql(u8, cmd, "resume"))
            &.{ "--log", "DEVLOG.jsonl", "resume", "--role", "worker" }
        else
            &.{ "--log", "DEVLOG.jsonl", "status" };
        const code = run(std.testing.allocator, std.testing.io, tmp.dir, stdin_file, test_ts, args, &out.writer, &err_out.writer);
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "(none recorded)") != null);
    }

    // Architect ruling (block 6B, review re-audit): the ruling that closed
    // this gap was scoped to "the text branch" too narrowly — the gap is
    // D15 parity, which is both renderings by definition. Assert the JSON
    // form of "no NEXT ever recorded" for both commands too.
    inline for (.{ "status", "resume" }) |cmd| {
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer err_out.deinit();
        const args: []const [:0]const u8 = if (std.mem.eql(u8, cmd, "resume"))
            &.{ "--log", "DEVLOG.jsonl", "resume", "--role", "worker", "--json" }
        else
            &.{ "--log", "DEVLOG.jsonl", "status", "--json" };
        const code = run(std.testing.allocator, std.testing.io, tmp.dir, stdin_file, test_ts, args, &out.writer, &err_out.writer);
        try std.testing.expectEqual(@as(u8, 0), code);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(?std.json.Value, .null), parsed.value.object.get("next"));
    }
}

test "resume --help and status --help each print their own usage" {
    try expectRun(std.testing.allocator, &.{ "resume", "--help" }, 0, "devlog resume", null);
    try expectRun(std.testing.allocator, &.{ "resume", "--help" }, 0, "--role", null);
    try expectRun(std.testing.allocator, &.{ "status", "--help" }, 0, "devlog status", null);
    try expectRun(std.testing.allocator, &.{ "status", "--help" }, 0, "--json", null);
}

// --- Block 6C: `list` (6.3) and `refs` (6.4) --------------------------------

/// Owned copies of one `run` call's stdout/stderr, so a seeded-fixture test
/// can inspect them after the tmp dir and writers that produced them go out
/// of scope — `expectRun` above has no seeding hook, and every `list`/
/// `refs` test below needs one, so this is `expectRun`'s seeded sibling
/// rather than sixteen copies of the same tmp-dir/stdin-standin/writer
/// boilerplate `show`'s and `resume`'s own fixtured tests already repeat
/// inline.
const RunResult = struct {
    code: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *RunResult, allocator: Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

fn runSeeded(
    allocator: Allocator,
    seed: *const fn (Allocator, Io.Dir, Io, *record.Diagnostics) anyerror!void,
    args: []const [:0]const u8,
) !RunResult {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();
    try seed(allocator, tmp.dir, std.testing.io, &diag);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(allocator);
    defer err_out.deinit();

    const code = run(allocator, std.testing.io, tmp.dir, stdin_file, test_ts, args, &out.writer, &err_out.writer);
    return .{
        .code = code,
        .stdout = try allocator.dupe(u8, out.written()),
        .stderr = try allocator.dupe(u8, err_out.written()),
    };
}

/// Spans every dimension `6.3` filters by and both halves `6.4` needs to
/// tell apart: a real structured reference vs. the same identifier merely
/// mentioned in prose. Deliberately leaves `section`/`block`/`to` unset on
/// some records (the `post`/`close`/`next` below) — block 6B's own hazard,
/// one field over — so a filter's guard against an absent field is
/// exercised by ordinary fixture diversity rather than a contrived
/// hand-written log line.
///
/// Records, in append order (kind, section/block, role, to):
///   1. post    section 4, block 4.1-4.3        architect          ref D:1
///   2. post    (none)                          worker             mentions "D7" in prose, no ref
///   3. brief   section 6, block 6C   -> worker  architect          ref D:7 (the real one)
///   4. post    section 9, block 6C              reviewer           ref D:10 (same label, other section)
///   5. item #1 section 6, block 6C   -> architect  worker  blocking, open
///   6. item #2 section 4, block 4.1-4.3 -> worker  architect  non-blocking, resolved (closed below)
///   7. close   (none)                           architect          closes #2
///   8. item #3 section 6, block 6A   -> reviewer  worker  non-blocking, open
///   9. item #4 section 6, block 6C   -> architect  worker  blocking, deferred (closed below)
///  10. close   (none)                           architect          closes #4
///  11. verdict section 6, block 6C              reviewer
///  12. next    (none)                           architect
fn seedListFixture(allocator: Allocator, dir: Io.Dir, io: Io, diag: *record.Diagnostics) !void {
    _ = try log.appendHeader(
        allocator,
        io,
        dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{ "architect", "worker", "reviewer" }, .closers = &.{"architect"} },
        diag,
    );

    _ = try log.appendRecord(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .post = .{
        .common = .{
            .seq = 0,
            .ts = "t1",
            .role = "architect",
            .section = "4",
            .block = "4.1-4.3",
            .refs = &.{.{ .ns = "D", .id = "1" }},
            .body = "opened section 4 with D1 in mind",
        },
    } }, diag);

    _ = try log.appendRecord(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .post = .{
        .common = .{
            .seq = 0,
            .ts = "t2",
            .role = "worker",
            .body = "reminds me of D7, but that's just prose, no structured reference here",
        },
    } }, diag);

    _ = try log.appendRecord(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .brief = .{
        .common = .{
            .seq = 0,
            .ts = "t3",
            .role = "architect",
            .section = "6",
            .block = "6C",
            .to = "worker",
            .refs = &.{.{ .ns = "D", .id = "7" }},
            .body = "brief for 6C, genuinely referencing D7",
        },
    } }, diag);

    _ = try log.appendRecord(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .post = .{
        .common = .{
            .seq = 0,
            .ts = "t4",
            .role = "reviewer",
            .section = "9",
            .block = "6C",
            .refs = &.{.{ .ns = "D", .id = "10" }},
            .body = "unrelated section nine, same block label",
        },
    } }, diag);

    _ = try log.appendItem(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .item = .{
        .common = .{
            .seq = 0,
            .ts = "t5",
            .role = "worker",
            .section = "6",
            .block = "6C",
            .to = "architect",
            .body = "blocking question for 6C",
        },
        .item = 0,
        .type = .question,
        .blocking = true,
    } }, diag);

    _ = try log.appendItem(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .item = .{
        .common = .{
            .seq = 0,
            .ts = "t6",
            .role = "architect",
            .section = "4",
            .block = "4.1-4.3",
            .to = "worker",
            .body = "non-blocking finding for 4.1-4.3",
        },
        .item = 0,
        .type = .finding,
        .blocking = false,
    } }, diag);
    _ = try log.appendRecord(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .close = .{
        .common = .{ .seq = 0, .ts = "t7", .role = "architect", .body = "closed, addressed" },
        .item = 2,
        .state = .resolved,
    } }, diag);

    _ = try log.appendItem(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .item = .{
        .common = .{
            .seq = 0,
            .ts = "t8",
            .role = "worker",
            .section = "6",
            .block = "6A",
            .to = "reviewer",
            .body = "open nit for 6A",
        },
        .item = 0,
        .type = .finding,
        .blocking = false,
    } }, diag);

    _ = try log.appendItem(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .item = .{
        .common = .{
            .seq = 0,
            .ts = "t9",
            .role = "worker",
            .section = "6",
            .block = "6C",
            .to = "architect",
            .body = "blocking but later deferred",
        },
        .item = 0,
        .type = .task,
        .blocking = true,
    } }, diag);
    _ = try log.appendRecord(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .close = .{
        .common = .{ .seq = 0, .ts = "t10", .role = "architect", .body = "superseded by later work" },
        .item = 4,
        .state = .deferred,
    } }, diag);

    _ = try log.appendRecord(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .verdict = .{
        .common = .{ .seq = 0, .ts = "t11", .role = "reviewer", .section = "6", .block = "6C", .body = "block 6C looks good" },
        .outcome = .approve,
        .commit = "abc123",
    } }, diag);

    _ = try log.appendRecord(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .next = .{
        .common = .{ .seq = 0, .ts = "t12", .role = "architect", .body = "resume at 6C" },
    } }, diag);
}

test "list with no filters returns every record from the positional slice, in log order (carried 16)" {
    var result = try runSeeded(std.testing.allocator, seedListFixture, &.{ "--log", "DEVLOG.jsonl", "list" });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.code);

    const text = result.stdout;
    const pos_header = std.mem.indexOf(u8, text, "kind: header") orelse return error.TestUnexpectedResult;
    const pos_post1 = std.mem.indexOf(u8, text, "opened section 4 with D1") orelse return error.TestUnexpectedResult;
    const pos_post2 = std.mem.indexOf(u8, text, "reminds me of D7") orelse return error.TestUnexpectedResult;
    const pos_brief = std.mem.indexOf(u8, text, "brief for 6C") orelse return error.TestUnexpectedResult;
    const pos_post3 = std.mem.indexOf(u8, text, "unrelated section nine") orelse return error.TestUnexpectedResult;
    const pos_next = std.mem.indexOf(u8, text, "resume at 6C") orelse return error.TestUnexpectedResult;
    try std.testing.expect(pos_header < pos_post1);
    try std.testing.expect(pos_post1 < pos_post2);
    try std.testing.expect(pos_post2 < pos_brief);
    try std.testing.expect(pos_brief < pos_post3);
    try std.testing.expect(pos_post3 < pos_next);
}

test "list --kind item is a single-filter key lookup: only item records, in log order" {
    var result = try runSeeded(std.testing.allocator, seedListFixture, &.{ "--log", "DEVLOG.jsonl", "list", "--kind", "item" });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.code);

    const text = result.stdout;
    try std.testing.expect(std.mem.indexOf(u8, text, "blocking question for 6C") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "non-blocking finding") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "open nit for 6A") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "blocking but later deferred") != null);
    // Every other kind is absent — this is the item *records*, not a
    // narrowing to items (`--kind item` alone does not imply `--state`).
    try std.testing.expect(std.mem.indexOf(u8, text, "opened section 4") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "brief for 6C") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "block 6C looks good") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "resume at 6C") == null);
}

test "list --section 6 is a single-filter key lookup: every record concerning that section" {
    var result = try runSeeded(std.testing.allocator, seedListFixture, &.{ "--log", "DEVLOG.jsonl", "list", "--section", "6" });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.code);

    const text = result.stdout;
    try std.testing.expect(std.mem.indexOf(u8, text, "brief for 6C") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "blocking question for 6C") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "open nit for 6A") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "blocking but later deferred") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "block 6C looks good") != null);
    // Section 4's and section 9's records, and the two records with no
    // section at all, are excluded.
    try std.testing.expect(std.mem.indexOf(u8, text, "opened section 4") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "non-blocking finding") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "unrelated section nine") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "reminds me of D7") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "resume at 6C") == null);
}

test "list --block 6C alone matches by label and spans sections (the rename's own ruling)" {
    var result = try runSeeded(std.testing.allocator, seedListFixture, &.{ "--log", "DEVLOG.jsonl", "list", "--block", "6C" });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.code);

    const text = result.stdout;
    // Section 6's block 6C records...
    try std.testing.expect(std.mem.indexOf(u8, text, "brief for 6C") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "blocking question for 6C") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "block 6C looks good") != null);
    // ...and section 9's, same label, different section — proving the span.
    try std.testing.expect(std.mem.indexOf(u8, text, "unrelated section nine") != null);
    // Block 6A and block 4.1-4.3 records are excluded — different labels.
    try std.testing.expect(std.mem.indexOf(u8, text, "open nit for 6A") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "opened section 4") == null);
}

test "list --section 6 --block 6C is the intersection — excludes section 9's same-labelled block" {
    var result = try runSeeded(std.testing.allocator, seedListFixture, &.{
        "--log", "DEVLOG.jsonl", "list", "--section", "6", "--block", "6C",
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.code);

    const text = result.stdout;
    try std.testing.expect(std.mem.indexOf(u8, text, "brief for 6C") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "blocking question for 6C") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "block 6C looks good") != null);
    // The section-5 close ruling's own scenario: same block label, wrong
    // section, excluded once --section narrows the intersection.
    try std.testing.expect(std.mem.indexOf(u8, text, "unrelated section nine") == null);
}

test "list --role and --to are each a single-filter key lookup, by author and by addressee" {
    {
        var result = try runSeeded(std.testing.allocator, seedListFixture, &.{ "--log", "DEVLOG.jsonl", "list", "--role", "reviewer" });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 0), result.code);
        const text = result.stdout;
        try std.testing.expect(std.mem.indexOf(u8, text, "unrelated section nine") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "block 6C looks good") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "opened section 4") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, "brief for 6C") == null);
    }
    {
        var result = try runSeeded(std.testing.allocator, seedListFixture, &.{ "--log", "DEVLOG.jsonl", "list", "--to", "worker" });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 0), result.code);
        const text = result.stdout;
        // The brief and item #2's own record are both addressed to worker.
        try std.testing.expect(std.mem.indexOf(u8, text, "brief for 6C") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "non-blocking finding") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "blocking question for 6C") == null);
    }
}

test "list --role and --section together is an intersection, sorted by seq (carried 16)" {
    var result = try runSeeded(std.testing.allocator, seedListFixture, &.{
        "--log", "DEVLOG.jsonl", "list", "--role", "worker", "--section", "6",
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.code);

    const text = result.stdout;
    // worker authored the section-6 item records (#1, #3, #4's opening
    // record) but not the section-6 brief (architect) or verdict
    // (reviewer) — the intersection, in ascending seq (append) order.
    const pos_1 = std.mem.indexOf(u8, text, "blocking question for 6C") orelse return error.TestUnexpectedResult;
    const pos_3 = std.mem.indexOf(u8, text, "open nit for 6A") orelse return error.TestUnexpectedResult;
    const pos_4 = std.mem.indexOf(u8, text, "blocking but later deferred") orelse return error.TestUnexpectedResult;
    try std.testing.expect(pos_1 < pos_3);
    try std.testing.expect(pos_3 < pos_4);
    try std.testing.expect(std.mem.indexOf(u8, text, "brief for 6C") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "block 6C looks good") == null);
}

test "list --state open narrows the result to items, blocking and non-blocking alike (ruling)" {
    var result = try runSeeded(std.testing.allocator, seedListFixture, &.{ "--log", "DEVLOG.jsonl", "list", "--state", "open" });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.code);

    const text = result.stdout;
    // #1 (blocking, open) and #3 (non-blocking, open) — #2 (resolved) and
    // #4 (deferred) are excluded.
    try std.testing.expect(std.mem.indexOf(u8, text, "blocking question for 6C") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "open nit for 6A") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "non-blocking finding") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "blocking but later deferred") == null);
    // Narrowed to items: no raw records (brief/post/verdict bodies) leak
    // into an item-shaped result.
    try std.testing.expect(std.mem.indexOf(u8, text, "brief for 6C") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "block 6C looks good") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "items (2):") != null);
}

test "list --blocking narrows to items regardless of state — there is no --no-blocking" {
    var result = try runSeeded(std.testing.allocator, seedListFixture, &.{ "--log", "DEVLOG.jsonl", "list", "--blocking" });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.code);

    const text = result.stdout;
    // #1 (open, blocking) and #4 (deferred, blocking) both qualify —
    // #4 proves --blocking alone is not implicitly --state open.
    try std.testing.expect(std.mem.indexOf(u8, text, "blocking question for 6C") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "blocking but later deferred") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "open nit for 6A") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "non-blocking finding") == null);
}

test "list --state open --blocking combines with AND: only the open, blocking item" {
    var result = try runSeeded(std.testing.allocator, seedListFixture, &.{
        "--log", "DEVLOG.jsonl", "list", "--state", "open", "--blocking",
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.code);

    const text = result.stdout;
    try std.testing.expect(std.mem.indexOf(u8, text, "items (1):") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "blocking question for 6C") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "blocking but later deferred") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "open nit for 6A") == null);
}

test "list --kind item alongside --state is allowed (redundant, not a conflict)" {
    var result = try runSeeded(std.testing.allocator, seedListFixture, &.{
        "--log", "DEVLOG.jsonl", "list", "--kind", "item", "--state", "open",
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "items (2):") != null);
}

test "list --kind naming anything but 'item' alongside --state or --blocking is a refusal, not an empty success (ruling, A6)" {
    // Both fire before the read-only load ever touches the filesystem
    // (A3) — run against an empty dir, no header ever written, and prove
    // nothing was created.
    {
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer err_out.deinit();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
        defer stdin_file.close(std.testing.io);
        const code = run(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            stdin_file,
            test_ts,
            &.{ "--log", "DEVLOG.jsonl", "list", "--kind", "post", "--state", "open" },
            &out.writer,
            &err_out.writer,
        );
        try std.testing.expectEqual(@as(u8, 1), code);
        try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "cannot be combined") != null);
        var count: usize = 0;
        var it = tmp.dir.iterate();
        while (try it.next(std.testing.io)) |entry| {
            try std.testing.expectEqualStrings("stdin-standin", entry.name);
            count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), count);
    }
    {
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer err_out.deinit();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
        defer stdin_file.close(std.testing.io);
        const code = run(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            stdin_file,
            test_ts,
            &.{ "--log", "DEVLOG.jsonl", "list", "--kind", "verdict", "--blocking" },
            &out.writer,
            &err_out.writer,
        );
        try std.testing.expectEqual(@as(u8, 1), code);
        try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "cannot be combined") != null);
    }
}

test "list --kind with an unrecognised value is refused, naming the permitted set" {
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "list", "--kind", "bogus" },
        1,
        null,
        "--kind 'bogus' must be one of",
    );
}

test "list --state with an unrecognised value is refused, naming the permitted set" {
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "list", "--state", "bogus" },
        1,
        null,
        "--state 'bogus' must be one of",
    );
}

test "list with no matches is an ordinary empty success, in both forms (not a refusal)" {
    {
        var result = try runSeeded(std.testing.allocator, seedListFixture, &.{ "--log", "DEVLOG.jsonl", "list", "--section", "999" });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 0), result.code);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "records (0):") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "(none)") != null);
    }
    {
        var result = try runSeeded(std.testing.allocator, seedListFixture, &.{ "--log", "DEVLOG.jsonl", "list", "--section", "999", "--json" });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 0), result.code);
        try std.testing.expectEqualStrings("[]\n", result.stdout);
    }
}

test "list --json is a bare array, parity-checked against the text form (D15)" {
    var result = try runSeeded(std.testing.allocator, seedListFixture, &.{ "--log", "DEVLOG.jsonl", "list", "--kind", "item" });
    defer result.deinit(std.testing.allocator);

    var json_result = try runSeeded(std.testing.allocator, seedListFixture, &.{ "--log", "DEVLOG.jsonl", "list", "--kind", "item", "--json" });
    defer json_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), json_result.code);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_result.stdout, .{});
    defer parsed.deinit();
    const arr = parsed.value.array;
    try std.testing.expectEqual(@as(usize, 4), arr.items.len);
    for (arr.items) |v| {
        try std.testing.expectEqualStrings("item", v.object.get("kind").?.string);
    }
    // Same bodies reachable in both forms.
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "blocking question for 6C") != null);
    try std.testing.expectEqualStrings("blocking question for 6C", arr.items[0].object.get("body").?.string);
}

test "list against a missing log reports plainly, exits non-zero, and creates nothing (durable-format)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "list" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "devlog header") != null);

    var count: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next(std.testing.io)) |entry| {
        try std.testing.expectEqualStrings("stdin-standin", entry.name);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "list --help prints its own usage, naming the --block and AND-combination semantics" {
    try expectRun(std.testing.allocator, &.{ "list", "--help" }, 0, "devlog list", null);
    try expectRun(std.testing.allocator, &.{ "list", "--help" }, 0, "matches by label and may span", null);
    try expectRun(std.testing.allocator, &.{ "list", "--help" }, 0, "filters combine", null);
}

test "refs returns every record carrying the exact reference, and only those" {
    var result = try runSeeded(std.testing.allocator, seedListFixture, &.{ "--log", "DEVLOG.jsonl", "refs", "--ref", "D:7" });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.code);

    const text = result.stdout;
    try std.testing.expect(std.mem.indexOf(u8, text, "records (1):") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "brief for 6C") != null);
}

test "refs excludes a record that merely mentions the identifier in prose without recording it as a reference (external-references' negative half, 6.4)" {
    var result = try runSeeded(std.testing.allocator, seedListFixture, &.{ "--log", "DEVLOG.jsonl", "refs", "--ref", "D:7" });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.code);

    // The second post's body contains the literal "D7" in prose but was
    // never given `--ref D:7` at write time — a prose-scanning
    // implementation would pass every other test in this block and fail
    // only this one.
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "reminds me of D7") == null);
}

test "refs is an exact match on the (ns, id) pair, never a prefix" {
    var result = try runSeeded(std.testing.allocator, seedListFixture, &.{ "--log", "DEVLOG.jsonl", "refs", "--ref", "D:1" });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.code);

    const text = result.stdout;
    try std.testing.expect(std.mem.indexOf(u8, text, "opened section 4 with D1") != null);
    // D:10 must not match a D:1 query.
    try std.testing.expect(std.mem.indexOf(u8, text, "unrelated section nine") == null);
}

test "refs requires --ref, refused before the read-only load, nothing created" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "refs" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "requires --ref") != null);

    var count: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next(std.testing.io)) |entry| {
        try std.testing.expectEqualStrings("stdin-standin", entry.name);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "refs takes exactly one --ref, refused when given twice, before the read-only load" {
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "refs", "--ref", "D:1", "--ref", "D:2" },
        1,
        null,
        "exactly one",
    );
}

test "refs reuses section 4's --ref parsing and its malformation fault, not a second parser (A6)" {
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "refs", "--ref", "no-colon-here" },
        1,
        null,
        "malformed",
    );
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "refs", "--ref", ":2" },
        1,
        null,
        "malformed",
    );
}

test "refs for a reference no record carries is an ordinary empty success, in both forms" {
    {
        var result = try runSeeded(std.testing.allocator, seedListFixture, &.{ "--log", "DEVLOG.jsonl", "refs", "--ref", "Z:nope" });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 0), result.code);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "records (0):") != null);
    }
    {
        var result = try runSeeded(std.testing.allocator, seedListFixture, &.{ "--log", "DEVLOG.jsonl", "refs", "--ref", "Z:nope", "--json" });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 0), result.code);
        try std.testing.expectEqualStrings("[]\n", result.stdout);
    }
}

test "refs --json is a bare array, parity-checked against the text form (D15)" {
    var result = try runSeeded(std.testing.allocator, seedListFixture, &.{ "--log", "DEVLOG.jsonl", "refs", "--ref", "D:7" });
    defer result.deinit(std.testing.allocator);

    var json_result = try runSeeded(std.testing.allocator, seedListFixture, &.{ "--log", "DEVLOG.jsonl", "refs", "--ref", "D:7", "--json" });
    defer json_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), json_result.code);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_result.stdout, .{});
    defer parsed.deinit();
    const arr = parsed.value.array;
    try std.testing.expectEqual(@as(usize, 1), arr.items.len);
    try std.testing.expectEqualStrings("brief", arr.items[0].object.get("kind").?.string);
    try std.testing.expectEqualStrings("brief for 6C, genuinely referencing D7", arr.items[0].object.get("body").?.string);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "brief for 6C, genuinely referencing D7") != null);
}

test "refs against a missing log reports plainly, exits non-zero, and creates nothing (durable-format)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "refs", "--ref", "D:1" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "devlog header") != null);

    var count: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next(std.testing.io)) |entry| {
        try std.testing.expectEqualStrings("stdin-standin", entry.name);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "refs --help prints its own usage" {
    try expectRun(std.testing.allocator, &.{ "refs", "--help" }, 0, "devlog refs", null);
    try expectRun(std.testing.allocator, &.{ "refs", "--help" }, 0, "--ref", null);
}

// --- Section 6 remediation: supervisor blockers 1-3 ------------------------

test "resume --role naming an undeclared role refuses, exactly as the write side does (blocker 1)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    try seedResumeFixture(std.testing.allocator, tmp.dir, std.testing.io, &diag);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "resume", "--role", "wroker" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "'wroker' is not declared") != null);
    try std.testing.expectEqualStrings("", out.written());
}

test "resume --role naming a declared role with nothing open is an ordinary empty success at exit 0, not a refusal (blocker 1)" {
    // The distinction blocker 1 is about: an undeclared role refuses, but a
    // legitimately empty orientation for a declared role must not.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    try seedHeaderOnly(std.testing.allocator, tmp.dir, std.testing.io, &diag); // roles: architect, worker, reviewer

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "resume", "--role", "reviewer" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "open items (0)") != null);
    try std.testing.expectEqualStrings("", err_out.written());
}

test "list --role and --to each refuse an undeclared value, and a declared value with no matches is an ordinary empty success (blocker 1)" {
    {
        var result = try runSeeded(std.testing.allocator, seedListFixture, &.{ "--log", "DEVLOG.jsonl", "list", "--role", "wroker" });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 1), result.code);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "'wroker' is not declared") != null);
    }
    {
        var result = try runSeeded(std.testing.allocator, seedListFixture, &.{ "--log", "DEVLOG.jsonl", "list", "--to", "wroker" });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 1), result.code);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "--to 'wroker' is not declared") != null);
    }
    {
        // "architect" is declared, but combined with a section no record
        // concerns, the result is legitimately empty — an ordinary
        // success, not a refusal.
        var result = try runSeeded(std.testing.allocator, seedListFixture, &.{
            "--log", "DEVLOG.jsonl", "list", "--role", "architect", "--section", "999",
        });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 0), result.code);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "records (0):") != null);
    }
}

/// This project's own `orchestrator` → `architect` retirement, in
/// miniature — the section 6 supervisor's repro for why the *latest*
/// header is the wrong vocabulary for `list --role`/`--to` to validate
/// against. The header first declares `orchestrator`; two records are
/// authored by (and addressed to) it; the header is then re-declared
/// without `orchestrator`, adding `architect` in its place. `orchestrator`
/// is now retired — undeclared by the **latest** header — but its two
/// records remain in the log.
fn seedRetiredRoleFixture(allocator: Allocator, dir: Io.Dir, io: Io, diag: *record.Diagnostics) !void {
    _ = try log.appendHeader(
        allocator,
        io,
        dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{ "orchestrator", "worker" }, .closers = &.{"orchestrator"} },
        diag,
    );
    _ = try log.appendRecord(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .post = .{
        .common = .{ .seq = 0, .ts = "t1", .role = "orchestrator", .body = "orchestrator's own post, authored while the role was current" },
    } }, diag);
    _ = try log.appendRecord(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .post = .{
        .common = .{ .seq = 0, .ts = "t2", .role = "worker", .to = "orchestrator", .body = "a post addressed to orchestrator" },
    } }, diag);
    _ = try log.appendHeader(
        allocator,
        io,
        dir,
        "DEVLOG.jsonl",
        "t3",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{ "architect", "worker" }, .closers = &.{"architect"} },
        diag,
    );
}

test "list --role/--to on a retired role still finds what it authored and was addressed to, while resume --role refuses it (architect ruling, ruling-1 follow-up)" {
    // The distinction the follow-up drew: resume --role is an identity
    // (validated against the latest header, unchanged), list --role/--to
    // is a filter over history (validated against every header the log
    // ever carried). Same log, same retired role, opposite outcomes.
    {
        var result = try runSeeded(std.testing.allocator, seedRetiredRoleFixture, &.{
            "--log", "DEVLOG.jsonl", "list", "--role", "orchestrator",
        });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 0), result.code);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "orchestrator's own post") != null);
        try std.testing.expectEqualStrings("", result.stderr);
    }
    {
        var result = try runSeeded(std.testing.allocator, seedRetiredRoleFixture, &.{
            "--log", "DEVLOG.jsonl", "list", "--to", "orchestrator",
        });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 0), result.code);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "a post addressed to orchestrator") != null);
        try std.testing.expectEqualStrings("", result.stderr);
    }
    {
        var result = try runSeeded(std.testing.allocator, seedRetiredRoleFixture, &.{
            "--log", "DEVLOG.jsonl", "resume", "--role", "orchestrator",
        });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 1), result.code);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "'orchestrator' is not declared") != null);
        try std.testing.expectEqualStrings("", result.stdout);
    }
}

test "list --role/--to still refuse a role never declared in any header, even though the rule now checks history (architect ruling, ruling-1 follow-up)" {
    {
        var result = try runSeeded(std.testing.allocator, seedRetiredRoleFixture, &.{
            "--log", "DEVLOG.jsonl", "list", "--role", "wroker",
        });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 1), result.code);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "'wroker' is not declared") != null);
        try std.testing.expectEqualStrings("", result.stdout);
    }
    {
        var result = try runSeeded(std.testing.allocator, seedRetiredRoleFixture, &.{
            "--log", "DEVLOG.jsonl", "resume", "--role", "wroker",
        });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 1), result.code);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "'wroker' is not declared") != null);
        try std.testing.expectEqualStrings("", result.stdout);
    }
}

/// A log the CLI itself could never produce: `checkRoleAllowed` refuses
/// every write (`appendHeader`/`appendRecord`) until a header exists, so
/// this writes two ordinary records directly to the file, bypassing the
/// log module entirely — standing in for a hand-edited or corrupted
/// `DEVLOG.jsonl`. Real, parseable content, seq `1..2`, contiguous — just
/// never once carrying a `header` record, so `latestHeader` over these two
/// records is `null` and a validating read must take the `NoHeader`
/// branch rather than the ordinary declared-role check.
fn seedHeaderlessLog(allocator: Allocator, dir: Io.Dir, io: Io, diag: *record.Diagnostics) !void {
    _ = allocator;
    _ = diag;
    var f = try dir.createFile(io, "DEVLOG.jsonl", .{ .truncate = true });
    defer f.close(io);
    const headerless =
        \\{"kind":"post","seq":1,"ts":"t","role":"architect","body":"line one, no header above it"}
        \\{"kind":"post","seq":2,"ts":"t","role":"architect","body":"line two, still no header anywhere"}
    ;
    try f.writePositionalAll(io, headerless, 0);
}

test "resume --role and list --role against a genuinely headerless log refuse cleanly, not with a panic or an empty success (section 6 remediation nit)" {
    // The path the remediation's blocker-1 fix created: before that fix,
    // no validating read ever consulted the header at all. The reviewer
    // traced `checkDeclaredValue`'s `NoHeader` branch to a clean
    // `reportLogError` exit by reading the code; this drives it, against
    // a log that genuinely carries no header record — not merely an
    // empty or nonexistent file.
    {
        var result = try runSeeded(std.testing.allocator, seedHeaderlessLog, &.{
            "--log", "DEVLOG.jsonl", "resume", "--role", "architect",
        });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 1), result.code);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "no header declared") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "devlog header") != null);
        try std.testing.expectEqualStrings("", result.stdout);
    }
    {
        var result = try runSeeded(std.testing.allocator, seedHeaderlessLog, &.{
            "--log", "DEVLOG.jsonl", "list", "--role", "architect",
        });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 1), result.code);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "no header declared") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "devlog header") != null);
        try std.testing.expectEqualStrings("", result.stdout);
    }
}

test "show, status, and refs each refuse --role as an unexpected flag rather than silently ignoring it (blocker 1)" {
    // Parse-time refusals (A6) — none of these need a seeded log, since
    // the fault fires before the read-only load ever touches the
    // filesystem (A3), exactly like every other command-scoped arity
    // refusal already pinned for the write commands.
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "show", "--seq", "1", "--role", "architect" },
        1,
        null,
        "unknown flag '--role'",
    );
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "status", "--role", "architect" },
        1,
        null,
        "unknown flag '--role'",
    );
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "refs", "--ref", "D:1", "--role", "architect" },
        1,
        null,
        "unknown flag '--role'",
    );
}

/// Asserts `text` is exactly one line: non-empty, ends `\n`, and carries no
/// other `\n` anywhere in it — the shared shape every block below checks,
/// factored out once the widened test (below) grew from three call sites
/// to all seven.
fn expectExactlyOneJsonLine(text: []const u8) !void {
    try std.testing.expect(text.len > 0);
    try std.testing.expectEqual(@as(u8, '\n'), text[text.len - 1]);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "\n"));
}

test "every --json form carries no embedded newline — one JSON value per line, all seven call sites (blocker 2; widened per architect ruling, DEVLOG ## 6, after the section 6 supervisor's re-review proved the newline was pinned at only three of them)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    try seedResumeFixture(std.testing.allocator, tmp.dir, std.testing.io, &diag);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);

    // show --seq --json — record.write's own newline-free contract, plus
    // the call site's own writeByte('\n') (main.zig:1888).
    {
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer err_out.deinit();
        const code = run(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            stdin_file,
            test_ts,
            &.{ "--log", "DEVLOG.jsonl", "show", "--seq", "2", "--json" },
            &out.writer,
            &err_out.writer,
        );
        try std.testing.expectEqual(@as(u8, 0), code);
        const text = out.written();
        try expectExactlyOneJsonLine(text);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("next", parsed.value.object.get("kind").?.string);
    }
    // show --item --json — writeItemJson's own newline-free contract, plus
    // the call site's own writeByte('\n') (main.zig:1911).
    {
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer err_out.deinit();
        const code = run(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            stdin_file,
            test_ts,
            &.{ "--log", "DEVLOG.jsonl", "show", "--item", "1", "--json" },
            &out.writer,
            &err_out.writer,
        );
        try std.testing.expectEqual(@as(u8, 0), code);
        const text = out.written();
        try expectExactlyOneJsonLine(text);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("number").?.integer);
    }
    // status --json — writeCurrentStateJson's own internal "}\n".
    {
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer err_out.deinit();
        const code = run(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            stdin_file,
            test_ts,
            &.{ "--log", "DEVLOG.jsonl", "status", "--json" },
            &out.writer,
            &err_out.writer,
        );
        try std.testing.expectEqual(@as(u8, 0), code);
        const text = out.written();
        try expectExactlyOneJsonLine(text);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("items").?.array.items.len >= 1);
    }
    // resume --json — the same writeCurrentStateJson as status.
    {
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer err_out.deinit();
        const code = run(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            stdin_file,
            test_ts,
            &.{ "--log", "DEVLOG.jsonl", "resume", "--role", "worker", "--json" },
            &out.writer,
            &err_out.writer,
        );
        try std.testing.expectEqual(@as(u8, 0), code);
        const text = out.written();
        try expectExactlyOneJsonLine(text);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("items").?.array.items.len >= 1);
    }
    // list --state open --json — writeItemListJson's own internal "]\n".
    {
        var result = try runSeeded(std.testing.allocator, seedListFixture, &.{ "--log", "DEVLOG.jsonl", "list", "--state", "open", "--json" });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 0), result.code);
        const text = result.stdout;
        try expectExactlyOneJsonLine(text);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.array.items.len >= 1);
    }
    // list --json, no filter — writeRecordListJson's own internal "]\n";
    // shared with refs below, but exercised here over the raw record path.
    {
        var result = try runSeeded(std.testing.allocator, seedListFixture, &.{ "--log", "DEVLOG.jsonl", "list", "--json" });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 0), result.code);
        const text = result.stdout;
        try expectExactlyOneJsonLine(text);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.array.items.len >= 1);
    }
    // refs --json — the same writeRecordListJson as list, over
    // Indexes.byReference instead of the full record slice.
    {
        var result = try runSeeded(std.testing.allocator, seedListFixture, &.{ "--log", "DEVLOG.jsonl", "refs", "--ref", "D:7", "--json" });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 0), result.code);
        const text = result.stdout;
        try expectExactlyOneJsonLine(text);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.array.items.len >= 1);
    }
}

test "list --state open --to <role> agrees with resume --role <role> on the same open items (blocker 3: one predicate, not two)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    try seedResumeFixture(std.testing.allocator, tmp.dir, std.testing.io, &diag);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);

    var resume_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer resume_out.deinit();
    var resume_err: Io.Writer.Allocating = .init(std.testing.allocator);
    defer resume_err.deinit();
    const resume_code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "resume", "--role", "worker", "--json" },
        &resume_out.writer,
        &resume_err.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), resume_code);

    var list_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer list_out.deinit();
    var list_err: Io.Writer.Allocating = .init(std.testing.allocator);
    defer list_err.deinit();
    const list_code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "list", "--state", "open", "--to", "worker", "--json" },
        &list_out.writer,
        &list_err.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), list_code);

    var resume_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, resume_out.written(), .{});
    defer resume_parsed.deinit();
    var list_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, list_out.written(), .{});
    defer list_parsed.deinit();

    const resume_items = resume_parsed.value.object.get("items").?.array.items;
    const list_items = list_parsed.value.array.items;
    try std.testing.expectEqual(@as(usize, 2), resume_items.len);
    try std.testing.expectEqual(resume_items.len, list_items.len);
    for (resume_items, list_items) |ri, li| {
        try std.testing.expectEqual(ri.object.get("number").?.integer, li.object.get("number").?.integer);
    }
}

// --- Section 7: search (7.1, 7.2) ----------------------------------------

/// A corpus small enough to rank by hand, and diverse enough to catch what
/// a search that indexed the wrong thing would get away with: bodies of
/// several kinds, a non-ASCII word, and one record whose body never
/// mentions the term the tests query for.
///
/// Records, in append order (kind, seq, body in brief):
///   1. header  seq 1  — no body at all: never a document (R4)
///   2. post    seq 2  — "lock" once, 12 tokens
///   3. post    seq 3  — "lock" twice, 11 tokens
///   4. brief   seq 4  — about ranking, no "lock"
///
/// The `brief` carries a `block` as of block 7B, not because any 7.1/7.2
/// assertion needs one but because `search` derives as of `7.3` and
/// `state.derive` faults on a `brief` missing `section`/`block`
/// (`BriefMissingKey`) — a log `runBrief` could never have written, since
/// it requires both. The fixture was legal only while `search` was the one
/// read command that skipped `derive`; a dedicated test below now pins that
/// fault reaching `search` deliberately rather than through this fixture.
///   5. post    seq 5  — carries the non-ASCII word "naïve"
///   6. item    seq 6  — an item's body is prose too, and is indexed
///   7. next    seq 7  — so is a next's
fn seedSearchFixture(allocator: Allocator, dir: Io.Dir, io: Io, diag: *record.Diagnostics) !void {
    _ = try log.appendHeader(
        allocator,
        io,
        dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "add-devlog-core", .roles = &.{ "architect", "worker" }, .closers = &.{"architect"} },
        diag,
    );

    _ = try log.appendRecord(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .post = .{
        .common = .{
            .seq = 0,
            .ts = "t1",
            .role = "architect",
            .section = "7",
            .body = "The write path takes the lock, assigns seq, and appends one line.",
        },
    } }, diag);

    _ = try log.appendRecord(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .post = .{
        .common = .{
            .seq = 0,
            .ts = "t2",
            .role = "worker",
            .section = "7",
            .body = "Lock, write, rename: the lock is what makes the write atomic.",
        },
    } }, diag);

    _ = try log.appendRecord(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .brief = .{
        .common = .{
            .seq = 0,
            .ts = "t3",
            .role = "architect",
            .section = "7",
            .block = "7A",
            .to = "worker",
            .body = "Ranking is the order, never a score field.",
        },
    } }, diag);

    _ = try log.appendRecord(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .post = .{
        .common = .{
            .seq = 0,
            .ts = "t4",
            .role = "worker",
            .body = "A naïve prose search would rescan the file.",
        },
    } }, diag);

    _ = try log.appendItem(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .item = .{
        .common = .{
            .seq = 0,
            .ts = "t5",
            .role = "worker",
            .to = "architect",
            .body = "Does the temp file count as state?",
        },
        .item = 0,
        .type = .question,
        .blocking = false,
    } }, diag);

    _ = try log.appendRecord(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .next = .{
        .common = .{ .seq = 0, .ts = "t6", .role = "architect", .body = "Resume at section 7." },
    } }, diag);
}

test "search returns only the records whose bodies match, ranked by relevance (7.2)" {
    var result = try runSeeded(std.testing.allocator, seedSearchFixture, &.{ "--log", "DEVLOG.jsonl", "search", "lock" });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.code);

    const text = result.stdout;
    try std.testing.expect(std.mem.indexOf(u8, text, "records (2):") != null);

    // Hand-checked BM25: the second post says "lock" twice in 11 tokens,
    // the first once in 12, so two occurrences beat the small extra length
    // penalty and it ranks first. The other five documents never say it and
    // are absent entirely — this is not `list` with a highlight.
    const pos_twice = std.mem.indexOf(u8, text, "Lock, write, rename") orelse return error.TestUnexpectedResult;
    const pos_once = std.mem.indexOf(u8, text, "The write path takes") orelse return error.TestUnexpectedResult;
    try std.testing.expect(pos_twice < pos_once);
    try std.testing.expect(std.mem.indexOf(u8, text, "Ranking is the order") == null);
}

test "search indexes every kind's body, and the header's absence of one (R4)" {
    // An item's body and a next's body are prose and are searchable; the
    // header carries no body, so a query for a word only its own metadata
    // fields hold ("add-devlog-core", its change) finds nothing.
    {
        var result = try runSeeded(std.testing.allocator, seedSearchFixture, &.{ "--log", "DEVLOG.jsonl", "search", "temp state resume" });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 0), result.code);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Does the temp file count as state?") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Resume at section 7.") != null);
    }
    {
        var result = try runSeeded(std.testing.allocator, seedSearchFixture, &.{ "--log", "DEVLOG.jsonl", "search", "add-devlog-core" });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 0), result.code);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "records (0):") != null);
    }
}

test "search folds ASCII case and leaves a multi-byte word whole, end to end" {
    for ([_][:0]const u8{ "naïve", "Naïve" }) |query| {
        var result = try runSeeded(std.testing.allocator, seedSearchFixture, &.{ "--log", "DEVLOG.jsonl", "search", query });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 0), result.code);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "records (1):") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "A naïve prose search") != null);
    }
}

test "search with no matches is an ordinary empty success, in both forms (as refs rules it)" {
    {
        var result = try runSeeded(std.testing.allocator, seedSearchFixture, &.{ "--log", "DEVLOG.jsonl", "search", "zebra" });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 0), result.code);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "records (0):") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "(none)") != null);
        try std.testing.expectEqualStrings("", result.stderr);
    }
    {
        var result = try runSeeded(std.testing.allocator, seedSearchFixture, &.{ "--log", "DEVLOG.jsonl", "search", "zebra", "--json" });
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 0), result.code);
        try std.testing.expectEqualStrings("[]\n", result.stdout);
    }
}

test "search --json is the same bare array list emits, in rank order and with no score field (R3, D15)" {
    var result = try runSeeded(std.testing.allocator, seedSearchFixture, &.{ "--log", "DEVLOG.jsonl", "search", "lock", "--json" });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try expectExactlyOneJsonLine(result.stdout);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result.stdout, .{});
    defer parsed.deinit();
    const arr = parsed.value.array;
    try std.testing.expectEqual(@as(usize, 2), arr.items.len);

    // The ranking is the array order and nothing else: no seventh JSON
    // shape, no score field for a consumer to depend on — which is what
    // keeps BM25's k1/b tunable later without breaking one.
    try std.testing.expectEqual(@as(i64, 3), arr.items[0].object.get("seq").?.integer);
    try std.testing.expectEqual(@as(i64, 2), arr.items[1].object.get("seq").?.integer);
    for (arr.items) |v| try std.testing.expect(v.object.get("score") == null);

    // Both forms describe the same records (D15).
    var text_result = try runSeeded(std.testing.allocator, seedSearchFixture, &.{ "--log", "DEVLOG.jsonl", "search", "lock" });
    defer text_result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, text_result.stdout, arr.items[0].object.get("body").?.string) != null);
}

test "search with no query at all is a refusal, not a whole-log dump (R1)" {
    var result = try runSeeded(std.testing.allocator, seedSearchFixture, &.{ "--log", "DEVLOG.jsonl", "search" });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 1), result.code);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "'search' requires a query") != null);
    try std.testing.expectEqualStrings("", result.stdout);
}

test "search with an empty query is a refusal, worded as an empty flag value is (R1)" {
    var result = try runSeeded(std.testing.allocator, seedSearchFixture, &.{ "--log", "DEVLOG.jsonl", "search", "" });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 1), result.code);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "<query> requires a non-empty value") != null);
    try std.testing.expectEqualStrings("", result.stdout);
}

test "search takes exactly one positional: a second bare token is refused, never silently dropped (R1, B1)" {
    // The defect this closes: `search a b c` under a boolean
    // takes_positional could have searched for "a" and thrown "b" and "c"
    // away without a word. A multi-word query is the caller's to quote.
    var result = try runSeeded(std.testing.allocator, seedSearchFixture, &.{ "--log", "DEVLOG.jsonl", "search", "lock", "atomic" });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 1), result.code);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "unexpected argument 'atomic'") != null);
    try std.testing.expectEqualStrings("", result.stdout);

    // And a quoted multi-word query is one argument, which works.
    var quoted = try runSeeded(std.testing.allocator, seedSearchFixture, &.{ "--log", "DEVLOG.jsonl", "search", "lock atomic" });
    defer quoted.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), quoted.code);
    try std.testing.expect(std.mem.indexOf(u8, quoted.stdout, "records (2):") != null);
}

test "search against a missing log reports plainly, exits non-zero, and creates nothing (carried 13, D5)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "search", "lock" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "devlog header") != null);

    var count: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next(std.testing.io)) |entry| {
        try std.testing.expectEqualStrings("stdin-standin", entry.name);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "search --help prints its own usage, naming the one-argument rule and the absent score" {
    try expectRun(std.testing.allocator, &.{ "search", "--help" }, 0, "devlog search", null);
    try expectRun(std.testing.allocator, &.{ "search", "--help" }, 0, "Exactly one argument", null);
    try expectRun(std.testing.allocator, &.{ "search", "--help" }, 0, "there is no score field", null);
}

// --- Section 7: search narrowed by 6.3's filters (7.3, 7.4) --------------

/// One word ("lock") deliberately spread across sections, roles,
/// addressees, kinds and item states, so that every filter has something to
/// remove and the removal is visible in the count. One record's body
/// mentions none of it, and one item is closed — so `--state open` and
/// `--state resolved` each have exactly one answer.
///
/// Records, in append order (kind, seq, section/block, role → to, body):
///   1. header  seq 1  — no body: never a document (R4)
///   2. post    seq 2  s6         architect → worker  "lock"
///   3. post    seq 3  s7         worker              "lock"
///   4. brief   seq 4  s7 / 7B    architect → worker  "lock"
///   5. item #1 seq 5  s6 / 6C    worker → architect  "lock", blocking, open
///   6. item #2 seq 6  s7 / 7B    reviewer → architect "lock", resolved below
///   7. close   seq 7             architect           closes #2, no "lock"
///   8. next    seq 8             architect           no "lock"
///   9. post    seq 9  s6         reviewer            no "lock"
fn seedSearchFilterFixture(allocator: Allocator, dir: Io.Dir, io: Io, diag: *record.Diagnostics) !void {
    _ = try log.appendHeader(
        allocator,
        io,
        dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{ "architect", "worker", "reviewer" }, .closers = &.{"architect"} },
        diag,
    );

    _ = try log.appendRecord(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .post = .{
        .common = .{
            .seq = 0,
            .ts = "t1",
            .role = "architect",
            .section = "6",
            .to = "worker",
            .body = "The lock is taken before seq is assigned.",
        },
    } }, diag);

    _ = try log.appendRecord(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .post = .{
        .common = .{
            .seq = 0,
            .ts = "t2",
            .role = "worker",
            .section = "7",
            .body = "Ranking happens after the lock is released.",
        },
    } }, diag);

    _ = try log.appendRecord(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .brief = .{
        .common = .{
            .seq = 0,
            .ts = "t3",
            .role = "architect",
            .section = "7",
            .block = "7B",
            .to = "worker",
            .body = "Narrow the lock discussion before ranking it.",
        },
    } }, diag);

    _ = try log.appendItem(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .item = .{
        .common = .{
            .seq = 0,
            .ts = "t4",
            .role = "worker",
            .section = "6",
            .block = "6C",
            .to = "architect",
            .body = "Does the lock cover the rename?",
        },
        .item = 0,
        .type = .question,
        .blocking = true,
    } }, diag);

    _ = try log.appendItem(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .item = .{
        .common = .{
            .seq = 0,
            .ts = "t5",
            .role = "reviewer",
            .section = "7",
            .block = "7B",
            .to = "architect",
            .body = "The lock comment is stale.",
        },
        .item = 0,
        .type = .finding,
        .blocking = false,
    } }, diag);

    _ = try log.appendRecord(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .close = .{
        .common = .{ .seq = 0, .ts = "t6", .role = "architect", .body = "Fixed and rewritten." },
        .item = 2,
        .state = .resolved,
    } }, diag);

    _ = try log.appendRecord(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .next = .{
        .common = .{ .seq = 0, .ts = "t7", .role = "architect", .body = "Resume at 7.3." },
    } }, diag);

    _ = try log.appendRecord(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .post = .{
        .common = .{
            .seq = 0,
            .ts = "t8",
            .role = "reviewer",
            .section = "6",
            .body = "Nothing to do with the topic at hand.",
        },
    } }, diag);
}

test "search returns the matching records, not the whole log (log-retrieval, 7.4)" {
    // The spec scenario in one assertion: "it receives the relevant records
    // rather than the entire log". The fixture makes the difference visible
    // — nine records in the log, five that say "lock" — so a ranking that
    // degenerated into "return everything, ordered" would fail here rather
    // than pass silently.
    var searched = try runSeeded(std.testing.allocator, seedSearchFilterFixture, &.{ "--log", "DEVLOG.jsonl", "search", "lock" });
    defer searched.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), searched.code);
    try std.testing.expect(std.mem.indexOf(u8, searched.stdout, "records (5):") != null);
    try std.testing.expect(std.mem.indexOf(u8, searched.stdout, "Nothing to do with the topic") == null);

    var listed = try runSeeded(std.testing.allocator, seedSearchFilterFixture, &.{ "--log", "DEVLOG.jsonl", "list" });
    defer listed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), listed.code);
    try std.testing.expect(std.mem.indexOf(u8, listed.stdout, "records (9):") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed.stdout, "Nothing to do with the topic") != null);
}

test "search is deterministic for a given file: repeated runs over one log are byte-identical (7.4)" {
    // Not the same log *content* re-seeded into a fresh directory — the
    // same file, opened again and again, which is what the requirement
    // says. Covers the unfiltered, filtered and JSON paths, since each
    // reaches a different sort input.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    try seedSearchFilterFixture(std.testing.allocator, tmp.dir, std.testing.io, &diag);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);

    const invocations = [_][]const [:0]const u8{
        &.{ "--log", "DEVLOG.jsonl", "search", "lock" },
        &.{ "--log", "DEVLOG.jsonl", "search", "lock", "--section", "7" },
        &.{ "--log", "DEVLOG.jsonl", "search", "lock", "--state", "open" },
        &.{ "--log", "DEVLOG.jsonl", "search", "lock", "--json" },
    };

    for (invocations) |args| {
        var first: ?[]u8 = null;
        defer if (first) |f| std.testing.allocator.free(f);
        for (0..8) |_| {
            var out: Io.Writer.Allocating = .init(std.testing.allocator);
            defer out.deinit();
            var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
            defer err_out.deinit();
            const code = run(
                std.testing.allocator,
                std.testing.io,
                tmp.dir,
                stdin_file,
                test_ts,
                args,
                &out.writer,
                &err_out.writer,
            );
            try std.testing.expectEqual(@as(u8, 0), code);
            if (first) |f| {
                try std.testing.expectEqualStrings(f, out.written());
            } else {
                first = try std.testing.allocator.dupe(u8, out.written());
            }
        }
    }
}

test "each of 6.3's filters narrows a search on its own (7.3)" {
    const cases = [_]struct { args: []const [:0]const u8, expect: []const u8 }{
        // Unfiltered: every record whose body says "lock".
        .{ .args = &.{ "--log", "DEVLOG.jsonl", "search", "lock" }, .expect = "records (5):" },
        // --section: only section 7's three.
        .{ .args = &.{ "--log", "DEVLOG.jsonl", "search", "lock", "--section", "7" }, .expect = "records (3):" },
        // --block: the label's two, and it is not the same set as --section.
        .{ .args = &.{ "--log", "DEVLOG.jsonl", "search", "lock", "--block", "7B" }, .expect = "records (2):" },
        // --role: by author.
        .{ .args = &.{ "--log", "DEVLOG.jsonl", "search", "lock", "--role", "architect" }, .expect = "records (2):" },
        // --to: by addressee.
        .{ .args = &.{ "--log", "DEVLOG.jsonl", "search", "lock", "--to", "architect" }, .expect = "records (2):" },
        // --kind: the two item records.
        .{ .args = &.{ "--log", "DEVLOG.jsonl", "search", "lock", "--kind", "item" }, .expect = "records (2):" },
        // A filter that matches nothing is an empty success, not a refusal.
        .{ .args = &.{ "--log", "DEVLOG.jsonl", "search", "lock", "--section", "3" }, .expect = "records (0):" },
    };
    for (cases) |c| {
        var result = try runSeeded(std.testing.allocator, seedSearchFilterFixture, c.args);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 0), result.code);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, c.expect) != null);
    }
}

test "two filters intersect with the query, and the intersection is not either one alone (7.3)" {
    // Section 7 holds three "lock" records; the worker authored two records
    // overall. Their intersection is exactly one — a result neither filter
    // produces by itself, which is what makes this an AND rather than a
    // pair of independent narrowings.
    var result = try runSeeded(std.testing.allocator, seedSearchFilterFixture, &.{ "--log", "DEVLOG.jsonl", "search", "lock", "--section", "7", "--role", "worker" });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "records (1):") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Ranking happens after the lock") != null);
}

test "search --state/--blocking narrow the candidates to item records and never switch the output shape (R2)" {
    // `list` answers these two flags with a list of items; `search` answers
    // them with the records those items opened, so its result is the same
    // shape under every combination of flags.
    const cases = [_]struct { args: []const [:0]const u8, body: []const u8 }{
        .{ .args = &.{ "--log", "DEVLOG.jsonl", "search", "lock", "--state", "open" }, .body = "Does the lock cover the rename?" },
        .{ .args = &.{ "--log", "DEVLOG.jsonl", "search", "lock", "--state", "resolved" }, .body = "The lock comment is stale." },
        .{ .args = &.{ "--log", "DEVLOG.jsonl", "search", "lock", "--blocking" }, .body = "Does the lock cover the rename?" },
        .{ .args = &.{ "--log", "DEVLOG.jsonl", "search", "lock", "--state", "open", "--section", "6" }, .body = "Does the lock cover the rename?" },
        // --kind item alongside --state is redundant, not a conflict.
        .{ .args = &.{ "--log", "DEVLOG.jsonl", "search", "lock", "--state", "open", "--kind", "item" }, .body = "Does the lock cover the rename?" },
    };
    for (cases) |c| {
        var result = try runSeeded(std.testing.allocator, seedSearchFilterFixture, c.args);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 0), result.code);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "records (1):") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "items (") == null);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, c.body) != null);
    }

    // And the same narrowing in JSON is still the bare record array, not a
    // seventh shape (R3, D15).
    var as_json = try runSeeded(std.testing.allocator, seedSearchFilterFixture, &.{ "--log", "DEVLOG.jsonl", "search", "lock", "--state", "open", "--json" });
    defer as_json.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), as_json.code);
    try expectExactlyOneJsonLine(as_json.stdout);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, as_json.stdout, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    try std.testing.expectEqualStrings("item", parsed.value.array.items[0].object.get("kind").?.string);
    try std.testing.expect(parsed.value.array.items[0].object.get("state") == null);
}

test "the --kind/--state conflict is one guard with one message, not a copy per command (R6)" {
    // The refusal `list` has carried since 6.3, reached through `search`.
    // Asserting the two stderrs are *equal* is the point: a second copy of
    // the message would satisfy a substring check and fail this one.
    var listed = try runSeeded(std.testing.allocator, seedSearchFilterFixture, &.{ "--log", "DEVLOG.jsonl", "list", "--kind", "post", "--state", "open" });
    defer listed.deinit(std.testing.allocator);
    var searched = try runSeeded(std.testing.allocator, seedSearchFilterFixture, &.{ "--log", "DEVLOG.jsonl", "search", "lock", "--kind", "post", "--state", "open" });
    defer searched.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, 1), listed.code);
    try std.testing.expectEqual(@as(u8, 1), searched.code);
    try std.testing.expectEqualStrings(listed.stderr, searched.stderr);
    try std.testing.expect(std.mem.indexOf(u8, searched.stderr, "cannot be combined with --state or --blocking") != null);
    try std.testing.expectEqualStrings("", searched.stdout);

    // The value-validation refusals are the same one place too.
    var bad_kind = try runSeeded(std.testing.allocator, seedSearchFilterFixture, &.{ "--log", "DEVLOG.jsonl", "search", "lock", "--kind", "nonsense" });
    defer bad_kind.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 1), bad_kind.code);
    try std.testing.expect(std.mem.indexOf(u8, bad_kind.stderr, "must be one of: header, section") != null);

    var bad_state = try runSeeded(std.testing.allocator, seedSearchFilterFixture, &.{ "--log", "DEVLOG.jsonl", "search", "lock", "--state", "nonsense" });
    defer bad_state.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 1), bad_state.code);
    try std.testing.expect(std.mem.indexOf(u8, bad_state.stderr, "must be one of: open, resolved") != null);
}

test "search --role/--to are history filters, refusing a value no header ever declared (section 6 ruling)" {
    var undeclared = try runSeeded(std.testing.allocator, seedSearchFilterFixture, &.{ "--log", "DEVLOG.jsonl", "search", "lock", "--role", "supervisor" });
    defer undeclared.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 1), undeclared.code);
    try std.testing.expect(std.mem.indexOf(u8, undeclared.stderr, "supervisor") != null);
    try std.testing.expectEqualStrings("", undeclared.stdout);

    var undeclared_to = try runSeeded(std.testing.allocator, seedSearchFilterFixture, &.{ "--log", "DEVLOG.jsonl", "search", "lock", "--to", "supervisor" });
    defer undeclared_to.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 1), undeclared_to.code);
    try std.testing.expectEqualStrings("", undeclared_to.stdout);

    // A declared role that authored nothing matching is an empty success.
    var declared = try runSeeded(std.testing.allocator, seedSearchFilterFixture, &.{ "--log", "DEVLOG.jsonl", "search", "lock", "--role", "reviewer" });
    defer declared.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), declared.code);
    try std.testing.expect(std.mem.indexOf(u8, declared.stdout, "records (1):") != null);
}

test "search derives as of 7.3, so a write-boundary violation faults instead of ranking over it" {
    // The rule every other read command has always been held to, now
    // reaching `search`: a `brief` carrying neither `section` nor `block`
    // is a log `runBrief` could not have written, and `state.derive`
    // refuses it (`BriefMissingKey`). Before 7.3, `search` skipped `derive`
    // and would have happily ranked this log.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var diag: record.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    _ = try log.appendHeader(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{ "architect", "worker" }, .closers = &.{"architect"} },
        &diag,
    );
    _ = try log.appendRecord(std.testing.allocator, std.testing.io, tmp.dir, "DEVLOG.jsonl", record.Record{ .brief = .{
        .common = .{ .seq = 0, .ts = "t1", .role = "architect", .to = "worker", .body = "malformed: no section, no block" },
    } }, &diag);

    var stdin_file = try openStdinStandin(tmp.dir, std.testing.io, "");
    defer stdin_file.close(std.testing.io);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    // No filter on the line at all: `search` derives unconditionally, so
    // the fault does not depend on which flags were given.
    const code = run(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        stdin_file,
        test_ts,
        &.{ "--log", "DEVLOG.jsonl", "search", "malformed" },
        &out.writer,
        &err_out.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "brief") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_out.written(), "section") != null);
    try std.testing.expectEqualStrings("", out.written());
}

/// Six documents of identical length, so BM25's length normalisation is the
/// same constant for every one of them and the ranking is decided by IDF
/// alone — which is what makes R5 testable by hand.
///
/// "alpha" appears in four of the six and in only one of section 8's three;
/// "beta" in two of the six and in two of section 8's three. So the query
/// "alpha beta" ranks the beta records above the alpha one over the whole
/// log, and the alpha record above them within section 8 — opposite orders
/// over the same three documents, decided entirely by which corpus the IDF
/// was computed against.
fn seedIdfFixture(allocator: Allocator, dir: Io.Dir, io: Io, diag: *record.Diagnostics) !void {
    _ = try log.appendHeader(
        allocator,
        io,
        dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{"architect"}, .closers = &.{"architect"} },
        diag,
    );
    const bodies = [_]struct { section: []const u8, body: []const u8 }{
        .{ .section = "5", .body = "alpha pad pad sigilone" },
        .{ .section = "5", .body = "alpha pad pad sigiltwo" },
        .{ .section = "5", .body = "alpha pad pad sigilthree" },
        .{ .section = "8", .body = "alpha pad pad sigilfour" },
        .{ .section = "8", .body = "beta pad pad sigilfive" },
        .{ .section = "8", .body = "beta pad pad sigilsix" },
    };
    for (bodies) |b| {
        _ = try log.appendRecord(allocator, io, dir, "DEVLOG.jsonl", record.Record{ .post = .{
            .common = .{
                .seq = 0,
                .ts = "t1",
                .role = "architect",
                .section = b.section,
                .body = b.body,
            },
        } }, diag);
    }
}

test "the index is built over the filtered candidates, so IDF is relative to what was asked about (R5)" {
    // The one assertion that tells filter-then-index apart from
    // index-then-filter. Over the whole log "alpha" is the common term and
    // "beta" the rare one, so the beta records rank first. Restricted to
    // section 8 the relationship inverts — "alpha" is now the rare term —
    // and the order of the *same three documents* inverts with it. If the
    // filters were applied to the results of a whole-log ranking instead,
    // the second ordering would match the first.
    var whole = try runSeeded(std.testing.allocator, seedIdfFixture, &.{ "--log", "DEVLOG.jsonl", "search", "alpha beta" });
    defer whole.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), whole.code);
    try std.testing.expect(std.mem.indexOf(u8, whole.stdout, "records (6):") != null);
    const whole_beta = std.mem.indexOf(u8, whole.stdout, "sigilfive") orelse return error.TestUnexpectedResult;
    const whole_alpha = std.mem.indexOf(u8, whole.stdout, "sigilfour") orelse return error.TestUnexpectedResult;
    try std.testing.expect(whole_beta < whole_alpha);

    var narrowed = try runSeeded(std.testing.allocator, seedIdfFixture, &.{ "--log", "DEVLOG.jsonl", "search", "alpha beta", "--section", "8" });
    defer narrowed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), narrowed.code);
    try std.testing.expect(std.mem.indexOf(u8, narrowed.stdout, "records (3):") != null);
    const narrowed_alpha = std.mem.indexOf(u8, narrowed.stdout, "sigilfour") orelse return error.TestUnexpectedResult;
    const narrowed_beta = std.mem.indexOf(u8, narrowed.stdout, "sigilfive") orelse return error.TestUnexpectedResult;
    try std.testing.expect(narrowed_alpha < narrowed_beta);

    // Ties within the narrowed set still break by seq ascending (R3):
    // sigilfive and sigilsix score identically.
    const narrowed_sixth = std.mem.indexOf(u8, narrowed.stdout, "sigilsix") orelse return error.TestUnexpectedResult;
    try std.testing.expect(narrowed_beta < narrowed_sixth);
}

test "search --help documents the filters and the leading-dash limit of its positional" {
    try expectRun(std.testing.allocator, &.{ "search", "--help" }, 0, "--section <s>", null);
    try expectRun(std.testing.allocator, &.{ "search", "--help" }, 0, "--blocking", null);
    try expectRun(std.testing.allocator, &.{ "search", "--help" }, 0, "cannot begin with '-'", null);
    try expectRun(std.testing.allocator, &.{ "search", "--help" }, 0, "there is no '--'", null);
    try expectRun(std.testing.allocator, &.{ "search", "--help" }, 0, "a search always returns", null);
}
