//! limits_check: the limits of the build against their sites and against
//! the merged PRs (limits.zig says what each mode checks).
//!
//! usage: limits_check tree --tree <dir> --limits <path in the tree>
//!            [--exclude <path, or directory ending in />]... --out <file>
//!        limits_check merged --limits <file> --subjects <file>
//!
//! `tree` reads every file of <dir> (the repository's files at their paths)
//! and writes <file>, the validation result Buck2 reads: status "failure"
//! with the findings as the message, else "success" with the count of
//! limits. `merged` reads the commit subjects of the main branch, one per
//! line, and prints the findings, or a PASS line.
//!
//! Exit status: tree: 0 the result is written (either status), 1 a file
//! cannot be read or written; merged: 0 no finding, 1 a finding or a file
//! cannot be read; 2 bad usage.
//!
//! A static executable: it runs with no shell, no PATH and no network.

const std = @import("std");
const limits = @import("limits.zig");

const usage =
    \\usage: limits_check tree --tree <dir> --limits <path in the tree> [--exclude <path or dir/>]... --out <file>
    \\       limits_check merged --limits <file> --subjects <file>
    \\
;

fn usageFail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("limits_check: " ++ fmt ++ "\n" ++ usage, args);
    std.process.exit(2);
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("limits_check: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn main() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const argv = std.process.argsAlloc(alloc) catch fail("out of memory", .{});
    if (argv.len < 2) usageFail("a mode is required", .{});
    const mode = argv[1];

    var tree: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var subjects: ?[]const u8 = null;
    var excludes = std.ArrayList([]const u8).init(alloc);
    var i: usize = 2;
    while (i < argv.len) : (i += 2) {
        if (i + 1 >= argv.len) usageFail("{s} needs a value", .{argv[i]});
        const v = argv[i + 1];
        if (std.mem.eql(u8, argv[i], "--tree")) {
            tree = v;
        } else if (std.mem.eql(u8, argv[i], "--limits")) {
            name = v;
        } else if (std.mem.eql(u8, argv[i], "--exclude")) {
            excludes.append(v) catch fail("out of memory", .{});
        } else if (std.mem.eql(u8, argv[i], "--out")) {
            out = v;
        } else if (std.mem.eql(u8, argv[i], "--subjects")) {
            subjects = v;
        } else usageFail("unknown argument {s}", .{argv[i]});
    }
    const limits_name = name orelse usageFail("--limits is required", .{});
    var report = std.ArrayList(u8).init(alloc);

    if (std.mem.eql(u8, mode, "merged")) {
        const subjects_path = subjects orelse usageFail("merged: --subjects is required", .{});
        if (tree != null or out != null or excludes.items.len > 0) usageFail("merged takes only --limits and --subjects", .{});
        const text = std.fs.cwd().readFileAlloc(alloc, limits_name, 1 << 24) catch |err|
            fail("cannot read {s}: {s}", .{ limits_name, @errorName(err) });
        const subj = std.fs.cwd().readFileAlloc(alloc, subjects_path, 1 << 30) catch |err|
            fail("cannot read {s}: {s}", .{ subjects_path, @errorName(err) });
        const r = limits.checkMerged(alloc, limits_name, text, subj, &report) catch fail("out of memory", .{});
        if (r.findings > 0) {
            std.io.getStdOut().writer().print("FAIL  limits: {d} finding(s)\n{s}", .{ r.findings, report.items }) catch {};
            std.process.exit(1);
        }
        std.io.getStdOut().writer().print("PASS  limits: no retiring PR of the {d} limits of {s} has merged\n", .{ r.limits, limits_name }) catch {};
        return;
    }
    if (!std.mem.eql(u8, mode, "tree")) usageFail("unknown mode {s}", .{mode});
    if (subjects != null) usageFail("tree takes no --subjects", .{});
    const tree_path = tree orelse usageFail("tree: --tree is required", .{});
    const out_path = out orelse usageFail("tree: --out is required", .{});

    var dir = std.fs.cwd().openDir(tree_path, .{ .iterate = true }) catch |err|
        fail("cannot open the tree {s}: {s}", .{ tree_path, @errorName(err) });
    defer dir.close();
    const text = dir.readFileAlloc(alloc, limits_name, 1 << 24) catch |err|
        fail("cannot read {s} in the tree: {s}", .{ limits_name, @errorName(err) });
    // The limits file is data, not a site.
    excludes.append(limits_name) catch fail("out of memory", .{});
    const files = limits.collect(alloc, dir, excludes.items) catch |err|
        fail("cannot read the tree {s}: {s}", .{ tree_path, @errorName(err) });
    const r = limits.checkTree(alloc, limits_name, text, files, &report) catch fail("out of memory", .{});

    var message = std.ArrayList(u8).init(alloc);
    const status = if (r.findings > 0) "failure" else "success";
    if (r.findings > 0) {
        message.writer().print("limits: {d} finding(s) over {d} file(s)\n{s}", .{ r.findings, files.len, report.items }) catch fail("out of memory", .{});
    } else {
        message.writer().print("limits: {d} limits, each declared at its site and listed in {s}, over {d} file(s)", .{ r.limits, limits_name, files.len }) catch fail("out of memory", .{});
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
