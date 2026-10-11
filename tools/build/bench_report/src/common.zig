//! What every module of bench_report shares: one arena (the tool runs once
//! and exits, so nothing is freed) and the refusal message.

const std = @import("std");

/// A refusal: its text is `msg`.
pub const Fail = error{Fail};

pub var msg: []const u8 = "";

var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);

pub fn a() std.mem.Allocator {
    return arena_state.allocator();
}

pub fn oom() noreturn {
    @panic("out of memory");
}

pub fn list(comptime T: type) std.ArrayList(T) {
    return std.ArrayList(T).init(a());
}

pub fn push(comptime T: type, l: *std.ArrayList(T), v: T) void {
    l.append(v) catch oom();
}

pub fn add(l: *std.ArrayList(u8), s: []const u8) void {
    l.appendSlice(s) catch oom();
}

pub fn fmt(comptime f: []const u8, args: anytype) []u8 {
    return std.fmt.allocPrint(a(), f, args) catch oom();
}

/// Sets the refusal text and returns the error that carries it.
pub fn fail(comptime f: []const u8, args: anytype) Fail {
    msg = fmt(f, args);
    return error.Fail;
}

pub fn eql(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

pub fn join(parts: []const []const u8, sep: []const u8) []u8 {
    return std.mem.join(a(), sep, parts) catch oom();
}

/// `s` with its first `from` replaced by `to`, or null when `from` does not
/// occur exactly once.
pub fn replaceOnce(s: []const u8, from: []const u8, to: []const u8) ?[]u8 {
    if (std.mem.count(u8, s, from) != 1) return null;
    const i = std.mem.indexOf(u8, s, from).?;
    return std.mem.concat(a(), u8, &.{ s[0..i], to, s[i + from.len ..] }) catch oom();
}
