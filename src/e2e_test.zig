// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Block 9A (`9.1`–`9.3`): end-to-end validation. Every other test in this
//! project calls `run()` in-process (`main.zig`'s own tests) — a shortcut
//! that cannot see a branch nothing executes, behaviour only the built
//! binary shows (real argv parsing, a real stdin pipe, a real process exit
//! code), or a defect only visible at realistic corpus size (section 7's
//! lesson). This file drives `zig-out/bin/devlog` as a real OS process,
//! replaying `docs/example/DEVLOG.md` (a full, unrelated project's thread —
//! not this change's own bootstrap log) through it, and asserts against
//! what the tool derives, never against a hand-typed expectation.
//!
//! `9.1`–`9.3` share one replay (`replay`, `setupReplay`); each test below
//! runs it fresh, in its own temp directory, so the three are independent
//! and order-proof.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

const record = @import("record.zig");
const log = @import("log.zig");
const state_mod = @import("state.zig");

/// The fixture: a different, fictional project's DEVLOG. `@embedFile`
/// cannot reach outside this module's root (`src/`), so it is read from
/// disk at runtime instead — relative to the test binary's cwd, the same
/// project root every gate already assumes (`zig-out/bin/devlog` below is
/// resolved the same way). Never edited by this block (Architect's
/// brief) — if the tool cannot replay it, that is a finding about the
/// tool, not something to fix by changing the input.
const fixture_path = "docs/example/DEVLOG.md";

fn readFixture(allocator: Allocator, io: Io) ![]u8 {
    var f = try Io.Dir.cwd().openFile(io, fixture_path, .{ .mode = .read_only });
    defer f.close(io);
    const st = try f.stat(io);
    const buf = try allocator.alloc(u8, st.size);
    errdefer allocator.free(buf);
    const n = try f.readPositionalAll(io, buf, 0);
    return buf[0..n];
}

const binary_path = "zig-out/bin/devlog";

const Role = enum { architect, worker, reviewer, supervisor };

fn roleName(r: Role) []const u8 {
    return @tagName(r);
}

const known_roles = [_]Role{ .architect, .worker, .reviewer, .supervisor };

fn roleFromTag(tag: []const u8) ?Role {
    inline for (known_roles) |r| {
        if (std.mem.eql(u8, tag, @tagName(r))) return r;
    }
    return null;
}

/// `zig-out/bin/devlog` is only produced by the default `zig build` step
/// (`b.getInstallStep()`); `zig build test` alone does not build it. `make
/// gates` runs `build` before `test`, so the done-gate always has it — but
/// a bare `make test` might not, and this must fail loudly rather than
/// silently pass on a stale or absent binary (the standing hazard: a test
/// sized so the property cannot fail).
fn requireBinaryBuilt() !void {
    Io.Dir.cwd().access(testing.io, binary_path, .{}) catch {
        std.debug.print(
            "\n{s} not found or not accessible — run `zig build` (or `make build`) before this test.\n",
            .{binary_path},
        );
        return error.DevlogBinaryMissing;
    };
}

// --- Subprocess plumbing ----------------------------------------------------

const RunResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *RunResult, allocator: Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// Spawns the built `devlog` binary as a real OS process. Mirrors
/// `std.process.run`'s own implementation (same `MultiReader` drain-before-
/// wait shape, avoiding the pipe-buffer deadlock a naive wait-then-read
/// would risk on a large `list --json` dump) — the one difference is
/// `stdin`, which `std.process.run` hardcodes to `.ignore` and every write
/// command here needs as a real, non-terminal file (D5).
fn runDevlog(allocator: Allocator, io: Io, argv: []const []const u8, stdin_file: ?Io.File) !RunResult {
    var full_argv = try allocator.alloc([]const u8, argv.len + 1);
    defer allocator.free(full_argv);
    full_argv[0] = binary_path;
    @memcpy(full_argv[1..], argv);

    var child = try std.process.spawn(io, .{
        .argv = full_argv,
        .stdin = if (stdin_file) |f| .{ .file = f } else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    while (multi_reader.fill(64, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try multi_reader.checkAnyError();

    const term = try child.wait(io);

    const stdout_slice = try multi_reader.toOwnedSlice(0);
    errdefer allocator.free(stdout_slice);
    const stderr_slice = try multi_reader.toOwnedSlice(1);
    errdefer allocator.free(stderr_slice);

    return .{ .term = term, .stdout = stdout_slice, .stderr = stderr_slice };
}

fn expectSuccess(result: RunResult, label: []const u8) !void {
    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print(
                    "devlog {s} exited {d}\nstdout: {s}\nstderr: {s}\n",
                    .{ label, code, result.stdout, result.stderr },
                );
                return error.DevlogCommandFailed;
            }
        },
        else => |t| {
            std.debug.print("devlog {s} terminated abnormally: {any}\n", .{ label, t });
            return error.DevlogCommandFailed;
        },
    }
}

/// Writes `body` to a scratch file in `dir` and reopens it read-only — the
/// same pattern `body.zig`'s own tests use for a real, non-terminal stdin
/// stand-in, here handed to a real child process instead of an in-process
/// call.
fn writeStdinFile(dir: Io.Dir, io: Io, body: []const u8) !Io.File {
    {
        var f = try dir.createFile(io, "stdin-scratch", .{ .truncate = true });
        defer f.close(io);
        try f.writePositionalAll(io, body, 0);
    }
    return dir.openFile(io, "stdin-scratch", .{ .mode = .read_only });
}

// --- Replay driver -----------------------------------------------------------

const VerdictTriple = struct {
    section: []const u8,
    block: []const u8,
    outcome: []const u8,
};

/// Everything one replay accumulates: `allocator` owns `RunResult` buffers
/// (freed per call); `arena` owns every string this driver builds itself
/// (block labels, item-id strings, joined paragraph bodies) and is torn
/// down once, by the caller, after all assertions are done.
const Ctx = struct {
    allocator: Allocator,
    arena: Allocator,
    io: Io,
    tmp: *testing.TmpDir,
    log_path: []const u8,
    kinds_seen: std.EnumSet(record.Kind) = .initEmpty(),
    expected_verdicts: std.ArrayList(VerdictTriple) = .empty,
    /// Incremented once per write command that returned exit 0 — the
    /// independent count 9.1 checks the produced log against, so a write
    /// path that exits success without actually appending (nothing else
    /// here reads a record back out of the log to catch that) diverges
    /// from `list --json`'s length instead of passing silently.
    records_written: usize = 0,

    fn writeCmd(self: *Ctx, role: Role, cmd: []const u8, extra: []const []const u8, body: []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.arena);
        try argv.appendSlice(self.arena, &.{ "--log", self.log_path, "--role", roleName(role), cmd });
        try argv.appendSlice(self.arena, extra);

        var stdin_file = try writeStdinFile(self.tmp.dir, self.io, body);
        defer stdin_file.close(self.io);

        var result = try runDevlog(self.allocator, self.io, argv.items, stdin_file);
        defer result.deinit(self.allocator);
        try expectSuccess(result, cmd);
        self.records_written += 1;
    }

    /// `item` is the one write command whose stdout is load-bearing: the
    /// assigned `#<n>`, needed to close the item later.
    fn writeItemCmd(self: *Ctx, role: Role, extra: []const []const u8, body: []const u8) !i64 {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.arena);
        try argv.appendSlice(self.arena, &.{ "--log", self.log_path, "--role", roleName(role), "item" });
        try argv.appendSlice(self.arena, extra);

        var stdin_file = try writeStdinFile(self.tmp.dir, self.io, body);
        defer stdin_file.close(self.io);

        var result = try runDevlog(self.allocator, self.io, argv.items, stdin_file);
        defer result.deinit(self.allocator);
        try expectSuccess(result, "item");
        self.records_written += 1;

        const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
        if (trimmed.len < 2 or trimmed[0] != '#') return error.UnexpectedItemOutput;
        return std.fmt.parseInt(i64, trimmed[1..], 10);
    }

    fn writeHeader(self: *Ctx) !void {
        var result = try runDevlog(self.allocator, self.io, &.{
            "--log",                self.log_path,
            "header",               "--change",
            "request-cancellation", "--role",
            "architect",            "--role",
            "worker",               "--role",
            "reviewer",             "--role",
            "supervisor",           "--closer",
            "architect",
        }, null);
        defer result.deinit(self.allocator);
        try expectSuccess(result, "header");
        self.kinds_seen.insert(.header);
        self.records_written += 1;
    }
};

