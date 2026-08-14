// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! The record model and its JSON codec (design.md ## Record schema).
//!
//! Pure in-memory: this module never touches a filesystem. Serialisation
//! writes bytes to an `Io.Writer`; parsing reads bytes already in memory.
//! Locking, atomic append, and the file itself belong to the I/O layer
//! (block 2B).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// The only format version this build understands (durable-format:
/// "The record format is precisely specified and versioned"). A `header`
/// declaring any other value is refused rather than guessed at.
pub const supported_format: i64 = 1;

/// `[{"ns":"D","id":"2"}]` — any namespace, unvalidated (D10). Item
/// identifiers are the neutral `#n` sequence and never appear here as a
/// kind-prefixed form (D9); `ns`/`id` are external reference namespaces.
pub const Ref = struct {
    ns: []const u8,
    id: []const u8,

    fn dupe(self: Ref, allocator: Allocator) Allocator.Error!Ref {
        const ns = try allocator.dupe(u8, self.ns);
        errdefer allocator.free(ns);
        const id = try allocator.dupe(u8, self.id);
        return .{ .ns = ns, .id = id };
    }

    fn free(self: Ref, allocator: Allocator) void {
        allocator.free(self.ns);
        allocator.free(self.id);
    }
};

fn freeRefs(allocator: Allocator, refs: []const Ref) void {
    for (refs) |r| r.free(allocator);
    allocator.free(refs);
}

fn dupeStringSlice(allocator: Allocator, items: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try allocator.alloc([]const u8, items.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |s| allocator.free(s);
        allocator.free(out);
    }
    for (items, 0..) |s, i| {
        out[i] = try allocator.dupe(u8, s);
        filled = i + 1;
    }
    return out;
}

fn freeStringSlice(allocator: Allocator, items: []const []const u8) void {
    for (items) |s| allocator.free(s);
    allocator.free(items);
}

pub const ItemType = enum { question, finding, decision, note, task };
pub const CloseState = enum { resolved, deferred, superseded };
pub const VerdictOutcome = enum { approve, @"approve-with-nits", @"request-changes" };

/// One of the eight record kinds. Doubles as the union tag and as the
/// `"kind"` field's JSON value (the tag name is the wire string).
pub const Kind = enum { header, section, brief, post, item, close, verdict, next };

/// Fields common to every kind except `header` (append-only-log: "The
/// header carries no role"). Modelled as its own type, embedded by every
/// non-header record — `header` simply has no field of this type, so a
/// `header` record cannot carry a role by construction, not by a check a
/// caller has to remember.
pub const Attributed = struct {
    seq: u64,
    ts: []const u8,
    role: []const u8,
    section: ?[]const u8 = null,
    block: ?[]const u8 = null,
    to: ?[]const u8 = null,
    refs: []const Ref = &.{},
    body: []const u8 = "",

    fn dupe(self: Attributed, allocator: Allocator) Allocator.Error!Attributed {
        const ts = try allocator.dupe(u8, self.ts);
        errdefer allocator.free(ts);
        const role = try allocator.dupe(u8, self.role);
        errdefer allocator.free(role);
        const section = if (self.section) |s| try allocator.dupe(u8, s) else null;
        errdefer if (section) |s| allocator.free(s);
        const block = if (self.block) |s| try allocator.dupe(u8, s) else null;
        errdefer if (block) |s| allocator.free(s);
        const to = if (self.to) |s| try allocator.dupe(u8, s) else null;
        errdefer if (to) |s| allocator.free(s);

        const refs = try allocator.alloc(Ref, self.refs.len);
        var filled: usize = 0;
        errdefer {
            for (refs[0..filled]) |r| r.free(allocator);
            allocator.free(refs);
        }
        for (self.refs, 0..) |r, i| {
            refs[i] = try r.dupe(allocator);
            filled = i + 1;
        }

        const body = try allocator.dupe(u8, self.body);
        errdefer allocator.free(body);

        return .{
            .seq = self.seq,
            .ts = ts,
            .role = role,
            .section = section,
            .block = block,
            .to = to,
            .refs = refs,
            .body = body,
        };
    }

    fn free(self: Attributed, allocator: Allocator) void {
        allocator.free(self.ts);
        allocator.free(self.role);
        if (self.section) |s| allocator.free(s);
        if (self.block) |s| allocator.free(s);
        if (self.to) |s| allocator.free(s);
        freeRefs(allocator, self.refs);
        allocator.free(self.body);
    }
};

