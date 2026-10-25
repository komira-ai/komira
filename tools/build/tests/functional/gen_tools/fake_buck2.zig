//! A stand-in for buck2, for the driver test of `regen`. It answers the three
//! commands regen runs from files in its working directory, and records each call:
//!
//!   uquery ... <query>       prints fake/uquery.json (exit 3 if fake/uquery_fails exists)
//!   build --show-full-output <label>...   prints fake/build.txt (exit 4 if fake/build_fails exists)
//!   audit cell --paths-only <cell>        prints fake/cell_root
//!
//! Every call is appended to calls.log as its arguments joined by spaces.
const std = @import("std");

fn exists(name: []const u8) bool {
    std.fs.cwd().access(name, .{}) catch return false;
    return true;
}

fn say(path: []const u8) void {
    const a = std.heap.page_allocator;
    const data = std.fs.cwd().readFileAlloc(a, path, 1 << 20) catch std.process.exit(9);
    _ = std.posix.write(1, data) catch std.process.exit(9);
}

pub fn main() void {
    const a = std.heap.page_allocator;
    const argv = std.process.argsAlloc(a) catch std.process.exit(9);
    var line = std.ArrayList(u8).empty;
    for (argv[1..], 0..) |s, i| {
        if (i > 0) line.append(a, ' ') catch std.process.exit(9);
        line.appendSlice(a, s) catch std.process.exit(9);
    }
    line.append(a, '\n') catch std.process.exit(9);
    const log = std.fs.cwd().createFile("calls.log", .{ .truncate = false }) catch std.process.exit(9);
    defer log.close();
    log.seekFromEnd(0) catch std.process.exit(9);
    log.writeAll(line.items) catch std.process.exit(9);

    if (argv.len < 2) std.process.exit(9);
    if (std.mem.eql(u8, argv[1], "uquery")) {
        if (exists("fake/uquery_fails")) std.process.exit(3);
        say("fake/uquery.json");
    } else if (std.mem.eql(u8, argv[1], "build")) {
        if (exists("fake/build_fails")) std.process.exit(4);
        say("fake/build.txt");
    } else if (std.mem.eql(u8, argv[1], "audit")) {
        say("fake/cell_root");
    } else {
        std.process.exit(9);
    }
}
