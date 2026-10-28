//! kind shellcheck: a planted warning is refused, naming its file, line and
//! code; an excluded code passes. Runs the pinned shellcheck (LINT_SHELLCHECK).

const std = @import("std");
const fx = @import("fixture.zig");
const tools = @import("tools.zig");

// An unused variable: SC2034, severity warning.
const planted = "#!/bin/sh\nunused=1\necho hi\n";

test "shellcheck: a planted warning is refused" {
    var f = try fx.Fixture.init();
    defer f.deinit();
    const sc = try fx.tool(f.alloc(), "LINT_SHELLCHECK");
    const s = try f.write("stage/run.sh", planted);
    const r = try f.run("shellcheck", "stage", &.{sc}, &.{ s, "-" });
    try fx.expectFinding(r, "run.sh:2:1: warning:");
    try fx.expectFinding(r, "[SC2034]");
    try std.testing.expect(std.mem.indexOf(u8, r.json, "test//run.sh:2:1: warning:") != null);
}

test "shellcheck: the code a file excludes passes, and clean files pass" {
    var f = try fx.Fixture.init();
    defer f.deinit();
    const sc = try fx.tool(f.alloc(), "LINT_SHELLCHECK");
    const s = try f.write("stage/run.sh", planted);
    const b = try f.write("stage/lib.sh", "# a sourced script, run as busybox sh\nx=$1\necho \"$x\"\n");
    try fx.expectPass(try f.run("shellcheck", "stage", &.{sc}, &.{ s, "SC2034", b, "-" }), 2);
}

test "shellcheck: a file with no shebang or directive is read as busybox" {
    try std.testing.expect(tools.namesShell("#!/bin/bash\n"));
    try std.testing.expect(tools.namesShell("# x\n# y\n# shellcheck shell=bash\n"));
    try std.testing.expect(!tools.namesShell("# x\n\n\n\n\n# shellcheck shell=bash\n"));
    try std.testing.expect(!tools.namesShell("echo #!/bin/sh\n"));
}
