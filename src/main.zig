// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

const std = @import("std");
const build_options = @import("build_options");
const manifest = @import("manifest");
const Io = std.Io;

// The record model and its JSON codec (block 2A), and the locked-append
// I/O layer (block 2B), have no consumer yet in this dispatcher — sections
// 4/6/7 wire them in. Referenced here only so `zig build test` discovers
// their tests; no production logic reaches either yet.
const record = @import("record.zig");
const log = @import("log.zig");
test {
    _ = record;
    _ = log;
}

/// One subcommand of the surface. `section` names the `tasks.md` section
/// that owns its real behaviour, so the placeholder help below never
/// invents a promise this block doesn't keep.
const CommandSpec = struct {
    name: []const u8,
    summary: []const u8,
    section: []const u8,
};

/// Names only, from sections 4, 6 and 7 of the change's `tasks.md`. This
/// block dispatches to them and gives each a `--help`; their behaviour is
/// those sections' to build.
const commands = [_]CommandSpec{
    .{ .name = "header", .summary = "Declare the project's role set, creating the log or appending a new header.", .section = "4" },
    .{ .name = "section", .summary = "Open a section and record its base commit.", .section = "4" },
    .{ .name = "brief", .summary = "Post the architect's block brief to a worker.", .section = "4" },
    .{ .name = "post", .summary = "Post general working-channel traffic.", .section = "4" },
    .{ .name = "item", .summary = "Raise a work item and print its identifier.", .section = "4" },
    .{ .name = "close", .summary = "Close a work item with a reason (declared closers only).", .section = "4" },
    .{ .name = "verdict", .summary = "Record a typed review verdict for a block.", .section = "4" },
    .{ .name = "next", .summary = "Append the current NEXT narrative.", .section = "4" },
    .{ .name = "resume", .summary = "Show the current NEXT, open items for a role, and its latest brief.", .section = "6" },
    .{ .name = "show", .summary = "Show one item or one record by its identifier.", .section = "6" },
    .{ .name = "list", .summary = "List records, filtered by section, block, role, kind, state, or addressee.", .section = "6" },
    .{ .name = "refs", .summary = "Show every record carrying a given external reference.", .section = "6" },
    .{ .name = "status", .summary = "Show the rendered current state: NEXT plus open items.", .section = "6" },
    .{ .name = "search", .summary = "Search record bodies, ranked by relevance.", .section = "7" },
};

fn findCommand(name: []const u8) ?CommandSpec {
    for (commands) |c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    return null;
}

/// Result of a single hand-rolled pass over argv (ADR-0002: no third-party
/// parser). Errors are recorded rather than acted on immediately, so that
/// `--help` and `--version` — which must never fail — can still win when
/// they appear anywhere in a malformed invocation.
const Parsed = struct {
    log_path: ?[]const u8 = null,
    role: ?[]const u8 = null,
    role_empty: bool = false,
    role_repeated: bool = false,
    help: bool = false,
    version: bool = false,
    command: ?[]const u8 = null,
    unknown_flag: ?[]const u8 = null,
    missing_value_for: ?[]const u8 = null,
};

fn parseArgs(args: []const [:0]const u8) Parsed {
    var p: Parsed = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];

        if (std.mem.eql(u8, arg, "--help")) {
            p.help = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            p.version = true;
        } else if (std.mem.eql(u8, arg, "--log")) {
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "--")) {
                if (p.missing_value_for == null) p.missing_value_for = "--log";
            } else {
                i += 1;
                p.log_path = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--role")) {
            if (i + 1 >= args.len or std.mem.startsWith(u8, args[i + 1], "--")) {
                if (p.missing_value_for == null) p.missing_value_for = "--role";
            } else {
                i += 1;
                // A second --role is a parse ambiguity, not a last-wins
                // overwrite (DEVLOG ## 1, supervisor finding B4): the tool
                // cannot tell which value the caller meant, so silently
                // keeping one and dropping the other is exactly the class
                // of accident this tool exists to prevent. `header`'s
                // repeatable --role (task 4.10) is a distinct, command-
                // scoped meaning this dispatcher does not build yet.
                if (p.role != null) {
                    p.role_repeated = true;
                } else if (args[i].len == 0) {
                    p.role_empty = true;
                } else {
                    p.role = args[i];
                }
            }
        } else if (p.command == null and !std.mem.startsWith(u8, arg, "-")) {
            p.command = arg;
        } else if (p.command == null) {
            // An unrecognised flag before the subcommand is a global-scope
            // error. Anything after the subcommand is left alone — its
            // flags belong to sections 4, 6 and 7, not this dispatcher.
            if (p.unknown_flag == null) p.unknown_flag = arg;
        }
    }
    return p;
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
        \\                   once.
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

