//! Text helpers the parsers and expectations share.
const std = @import("std");

pub fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

/// The number of times `needle` occurs in `hay`, not overlapping.
pub fn count(hay: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var n: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, hay, pos, needle)) |i| {
        n += 1;
        pos = i + needle.len;
    }
    return n;
}

/// The last `n` lines of `s` (all of it when it has fewer).
pub fn tail(s: []const u8, n: usize) []const u8 {
    if (s.len == 0) return s;
    var end = s.len;
    if (s[end - 1] == '\n') end -= 1;
    var seen: usize = 0;
    var i = end;
    while (i > 0) : (i -= 1) {
        if (s[i - 1] == '\n') {
            seen += 1;
            if (seen == n) return s[i..end];
        }
    }
    return s[0..end];
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

/// Sorts `items` bytewise (LC_ALL=C order).
pub fn sort(items: [][]const u8) void {
    std.mem.sort([]const u8, items, {}, lessThan);
}

/// Whether two lists hold the same strings in the same order.
pub fn eqlLists(x: []const []const u8, y: []const []const u8) bool {
    if (x.len != y.len) return false;
    for (x, y) |p, q| if (!std.mem.eql(u8, p, q)) return false;
    return true;
}

/// The non-empty lines of `s`, trailing `\r` kept (nothing here writes one).
pub fn lines(a: std.mem.Allocator, s: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |l| if (l.len > 0) try out.append(a, l);
    return out.toOwnedSlice(a);
}

/// `items` joined with `sep`.
pub fn join(a: std.mem.Allocator, items: []const []const u8, sep: []const u8) ![]u8 {
    return std.mem.join(a, sep, items);
}
