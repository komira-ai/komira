//! native_policy: how a refusal travels. Every function that can refuse returns
//! `error.Refused` and leaves the reason in a `Diag`; only the command (the
//! tool's main.zig, as komira_wheel's) turns it into an exit, so each refusal
//! is unit-tested in process by its exact message.

const std = @import("std");
const Alloc = std.mem.Allocator;

pub const Diag = struct {
    msg: []const u8 = "",
};

pub const Refused = error{Refused} || Alloc.Error;

pub fn refuse(d: *Diag, alloc: Alloc, comptime fmt: []const u8, args: anytype) Refused {
    d.msg = try std.fmt.allocPrint(alloc, fmt, args);
    return error.Refused;
}

/// The part of `path` after its last `/`.
pub fn baseName(path: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| path[s + 1 ..] else path;
}

/// `a` and `b` as dot-separated numbers, compared part by part (a missing
/// part is 0): -1, 0 or 1. Null when either is not dot-separated digits.
pub fn compareVersions(a: []const u8, b: []const u8) ?std.math.Order {
    var ia = std.mem.splitScalar(u8, a, '.');
    var ib = std.mem.splitScalar(u8, b, '.');
    if (a.len == 0 or b.len == 0) return null;
    while (true) {
        const pa = ia.next();
        const pb = ib.next();
        if (pa == null and pb == null) return .eq;
        const na = number(pa orelse "0") orelse return null;
        const nb = number(pb orelse "0") orelse return null;
        if (na != nb) return std.math.order(na, nb);
    }
}

fn number(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    for (s) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u64, s, 10) catch null;
}
