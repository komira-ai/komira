//! A raw deflate encoder (RFC 1951): one block of fixed Huffman codes over a
//! greedy LZ77 parse (hash chains, a 32 KiB window). The standard library of
//! this zig release has no working compressor (its `Compress` is unfinished),
//! and the packager needs one for the gzip layers it writes. The output is a
//! pure function of the input, so packages stay reproducible.

const std = @import("std");

const LENGTH_BASE = [29]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const LENGTH_EXTRA = [29]u4{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const DIST_BASE = [30]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const DIST_EXTRA = [30]u4{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

const WINDOW: usize = 32768;
const MAX_MATCH: usize = 258;
const MIN_MATCH: usize = 3;
const HASH_BITS = 15;
const CHAIN: usize = 48;

const Bits = struct {
    out: std.ArrayList(u8) = .empty,
    alloc: std.mem.Allocator,
    acc: u64 = 0,
    n: u6 = 0,

    /// `count` bits of `v`, least significant first (how deflate packs extra
    /// bits and headers).
    fn put(self: *Bits, v: u32, count: u6) !void {
        self.acc |= @as(u64, v) << self.n;
        self.n += count;
        while (self.n >= 8) {
            try self.out.append(self.alloc, @truncate(self.acc));
            self.acc >>= 8;
            self.n -= 8;
        }
    }

    /// A Huffman code of `count` bits, most significant bit first.
    fn code(self: *Bits, v: u32, count: u6) !void {
        var rev: u32 = 0;
        var i: u6 = 0;
        while (i < count) : (i += 1) rev |= ((v >> @intCast(i)) & 1) << @intCast(count - 1 - i);
        try self.put(rev, count);
    }

    fn finish(self: *Bits) ![]u8 {
        if (self.n > 0) try self.out.append(self.alloc, @truncate(self.acc));
        return self.out.toOwnedSlice(self.alloc);
    }
};

/// The fixed-Huffman code of literal/length symbol `sym`.
fn litLen(b: *Bits, sym: u32) !void {
    if (sym < 144) return b.code(0x30 + sym, 8);
    if (sym < 256) return b.code(0x190 + (sym - 144), 9);
    if (sym < 280) return b.code(sym - 256, 7);
    return b.code(0xC0 + (sym - 280), 8);
}

fn lengthSymbol(len: usize) usize {
    var i: usize = LENGTH_BASE.len - 1;
    while (LENGTH_BASE[i] > len) i -= 1;
    return i;
}

fn distSymbol(dist: usize) usize {
    var i: usize = DIST_BASE.len - 1;
    while (DIST_BASE[i] > dist) i -= 1;
    return i;
}

fn hash3(d: []const u8, i: usize) usize {
    const v = @as(u32, d[i]) | (@as(u32, d[i + 1]) << 8) | (@as(u32, d[i + 2]) << 16);
    return (v *% 2654435761) >> (32 - HASH_BITS);
}

/// `data` as a raw deflate stream (one final block).
pub fn deflate(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
    var b = Bits{ .alloc = alloc };
    errdefer b.out.deinit(alloc);
    try b.put(0b011, 3); // BFINAL = 1, BTYPE = 01 (fixed Huffman)
    const head = try alloc.alloc(u32, 1 << HASH_BITS); // position + 1, 0 = none
    defer alloc.free(head);
    @memset(head, 0);
    const prev = try alloc.alloc(u32, data.len);
    defer alloc.free(prev);

    var i: usize = 0;
    while (i < data.len) {
        var best_len: usize = 0;
        var best_dist: usize = 0;
        if (i + MIN_MATCH <= data.len) {
            const h = hash3(data, i);
            var cand = head[h];
            var tries: usize = 0;
            const limit = @min(MAX_MATCH, data.len - i);
            while (cand != 0 and tries < CHAIN) : (tries += 1) {
                const at: usize = cand - 1;
                if (i - at > WINDOW) break;
                var l: usize = 0;
                while (l < limit and data[at + l] == data[i + l]) l += 1;
                if (l > best_len) {
                    best_len = l;
                    best_dist = i - at;
                    if (l == limit) break;
                }
                cand = prev[at];
            }
        }
        const step = if (best_len >= MIN_MATCH) best_len else 1;
        if (best_len >= MIN_MATCH) {
            const ls = lengthSymbol(best_len);
            try litLen(&b, @intCast(257 + ls));
            try b.put(@intCast(best_len - LENGTH_BASE[ls]), LENGTH_EXTRA[ls]);
            const ds = distSymbol(best_dist);
            try b.code(@intCast(ds), 5);
            try b.put(@intCast(best_dist - DIST_BASE[ds]), DIST_EXTRA[ds]);
        } else {
            try litLen(&b, data[i]);
        }
        // Every position the step covers enters the chains.
        var k: usize = 0;
        while (k < step) : (k += 1) {
            const p = i + k;
            if (p + MIN_MATCH <= data.len) {
                const h = hash3(data, p);
                prev[p] = head[h];
                head[h] = @intCast(p + 1);
            }
        }
        i += step;
    }
    try litLen(&b, 256);
    return b.finish();
}
