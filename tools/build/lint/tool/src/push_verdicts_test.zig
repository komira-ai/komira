//! kind push_verdicts: a push-triggered workflow whose concurrency group
//! does not name github.sha is refused.

const std = @import("std");
const fx = @import("fixture.zig");

test "push_verdicts: a push workflow grouped by ref is refused, naming the group's line" {
    var f = try fx.Fixture.init();
    defer f.deinit();
    const wf = try f.write("stage/main.yml", "on:\n  push:\n    branches: [main]\nconcurrency:\n  group: main-${{ github.ref }}\n  cancel-in-progress: false\njobs: {}\n");
    const r = try f.run("push_verdicts", "stage", &.{}, &.{wf});
    try fx.expectFinding(r, "main.yml:5: the concurrency group of a push-triggered workflow does not name github.sha");
    try std.testing.expectEqual(@as(usize, 1), r.checked);
}

test "push_verdicts: a one-line group and a list trigger are read" {
    var f = try fx.Fixture.init();
    defer f.deinit();
    const wf = try f.write("stage/a.yml", "\"on\": [pull_request, push]\nconcurrency: ci-${{ github.ref }}\n");
    try fx.expectFinding(try f.run("push_verdicts", "stage", &.{}, &.{wf}), "a.yml:2: the concurrency group");
}

test "push_verdicts: a group naming github.sha, and no group, pass" {
    var f = try fx.Fixture.init();
    defer f.deinit();
    const a = try f.write("stage/a.yml", "on: push\nconcurrency:\n  group: post-${{ github.sha }}\n");
    const b = try f.write("stage/b.yml", "on:\n  - push\njobs: {}\n");
    try fx.expectPass(try f.run("push_verdicts", "stage", &.{}, &.{ a, b }), 2);
}

test "push_verdicts: no push-triggered workflow checks nothing, so fails" {
    var f = try fx.Fixture.init();
    defer f.deinit();
    const a = try f.write("stage/a.yml", "on: pull_request\nconcurrency:\n  group: pr\n# on: push\n");
    const r = try f.run("push_verdicts", "stage", &.{}, &.{a});
    try std.testing.expectEqual(@as(usize, 0), r.checked);
    try std.testing.expect(r.failed());
}