fn isRoleLine(line: []const u8) ?struct { role: Role, prefix_len: usize } {
    if (!std.mem.startsWith(u8, line, "**[")) return null;
    const close = std.mem.indexOf(u8, line, "]**") orelse return null;
    const role = roleFromTag(line[3..close]) orelse return null;
    const after = close + 3;
    if (after >= line.len or line[after] != ' ') return null;
    return .{ .role = role, .prefix_len = after + 1 };
}

fn isSectionHeading(line: []const u8) ?struct { n: []const u8, title: []const u8 } {
    if (!std.mem.startsWith(u8, line, "## ")) return null;
    const rest = line[3..];
    if (rest.len == 0 or !std.ascii.isDigit(rest[0])) return null;
    const dot = std.mem.indexOf(u8, rest, ". ") orelse return null;
    return .{ .n = rest[0..dot], .title = rest[dot + 2 ..] };
}

fn isParagraphBoundary(line: []const u8) bool {
    return isRoleLine(line) != null or std.mem.startsWith(u8, line, "## ");
}

fn joinParagraph(arena: Allocator, raw_lines: []const []const u8, first_stripped: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, first_stripped);
    for (raw_lines[1..]) |l| {
        try buf.append(arena, '\n');
        try buf.appendSlice(arena, l);
    }
    return std.mem.trimEnd(u8, buf.items, " \t\r\n");
}

fn joinLines(arena: Allocator, raw_lines: []const []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (raw_lines, 0..) |l, idx| {
        if (idx != 0) try buf.append(arena, '\n');
        try buf.appendSlice(arena, l);
    }
    return std.mem.trim(u8, buf.items, " \t\r\n");
}

/// The role named immediately after the first `@` following `anchor`'s
/// last occurrence-search-start — used for both "→ @worker" (a brief's
/// addressee) and "❓ @role" (a question's addressee). Anchored on the
/// marker itself, not "first @ in the paragraph", since a long paragraph
/// can carry unrelated `@`-looking text before the one that matters.
fn roleAfterMarker(text: []const u8, marker: []const u8) ?Role {
    const marker_idx = std.mem.indexOf(u8, text, marker) orelse return null;
    const at_idx = std.mem.indexOfScalarPos(u8, text, marker_idx, '@') orelse return null;
    var end = at_idx + 1;
    while (end < text.len and std.ascii.isLower(text[end])) : (end += 1) {}
    return roleFromTag(text[at_idx + 1 .. end]);
}

fn classifyOutcome(text: []const u8) []const u8 {
    if (std.mem.indexOf(u8, text, "Request changes") != null) return "request-changes";
    if (std.mem.indexOf(u8, text, "Approve, with") != null or
        std.mem.indexOf(u8, text, "Approve with nits") != null) return "approve-with-nits";
    return "approve";
}

