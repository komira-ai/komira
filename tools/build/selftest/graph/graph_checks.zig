//! graph_checks: the checkers of the graph checks (checks.bxl).
//!
//! usage: graph_checks --check <name> --cell <cell> --label <target> --facts <file> --out <file>
//!
//! Reads the facts checks.bxl collected for the check and writes <out> only
//! when they hold; otherwise prints each finding and exits 1. A check that
//! read no fact fails too: it checked nothing.
//!
//!   selftest_closure  the facts are labels, one per line: the closure of
//!                     the self-test package. A label of <cell> under src/
//!                     is a finding, because a library there would put
//!                     every scenario in the reverse dependencies of a
//!                     change to that library (docs/design/build_selftests.md,
//!                     "Only a widened change reaches build_selftests").
const std = @import("std");

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
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        const k = args[i];
        const v = args[i + 1];
        if (std.mem.eql(u8, k, "--check")) check = v else if (std.mem.eql(u8, k, "--cell")) cell = v else if (std.mem.eql(u8, k, "--label")) label = v else if (std.mem.eql(u8, k, "--facts")) facts_path = v else if (std.mem.eql(u8, k, "--out")) out_path = v else fail("unknown argument {s}", .{k});
    }
    if (i != args.len or check == null or cell == null or label == null or facts_path == null or out_path == null)
        fail("usage: graph_checks --check <name> --cell <cell> --label <target> --facts <file> --out <file>", .{});
    const facts = std.fs.cwd().readFileAlloc(a, facts_path.?, 1 << 28) catch |e| fail("cannot read {s}: {s}", .{ facts_path.?, @errorName(e) });
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
