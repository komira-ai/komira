//! kind no_endpoint: a committed endpoint key, an unignored
//! .buckconfig.local and a committed grpc address are each refused.

const std = @import("std");
const fx = @import("fixture.zig");

// Spelled in parts, so this file names no address.
const scheme = "grpc" ++ "s://";
const ignore = "/.buckconfig.local\nbuck-out/\n";

test "no_endpoint: an endpoint key in a committed buckconfig is refused" {
    var f = try fx.Fixture.init();
    defer f.deinit();
    const gi = try f.write("stage/.gitignore", ignore);
    const bc = try f.write("stage/.buckconfig", "[buck2_re_client]\n  engine_address = $(config komira_re.engine)\n");
    const r = try f.run("no_endpoint", "stage", &.{}, &.{ gi, "1", bc });
    try fx.expectFinding(r, ".buckconfig:2:  engine_address = $(config komira_re.engine) -- an endpoint belongs in .buckconfig.local");
}

test "no_endpoint: a .gitignore that does not ignore /.buckconfig.local is refused" {
    var f = try fx.Fixture.init();
    defer f.deinit();
    const gi = try f.write("stage/.gitignore", "buck-out/\n.buckconfig.local\n");
    const bc = try f.write("stage/.buckconfig", "[cells]\n");
    try fx.expectFinding(try f.run("no_endpoint", "stage", &.{}, &.{ gi, "1", bc }), ".gitignore: does not ignore /.buckconfig.local");
}

test "no_endpoint: a grpc address outside example.* is refused, in any file" {
    var f = try fx.Fixture.init();
    defer f.deinit();
    const gi = try f.write("stage/.gitignore", ignore);
    const bc = try f.write("stage/.buckconfig", "[cells]\n");
    const wf = try f.write("stage/ci.yml", "env:\n  RE: " ++ scheme ++ "re.build.zz:443 # and " ++ scheme ++ "re.example.com:443\n");
    const r = try f.run("no_endpoint", "stage", &.{}, &.{ gi, "1", bc, wf });
    try fx.expectFinding(r, "ci.yml:2:" ++ scheme ++ "re.build.zz:443 -- a remote-execution address is committed");
    try std.testing.expect(std.mem.indexOf(u8, r.report, "example.com") == null);
    try std.testing.expectEqual(@as(usize, 2), r.checked);
}

test "no_endpoint: example addresses, and endpoint keys outside the buckconfigs, pass" {
    var f = try fx.Fixture.init();
    defer f.deinit();
    const gi = try f.write("stage/.gitignore", ignore);
    const bc = try f.write("stage/.buckconfig", "[cells]\n  komira = .\n");
    const ex = try f.write("stage/.buckconfig.local.example", "  engine_address = " ++ scheme ++ "re.example.net:8980\n  cas_address = " ++ scheme ++ "example.org\n");
    try fx.expectPass(try f.run("no_endpoint", "stage", &.{}, &.{ gi, "1", bc, ex }), 2);
}