/// Classifies and executes one role-tagged paragraph. Priority order
/// matters: a brief and a verdict are identified by how the paragraph
/// *opens* (unambiguous — checked against the whole fixture before this
/// was written); the "ruling" close and the "❓" question checks look
/// anywhere in the body, so a paragraph that could match more than one is
/// resolved brief > close-ruling > verdict > question > post.
fn handleParagraph(
    ctx: *Ctx,
    role: Role,
    text: []const u8,
    current_section: *[]const u8,
    current_block: *[]const u8,
    current_base_sha: *[]const u8,
    block_counters: *std.StringHashMapUnmanaged(u32),
    open_questions: *std.ArrayList(i64),
) !void {
    if (role == .architect and
        (std.mem.startsWith(u8, text, "\u{2192} @") or std.mem.startsWith(u8, text, "Brief")))
    {
        const to = roleAfterMarker(text, "\u{2192}") orelse return error.BriefMissingAddressee;
        const gop = try block_counters.getOrPutValue(ctx.arena, current_section.*, 0);
        gop.value_ptr.* += 1;
        const label = try std.fmt.allocPrint(ctx.arena, "{s}.{d}", .{ current_section.*, gop.value_ptr.* });
        current_block.* = label;
        try ctx.writeCmd(role, "brief", &.{ "--section", current_section.*, "--block", label, "--to", roleName(to) }, text);
        ctx.kinds_seen.insert(.brief);
        return;
    }

    if (role == .architect and
        std.mem.indexOf(u8, text, "ruling on the \u{2753}") != null and
        open_questions.items.len > 0)
    {
        const id = open_questions.orderedRemove(0);
        const id_str = try std.fmt.allocPrint(ctx.arena, "{d}", .{id});
        try ctx.writeCmd(role, "close", &.{ "--item", id_str, "--state", "resolved" }, text);
        ctx.kinds_seen.insert(.close);
        return;
    }

    if (std.mem.startsWith(u8, text, "Verdict on") or std.mem.startsWith(u8, text, "Second pass on block")) {
        const outcome = classifyOutcome(text);
        try ctx.writeCmd(role, "verdict", &.{
            "--section", current_section.*,
            "--block",   current_block.*,
            "--outcome", outcome,
            "--commit",  current_base_sha.*,
        }, text);
        ctx.kinds_seen.insert(.verdict);
        try ctx.expected_verdicts.append(ctx.arena, .{
            .section = current_section.*,
            .block = current_block.*,
            .outcome = outcome,
        });
        return;
    }

    if (std.mem.indexOf(u8, text, "\u{2753}") != null) {
        var extra: std.ArrayList([]const u8) = .empty;
        defer extra.deinit(ctx.arena);
        try extra.appendSlice(ctx.arena, &.{ "--type", "question", "--section", current_section.* });
        if (roleAfterMarker(text, "\u{2753}")) |to| {
            try extra.appendSlice(ctx.arena, &.{ "--to", roleName(to) });
        }
        const id = try ctx.writeItemCmd(role, extra.items, text);
        try open_questions.append(ctx.arena, id);
        ctx.kinds_seen.insert(.item);
        return;
    }

    try ctx.writeCmd(role, "post", &.{ "--section", current_section.* }, text);
    ctx.kinds_seen.insert(.post);
}