/// Provenance, the project's declared role set, and which of those roles
/// may close items (D13). Exempt from `Attributed` — see the type doc
/// above. First line of the log; appended again whenever a different tool
/// version writes it or the declaration changes.
pub const HeaderRecord = struct {
    seq: u64,
    ts: []const u8,
    format: i64,
    tool: []const u8,
    change: []const u8,
    roles: []const []const u8,
    closers: []const []const u8,

    fn dupe(self: HeaderRecord, allocator: Allocator) Allocator.Error!HeaderRecord {
        const ts = try allocator.dupe(u8, self.ts);
        errdefer allocator.free(ts);
        const tool = try allocator.dupe(u8, self.tool);
        errdefer allocator.free(tool);
        const change = try allocator.dupe(u8, self.change);
        errdefer allocator.free(change);
        const roles = try dupeStringSlice(allocator, self.roles);
        errdefer freeStringSlice(allocator, roles);
        const closers = try dupeStringSlice(allocator, self.closers);
        return .{
            .seq = self.seq,
            .ts = ts,
            .format = self.format,
            .tool = tool,
            .change = change,
            .roles = roles,
            .closers = closers,
        };
    }

    fn free(self: HeaderRecord, allocator: Allocator) void {
        allocator.free(self.ts);
        allocator.free(self.tool);
        allocator.free(self.change);
        freeStringSlice(allocator, self.roles);
        freeStringSlice(allocator, self.closers);
    }
};

pub const SectionRecord = struct { common: Attributed, title: []const u8, base: []const u8 };
pub const BriefRecord = struct { common: Attributed };
pub const PostRecord = struct { common: Attributed };
pub const ItemRecord = struct { common: Attributed, item: i64, type: ItemType, blocking: bool };
pub const CloseRecord = struct { common: Attributed, item: i64, state: CloseState };
pub const VerdictRecord = struct { common: Attributed, outcome: VerdictOutcome, commit: []const u8 };
pub const NextRecord = struct { common: Attributed };

/// One record, of one of the eight kinds. Owns every slice it carries;
/// free with `deinit`.
pub const Record = union(Kind) {
    header: HeaderRecord,
    section: SectionRecord,
    brief: BriefRecord,
    post: PostRecord,
    item: ItemRecord,
    close: CloseRecord,
    verdict: VerdictRecord,
    next: NextRecord,

    pub fn seq(self: Record) u64 {
        return switch (self) {
            .header => |r| r.seq,
            inline .section, .brief, .post, .item, .close, .verdict, .next => |r| r.common.seq,
        };
    }

    /// `null` only for `header` (D13).
    pub fn role(self: Record) ?[]const u8 {
        return switch (self) {
            .header => null,
            inline .section, .brief, .post, .item, .close, .verdict, .next => |r| r.common.role,
        };
    }

    pub fn deinit(self: Record, allocator: Allocator) void {
        switch (self) {
            .header => |r| r.free(allocator),
            .section => |r| {
                r.common.free(allocator);
                allocator.free(r.title);
                allocator.free(r.base);
            },
            .brief => |r| r.common.free(allocator),
            .post => |r| r.common.free(allocator),
            .item => |r| r.common.free(allocator),
            .close => |r| r.common.free(allocator),
            .verdict => |r| {
                r.common.free(allocator);
                allocator.free(r.commit);
            },
            .next => |r| r.common.free(allocator),
        }
    }
};

// --- Serialisation ---------------------------------------------------------

/// Writes one record as a single JSON object (no trailing newline — the
/// caller decides how records are joined; block 2B's append writes one
/// per line). Field order matches `design.md`'s example, for a `git diff`
/// that reads in a stable order; optional common fields absent on the
/// record are omitted rather than written as `null`.
pub fn write(w: *Io.Writer, record: Record) Io.Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("kind");
    try s.write(std.meta.activeTag(record));
    try s.objectField("seq");
    try s.write(record.seq());

    switch (record) {
        .header => |r| {
            try s.objectField("ts");
            try s.write(r.ts);
            try s.objectField("format");
            try s.write(r.format);
            try s.objectField("tool");
            try s.write(r.tool);
            try s.objectField("change");
            try s.write(r.change);
            try s.objectField("roles");
            try s.write(r.roles);
            try s.objectField("closers");
            try s.write(r.closers);
        },
        .section => |r| {
            try writeAttributedHead(&s, r.common);
            try s.objectField("title");
            try s.write(r.title);
            try s.objectField("base");
            try s.write(r.base);
            try writeAttributedTail(&s, r.common);
        },
        .brief, .post, .next => {
            const common = switch (record) {
                inline .brief, .post, .next => |r| r.common,
                else => unreachable,
            };
            try writeAttributedHead(&s, common);
            try writeAttributedTail(&s, common);
        },
        .item => |r| {
            try writeAttributedHead(&s, r.common);
            try s.objectField("item");
            try s.write(r.item);
            try s.objectField("type");
            try s.write(r.type);
            // `to` sits between `type` and `blocking` here (design.md:240),
            // unlike every other kind where it trails after the
            // kind-specific fields — writeAttributedTail's `to` placement
            // doesn't fit `item`, so it's emitted inline and the shared
            // tail below only contributes refs/body.
            if (r.common.to) |v| {
                try s.objectField("to");
                try s.write(v);
            }
            try s.objectField("blocking");
            try s.write(r.blocking);
            try writeRefsAndBody(&s, r.common);
        },
        .close => |r| {
            try writeAttributedHead(&s, r.common);
            try s.objectField("item");
            try s.write(r.item);
            try s.objectField("state");
            try s.write(r.state);
            try writeAttributedTail(&s, r.common);
        },
        .verdict => |r| {
            try writeAttributedHead(&s, r.common);
            try s.objectField("outcome");
            try s.write(r.outcome);
            try s.objectField("commit");
            try s.write(r.commit);
            try writeAttributedTail(&s, r.common);
        },
    }

    try s.endObject();
}

