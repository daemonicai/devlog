// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Derived, in-memory state folded from a parsed log's records
//! (design.md D9, D14; ADR-0002 — no database, no persisted index:
//! everything here is rebuilt from `record.ParsedLog` on every invocation
//! and discarded on exit).
//!
//! `derive` is a pure fold over `[]const record.Record` in file order. It
//! performs **no filesystem access whatsoever** — no open, no stat, no
//! temp file. `State`'s `items[].opened`/`items[].closes` and
//! `next_history` borrow directly from the records passed in: the caller
//! must keep the `record.ParsedLog` it derived from alive for the whole
//! lifetime of the returned `State`. `State.deinit` frees only what
//! `derive` itself allocated — never anything reachable through a
//! borrowed record.

const std = @import("std");
const Allocator = std.mem.Allocator;
const record = @import("record.zig");

/// An item's derived state (work-items: "SHALL be one of: open, resolved,
/// deferred, or superseded"). Distinct from `record.CloseState`, which
/// names only the three closed states a `close` record itself can carry —
/// `open` has no close record to carry it, since it is the absence of one.
pub const ItemState = enum { open, resolved, deferred, superseded };

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

/// Derived view of the whole log: every item with its state and full
/// close history, and every `next` record with the current one singled
/// out.
pub const State = struct {
    allocator: Allocator,
    /// One entry per raised item, in positional (`#n`) order.
    items: []const Item,
    /// Every `next` record, in log order (`next-state`: "every NEXT ever
    /// recorded is available in order"). Borrowed from the caller's
    /// `record.ParsedLog`.
    next_history: []const record.NextRecord,

    /// The most recently appended `next` record, or `null` if none has
    /// ever been recorded (`next-state`: "it receives the most recently
    /// appended one and no other").
    pub fn currentNext(self: State) ?record.NextRecord {
        if (self.next_history.len == 0) return null;
        return self.next_history[self.next_history.len - 1];
    }

    /// Frees only what `derive` allocated: the `items` array, each of its
    /// `closes` slices, and the `next_history` array. Does **not** free
    /// anything reachable through a borrowed `record.ItemRecord` /
    /// `record.CloseRecord` / `record.NextRecord` — that memory belongs to
    /// the `record.ParsedLog` the caller derived from, and must outlive
    /// this `State` by construction, not merely by convention.
    pub fn deinit(self: *State) void {
        for (self.items) |it| self.allocator.free(it.closes);
        self.allocator.free(self.items);
        self.allocator.free(self.next_history);
        self.* = undefined;
    }
};

pub const DeriveError = error{ ItemNumberMismatch, CloseTargetMissing } || Allocator.Error;

fn closeStateToItemState(state: record.CloseState) ItemState {
    return switch (state) {
        .resolved => .resolved,
        .deferred => .deferred,
        .superseded => .superseded,
    };
}

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
pub fn derive(
    allocator: Allocator,
    records: []const record.Record,
    diag: ?*record.Diagnostics,
) DeriveError!State {
    var item_records: std.ArrayList(record.ItemRecord) = .empty;
    defer item_records.deinit(allocator);

    // Unconditional `defer`, not `errdefer`: this is the only place
    // `item_closes` is freed, on every path. Each inner list becomes
    // `.empty` (not `undefined`) the moment its `toOwnedSlice` runs below
    // (Zig 0.16 `ArrayList(T).toOwnedSlice` resets to `.empty` on success,
    // unlike `deinit`, which sets `undefined`), so deiniting an
    // already-drained list here is a harmless no-op — there is no second
    // cleanup path to keep in sync with this one.
    var item_closes: std.ArrayList(std.ArrayList(record.CloseRecord)) = .empty;
    defer {
        for (item_closes.items) |*list| list.deinit(allocator);
        item_closes.deinit(allocator);
    }

    var next_history: std.ArrayList(record.NextRecord) = .empty;
    errdefer next_history.deinit(allocator);

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
        const state: ItemState = if (closes.len == 0)
            .open
        else
            closeStateToItemState(closes[closes.len - 1].state);
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
    const next_slice = try next_history.toOwnedSlice(allocator);

    return .{
        .allocator = allocator,
        .items = items_slice,
        .next_history = next_slice,
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
