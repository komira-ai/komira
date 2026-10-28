//! kind doc_links: a dead link is refused; links into another cell's tree,
//! placed at its path, resolve. Runs the pinned inspect (LINT_INSPECT).

const std = @import("std");
const fx = @import("fixture.zig");

test "doc_links: a link to a missing file is refused" {
    var f = try fx.Fixture.init();
    defer f.deinit();
    const inspect = try fx.tool(f.alloc(), "LINT_INSPECT");
    _ = try f.write("stage/README.md", "# Top\n\nSee [a](docs/a.md) and [gone](docs/gone.md).\n");
    _ = try f.write("stage/docs/a.md", "# A\n");
    const r = try f.run("doc_links", "stage", &.{inspect}, &.{ try f.path("stage"), "-" });
    try fx.expectFinding(r, "README.md:3: docs/gone.md (no such file)");
    try std.testing.expectEqual(@as(usize, 2), r.checked);
}

test "doc_links: a planted dead link in an unchecked file passes, and another cell's tree resolves" {
    var f = try fx.Fixture.init();
    defer f.deinit();
    const inspect = try fx.tool(f.alloc(), "LINT_INSPECT");
    _ = try f.write("stage/README.md", "# Top\n\n[tests](tools/tests/README.md#tests)\n");
    _ = try f.write("stage/dead.md", "[gone](gone.md)\n");
    _ = try f.write("cell/README.md", "# Tests\n");
    const r = try f.run("doc_links", "stage", &.{inspect}, &.{ try f.path("stage"), "dead.md", "tools/tests", try f.path("cell") });
    try fx.expectPass(r, 1);
}
