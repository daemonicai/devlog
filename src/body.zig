// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Reads a record's body from stdin (design.md D5, `append-only-log`).
//!
//! A body is bytes, never parsed, reformatted, or interpreted here or
//! anywhere else in this tool — **no trailing-newline trim, no CRLF
//! translation, no BOM strip, no UTF-8 validation.** If the bytes happen
//! to be invalid UTF-8, that is the caller's business, not this module's;
//! do not "fix" that by adding validation later.
//!
//! This module decides two things and nothing more: *whether to read at
//! all* (refusing a terminal, so the process never blocks waiting on
//! interactive input) and *whether to accept what came back* (refusing an
//! empty or whitespace-only result). Both are refusal decisions, not
//! transforms — the bytes this returns on success are always exactly the
//! bytes that arrived; the whitespace check that decides whether to
//! refuse never produces a trimmed copy.
//!
//! Sections 4/6/7 own the actual `devlog <command>` surface; this module
//! is only the read primitive they call.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const record = @import("record.zig");
const log = @import("log.zig");

/// `StreamTooLong` and `Allocator.Error` come from the underlying
/// `Io.Reader.allocRemaining` call (via `.unlimited` — see `readBody`);
/// `Io.Cancelable` from `isTty`. `ReadFailed` is `Io.Reader`'s own opaque
/// I/O-failure error — the concrete cause isn't threaded through by the
/// standard library's `Io.Reader` interface, only exposed generically.
pub const ReadBodyError = error{
    /// Refused before reading a single byte: stdin is a terminal, so
    /// reading it would block waiting on interactive input the caller
    /// never intends to supply (D5's "guard against hanging").
    StdinIsTerminal,
    /// Refused after reading to EOF: zero bytes, or bytes that are
    /// whitespace only. The bytes read are discarded, not stored — an
    /// accidentally-empty heredoc arrives as a lone newline, and a
    /// record whose body is `"\n"` is noise in a permanent log.
    EmptyBody,
    ReadFailed,
    StreamTooLong,
} || Allocator.Error || Io.Cancelable;

/// Reads `stdin` to EOF and returns its bytes verbatim, caller-owned.
///
/// Reads to EOF, not to a line, not into a fixed-size buffer, and with
/// no size cap (`.unlimited` below) — a real DEVLOG post runs to dozens
/// of lines and this must not silently truncate one.
///
/// Refuses immediately, without reading, if `stdin` is a terminal
/// (`error.StdinIsTerminal`) — this is the one guard against hanging:
/// a terminal blocks on input that will never arrive in an agent
/// harness, and a hung invocation is worse than any error (D5). Refuses
/// after reading if the result is empty or whitespace-only
/// (`error.EmptyBody`).
pub fn readBody(allocator: Allocator, io: Io, stdin: Io.File) ReadBodyError![]u8 {
    if (try stdin.isTty(io)) return error.StdinIsTerminal;

    var buffer: [4096]u8 = undefined;
    var file_reader: Io.File.Reader = .init(stdin, io, &buffer);
    const bytes = file_reader.interface.allocRemaining(allocator, .unlimited) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadFailed => return error.ReadFailed,
        // Structurally unreachable, not just impractical: `Io.Reader.
        // appendRemainingAligned`'s loop only returns `StreamTooLong`
        // after its `remaining` limit reaches `.nothing`, and
        // `Io.Limit.subtract` special-cases `.unlimited` to never
        // decrement — so with the `.unlimited` passed above, that branch
        // of the loop can never execute (verified against the pinned
        // 0.16.0 stdlib source, reviewer finding, block 3). Unlike
        // `log.zig:449`'s `.header => unreachable`, which is guarded by
        // this codebase's own runtime check, this one rests on an
        // external stdlib contract — re-verify it against `Io.Reader`'s
        // source on any Zig version bump, since nothing in this file
        // would fail to compile if that contract changed.
        error.StreamTooLong => unreachable,
    };
    errdefer allocator.free(bytes);

    if (isBlank(bytes)) return error.EmptyBody;

    return bytes;
}

/// Byte-level, deliberately: this module never interprets a body as
/// text in any particular encoding, so "whitespace" here means ASCII
/// whitespace bytes only, checked one byte at a time — not a Unicode
/// notion of blank that would require decoding the body first.
fn isBlank(bytes: []const u8) bool {
    for (bytes) |b| {
        if (!std.ascii.isWhitespace(b)) return false;
    }
    return true;
}

