// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Derived, in-memory state folded from a parsed log's records
//! (design.md D7, D9, D14; ADR-0002 — no database, no persisted index:
//! everything here is rebuilt from `record.ParsedLog` on every invocation
//! and discarded on exit).
//!
//! `derive` is a pure fold over `[]const record.Record` in file order. It
//! performs **no filesystem access whatsoever** — no open, no stat, no
//! temp file. `State`'s `items[].opened`/`items[].closes`, `blocks[].
//! verdicts` and `next_history` borrow directly from the records passed
//! in: the caller must keep the `record.ParsedLog` it derived from alive
//! for the whole lifetime of the returned `State`. `State.deinit` frees
//! only what `derive` itself allocated — never anything reachable through
//! a borrowed record.
//!
//! **Three folds, one shape — a deliberate split, not an oversight.** Item
//! closes (`5.1`), NEXT history (`5.3`) and verdict history (`5.4`) are
//! all "keep every record for a key in log order, and the last one is
//! current". The two halves of that shape are factored separately rather
//! than forced through one generic container:
//!
//! - **"Latest is current"** is identical in all three and is genuinely
//!   shared: `latest` below is the one place it's written.
//! - **"Grouped by a key"** differs by key domain — item numbers are dense
//!   positional integers assigned in the same pass that discovers them
//!   (a plain array, indexed directly, is the natural fit and is already
//!   reviewed and approved from `5A`); NEXT history has no key at all,
//!   every record belongs to the one implicit group; verdict history and
//!   every `5.5` index key on a string or a `record.Ref`, which is where
//!   `appendGrouped` below *is* shared. Reworking `5A`'s array-indexed
//!   item-close accumulation onto a hash map would trade a direct
//!   reflection of `5.2`'s positional invariant for an indirection with no
//!   behavioural benefit, on code that already cleared two review rounds.

const std = @import("std");
const Allocator = std.mem.Allocator;
const record = @import("record.zig");

/// An item's derived state (work-items: "SHALL be one of: open, resolved,
/// deferred, or superseded"). Distinct from `record.CloseState`, which
/// names only the three closed states a `close` record itself can carry —
/// `open` has no close record to carry it, since it is the absence of one.
pub const ItemState = enum { open, resolved, deferred, superseded };

/// The most recently appended element of an ordered history, or `null` if
/// there is none — the "latest is current" half of the shape shared by
/// item closes (`5.1`), NEXT history (`5.3`) and verdict history (`5.4`).
/// See the module doc comment for why the grouping half is *not* also
/// unified.
fn latest(comptime T: type, entries: []const T) ?T {
    if (entries.len == 0) return null;
    return entries[entries.len - 1];
}

/// Appends `value` under `key` in a hash-keyed accumulator, creating the
/// group's list on first use, and reports whether the group was newly
/// created (`!gop.found_existing`). Shared by the verdict grid (`5.4`) and
/// every string- or `record.Ref`-keyed index (`5.5`) — each is "group
/// values by a key, preserving log order within a group", differing only
/// in the key type, its hash context, and whether the caller needs the
/// "newly created" signal: the verdict grid uses it to track first-verdict
/// insertion order (see `block_order`); the `5.5` indexes discard it, since
/// they are queried by exact key, never enumerated in insertion order.
fn appendGrouped(map: anytype, allocator: Allocator, key: anytype, value: anytype) Allocator.Error!bool {
    const gop = try map.getOrPut(allocator, key);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(allocator, value);
    return !gop.found_existing;
}

/// One raised item, positionally numbered, together with every close
/// record that named it and the state derived from them.
pub const Item = struct {
    /// The positional ordinal — the derived `#n` (D9) — equal to
    /// `opened.item`, which `derive` has already asserted.
    number: i64,
    /// The opening `item` record. Borrowed from the caller's
    /// `record.ParsedLog`.
    opened: record.ItemRecord,
    /// Every close record naming this item, in log order — not just the
    /// winning one. `work-items`: "who closed it, when, and why are all
    /// recoverable." Owned by this `Item` (freed by `State.deinit`); each
    /// element itself still borrows from the caller's `record.ParsedLog`.
    closes: []const record.CloseRecord,
    /// `open` when `closes` is empty; otherwise the state of `closes`'
    /// last element, in log order. `work-items`: "an item closed as
    /// deferred and later resolved is an ordinary sequence rather than an
    /// error ... answered by the ordering the log already carries" — a
    /// second close is not a fault, it is the answer.
    state: ItemState,
};

/// One `(section, block)` pair's verdict history and current status (D7).
pub const BlockStatus = struct {
    /// Borrowed from the `record.VerdictRecord`s in `verdicts` — never
    /// duplicated, so it is valid exactly as long as they are.
    section: []const u8,
    block: []const u8,
    /// Every verdict recorded for this block, in log order. Never empty —
    /// a `BlockStatus` exists only once its first verdict has been folded
    /// in. Owned by this `BlockStatus` (freed by `State.deinit`); each
    /// element still borrows from the caller's `record.ParsedLog`.
    verdicts: []const record.VerdictRecord,

    /// The block's current status: the outcome of the most recently
    /// recorded verdict. A `request-changes` later followed by an
    /// `approve` is the ordinary case (D7); both remain in `verdicts`.
    pub fn currentOutcome(self: BlockStatus) record.VerdictOutcome {
        return latest(record.VerdictRecord, self.verdicts).?.outcome;
    }
};

const StringMultimap = std.HashMapUnmanaged(
    []const u8,
    std.ArrayList(record.Record),
    std.hash_map.StringContext,
    std.hash_map.default_max_load_percentage,
);

const RefKeyContext = struct {
    pub fn hash(self: @This(), key: record.Ref) u64 {
        _ = self;
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(key.ns);
        hasher.update(key.id);
        return hasher.final();
    }
    pub fn eql(self: @This(), a: record.Ref, b: record.Ref) bool {
        _ = self;
        return std.mem.eql(u8, a.ns, b.ns) and std.mem.eql(u8, a.id, b.id);
    }
};