/// Dispatches one invocation and returns the process exit code. Pure
/// function of argv (minus argv[0]) so it can be exercised by tests without
/// a real process — no allocation, no filesystem access, matching this
/// block's scope (record types, the log file, and every subcommand's real
/// behaviour belong to later sections).
fn run(args: []const [:0]const u8, stdout: *Io.Writer, stderr: *Io.Writer) u8 {
    const p = parseArgs(args);

    // Parse-ambiguity errors beat --help/--version (architect ruling, DEVLOG
    // ## 1). The caller is an agent composing an invocation, and D13 stakes
    // this tool's design on exit codes being trustworthy: a line the parser
    // could not make sense of is not a coherent request for help or the
    // version, even if one of those tokens is also present. Silent success
    // on an unparseable line — a stray or hallucinated --help swallowing a
    // real write and exiting 0 with nothing done — is the one outcome this
    // tool must never produce.
    if (p.unknown_flag) |flag| {
        stderr.print("devlog: unknown flag '{s}' — see --help\n", .{flag}) catch {};
        return 1;
    }

    if (p.missing_value_for) |flag| {
        stderr.print("devlog: {s} requires a value\n", .{flag}) catch {};
        return 1;
    }

    if (p.role_empty) {
        stderr.print("devlog: --role requires a non-empty value\n", .{}) catch {};
        return 1;
    }

    if (p.role_repeated) {
        stderr.print("devlog: --role given more than once — see --help\n", .{}) catch {};
        return 1;
    }

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
        stderr.print("devlog: no command given — see --help\n", .{}) catch {};
        return 1;
    };

    const spec = findCommand(command_name) orelse {
        stderr.print("devlog: unknown command '{s}' — see --help\n", .{command_name}) catch {};
        return 1;
    };

    // `--log` is required, with no default and no guessing
    // (durable-format/spec.md:56): a command that needs the log and wasn't
    // given `--log` is an error, before anything else is attempted.
    if (p.log_path == null) {
        stderr.print("devlog: '{s}' requires --log <path>\n", .{spec.name}) catch {};
        return 1;
    }

    // `--role` is carried for task 4.9's future enforcement; nothing reads
    // it yet, and the vocabulary question is parked in DEVLOG.md's NEXT.

    // No subcommand has a body yet (sections 4, 6, 7). Fail honestly rather
    // than silently succeed, and touch nothing on the way out (D5).
    stderr.print("devlog: '{s}' is not implemented yet\n", .{spec.name}) catch {};
    return 1;
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

    const exit_code = run(args[1..], stdout, stderr);

    stdout.flush() catch {};
    stderr.flush() catch {};

    std.process.exit(exit_code);
}

fn expectRun(
    allocator: std.mem.Allocator,
    args: []const [:0]const u8,
    expected_code: u8,
    stdout_contains: ?[]const u8,
    stderr_contains: ?[]const u8,
) !void {
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(allocator);
    defer err_out.deinit();

    const code = run(args, &out.writer, &err_out.writer);
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
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err_out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_out.deinit();

    const code = run(&.{"--version"}, &out.writer, &err_out.writer);
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

test "a recognised command with --log fails honestly as not implemented" {
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "post" },
        1,
        null,
        "'post' is not implemented yet",
    );
}

test "a command's own --help works without --log and doesn't dispatch it" {
    try expectRun(std.testing.allocator, &.{ "post", "--help" }, 0, "devlog post", null);
    try expectRun(std.testing.allocator, &.{ "post", "--help" }, 0, "section 4", null);
}

test "header (D13) is a known command, listed and dispatched like the rest" {
    try expectRun(std.testing.allocator, &.{"--help"}, 0, "header", null);
    try expectRun(std.testing.allocator, &.{ "header", "--help" }, 0, "devlog header", null);
    // Uniform with every other command: --log is required even though
    // header is the one command that will create the file (D13/4.10 own
    // creation semantics; this block only wires the same flag check).
    try expectRun(std.testing.allocator, &.{"header"}, 1, null, "requires --log");
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "header", "--role", "architect" },
        1,
        null,
        "'header' is not implemented yet",
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
    // item's real flags (--type, --to, --blocking) belong to section 4;
    // this block must not invent validation for them.
    try expectRun(
        std.testing.allocator,
        &.{ "--log", "DEVLOG.jsonl", "item", "--type", "question" },
        1,
        null,
        "'item' is not implemented yet",
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