/// Writes the user-facing message for a `readBody` refusal to `w`,
/// without a trailing newline — the caller appends one if it wants one,
/// the way `main.zig`'s own `stderr.print(...)` calls each write their
/// own `"...\n"` today. Kept here, next to the errors it explains,
/// rather than duplicated in every section 4 command that calls
/// `readBody`.
///
/// The terminal message names the real fix — file redirection — because
/// the caller is an agent that needs to know what to do, not just that
/// it was wrong (architect ruling, DEVLOG ## 3).
pub fn writeRefusalMessage(w: *Io.Writer, err: ReadBodyError) void {
    switch (err) {
        error.StdinIsTerminal => w.print(
            "devlog: refusing to read a body from a terminal — redirect it from a file instead, e.g. `devlog post ... < body.md`",
            .{},
        ) catch {},
        error.EmptyBody => w.print("devlog: refusing an empty body", .{}) catch {},
        else => w.print("devlog: failed to read body from stdin: {s}", .{@errorName(err)}) catch {},
    }
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

/// Opens `contents` as a real (non-terminal) file and returns a handle
/// `readBody` can be pointed at in place of `Io.File.stdin()` — every
/// test below exercises the exact same code path a real pipe redirect
/// would take; only the terminal-refusal branch (`3.2`) cannot be
/// exercised this way, since a test harness only ever supplies a pipe,
/// never a real TTY. See the DEVLOG for that gap stated plainly.
fn openAsStdin(dir: std.Io.Dir, io: Io, name: []const u8, contents: []const u8) !Io.File {
    {
        var f = try dir.createFile(io, name, .{ .truncate = true });
        defer f.close(io);
        try f.writePositionalAll(io, contents, 0);
    }
    return dir.openFile(io, name, .{ .mode = .read_only });
}

test "readBody returns the bytes verbatim from a real (non-terminal) file, to EOF" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const contents = "line one\nline two\nline three";
    var f = try openAsStdin(tmp.dir, testing.io, "in", contents);
    defer f.close(testing.io);

    const body = try readBody(allocator, testing.io, f);
    defer allocator.free(body);
    try testing.expectEqualStrings(contents, body);
}

test "readBody refuses a zero-byte body" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var f = try openAsStdin(tmp.dir, testing.io, "in", "");
    defer f.close(testing.io);

    try testing.expectError(error.EmptyBody, readBody(allocator, testing.io, f));
}

test "readBody refuses a body that is whitespace only (a lone newline, the common accident)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var f = try openAsStdin(tmp.dir, testing.io, "in", "\n");
    defer f.close(testing.io);

    try testing.expectError(error.EmptyBody, readBody(allocator, testing.io, f));
}

test "readBody refuses a body of only spaces and tabs, not just a bare newline" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var f = try openAsStdin(tmp.dir, testing.io, "in", "   \t  \n\n  ");
    defer f.close(testing.io);

    try testing.expectError(error.EmptyBody, readBody(allocator, testing.io, f));
}

test "readBody accepts a body of only U+00A0 (non-breaking space) — deliberate, not an oversight" {
    // `isBlank` is byte-level ASCII-only by design (module doc comment):
    // it must never decode the body to reach a Unicode notion of
    // "whitespace", because that would be interpreting content this
    // module is only allowed to inspect at the refusal boundary, not
    // understand. U+00A0 encodes as the two bytes 0xC2 0xA0, neither of
    // which `std.ascii.isWhitespace` recognises, so a body that is
    // *only* non-breaking spaces is accepted verbatim rather than
    // refused as empty. Pinned here so a future "smarter" `isBlank`
    // cannot start refusing it without this test objecting.
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const contents = "\u{00A0}\u{00A0}\u{00A0}";
    var f = try openAsStdin(tmp.dir, testing.io, "in", contents);
    defer f.close(testing.io);

    const body = try readBody(allocator, testing.io, f);
    defer allocator.free(body);
    try testing.expectEqualStrings(contents, body);
}

test "readBody accepts a body that is whitespace plus one real character" {
    // Confirms the blank check looks at every byte rather than, say,
    // only the first or last — a body that is *almost* blank must still
    // be accepted verbatim, whitespace and all.
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const contents = "   \n x \n  ";
    var f = try openAsStdin(tmp.dir, testing.io, "in", contents);
    defer f.close(testing.io);

    const body = try readBody(allocator, testing.io, f);
    defer allocator.free(body);
    try testing.expectEqualStrings(contents, body);
}