const RefMultimap = std.HashMapUnmanaged(
    record.Ref,
    std.ArrayList(record.Record),
    RefKeyContext,
    std.hash_map.default_max_load_percentage,
);

fn deinitStringMultimap(map: *StringMultimap, allocator: Allocator) void {
    var it = map.valueIterator();
    while (it.next()) |list| list.deinit(allocator);
    map.deinit(allocator);
}

/// Mirrors `record.Record.role()`/`.to()` for the two more `Attributed`
/// fields `5.5`'s indexes need — `null` only for `header`, which carries
/// no `Attributed` at all.
fn recordSection(rec: record.Record) ?[]const u8 {
    return switch (rec) {
        .header => null,
        inline .section, .brief, .post, .item, .close, .verdict, .next => |r| r.common.section,
    };
}

fn recordBlock(rec: record.Record) ?[]const u8 {
    return switch (rec) {
        .header => null,
        inline .section, .brief, .post, .item, .close, .verdict, .next => |r| r.common.block,
    };
}

fn recordRefs(rec: record.Record) []const record.Ref {
    return switch (rec) {
        .header => &.{},
        inline .section, .brief, .post, .item, .close, .verdict, .next => |r| r.common.refs,
    };
}

/// In-memory indexes over one `derive` call's records (and, for
/// `by_state`, its derived items) — built fresh every invocation and
/// discarded with the `State` that owns them (ADR-0002: no persisted
/// index, no cache file, no reuse across runs). Each accessor returns the
/// matching group in log order, or an empty slice if the key was never
/// seen.
pub const Indexes = struct {
    allocator: Allocator,
    by_role: StringMultimap,
    by_section: StringMultimap,
    by_block: StringMultimap,
    /// Records whose `to` names this addressee (`record.Record.to()`).
    by_addressee: StringMultimap,
    by_kind: std.EnumArray(record.Kind, std.ArrayList(record.Record)),
    /// Derived *item* state (`5.1`), not a raw record field — there is no
    /// record kind "state" could otherwise mean.
    by_state: std.EnumArray(ItemState, std.ArrayList(Item)),
    /// Keyed on the exact `(ns, id)` pair (`external-references` `6.4`:
    /// "exact match on the structured reference, not a text search").
    /// A record naming several refs is indexed under each.
    by_reference: RefMultimap,

    pub fn byRole(self: Indexes, role_name: []const u8) []const record.Record {
        return if (self.by_role.get(role_name)) |list| list.items else &.{};
    }
    pub fn bySection(self: Indexes, section: []const u8) []const record.Record {
        return if (self.by_section.get(section)) |list| list.items else &.{};
    }
    pub fn byBlock(self: Indexes, block: []const u8) []const record.Record {
        return if (self.by_block.get(block)) |list| list.items else &.{};
    }
    pub fn byAddressee(self: Indexes, to: []const u8) []const record.Record {
        return if (self.by_addressee.get(to)) |list| list.items else &.{};
    }
    pub fn byKind(self: Indexes, kind: record.Kind) []const record.Record {
        return self.by_kind.get(kind).items;
    }
    pub fn byState(self: Indexes, state: ItemState) []const Item {
        return self.by_state.get(state).items;
    }
    pub fn byReference(self: Indexes, ref: record.Ref) []const record.Record {
        return if (self.by_reference.get(ref)) |list| list.items else &.{};
    }

    pub fn deinit(self: *Indexes) void {
        deinitStringMultimap(&self.by_role, self.allocator);
        deinitStringMultimap(&self.by_section, self.allocator);
        deinitStringMultimap(&self.by_block, self.allocator);
        deinitStringMultimap(&self.by_addressee, self.allocator);
        {
            var it = self.by_kind.iterator();
            while (it.next()) |entry| entry.value.deinit(self.allocator);
        }
        {
            var it = self.by_state.iterator();
            while (it.next()) |entry| entry.value.deinit(self.allocator);
        }
        {
            var it = self.by_reference.valueIterator();
            while (it.next()) |list| list.deinit(self.allocator);
            self.by_reference.deinit(self.allocator);
        }
        self.* = undefined;
    }
};

/// Builds every `5.5` index in one pass over `records`, plus `by_state`
/// over the already-derived `items`. `items` is borrowed for the
/// duration of this call only; the `Item` values copied into `by_state`
/// share (not duplicate) their `closes` slices with `items` — ownership of
/// that memory stays with `State.items`, per `State.deinit`.
fn buildIndexes(
    allocator: Allocator,
    records: []const record.Record,
    items: []const Item,
) Allocator.Error!Indexes {
    var by_role: StringMultimap = .empty;
    errdefer deinitStringMultimap(&by_role, allocator);
    var by_section: StringMultimap = .empty;
    errdefer deinitStringMultimap(&by_section, allocator);
    var by_block: StringMultimap = .empty;
    errdefer deinitStringMultimap(&by_block, allocator);
    var by_addressee: StringMultimap = .empty;
    errdefer deinitStringMultimap(&by_addressee, allocator);
    var by_reference: RefMultimap = .empty;
    errdefer {
        var it = by_reference.valueIterator();
        while (it.next()) |list| list.deinit(allocator);
        by_reference.deinit(allocator);
    }
    var by_kind: std.EnumArray(record.Kind, std.ArrayList(record.Record)) = .initFill(.empty);
    errdefer {
        var it = by_kind.iterator();
        while (it.next()) |entry| entry.value.deinit(allocator);
    }

    for (records) |rec| {
        if (rec.role()) |r| _ = try appendGrouped(&by_role, allocator, r, rec);
        if (recordSection(rec)) |s| _ = try appendGrouped(&by_section, allocator, s, rec);
        if (recordBlock(rec)) |b| _ = try appendGrouped(&by_block, allocator, b, rec);
        if (rec.to()) |t| _ = try appendGrouped(&by_addressee, allocator, t, rec);
        for (recordRefs(rec)) |ref| _ = try appendGrouped(&by_reference, allocator, ref, rec);
        try by_kind.getPtr(std.meta.activeTag(rec)).append(allocator, rec);
    }

    var by_state: std.EnumArray(ItemState, std.ArrayList(Item)) = .initFill(.empty);
    errdefer {
        var it = by_state.iterator();
        while (it.next()) |entry| entry.value.deinit(allocator);
    }
    for (items) |it| try by_state.getPtr(it.state).append(allocator, it);

    return .{
        .allocator = allocator,
        .by_role = by_role,
        .by_section = by_section,
        .by_block = by_block,
        .by_addressee = by_addressee,
        .by_kind = by_kind,
        .by_state = by_state,
        .by_reference = by_reference,
    };
}