fn replay(ctx: *Ctx, fixture_text: []const u8) !void {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(ctx.arena);
    var it = std.mem.splitScalar(u8, fixture_text, '\n');
    while (it.next()) |l| try lines.append(ctx.arena, l);

    try ctx.writeHeader();

    var current_section: []const u8 = "0";
    var current_block: []const u8 = "0";
    var current_base_sha: []const u8 = "unknown";
    var block_counters: std.StringHashMapUnmanaged(u32) = .empty;
    var open_questions: std.ArrayList(i64) = .empty;
    defer open_questions.deinit(ctx.arena);

    var i: usize = 0;
    while (i < lines.items.len) {
        const line = lines.items[i];

        if (std.mem.eql(u8, line, "## NEXT")) {
            const body = try joinLines(ctx.arena, lines.items[i + 1 ..]);
            try ctx.writeCmd(.architect, "next", &.{}, body);
            ctx.kinds_seen.insert(.next);
            break;
        }

        if (isSectionHeading(line)) |h| {
            current_section = h.n;
            i += 1;
            while (i < lines.items.len and std.mem.trim(u8, lines.items[i], " \t\r").len == 0) : (i += 1) {}
            if (i < lines.items.len) {
                if (isRoleLine(lines.items[i])) |rl| {
                    var j = i + 1;
                    while (j < lines.items.len and !isParagraphBoundary(lines.items[j])) : (j += 1) {}
                    const first_stripped = lines.items[i][rl.prefix_len..];
                    const base_prefix = "Base: `";
                    if (std.mem.startsWith(u8, first_stripped, base_prefix)) {
                        const after_tick = first_stripped[base_prefix.len..];
                        const tick_end = std.mem.indexOfScalar(u8, after_tick, '`') orelse after_tick.len;
                        const sha = after_tick[0..tick_end];
                        current_base_sha = sha;
                        const body = try joinParagraph(ctx.arena, lines.items[i..j], first_stripped);
                        try ctx.writeCmd(rl.role, "section", &.{
                            "--section", current_section,
                            "--title",   h.title,
                            "--base",    sha,
                        }, body);
                        ctx.kinds_seen.insert(.section);
                        i = j;
                        continue;
                    }
                }
            }
            continue;
        }

        if (isRoleLine(line)) |rl| {
            var j = i + 1;
            while (j < lines.items.len and !isParagraphBoundary(lines.items[j])) : (j += 1) {}
            const first_stripped = line[rl.prefix_len..];
            const body = try joinParagraph(ctx.arena, lines.items[i..j], first_stripped);
            try handleParagraph(
                ctx,
                rl.role,
                body,
                &current_section,
                &current_block,
                &current_base_sha,
                &block_counters,
                &open_questions,
            );
            i = j;
            continue;
        }

        i += 1;
    }
}

const Replayed = struct {
    tmp: testing.TmpDir,
    log_path: []const u8,
    kinds_seen: std.EnumSet(record.Kind),
    expected_verdicts: std.ArrayList(VerdictTriple),
    records_written: usize,

    fn cleanup(self: *Replayed) void {
        self.tmp.cleanup();
    }
};

fn setupReplay(allocator: Allocator, arena: Allocator, io: Io) !Replayed {
    var tmp = testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const log_path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/DEVLOG.jsonl", .{tmp.sub_path});

    var ctx = Ctx{
        .allocator = allocator,
        .arena = arena,
        .io = io,
        .tmp = &tmp,
        .log_path = log_path,
    };
    const fixture_text = try readFixture(arena, io);
    try replay(&ctx, fixture_text);

    return .{
        .tmp = tmp,
        .log_path = log_path,
        .kinds_seen = ctx.kinds_seen,
        .expected_verdicts = ctx.expected_verdicts,
        .records_written = ctx.records_written,
    };
}

fn foldGrid(arena: Allocator, triples: []const VerdictTriple) ![]VerdictTriple {
    var out: std.ArrayList(VerdictTriple) = .empty;
    for (triples) |t| {
        var updated = false;
        for (out.items) |*existing| {
            if (std.mem.eql(u8, existing.section, t.section) and std.mem.eql(u8, existing.block, t.block)) {
                existing.outcome = t.outcome;
                updated = true;
                break;
            }
        }
        if (!updated) try out.append(arena, t);
    }
    return out.items;
}

// --- 9.1 ---------------------------------------------------------------------

