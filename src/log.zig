// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Locking, atomic replacement, and the `header` record's write-time
//! rules (design.md D11, D13). This is the only module in the change that
//! touches a filesystem so far — `record.zig`'s model and codec stay pure.
//!
//! Every write here follows the same shape: take an exclusive lock on the
//! log (creating it if it does not exist), confirm the lock is not stale
//! (see below), read and parse whatever is already there to learn the
//! next `seq` and the latest `header`, build the complete new file
//! content in memory (existing bytes plus the new line), stage it in a
//! fresh temporary file next to the log, and `rename` that temporary
//! file over the log. `rename` is atomic, so a reader sees either the
//! log's previous content or all of the new content — never a torn
//! record (D11, amended during this block: an in-place positional
//! append cannot make that guarantee, because the write syscall it
//! relies on loops internally and can be interrupted mid-line).
//!
//! **The lock-staleness hazard (D11's amendment, not optional).** The
//! lock is held on the log's *inode*. A `rename` replaces the directory
//! entry, not the inode a still-open file descriptor refers to — so a
//! second writer that opened the log *before* a first writer's `rename`,
//! and is then granted the lock *after* that `rename` completes, ends up
//! holding a lock on an orphaned inode: an append there would never be
//! seen by anyone, the worst failure mode this tool has. Every lock
//! acquisition in this module is therefore followed by re-`stat`ing the
//! path and comparing it against the handle actually held; a mismatch
//! means the lock is stale and the whole open-lock sequence retries
//! against whatever the path names now, bounded so it cannot spin
//! forever.
//!
//! The temporary file this creates is the one exception `durable-format`
//! carves out of "no state exists outside the log file": it lives only
//! for the duration of one write, in the same directory (so `rename` is
//! guaranteed atomic), is removed on every exit path whether the write
//! succeeded or failed, and is never read by any command — a write
//! mechanism, not state.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const record = @import("record.zig");

/// A project's role declaration, as `devlog header` (task 4.10) will
/// supply it. `tool` and `ts` are asked for separately by `appendHeader`
/// rather than folded in here, so a caller cannot construct a
/// `HeaderDeclaration` that quietly claims a different tool's provenance.
pub const HeaderDeclaration = struct {
    change: []const u8,
    roles: []const []const u8,
    closers: []const []const u8,
};

/// What `appendHeader` did. `.unchanged` is not a failure — it is D13's
/// own rule: "an unchanged tool writing an unchanged declaration appends
/// no header at all."
pub const HeaderOutcome = enum { created, appended, unchanged };

pub const HeaderResult = struct {
    outcome: HeaderOutcome,
    /// `null` only when `outcome == .unchanged` — nothing was written, so
    /// there is no new `seq` to report.
    seq: ?u64 = null,
};

/// Bound on how many times `openLocked` retries after finding a stale
/// lock (see the module doc comment). Generous rather than tight: each
/// retry costs one open/lock/stat cycle, and the only way to exhaust it
/// is a concurrent writer completing a full replace on every single one
/// of this many attempts, which is not a scenario a finite bound needs
/// to be tight against — it only needs to exist, so the tool fails loudly
/// instead of spinning forever.
const max_lock_attempts = 64;

/// Bound on how many times `atomicReplace` retries after a temporary-file
/// name collision. Effectively unreachable — each name carries 128 bits
/// of randomness — but "effectively unreachable" is not the same as
/// "unbounded", so this exists anyway.
const max_temp_name_attempts = 8;

/// Long enough for `.<basename>.tmp-<32 hex chars>` for any filename this
/// tool is given, with headroom.
const tmp_name_buf_len = 320;

/// Holds the lock and the file's contents for the duration of one write.
/// Constructed by `openLocked`; always released by `close`, on every path.
const Opened = struct {
    file: Io.File,
    io: Io,
    bytes: []u8,
    log: record.ParsedLog,

    fn close(self: *Opened, allocator: Allocator) void {
        self.log.deinit();
        allocator.free(self.bytes);
        self.file.unlock(self.io);
        self.file.close(self.io);
    }
};

/// Test-only seam (compiled out entirely in non-test builds): if set,
/// called once immediately after `openLocked` acquires a lock, before the
/// staleness recheck. Lets a test deterministically land a simulated
/// concurrent writer's `rename` in the exact window the recheck exists to
/// catch, rather than relying on real OS thread-scheduling luck. Always
/// unset outside this file's own tests.
var test_after_lock_hook: if (builtin.is_test) ?*const fn () void else void =
    if (builtin.is_test) null else {};

/// True when the lock just acquired on `file` is on an inode `sub_path`
/// no longer names — see the module doc comment. Only once this returns
/// `false` can `file`'s content be trusted.
fn isStaleLock(file: Io.File, io: Io, dir: Io.Dir, sub_path: []const u8) !bool {
    const held = try file.stat(io);
    const current = dir.statFile(io, sub_path, .{}) catch |err| switch (err) {
        // The path names nothing at all right now (e.g. renamed away and
        // not yet replaced) — definitely not the inode we're holding.
        error.FileNotFound => return true,
        else => return err,
    };
    return held.inode != current.inode;
}

/// Whether `openLocked` may create the log if the path names nothing yet.
/// `appendHeader` is the only caller that passes `.create_if_missing`
/// (D13: declaring the role set is what brings a log into existence).
/// `appendRecord` always passes `.existing_only` (A2, architect ruling,
/// section 4): a non-header write against a path with no log must never
/// create one — creating it and *then* failing a later check (no header
/// declared, an undeclared role) would leave a zero-byte `DEVLOG.jsonl`
/// behind, the exact hazard `durable-format`'s "no stray files" requirement
/// and the section-3 supervisor's carried finding C2 both name.
const OpenMode = enum { create_if_missing, existing_only };

/// Opens `sub_path` under `dir` for read-write, taking an exclusive lock
/// — creating the file if it does not exist **and** `mode` allows it —
/// confirms the lock is not stale (retrying against whatever the path
/// names now if it is, bounded by `max_lock_attempts`), then reads and
/// parses the entire file. Nothing is written yet: this is "lock, then
/// read the tail" — D11's ordering, with the staleness recheck folded
/// into "lock". If the existing content fails to parse (durable-format: a
/// corrupt or partial tail from an earlier interrupted write), this
/// returns the parse error and touches nothing further — no write is
/// attempted on top of content that cannot be trusted.
fn openLocked(
    allocator: Allocator,
    io: Io,
    dir: Io.Dir,
    sub_path: []const u8,
    mode: OpenMode,
    diag: ?*record.Diagnostics,
) !Opened {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        var file = dir.openFile(io, sub_path, .{ .mode = .read_write, .lock = .exclusive }) catch |err| switch (err) {
            // truncate = false: another writer may have created and
            // populated the file between our failed openFile above and
            // this call. exclusive = false for the same reason — losing
            // the create race to a concurrent writer is not an error, it
            // just means this call did not, in fact, create the file
            // (harmless: nothing here depends on which caller wins that
            // race, and the lock below still serialises what happens
            // next). Whether a header is needed is decided from the
            // record count once parsed, not from which branch opened the
            // file — an existing-but-empty file behaves identically to a
            // brand new one.
            error.FileNotFound => switch (mode) {
                .create_if_missing => try dir.createFile(io, sub_path, .{ .read = true, .truncate = false, .lock = .exclusive }),
                .existing_only => {
                    if (diag) |d| d.set("no log at this path yet — run 'devlog header' first", .{});
                    return error.NoLog;
                },
            },
            else => return err,
        };
        errdefer {
            file.unlock(io);
            file.close(io);
        }

        if (builtin.is_test) {
            if (test_after_lock_hook) |hook| hook();
        }

        if (try isStaleLock(file, io, dir, sub_path)) {
            // Bound check *before* the manual cleanup: on the last
            // allowed attempt, `return` below must be the only thing
            // that releases this handle, so the iteration's `errdefer`
            // does it exactly once. Doing the manual unlock+close first
            // and returning after would double-release — a `return`
            // (unlike `continue`) does not skip the armed `errdefer`,
            // it triggers it (reviewer finding, block 2B: the reversed
            // order aborted the process on 0.16's `fileUnlock`).
            if (attempt + 1 >= max_lock_attempts) return error.StaleLockRetriesExceeded;
            file.unlock(io);
            file.close(io);
            continue;
        }

        const len = try file.length(io);
        const bytes = try allocator.alloc(u8, len);
        errdefer allocator.free(bytes);
        if (len != 0) _ = try file.readPositionalAll(io, bytes, 0);

        const log = try record.parseLog(allocator, bytes, diag);

        return .{ .file = file, .io = io, .bytes = bytes, .log = log };
    }
}

