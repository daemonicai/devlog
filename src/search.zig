// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//! Lexical search over record bodies — tokenisation and a BM25 index,
//! built in memory from records already parsed and thrown away with them
//! (design.md D3; ADR-0002 — no persisted index, no cache file, no
//! embeddings, no model download).
//!
//! This module performs **no filesystem access whatsoever** and knows
//! nothing about argv or output: it takes a slice of `record.Record` and a
//! query string, and returns those records ranked. Scoping search to one
//! change (`log-retrieval`) is therefore not this module's problem either
//! — it ranks exactly the records it is handed.
//!
//! The returned slice is allocated here and owned by the caller; its
//! elements *borrow* from the records passed in, exactly as `state.zig`'s
//! indexes do, so the caller must keep the `record.ParsedLog` alive for as
//! long as it holds the result.
//!
//! **The document is `common.body`, and nothing else** (architect ruling
//! R4, DEVLOG `## 7`). A `section`'s title, a `verdict`'s commit and a
//! `close`'s state are metadata, not prose. `record.Record.body()` owns
//! which field that is — this module never switches on the union tag — and
//! a record with no body (only `header`) is not a document at all.

const std = @import("std");
const Allocator = std.mem.Allocator;
const record = @import("record.zig");

/// BM25's term-frequency saturation and length-normalisation parameters,
/// at their standard values. Deliberately **not** exposed: `search` emits
/// the ranking as the order of its results and never a score (ruling R3),
/// precisely so these two stay an implementation detail that can be tuned
/// without breaking a consumer.
const bm25_k1: f64 = 1.2;
const bm25_b: f64 = 0.75;

/// True for a byte that is part of a token: an ASCII alphanumeric, or any
/// byte at or above `0x80`.
///
/// The second half is what makes the tokeniser UTF-8-safe. Every byte of a
/// multi-byte UTF-8 sequence — lead and continuation alike — is `>= 0x80`,
/// so treating those bytes as token characters keeps a non-ASCII word
/// whole; treating them as separators (the obvious `isAlphanumeric`-only
/// rule) would shatter `café` into `caf` and a dropped tail, and `日本語`
/// into nothing at all. Bodies are validated UTF-8 before they are ever
/// written (D14), so a token can never begin or end mid-codepoint.
fn isTokenByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

/// Splits text into tokens: maximal runs of `isTokenByte`, everything else
/// a separator. Yields the raw bytes — case folding is not done here but
/// in term comparison (`FoldedTerm`), so no token is ever copied.
///
/// **This is the whole tokenisation rule, stated once**: ASCII case fold,
/// split on non-alphanumeric ASCII, and *no stemming and no stop-word
/// list*. D3 licenses neither, and a stop list in particular would be a
/// second place for this project's vocabulary to live, one that silently
/// makes a real query ("the log is the only state") match nothing.
pub const Tokenizer = struct {
    input: []const u8,
    pos: usize = 0,

    pub fn init(input: []const u8) Tokenizer {
        return .{ .input = input };
    }

    pub fn next(self: *Tokenizer) ?[]const u8 {
        while (self.pos < self.input.len and !isTokenByte(self.input[self.pos])) self.pos += 1;
        if (self.pos == self.input.len) return null;
        const start = self.pos;
        while (self.pos < self.input.len and isTokenByte(self.input[self.pos])) self.pos += 1;
        return self.input[start..self.pos];
    }
};

/// Hashes and compares terms with an ASCII case fold, so the index's keys
/// can borrow the body bytes verbatim instead of allocating a lowercased
/// copy of every token. `std.ascii.toLower` touches `A`–`Z` only, leaving
/// every byte `>= 0x80` alone — the fold is ASCII, so `Café` and `café`
/// are one term while `CAFÉ` keeps its own (no Unicode case folding: D3
/// buys a lexical index, not a text-processing library).
const FoldedTerm = struct {
    pub fn hash(_: FoldedTerm, key: []const u8) u64 {
        var hasher = std.hash.Wyhash.init(0);
        for (key) |c| {
            const folded = [_]u8{std.ascii.toLower(c)};
            hasher.update(&folded);
        }
        return hasher.final();
    }

    pub fn eql(_: FoldedTerm, a: []const u8, b: []const u8) bool {
        return std.ascii.eqlIgnoreCase(a, b);
    }
};

/// One term's occurrence count within one document. `doc` indexes
/// `Index.docs`/`Index.doc_len`.
const Posting = struct { doc: u32, tf: u32 };

const PostingMap = std.HashMapUnmanaged(
    []const u8,
    std.ArrayList(Posting),
    FoldedTerm,
    std.hash_map.default_max_load_percentage,
);

/// A record and the score it earned, internal to `Index.rank` — the score
/// decides the order and is then discarded (R3).
const Scored = struct { rec: record.Record, score: f64 };

