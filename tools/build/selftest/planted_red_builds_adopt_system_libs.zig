//! planted_red_builds_adopt_system_libs: the negatives of the pinned system libraries of a package adopted by `mojo_adopted_library`
//! (tools/build/mojo/system_libs.bzl), over tests//negative/adopt_system_libs. `codec` opens SQLite by its bare name (a farm worker has no libsqlite3); `:adopted`
//! adopts a `:lib` that exports the pinned libsqlite and libzlib, and `-c adopt_system_libs.case=unpinned` adds the `_unpinned` twins over a `:lib` that forgot its
//! pins. The positives are ordinary targets of the package (its BUCK file lists them: the welded test, the kcov and branch runs, a `mojo_test`, a shared library's
//! driver) and need no scenario. Two checks here, the cheapest that hold the wiring on a red build:
//!
//!   - the welded test of `consumer_unpinned` fails in its action on the farm with the loader's refusal, `dlopen failed: libsqlite3.so.0: cannot open shared object
//!     file`. Catches a host that supplies the library (the pinned twin would pass for the wrong reason), and a control that never ran the test;
//!   - the `mojo_test` `program_test_unpinned` fails under `buck2 test` with the same refusal.
//!
//! The coverage runs and the shared library are not asserted red here (that needs a coverage build in a cold daemon): their wiring is held by the positive targets
//! building, which they can only do with the libraries.
const std = @import("std");
const lib = @import("lib/lib.zig");

const T = "tests//negative/adopt_system_libs:";
const WHY = "dlopen failed: libsqlite3.so.0: cannot open shared object file";
const UNPINNED = &.{"adopt_system_libs.case=unpinned"};

const REDS = [_]lib.Row{
    .{ .name = "welded_test_without_the_pins", .target = T ++ "consumer_unpinned", .text = WHY, .cfg = UNPINNED },
};

fn testRun(c: *lib.Ctx) !void {
    const target = T ++ "program_test_unpinned";
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
    try c.reds(&REDS);
    try testRun(c);
}

pub fn main() u8 {
    return lib.main(body);
}