/// The temporary file's name: recognisably this tool's own
/// (`.<basename>.tmp-<hex>`, so a reader can ignore one left behind by a
/// killed process, per `durable-format`'s amended scenario), and unique
/// enough per call that concurrent writers never collide (16 random
/// bytes via `io.random`, ~128 bits) — a dotfile so it doesn't casually
/// show up next to the log in a plain directory listing either.
fn tempName(buf: []u8, io: Io, sub_path: []const u8) ![]const u8 {
    const base = std.fs.path.basename(sub_path);
    var rand_bytes: [16]u8 = undefined;
    io.random(&rand_bytes);
    const hex = std.fmt.bytesToHex(rand_bytes, .lower);
    return std.fmt.bufPrint(buf, ".{s}.tmp-{s}", .{ base, hex });
}

/// Test-only seam (compiled out entirely in non-test builds, same shape as
/// `test_after_lock_hook`): if set, called once inside `atomicReplace`
/// immediately after the temporary file is created, before it is written.
/// A test that makes it return an error deterministically exercises the
/// cleanup path for a failure between temp-file creation and a completed
/// write — the sibling of the already-covered "temp file created, then the
/// rename fails" case.
var test_before_temp_write_hook: if (builtin.is_test) ?*const fn () error{SimulatedTestFailure}!void else void =
    if (builtin.is_test) null else {};

/// `fsync`s the directory itself (its metadata — the name-to-inode
/// mapping a `rename` just changed), not any file in it. Zig's `Io.Dir`
/// doesn't expose this directly, but `Dir.handle` already *is* an open
/// POSIX descriptor for the directory, so wrapping it as an `Io.File`
/// reaches `File.sync`'s existing syscall — no separate open, nothing new
/// acquired or leaked, since the wrapper doesn't own the handle and is
/// never `close`d. Correct on this project's whole target matrix (D12:
/// macOS arm64, Linux x86_64/arm64), where directory `fsync` is
/// well-defined; not assumed to generalise beyond it.
///
/// `dir` must be a genuine directory file descriptor, never the
/// `AT_FDCWD` sentinel (`Io.Dir.cwd()`): the kernel rejects `fsync` on
/// that sentinel with `EBADF`, and Zig 0.16's `Io.Threaded` escalates
/// that failure to a panic rather than returning it as an error.
fn syncDir(dir: Io.Dir, io: Io) !void {
    const as_file: Io.File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
    try as_file.sync(io);
}

/// Stages `content` in a fresh temporary file alongside `sub_path` and
/// `rename`s it into place — D11's amended write mechanism. `rename` is
/// atomic, so a reader observes either the log's previous content or all
/// of `content`, never a torn record. `permissions` is applied to the
/// temporary file via an explicit `setPermissions` (`fchmod`) call after
/// creation, not through `createFile`'s own mode argument — that argument
/// is always filtered through the process umask on POSIX, so a mode more
/// permissive than the umask default would otherwise be silently stripped
/// right back (reviewer finding, block 2B, round two: the first fix used
/// `CreateFileOptions.permissions` and passed only because its one test
/// used a mode that was already a *subset* of the umask default, so the
/// masking was never exercised). See `replaceWith`, which reads the log's
/// *current* permissions (freshly created or pre-existing, either way)
/// and passes them through here. The temporary file is created
/// `exclusive` (never overwrites a same-named leftover — collision is
/// retried under `max_temp_name_attempts`, not silently clobbered) and is
/// removed on every failure path between its creation and the `rename`
/// that consumes it; once `rename` succeeds there is nothing left to
/// clean up, and nothing else in this function can fail afterwards.
///
/// **Durability, not just atomicity (architect ruling, block 2B).**
/// `rename` alone only guarantees a reader never observes a torn record
/// — it says nothing about surviving a power loss, and neither
/// `durable-format` nor D11 carve out that caveat. So the temp file's
/// content is `sync`ed before the `rename` (the new bytes are safely on
/// disk before the name that will point to them changes), and the
/// directory is `sync`ed after (the `rename` itself — the metadata change
/// — is durable too). Both are one `fsync`-class syscall on a file that's
/// hundreds of kilobytes at most, written once per agent post: immaterial
/// at this scale.
fn atomicReplace(io: Io, dir: Io.Dir, sub_path: []const u8, content: []const u8, permissions: Io.File.Permissions) !void {
    var name_buf: [tmp_name_buf_len]u8 = undefined;
    var attempt: usize = 0;
    const tmp_name = while (true) : (attempt += 1) {
        const name = try tempName(&name_buf, io, sub_path);
        // `permissions` is deliberately *not* passed as `CreateFileOptions`'s
        // `.permissions` here — that value goes straight into `open()`'s
        // mode argument, which the kernel always filters through the
        // process umask (reviewer finding: `dirCreateFilePosix` traced,
        // reproduced — `0o664` under a `022` umask becomes `0o644` on
        // disk). `setPermissions` below is a separate `fchmod` call, which
        // is not subject to umask, so it is the only way to actually land
        // a mode more permissive than the umask default.
        var tmp_file = dir.createFile(io, name, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                if (attempt + 1 >= max_temp_name_attempts) return err;
                continue;
            },
            else => return err,
        };
        errdefer {
            tmp_file.close(io);
            dir.deleteFile(io, name) catch {};
        }

        try tmp_file.setPermissions(io, permissions);

        if (builtin.is_test) {
            if (test_before_temp_write_hook) |hook| try hook();
        }

        try tmp_file.writePositionalAll(io, content, 0);
        try tmp_file.sync(io);
        tmp_file.close(io);
        break name;
    };
    errdefer dir.deleteFile(io, tmp_name) catch {};

    try Io.Dir.rename(dir, tmp_name, dir, sub_path, io);
    try syncDir(dir, io);
}

/// Serialises `rec` as one JSON line plus a trailing newline into an owned
/// buffer. Building this fully in memory before anything reaches
/// `atomicReplace` means a failure here (allocation, a writer error) never
/// touches the filesystem at all.
fn encodeLine(allocator: Allocator, rec: record.Record, diag: ?*record.Diagnostics) ![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try record.write(&out.writer, rec, diag);
    try out.writer.writeByte('\n');
    return allocator.dupe(u8, out.written());
}

fn concatOwned(allocator: Allocator, prefix: []const u8, suffix: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, prefix.len + suffix.len);
    @memcpy(out[0..prefix.len], prefix);
    @memcpy(out[prefix.len..], suffix);
    return out;
}

/// Builds the complete new file content (`opened`'s existing bytes plus
/// `rec` as one more line) and replaces the log with it atomically. The
/// lock `opened` holds stays held for the whole operation — the caller's
/// `defer opened.close(...)` releases it only after this returns.
///
/// `opened.file` already *is* the log's current state — freshly created
/// or pre-existing, either way — so reading its permissions here and
/// carrying them onto the replacement handles both cases uniformly: a
/// brand new log gets whatever mode it was just created with (umask
/// applied once, not reset on every subsequent write), and an existing
/// log keeps whatever mode it actually has, including one set outside
/// this tool (e.g. `chmod`) after the fact.
fn replaceWith(
    allocator: Allocator,
    io: Io,
    dir: Io.Dir,
    sub_path: []const u8,
    opened: *const Opened,
    rec: record.Record,
    diag: ?*record.Diagnostics,
) !void {
    const line = try encodeLine(allocator, rec, diag);
    defer allocator.free(line);
    const full = try concatOwned(allocator, opened.bytes, line);
    defer allocator.free(full);
    const permissions = (try opened.file.stat(io)).permissions;
    try atomicReplace(io, dir, sub_path, full, permissions);
}

/// Set equality by mutual containment (D13, section 4 supervisor finding
/// B2): every element of `a` is present in `b` and vice versa. Order
/// carries no meaning, and neither does a repeated element — mutual
/// containment establishes set equality regardless of how many times a
/// value appears on either side, so this stays correct even against a
/// latest header written before `runHeader` started refusing duplicates.
fn sameRoleSet(a: []const []const u8, b: []const []const u8) bool {
    for (a) |x| {
        if (!containsString(b, x)) return false;
    }
    for (b) |y| {
        if (!containsString(a, y)) return false;
    }
    return true;
}

