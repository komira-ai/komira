//! kind retired_names: a retired name on an undated line is refused, in the
//! tree and in the extra files; a dated history note keeps it.

const std = @import("std");
const fx = @import("fixture.zig");

// The planted name, spelled in parts as the BUCK files spell theirs.
const old = "kci" ++ "_oldname";

test "retired_names: an undated line naming a retired name is refused" {
    var f = try fx.Fixture.init();
    defer f.deinit();
    _ = try f.write("tree/docs/a.md", "# A\n\nUse " ++ old ++ " here.\n");
    _ = try f.write("tree/docs/b.md", "nothing\n");
    const dot = try f.write("stage/.bazelrc", "x\n" ++ old ++ "\n");
    const r = try f.run("retired_names", "stage", &.{}, &.{ try f.path("tree"), "komira//", old, "--", dot });
    try fx.expectFinding(r, "komira//docs/a.md:3:Use " ++ old ++ " here. -- a retired name; only a dated history note may keep it");
    try fx.expectFinding(r, ".bazelrc:2:" ++ old);
    try std.testing.expectEqual(@as(usize, 3), r.checked);
}

test "retired_names: a dated history note keeps the name" {
    var f = try fx.Fixture.init();
    defer f.deinit();
    _ = try f.write("tree/docs/history.md", "2030-01-15: " ++ old ++ " became kci_new.\n");
    try fx.expectPass(try f.run("retired_names", "stage", &.{}, &.{ try f.path("tree"), "komira//", old, "other_old", "--" }), 1);
}

test "retired_names: an empty tree checks nothing, so fails" {
    var f = try fx.Fixture.init();
    defer f.deinit();
    try f.tmp.dir.makePath("tree/empty");
    const r = try f.run("retired_names", "stage", &.{}, &.{ try f.path("tree"), "komira//", old, "--" });
    try std.testing.expect(r.failed());
    try std.testing.expectEqual(@as(usize, 0), r.checked);
}
