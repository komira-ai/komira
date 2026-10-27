//! The lint kinds that run a pinned tool and report what it prints:
//! shellcheck, actionlint and doc_links.

const std = @import("std");
const lint = @import("lint.zig");
const Ctx = lint.Ctx;

/// Whether shellcheck reads the file's shell from the file itself: a `#!`
/// first line, or a `# shellcheck shell=` directive in its first five lines.
pub fn namesShell(text: []const u8) bool {
    var lines = lint.Lines.init(text);
    while (lines.next()) |line| {
        if (lines.n == 1 and std.mem.startsWith(u8, line, "#!")) return true;
        if (std.mem.startsWith(u8, line, "# shellcheck shell=")) return true;
        if (lines.n == 5) break;
    }
    return false;
}

/// kind shellcheck, tools <shellcheck>, args <file> <codes>...: every file
/// passes shellcheck at severity warning. A file with a shebang is checked as
/// its shebang says; one without that names its shell in a
/// `# shellcheck shell=` directive, as that shell; any other, which the rules
/// run as `busybox sh <file>`, as busybox. <codes> is `-` or the
/// comma-separated codes excluded for that file.
pub fn shellcheck(c: *Ctx, tools: []const []const u8, args: []const []const u8) !void {
    if (tools.len != 1 or args.len % 2 != 0) return error.Usage;
    const sc = try c.abs(tools[0]);
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        const f = args[i];
        const codes = args[i + 1];
        c.checked += 1;
        var argv = std.ArrayList([]const u8).empty;
        try argv.appendSlice(c.alloc, &.{ sc, "-S", "warning", "-f", "gcc" });
        if (!std.mem.eql(u8, codes, "-")) try argv.appendSlice(c.alloc, &.{ "-e", codes });
        if (!namesShell(try lint.readFile(c.alloc, f))) try argv.appendSlice(c.alloc, &.{ "-s", "busybox" });
        try argv.append(c.alloc, f);
        const r = try lint.runTool(c.alloc, argv.items, null);
        try c.appendOutput(r.stdout);
        try c.appendOutput(r.stderr);
    }
}

/// kind actionlint, tools <actionlint> <shellcheck> <config>, args
/// <workflow>...: the workflows pass actionlint (configured by <config>),
/// with shellcheck over their `run:` steps.
pub fn actionlint(c: *Ctx, tools: []const []const u8, args: []const []const u8) !void {
    if (tools.len != 3) return error.Usage;
    c.checked = args.len;
    var argv = std.ArrayList([]const u8).empty;
    try argv.appendSlice(c.alloc, &.{ try c.abs(tools[0]), "-no-color", "-config-file", tools[2], "-shellcheck", try c.abs(tools[1]) });
    try argv.appendSlice(c.alloc, args);
    const r = try lint.runTool(c.alloc, argv.items, null);
    try c.appendOutput(r.stdout);
    try c.appendOutput(r.stderr);
}

/// The number after `head` up to `tail` on some line of `out`, or null.
fn countAfter(out: []const u8, head: []const u8, tail: []const u8) ?usize {
    var lines = lint.Lines.init(out);
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, head)) continue;
        const rest = line[head.len..];
        var e: usize = 0;
        while (e < rest.len and std.ascii.isDigit(rest[e])) e += 1;
        if (e == 0 or !std.mem.startsWith(u8, rest[e..], tail)) continue;
        return std.fmt.parseInt(usize, rest[0..e], 10) catch null;
    }
    return null;
}

/// kind doc_links, tools <inspect runnable dir>, args <tree> <unchecked>
/// [<path> <tree>]...: every relative link and #anchor in every .md file
/// under <tree> resolves to a file, directory or heading under <tree>, with
/// each further tree (another cell's) placed at its <path>. <unchecked> is
/// `-` or a comma-separated list of .md paths left out (planted dead links).
/// The reader is `inspect doc-links` (tools/build/inspect).
pub fn docLinks(c: *Ctx, tools: []const []const u8, args: []const []const u8) !void {
    if (tools.len != 1 or args.len < 2 or args.len % 2 != 0) return error.Usage;
    const inspect = try std.fs.path.join(c.alloc, &.{ try c.abs(tools[0]), "inspect" });
    var tree: []const u8 = try std.fs.cwd().realpathAlloc(c.alloc, args[0]);
    var skip = std.StringHashMap(void).init(c.alloc);
    var it = std.mem.splitScalar(u8, args[1], ',');
    while (it.next()) |u| try skip.put(u, {});
    if (args.len > 2) {
        // Other cells' trees, each at its path: merge them into one copy.
        const merged = try c.scratchPath("merged");
        try lint.copyTree(c.alloc, tree, merged);
        var i: usize = 2;
        while (i < args.len) : (i += 2) {
            try lint.copyTree(c.alloc, args[i + 1], try std.fs.path.join(c.alloc, &.{ merged, args[i] }));
        }
        tree = merged;
    }
    // Every file staged under the tree, as `git ls-files -z` lists a
    // checkout: the Markdown reader checks each .md among them.
    var list = std.ArrayList(u8).empty;
    for (try lint.listFiles(c.alloc, tree)) |p| {
        if (skip.contains(p)) continue;
        try list.appendSlice(c.alloc, p);
        try list.append(c.alloc, 0);
    }
    const list_path = try c.scratchPath("tree.list");
    try std.fs.cwd().writeFile(.{ .sub_path = list_path, .data = list.items });

    const r = try lint.runTool(c.alloc, &.{ inspect, "doc-links", tree, list_path }, null);
    const out = try std.mem.concat(c.alloc, u8, &.{ r.stdout, r.stderr });
    if (r.code == 0) {
        c.checked = countAfter(out, "PASS  doc links: all ", " relative links resolve") orelse 0;
        return;
    }
    // `FAIL  doc links: <bad> of <all> ...`: the number checked is <all>.
    var lines = lint.Lines.init(out);
    while (lines.next()) |line| {
        const head = "FAIL  doc links: ";
        if (!std.mem.startsWith(u8, line, head)) continue;
        const of = std.mem.indexOf(u8, line, " of ") orelse continue;
        c.checked = countAfter(line[of..], " of ", " ") orelse 0;
        break;
    }
    const before = c.report.items.len;
    lines = lint.Lines.init(out);
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "PASS")) try c.finding("{s}", .{line});
    }
    if (c.report.items.len == before) try c.finding("inspect doc-links failed without a finding", .{});
}
