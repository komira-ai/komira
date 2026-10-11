//! kind public_boundary: a planted private address is refused; a clean tree
//! passes; binary data is read by its path only. Runs the pinned busybox's
//! awk over public_boundary.awk (LINT_BUSYBOX, LINT_PUBLIC_AWK).

const std = @import("std");
const fx = @import("fixture.zig");
const readers = @import("readers.zig");

// Spelled in parts, so this file holds no address.
const private_ip = "10." ++ "1.2.3";

fn args(f: *fx.Fixture) ![]const []const u8 {
    const holds = try f.write("holds.tsv", "# rule\tfile\tcount\treason\n");
    const hosts = try f.write("hosts.tsv", "# domain\treason\n");
    const out = try f.alloc().alloc([]const u8, 7);
    out[0..7].* = .{ holds, "test//holds.tsv", hosts, "test//hosts.tsv", "-", "2030", "2031-09-01" };
    return out;
}

test "public_boundary: a private address is refused, naming file and line" {
    var f = try fx.Fixture.init();
    defer f.deinit();
    _ = try fx.tool(f.alloc(), "LINT_BUSYBOX");
    const awk = try fx.tool(f.alloc(), "LINT_PUBLIC_AWK");
    _ = try f.write("stage/docs/plant.md", "The builder is at " ++ private_ip ++ ".\n");
    _ = try f.write("stage/docs/near.md", "Version 1.2.3.\n");
    const r = try f.run("public_boundary", "stage", &.{awk}, try args(&f));
    try fx.expectFinding(r, "docs/plant.md:1: ip: " ++ private_ip ++ " -- ");
    try std.testing.expectEqual(@as(usize, 2), r.checked);
}

test "public_boundary: a clean tree passes, and binary data is not read" {
    var f = try fx.Fixture.init();
    defer f.deinit();
    _ = try fx.tool(f.alloc(), "LINT_BUSYBOX");
    const awk = try fx.tool(f.alloc(), "LINT_PUBLIC_AWK");
    _ = try f.write("stage/docs/near.md", "Version 1.2.3, see https://www.example.com/x.\n");
    _ = try f.write("stage/data/blob.parquet", "at " ++ private_ip ++ "\n");
    try fx.expectPass(try f.run("public_boundary", "stage", &.{awk}, try args(&f)), 1);
}

test "public_boundary: binary suffixes" {
    try std.testing.expect(readers.isBinary("a/b.parquet"));
    try std.testing.expect(readers.isBinary("lib.a"));
    try std.testing.expect(!readers.isBinary("a.so/README.md"));
    try std.testing.expect(!readers.isBinary("BUCK"));
}