/// Ranks by descending score, ties by ascending `seq`.
///
/// The tiebreak is what makes the ordering a *total* order and therefore
/// reproducible: two records with the same terms at the same lengths score
/// identically to the last bit, and without it their relative order would
/// depend on the sort's internals rather than on the log.
fn scoreThenSeqLessThan(_: void, a: Scored, b: Scored) bool {
    if (a.score != b.score) return a.score > b.score;
    return a.rec.seq() < b.rec.seq();
}

fn containsFolded(terms: []const []const u8, term: []const u8) bool {
    for (terms) |t| {
        if (std.ascii.eqlIgnoreCase(t, term)) return true;
    }
    return false;
}

/// An inverted index over the bodies of one log's records, built per
/// invocation and discarded on exit (D3, ADR-0002). Nothing here is
/// written to disk, and nothing here is reused between runs.
pub const Index = struct {
    allocator: Allocator,
    /// The records that are documents — those with a body — in log order.
    /// Borrowed from the caller's records; freeing the slice frees no
    /// record.
    docs: []const record.Record,
    /// Each document's length in tokens, parallel to `docs`.
    doc_len: []const u32,
    /// Term → its postings, in ascending `doc` order. Keys borrow the body
    /// bytes of the first occurrence of the term; because lookup folds
    /// case, which spelling that was is never load-bearing.
    postings: PostingMap,
    /// Mean document length in tokens, BM25's `avgdl`. Zero only when
    /// there are no documents or no tokens at all — in which case there
    /// are no postings either, so it is never a divisor (see `rank`).
    avg_doc_len: f64,

    pub fn build(allocator: Allocator, records: []const record.Record) Allocator.Error!Index {
        var docs: std.ArrayList(record.Record) = .empty;
        errdefer docs.deinit(allocator);
        var lengths: std.ArrayList(u32) = .empty;
        errdefer lengths.deinit(allocator);
        var postings: PostingMap = .empty;
        errdefer freePostings(&postings, allocator);

        var total_tokens: u64 = 0;
        for (records) |rec| {
            const text = rec.body() orelse continue;
            const doc: u32 = @intCast(docs.items.len);
            try docs.append(allocator, rec);

            var length: u32 = 0;
            var tokens: Tokenizer = .init(text);
            while (tokens.next()) |term| {
                length += 1;
                const gop = try postings.getOrPut(allocator, term);
                if (!gop.found_existing) {
                    gop.key_ptr.* = term;
                    gop.value_ptr.* = .empty;
                }
                // Documents are indexed in log order and a term's postings
                // are only ever appended to, so the last posting for a term
                // is this document's if it has one at all — no lookup, and
                // every postings list stays in ascending `doc` order, which
                // is what fixes the order the scores are summed in and so
                // makes the floating-point result itself reproducible.
                const list = gop.value_ptr;
                if (list.items.len > 0 and list.items[list.items.len - 1].doc == doc) {
                    list.items[list.items.len - 1].tf += 1;
                } else {
                    try list.append(allocator, .{ .doc = doc, .tf = 1 });
                }
            }
            try lengths.append(allocator, length);
            total_tokens += length;
        }

        const doc_slice = try docs.toOwnedSlice(allocator);
        errdefer allocator.free(doc_slice);
        const len_slice = try lengths.toOwnedSlice(allocator);

        return .{
            .allocator = allocator,
            .docs = doc_slice,
            .doc_len = len_slice,
            .postings = postings,
            .avg_doc_len = if (doc_slice.len == 0)
                0
            else
                @as(f64, @floatFromInt(total_tokens)) / @as(f64, @floatFromInt(doc_slice.len)),
        };
    }

    pub fn deinit(self: *Index) void {
        freePostings(&self.postings, self.allocator);
        self.allocator.free(self.docs);
        self.allocator.free(self.doc_len);
    }

    /// The matching records, most relevant first. A record matches when it
    /// contains at least one of the query's terms; the query is a bag of
    /// terms, not a phrase and not a conjunction.
    ///
    /// Okapi BM25, since it is not self-evident from the code below:
    ///
    ///     score(D, Q) = Σ_{t ∈ Q}  IDF(t) · ( tf(t,D) · (k1 + 1) )
    ///                              ─────────────────────────────────────
    ///                              tf(t,D) + k1 · (1 − b + b · |D| / avgdl)
    ///
    ///     IDF(t) = ln( 1 + (N − df(t) + 0.5) / (df(t) + 0.5) )
    ///
    /// where `N` is the number of documents, `df(t)` the number containing
    /// `t`, `tf(t,D)` the count of `t` in `D`, `|D|` that document's length
    /// in tokens and `avgdl` the mean over all documents. `k1` saturates
    /// repetition; `b` normalises for length. The `1 +` in the IDF is the
    /// standard smoothing that keeps it positive even for a term in every
    /// document — worth having on a corpus of 50–200 records from one
    /// change, where a term genuinely can appear everywhere, and what lets
    /// "score above zero" mean exactly "matched at least one term".
    ///
    /// Caller owns the returned slice; its records borrow from the ones
    /// the index was built over.
    pub fn rank(self: *const Index, allocator: Allocator, query: []const u8) Allocator.Error![]record.Record {
        const scores = try allocator.alloc(f64, self.docs.len);
        defer allocator.free(scores);
        @memset(scores, 0);

        // A term repeated in the query is one term: BM25 already models
        // repetition on the document side, and counting "log log" twice
        // would weight it by how the caller happened to phrase the
        // question rather than by what the log says. Queries are a handful
        // of words, so a linear scan is the right container.
        var terms: std.ArrayList([]const u8) = .empty;
        defer terms.deinit(allocator);
        var query_tokens: Tokenizer = .init(query);
        while (query_tokens.next()) |term| {
            if (containsFolded(terms.items, term)) continue;
            try terms.append(allocator, term);
        }

        const n: f64 = @floatFromInt(self.docs.len);
        for (terms.items) |term| {
            const list = self.postings.getPtr(term) orelse continue;
            const df: f64 = @floatFromInt(list.items.len);
            const idf = @log(1.0 + (n - df + 0.5) / (df + 0.5));
            for (list.items) |posting| {
                // A posting exists only for a document with at least one
                // token, so `avg_doc_len` is strictly positive here — the
                // guard is structural, not a check that could be forgotten.
                const tf: f64 = @floatFromInt(posting.tf);
                const dl: f64 = @floatFromInt(self.doc_len[posting.doc]);
                const denominator = tf + bm25_k1 * (1.0 - bm25_b + bm25_b * dl / self.avg_doc_len);
                scores[posting.doc] += idf * (tf * (bm25_k1 + 1.0)) / denominator;
            }
        }

        var hits: std.ArrayList(Scored) = .empty;
        defer hits.deinit(allocator);
        for (self.docs, 0..) |rec, i| {
            if (scores[i] > 0) try hits.append(allocator, .{ .rec = rec, .score = scores[i] });
        }
        std.mem.sort(Scored, hits.items, {}, scoreThenSeqLessThan);

        const ranked = try allocator.alloc(record.Record, hits.items.len);
        for (hits.items, 0..) |hit, i| ranked[i] = hit.rec;
        return ranked;
    }
};