fn writeAttributedHead(s: *std.json.Stringify, common: Attributed) Io.Writer.Error!void {
    try s.objectField("ts");
    try s.write(common.ts);
    try s.objectField("role");
    try s.write(common.role);
    if (common.section) |v| {
        try s.objectField("section");
        try s.write(v);
    }
    if (common.block) |v| {
        try s.objectField("block");
        try s.write(v);
    }
}

fn writeAttributedTail(s: *std.json.Stringify, common: Attributed) Io.Writer.Error!void {
    if (common.to) |v| {
        try s.objectField("to");
        try s.write(v);
    }
    try writeRefsAndBody(s, common);
}

/// `refs` then `body` — the tail shared by every kind, including `item`
/// (design.md:240), where `to` is emitted earlier and so is not part of
/// this tail.
fn writeRefsAndBody(s: *std.json.Stringify, common: Attributed) Io.Writer.Error!void {
    if (common.refs.len != 0) {
        try s.objectField("refs");
        try s.write(common.refs);
    }
    try s.objectField("body");
    try s.write(common.body);
}

// --- Parsing -----------------------------------------------------------

pub const ParseError = error{
    InvalidJson,
    NotAnObject,
    MissingField,
    InvalidFieldType,
    UnknownKind,
    UnsupportedFormatVersion,
} || Allocator.Error;

/// Set by `parseLine`/`parseLog` on failure so the caller can build a
/// clear message (durable-format: "reports this clearly rather than
/// misreading the contents"). No allocation — filled with `bufPrint` into
/// a buffer owned by the caller-supplied `Diagnostics`.
pub const Diagnostics = struct {
    line_number: usize = 0,
    buf: [200]u8 = undefined,
    message: []const u8 = "",

    fn set(self: *Diagnostics, comptime fmt: []const u8, args: anytype) void {
        self.message = std.fmt.bufPrint(&self.buf, fmt, args) catch self.buf[0..];
    }
};

fn getMember(obj: std.json.ObjectMap, key: []const u8) ?std.json.Value {
    return obj.get(key);
}

fn requireString(obj: std.json.ObjectMap, key: []const u8, diag: ?*Diagnostics) ParseError![]const u8 {
    const v = getMember(obj, key) orelse {
        if (diag) |d| d.set("missing required field '{s}'", .{key});
        return error.MissingField;
    };
    return switch (v) {
        .string => |s| s,
        else => {
            if (diag) |d| d.set("field '{s}' must be a string", .{key});
            return error.InvalidFieldType;
        },
    };
}

fn optionalString(obj: std.json.ObjectMap, key: []const u8, diag: ?*Diagnostics) ParseError!?[]const u8 {
    const v = getMember(obj, key) orelse return null;
    return switch (v) {
        .string => |s| s,
        .null => null,
        else => {
            if (diag) |d| d.set("field '{s}' must be a string", .{key});
            return error.InvalidFieldType;
        },
    };
}

fn requireInt(obj: std.json.ObjectMap, key: []const u8, diag: ?*Diagnostics) ParseError!i64 {
    const v = getMember(obj, key) orelse {
        if (diag) |d| d.set("missing required field '{s}'", .{key});
        return error.MissingField;
    };
    return switch (v) {
        .integer => |n| n,
        else => {
            if (diag) |d| d.set("field '{s}' must be an integer", .{key});
            return error.InvalidFieldType;
        },
    };
}

fn requireU64(obj: std.json.ObjectMap, key: []const u8, diag: ?*Diagnostics) ParseError!u64 {
    const n = try requireInt(obj, key, diag);
    if (n < 0) {
        if (diag) |d| d.set("field '{s}' must not be negative", .{key});
        return error.InvalidFieldType;
    }
    return @intCast(n);
}