test "9.1: replaying docs/example/DEVLOG.md through the built binary covers every record kind" {
    try requireBinaryBuilt();
    const allocator = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var replayed = try setupReplay(allocator, arena, testing.io);
    defer replayed.cleanup();

    // `kinds_seen`: a claim about the *driver*, not the log — each insert
    // fires in `handleParagraph`/`writeHeader` the moment the fixture's
    // paragraph-detection rule matched and the write returned exit 0, so
    // this loop asserts every one of the fixture's eight paragraph-shape
    // rules fired at least once (e.g. some paragraph really did open with
    // "Verdict on"). It says nothing about what actually landed in the
    // log — that is the separate, log-derived check below — so the two
    // are not duplicates of each other despite both mentioning all eight
    // kinds. What would make this fail: a detection rule's pattern no
    // longer matching anything in the fixture text.
    inline for (@typeInfo(record.Kind).@"enum".fields) |f| {
        const k = @field(record.Kind, f.name);
        if (!replayed.kinds_seen.contains(k)) {
            std.debug.print("missing record kind from replay driver: {s}\n", .{f.name});
            return error.RecordKindNotCovered;
        }
    }

    // The log-derived claim: read back what the binary actually wrote,
    // via `list --json`, and check both that every kind is *present in
    // the log itself* (not merely attempted by the driver — this is what
    // would catch a write command serialising the wrong `kind`, e.g.
    // `close` emitting `"kind":"post"`, which `kinds_seen` above cannot
    // see since it is set from which branch the driver took, not from
    // anything read back) and that the record *count* matches exactly how
    // many writes succeeded (`records_written`, incremented once per
    // `writeCmd`/`writeItemCmd`/`writeHeader` call that returned exit 0).
    // What would make the count assertion fail: a write path that exits 0
    // without appending — the count read back would fall short of
    // `records_written` instead of merely clearing a floor that a
    // truncated replay could still clear.
    var result = try runDevlog(allocator, testing.io, &.{ "--log", replayed.log_path, "list", "--json" }, null);
    defer result.deinit(allocator);
    try expectSuccess(result, "list");
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();

    var kinds_in_log: std.EnumSet(record.Kind) = .initEmpty();
    for (parsed.value.array.items) |rec| {
        const kind_str = rec.object.get("kind").?.string;
        const k = std.meta.stringToEnum(record.Kind, kind_str) orelse {
            std.debug.print("unrecognised kind in produced log: {s}\n", .{kind_str});
            return error.RecordKindNotCovered;
        };
        kinds_in_log.insert(k);
    }
    inline for (@typeInfo(record.Kind).@"enum".fields) |f| {
        const k = @field(record.Kind, f.name);
        if (!kinds_in_log.contains(k)) {
            std.debug.print("missing record kind from produced log: {s}\n", .{f.name});
            return error.RecordKindNotCovered;
        }
    }

    try testing.expectEqual(replayed.records_written, parsed.value.array.items.len);
}

// --- 9.2 ---------------------------------------------------------------------

/// Opens the log the binary produced and runs the **shipped** D7 fold over
/// it (`state.zig`'s `derive`, the same function `resume`/`status`/`show`
/// call in production) — never a second implementation of that fold. Each
/// field is copied into `arena` before `opened`/`derived` are torn down by
/// this function's own defers, since `BlockStatus.section`/`.block`
/// otherwise borrow from `opened`'s backing bytes (see `BlockStatus`'s own
/// doc comment in `state.zig`).
fn deriveGridFromLog(allocator: Allocator, arena: Allocator, io: Io, log_path: []const u8) ![]VerdictTriple {
    var cwd = try Io.Dir.cwd().openDir(io, ".", .{});
    defer cwd.close(io);

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();

    var opened = log.openReadOnly(allocator, io, cwd, log_path, &diag) catch |err| {
        std.debug.print("openReadOnly failed: {s} ({any})\n", .{ diag.message, err });
        return err;
    };
    defer opened.close(allocator);

    var derived = state_mod.derive(allocator, opened.log.records, &diag) catch |err| {
        std.debug.print("state.derive failed: {s} ({any})\n", .{ diag.message, err });
        return err;
    };
    defer derived.deinit();

    var out: std.ArrayList(VerdictTriple) = .empty;
    for (derived.blocks) |b| {
        try out.append(arena, .{
            .section = try arena.dupe(u8, b.section),
            .block = try arena.dupe(u8, b.block),
            .outcome = @tagName(b.currentOutcome()),
        });
    }
    return out.items;
}