test "readBody does not trim, translate, or otherwise touch a real body's bytes" {
    // Fenced code blocks with backticks inside them, a table, text that
    // looks like a flag and like a section heading, apparent JSON, CRLF
    // line endings, and both a present and an absent trailing newline —
    // 3.4's coverage list, each asserted byte-for-byte.
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cases = [_][]const u8{
        // Fenced code block containing backticks of its own.
        "Before.\n\n````markdown\nHere is a fence: ```zig\ncode\n```\n````\n\nAfter.",
        // A Markdown table.
        "| a | b |\n|---|---|\n| 1 | 2 |\n",
        // Text resembling a flag and a role.
        "Run `devlog post --role architect --log DEVLOG.jsonl < body.md`.",
        // Text resembling a tasks.md section heading.
        "## 3. Body input\n\n- [ ] 3.1 not a real task list, just prose",
        // Apparent JSON.
        "{\"kind\":\"post\",\"seq\":4,\"role\":\"architect\",\"body\":\"looks real, isn't\"}",
        // CRLF line endings.
        "line one\r\nline two\r\nline three\r\n",
        // Trailing newline present.
        "trailing newline present\n",
        // Trailing newline absent.
        "trailing newline absent",
    };

    for (cases, 0..) |contents, i| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "in-{d}", .{i});
        var f = try openAsStdin(tmp.dir, testing.io, name, contents);
        defer f.close(testing.io);

        const body = try readBody(allocator, testing.io, f);
        defer allocator.free(body);
        try testing.expectEqualStrings(contents, body);
    }
}

test "writeRefusalMessage for a terminal points at file redirection, naming the real fix" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    writeRefusalMessage(&out.writer, error.StdinIsTerminal);
    const msg = out.written();
    try testing.expect(std.mem.indexOf(u8, msg, "< body.md") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "redirect") != null);
}

test "writeRefusalMessage for an empty body says so plainly" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    writeRefusalMessage(&out.writer, error.EmptyBody);
    try testing.expect(std.mem.indexOf(u8, out.written(), "empty") != null);
}

test "3.4: a body round-trips unchanged through the full read-then-write-then-read path" {
    // Not just readBody's own return value — a body read from stdin,
    // carried into a real record, appended to a real locked-and-atomic
    // log file (log.zig), and parsed back out (record.zig) must come
    // back exactly as it went in. Coverage matches the brief: fenced
    // code blocks with backticks inside them, a table, flag-like and
    // section-heading-like text, apparent JSON, CRLF, and a trailing
    // newline both present and absent.
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();

    _ = try log.appendHeader(
        allocator,
        testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "add-devlog-core", .roles = &.{"architect"}, .closers = &.{"architect"} },
        &diag,
    );

    const cases = [_][]const u8{
        "Before.\n\n````markdown\nHere is a fence: ```zig\ncode\n```\n````\n\nAfter.",
        "| a | b |\n|---|---|\n| 1 | 2 |\n",
        "Run `devlog post --role architect --log DEVLOG.jsonl < body.md`.",
        "## 3. Body input\n\n- [ ] 3.1 not a real task list, just prose",
        "{\"kind\":\"post\",\"seq\":4,\"role\":\"architect\",\"body\":\"looks real, isn't\"}",
        "line one\r\nline two\r\nline three\r\n",
        "trailing newline present\n",
        "trailing newline absent",
    };

    var expected_seq: u64 = 1;
    for (cases, 0..) |contents, i| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "in-{d}", .{i});
        var stdin_file = try openAsStdin(tmp.dir, testing.io, name, contents);
        defer stdin_file.close(testing.io);

        const body = try readBody(allocator, testing.io, stdin_file);
        defer allocator.free(body);
        try testing.expectEqualStrings(contents, body);

        const post = record.Record{ .post = .{
            .common = .{ .seq = 0, .ts = "t", .role = "architect", .body = body },
        } };
        expected_seq += 1;
        const seq = try log.appendRecord(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", post, &diag);
        try testing.expectEqual(expected_seq, seq);
    }

    var f = try tmp.dir.openFile(testing.io, "DEVLOG.jsonl", .{ .mode = .read_only });
    defer f.close(testing.io);
    const len = try f.length(testing.io);
    const bytes = try allocator.alloc(u8, len);
    defer allocator.free(bytes);
    if (len != 0) _ = try f.readPositionalAll(testing.io, bytes, 0);

    var parsed = try record.parseLog(allocator, bytes, &diag);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, cases.len + 1), parsed.records.len);
    for (cases, parsed.records[1..]) |expected, rec| {
        try testing.expectEqualStrings(expected, rec.post.common.body);
    }
}