fn requireBool(obj: std.json.ObjectMap, key: []const u8, diag: ?*Diagnostics) ParseError!bool {
    const v = getMember(obj, key) orelse {
        if (diag) |d| d.set("missing required field '{s}'", .{key});
        return error.MissingField;
    };
    return switch (v) {
        .bool => |b| b,
        else => {
            if (diag) |d| d.set("field '{s}' must be a boolean", .{key});
            return error.InvalidFieldType;
        },
    };
}

fn requireStringArray(
    allocator: Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
    diag: ?*Diagnostics,
) ParseError![]const []const u8 {
    const v = getMember(obj, key) orelse {
        if (diag) |d| d.set("missing required field '{s}'", .{key});
        return error.MissingField;
    };
    const arr = switch (v) {
        .array => |a| a,
        else => {
            if (diag) |d| d.set("field '{s}' must be an array", .{key});
            return error.InvalidFieldType;
        },
    };
    // Borrows each string from the parse arena rather than duping it here —
    // the caller runs exactly one deep-copy pass (`.dupe`) over the whole
    // record before the arena goes away, so an element-level dupe here
    // would leak its own copy once that pass makes a second one.
    const out = try allocator.alloc([]const u8, arr.items.len);
    errdefer allocator.free(out);
    for (arr.items, 0..) |item, i| {
        out[i] = switch (item) {
            .string => |s| s,
            else => {
                if (diag) |d| d.set("field '{s}' must be an array of strings", .{key});
                return error.InvalidFieldType;
            },
        };
    }
    return out;
}

/// Borrows `ns`/`id` from the parse arena; only the returned container
/// slice is `allocator`-owned (free it once the caller's single deep-copy
/// pass has consumed it — see `requireStringArray`).
fn parseRefs(allocator: Allocator, obj: std.json.ObjectMap, diag: ?*Diagnostics) ParseError![]const Ref {
    const v = getMember(obj, "refs") orelse return &.{};
    const arr = switch (v) {
        .array => |a| a,
        .null => return &.{},
        else => {
            if (diag) |d| d.set("field 'refs' must be an array", .{});
            return error.InvalidFieldType;
        },
    };
    const out = try allocator.alloc(Ref, arr.items.len);
    errdefer allocator.free(out);
    for (arr.items, 0..) |item, i| {
        const ref_obj = switch (item) {
            .object => |o| o,
            else => {
                if (diag) |d| d.set("each 'refs' entry must be an object", .{});
                return error.InvalidFieldType;
            },
        };
        const ns = try requireString(ref_obj, "ns", diag);
        const id = try requireString(ref_obj, "id", diag);
        out[i] = .{ .ns = ns, .id = id };
    }
    return out;
}

fn enumFromString(comptime E: type, s: []const u8) ?E {
    inline for (@typeInfo(E).@"enum".fields) |f| {
        if (std.mem.eql(u8, f.name, s)) return @field(E, f.name);
    }
    return null;
}

