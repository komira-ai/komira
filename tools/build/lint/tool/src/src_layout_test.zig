//! kind src_layout: a test-only package outside src/tests, an unshipped
//! test library, and a module map out of step with the packages are refused.

const std = @import("std");
const fx = @import("fixture.zig");

const map =
    \\# Architecture
    \\
    \\| [`komira_a`](../src/komira_a/) | a |
    \\| [`komira_test_kit`](../src/komira_test_kit) | the shipped kit |
    \\| [`komira_x_e2e`](../src/tests/e2e/komira_x_e2e/) | e2e |
    \\
;

test "src_layout: a clean layout and map pass" {
    var f = try fx.Fixture.init();
    defer f.deinit();
    const m = try f.write("stage/docs/architecture.md", map);
    const r = try f.run("src_layout", "stage", &.{}, &.{ "src", "komira_test_kit", "komira//", m, "src/komira_a", "src/komira_test_kit", "src/tests/e2e/komira_x_e2e", "tools/other" });
    try fx.expectPass(r, 3);
}

test "src_layout: an e2e package directly under src/ is refused" {
    var f = try fx.Fixture.init();
    defer f.deinit();
    const r = try f.run("src_layout", "stage", &.{}, &.{ "src", "-", "komira//", "-", "src/komira_a", "src/komira_foo_e2e" });
    try fx.expectFinding(r, "komira//src/komira_foo_e2e: a test-only package directly under src/, which holds what komira ships; move it to src/tests/e2e/komira_foo_e2e");
}

test "src_layout: misplaced and unshipped packages are refused" {
    var f = try fx.Fixture.init();
    defer f.deinit();
    const r = try f.run("src_layout", "stage", &.{}, &.{ "src", "komira_test_gone", "komira//", "-", "src/komira_test_kit", "src/tests/helpers/komira_w_e2e", "src/tests/bench/komira_y", "src/komira_a/inner" });
    try fx.expectFinding(r, "komira//src/komira_test_kit: a test library directly under src/ that `shipped` does not name");
    try fx.expectFinding(r, "this one belongs in src/tests/e2e/komira_w_e2e");
    try fx.expectFinding(r, "komira//src/tests/bench/komira_y: src/tests holds packages only at src/tests/<kind>/<name>");
    try fx.expectFinding(r, "komira//src/komira_a/inner: a package is src/<name>");
    try fx.expectFinding(r, "shipped names komira_test_gone, which is no package directly under src/; delete it");
}

test "src_layout: a package with no row, a stale, second or misnamed row are refused" {
    var f = try fx.Fixture.init();
    defer f.deinit();
    const m = try f.write("stage/map.md", map ++ "| [`komira_b`](../src/komira_a) | again |\n");
    const r = try f.run("src_layout", "stage", &.{}, &.{ "src", "komira_test_kit", "komira//", m, "src/komira_test_kit", "src/tests/e2e/komira_x_e2e", "src/komira_new" });
    try fx.expectFinding(r, "komira//src/komira_new: no row in");
    try fx.expectFinding(r, "map.md:3: a row for src/komira_a, which is no package");
    try fx.expectFinding(r, "map.md:6: a second row for src/komira_a (the first is line 3)");
    const m2 = try f.write("stage/map2.md", "| [`komira_b`](src/komira_a) |\n");
    try fx.expectFinding(try f.run("src_layout", "stage", &.{}, &.{ "src", "-", "komira//", m2, "src/komira_a" }), "map2.md:1: the row names komira_b but links src/komira_a; name it komira_a");
}

test "src_layout: no package under src checks nothing, so fails" {
    var f = try fx.Fixture.init();
    defer f.deinit();
    const r = try f.run("src_layout", "stage", &.{}, &.{ "src", "-", "komira//", "-", "tools/x" });
    try std.testing.expect(r.failed());
}
