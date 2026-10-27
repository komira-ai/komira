//! deflate.zig against the standard library's decoder: every input comes back
//! byte for byte, and repetition really is compressed (a match encoder that
//! only wrote literals would round-trip too).

const std = @import("std");
const d = @import("deflate.zig");
const t = std.testing;

fn inflate(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(raw);
    // No window buffer: the decoder writes straight into the output, which keeps
    // the history (the windowed mode of this release mishandles a fixed-Huffman
    // match that reaches the end of its window).
    var dec = std.compress.flate.Decompress.init(&in, .raw, &.{});
    var out = std.Io.Writer.Allocating.init(alloc);
    errdefer out.deinit();
    _ = try dec.reader.streamRemaining(&out.writer);
    return out.toOwnedSlice();
}

fn roundTrip(data: []const u8) !usize {
    const raw = try d.deflate(t.allocator, data);
    defer t.allocator.free(raw);
    const back = try inflate(t.allocator, raw);
    defer t.allocator.free(back);
    try t.expectEqualSlices(u8, data, back);
    return raw.len;
}

test "empty, one byte, short text" {
    _ = try roundTrip("");
    _ = try roundTrip("a");
    _ = try roundTrip("abcabcabcabc, abcabcabcabc");
}

test "a long run of one byte is a few bytes of matches" {
    const data = try t.allocator.alloc(u8, 100_000);
    defer t.allocator.free(data);
    @memset(data, 'a');
    const n = try roundTrip(data);
    try t.expect(n < 1000);
}

test "bytes that do not repeat round-trip (literals above 143 included)" {
    const data = try t.allocator.alloc(u8, 70_000);
    defer t.allocator.free(data);
    var x: u32 = 12345;
    for (data) |*b| {
        x = x *% 1664525 +% 1013904223;
        b.* = @truncate(x >> 24);
    }
    _ = try roundTrip(data);
}

test "a pattern repeated beyond the 32 KiB window, and a match at the largest distance" {
    const block = try t.allocator.alloc(u8, 40_000);
    defer t.allocator.free(block);
    var x: u32 = 99;
    for (block) |*b| {
        x = x *% 1103515245 +% 12345;
        b.* = @truncate(x >> 16);
    }
    // Out of the window: 40000 back. It must round-trip, as literals.
    const far = try std.mem.concat(t.allocator, u8, &.{ block, block });
    defer t.allocator.free(far);
    _ = try roundTrip(far);
    // Inside it: 30000 back, three copies; the last two collapse into matches.
    const near = try std.mem.concat(t.allocator, u8, &.{ block[0..30_000], block[0..30_000], block[0..30_000] });
    defer t.allocator.free(near);
    const n = try roundTrip(near);
    try t.expect(n < near.len / 2);
}

test "text with every match length and several distances" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(t.allocator);
    var len: usize = 3;
    while (len <= 300) : (len += 1) {
        try list.appendNTimes(t.allocator, 'x', len);
        try list.append(t.allocator, @intCast('A' + len % 26));
        try list.appendSlice(t.allocator, "the quick brown fox ");
    }
    _ = try roundTrip(list.items);
}
