//! shell_budget: the shell regrowth guard's validation (budget.zig says what
//! it checks).
//!
//! usage: shell_budget --tree <dir> --allowlist <path in the tree> --out <file>
//!
//! Reads every file of <dir> (the repository's files at their paths) and the
//! allowlist at <path in the tree>, and writes <file>, the validation result
//! Buck2 reads: status "failure" with the findings as the message when there
//! are any, "success" with the number of scripts checked otherwise.
//!
//! Exit status: 0 the result is written (either status); 1 the tree or the
//! allowlist cannot be read, or the result cannot be written; 2 bad usage.
//!
//! A static executable: it runs with no shell, no PATH and no network.

const std = @import("std");
const budget = @import("budget.zig");

const usage = "usage: shell_budget --tree <dir> --allowlist <path in the tree> --out <file>\n";

fn usageFail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("shell_budget: " ++ fmt ++ "\n" ++ usage, args);
    std.process.exit(2);
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("shell_budget: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn main() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const argv = std.process.argsAlloc(alloc) catch fail("out of memory", .{});

    var tree: ?[]const u8 = null;
    var allowlist: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 2) {
        if (i + 1 >= argv.len) usageFail("{s} needs a value", .{argv[i]});
        const v = argv[i + 1];
        if (std.mem.eql(u8, argv[i], "--tree")) {
            tree = v;
        } else if (std.mem.eql(u8, argv[i], "--allowlist")) {
            allowlist = v;
        } else if (std.mem.eql(u8, argv[i], "--out")) {
            out = v;
        } else usageFail("unknown argument {s}", .{argv[i]});
    }
    const tree_path = tree orelse usageFail("--tree is required", .{});
    const name = allowlist orelse usageFail("--allowlist is required", .{});
    const out_path = out orelse usageFail("--out is required", .{});

    var dir = std.fs.cwd().openDir(tree_path, .{ .iterate = true }) catch |err|
        fail("cannot open the tree {s}: {s}", .{ tree_path, @errorName(err) });
    defer dir.close();
    const text = dir.readFileAlloc(alloc, name, 1 << 24) catch |err|
        fail("cannot read the allowlist {s} in the tree: {s}", .{ name, @errorName(err) });
    const scripts = budget.collect(alloc, dir) catch |err|
        fail("cannot read the tree {s}: {s}", .{ tree_path, @errorName(err) });

    var report = std.ArrayList(u8).init(alloc);
    const r = budget.check(alloc, name, text, scripts, &report) catch fail("out of memory", .{});

    var message = std.ArrayList(u8).init(alloc);
    const status = if (r.findings > 0) "failure" else "success";
    if (r.findings > 0) {
        message.writer().print("shell_budget: {d} finding(s) over {d} shell script(s)\n{s}", .{ r.findings, r.scripts, report.items }) catch fail("out of memory", .{});
    } else {
        message.writer().print("shell_budget: {d} shell script(s) checked against {s}", .{ r.scripts, name }) catch fail("out of memory", .{});
    }
    var json = std.ArrayList(u8).init(alloc);
    const jw = json.writer();
    jw.print("{{\"version\": 1, \"data\": {{\"status\": \"{s}\", \"message\": ", .{status}) catch fail("out of memory", .{});
    std.json.encodeJsonString(message.items, .{}, jw) catch fail("out of memory", .{});
    jw.writeAll("}}\n") catch fail("out of memory", .{});
    std.fs.cwd().writeFile(out_path, json.items) catch |err|
        fail("cannot write {s}: {s}", .{ out_path, @errorName(err) });
    if (r.findings > 0) std.debug.print("{s}", .{message.items});
}

test {
    _ = @import("budget.zig");
}