fn freePostings(postings: *PostingMap, allocator: Allocator) void {
    var it = postings.valueIterator();
    while (it.next()) |list| list.deinit(allocator);
    postings.deinit(allocator);
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;

fn collectTokens(allocator: Allocator, input: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    var it: Tokenizer = .init(input);
    while (it.next()) |t| try out.append(allocator, t);
    return out.toOwnedSlice(allocator);
}

fn expectTokens(input: []const u8, expected: []const []const u8) !void {
    const got = try collectTokens(testing.allocator, input);
    defer testing.allocator.free(got);
    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |want, have| try testing.expectEqualStrings(want, have);
}

test "the tokeniser splits on every non-alphanumeric ASCII byte and keeps digits" {
    try expectTokens(
        "The quick-brown fox's DEVLOG.jsonl, v2!",
        &.{ "The", "quick", "brown", "fox", "s", "DEVLOG", "jsonl", "v2" },
    );
    try expectTokens("", &.{});
    try expectTokens("   --- ,.;   ", &.{});
}

test "the tokeniser is UTF-8-safe: a multi-byte word is one token, not several" {
    // Every byte of a multi-byte sequence is >= 0x80. A tokeniser that
    // treated those as separators would return "caf"/"na"/"ve" here and
    // nothing at all for the CJK run — this is the test that catches it.
    try expectTokens("café naïve", &.{ "café", "naïve" });
    try expectTokens("日本語 text", &.{ "日本語", "text" });
    try expectTokens("emoji 🚀 alone", &.{ "emoji", "🚀", "alone" });
}

test "terms fold ASCII case but leave non-ASCII bytes alone" {
    try testing.expect(FoldedTerm.eql(.{}, "Append", "APPEND"));
    try testing.expect(FoldedTerm.eql(.{}, "café", "CAFé"));
    try testing.expect(!FoldedTerm.eql(.{}, "café", "cafe"));
    try testing.expectEqual(FoldedTerm.hash(.{}, "Append"), FoldedTerm.hash(.{}, "append"));
}

fn post(seq: u64, body_text: []const u8) record.Record {
    return .{ .post = .{ .common = .{ .seq = seq, .ts = "t", .role = "worker", .body = body_text } } };
}

fn expectRanked(records: []const record.Record, query: []const u8, expected_seqs: []const u64) !void {
    var index = try Index.build(testing.allocator, records);
    defer index.deinit();
    const ranked = try index.rank(testing.allocator, query);
    defer testing.allocator.free(ranked);

    try testing.expectEqual(expected_seqs.len, ranked.len);
    for (expected_seqs, ranked) |want, have| try testing.expectEqual(want, have.seq());
}

test "a header is not a document: it has no body to index" {
    const records = [_]record.Record{
        .{ .header = .{
            .seq = 1,
            .ts = "t",
            .format = 1,
            .tool = "devlog 0.1.0",
            .change = "add-devlog-core",
            .roles = &.{"worker"},
            .closers = &.{"architect"},
        } },
        post(2, "the header record carries no body"),
    };

    var index = try Index.build(testing.allocator, &records);
    defer index.deinit();
    try testing.expectEqual(@as(usize, 1), index.docs.len);
    try testing.expectEqual(@as(u64, 2), index.docs[0].seq());
    // "header" appears once, in the one document — the header record's own
    // `change` and `tool` fields are metadata and were never indexed.
    try testing.expectEqual(@as(usize, 1), index.postings.getPtr("header").?.items.len);
}

test "ranking is by relevance, worked by hand: more occurrences in a shorter body wins" {
    const records = [_]record.Record{
        // 4 tokens, "lock" twice.
        post(1, "lock the lock now"),
        // 12 tokens, "lock" once — longer and less about it.
        post(2, "we should probably think about whether the write path takes a lock"),
        post(3, "nothing about concurrency at all here"),
    };
    try expectRanked(&records, "lock", &.{ 1, 2 });
}

test "a rare term outweighs one that appears in every document (IDF)" {
    const records = [_]record.Record{
        post(1, "the log is append only"),
        post(2, "the log is the only state"),
        post(3, "the log is locked while writing"),
        post(4, "the log is fsynced"),
    };
    // "log" is in all four; "fsynced" in one. The record carrying the rare
    // term must win despite both matching exactly one query term.
    try expectRanked(&records, "log fsynced", &.{ 4, 1, 2, 3 });
}

test "ties break by seq ascending, so the order is reproducible (R3)" {
    const records = [_]record.Record{
        post(7, "identical body about locking"),
        post(3, "identical body about locking"),
        post(5, "identical body about locking"),
    };
    try expectRanked(&records, "locking", &.{ 3, 5, 7 });
}

test "matching is case-insensitive across ASCII, in both directions" {
    const records = [_]record.Record{
        post(1, "ATOMIC replace under the lock"),
        post(2, "nothing relevant"),
    };
    try expectRanked(&records, "Atomic", &.{1});
    try expectRanked(&records, "atomic", &.{1});
    try expectRanked(&records, "AtOmIc", &.{1});
}

test "a query is a bag of terms: any term matching is a match" {
    const records = [_]record.Record{
        post(1, "the append path"),
        post(2, "the read path"),
        post(3, "unrelated"),
    };
    const ranked_seqs = [_]u64{ 1, 2 };
    try expectRanked(&records, "append read", &ranked_seqs);
}

test "no matches, an all-punctuation query, and an empty corpus are each an empty ranking" {
    const records = [_]record.Record{ post(1, "one"), post(2, "two") };
    try expectRanked(&records, "three", &.{});
    try expectRanked(&records, "--- , ;", &.{});
    try expectRanked(&.{}, "anything", &.{});
}

test "a repeated query term is one term, not two" {
    const records = [_]record.Record{
        post(1, "lock lock lock"),
        post(2, "lock and a mention of the temp file"),
    };
    var index = try Index.build(testing.allocator, &records);
    defer index.deinit();

    const once = try index.rank(testing.allocator, "lock");
    defer testing.allocator.free(once);
    const twice = try index.rank(testing.allocator, "lock LOCK");
    defer testing.allocator.free(twice);

    try testing.expectEqual(once.len, twice.len);
    for (once, twice) |a, b| try testing.expectEqual(a.seq(), b.seq());
}

test "an empty body is a document that can never match" {
    const records = [_]record.Record{ post(1, ""), post(2, "something") };
    var index = try Index.build(testing.allocator, &records);
    defer index.deinit();
    try testing.expectEqual(@as(usize, 2), index.docs.len);
    try testing.expectEqual(@as(u32, 0), index.doc_len[0]);
    try expectRanked(&records, "something", &.{2});
}

test "the index is built over exactly the records it is handed, and borrows them" {
    // The narrowing 7.3 will do is a smaller slice, not a flag on this
    // module: ranking two of three records is the same call with a
    // different slice.
    const records = [_]record.Record{
        post(1, "alpha beta"),
        post(2, "alpha gamma"),
        post(3, "alpha delta"),
    };
    try expectRanked(records[0..2], "alpha", &.{ 1, 2 });
}