test "9.2: the generated status grid matches the verdicts recorded, both sides derived" {
    try requireBinaryBuilt();
    const allocator = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var replayed = try setupReplay(allocator, arena, testing.io);
    defer replayed.cleanup();

    // "Generated": the tool's own retrieval of the verdicts it wrote —
    // never a literal table.
    var result = try runDevlog(allocator, testing.io, &.{
        "--log", replayed.log_path, "list", "--kind", "verdict", "--json",
    }, null);
    defer result.deinit(allocator);
    try expectSuccess(result, "list --kind verdict");
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{});
    defer parsed.deinit();

    var actual_triples: std.ArrayList(VerdictTriple) = .empty;
    defer actual_triples.deinit(arena);
    for (parsed.value.array.items) |v| {
        try actual_triples.append(arena, .{
            .section = v.object.get("section").?.string,
            .block = v.object.get("block").?.string,
            .outcome = v.object.get("outcome").?.string,
        });
    }

    // Round trip: every verdict written is a verdict read back, in order.
    // What would make this fail: a write silently dropped, reordered, or
    // corrupted between `writeCmd` and this read.
    try testing.expectEqual(replayed.expected_verdicts.items.len, actual_triples.items.len);
    for (replayed.expected_verdicts.items, actual_triples.items) |exp, act| {
        try testing.expectEqualStrings(exp.section, act.section);
        try testing.expectEqualStrings(exp.block, act.block);
        try testing.expectEqualStrings(exp.outcome, act.outcome);
    }

    // The grid. "Fixture" side: fold the replay driver's own record of
    // what it wrote, by D7's rule (latest verdict per block wins) — this
    // fold is ours, over data that never touched the tool's derivation,
    // so it is not a duplicate of anything shipped. "Generated" side: the
    // real, shipped `state.zig` fold, run over the log the binary
    // produced (`deriveGridFromLog`) — never reimplemented here. Mixing
    // an in-process call (`state.derive`) into a binary-driven replay is
    // deliberate: 9.1 already proved the binary produces the log; this
    // proves the shipped derivation reads it correctly. Do not "fix" this
    // back to a binary-only round trip — that was the defect the
    // reviewer found (a hand-rolled second fold could pass while the
    // shipped one was wrong).
    const expected_grid = try foldGrid(arena, replayed.expected_verdicts.items);
    const actual_grid = try deriveGridFromLog(allocator, arena, testing.io, replayed.log_path);
    try testing.expectEqual(expected_grid.len, actual_grid.len);
    for (expected_grid, actual_grid) |exp, act| {
        try testing.expectEqualStrings(exp.section, act.section);
        try testing.expectEqualStrings(exp.block, act.block);
        try testing.expectEqualStrings(exp.outcome, act.outcome);
    }

    // The one block this fixture gives multiple verdicts (request-changes,
    // then approve): the shipped fold must resolve to the *latest*. What
    // would make this fail: `state.zig`'s fold picking first-wins instead
    // of latest-wins, which would report "request-changes" here instead.
    var found_multi_verdict_block = false;
    for (actual_grid) |g| {
        if (std.mem.eql(u8, g.block, "4.1")) {
            try testing.expectEqualStrings("approve", g.outcome);
            found_multi_verdict_block = true;
        }
    }
    try testing.expect(found_multi_verdict_block);
}
// --- 9.3 ---------------------------------------------------------------------

fn assertResumeOnlyForRole(allocator: Allocator, json_text: []const u8, role: Role) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();

    // Every returned open item is addressed to exactly this role — never
    // "every open item" and never another role's. What would make this
    // fail: `resume` filtering by the wrong field, or not filtering at
    // all.
    const items = parsed.value.object.get("items").?.array;
    for (items.items) |it| {
        const to = it.object.get("item").?.object.get("to").?.string;
        try testing.expectEqualStrings(roleName(role), to);
    }

    // The brief, when present, is addressed to this role too.
    if (parsed.value.object.get("brief")) |b| {
        switch (b) {
            .null => {},
            .object => |obj| try testing.expectEqualStrings(roleName(role), obj.get("to").?.string),
            else => return error.UnexpectedBriefShape,
        }
    }
}

