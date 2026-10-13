//! kind actionlint: a planted workflow defect is refused; a clean workflow
//! passes. Runs the pinned actionlint and shellcheck (LINT_ACTIONLINT,
//! LINT_SHELLCHECK).

const std = @import("std");
const fx = @import("fixture.zig");

const config = "self-hosted-runner:\n  labels: [komira-linux]\n";
const clean =
    \\name: ci
    \\on: pull_request
    \\jobs:
    \\  check:
    \\    runs-on: komira-linux
    \\    steps:
    \\      - run: echo "ok"
    \\
;

fn tools(f: *fx.Fixture) ![3][]const u8 {
    return .{ try fx.tool(f.alloc(), "LINT_ACTIONLINT"), try fx.tool(f.alloc(), "LINT_SHELLCHECK"), try f.write("stage/actionlint.yaml", config) };
}

test "actionlint: a runner label the config does not name is refused" {
    var f = try fx.Fixture.init();
    defer f.deinit();
    const t = try tools(&f);
    const wf = try f.write("stage/ci.yml", try std.mem.replaceOwned(u8, f.alloc(), clean, "komira-linux", "komira-gpu"));
    const r = try f.run("actionlint", "stage", &t, &.{wf});
    try fx.expectFinding(r, "ci.yml:5:");
    try fx.expectFinding(r, "komira-gpu");
}

test "actionlint: shellcheck reads the run steps" {
    var f = try fx.Fixture.init();
    defer f.deinit();
    const t = try tools(&f);
    const wf = try f.write("stage/ci.yml", try std.mem.replaceOwned(u8, f.alloc(), clean, "echo \"ok\"", "echo $1"));
    try fx.expectFinding(try f.run("actionlint", "stage", &t, &.{wf}), "SC2086");
}

test "actionlint: a clean workflow passes" {
    var f = try fx.Fixture.init();
    defer f.deinit();
    const t = try tools(&f);
    const wf = try f.write("stage/ci.yml", clean);
    try fx.expectPass(try f.run("actionlint", "stage", &t, &.{wf}), 1);
}