fn headerUnchanged(latest: record.HeaderRecord, tool: []const u8, decl: HeaderDeclaration) bool {
    return std.mem.eql(u8, latest.tool, tool) and
        sameRoleSet(latest.roles, decl.roles) and
        sameRoleSet(latest.closers, decl.closers);
}

fn latestHeader(records: []const record.Record) ?record.HeaderRecord {
    var i = records.len;
    while (i > 0) {
        i -= 1;
        switch (records[i]) {
            .header => |h| return h,
            else => {},
        }
    }
    return null;
}

// `appendHeader` and `appendRecord` below both return a bare `!`
// (inferred error set) rather than a named one, deliberately — unlike
// `record.zig`'s `ParseError`/`SeqError`/`WriteError`, all three named
// (reviewer, section 3 remediation). The rule the difference follows: a
// **named** error set fits a surface that is self-contained — `record.
// zig`'s parsing and serialisation never call outside the file, so the
// set they can raise is fixed and worth writing down. `appendHeader` and
// `appendRecord` are the opposite: each composes `openLocked`, `record.
// parseLog`/`SeqError`, `replaceWith` -> `encodeLine` ->
// `record.write`/`WriteError`, and `atomicReplace`'s several IO failure
// modes — a surface stitched together across modules whose own error
// sets already change independently (this very block added
// `record.WriteError`, which an explicit set here would have had to be
// updated to include, or gone stale — exactly the drift the previously
// declared, unused `AppendRecordError` had already fallen into, with
// only one variant to track). Zig's inferred set is computed exactly
// from the body, at compile time, and updates itself when a callee's
// errors change — it is not `anyerror`; the earlier declared-but-unused
// type was the actual staleness hazard here, not the inferred `!`
// (N-b, section 3 remediation).

/// Declares (or re-declares) the project's role set — the mechanism task
/// 4.10's `devlog header` calls. Locks, reads, and decides against the
/// **latest** header in the file, not the first (design.md D13): a header
/// is appended when the file is created, and again whenever `tool` or the
/// declaration (`roles`, `closers`) differs from that latest header.
/// Otherwise nothing is written — `.unchanged`, not an error.
pub fn appendHeader(
    allocator: Allocator,
    io: Io,
    dir: Io.Dir,
    sub_path: []const u8,
    ts: []const u8,
    tool: []const u8,
    decl: HeaderDeclaration,
    diag: ?*record.Diagnostics,
) !HeaderResult {
    var opened = try openLocked(allocator, io, dir, sub_path, .create_if_missing, diag);
    defer opened.close(allocator);

    const created = opened.log.records.len == 0;

    if (!created) {
        if (latestHeader(opened.log.records)) |latest| {
            if (headerUnchanged(latest, tool, decl)) {
                return .{ .outcome = .unchanged, .seq = null };
            }
        }
    }

    const next_seq = record.nextSeq(opened.log.records);
    const new_header = record.Record{ .header = .{
        .seq = next_seq,
        .ts = ts,
        .format = record.supported_format,
        .tool = tool,
        .change = decl.change,
        .roles = decl.roles,
        .closers = decl.closers,
    } };

    try replaceWith(allocator, io, dir, sub_path, &opened, new_header, diag);

    return .{ .outcome = if (created) .created else .appended, .seq = next_seq };
}

/// Result of the shared locked write path (`appendLocked`): the `seq`
/// assigned under the lock, and — only when the record was `.item` — the
/// item identifier assigned under that same lock (D9). `null` for every
/// other kind.
const AppendedRecord = struct {
    seq: u64,
    item: ?i64,
};

/// The shared locked write path (D11, D13, A1) behind both `appendRecord`
/// and `appendItem`: open, validate the writer against the latest header,
/// derive whatever this record kind needs derived from the parsed log
/// (`seq` always; an `item` number too, when `rec == .item`), stamp, and
/// atomically replace. One locked write path, one place that stamps — a
/// check added here is inherited by both callers instead of needing to be
/// kept in sync across two copies of the glue.
///
/// Opens `.existing_only` (A2): a missing log is refused, naming
/// `devlog header`, rather than created and then possibly left behind by
/// a later refusal. Validates the writer's role against the **latest**
/// header before writing anything (A1, D13, `work-items`) — see
/// `checkRoleAllowed`. For a `.close`, additionally refuses an `--item`
/// naming a number no `item` record has ever raised (`4.5`, architect
/// ruling, DEVLOG `## 4` block 4C brief) — see `checkItemExists`. Closing
/// an already-closed item is deliberately **not** refused here: which
/// close wins is a derivation question (`5.1`), not the write boundary's
/// (append-only-log: a correction is a new record, not a rewrite).
fn appendLocked(
    allocator: Allocator,
    io: Io,
    dir: Io.Dir,
    sub_path: []const u8,
    rec: record.Record,
    diag: ?*record.Diagnostics,
) !AppendedRecord {
    var opened = try openLocked(allocator, io, dir, sub_path, .existing_only, diag);
    defer opened.close(allocator);

    try checkRoleAllowed(opened.log.records, rec, diag);

    if (rec == .close) {
        try checkItemExists(opened.log.records, rec.close.item, diag);
    }

    const next_seq = record.nextSeq(opened.log.records);
    var stamped = withSeq(rec, next_seq);

    const item_num: ?i64 = if (rec == .item) blk: {
        const next_item = countItems(opened.log.records) + 1;
        stamped.item.item = next_item;
        break :blk next_item;
    } else null;

    try replaceWith(allocator, io, dir, sub_path, &opened, stamped, diag);

    return .{ .seq = next_seq, .item = item_num };
}

/// Appends one non-header record, assigning `seq` under the lock (D11)
/// via `appendLocked`. `rec.seq` is ignored and overwritten — callers do
/// not need to compute it, and could not do so safely outside the lock in
/// any case. Returns the assigned `seq`. `rec` must not be `.header` —
/// see `appendHeader`. `rec` must not be `.item` either — item numbering
/// is its own under-the-lock derivation (D9); see `appendItem`.
pub fn appendRecord(
    allocator: Allocator,
    io: Io,
    dir: Io.Dir,
    sub_path: []const u8,
    rec: record.Record,
    diag: ?*record.Diagnostics,
) !u64 {
    if (rec == .header) return error.RecordMustNotBeHeader;
    if (rec == .item) return error.RecordMustBeAppendedViaAppendItem;

    const result = try appendLocked(allocator, io, dir, sub_path, rec, diag);
    return result.seq;
}

pub const AppendItemResult = struct {
    seq: u64,
    /// The assigned identifier — `#<item>` is what `devlog item` prints
    /// (`work-items`: "the tool returns its identifier").
    item: i64,
};

/// Appends an `item` record, assigning **both** `seq` and the item's own
/// identifier under the same lock (`4.4`, D9: "the *n*th `item` record is
/// `#n`"), via `appendLocked`. That number is a function of the log's
/// contents, so it must be derived here, inside the locked read-then-write
/// — the way `appendRecord`'s `seq` already is — never by the caller
/// outside the lock, which is exactly the race `seq` itself would have
/// with two concurrent writers. `rec` must be `.item`; its own `.item`
/// field is ignored and overwritten, exactly as `appendRecord` ignores and
/// overwrites `rec.seq()`. Shares `checkRoleAllowed` with `appendRecord`
/// — the writer-role and `--to` checks are identical for an `item`, not a
/// separate mechanism.
pub fn appendItem(
    allocator: Allocator,
    io: Io,
    dir: Io.Dir,
    sub_path: []const u8,
    rec: record.Record,
    diag: ?*record.Diagnostics,
) !AppendItemResult {
    if (rec != .item) return error.RecordMustBeItem;

    const result = try appendLocked(allocator, io, dir, sub_path, rec, diag);
    return .{ .seq = result.seq, .item = result.item.? };
}

/// How many `item` records `records` already contains — the basis for
/// both D9's next identifier (`appendItem`) and the "how many items exist"
/// half of `checkItemExists`'s refusal message. A pure function of a
/// parsed set, the same shape as `record.nextSeq`.
fn countItems(records: []const record.Record) i64 {
    var count: i64 = 0;
    for (records) |r| {
        if (r == .item) count += 1;
    }
    return count;
}

