//! graph_checks: the checkers of the graph checks (checks.bxl).
//!
//! usage: graph_checks --check <name> --cell <cell> --label <target> --facts <file> [--scan <dir>] --out <file>
//!
//! Reads the facts checks.bxl collected for the check and writes <out> only
//! when they hold; otherwise prints each finding and exits 1. A check that
//! read no fact fails too: it checked nothing.
//!
//! The python_closure check also takes --scan <dir>: the files its facts
//! name as `scan`, at their paths in the repository.
//!
//!   selftest_closure  the facts are labels, one per line: the closure of
//!                     the self-test package. A label of <cell> under src/
//!                     is a finding, because a library there would put
//!                     every scenario in the reverse dependencies of a
//!                     change to that library (docs/design/build_selftests.md,
//!                     "Only a widened change reaches build_selftests").
//!   python_closure    no Python outside the Python surface: python_closure.zig.
const std = @import("std");
const python_closure = @import("python_closure.zig");

pub const Outcome = struct {
    facts: usize,
    findings: []const []const u8,
};

/// The labels of `facts` that are of `cell` under src/.
pub fn selftestClosure(a: std.mem.Allocator, cell: []const u8, facts: []const u8) !Outcome {
    const prefix = try std.fmt.allocPrint(a, "{s}//src/", .{cell});
    const exact = try std.fmt.allocPrint(a, "{s}//src:", .{cell});
    var findings = std.ArrayList([]const u8).init(a);
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, facts, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        n += 1;
        if (std.mem.startsWith(u8, line, prefix) or std.mem.startsWith(u8, line, exact)) try findings.append(line);
    }
    return .{ .facts = n, .findings = try findings.toOwnedSlice() };
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.io.getStdErr().writer().print("graph_checks: " ++ fmt ++ "\n", args) catch {};
    std.process.exit(1);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    var check: ?[]const u8 = null;
    var cell: ?[]const u8 = null;
    var label: ?[]const u8 = null;
    var facts_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var scan_dir: ?[]const u8 = null;
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        const k = args[i];
        const v = args[i + 1];
        if (std.mem.eql(u8, k, "--check")) check = v else if (std.mem.eql(u8, k, "--cell")) cell = v else if (std.mem.eql(u8, k, "--label")) label = v else if (std.mem.eql(u8, k, "--facts")) facts_path = v else if (std.mem.eql(u8, k, "--out")) out_path = v else if (std.mem.eql(u8, k, "--scan")) scan_dir = v else fail("unknown argument {s}", .{k});
    }
    if (i != args.len or check == null or cell == null or label == null or facts_path == null or out_path == null)
        fail("usage: graph_checks --check <name> --cell <cell> --label <target> --facts <file> [--scan <dir>] --out <file>", .{});
    const facts = std.fs.cwd().readFileAlloc(a, facts_path.?, 1 << 28) catch |e| fail("cannot read {s}: {s}", .{ facts_path.?, @errorName(e) });
    if (std.mem.eql(u8, check.?, "python_closure")) return pythonClosureMain(a, cell.?, label.?, facts, scan_dir, out_path.?);
    if (!std.mem.eql(u8, check.?, "selftest_closure")) fail("{s}: no checker for the check `{s}`", .{ label.?, check.? });
    const o = try selftestClosure(a, cell.?, facts);
    if (o.facts == 0) fail("{s}: selftest_closure read no label: the closure query matched nothing, so it checked nothing", .{label.?});
    if (o.findings.len > 0) {
        const w = std.io.getStdErr().writer();
        for (o.findings) |f| try w.print("{s}: selftest_closure: {s} is in the closure of the self-test package; a scenario names what it builds as a string, never as a dependency\n", .{ label.?, f });
        fail("{s}: selftest_closure: {d} of {d} labels are of {s}//src/", .{ label.?, o.findings.len, o.facts, cell.? });
    }
    const f = std.fs.cwd().createFile(out_path.?, .{}) catch |e| fail("cannot create {s}: {s}", .{ out_path.?, @errorName(e) });
    defer f.close();
    try f.writer().print("selftest_closure: {d} labels, none under {s}//src/\n", .{ o.facts, cell.? });
}

fn pythonClosureMain(a: std.mem.Allocator, cell: []const u8, label: []const u8, facts: []const u8, scan_dir: ?[]const u8, out_path: []const u8) !void {
    // The files the facts name as `scan`, read from --scan.
    var texts = std.StringHashMap([]const u8).init(a);
    var it = std.mem.splitScalar(u8, facts, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "scan\t")) continue;
        const path = line["scan\t".len..];
        const dir = scan_dir orelse fail("{s}: python_closure: the facts name files to read ({s}) and no --scan directory was given", .{ label, path });
        const full = try std.fs.path.join(a, &.{ dir, path });
        const text = std.fs.cwd().readFileAlloc(a, full, 1 << 26) catch |e| fail("{s}: python_closure: cannot read {s}: {s}", .{ label, full, @errorName(e) });
        try texts.put(path, text);
    }
    const o = try python_closure.pythonClosure(a, cell, facts, &texts);
    if (o.nodes == 0) fail("{s}: python_closure read no target: the closure query matched nothing, so it checked nothing", .{label});
    if (o.refused.len > 0) {
        const w = std.io.getStdErr().writer();
        for (o.refused) |r| try w.print("{s}: python_closure: {s}\n", .{ label, r });
        fail("{s}: python_closure: {d} refused ({d} targets, {d} files, {d} files read; {d} findings allowed by the surface and the ceiling)", .{ label, o.refused.len, o.nodes, o.files, o.scanned, o.allowed });
    }
    const f = std.fs.cwd().createFile(out_path, .{}) catch |e| fail("cannot create {s}: {s}", .{ out_path, @errorName(e) });
    defer f.close();
    try f.writer().print("python_closure: {d} targets, {d} files, {d} files read; no Python outside the allowlist ({d} findings allowed)\n", .{ o.nodes, o.files, o.scanned, o.allowed });
}

test {
    _ = python_closure;
}

test "a closure with no label under src/ holds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const o = try selftestClosure(arena.allocator(), "komira", "komira//tools/build/selftest:lib\ntoolchains//:mojo\nkomira//tools/build/toolchains:zig\n");
    try std.testing.expectEqual(@as(usize, 3), o.facts);
    try std.testing.expectEqual(@as(usize, 0), o.findings.len);
}

test "a library under src/ in the closure is a finding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const o = try selftestClosure(arena.allocator(), "komira", "komira//tools/build/selftest:lib\nkomira//src/komira_clock:komira_clock\nkomira//src:x\n");
    try std.testing.expectEqual(@as(usize, 3), o.facts);
    try std.testing.expectEqual(@as(usize, 2), o.findings.len);
    try std.testing.expectEqualStrings("komira//src/komira_clock:komira_clock", o.findings[0]);
}

test "only the check's own cell counts, and only a src/ segment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const o = try selftestClosure(arena.allocator(), "komira", "tests//src/tests/coverage:x\nkomira//srcs/x:y\nkomira//tools/src/x:y\n");
    try std.testing.expectEqual(@as(usize, 0), o.findings.len);
    const p = try selftestClosure(arena.allocator(), "internal", "internal//src/x:x\nkomira//src/y:y\n");
    try std.testing.expectEqual(@as(usize, 1), p.findings.len);
}

test "no fact is counted as none read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try selftestClosure(arena.allocator(), "komira", "\n\n")).facts);
}