/// Parses one JSON line into an owned `Record`. Unknown *fields* are
/// ignored silently (durable-format forward compatibility); a `header`
/// whose `format` this build does not understand is refused via
/// `error.UnsupportedFormatVersion` rather than guessed at.
pub fn parseLine(allocator: Allocator, line: []const u8, diag: ?*Diagnostics) ParseError!Record {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
        if (diag) |d| d.set("invalid JSON", .{});
        return error.InvalidJson;
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            if (diag) |d| d.set("a record must be a JSON object", .{});
            return error.NotAnObject;
        },
    };

    const kind_str = try requireString(obj, "kind", diag);
    const kind = enumFromString(Kind, kind_str) orelse {
        if (diag) |d| d.set("unknown record kind '{s}'", .{kind_str});
        return error.UnknownKind;
    };

    const rec_seq = try requireU64(obj, "seq", diag);
    const ts = try requireString(obj, "ts", diag);

    if (kind == .header) {
        const format = try requireInt(obj, "format", diag);
        if (format != supported_format) {
            if (diag) |d| d.set(
                "log format {d} is not a version this build understands (this build understands format version {d})",
                .{ format, supported_format },
            );
            return error.UnsupportedFormatVersion;
        }
        const tool = try requireString(obj, "tool", diag);
        const change = try requireString(obj, "change", diag);
        // `roles`/`closers` are containers of borrowed strings (see
        // `requireStringArray`); freeing just the container is correct
        // both on success (after `.dupe` below has deep-copied the
        // contents) and on a later error (nothing else was allocated).
        const roles = try requireStringArray(allocator, obj, "roles", diag);
        defer allocator.free(roles);
        const closers = try requireStringArray(allocator, obj, "closers", diag);
        defer allocator.free(closers);

        return .{ .header = try (HeaderRecord{
            .seq = rec_seq,
            .ts = ts,
            .format = format,
            .tool = tool,
            .change = change,
            .roles = roles,
            .closers = closers,
        }).dupe(allocator) };
    }

    const role_str = try requireString(obj, "role", diag);
    const section = try optionalString(obj, "section", diag);
    const block = try optionalString(obj, "block", diag);
    const to = try optionalString(obj, "to", diag);
    // `refs` is a container of borrowed `Ref`s (see `parseRefs`); freed
    // just below once every branch has either deep-copied it via
    // `common.dupe` or bailed out with an error, whichever it is.
    const refs = try parseRefs(allocator, obj, diag);
    defer allocator.free(refs);
    const body = try requireString(obj, "body", diag);

    const common = Attributed{
        .seq = rec_seq,
        .ts = ts,
        .role = role_str,
        .section = section,
        .block = block,
        .to = to,
        .refs = refs,
        .body = body,
    };

    switch (kind) {
        .header => unreachable,
        .section => {
            const title = try requireString(obj, "title", diag);
            const base = try requireString(obj, "base", diag);
            const dup_common = try common.dupe(allocator);
            errdefer dup_common.free(allocator);
            const dup_title = try allocator.dupe(u8, title);
            errdefer allocator.free(dup_title);
            const dup_base = try allocator.dupe(u8, base);
            return .{ .section = .{ .common = dup_common, .title = dup_title, .base = dup_base } };
        },
        .brief => return .{ .brief = .{ .common = try common.dupe(allocator) } },
        .post => return .{ .post = .{ .common = try common.dupe(allocator) } },
        .next => return .{ .next = .{ .common = try common.dupe(allocator) } },
        .item => {
            const item_num = try requireInt(obj, "item", diag);
            const type_str = try requireString(obj, "type", diag);
            const item_type = enumFromString(ItemType, type_str) orelse {
                if (diag) |d| d.set("field 'type' has unrecognised value '{s}'", .{type_str});
                return error.InvalidFieldType;
            };
            const blocking = try requireBool(obj, "blocking", diag);
            return .{ .item = .{
                .common = try common.dupe(allocator),
                .item = item_num,
                .type = item_type,
                .blocking = blocking,
            } };
        },
        .close => {
            const item_num = try requireInt(obj, "item", diag);
            const state_str = try requireString(obj, "state", diag);
            const state = enumFromString(CloseState, state_str) orelse {
                if (diag) |d| d.set("field 'state' has unrecognised value '{s}'", .{state_str});
                return error.InvalidFieldType;
            };
            return .{ .close = .{
                .common = try common.dupe(allocator),
                .item = item_num,
                .state = state,
            } };
        },
        .verdict => {
            const outcome_str = try requireString(obj, "outcome", diag);
            const outcome = enumFromString(VerdictOutcome, outcome_str) orelse {
                if (diag) |d| d.set("field 'outcome' has unrecognised value '{s}'", .{outcome_str});
                return error.InvalidFieldType;
            };
            const commit = try requireString(obj, "commit", diag);
            const dup_common = try common.dupe(allocator);
            errdefer dup_common.free(allocator);
            const dup_commit = try allocator.dupe(u8, commit);
            return .{ .verdict = .{ .common = dup_common, .outcome = outcome, .commit = dup_commit } };
        },
    }
}

// --- seq / total order (append-only-log: "Records have a definite order") --

/// The `seq` the next record should carry: one past the highest `seq`
/// currently present, or `1` for an empty log. Pure function of a parsed
/// set — assignment under the lock (2.5) calls this after re-reading the
/// file.
pub fn nextSeq(records: []const Record) u64 {
    var max: u64 = 0;
    for (records) |r| max = @max(max, r.seq());
    return max + 1;
}

pub const SeqError = error{
    NonContiguousSeq,
    SeqOutOfOrder,
};

/// `records` must already be in file order. A `seq` sequence that is not
/// strictly increasing, or not contiguous from `1`, is a fault this
/// function reports — the spec does not say how to repair a corrupted
/// log, and this module does not invent a policy for that (parked for the
/// Product Owner, per the block brief).
pub fn validateSeqOrder(records: []const Record, diag: ?*Diagnostics) SeqError!void {
    var expected: u64 = 1;
    for (records) |r| {
        const s = r.seq();
        if (s < expected) {
            if (diag) |d| d.set("seq {d} is out of order (expected at least {d})", .{ s, expected });
            return error.SeqOutOfOrder;
        }
        if (s != expected) {
            if (diag) |d| d.set("seq is not contiguous: expected {d}, found {d}", .{ expected, s });
            return error.NonContiguousSeq;
        }
        expected += 1;
    }
}

// --- Log parsing (bytes -> records; no filesystem) --------------------

pub const ParsedLog = struct {
    records: []Record,
    allocator: Allocator,

    pub fn deinit(self: *ParsedLog) void {
        for (self.records) |r| r.deinit(self.allocator);
        self.allocator.free(self.records);
        self.* = undefined;
    }
};