/// `4.5`, architect ruling (DEVLOG `## 4`, block 4C brief): a close naming
/// an item number the log has never raised is refused rather than silently
/// appended — the parsed log is already in hand under the lock, so this
/// costs one linear scan. The same typo hazard A1's role/`--to` checks
/// already guard against, one field over: a mistyped `--item 7` would
/// otherwise close nothing, leave the real item open forever, and report
/// no fault. Deliberately does **not** check whether the item is already
/// closed — see `appendRecord`'s doc comment for why.
fn checkItemExists(records: []const record.Record, item_num: i64, diag: ?*record.Diagnostics) !void {
    for (records) |r| {
        if (r == .item and r.item.item == item_num) return;
    }
    if (diag) |d| {
        d.set("item #{d} does not exist — {d} item(s) have been raised so far", .{ item_num, countItems(records) });
    }
    return error.ItemNotFound;
}

/// A1 (architect ruling, DEVLOG `## 4`, settling `## NEXT`'s N1): "is
/// this writer entitled to write this record" — role ∈ the **latest**
/// header's declared `roles` for every kind, and role ∈ its declared
/// `closers` additionally when `rec` is `.close` (D13, the `work-items`
/// closer guardrail). One place enforces both, under the lock, against
/// the latest header (D13: "the latest header wins") — so `close` (block
/// 4C) inherits this rather than re-implementing it. Called only from
/// `appendLocked`, which is the single locked write path behind both
/// `appendRecord` and `appendItem` (consolidated closing block 4C's
/// review, precisely so this check cannot come to exist on one path and
/// not the other). `.header` is excluded by both public entry points
/// before `appendLocked` is reached — `appendHeader` does not route
/// through it at all — so `rec.role()` is never `null` here.
///
/// **Extended in block 4B, on D13's own reasoning:** when `rec` carries
/// a `to`, that addressee must also be a declared role. `--to reviewr`
/// would otherwise silently address a brief to nobody, and
/// `devlog resume --role reviewer` (6.1) would never surface it — the
/// same typo hazard D13 already rejects for the writer, applied to the
/// addressee. Checked against the same latest header, in the same
/// lock-held call; not a new mechanism.
fn checkRoleAllowed(records: []const record.Record, rec: record.Record, diag: ?*record.Diagnostics) !void {
    const latest = latestHeader(records) orelse {
        if (diag) |d| d.set("no header declared for this log yet — run 'devlog header' first", .{});
        return error.NoHeader;
    };

    const writer_role = rec.role().?;

    if (!containsString(latest.roles, writer_role)) {
        setUndeclaredMessage(diag, "role '{s}' is not declared for this project — declared roles: {s}", "role '{s}' is not declared", writer_role, latest.roles);
        return error.UndeclaredRole;
    }

    if (rec.to()) |to_role| {
        if (!containsString(latest.roles, to_role)) {
            setUndeclaredMessage(diag, "--to '{s}' is not declared for this project — declared roles: {s}", "--to '{s}' is not declared", to_role, latest.roles);
            return error.UndeclaredTo;
        }
    }

    if (rec == .close and !containsString(latest.closers, writer_role)) {
        setUndeclaredMessage(diag, "role '{s}' is not a declared closer — declared closers: {s}", "role '{s}' is not a declared closer", writer_role, latest.closers);
        return error.RoleNotCloser;
    }
}

