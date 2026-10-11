//! Test fixtures: a tar writer (ustar, and pax for a long name), laid out
//! here rather than by the writer under test.

const std = @import("std");
const C = @import("common.zig");

pub fn header(name: []const u8, flag: u8, mode: u32, size: usize, link: []const u8) []u8 {
    const h = C.a().alloc(u8, 512) catch C.oom();
    @memset(h, 0);
    @memcpy(h[0..name.len], name);
    @memcpy(h[100..108], C.fmt("{o:0>7}\x00", .{mode}));
    @memcpy(h[124..136], C.fmt("{o:0>11}\x00", .{size}));
    h[156] = flag;
    @memcpy(h[157 .. 157 + link.len], link);
    @memcpy(h[257..263], "ustar\x00");
    @memcpy(h[263..265], "00");
    @memset(h[148..156], ' ');
    var sum: u32 = 0;
    for (h) |b| sum += b;
    @memcpy(h[148..156], C.fmt("{o:0>6}\x00 ", .{sum}));
    return h;
}

/// `t` padded with zeros to a whole number of blocks.
pub fn padBlock(t: *C.List(u8)) void {
    const want = (t.items.len + 511) / 512 * 512;
    t.appendNTimes(0, want - t.items.len) catch C.oom();
}

pub fn entry(out: *C.List(u8), name: []const u8, flag: u8, mode: u32, data: []const u8, link: []const u8) void {
    C.add(out, header(name, flag, mode, data.len, link));
    C.add(out, data);
    padBlock(out);
}

/// `(path, flag, mode, data, link)`
pub const E = struct { []const u8, u8, u32, []const u8, []const u8 };

/// Entries, then the two zero blocks.
pub fn tar(entries: []const E) []u8 {
    var out = C.list(u8);
    for (entries) |e| entry(&out, e[0], e[1], e[2], e[3], e[4]);
    out.appendNTimes(0, 1024) catch C.oom();
    return out.items;
}

/// `t` and two zero blocks.
pub fn end(t: []const u8) []u8 {
    var out = C.list(u8);
    C.add(&out, t);
    out.appendNTimes(0, 1024) catch C.oom();
    return out.items;
}

pub fn rep(s: []const u8, n: usize) []u8 {
    var out = C.list(u8);
    for (0..n) |_| C.add(&out, s);
    return out.items;
}

pub fn cat(x: []const u8, y: []const u8) []u8 {
    return C.fmt("{s}{s}", .{ x, y });
}

/// `r`, an error union, is a refusal whose text is exactly `want`.
pub fn expectFail(r: anytype, want: []const u8) !void {
    if (r) |_| {
        std.debug.print("accepted; want the refusal `{s}`\n", .{want});
        return error.TestUnexpectedResult;
    } else |_| try std.testing.expectEqualStrings(want, C.msg);
}

/// `r` is a refusal whose text starts with `prefix`.
pub fn expectFailPrefix(r: anytype, prefix: []const u8) !void {
    if (r) |_| {
        std.debug.print("accepted; want a refusal starting `{s}`\n", .{prefix});
        return error.TestUnexpectedResult;
    } else |_| {
        if (!C.startsWith(C.msg, prefix)) {
            std.debug.print("refused `{s}`; want it to start `{s}`\n", .{ C.msg, prefix });
            return error.TestUnexpectedResult;
        }
    }
}

/// `r` is a refusal whose text holds `part`.
pub fn expectFailContains(r: anytype, part: []const u8) !void {
    if (r) |_| {
        std.debug.print("accepted; want a refusal holding `{s}`\n", .{part});
        return error.TestUnexpectedResult;
    } else |_| {
        if (!C.contains(C.msg, part)) {
            std.debug.print("refused `{s}`; want it to hold `{s}`\n", .{ C.msg, part });
            return error.TestUnexpectedResult;
        }
    }
}

/// The refusal's text, failing the test if `r` was accepted.
pub fn failText(r: anytype) ![]const u8 {
    if (r) |_| {
        std.debug.print("accepted; want a refusal\n", .{});
        return error.TestUnexpectedResult;
    } else |_| return C.msg;
}

pub fn ok(r: anytype) !@typeInfo(@TypeOf(r)).ErrorUnion.payload {
    return r catch {
        std.debug.print("refused: {s}\n", .{C.msg});
        return error.TestUnexpectedResult;
    };
}