/// Parses every line of a log's bytes into records, in file order.
/// Ignores unknown fields (durable-format), refuses an unrecognised
/// `format` (via `parseLine`), and reports a non-contiguous or
/// out-of-order `seq` as a fault rather than repairing it.
pub fn parseLog(allocator: Allocator, bytes: []const u8, diag: ?*Diagnostics) (ParseError || SeqError)!ParsedLog {
    var list: std.ArrayList(Record) = .empty;
    errdefer {
        for (list.items) |r| r.deinit(allocator);
        list.deinit(allocator);
    }

    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        line_no += 1;
        if (line.len == 0) continue;
        const record = parseLine(allocator, line, diag) catch |err| {
            if (diag) |d| d.line_number = line_no;
            return err;
        };
        try list.append(allocator, record);
    }

    const records = try list.toOwnedSlice(allocator);
    errdefer {
        for (records) |r| r.deinit(allocator);
        allocator.free(records);
    }

    validateSeqOrder(records, diag) catch |err| return err;

    return .{ .records = records, .allocator = allocator };
}

// --- Tests ---------------------------------------------------------------

const testing = std.testing;

fn encodeAlloc(allocator: Allocator, record: Record) ![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try write(&out.writer, record);
    return allocator.dupe(u8, out.written());
}

test "header round-trips and carries no role field" {
    const allocator = testing.allocator;
    const header = Record{ .header = .{
        .seq = 1,
        .ts = "2026-08-12T09:00:00Z",
        .format = 1,
        .tool = "devlog 0.1.0",
        .change = "add-devlog-core",
        .roles = &.{ "architect", "worker" },
        .closers = &.{"architect"},
    } };

    const line = try encodeAlloc(allocator, header);
    defer allocator.free(line);

    try testing.expect(std.mem.indexOf(u8, line, "\"role\"") == null);
    try testing.expect(std.mem.indexOf(u8, line, "\"kind\":\"header\"") != null);

    var diag: Diagnostics = .{};
    var parsed = try parseLine(allocator, line, &diag);
    defer parsed.deinit(allocator);

    try testing.expectEqual(Kind.header, std.meta.activeTag(parsed));
    try testing.expectEqual(@as(?[]const u8, null), parsed.role());
    try testing.expectEqualStrings("add-devlog-core", parsed.header.change);
    try testing.expectEqual(@as(usize, 2), parsed.header.roles.len);
    try testing.expectEqualStrings("architect", parsed.header.closers[0]);
}

test "section round-trips with title, base, and a common field" {
    const allocator = testing.allocator;
    const rec = Record{ .section = .{
        .common = .{
            .seq = 2,
            .ts = "2026-08-12T09:01:00Z",
            .role = "architect",
            .section = "3",
        },
        .title = "Submission form",
        .base = "a1b2c3d",
    } };

    const line = try encodeAlloc(allocator, rec);
    defer allocator.free(line);

    var diag: Diagnostics = .{};
    var parsed = try parseLine(allocator, line, &diag);
    defer parsed.deinit(allocator);

    try testing.expectEqualStrings("Submission form", parsed.section.title);
    try testing.expectEqualStrings("a1b2c3d", parsed.section.base);
    try testing.expectEqualStrings("architect", parsed.role().?);
    try testing.expectEqualStrings("3", parsed.section.common.section.?);
    try testing.expectEqual(@as(?[]const u8, null), parsed.section.common.block);
}

test "item round-trips type, blocking, refs, and an addressee" {
    const allocator = testing.allocator;
    const rec = Record{ .item = .{
        .common = .{
            .seq = 5,
            .ts = "2026-08-12T10:15:00Z",
            .role = "worker-frontend",
            .section = "3",
            .block = "3.1-3.3",
            .to = "architect",
            .refs = &.{.{ .ns = "S", .id = "4" }},
            .body = "Spec says 300ms, design says 500ms. Which wins?",
        },
        .item = 1,
        .type = .question,
        .blocking = true,
    } };

    const line = try encodeAlloc(allocator, rec);
    defer allocator.free(line);

    var diag: Diagnostics = .{};
    var parsed = try parseLine(allocator, line, &diag);
    defer parsed.deinit(allocator);

    try testing.expectEqual(@as(i64, 1), parsed.item.item);
    try testing.expectEqual(ItemType.question, parsed.item.type);
    try testing.expect(parsed.item.blocking);
    try testing.expectEqualStrings("architect", parsed.item.common.to.?);
    try testing.expectEqual(@as(usize, 1), parsed.item.common.refs.len);
    try testing.expectEqualStrings("S", parsed.item.common.refs[0].ns);
    try testing.expectEqualStrings("4", parsed.item.common.refs[0].id);
}

