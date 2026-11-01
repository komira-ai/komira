//! The ELF fixture of cov_zig's cases (cov_zig_test.zig and
//! cov_zig_exe_test.zig): what the stand-in zig (cov_zig_stub.zig) copies to
//! a link's output. A test-only file: no executable imports it.

const std = @import("std");

fn le(w: anytype, comptime T: type, v: u64) !void {
    try w.writeInt(T, @intCast(v), .little);
}

fn shdr(w: anytype, name: u32, typ: u32, flags: u64, off: u64, size: u64) !void {
    try le(w, u32, name);
    try le(w, u32, typ);
    try le(w, u64, flags);
    try le(w, u64, 0);
    try le(w, u64, off);
    try le(w, u64, size);
    try le(w, u32, 0);
    try le(w, u32, 0);
    try le(w, u64, 1);
    try le(w, u64, 0);
}

/// An ELF64 file with three sections: null, .shstrtab, and `name` holding
/// `payload`.
pub fn elf(a: std.mem.Allocator, name: []const u8, flags: u64, payload: []const u8) ![]const u8 {
    var b = std.ArrayList(u8).empty;
    const w = b.writer(a);
    const sl = 1 + 10 + name.len + 1;
    try b.appendSlice(a, "\x7fELF\x02\x01\x01");
    try b.appendNTimes(a, 0, 9);
    try le(w, u16, 2);
    try le(w, u16, 62);
    try le(w, u32, 1);
    try le(w, u64, 0);
    try le(w, u64, 0);
    try le(w, u64, 64 + sl + payload.len);
    try le(w, u32, 0);
    try le(w, u16, 64);
    try le(w, u16, 0);
    try le(w, u16, 0);
    try le(w, u16, 64);
    try le(w, u16, 3);
    try le(w, u16, 1);
    try b.appendSlice(a, "\x00.shstrtab\x00");
    try b.appendSlice(a, name);
    try b.append(a, 0);
    try b.appendSlice(a, payload);
    try b.appendNTimes(a, 0, 64);
    try shdr(w, 1, 3, 0, 64, sl);
    try shdr(w, 11, 1, flags, 64 + sl, payload.len);
    return b.items;
}