/// Derived view of the whole log: every item with its state and full
/// close history, every `(section, block)`'s verdict history, every
/// `next` record with the current one singled out, and the `5.5` indexes
/// over all of it.
pub const State = struct {
    allocator: Allocator,
    /// One entry per raised item, in positional (`#n`) order.
    items: []const Item,
    /// One entry per `(section, block)` pair that has ever received a
    /// verdict (D7), in the order its first verdict was recorded.
    blocks: []const BlockStatus,
    /// Every `next` record, in log order (`next-state`: "every NEXT ever
    /// recorded is available in order"). Borrowed from the caller's
    /// `record.ParsedLog`.
    next_history: []const record.NextRecord,
    /// Built fresh by this `derive` call; discarded with this `State`
    /// (ADR-0002).
    indexes: Indexes,

    /// The most recently appended `next` record, or `null` if none has
    /// ever been recorded (`next-state`: "it receives the most recently
    /// appended one and no other").
    pub fn currentNext(self: State) ?record.NextRecord {
        return latest(record.NextRecord, self.next_history);
    }

    /// Frees only what `derive` allocated: the `items` array and each of
    /// its `closes` slices, the `blocks` array and each of its `verdicts`
    /// slices, the `next_history` array, and `indexes`. Does **not** free
    /// anything reachable through a borrowed `record.ItemRecord` /
    /// `record.CloseRecord` / `record.VerdictRecord` / `record.NextRecord`
    /// — that memory belongs to the `record.ParsedLog` the caller derived
    /// from, and must outlive this `State` by construction, not merely by
    /// convention.
    pub fn deinit(self: *State) void {
        for (self.items) |it| self.allocator.free(it.closes);
        self.allocator.free(self.items);
        for (self.blocks) |b| self.allocator.free(b.verdicts);
        self.allocator.free(self.blocks);
        self.allocator.free(self.next_history);
        self.indexes.deinit();
        self.* = undefined;
    }
};

pub const DeriveError = error{ ItemNumberMismatch, CloseTargetMissing, VerdictMissingKey } || Allocator.Error;

fn closeStateToItemState(state: record.CloseState) ItemState {
    return switch (state) {
        .resolved => .resolved,
        .deferred => .deferred,
        .superseded => .superseded,
    };
}

const BlockKey = struct {
    section: []const u8,
    block: []const u8,
};

const BlockKeyContext = struct {
    pub fn hash(self: @This(), key: BlockKey) u64 {
        _ = self;
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(key.section);
        hasher.update(key.block);
        return hasher.final();
    }
    pub fn eql(self: @This(), a: BlockKey, b: BlockKey) bool {
        _ = self;
        return std.mem.eql(u8, a.section, b.section) and std.mem.eql(u8, a.block, b.block);
    }
};