test "close, verdict and next round-trip their kind-specific fields" {
    const allocator = testing.allocator;

    const close = Record{ .close = .{
        .common = .{ .seq = 6, .ts = "t", .role = "architect", .body = "500ms — design wins." },
        .item = 1,
        .state = .resolved,
    } };
    const close_line = try encodeAlloc(allocator, close);
    defer allocator.free(close_line);
    var diag: Diagnostics = .{};
    var parsed_close = try parseLine(allocator, close_line, &diag);
    defer parsed_close.deinit(allocator);
    try testing.expectEqual(CloseState.resolved, parsed_close.close.state);

    const verdict = Record{ .verdict = .{
        .common = .{ .seq = 11, .ts = "t", .role = "reviewer", .body = "Approve." },
        .outcome = .@"approve-with-nits",
        .commit = "c9d0e1f",
    } };
    const verdict_line = try encodeAlloc(allocator, verdict);
    defer allocator.free(verdict_line);
    var parsed_verdict = try parseLine(allocator, verdict_line, &diag);
    defer parsed_verdict.deinit(allocator);
    try testing.expectEqual(VerdictOutcome.@"approve-with-nits", parsed_verdict.verdict.outcome);
    try testing.expectEqualStrings("c9d0e1f", parsed_verdict.verdict.commit);

    const next = Record{ .next = .{
        .common = .{ .seq = 14, .ts = "t", .role = "architect", .body = "Resume at 4.1." },
    } };
    const next_line = try encodeAlloc(allocator, next);
    defer allocator.free(next_line);
    var parsed_next = try parseLine(allocator, next_line, &diag);
    defer parsed_next.deinit(allocator);
    try testing.expectEqualStrings("Resume at 4.1.", parsed_next.next.common.body);
}

test "body survives a round trip byte-for-byte through newlines, quotes, and control characters" {
    const allocator = testing.allocator;
    const body = "line one\nline two with \"quotes\"\tand a tab\r\nand a back\\slash";
    const rec = Record{ .post = .{
        .common = .{ .seq = 3, .ts = "t", .role = "worker", .body = body },
    } };

    const line = try encodeAlloc(allocator, rec);
    defer allocator.free(line);

    // The serialised form is one JSON line: no literal newline byte in it.
    try testing.expect(std.mem.indexOfScalar(u8, line, '\n') == null);

    var diag: Diagnostics = .{};
    var parsed = try parseLine(allocator, line, &diag);
    defer parsed.deinit(allocator);

    try testing.expectEqualStrings(body, parsed.post.common.body);
}

test "an unknown field is ignored, not rejected (durable-format forward compat)" {
    const allocator = testing.allocator;
    const line =
        \\{"kind":"post","seq":1,"ts":"t","role":"worker","body":"hi","from_a_future_version":{"nested":true}}
    ;
    var diag: Diagnostics = .{};
    var parsed = try parseLine(allocator, line, &diag);
    defer parsed.deinit(allocator);
    try testing.expectEqualStrings("hi", parsed.post.common.body);
}

test "an unrecognised format version is refused with a clear message, not guessed at" {
    const allocator = testing.allocator;
    const line =
        \\{"kind":"header","seq":1,"ts":"t","format":99,"tool":"devlog 9.9.9","change":"x","roles":["architect"],"closers":["architect"]}
    ;
    var diag: Diagnostics = .{};
    const result = parseLine(allocator, line, &diag);
    try testing.expectError(error.UnsupportedFormatVersion, result);
    try testing.expect(std.mem.indexOf(u8, diag.message, "99") != null);
    try testing.expect(std.mem.indexOf(u8, diag.message, "format") != null);
}

test "a non-header record without a role is rejected (role is required, not header-only)" {
    const allocator = testing.allocator;
    const line =
        \\{"kind":"post","seq":1,"ts":"t","body":"hi"}
    ;
    var diag: Diagnostics = .{};
    const result = parseLine(allocator, line, &diag);
    try testing.expectError(error.MissingField, result);
    try testing.expect(std.mem.indexOf(u8, diag.message, "role") != null);
}

test "an unknown kind is rejected" {
    const allocator = testing.allocator;
    const line =
        \\{"kind":"mystery","seq":1,"ts":"t","role":"worker","body":"hi"}
    ;
    var diag: Diagnostics = .{};
    const result = parseLine(allocator, line, &diag);
    try testing.expectError(error.UnknownKind, result);
}

test "malformed JSON is rejected, not partially interpreted" {
    const allocator = testing.allocator;
    var diag: Diagnostics = .{};
    const result = parseLine(allocator, "{not json", &diag);
    try testing.expectError(error.InvalidJson, result);
}