test "9.3: resume returns only what a role needs, and stays bounded as history grows" {
    try requireBinaryBuilt();
    const allocator = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var replayed = try setupReplay(allocator, arena, testing.io);
    defer replayed.cleanup();

    // "Only what that role needs" — every declared role, an invariant
    // check derived from the JSON shape itself, not a fixed expected list.
    inline for (known_roles) |role| {
        var result = try runDevlog(allocator, testing.io, &.{
            "--log", replayed.log_path, "resume", "--role", roleName(role), "--json",
        }, null);
        defer result.deinit(allocator);
        try expectSuccess(result, "resume");
        try assertResumeOnlyForRole(allocator, result.stdout, role);
    }

    // "Stays small as history grows" — the property section 7 found
    // missing at realistic scale. Copy the replayed log, then grow the
    // copy by 800 records addressed to roles other than `worker` (or
    // closed before `resume` ever runs), so `worker`'s current state does
    // not change even though the underlying log does, substantially.
    var base_result = try runDevlog(allocator, testing.io, &.{
        "--log", replayed.log_path, "resume", "--role", "worker", "--json",
    }, null);
    defer base_result.deinit(allocator);
    try expectSuccess(base_result, "resume");

    const grown_log_path = try std.fmt.allocPrint(
        arena,
        ".zig-cache/tmp/{s}/DEVLOG-grown.jsonl",
        .{replayed.tmp.sub_path},
    );
    try Io.Dir.cwd().copyFile(replayed.log_path, Io.Dir.cwd(), grown_log_path, testing.io, .{ .replace = true });

    const before_stat = try Io.Dir.cwd().statFile(testing.io, replayed.log_path, .{});

    var noise = Ctx{
        .allocator = allocator,
        .arena = arena,
        .io = testing.io,
        .tmp = &replayed.tmp,
        .log_path = grown_log_path,
    };

    // Padded so 800 records substantially outgrow the replayed log's own
    // 250 KB (real prose bodies) without needing thousands of extra
    // subprocess spawns — the growth this checks for is in bytes, and a
    // linear-in-history bug would show it just as clearly at this size.
    const filler = "noise " ** 100;

    var n: usize = 0;
    while (n < 400) : (n += 1) {
        const body = try std.fmt.allocPrint(
            arena,
            "synthetic history record {d} — noise the growth check must not leak through resume. {s}",
            .{ n, filler },
        );
        try noise.writeCmd(.architect, "post", &.{}, body);
    }
    n = 0;
    while (n < 300) : (n += 1) {
        const body = try std.fmt.allocPrint(
            arena,
            "synthetic item {d}, addressed to reviewer, left open. {s}",
            .{ n, filler },
        );
        _ = try noise.writeItemCmd(.architect, &.{ "--type", "task", "--to", "reviewer" }, body);
    }
    n = 0;
    while (n < 100) : (n += 1) {
        const body = try std.fmt.allocPrint(
            arena,
            "synthetic item {d}, addressed to worker, closed immediately. {s}",
            .{ n, filler },
        );
        const id = try noise.writeItemCmd(.architect, &.{ "--type", "task", "--to", "worker" }, body);
        const id_str = try std.fmt.allocPrint(arena, "{d}", .{id});
        try noise.writeCmd(.architect, "close", &.{ "--item", id_str, "--state", "resolved" }, "closed as noise before resume runs.");
    }

    const after_stat = try Io.Dir.cwd().statFile(testing.io, grown_log_path, .{});
    // The corpus really did grow substantially — otherwise the bound
    // below proves nothing.
    try testing.expect(after_stat.size > before_stat.size * 3);

    var grown_result = try runDevlog(allocator, testing.io, &.{
        "--log", grown_log_path, "resume", "--role", "worker", "--json",
    }, null);
    defer grown_result.deinit(allocator);
    try expectSuccess(grown_result, "resume");

    // What would make this fail: `resume` doing anything proportional to
    // total history — a leaked item, a growing byte count — rather than
    // to what is currently open and addressed to `worker`. None of the
    // 800 synthetic records above are open and addressed to `worker`, so
    // a correct `resume` must return byte-for-byte the same result on a
    // log more than 3x larger. A linear-in-history `resume` would either
    // grow this output or take proportionally longer; this asserts the
    // stronger, easily-checked half — the output itself.
    try testing.expectEqualStrings(base_result.stdout, grown_result.stdout);
}