/// Folds `records` (already in file order, as `record.parseLog` produces
/// them) into a `State`.
///
/// **`5.2`.** Item numbering is derived positionally — the *n*th `item`
/// record is `#n` (D9) — and asserted equal to the record's own stored
/// `item` field. On mismatch this reports a fault via `diag` and returns
/// `error.ItemNumberMismatch`, in the manner `record.validateSeqOrder`
/// already handles a broken `seq`: it does **not** repair, renumber, or
/// prefer one number over the other. Section 4 established that every
/// stored item number was assigned positionally under the lock, so a
/// mismatch means either a log this tool did not write or a bug in this
/// tool (D14's no-repair-path posture: say so, don't paper over it).
///
/// **`5.1`.** A `close` naming an item number with no matching `item`
/// record among those seen so far in the pass — whether the number is
/// out of range entirely, or names an item that only appears *later* in
/// the log — is a fault, not a skip. In an append-only log a close can
/// never precede the item it closes, so both cases mean the same thing
/// `5.2`'s mismatch means: either a log this tool did not write, or a bug
/// in this tool (D14: say so, don't paper over it). `derive` reports it
/// via `diag` and returns `error.CloseTargetMissing`, naming the close's
/// `seq`, the item number it asks for, and how many item records precede
/// it in this single forward pass — never a total the pass has not
/// counted.
///
/// **`5.3`.** Every `next` record is retained in `State.next_history`, in
/// order; `State.currentNext` names the last one.
///
/// **`5.4`.** Every `verdict` is grouped by its `(section, block)` pair
/// into `State.blocks`, in order; `BlockStatus.currentOutcome` names the
/// last one per block (D7). Inherits `5.2`'s ruling directly: `runVerdict`
/// requires both `--section` and `--block`, so every verdict this tool
/// wrote has both — the same invariant class as "every stored close names
/// an item that exists". A verdict missing either is therefore a fault,
/// not a silently dropped grid entry: `derive` reports it via `diag` and
/// returns `error.VerdictMissingKey`.
pub fn derive(
    allocator: Allocator,
    records: []const record.Record,
    diag: ?*record.Diagnostics,
) DeriveError!State {
    var item_records: std.ArrayList(record.ItemRecord) = .empty;
    defer item_records.deinit(allocator);

    // Unconditional `defer`, not `errdefer`: this is the only place
    // `item_closes` is freed, on every path. Each inner list is left at
    // zero length the moment its `toOwnedSlice` runs below — exactly
    // `.empty` on the fast `remap`-succeeds path, and equivalently empty
    // (though not byte-identical to `.empty`: `items.ptr` points at freed
    // memory rather than `&.{}`) on the `clearAndFree` fallback, in either
    // case gated safely by `len == 0` — unlike `deinit`, which sets
    // `undefined`. So deiniting an already-drained list here is a
    // harmless no-op — there is no second cleanup path to keep in sync
    // with this one.
    var item_closes: std.ArrayList(std.ArrayList(record.CloseRecord)) = .empty;
    defer {
        for (item_closes.items) |*list| list.deinit(allocator);
        item_closes.deinit(allocator);
    }

    var next_history: std.ArrayList(record.NextRecord) = .empty;
    errdefer next_history.deinit(allocator);

    // Same discipline as `item_closes` above, and for the same reason: one
    // unconditional `defer`, safe to run whether or not the per-key lists
    // have already been drained by the assembly loop below.
    var block_verdicts: std.HashMapUnmanaged(
        BlockKey,
        std.ArrayList(record.VerdictRecord),
        BlockKeyContext,
        std.hash_map.default_max_load_percentage,
    ) = .empty;
    // Hash-map iteration order is not stable, so enumerating
    // `block_verdicts` directly would make `State.blocks`'s order vary
    // between runs. `block_order` records each key's first-verdict
    // insertion order separately so the assembly loop below can walk
    // `block_verdicts` in a fixed order instead — this is what `5.6`'s
    // determinism test exercises. Do not replace this with a map
    // iteration; it would not be a simplification.
    var block_order: std.ArrayList(BlockKey) = .empty;
    defer {
        var it = block_verdicts.valueIterator();
        while (it.next()) |list| list.deinit(allocator);
        block_verdicts.deinit(allocator);
        block_order.deinit(allocator);
    }

    var ordinal: i64 = 0;
    for (records) |rec| {
        switch (rec) {
            .item => |ir| {
                ordinal += 1;
                if (ir.item != ordinal) {
                    if (diag) |d| d.set(
                        "item record at seq {d} stores item number {d}, but is positionally #{d}",
                        .{ ir.common.seq, ir.item, ordinal },
                    );
                    return error.ItemNumberMismatch;
                }
                try item_records.append(allocator, ir);
                try item_closes.append(allocator, .empty);
            },
            .close => |cr| {
                // `item_closes.items.len` is how many `item` records this
                // forward pass has seen so far. `cr.item` outside `[1,
                // len]` covers both an out-of-range number and a close
                // naming an item that appears *later* in the log — in an
                // append-only log a close can never precede its item, so
                // both are the same fault.
                if (cr.item < 1 or cr.item > item_closes.items.len) {
                    if (diag) |d| d.set(
                        "close at seq {d} names item #{d}, but only {d} item record(s) precede it",
                        .{ cr.common.seq, cr.item, item_closes.items.len },
                    );
                    return error.CloseTargetMissing;
                }
                const idx: usize = @intCast(cr.item - 1);
                try item_closes.items[idx].append(allocator, cr);
            },
            .verdict => |vr| {
                const section = vr.common.section orelse {
                    if (diag) |d| d.set("verdict at seq {d} is missing 'section'", .{vr.common.seq});
                    return error.VerdictMissingKey;
                };
                const block_id = vr.common.block orelse {
                    if (diag) |d| d.set("verdict at seq {d} is missing 'block'", .{vr.common.seq});
                    return error.VerdictMissingKey;
                };
                const key = BlockKey{ .section = section, .block = block_id };
                if (try appendGrouped(&block_verdicts, allocator, key, vr)) try block_order.append(allocator, key);
            },
            .next => |nr| try next_history.append(allocator, nr),
            else => {},
        }
    }

    var items: std.ArrayList(Item) = .empty;
    errdefer {
        for (items.items) |it| allocator.free(it.closes);
        items.deinit(allocator);
    }
    for (item_records.items, 0..) |ir, i| {
        const closes = try item_closes.items[i].toOwnedSlice(allocator);
        errdefer allocator.free(closes);
        const state: ItemState = if (latest(record.CloseRecord, closes)) |c|
            closeStateToItemState(c.state)
        else
            .open;
        try items.append(allocator, .{
            .number = @intCast(i + 1),
            .opened = ir,
            .closes = closes,
            .state = state,
        });
    }

    const items_slice = try items.toOwnedSlice(allocator);
    errdefer {
        for (items_slice) |it| allocator.free(it.closes);
        allocator.free(items_slice);
    }

    var blocks: std.ArrayList(BlockStatus) = .empty;
    errdefer {
        for (blocks.items) |b| allocator.free(b.verdicts);
        blocks.deinit(allocator);
    }
    for (block_order.items) |key| {
        const list = block_verdicts.getPtr(key).?;
        const verdicts = try list.toOwnedSlice(allocator);
        errdefer allocator.free(verdicts);
        try blocks.append(allocator, .{ .section = key.section, .block = key.block, .verdicts = verdicts });
    }

    const blocks_slice = try blocks.toOwnedSlice(allocator);
    errdefer {
        for (blocks_slice) |b| allocator.free(b.verdicts);
        allocator.free(blocks_slice);
    }

    var indexes = try buildIndexes(allocator, records, items_slice);
    errdefer indexes.deinit();

    const next_slice = try next_history.toOwnedSlice(allocator);

    return .{
        .allocator = allocator,
        .items = items_slice,
        .blocks = blocks_slice,
        .next_history = next_slice,
        .indexes = indexes,
    };
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

fn item(seq: u64, n: i64) record.Record {
    return .{ .item = .{
        .common = .{ .seq = seq, .ts = "t", .role = "worker" },
        .item = n,
        .type = .task,
        .blocking = false,
    } };
}

fn close(seq: u64, n: i64, state: record.CloseState) record.Record {
    return .{ .close = .{
        .common = .{ .seq = seq, .ts = "t", .role = "architect", .body = "because" },
        .item = n,
        .state = state,
    } };
}

fn next(seq: u64, body: []const u8) record.Record {
    return .{ .next = .{
        .common = .{ .seq = seq, .ts = "t", .role = "architect", .body = body },
    } };
}

fn verdict(
    seq: u64,
    section: []const u8,
    block_id: []const u8,
    outcome: record.VerdictOutcome,
    commit: []const u8,
) record.Record {
    return .{ .verdict = .{
        .common = .{ .seq = seq, .ts = "t", .role = "reviewer", .section = section, .block = block_id },
        .outcome = outcome,
        .commit = commit,
    } };
}

fn verdictMissingSection(
    seq: u64,
    block_id: []const u8,
    outcome: record.VerdictOutcome,
    commit: []const u8,
) record.Record {
    return .{ .verdict = .{
        .common = .{ .seq = seq, .ts = "t", .role = "reviewer", .block = block_id },
        .outcome = outcome,
        .commit = commit,
    } };
}

fn verdictMissingBlock(
    seq: u64,
    section: []const u8,
    outcome: record.VerdictOutcome,
    commit: []const u8,
) record.Record {
    return .{ .verdict = .{
        .common = .{ .seq = seq, .ts = "t", .role = "reviewer", .section = section },
        .outcome = outcome,
        .commit = commit,
    } };
}

test "an item with no close is derived as open" {
    const allocator = testing.allocator;
    const records = [_]record.Record{item(1, 1)};
    var state = try derive(allocator, &records, null);
    defer state.deinit();

    try testing.expectEqual(@as(usize, 1), state.items.len);
    try testing.expectEqual(ItemState.open, state.items[0].state);
    try testing.expectEqual(@as(usize, 0), state.items[0].closes.len);
}

test "each close state (resolved, deferred, superseded) derives the matching item state" {
    const allocator = testing.allocator;

    inline for (.{
        .{ record.CloseState.resolved, ItemState.resolved },
        .{ record.CloseState.deferred, ItemState.deferred },
        .{ record.CloseState.superseded, ItemState.superseded },
    }) |case| {
        const records = [_]record.Record{ item(1, 1), close(2, 1, case[0]) };
        var state = try derive(allocator, &records, null);
        defer state.deinit();

        try testing.expectEqual(@as(usize, 1), state.items[0].closes.len);
        try testing.expectEqual(case[1], state.items[0].state);
    }
}

test "a second close overrides the first, in log order, and both are retained" {
    const allocator = testing.allocator;
    const records = [_]record.Record{
        item(1, 1),
        close(2, 1, .deferred),
        close(3, 1, .resolved),
    };
    var state = try derive(allocator, &records, null);
    defer state.deinit();

    try testing.expectEqual(@as(usize, 1), state.items.len);
    try testing.expectEqual(ItemState.resolved, state.items[0].state);
    try testing.expectEqual(@as(usize, 2), state.items[0].closes.len);
    try testing.expectEqual(record.CloseState.deferred, state.items[0].closes[0].state);
    try testing.expectEqual(record.CloseState.resolved, state.items[0].closes[1].state);
}

test "interleaved items and closes attach each close to the item it names, not by position" {
    const allocator = testing.allocator;
    const records = [_]record.Record{
        item(1, 1),
        item(2, 2),
        close(3, 1, .resolved),
        item(4, 3),
        close(5, 2, .deferred),
        close(6, 3, .superseded),
    };
    var state = try derive(allocator, &records, null);
    defer state.deinit();

    try testing.expectEqual(@as(usize, 3), state.items.len);
    try testing.expectEqual(ItemState.resolved, state.items[0].state);
    try testing.expectEqual(ItemState.deferred, state.items[1].state);
    try testing.expectEqual(ItemState.superseded, state.items[2].state);
    try testing.expectEqual(@as(i64, 1), state.items[0].number);
    try testing.expectEqual(@as(i64, 2), state.items[1].number);
    try testing.expectEqual(@as(i64, 3), state.items[2].number);
}

test "a double close on one item survives interleaving with another item's records" {
    const allocator = testing.allocator;
    const records = [_]record.Record{
        item(1, 1),
        item(2, 2),
        close(3, 1, .deferred),
        close(4, 2, .resolved),
        close(5, 1, .resolved),
        item(6, 3),
        close(7, 2, .superseded),
    };
    var state = try derive(allocator, &records, null);
    defer state.deinit();

    try testing.expectEqual(@as(usize, 3), state.items.len);

    // Item 1: deferred then resolved, with an unrelated item 2 close and
    // item 3's own opening falling between the two closes.
    try testing.expectEqual(@as(usize, 2), state.items[0].closes.len);
    try testing.expectEqual(record.CloseState.deferred, state.items[0].closes[0].state);
    try testing.expectEqual(record.CloseState.resolved, state.items[0].closes[1].state);
    try testing.expectEqual(ItemState.resolved, state.items[0].state);

    // Item 2: resolved then superseded, with item 1's second close and
    // item 3's opening interleaved between the two.
    try testing.expectEqual(@as(usize, 2), state.items[1].closes.len);
    try testing.expectEqual(record.CloseState.resolved, state.items[1].closes[0].state);
    try testing.expectEqual(record.CloseState.superseded, state.items[1].closes[1].state);
    try testing.expectEqual(ItemState.superseded, state.items[1].state);

    // Item 3: opened last, never closed.
    try testing.expectEqual(@as(usize, 0), state.items[2].closes.len);
    try testing.expectEqual(ItemState.open, state.items[2].state);
}

test "a close naming an item outside the range seen so far is a fault, not a silent skip" {
    const allocator = testing.allocator;
    const records = [_]record.Record{
        item(1, 1),
        close(2, 5, .resolved),
    };
    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();
    const result = derive(allocator, &records, &diag);
    try testing.expectError(error.CloseTargetMissing, result);
    try testing.expect(std.mem.indexOf(u8, diag.message, "#5") != null);
    try testing.expect(std.mem.indexOf(u8, diag.message, "1 item record") != null);
}

test "a close naming an item that appears later in the log is a fault (a close cannot precede its item)" {
    const allocator = testing.allocator;
    const records = [_]record.Record{
        close(1, 2, .resolved),
        item(2, 1),
        item(3, 2),
    };
    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();
    const result = derive(allocator, &records, &diag);
    try testing.expectError(error.CloseTargetMissing, result);
    try testing.expect(std.mem.indexOf(u8, diag.message, "#2") != null);
    try testing.expect(std.mem.indexOf(u8, diag.message, "0 item record") != null);
}

test "positional numbering holds across a log where item records are separated by other kinds" {
    const allocator = testing.allocator;
    const records = [_]record.Record{
        item(1, 1),
        next(2, "resume at 5.1"),
        close(3, 1, .resolved),
        item(4, 2),
    };
    var state = try derive(allocator, &records, null);
    defer state.deinit();

    try testing.expectEqual(@as(usize, 2), state.items.len);
    try testing.expectEqual(@as(i64, 1), state.items[0].number);
    try testing.expectEqual(@as(i64, 2), state.items[1].number);
}

test "a mismatched stored item number is reported as a fault, not repaired" {
    const allocator = testing.allocator;
    const records = [_]record.Record{
        item(1, 1),
        item(2, 5),
    };
    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();
    const result = derive(allocator, &records, &diag);
    try testing.expectError(error.ItemNumberMismatch, result);
    try testing.expect(std.mem.indexOf(u8, diag.message, "5") != null);
    try testing.expect(std.mem.indexOf(u8, diag.message, "#2") != null);
}

test "no next record at all leaves history empty and current null" {
    const allocator = testing.allocator;
    const records = [_]record.Record{item(1, 1)};
    var state = try derive(allocator, &records, null);
    defer state.deinit();

    try testing.expectEqual(@as(usize, 0), state.next_history.len);
    try testing.expectEqual(@as(?record.NextRecord, null), state.currentNext());
}

test "one next superseding another is current, and the full history is retained in order" {
    const allocator = testing.allocator;
    const records = [_]record.Record{
        next(1, "first plan"),
        next(2, "revised plan"),
    };
    var state = try derive(allocator, &records, null);
    defer state.deinit();

    try testing.expectEqual(@as(usize, 2), state.next_history.len);
    try testing.expectEqualStrings("first plan", state.next_history[0].common.body);
    try testing.expectEqualStrings("revised plan", state.next_history[1].common.body);
    try testing.expectEqualStrings("revised plan", state.currentNext().?.common.body);
}

test "a block's status is the outcome of its most recently recorded verdict, and both are retained" {
    const allocator = testing.allocator;
    const records = [_]record.Record{
        verdict(1, "5", "5.1-5.3", .@"request-changes", "abc"),
        verdict(2, "5", "5.1-5.3", .approve, "def"),
    };
    var state = try derive(allocator, &records, null);
    defer state.deinit();

    try testing.expectEqual(@as(usize, 1), state.blocks.len);
    try testing.expectEqual(@as(usize, 2), state.blocks[0].verdicts.len);
    try testing.expectEqual(record.VerdictOutcome.@"request-changes", state.blocks[0].verdicts[0].outcome);
    try testing.expectEqual(record.VerdictOutcome.approve, state.blocks[0].verdicts[1].outcome);
    try testing.expectEqual(record.VerdictOutcome.approve, state.blocks[0].currentOutcome());
}

test "two different blocks are tracked independently, in order of first verdict" {
    const allocator = testing.allocator;
    const records = [_]record.Record{
        verdict(1, "5", "5.4-5.6", .approve, "bbb"),
        verdict(2, "5", "5.1-5.3", .@"request-changes", "aaa"),
    };
    var state = try derive(allocator, &records, null);
    defer state.deinit();

    try testing.expectEqual(@as(usize, 2), state.blocks.len);
    try testing.expectEqualStrings("5.4-5.6", state.blocks[0].block);
    try testing.expectEqualStrings("5.1-5.3", state.blocks[1].block);
    try testing.expectEqual(record.VerdictOutcome.approve, state.blocks[0].currentOutcome());
    try testing.expectEqual(record.VerdictOutcome.@"request-changes", state.blocks[1].currentOutcome());
}

test "a verdict missing 'section' is a fault, not a silently dropped grid entry" {
    const allocator = testing.allocator;
    const records = [_]record.Record{verdictMissingSection(1, "5.1-5.3", .approve, "aaa")};
    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();
    const result = derive(allocator, &records, &diag);
    try testing.expectError(error.VerdictMissingKey, result);
    try testing.expect(std.mem.indexOf(u8, diag.message, "section") != null);
}

test "a verdict missing 'block' is a fault, not a silently dropped grid entry" {
    const allocator = testing.allocator;
    const records = [_]record.Record{verdictMissingBlock(1, "5", .approve, "aaa")};
    var diag: record.Diagnostics = .init(allocator);
    defer diag.deinit();
    const result = derive(allocator, &records, &diag);
    try testing.expectError(error.VerdictMissingKey, result);
    try testing.expect(std.mem.indexOf(u8, diag.message, "block") != null);
}

test "indexes group records by role, section, and block" {
    const allocator = testing.allocator;
    const records = [_]record.Record{
        item(1, 1),
        close(2, 1, .resolved),
        verdict(3, "5", "5.1-5.3", .approve, "aaa"),
    };
    var state = try derive(allocator, &records, null);
    defer state.deinit();

    try testing.expectEqual(@as(usize, 1), state.indexes.byRole("worker").len);
    try testing.expectEqual(@as(usize, 1), state.indexes.byRole("architect").len);
    try testing.expectEqual(@as(usize, 1), state.indexes.byRole("reviewer").len);
    try testing.expectEqual(@as(usize, 0), state.indexes.byRole("nobody").len);

    try testing.expectEqual(@as(usize, 1), state.indexes.bySection("5").len);
    try testing.expectEqual(@as(usize, 0), state.indexes.bySection("99").len);
    try testing.expectEqual(@as(usize, 1), state.indexes.byBlock("5.1-5.3").len);
}

test "the kind index groups every record by its own kind, including those derive ignores" {
    const allocator = testing.allocator;
    const records = [_]record.Record{
        item(1, 1),
        item(2, 2),
        close(3, 1, .resolved),
        next(4, "plan"),
    };
    var state = try derive(allocator, &records, null);
    defer state.deinit();

    try testing.expectEqual(@as(usize, 2), state.indexes.byKind(.item).len);
    try testing.expectEqual(@as(usize, 1), state.indexes.byKind(.close).len);
    try testing.expectEqual(@as(usize, 1), state.indexes.byKind(.next).len);
    try testing.expectEqual(@as(usize, 0), state.indexes.byKind(.verdict).len);
}

test "the state index groups derived items by ItemState, not raw records" {
    const allocator = testing.allocator;
    const records = [_]record.Record{
        item(1, 1),
        item(2, 2),
        close(3, 1, .resolved),
    };
    var state = try derive(allocator, &records, null);
    defer state.deinit();

    try testing.expectEqual(@as(usize, 1), state.indexes.byState(.open).len);
    try testing.expectEqual(@as(usize, 1), state.indexes.byState(.resolved).len);
    try testing.expectEqual(@as(usize, 0), state.indexes.byState(.deferred).len);
    try testing.expectEqual(@as(i64, 2), state.indexes.byState(.open)[0].number);
}

test "the addressee index groups records by their 'to' field" {
    const allocator = testing.allocator;
    const records = [_]record.Record{
        .{ .post = .{ .common = .{ .seq = 1, .ts = "t", .role = "architect", .to = "worker", .body = "go" } } },
        .{ .post = .{ .common = .{ .seq = 2, .ts = "t", .role = "architect", .body = "no addressee" } } },
    };
    var state = try derive(allocator, &records, null);
    defer state.deinit();

    try testing.expectEqual(@as(usize, 1), state.indexes.byAddressee("worker").len);
    try testing.expectEqual(@as(usize, 0), state.indexes.byAddressee("reviewer").len);
}

test "the reference index is an exact (ns, id) match, never a prefix" {
    const allocator = testing.allocator;
    const records = [_]record.Record{
        .{ .post = .{ .common = .{
            .seq = 1,
            .ts = "t",
            .role = "architect",
            .refs = &.{.{ .ns = "D", .id = "1" }},
            .body = "about D1",
        } } },
        .{ .post = .{ .common = .{
            .seq = 2,
            .ts = "t",
            .role = "architect",
            .refs = &.{.{ .ns = "D", .id = "10" }},
            .body = "about D10",
        } } },
    };
    var state = try derive(allocator, &records, null);
    defer state.deinit();

    try testing.expectEqual(@as(usize, 1), state.indexes.byReference(.{ .ns = "D", .id = "1" }).len);
    try testing.expectEqual(@as(usize, 1), state.indexes.byReference(.{ .ns = "D", .id = "10" }).len);
    try testing.expectEqual(@as(usize, 0), state.indexes.byReference(.{ .ns = "D", .id = "100" }).len);
}

test "a record naming several refs is indexed under each" {
    const allocator = testing.allocator;
    const records = [_]record.Record{
        .{ .post = .{ .common = .{
            .seq = 1,
            .ts = "t",
            .role = "architect",
            .refs = &.{ .{ .ns = "D", .id = "1" }, .{ .ns = "N", .id = "3" } },
            .body = "touches both",
        } } },
    };
    var state = try derive(allocator, &records, null);
    defer state.deinit();

    try testing.expectEqual(@as(usize, 1), state.indexes.byReference(.{ .ns = "D", .id = "1" }).len);
    try testing.expectEqual(@as(usize, 1), state.indexes.byReference(.{ .ns = "N", .id = "3" }).len);
}

fn expectStatesEqual(a: State, b: State) !void {
    try testing.expectEqual(a.items.len, b.items.len);
    for (a.items, b.items) |ia, ib| {
        try testing.expectEqual(ia.number, ib.number);
        try testing.expectEqual(ia.opened.item, ib.opened.item);
        try testing.expectEqual(ia.opened.type, ib.opened.type);
        try testing.expectEqual(ia.opened.blocking, ib.opened.blocking);
        try testing.expectEqual(ia.state, ib.state);
        try testing.expectEqual(ia.closes.len, ib.closes.len);
        for (ia.closes, ib.closes) |ca, cb| {
            try testing.expectEqual(ca.item, cb.item);
            try testing.expectEqual(ca.state, cb.state);
        }
    }

    try testing.expectEqual(a.blocks.len, b.blocks.len);
    for (a.blocks, b.blocks) |ba, bb| {
        try testing.expectEqualStrings(ba.section, bb.section);
        try testing.expectEqualStrings(ba.block, bb.block);
        try testing.expectEqual(ba.verdicts.len, bb.verdicts.len);
        for (ba.verdicts, bb.verdicts) |va, vb| {
            try testing.expectEqual(va.outcome, vb.outcome);
            try testing.expectEqualStrings(va.commit, vb.commit);
        }
        try testing.expectEqual(ba.currentOutcome(), bb.currentOutcome());
    }

    try testing.expectEqual(a.next_history.len, b.next_history.len);
    for (a.next_history, b.next_history) |na, nb| {
        try testing.expectEqualStrings(na.common.body, nb.common.body);
    }
    const cur_a = a.currentNext();
    const cur_b = b.currentNext();
    try testing.expectEqual(cur_a == null, cur_b == null);
    if (cur_a) |ca| try testing.expectEqualStrings(ca.common.body, cur_b.?.common.body);
}

test "deriving state twice from the same parsed bytes gives identical results" {
    const allocator = testing.allocator;
    const bytes =
        \\{"kind":"item","seq":1,"ts":"t1","role":"worker","item":1,"type":"task","blocking":false,"body":"first item"}
        \\{"kind":"item","seq":2,"ts":"t2","role":"worker","item":2,"type":"task","blocking":true,"body":"second item"}
        \\{"kind":"item","seq":3,"ts":"t3","role":"worker","item":3,"type":"finding","blocking":false,"body":"third item"}
        \\{"kind":"close","seq":4,"ts":"t4","role":"architect","item":1,"state":"resolved","body":"done"}
        \\{"kind":"close","seq":5,"ts":"t5","role":"architect","item":2,"state":"deferred","body":"later"}
        \\{"kind":"verdict","seq":6,"ts":"t6","role":"reviewer","section":"5","block":"5.1-5.3","outcome":"request-changes","commit":"abc123","body":"needs fixes"}
        \\{"kind":"verdict","seq":7,"ts":"t7","role":"reviewer","section":"5","block":"5.1-5.3","outcome":"approve","commit":"def456","body":"looks good now"}
        \\{"kind":"verdict","seq":8,"ts":"t8","role":"reviewer","section":"5","block":"5.4-5.6","outcome":"approve","commit":"ghi789","body":"clean"}
        \\{"kind":"next","seq":9,"ts":"t9","role":"architect","body":"first plan"}
        \\{"kind":"next","seq":10,"ts":"t10","role":"architect","refs":[{"ns":"D","id":"7"}],"body":"second plan, see D7"}
        \\
    ;

    var log1 = try record.parseLog(allocator, bytes, null);
    defer log1.deinit();
    var log2 = try record.parseLog(allocator, bytes, null);
    defer log2.deinit();

    var s1 = try derive(allocator, log1.records, null);
    defer s1.deinit();
    var s2 = try derive(allocator, log2.records, null);
    defer s2.deinit();

    try expectStatesEqual(s1, s2);
}

test "closing an item changes only what is derived for that item" {
    const allocator = testing.allocator;
    const base_bytes =
        \\{"kind":"item","seq":1,"ts":"t1","role":"worker","item":1,"type":"task","blocking":false,"body":"first item"}
        \\{"kind":"item","seq":2,"ts":"t2","role":"worker","item":2,"type":"task","blocking":true,"body":"second item"}
        \\{"kind":"item","seq":3,"ts":"t3","role":"worker","item":3,"type":"finding","blocking":false,"body":"third item"}
        \\{"kind":"close","seq":4,"ts":"t4","role":"architect","item":1,"state":"resolved","body":"done"}
        \\{"kind":"verdict","seq":5,"ts":"t5","role":"reviewer","section":"5","block":"5.1-5.3","outcome":"approve","commit":"abc123","body":"clean"}
        \\{"kind":"next","seq":6,"ts":"t6","role":"architect","body":"first plan"}
        \\
    ;
    const closed_bytes = base_bytes ++
        \\{"kind":"close","seq":7,"ts":"t7","role":"architect","item":3,"state":"superseded","body":"no longer needed"}
        \\
    ;

    var log_before = try record.parseLog(allocator, base_bytes, null);
    defer log_before.deinit();
    var before = try derive(allocator, log_before.records, null);
    defer before.deinit();

    var log_after = try record.parseLog(allocator, closed_bytes, null);
    defer log_after.deinit();
    var after = try derive(allocator, log_after.records, null);
    defer after.deinit();

    try testing.expectEqual(@as(usize, 3), before.items.len);
    try testing.expectEqual(@as(usize, 3), after.items.len);

    // Item 1 and item 2 (index 0, 1) are untouched by closing item 3.
    for ([_]usize{ 0, 1 }) |i| {
        try testing.expectEqual(before.items[i].number, after.items[i].number);
        try testing.expectEqual(before.items[i].state, after.items[i].state);
        try testing.expectEqual(before.items[i].closes.len, after.items[i].closes.len);
    }

    // Item 3 (index 2) is the one that changed: open -> superseded.
    try testing.expectEqual(ItemState.open, before.items[2].state);
    try testing.expectEqual(@as(usize, 0), before.items[2].closes.len);
    try testing.expectEqual(ItemState.superseded, after.items[2].state);
    try testing.expectEqual(@as(usize, 1), after.items[2].closes.len);
    try testing.expectEqual(record.CloseState.superseded, after.items[2].closes[0].state);

    // Nothing else moved: item numbering, the NEXT history, and the
    // verdict grid are all identical before and after.
    try testing.expectEqual(@as(i64, 1), after.items[0].number);
    try testing.expectEqual(@as(i64, 2), after.items[1].number);
    try testing.expectEqual(@as(i64, 3), after.items[2].number);

    try testing.expectEqual(before.next_history.len, after.next_history.len);
    try testing.expectEqualStrings(before.currentNext().?.common.body, after.currentNext().?.common.body);

    try testing.expectEqual(before.blocks.len, after.blocks.len);
    try testing.expectEqualStrings(before.blocks[0].section, after.blocks[0].section);
    try testing.expectEqualStrings(before.blocks[0].block, after.blocks[0].block);
    try testing.expectEqual(before.blocks[0].verdicts.len, after.blocks[0].verdicts.len);
    try testing.expectEqual(before.blocks[0].currentOutcome(), after.blocks[0].currentOutcome());
}
