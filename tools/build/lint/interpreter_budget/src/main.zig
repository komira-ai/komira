//! interpreter_budget: the interpreter list's validation (budget.zig says
//! what it checks).
//!
//! usage: interpreter_budget --tree <dir> --allowlist <path in the tree>
//!            [--scope <path prefix>]... [--expect <text>]... --out <file>
//!
//! Reads every file of <dir> (the repository's files at their paths) and the
//! allowlist at <path in the tree>, and writes <file>, the validation result
//! Buck2 reads: status "failure" with the findings as the message when there
//! are any, "success" with the number of interpreter files checked otherwise.
//! Each `--scope` limits the check to paths starting with it (none: the whole
//! tree). With `--expect`, the verdict is inverted for a planted defect: the
//! status is "success" only when there are findings and the report holds
//! every expected text.
//!
//! Exit status: 0 the result is written (either status); 1 the tree or the
//! allowlist cannot be read, or the result cannot be written; 2 bad usage.
//!
//! A static executable: it runs with no shell, no PATH and no network.

const std = @import("std");
const budget = @import("budget.zig");

const usage = "usage: interpreter_budget --tree <dir> --allowlist <path in the tree> [--scope <path prefix>]... [--expect <text>]... --out <file>\n";

fn usageFail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("interpreter_budget: " ++ fmt ++ "\n" ++ usage, args);
    std.process.exit(2);
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("interpreter_budget: " ++ fmt ++ "\n", args);
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
    var scope = std.ArrayList([]const u8).init(alloc);
    var expect = std.ArrayList([]const u8).init(alloc);
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
        } else if (std.mem.eql(u8, argv[i], "--scope")) {
            if (v.len == 0) usageFail("--scope needs a non-empty path prefix", .{});
            scope.append(v) catch fail("out of memory", .{});
        } else if (std.mem.eql(u8, argv[i], "--expect")) {
            if (v.len == 0) usageFail("--expect needs a non-empty text", .{});
            expect.append(v) catch fail("out of memory", .{});
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
    const found = budget.collect(alloc, dir, scope.items) catch |err|
        fail("cannot read the tree {s}: {s}", .{ tree_path, @errorName(err) });

    var report = std.ArrayList(u8).init(alloc);
    const r = budget.check(alloc, name, text, scope.items, found, &report) catch fail("out of memory", .{});
    const v = budget.verdict(r, report.items, expect.items);

    var message = std.ArrayList(u8).init(alloc);
    const mw = message.writer();
    const status = if (v.ok) "success" else "failure";
    (if (expect.items.len > 0) blk: {
        if (v.missing) |m| {
            break :blk mw.print("interpreter_budget: the planted defect was not refused as expected: no finding holds `{s}`; {d} finding(s):\n{s}", .{ m, r.findings, report.items });
        }
        if (!v.ok) break :blk mw.print("interpreter_budget: the planted defect was not refused: no finding over {d} interpreter file(s)", .{r.files});
        break :blk mw.print("interpreter_budget: the planted defect was refused as expected ({d} finding(s)):\n{s}", .{ r.findings, report.items });
    } else if (r.findings > 0)
        mw.print("interpreter_budget: {d} finding(s) over {d} interpreter file(s)\n{s}", .{ r.findings, r.files, report.items })
    else
        mw.print("interpreter_budget: {d} interpreter file(s) checked against {s}", .{ r.files, name })) catch fail("out of memory", .{});
    var json = std.ArrayList(u8).init(alloc);
    const jw = json.writer();
    jw.print("{{\"version\": 1, \"data\": {{\"status\": \"{s}\", \"message\": ", .{status}) catch fail("out of memory", .{});
    std.json.encodeJsonString(message.items, .{}, jw) catch fail("out of memory", .{});
    jw.writeAll("}}\n") catch fail("out of memory", .{});
    std.fs.cwd().writeFile(out_path, json.items) catch |err|
        fail("cannot write {s}: {s}", .{ out_path, @errorName(err) });
    if (!v.ok) std.debug.print("{s}", .{message.items});
}

test {
    _ = @import("budget.zig");
}