fn containsString(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

/// Joins `declared` with `, ` for the diag message so a refusal names the
/// actual roles rather than merely counting them — the point of `4.11`.
/// `comptime fmt` takes exactly two `{s}` args: `subject`, then the joined
/// list. `comptime fallback_fmt` takes exactly one `{s}` arg (`subject`
/// alone) and is used instead on allocation failure — it must not allocate,
/// since the whole point of the fallback path is that allocation just
/// failed. Each of the three call sites passes its own `fallback_fmt` so a
/// degraded message still names which of "role", "--to", or "closer" was
/// wrong rather than defaulting to the writer-role wording regardless of
/// which check triggered it.
fn setUndeclaredMessage(
    diag: ?*record.Diagnostics,
    comptime fmt: []const u8,
    comptime fallback_fmt: []const u8,
    subject: []const u8,
    declared: []const []const u8,
) void {
    const d = diag orelse return;
    const joined = std.mem.join(d.allocator, ", ", declared) catch {
        d.set(fallback_fmt, .{subject});
        return;
    };
    defer d.allocator.free(joined);
    d.set(fmt, .{ subject, joined });
}

fn withSeq(rec: record.Record, new_seq: u64) record.Record {
    var r = rec;
    switch (r) {
        .header => unreachable, // guarded by appendRecord's caller check
        inline .section, .brief, .post, .item, .close, .verdict, .next => |*payload| payload.common.seq = new_seq,
    }
    return r;
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

/// Reads a whole file into an exact-length allocation, independent of
/// `appendHeader`/`appendRecord`, so tests verify what actually landed on
/// disk rather than re-deriving it from this module's own bookkeeping.
/// `dir.readFile` needs a caller-sized buffer and returns a sub-slice of
/// it, which `allocator.free` cannot accept — this always returns exactly
/// what it allocated.
///
/// Test-only helper, `pub` so `body.zig`'s tests can reuse it rather than
/// keeping a second copy (supervisor finding N-f, section 3 remediation).
/// Always reads `"DEVLOG.jsonl"`, matching every test in this file and in
/// `body.zig`'s full-path tests.
pub fn readAllLog(allocator: Allocator, dir: Io.Dir, io: Io) ![]u8 {
    var file = try dir.openFile(io, "DEVLOG.jsonl", .{ .mode = .read_only });
    defer file.close(io);
    const len = try file.length(io);
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    if (len != 0) _ = try file.readPositionalAll(io, buf, 0);
    return buf;
}

test "appendHeader creates the log on first write" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();

    const result = try appendHeader(
        allocator,
        testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "2026-08-14T09:00:00Z",
        "devlog 0.1.0",
        .{ .change = "add-devlog-core", .roles = &.{ "architect", "worker" }, .closers = &.{"architect"} },
        &diag,
    );

    try testing.expectEqual(HeaderOutcome.created, result.outcome);
    try testing.expectEqual(@as(?u64, 1), result.seq);

    const bytes = try readAllLog(allocator, tmp.dir, testing.io);
    defer allocator.free(bytes);
    var log = try record.parseLog(allocator, bytes, &diag);
    defer log.deinit();
    try testing.expectEqual(@as(usize, 1), log.records.len);
    try testing.expectEqual(record.Kind.header, std.meta.activeTag(log.records[0]));
    try testing.expectEqual(@as(?[]const u8, null), log.records[0].role());
}

test "appendHeader is a no-op when the tool version and declaration are unchanged" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();

    const decl: HeaderDeclaration = .{ .change = "add-devlog-core", .roles = &.{"architect"}, .closers = &.{"architect"} };

    const first = try appendHeader(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", "t1", "devlog 0.1.0", decl, &diag);
    try testing.expectEqual(HeaderOutcome.created, first.outcome);

    const second = try appendHeader(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", "t2", "devlog 0.1.0", decl, &diag);
    try testing.expectEqual(HeaderOutcome.unchanged, second.outcome);
    try testing.expectEqual(@as(?u64, null), second.seq);

    const bytes = try readAllLog(allocator, tmp.dir, testing.io);
    defer allocator.free(bytes);
    var log = try record.parseLog(allocator, bytes, &diag);
    defer log.deinit();
    try testing.expectEqual(@as(usize, 1), log.records.len);
}

test "appendHeader re-appends when the tool version differs from the latest header" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();

    const decl: HeaderDeclaration = .{ .change = "x", .roles = &.{"architect"}, .closers = &.{"architect"} };

    _ = try appendHeader(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", "t1", "devlog 0.1.0", decl, &diag);
    const second = try appendHeader(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", "t2", "devlog 0.2.0", decl, &diag);

    try testing.expectEqual(HeaderOutcome.appended, second.outcome);
    try testing.expectEqual(@as(?u64, 2), second.seq);

    const bytes = try readAllLog(allocator, tmp.dir, testing.io);
    defer allocator.free(bytes);
    var log = try record.parseLog(allocator, bytes, &diag);
    defer log.deinit();
    try testing.expectEqual(@as(usize, 2), log.records.len);
    try testing.expectEqualStrings("devlog 0.2.0", log.records[1].header.tool);
}

test "appendHeader re-appends when the declared roles differ from the latest header" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();

    _ = try appendHeader(
        allocator,
        testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t1",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{"architect"}, .closers = &.{"architect"} },
        &diag,
    );
    const second = try appendHeader(
        allocator,
        testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t2",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{ "architect", "reviewer" }, .closers = &.{"architect"} },
        &diag,
    );

    try testing.expectEqual(HeaderOutcome.appended, second.outcome);

    const bytes = try readAllLog(allocator, tmp.dir, testing.io);
    defer allocator.free(bytes);
    var log = try record.parseLog(allocator, bytes, &diag);
    defer log.deinit();
    try testing.expectEqual(@as(usize, 2), log.records.len);
    try testing.expectEqual(@as(usize, 2), log.records[1].header.roles.len);
}

test "appendHeader is a no-op when the same roles are re-declared in a different order" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();

    const first = try appendHeader(
        allocator,
        testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t1",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{ "architect", "worker", "reviewer" }, .closers = &.{ "architect", "worker" } },
        &diag,
    );
    try testing.expectEqual(HeaderOutcome.created, first.outcome);

    const before = try readAllLog(allocator, tmp.dir, testing.io);
    defer allocator.free(before);

    const second = try appendHeader(
        allocator,
        testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t2",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{ "reviewer", "architect", "worker" }, .closers = &.{ "worker", "architect" } },
        &diag,
    );
    try testing.expectEqual(HeaderOutcome.unchanged, second.outcome);
    try testing.expectEqual(@as(?u64, null), second.seq);

    const after = try readAllLog(allocator, tmp.dir, testing.io);
    defer allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

test "the latest header is what governs re-append, not the first" {
    // Three headers: v1 -> v2 -> v1 again. Re-declaring v1's tool after v2
    // must append a third header, because it differs from the *latest*
    // (v2), even though it matches the first.
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();
    const decl: HeaderDeclaration = .{ .change = "x", .roles = &.{"architect"}, .closers = &.{"architect"} };

    _ = try appendHeader(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", "t1", "devlog 0.1.0", decl, &diag);
    _ = try appendHeader(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", "t2", "devlog 0.2.0", decl, &diag);
    const third = try appendHeader(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", "t3", "devlog 0.1.0", decl, &diag);

    try testing.expectEqual(HeaderOutcome.appended, third.outcome);
    try testing.expectEqual(@as(?u64, 3), third.seq);
}

test "appendRecord assigns seq under the lock, starting after the header" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();

    _ = try appendHeader(
        allocator,
        testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t1",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{"architect"}, .closers = &.{"architect"} },
        &diag,
    );

    const post = record.Record{ .post = .{
        .common = .{ .seq = 0, .ts = "t2", .role = "architect", .body = "progress" },
    } };
    const seq = try appendRecord(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", post, &diag);
    try testing.expectEqual(@as(u64, 2), seq);

    const bytes = try readAllLog(allocator, tmp.dir, testing.io);
    defer allocator.free(bytes);
    var log = try record.parseLog(allocator, bytes, &diag);
    defer log.deinit();
    try testing.expectEqual(@as(usize, 2), log.records.len);
    try testing.expectEqual(@as(u64, 2), log.records[1].seq());
}

test "appendRecord refuses a header record rather than bypassing the re-append rule" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const header = record.Record{ .header = .{
        .seq = 0,
        .ts = "t",
        .format = record.supported_format,
        .tool = "devlog 0.1.0",
        .change = "x",
        .roles = &.{"architect"},
        .closers = &.{"architect"},
    } };

    const result = appendRecord(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", header, null);
    try testing.expectError(error.RecordMustNotBeHeader, result);
}

test "appendRecord refuses a write against a log that does not exist yet, naming devlog header, and creates nothing (A2)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();

    const post = record.Record{ .post = .{
        .common = .{ .seq = 0, .ts = "t", .role = "architect", .body = "hi" },
    } };
    const result = appendRecord(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", post, &diag);
    try testing.expectError(error.NoLog, result);
    try testing.expect(std.mem.indexOf(u8, diag.message, "devlog header") != null);

    var count: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next(testing.io)) |_| count += 1;
    try testing.expectEqual(@as(usize, 0), count);
}

test "appendRecord refuses a write when the log exists but has no header, naming devlog header (A1)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var f = try tmp.dir.createFile(testing.io, "DEVLOG.jsonl", .{ .truncate = false });
        defer f.close(testing.io);
    }

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();
    const before = try readAllLog(allocator, tmp.dir, testing.io);
    defer allocator.free(before);

    const post = record.Record{ .post = .{
        .common = .{ .seq = 0, .ts = "t", .role = "architect", .body = "hi" },
    } };
    const result = appendRecord(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", post, &diag);
    try testing.expectError(error.NoHeader, result);
    try testing.expect(std.mem.indexOf(u8, diag.message, "devlog header") != null);

    const after = try readAllLog(allocator, tmp.dir, testing.io);
    defer allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

test "appendRecord refuses a role the latest header did not declare, naming the declared roles (A1, 4.11)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();
    _ = try appendHeader(
        allocator,
        testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t1",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{ "architect", "worker" }, .closers = &.{"architect"} },
        &diag,
    );
    const before = try readAllLog(allocator, tmp.dir, testing.io);
    defer allocator.free(before);

    const post = record.Record{ .post = .{
        .common = .{ .seq = 0, .ts = "t2", .role = "reviewr", .body = "typo'd role" },
    } };
    const result = appendRecord(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", post, &diag);
    try testing.expectError(error.UndeclaredRole, result);
    try testing.expect(std.mem.indexOf(u8, diag.message, "reviewr") != null);
    try testing.expect(std.mem.indexOf(u8, diag.message, "architect") != null);
    try testing.expect(std.mem.indexOf(u8, diag.message, "worker") != null);

    const after = try readAllLog(allocator, tmp.dir, testing.io);
    defer allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

test "appendRecord refuses an addressee (--to) the latest header did not declare, naming the declared roles (block 4B decision)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();
    _ = try appendHeader(
        allocator,
        testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t1",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{ "architect", "worker" }, .closers = &.{"architect"} },
        &diag,
    );
    const before = try readAllLog(allocator, tmp.dir, testing.io);
    defer allocator.free(before);

    const brief = record.Record{ .brief = .{
        .common = .{ .seq = 0, .ts = "t2", .role = "architect", .to = "reviewr", .body = "typo'd addressee" },
    } };
    const result = appendRecord(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", brief, &diag);
    try testing.expectError(error.UndeclaredTo, result);
    try testing.expect(std.mem.indexOf(u8, diag.message, "reviewr") != null);
    try testing.expect(std.mem.indexOf(u8, diag.message, "architect") != null);
    try testing.expect(std.mem.indexOf(u8, diag.message, "worker") != null);

    const after = try readAllLog(allocator, tmp.dir, testing.io);
    defer allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

test "appendRecord accepts a --to naming a declared role, unlike the undeclared-role refusal" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();
    _ = try appendHeader(
        allocator,
        testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t1",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{ "architect", "worker" }, .closers = &.{"architect"} },
        &diag,
    );

    const brief = record.Record{ .brief = .{
        .common = .{ .seq = 0, .ts = "t2", .role = "architect", .to = "worker", .body = "fine" },
    } };
    _ = try appendRecord(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", brief, &diag);

    const bytes = try readAllLog(allocator, tmp.dir, testing.io);
    defer allocator.free(bytes);
    var parsed = try record.parseLog(allocator, bytes, &diag);
    defer parsed.deinit();
    try testing.expectEqualStrings("worker", parsed.records[1].brief.common.to.?);
}

test "appendRecord refuses a close from a role not among the declared closers (A1, forward-looking for 4C)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();
    _ = try appendHeader(
        allocator,
        testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t1",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{ "architect", "worker" }, .closers = &.{"architect"} },
        &diag,
    );

    const close = record.Record{ .close = .{
        .common = .{ .seq = 0, .ts = "t2", .role = "worker", .body = "not mine to close" },
        .item = 1,
        .state = .resolved,
    } };
    const result = appendRecord(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", close, &diag);
    try testing.expectError(error.RoleNotCloser, result);
    try testing.expect(std.mem.indexOf(u8, diag.message, "worker") != null);
    try testing.expect(std.mem.indexOf(u8, diag.message, "architect") != null);
}

test "appendRecord accepts a close from a declared closer (A1)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();
    _ = try appendHeader(
        allocator,
        testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t1",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{"architect"}, .closers = &.{"architect"} },
        &diag,
    );

    // Block 4C: appendRecord now refuses a close naming an item that was
    // never raised, so this test's own item #1 has to exist first — the
    // only change this test needed once that check landed.
    _ = try appendItem(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", .{ .item = .{
        .common = .{ .seq = 0, .ts = "t1a", .role = "architect", .body = "raised" },
        .item = 0,
        .type = .note,
        .blocking = false,
    } }, &diag);

    const close = record.Record{ .close = .{
        .common = .{ .seq = 0, .ts = "t2", .role = "architect", .body = "resolved" },
        .item = 1,
        .state = .resolved,
    } };
    const seq = try appendRecord(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", close, &diag);
    try testing.expectEqual(@as(u64, 3), seq);
}

test "a read against a missing log is a plain not-found, and creates nothing" {
    // appendRecord/appendHeader are writes and are allowed to create the
    // file (D13); this test pins the read-side half of durable-format's
    // requirement structurally, so 6.x's read commands inherit a module
    // that never creates a file on a path that merely inspects one.
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = readAllLog(allocator, tmp.dir, testing.io);
    try testing.expectError(error.FileNotFound, result);
}

test "no file other than the log itself is created by a successful append" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();

    _ = try appendHeader(
        allocator,
        testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{"architect"}, .closers = &.{"architect"} },
        &diag,
    );

    var count: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next(testing.io)) |entry| {
        try testing.expectEqualStrings("DEVLOG.jsonl", entry.name);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "an append that cannot proceed because the existing log is corrupt leaves the file untouched" {
    // Simulates the aftermath of an interrupted write: a log whose last
    // line is not a complete, parseable record (durable-format: "A write
    // interrupted part-way -> the file does not contain a partial
    // record"). The tool cannot un-happen a real crash, but it must never
    // compound one — appendRecord/appendHeader must refuse to build a new
    // record on top of a tail it cannot trust, and must leave the file
    // exactly as found rather than attempting a silent repair (D6:
    // append-only, no rewrite/truncate/delete of anything already there).
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const good_header =
        \\{"kind":"header","seq":1,"ts":"t","format":1,"tool":"devlog 0.1.0","change":"x","roles":["architect"],"closers":["architect"]}
    ;
    const partial_line = "\n{\"kind\":\"post\",\"seq\":2,\"ts\":\"t\",\"role\":\"architect\",\"body\":\"cut off mid-writ";
    const corrupt = good_header ++ partial_line;

    {
        var f = try tmp.dir.createFile(testing.io, "DEVLOG.jsonl", .{ .truncate = false });
        defer f.close(testing.io);
        try f.writePositionalAll(testing.io, corrupt, 0);
    }

    const before = try readAllLog(allocator, tmp.dir, testing.io);
    defer allocator.free(before);

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();
    const post = record.Record{ .post = .{
        .common = .{ .seq = 0, .ts = "t", .role = "architect", .body = "hi" },
    } };
    const result = appendRecord(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", post, &diag);
    try testing.expectError(error.InvalidJson, result);
    try testing.expect(diag.message.len != 0);

    const after = try readAllLog(allocator, tmp.dir, testing.io);
    defer allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

test "isStaleLock detects a rename that replaced the inode a held lock refers to" {
    // Direct, deterministic unit test of the primitive the D11 hazard
    // hinges on — no threading, no timing luck. Written before the
    // integration-level test below so the primitive is trusted on its
    // own terms first.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var held = try tmp.dir.createFile(io, "DEVLOG.jsonl", .{ .read = true, .truncate = false, .lock = .exclusive });
    defer {
        held.unlock(io);
        held.close(io);
    }
    try testing.expect(!(try isStaleLock(held, io, tmp.dir, "DEVLOG.jsonl")));

    // Replace the log out from under `held`, exactly as a concurrent
    // writer's `atomicReplace` would — `held`'s own lock does not
    // prevent this, because the replacement is a *different* inode, not
    // a write to the one `held` has locked.
    var tmp_file = try tmp.dir.createFile(io, ".replacement", .{ .exclusive = true });
    try tmp_file.writePositionalAll(io, "replaced\n", 0);
    tmp_file.close(io);
    try Io.Dir.rename(tmp.dir, ".replacement", tmp.dir, "DEVLOG.jsonl", io);

    try testing.expect(try isStaleLock(held, io, tmp.dir, "DEVLOG.jsonl"));
}

test "a lock made stale by a concurrent rename is detected, retried, and the write is not lost (D11 hazard)" {
    // Integration-level counterpart to the unit test above: forces the
    // exact race window through the real openLocked/appendRecord path,
    // using a test-only hook rather than real thread timing, so the test
    // is deterministic rather than merely likely to catch a regression.
    // Before this fix landed, a version of this module without the
    // staleness recheck would have built its new content from the
    // pre-hook bytes and written it into the inode the hook just
    // orphaned — this record would vanish silently, and the assertions
    // below would fail on the record count and the missing body.
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();

    _ = try appendHeader(
        allocator,
        testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t1",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{"architect"}, .closers = &.{"architect"} },
        &diag,
    );

    const StaleSim = struct {
        var dir: Io.Dir = undefined;
        var io: Io = undefined;
        var ran: bool = false;

        // The content a fully-completed concurrent writer would have
        // left behind: the same header, plus one post this call's
        // in-flight read never saw.
        const content =
            \\{"kind":"header","seq":1,"ts":"t1","format":1,"tool":"devlog 0.1.0","change":"x","roles":["architect"],"closers":["architect"]}
            \\{"kind":"post","seq":2,"ts":"t2","role":"architect","body":"from the concurrent writer"}
            \\
        ;

        // Idempotent: `openLocked`'s retry means this can be reached
        // more than once (its own re-acquired lock is, correctly, not
        // stale the second time), and it must only replace the log once.
        fn run() void {
            if (ran) return;
            ran = true;
            var tmp_file = dir.createFile(io, ".sim-concurrent-writer", .{ .exclusive = true }) catch
                @panic("test setup: createFile failed");
            tmp_file.writePositionalAll(io, content, 0) catch @panic("test setup: write failed");
            tmp_file.close(io);
            Io.Dir.rename(dir, ".sim-concurrent-writer", dir, "DEVLOG.jsonl", io) catch
                @panic("test setup: rename failed");
        }
    };
    StaleSim.dir = tmp.dir;
    StaleSim.io = testing.io;
    StaleSim.ran = false;
    test_after_lock_hook = StaleSim.run;
    defer test_after_lock_hook = null;

    const post = record.Record{ .post = .{
        .common = .{ .seq = 0, .ts = "t3", .role = "architect", .body = "should not be lost" },
    } };
    const seq = try appendRecord(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", post, &diag);
    try testing.expectEqual(@as(u64, 3), seq);

    const bytes = try readAllLog(allocator, tmp.dir, testing.io);
    defer allocator.free(bytes);
    var log = try record.parseLog(allocator, bytes, &diag);
    defer log.deinit();

    try testing.expectEqual(@as(usize, 3), log.records.len);
    try testing.expectEqualStrings("from the concurrent writer", log.records[1].post.common.body);
    try testing.expectEqualStrings("should not be lost", log.records[2].post.common.body);

    // The hazard is specifically about *silent loss into an orphaned
    // inode*, not about stray files — but confirm the simulated writer's
    // own temp file didn't leak either, since the assertions above
    // wouldn't otherwise catch it.
    var count: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next(testing.io)) |entry| {
        try testing.expectEqualStrings("DEVLOG.jsonl", entry.name);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "atomicReplace cleans up its temporary file when the rename fails" {
    // Forces a failure between the temp file's creation (and completed
    // write) and the rename that would consume it (a missing target
    // directory), so a passing test here specifically exercises the
    // errdefer cleanup path rather than only the happy path's implicit
    // absence of leftovers.
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = atomicReplace(io, tmp.dir, "no-such-directory/DEVLOG.jsonl", "content\n", .default_file);
    try testing.expectError(error.FileNotFound, result);

    var count: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next(io)) |entry| {
        try testing.expect(std.mem.indexOf(u8, entry.name, ".tmp-") == null);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 0), count);
}

test "atomicReplace cleans up its temporary file when the write into it fails" {
    // The sibling of the rename-failure test above: forces the failure
    // *before* the rename is ever attempted, between temp-file creation
    // and a completed write, via the test-only hook — deterministic,
    // rather than relying on an environment where a real write can be
    // made to fail (disk full, permission changed mid-flight, neither
    // portable nor reliable to construct).
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const Fail = struct {
        fn run() error{SimulatedTestFailure}!void {
            return error.SimulatedTestFailure;
        }
    };
    test_before_temp_write_hook = Fail.run;
    defer test_before_temp_write_hook = null;

    const result = atomicReplace(io, tmp.dir, "DEVLOG.jsonl", "content\n", .default_file);
    try testing.expectError(error.SimulatedTestFailure, result);

    var count: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next(io)) |entry| {
        try testing.expect(std.mem.indexOf(u8, entry.name, ".tmp-") == null);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 0), count);
}

test "atomic replace preserves the log's existing file permissions rather than resetting them" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();
    _ = try appendHeader(
        allocator,
        testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{"architect"}, .closers = &.{"architect"} },
        &diag,
    );

    // `0o664` is the discriminating case: it is *more* permissive than a
    // typical `022` umask default (`0o644`) would produce — it has the
    // group-write bit a `022` umask always strips. A mode that is a
    // *subset* of the umask default (e.g. `0o640`) would survive whether
    // or not `atomicReplace` actually bypasses umask, because masking an
    // already-masked-down value is a no-op — that shape was tried first
    // and it could not fail, which is exactly the failure mode this test
    // exists to not repeat (reviewer finding, block 2B, round two).
    // Confirmed before writing the fix: with `atomicReplace` applying the
    // mode through `createFile`'s own argument (the buggy shape), this
    // assertion failed with `0o644` on disk under this environment's
    // `022` umask — group-write silently stripped on the very write this
    // test is exercising. `0o640` is kept alongside as a second data
    // point, not the load-bearing one.
    for ([_]std.posix.mode_t{ 0o664, 0o640 }) |mode| {
        const distinctive = Io.File.Permissions.fromMode(mode);
        {
            var f = try tmp.dir.openFile(testing.io, "DEVLOG.jsonl", .{ .mode = .read_write });
            defer f.close(testing.io);
            try f.setPermissions(testing.io, distinctive);
        }

        const post = record.Record{ .post = .{
            .common = .{ .seq = 0, .ts = "t2", .role = "architect", .body = "hi" },
        } };
        _ = try appendRecord(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", post, &diag);

        const stat_after = try tmp.dir.statFile(testing.io, "DEVLOG.jsonl", .{});
        try testing.expectEqual(distinctive.toMode() & 0o777, stat_after.permissions.toMode() & 0o777);
    }
}

test "openLocked gives up after max_lock_attempts with a clean error, not a crash (blocker 1)" {
    // Before the fix, exhausting the retry bound double-released the
    // file handle (manual unlock+close, then the still-armed `errdefer`
    // firing again on the `return`) and aborted the process outright on
    // 0.16's `fileUnlock` — this test reaching its final `expectError`
    // at all, rather than the test binary crashing, is itself part of
    // what it proves.
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();
    _ = try appendHeader(
        allocator,
        testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{"architect"}, .closers = &.{"architect"} },
        &diag,
    );

    const PerpetuallyStale = struct {
        var dir: Io.Dir = undefined;
        var io: Io = undefined;
        var calls: usize = 0;

        // Replaces the log's inode on *every* call, so every attempt
        // `openLocked` makes finds itself stale again — forcing the loop
        // all the way to its bound rather than resolving after one retry.
        fn run() void {
            calls += 1;
            var name_buf: [64]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, ".perpetual-{d}", .{calls}) catch @panic("test setup: name");
            var tmp_file = dir.createFile(io, name, .{ .exclusive = true }) catch @panic("test setup: createFile");
            tmp_file.writePositionalAll(io, "{}\n", 0) catch @panic("test setup: write");
            tmp_file.close(io);
            Io.Dir.rename(dir, name, dir, "DEVLOG.jsonl", io) catch @panic("test setup: rename");
        }
    };
    PerpetuallyStale.dir = tmp.dir;
    PerpetuallyStale.io = testing.io;
    PerpetuallyStale.calls = 0;
    test_after_lock_hook = PerpetuallyStale.run;
    defer test_after_lock_hook = null;

    const post = record.Record{ .post = .{
        .common = .{ .seq = 0, .ts = "t", .role = "architect", .body = "x" },
    } };
    const result = appendRecord(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", post, &diag);
    try testing.expectError(error.StaleLockRetriesExceeded, result);
    try testing.expectEqual(@as(usize, max_lock_attempts), PerpetuallyStale.calls);
}

fn concurrentWorker(
    dir: Io.Dir,
    io: Io,
    allocator: Allocator,
    writes_per_thread: usize,
    err_flag: *std.atomic.Value(bool),
) void {
    for (0..writes_per_thread) |_| {
        const post = record.Record{ .post = .{
            .common = .{ .seq = 0, .ts = "t", .role = "architect", .body = "concurrent" },
        } };
        _ = appendRecord(allocator, io, dir, "DEVLOG.jsonl", post, null) catch {
            err_flag.store(true, .seq_cst);
            return;
        };
    }
}

test "two writers at once: the lock serialises them and every seq is intact" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();
    _ = try appendHeader(
        allocator,
        testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{"architect"}, .closers = &.{"architect"} },
        &diag,
    );

    const thread_count = 4;
    const writes_per_thread = 5;
    var err_flag = std.atomic.Value(bool).init(false);

    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, concurrentWorker, .{ tmp.dir, testing.io, allocator, writes_per_thread, &err_flag });
    }
    for (threads) |t| t.join();

    try testing.expect(!err_flag.load(.seq_cst));

    const bytes = try readAllLog(allocator, tmp.dir, testing.io);
    defer allocator.free(bytes);
    var log = try record.parseLog(allocator, bytes, &diag);
    defer log.deinit();

    // 1 header + thread_count * writes_per_thread posts, and parseLog's
    // own validateSeqOrder already proved the sequence is strictly
    // increasing and contiguous — a torn write or a lost update would
    // have failed that parse outright.
    try testing.expectEqual(@as(usize, 1 + thread_count * writes_per_thread), log.records.len);
    try testing.expectEqual(@as(u64, log.records.len), record.nextSeq(log.records) - 1);
}

