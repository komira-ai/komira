//! cov_zig_stub: the stand-in `real/zig` of the cases in cov_zig_test.zig.
//!
//! usage: <dir>/zig <arguments...>
//!
//! It writes its arguments (argv[1..]), one per line, to `<dir>/argv`. When
//! `<dir>/stub_out` exists, it holds the path of a file the stub copies to
//! the output a `-o <file>` or `-o<file>` argument names (the last one, in
//! the working directory). It exits with the decimal status in
//! `<dir>/stub_rc`, 0 when there is none. <dir> is the directory argv[0]
//! names. A test-only program: no rule hands it out.

const std = @import("std");

fn readOpt(alloc: std.mem.Allocator, dir: std.fs.Dir, name: []const u8) !?[]const u8 {
    return dir.readFileAlloc(alloc, name, 1 << 16) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
}

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    const argv = try std.process.argsAlloc(alloc);
    var dir = try std.fs.cwd().openDir(std.fs.path.dirname(argv[0]) orelse return error.NoDirectory, .{});
    defer dir.close();

    var rec = std.ArrayList(u8).empty;
    var out: ?[]const u8 = null;
    var prev: []const u8 = "";
    for (argv[1..]) |a| {
        try rec.appendSlice(alloc, a);
        try rec.append(alloc, '\n');
        if (std.mem.eql(u8, prev, "-o")) out = a;
        if (a.len > 2 and std.mem.startsWith(u8, a, "-o")) out = a[2..];
        prev = a;
    }
    try dir.writeFile(.{ .sub_path = "argv", .data = rec.items });

    if (out) |o| {
        if (try readOpt(alloc, dir, "stub_out")) |src| {
            try std.fs.cwd().copyFile(std.mem.trimRight(u8, src, "\n"), std.fs.cwd(), o, .{});
        }
    }
    const rc = (try readOpt(alloc, dir, "stub_rc")) orelse return 0;
    return try std.fmt.parseUnsigned(u8, std.mem.trim(u8, rc, " \n"), 10);
}