test "nextSeq derives one past the highest seq, and 1 for an empty log" {
    var empty: [0]Record = .{};
    try testing.expectEqual(@as(u64, 1), nextSeq(&empty));

    const a = Record{ .next = .{ .common = .{ .seq = 1, .ts = "t", .role = "architect" } } };
    const b = Record{ .next = .{ .common = .{ .seq = 4, .ts = "t", .role = "architect" } } };
    const records = [_]Record{ a, b };
    try testing.expectEqual(@as(u64, 5), nextSeq(&records));
}

test "seq validation accepts a strictly increasing, contiguous sequence" {
    const a = Record{ .next = .{ .common = .{ .seq = 1, .ts = "t", .role = "architect" } } };
    const b = Record{ .next = .{ .common = .{ .seq = 2, .ts = "t", .role = "architect" } } };
    const c = Record{ .next = .{ .common = .{ .seq = 3, .ts = "t", .role = "architect" } } };
    const records = [_]Record{ a, b, c };
    try validateSeqOrder(&records, null);
}

test "seq validation reports a gap as a fault, not a repair" {
    const a = Record{ .next = .{ .common = .{ .seq = 1, .ts = "t", .role = "architect" } } };
    const b = Record{ .next = .{ .common = .{ .seq = 3, .ts = "t", .role = "architect" } } };
    const records = [_]Record{ a, b };
    var diag: Diagnostics = .{};
    try testing.expectError(error.NonContiguousSeq, validateSeqOrder(&records, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message, "contiguous") != null);
}

test "seq validation reports a repeat or decrease as out of order, not a gap" {
    const a = Record{ .next = .{ .common = .{ .seq = 1, .ts = "t", .role = "architect" } } };
    const b = Record{ .next = .{ .common = .{ .seq = 2, .ts = "t", .role = "architect" } } };
    const c = Record{ .next = .{ .common = .{ .seq = 1, .ts = "t", .role = "architect" } } };
    const records = [_]Record{ a, b, c };
    var diag: Diagnostics = .{};
    try testing.expectError(error.SeqOutOfOrder, validateSeqOrder(&records, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message, "out of order") != null);
}

test "parseLog parses a multi-line, multi-kind log in file order" {
    const allocator = testing.allocator;
    const bytes =
        \\{"kind":"header","seq":1,"ts":"t","format":1,"tool":"devlog 0.1.0","change":"add-devlog-core","roles":["architect","worker"],"closers":["architect"]}
        \\{"kind":"section","seq":2,"ts":"t","role":"architect","section":"3","title":"Submission form","base":"a1b2c3d","body":"desc"}
        \\{"kind":"post","seq":3,"ts":"t","role":"worker","body":"progress"}
        \\
    ;
    var diag: Diagnostics = .{};
    var log = try parseLog(allocator, bytes, &diag);
    defer log.deinit();

    try testing.expectEqual(@as(usize, 3), log.records.len);
    try testing.expectEqual(Kind.header, std.meta.activeTag(log.records[0]));
    try testing.expectEqual(Kind.section, std.meta.activeTag(log.records[1]));
    try testing.expectEqual(Kind.post, std.meta.activeTag(log.records[2]));
    try testing.expectEqual(@as(u64, 4), nextSeq(log.records));
}

test "parseLog reports which line failed" {
    const allocator = testing.allocator;
    const bytes =
        \\{"kind":"header","seq":1,"ts":"t","format":1,"tool":"devlog 0.1.0","change":"x","roles":["architect"],"closers":["architect"]}
        \\{"kind":"post","seq":2,"ts":"t","body":"missing role"}
    ;
    var diag: Diagnostics = .{};
    const result = parseLog(allocator, bytes, &diag);
    try testing.expectError(error.MissingField, result);
    try testing.expectEqual(@as(usize, 2), diag.line_number);
}

test "parseLog surfaces a non-contiguous seq across the whole file as a fault" {
    const allocator = testing.allocator;
    const bytes =
        \\{"kind":"header","seq":1,"ts":"t","format":1,"tool":"devlog 0.1.0","change":"x","roles":["architect"],"closers":["architect"]}
        \\{"kind":"post","seq":3,"ts":"t","role":"worker","body":"hi"}
    ;
    var diag: Diagnostics = .{};
    const result = parseLog(allocator, bytes, &diag);
    try testing.expectError(error.NonContiguousSeq, result);
}

test "refs are stored verbatim across any namespace, unvalidated (D10)" {
    const allocator = testing.allocator;
    const line =
        \\{"kind":"post","seq":1,"ts":"t","role":"worker","refs":[{"ns":"D","id":"2"},{"ns":"totally-unknown-ns","id":"whatever"}],"body":"hi"}
    ;
    var diag: Diagnostics = .{};
    var parsed = try parseLine(allocator, line, &diag);
    defer parsed.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), parsed.post.common.refs.len);
    try testing.expectEqualStrings("totally-unknown-ns", parsed.post.common.refs[1].ns);
}