test "round-trip: every one of the eight record kinds survives a real file, in order (2.7)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();

    const header_result = try appendHeader(
        allocator,
        testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "2026-08-14T09:00:00Z",
        "devlog 0.1.0",
        .{
            .change = "add-devlog-core",
            .roles = &.{ "architect", "worker", "reviewer", "supervisor" },
            .closers = &.{"architect"},
        },
        &diag,
    );
    try testing.expectEqual(HeaderOutcome.created, header_result.outcome);

    const fenced_body =
        \\Notes on the approach.
        \\
        \\```zig
        \\const x: i32 = 1;
        \\```
        \\
        \\Quotes: "like this" and a trailing backslash\
    ;

    const section = record.Record{ .section = .{
        .common = .{ .seq = 0, .ts = "t2", .role = "architect", .section = "2" },
        .title = "Record model and the log file",
        .base = "0a7d8b0",
    } };
    const brief = record.Record{ .brief = .{
        .common = .{
            .seq = 0,
            .ts = "t3",
            .role = "architect",
            .section = "2",
            .block = "2.5-2.7",
            .to = "worker",
            .refs = &.{.{ .ns = "D", .id = "11" }},
            .body = fenced_body,
        },
    } };
    const post = record.Record{ .post = .{
        .common = .{ .seq = 0, .ts = "t4", .role = "worker", .body = "Locked append implemented." },
    } };
    const item = record.Record{
        .item = .{
            .common = .{
                .seq = 0,
                .ts = "t5",
                .role = "worker",
                .to = "architect",
                .refs = &.{ .{ .ns = "S", .id = "4" }, .{ .ns = "N", .id = "7" } },
                .body = "Should the header carry a role?",
            },
            .item = 0, // ignored — appendItem assigns it under the lock (D9, block 4C)
            .type = .question,
            .blocking = true,
        },
    };
    const close = record.Record{ .close = .{
        .common = .{ .seq = 0, .ts = "t6", .role = "architect", .refs = &.{.{ .ns = "D", .id = "13" }}, .body = "No — exempt." },
        .item = 1,
        .state = .resolved,
    } };
    const verdict = record.Record{ .verdict = .{
        .common = .{ .seq = 0, .ts = "t7", .role = "reviewer", .body = "Approve." },
        .outcome = .approve,
        .commit = "eb01909",
    } };
    const next = record.Record{ .next = .{
        .common = .{ .seq = 0, .ts = "t8", .role = "architect", .body = "Section 2 continues at block 2B." },
    } };

    const seq_section = try appendRecord(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", section, &diag);
    const seq_brief = try appendRecord(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", brief, &diag);
    const seq_post = try appendRecord(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", post, &diag);
    // item is appended via appendItem, not appendRecord (block 4C:
    // appendRecord now refuses .item outright — see its doc comment) —
    // the only line in this test that changed shape when 4C landed.
    const item_result = try appendItem(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", item, &diag);
    const seq_item = item_result.seq;
    try testing.expectEqual(@as(i64, 1), item_result.item);
    const seq_close = try appendRecord(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", close, &diag);
    const seq_verdict = try appendRecord(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", verdict, &diag);
    const seq_next = try appendRecord(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", next, &diag);

    try testing.expectEqual(@as(u64, 2), seq_section);
    try testing.expectEqual(@as(u64, 3), seq_brief);
    try testing.expectEqual(@as(u64, 4), seq_post);
    try testing.expectEqual(@as(u64, 5), seq_item);
    try testing.expectEqual(@as(u64, 6), seq_close);
    try testing.expectEqual(@as(u64, 7), seq_verdict);
    try testing.expectEqual(@as(u64, 8), seq_next);

    const bytes = try readAllLog(allocator, tmp.dir, testing.io);
    defer allocator.free(bytes);
    var log = try record.parseLog(allocator, bytes, &diag);
    defer log.deinit();

    try testing.expectEqual(@as(usize, 8), log.records.len);

    // Order, and that every kind round-tripped as itself.
    const expected_kinds = [_]record.Kind{ .header, .section, .brief, .post, .item, .close, .verdict, .next };
    for (log.records, expected_kinds) |r, k| {
        try testing.expectEqual(k, std.meta.activeTag(r));
    }

    // Header: no role, carries the declared set.
    try testing.expectEqual(@as(?[]const u8, null), log.records[0].role());
    try testing.expectEqual(@as(usize, 4), log.records[0].header.roles.len);
    try testing.expectEqualStrings("architect", log.records[0].header.closers[0]);

    // Section: kind-specific fields plus a common one, optional fields absent.
    try testing.expectEqualStrings("Record model and the log file", log.records[1].section.title);
    try testing.expectEqualStrings("0a7d8b0", log.records[1].section.base);
    try testing.expectEqual(@as(?[]const u8, null), log.records[1].section.common.block);

    // Brief: refs, an addressee, and a body with a fenced code block, a
    // quote, and a trailing backslash, verbatim.
    try testing.expectEqualStrings("worker", log.records[2].brief.common.to.?);
    try testing.expectEqual(@as(usize, 1), log.records[2].brief.common.refs.len);
    try testing.expectEqualStrings("D", log.records[2].brief.common.refs[0].ns);
    try testing.expectEqualStrings(fenced_body, log.records[2].brief.common.body);

    // Post: minimal — just role and body.
    try testing.expectEqualStrings("Locked append implemented.", log.records[3].post.common.body);

    // Item: type, blocking, two refs in different namespaces, an addressee.
    try testing.expectEqual(@as(i64, 1), log.records[4].item.item);
    try testing.expectEqual(record.ItemType.question, log.records[4].item.type);
    try testing.expect(log.records[4].item.blocking);
    try testing.expectEqual(@as(usize, 2), log.records[4].item.common.refs.len);
    try testing.expectEqualStrings("S", log.records[4].item.common.refs[0].ns);
    try testing.expectEqualStrings("N", log.records[4].item.common.refs[1].ns);

    // Close: state and the item it targets.
    try testing.expectEqual(@as(i64, 1), log.records[5].close.item);
    try testing.expectEqual(record.CloseState.resolved, log.records[5].close.state);

    // Verdict: outcome and commit.
    try testing.expectEqual(record.VerdictOutcome.approve, log.records[6].verdict.outcome);
    try testing.expectEqualStrings("eb01909", log.records[6].verdict.commit);

    // Next: the narrative body.
    try testing.expectEqualStrings("Section 2 continues at block 2B.", log.records[7].next.common.body);

    // The whole file re-validates as a single, gap-free, strictly
    // increasing order — the property `append-only-log`'s "Order survives
    // reconstruction" scenario asks for.
    try record.validateSeqOrder(log.records, null);
}

// --- Block 4C: item numbering and the close-target check --------------

fn makeItem(role: []const u8, ts: []const u8) record.Record {
    return .{ .item = .{
        .common = .{ .seq = 0, .ts = ts, .role = role, .body = "raised" },
        .item = 0,
        .type = .note,
        .blocking = false,
    } };
}

test "appendItem assigns item numbers under the lock, starting at 1 and counting up (D9, 4.4)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();
    _ = try appendHeader(
        allocator,
        testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{"architect"}, .closers = &.{"architect"} },
        &diag,
    );

    const first = try appendItem(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", makeItem("architect", "t1"), &diag);
    try testing.expectEqual(@as(i64, 1), first.item);
    try testing.expectEqual(@as(u64, 2), first.seq);

    const second = try appendItem(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", makeItem("architect", "t2"), &diag);
    try testing.expectEqual(@as(i64, 2), second.item);
    try testing.expectEqual(@as(u64, 3), second.seq);

    const bytes = try readAllLog(allocator, tmp.dir, testing.io);
    defer allocator.free(bytes);
    var parsed = try record.parseLog(allocator, bytes, &diag);
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 1), parsed.records[1].item.item);
    try testing.expectEqual(@as(i64, 2), parsed.records[2].item.item);
}

test "appendItem refuses a role the latest header did not declare, and writes nothing (A1, forward from 4A)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();
    _ = try appendHeader(
        allocator,
        testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{"architect"}, .closers = &.{"architect"} },
        &diag,
    );
    const before = try readAllLog(allocator, tmp.dir, testing.io);
    defer allocator.free(before);

    const result = appendItem(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", makeItem("reviewr", "t1"), &diag);
    try testing.expectError(error.UndeclaredRole, result);
    try testing.expect(std.mem.indexOf(u8, diag.message, "reviewr") != null);

    const after = try readAllLog(allocator, tmp.dir, testing.io);
    defer allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

test "appendRecord refuses an .item record outright — it must be appended via appendItem (block 4C)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = appendRecord(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", makeItem("architect", "t"), null);
    try testing.expectError(error.RecordMustBeAppendedViaAppendItem, result);
}

test "appendRecord refuses a close naming an item number that was never raised, and names how many exist (4.5)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();
    _ = try appendHeader(
        allocator,
        testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{"architect"}, .closers = &.{"architect"} },
        &diag,
    );
    _ = try appendItem(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", makeItem("architect", "t1"), &diag);
    const before = try readAllLog(allocator, tmp.dir, testing.io);
    defer allocator.free(before);

    const close = record.Record{ .close = .{
        .common = .{ .seq = 0, .ts = "t2", .role = "architect", .body = "typo'd item number" },
        .item = 7,
        .state = .resolved,
    } };
    const result = appendRecord(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", close, &diag);
    try testing.expectError(error.ItemNotFound, result);
    try testing.expect(std.mem.indexOf(u8, diag.message, "#7") != null);
    try testing.expect(std.mem.indexOf(u8, diag.message, "1") != null);

    const after = try readAllLog(allocator, tmp.dir, testing.io);
    defer allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

test "appendRecord accepts a second close on an already-closed item — a correction, not an error (4.5, architect ruling)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();
    _ = try appendHeader(
        allocator,
        testing.io,
        tmp.dir,
        "DEVLOG.jsonl",
        "t0",
        "devlog 0.1.0",
        .{ .change = "x", .roles = &.{"architect"}, .closers = &.{"architect"} },
        &diag,
    );
    _ = try appendItem(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", makeItem("architect", "t1"), &diag);

    const first_close = record.Record{ .close = .{
        .common = .{ .seq = 0, .ts = "t2", .role = "architect", .body = "deferred for now" },
        .item = 1,
        .state = .deferred,
    } };
    _ = try appendRecord(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", first_close, &diag);

    const second_close = record.Record{ .close = .{
        .common = .{ .seq = 0, .ts = "t3", .role = "architect", .body = "actually resolved" },
        .item = 1,
        .state = .resolved,
    } };
    _ = try appendRecord(allocator, testing.io, tmp.dir, "DEVLOG.jsonl", second_close, &diag);

    const bytes = try readAllLog(allocator, tmp.dir, testing.io);
    defer allocator.free(bytes);
    var parsed = try record.parseLog(allocator, bytes, &diag);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 4), parsed.records.len);
    try testing.expectEqual(record.CloseState.deferred, parsed.records[2].close.state);
    try testing.expectEqual(record.CloseState.resolved, parsed.records[3].close.state);
}
