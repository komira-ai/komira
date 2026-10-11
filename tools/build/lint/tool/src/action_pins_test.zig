//! kind action_pins: a `uses:` by tag is refused; a full commit SHA or a
//! local action passes.

const std = @import("std");
const fx = @import("fixture.zig");

// A full commit SHA, spelled so this file holds no 40-hex run.
const sha = "0123456789abcdef" ** 2 ++ "01234567";

test "action_pins: an action pinned by tag is refused, naming its line" {
    var f = try fx.Fixture.init();
    defer f.deinit();
    const wf = try f.write("stage/ci.yml", "jobs:\n  a:\n    steps:\n      - uses: actions/checkout@" ++ sha ++ "\n      - uses: actions/cache@v4\n");
    const r = try f.run("action_pins", "stage", &.{}, &.{wf});
    try fx.expectFinding(r, "ci.yml:5:      - uses: actions/cache@v4 -- not pinned to a full commit SHA");
    try std.testing.expectEqual(@as(usize, 2), r.checked);
    // The finding names the file by its path in the package, not the stage.
    try std.testing.expect(std.mem.indexOf(u8, r.json, "test//ci.yml:5:") != null);
}

test "action_pins: a SHA one digit short, or one in a trailing comment, is refused" {
    var f = try fx.Fixture.init();
    defer f.deinit();
    const wf = try f.write("stage/ci.yml", "    - uses: a/b@" ++ sha[0..39] ++ "\n    - uses: a/c@v1 # " ++ sha ++ "\n");
    const r = try f.run("action_pins", "stage", &.{}, &.{wf});
    try fx.expectFinding(r, "ci.yml:1:");
    try fx.expectFinding(r, "ci.yml:2:");
}

test "action_pins: full SHAs and local actions pass" {
    var f = try fx.Fixture.init();
    defer f.deinit();
    const wf = try f.write("stage/ci.yml", "- uses: actions/checkout@" ++ sha ++ "\n  uses: ./.github/actions/setup\n  name: uses: none\n");
    try fx.expectPass(try f.run("action_pins", "stage", &.{}, &.{wf}), 2);
}

test "action_pins: a set with no `uses:` checks nothing, so fails" {
    var f = try fx.Fixture.init();
    defer f.deinit();
    const wf = try f.write("stage/ci.yml", "on: push\n");
    const r = try f.run("action_pins", "stage", &.{}, &.{wf});
    try std.testing.expect(r.failed());
    try std.testing.expect(std.mem.indexOf(u8, r.json, "action_pins: checked nothing") != null);
}
