//! Findings 1 to 3: the vocabulary against the grounding files. The fixture
//! is the planted plan of tests//functional/surface_capability_matrix
//! (fixture.bzl), cut down: each test plants one defect and requires exactly
//! its finding.

const std = @import("std");
const g = @import("grounding.zig");

const plan =
    \\# A planted plan.
    \\comptime PLAN_SCAN: UInt8 = 1
    \\comptime PLAN_FILTER: UInt8 = 2
    \\comptime PLAN_TAG_COUNT: Int = 3
    \\comptime PLAN_CSE_REF: UInt8 = 4
    \\    comptime PLAN_NESTED: UInt8 = 9
    \\comptime PLAN_UNTYPED = UInt8(16)
    \\comptime JOIN_LEFT: UInt8 = 1
    \\comptime SOURCE_CSV: UInt8 = 1
    \\
;
const udf = "comptime UDF_KIND_MAP: UInt8 = 1\ncomptime UDF_KIND_SPARE: UInt8 = 2\n";

const families = [_]g.Family{
    .{ .path = "src/plan/plan.mojo", .prefixes = &.{ "PLAN_", "JOIN_" }, .data = plan },
    .{ .path = "src/plan/udf.mojo", .prefixes = &.{}, .data = udf },
};

const named = [_]g.Named{
    .{ .what = "capability scan_csv", .id = "PLAN_SCAN" },
    .{ .what = "capability scan_csv", .id = "SOURCE_CSV" },
    .{ .what = "capability filter", .id = "PLAN_FILTER" },
    .{ .what = "capability join_left", .id = "JOIN_LEFT" },
    .{ .what = "capability udf_map", .id = "UDF_KIND_MAP" },
    .{ .what = "not_capabilities row 1", .id = "PLAN_CSE_REF" },
    .{ .what = "not_capabilities row 2", .id = "PLAN_UNTYPED" },
};

const Run = struct { findings: usize, report: []const u8 };

fn run(a: std.mem.Allocator, fams: []const g.Family, nams: []const g.Named) !Run {
    var out = std.ArrayList(u8).init(a);
    const n = try g.check(a, fams, nams, &out);
    return .{ .findings = n, .report = out.items };
}

fn only(r: Run, needle: []const u8) !void {
    if (r.findings != 1 or std.mem.indexOf(u8, r.report, needle) == null) {
        std.debug.print("want one finding holding `{s}`, got {d}:\n{s}\n", .{ needle, r.findings, r.report });
        return error.TestExpectedFinding;
    }
}

test "the planted plan, fully named, passes; a constant outside every family need not be named" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try run(arena.allocator(), &families, &named);
    try std.testing.expectEqualStrings("", r.report);
}

test "a grounding identifier no file declares is refused, naming who grounds on it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var nams = named;
    nams[4] = .{ .what = "capability udf_map", .id = "UDF_KIND_MAPX" };
    try only(try run(arena.allocator(), &families, &nams), "capability udf_map: grounding `UDF_KIND_MAPX` is declared by no grounding file (as comptime UDF_KIND_MAPX: UInt8)");
}

test "a name declared only with another type, or indented, grounds nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try only(try run(a, &families, &(named ++ [_]g.Named{.{ .what = "not_capabilities row 3", .id = "PLAN_TAG_COUNT" }})), "not_capabilities row 3: grounding `PLAN_TAG_COUNT` is declared by no grounding file");
    try only(try run(a, &families, &(named ++ [_]g.Named{.{ .what = "capability nested", .id = "PLAN_NESTED" }})), "capability nested: grounding `PLAN_NESTED`");
}

test "a family tag nothing names is refused, by file and line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Without not_capabilities row 1, PLAN_CSE_REF (line 5) is unclaimed.
    const nams = [_]g.Named{ named[0], named[1], named[2], named[3], named[4], named[6] };
    try only(try run(arena.allocator(), &families, &nams), "src/plan/plan.mojo:5: PLAN_CSE_REF is a plan constant that no capability and no not_capabilities row names");
}

test "the unannotated tag form is read: unnamed, PLAN_UNTYPED is unclaimed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try only(try run(arena.allocator(), &families, named[0..6]), "src/plan/plan.mojo:7: PLAN_UNTYPED is a plan constant");
}

test "a family constant in an unread form is refused, not skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fams = families;
    fams[0].data = plan ++ "comptime PLAN_ODD = 17\n";
    try only(try run(arena.allocator(), &fams, &named), "src/plan/plan.mojo:10: PLAN_ODD is a constant of a grounding family in a form this lint cannot read");
}

test "outside every family, an unread form is no finding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fams = families;
    fams[1].data = udf ++ "comptime UDF_ODD = 17\n";
    const r = try run(arena.allocator(), &fams, &named);
    try std.testing.expectEqualStrings("", r.report);
}
