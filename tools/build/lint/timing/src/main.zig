//! timing: the wall-clock ledger's validation (rules.zig says what it checks).
//!
//! usage: timing --tree <dir> --list <path in the tree> [--expect <text>]... --out <file>
//!
//! Reads every Zig file of <dir> (the repository's files at their paths) and
//! the list at <path in the tree>, and writes <file>, the validation result
//! Buck2 reads: status "failure" with the findings as the message when there
//! are any, "success" with the numbers checked otherwise. With `--expect`, the
//! verdict is inverted for a planted defect: the status is "success" only when
//! there are findings and the report holds every expected text.
//!
//! Exit status: 0 the result is written (either status); 1 the tree or the
//! list cannot be read, or the result cannot be written; 2 bad usage.

const std = @import("std");
const rules = @import("rules.zig");

const usage = "usage: timing --tree <dir> --list <path in the tree> [--expect <text>]... --out <file>\n";

fn usageFail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("timing: " ++ fmt ++ "\n" ++ usage, args);
    std.process.exit(2);
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("timing: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn main() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const argv = std.process.argsAlloc(alloc) catch fail("out of memory", .{});

    var tree: ?[]const u8 = null;
    var list: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var expect = std.ArrayList([]const u8).empty;
    var i: usize = 1;
    while (i < argv.len) : (i += 2) {
        if (i + 1 >= argv.len) usageFail("{s} needs a value", .{argv[i]});
        const v = argv[i + 1];
        if (std.mem.eql(u8, argv[i], "--tree")) {
            tree = v;
        } else if (std.mem.eql(u8, argv[i], "--list")) {
            list = v;
        } else if (std.mem.eql(u8, argv[i], "--out")) {
            out = v;
        } else if (std.mem.eql(u8, argv[i], "--expect")) {
            if (v.len == 0) usageFail("--expect needs a non-empty text", .{});
            expect.append(alloc, v) catch fail("out of memory", .{});
        } else usageFail("unknown argument {s}", .{argv[i]});
    }
    const tree_path = tree orelse usageFail("--tree is required", .{});
    const name = list orelse usageFail("--list is required", .{});
    const out_path = out orelse usageFail("--out is required", .{});

    var dir = std.fs.cwd().openDir(tree_path, .{ .iterate = true }) catch |err|
        fail("cannot open the tree {s}: {s}", .{ tree_path, @errorName(err) });
    defer dir.close();
    const text = dir.readFileAlloc(alloc, name, 1 << 24) catch |err|
        fail("cannot read the list {s} in the tree: {s}", .{ name, @errorName(err) });
    const found = rules.collect(alloc, dir) catch |err|
        fail("cannot read the tree {s}: {s}", .{ tree_path, @errorName(err) });

    var report = std.ArrayList(u8).empty;
    const r = rules.check(alloc, name, text, found, &report) catch fail("out of memory", .{});
    const v = rules.verdict(r, report.items, expect.items);

    const rendered = rules.render(alloc, name, r, v, report.items, expect.items) catch fail("out of memory", .{});
    std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = rendered.json }) catch |err|
        fail("cannot write {s}: {s}", .{ out_path, @errorName(err) });
    if (!v.ok) std.debug.print("{s}", .{rendered.message});
}

test {
    _ = @import("rules.zig");
}
