//! planted_red_builds_adopt_system_libs: the pinned system libraries of a package adopted by `mojo_adopted_library` reach every test run of an old-rule dependent
//! (tools/build/mojo/system_libs.bzl). The fixture is tests//negative/adopt_system_libs: `codec` opens SQLite by its bare name (a farm worker has no libsqlite3),
//! `:adopted` adopts a `:lib` that exports the directories of the pinned libsqlite and libzlib (`-c adopt_system_libs.case=pinned`) or none
//! (`unpinned`, a package whose `:lib` forgot its pins), and `consumer`, a `mojo_library` with a welded test that calls the codec, depends on it. Checks:
//!
//!   - with the pins, the welded test builds and passes, so do its kcov run (`[coverage][tests]`) and its branch run (`[coverage][branch]`, under
//!     `-c komira.coverage=true`), and a `mojo_test` that depends on the adopted label passes under `buck2 test`;
//!   - without them, each of those runs fails in its action on the farm with the loader's refusal, `dlopen failed: libsqlite3.so.0: cannot open shared object file`.
//!     Catches a run (welded, kcov, branch, `mojo_test`) that is not given `--lib-dir`, a gate that does not put the directories on the library path, a label that does not
//!     hand them on, and the host supplying the library (the unpinned runs would pass).
const std = @import("std");
const lib = @import("lib/lib.zig");

const T = "tests//negative/adopt_system_libs:";
const WHY = "dlopen failed: libsqlite3.so.0: cannot open shared object file";
const UNPINNED = &.{"adopt_system_libs.case=unpinned"};
const PINNED = &.{"adopt_system_libs.case=pinned"};
const COVERAGE_UNPINNED = &.{ "adopt_system_libs.case=unpinned", "komira.coverage=true" };
const COVERAGE_PINNED = &.{ "adopt_system_libs.case=pinned", "komira.coverage=true" };

const REDS = [_]lib.Row{
    .{ .name = "welded_test_without_the_pins", .target = T ++ "consumer", .text = WHY, .cfg = UNPINNED },
    .{ .name = "kcov_run_without_the_pins", .target = T ++ "consumer[coverage][tests]", .text = WHY, .cfg = COVERAGE_UNPINNED },
    .{ .name = "branch_run_without_the_pins", .target = T ++ "consumer[coverage][branch]", .text = WHY, .cfg = COVERAGE_UNPINNED },
};

const GREENS = [_]struct { name: []const u8, target: []const u8, cfg: []const []const u8 }{
    .{ .name = "welded_test_with_the_pins", .target = T ++ "consumer", .cfg = PINNED },
    .{ .name = "kcov_run_with_the_pins", .target = T ++ "consumer[coverage][tests]", .cfg = COVERAGE_PINNED },
    .{ .name = "branch_run_with_the_pins", .target = T ++ "consumer[coverage][branch]", .cfg = COVERAGE_PINNED },
};

fn builds(c: *lib.Ctx, name: []const u8, target: []const u8, cfg: []const []const u8) !void {
    const r = try c.run(&.{ "build", target }, .{ .cfg = cfg });
    if (r.ok()) {
        c.pass("{s}: {s} builds", .{ name, target });
    } else {
        c.fail("{s}: {s} failed (see {s}); its last lines:\n{s}", .{ name, target, r.log, r.stderr[r.stderr.len -| 800..] });
    }
}

/// `buck2 test` of the `mojo_test`: it passes with the pins, and without them fails with the loader's refusal.
fn testRun(c: *lib.Ctx) !void {
    const target = T ++ "program_test";
    const green = try c.run(&.{ "test", target }, .{ .cfg = PINNED });
    if (green.ok()) {
        c.pass("mojo_test_with_the_pins: {s} passes under buck2 test", .{target});
    } else {
        c.fail("mojo_test_with_the_pins: {s} failed (see {s}); its last lines:\n{s}", .{ target, green.log, green.stderr[green.stderr.len -| 800..] });
    }
    const red = try c.run(&.{ "test", target }, .{ .cfg = UNPINNED });
    const out = try std.mem.concat(c.a, u8, &.{ red.stdout, red.stderr });
    if (red.ok()) {
        c.fail("mojo_test_without_the_pins: {s} passed, but nothing gave its run the library (see {s})", .{ target, red.log });
    } else if (std.mem.indexOf(u8, out, WHY) == null) {
        c.fail("mojo_test_without_the_pins: {s} failed without `{s}` (see {s})", .{ target, WHY, red.log });
    } else {
        c.pass("mojo_test_without_the_pins: {s} fails: {s}", .{ target, WHY });
    }
}

fn body(c: *lib.Ctx) !void {
    for (GREENS) |g| try builds(c, g.name, g.target, g.cfg);
    try c.reds(&REDS);
    try testRun(c);
}

pub fn main() u8 {
    return lib.main(body);
}
