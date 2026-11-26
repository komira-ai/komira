//! komira_npm: an npm package tarball written from the rule's manifest and
//! files, byte for byte reproducible, and its read-back check
//! (tools/build/package/npm.bzl runs both).
//!
//! usage:
//!   komira_npm write <flags> --out <tarball>
//!   komira_npm check <flags> --tarball <tarball> --require-stamped true|false
//!       [--twin <tarball>] --out <marker>
//! cli.zig lists the flags. `write` refuses to write a package that npm.zig
//! refuses; `check` writes `ok` to --out only if check.zig refuses nothing.
//!
//! A static executable: no shell, no PATH, no network, no clock. Exit status
//! 2 on any refusal, with its reason. This file only forwards; the sections
//! are cli.zig (flags and files), manifest.zig (package.json), npm.zig (the
//! package), tarball.zig (gzip and tar) and check.zig; the version is the
//! wheel's stamp (../wheel/stamp.zig, the module package_stamp), what its
//! libraries need is the module native_policy (../native_policy/), and a
//! refusal travels as its diag.zig says.

const std = @import("std");
const diag = @import("native_policy").diag;
const check = @import("check.zig");
const cli = @import("cli.zig");
const npm = @import("npm.zig");
const Alloc = std.mem.Allocator;

fn writeOut(alloc: Alloc, d: *diag.Diag, path: []const u8, data: []const u8) diag.Refused!void {
    std.fs.cwd().writeFile(.{ .sub_path = path, .data = data }) catch |err|
        return diag.refuse(d, alloc, "cannot write {s}: {s}", .{ path, @errorName(err) });
}

fn cmdWrite(alloc: Alloc, d: *diag.Diag, argv: []const []const u8) diag.Refused!void {
    const a = try cli.parse(alloc, d, argv, &.{"--out"});
    const in = try cli.input(alloc, d, a);
    const out = try a.one(alloc, d, "--out");
    const want = try npm.fileName(alloc, in.name, in.version);
    if (!std.mem.eql(u8, std.fs.path.basename(out), want)) return diag.refuse(d, alloc, "name: --out is {s}, but the tarball is named {s}", .{ out, want });
    const bytes = try npm.build(alloc, d, in);
    if (std.fs.path.dirname(out)) |dir| std.fs.cwd().makePath(dir) catch |err|
        return diag.refuse(d, alloc, "cannot create {s}: {s}", .{ dir, @errorName(err) });
    try writeOut(alloc, d, out, bytes);
}

fn cmdCheck(alloc: Alloc, d: *diag.Diag, argv: []const []const u8) diag.Refused!void {
    const a = try cli.parse(alloc, d, argv, &.{ "--tarball", "--require-stamped", "--twin", "--out" });
    const in = try cli.input(alloc, d, a);
    const path = try a.one(alloc, d, "--tarball");
    const twin = if (try a.opt(alloc, d, "--twin")) |p| try cli.readFile(alloc, d, p) else null;
    const stamped = try cli.flagBool(alloc, d, "--require-stamped", try a.one(alloc, d, "--require-stamped"));
    try check.check(alloc, d, in, std.fs.path.basename(path), try cli.readFile(alloc, d, path), stamped, twin);
    try writeOut(alloc, d, try a.one(alloc, d, "--out"), "ok\n");
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const argv = try std.process.argsAlloc(alloc);
    var d = diag.Diag{};
    var rest = std.ArrayList([]const u8).empty;
    for (argv[@min(argv.len, 2)..]) |x| try rest.append(alloc, x);
    const cmd: []const u8 = if (argv.len >= 2) argv[1] else "";
    const result = if (cli.subcommand(alloc, &d, cmd)) |c| switch (c) {
        .write => cmdWrite(alloc, &d, rest.items),
        .check => cmdCheck(alloc, &d, rest.items),
    } else |err| err;
    result catch |err| {
        switch (err) {
            error.Refused => std.debug.print("komira_npm: {s}\n", .{d.msg}),
            error.OutOfMemory => std.debug.print("komira_npm: out of memory\n", .{}),
        }
        std.process.exit(2);
    };
}
