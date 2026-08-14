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
test {
    _ = record;
    _ = log;
    _ = body;
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
    .{ .name = "resume", .summary = "Show the current NEXT, open items for a role, and its latest brief.", .section = "6" },
    .{ .name = "show", .summary = "Show one item or one record by its identifier.", .section = "6" },
    .{ .name = "list", .summary = "List records, filtered by section, block, role, kind, state, or addressee.", .section = "6" },
    .{ .name = "refs", .summary = "Show every record carrying a given external reference.", .section = "6" },
    .{ .name = "status", .summary = "Show the rendered current state: NEXT plus open items.", .section = "6" },
    .{ .name = "search", .summary = "Search record bodies, ranked by relevance.", .section = "7", .takes_positional = true },
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
    /// `item`-only, a bare boolean flag (4.4): absent means false,
    /// present means true. No arity ambiguity to check — repeating it is
    /// harmless, unlike a value-carrying flag.
    blocking: bool = false,
    /// `close`-only, exactly-once, required (4.5). The raw digits; parsed
    /// to a positive `i64` in `runClose`.
    item_num: ?[]const u8 = null,
    /// `close`-only, exactly-once, required (4.5). Validated against
    /// `record.CloseState`'s permitted set in `runClose`.
    state: ?[]const u8 = null,
    /// `verdict`-only, exactly-once, required (4.6). Validated against
    /// `record.VerdictOutcome`'s permitted set in `runVerdict`.
    outcome: ?[]const u8 = null,
    /// `verdict`-only, exactly-once, required (4.6). Stored verbatim and
    /// unvalidated — same posture as `section`'s `--base` (D10).
    commit: ?[]const u8 = null,

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
/// `--help`, `--version`, `--log`, and `--role` are always recognised
/// regardless of position relative to the command token (the "any
/// position" behaviour this dispatcher has always had). An unrecognised
/// flag is a fault when it appears before the command token is found
/// (unconditionally — there is no command yet to defer to) *or* when the
/// command is one this dispatcher already builds (`header`, `post`,
/// `section`, `brief`, `next` as of blocks 4A/4B — their grammars are
/// enforced everywhere on the line, not just before the bare word); an
/// unrecognised flag after any other command's bare token is left alone,
/// for that command's own section to validate once it exists (unchanged
/// pre-4A behaviour).
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
    const strict = wants_header or wants_post or wants_section_cmd or wants_brief or wants_next or
        wants_item or wants_close or wants_verdict;
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
    // not `--to` (4.6 names no addressee).
    const wants_section_flag = wants_post or wants_section_cmd or wants_brief or wants_item or wants_verdict;
    const wants_block_flag = wants_post or wants_brief or wants_item or wants_verdict;
    const wants_to_flag = wants_post or wants_brief or wants_item;
    const wants_ref_flag = wants_post or wants_section_cmd or wants_brief or wants_next or
        wants_item or wants_close or wants_verdict;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];

        if (std.mem.eql(u8, arg, "--help")) {
            p.help = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            p.version = true;
        } else if (std.mem.eql(u8, arg, "--log")) {
            if (takeFlagValue(&p, args, &i, "--log")) |v| p.log_path = v;
        } else if (std.mem.eql(u8, arg, "--role")) {
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
        } else if (wants_item and std.mem.eql(u8, arg, "--blocking")) {
            p.blocking = true;
        } else if (wants_close and std.mem.eql(u8, arg, "--item")) {
            if (takeFlagValue(&p, args, &i, "--item")) |v| setOnce(&p, &p.item_num, "--item", v);
        } else if (wants_close and std.mem.eql(u8, arg, "--state")) {
            if (takeFlagValue(&p, args, &i, "--state")) |v| setOnce(&p, &p.state, "--state", v);
        } else if (wants_verdict and std.mem.eql(u8, arg, "--outcome")) {
            if (takeFlagValue(&p, args, &i, "--outcome")) |v| setOnce(&p, &p.outcome, "--outcome", v);
        } else if (wants_verdict and std.mem.eql(u8, arg, "--commit")) {
            if (takeFlagValue(&p, args, &i, "--commit")) |v| setOnce(&p, &p.commit, "--commit", v);
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
        } else if (p.command != null and !startsWithDash(arg) and strict and !takes_positional) {
            // A bare token after the command, for a command that does not
            // take one (B1): silent success here is the one outcome this
            // tool must never produce, so it is a parse fault through the
            // same first-fault-wins structure as every other one (A6),
            // not a branch that does nothing.
            p.setFault(.{ .unexpected_argument = arg });
        }
        // else: a bare token after the command on a command that takes
        // one (`search`, once 7.2 builds it) or a flag belonging to a
        // command this block does not build, left untouched for that
        // command's own section to validate once it exists.
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
/// both of them uniformly through `fail()`).
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

    // No other subcommand is wired yet (sections 6, 7). Fail honestly
    // rather than silently succeed, and touch nothing on the way out (D5).
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

test "a recognised but unimplemented command with --log fails honestly as not implemented" {
    // status is still a placeholder past block 4A — header and post are
    // the two commands this block makes real; every other command must
    // still fail this way rather than silently succeed.
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "status" },
        1,
        null,
        "'status' is not implemented yet",
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

test "flags after the subcommand are left for its own section, not rejected here" {
    // show's real flags belong to section 6, not yet built — item, close,
    // and verdict are the ones block 4C makes real, so this test (from
    // block 4A, pre-4C) now points at a command that's still a
    // placeholder, retargeted rather than deleted (same standard as the
    // block 4A retargeting the reviewer accepted).
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "show", "--item", "5" },
        1,
        null,
        "'show' is not implemented yet",
    );
}

test "--log and --role are recognised in any position relative to the command" {
    try expectRun(
        std.testing.allocator,
        &.{ "status", "--log", "DEVLOG.jsonl", "--role", "architect" },
        1,
        null,
        "'status' is not implemented yet",
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
