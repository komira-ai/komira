//! komira_wheel: a wheel written from the rule's attributes and files, byte
//! for byte reproducible, and its read-back check (tools/build/package/
//! wheel.bzl runs both).
//!
//! usage:
//!   komira_wheel write <flags> --out <wheel>
//!   komira_wheel check <flags> --wheel <wheel> --require-stamped true|false
//!       [--twin <wheel>] --out <marker>
//!   komira_wheel libs --wheel <wheel> --entry <member path>
//!       --runtime-lib <name>=<file>... [--runtime-license <name>]...
//!       [--runtime-dist <distribution>]...
//!       [--expect-refusal <text>] --out <marker>
//!   komira_wheel same --wheel <wheel> --like <wheel>
//!       [--only-in-wheel <member path>]... [--only-in-like <member path>]...
//!       --out <marker>
//! cli.zig lists the flags of `write` and `check`. `write` refuses to write a
//! wheel that native_policy's policy.zig refuses; `check` writes `ok` to
//! --out only if check.zig refuses nothing. `libs` reads the wheel
//! alone (libs.zig): --out gets the libraries the entry loads, in load order,
//! one member path a line, only if libs.zig refuses nothing (with
//! --expect-refusal, `refused: <text>` only if it refuses the wheel with
//! exactly that text); each `--runtime-lib` file is the toolchain's copy of
//! that Mojo runtime library. `same` reads two wheels of one package for two
//! platforms (compare.zig): --out gets the members alike and each wheel's own
//! native libraries, only if they are the same package apart from those.
//!
//! A static executable: no shell, no PATH, no network, no clock. Exit status 2
//! on any refusal, with its reason. This file only forwards; the sections are
//! cli.zig (flags and files), stamp.zig (version), tag.zig, wheel.zig (the
//! wheel), zip.zig, check.zig, libs.zig and compare.zig; what its libraries
//! need is the module native_policy (../native_policy/: policy.zig, elf.zig,
//! macho.zig and codesign.zig), and a refusal travels as its diag.zig says.

const std = @import("std");
const diag = @import("native_policy").diag;
const cli = @import("cli.zig");
const check = @import("check.zig");
const compare = @import("compare.zig");
const libs = @import("libs.zig");
const wheel = @import("wheel.zig");
const zip = @import("zip.zig");
const Alloc = std.mem.Allocator;

fn writeOut(alloc: Alloc, d: *diag.Diag, path: []const u8, data: []const u8) diag.Refused!void {
    std.fs.cwd().writeFile(.{ .sub_path = path, .data = data }) catch |err|
        return diag.refuse(d, alloc, "cannot write {s}: {s}", .{ path, @errorName(err) });
}

fn cmdWrite(alloc: Alloc, d: *diag.Diag, argv: []const []const u8) diag.Refused!void {
    const a = try cli.parse(alloc, d, argv, &.{"--out"});
    const x = try cli.input(alloc, d, a);
    const out = try a.one(alloc, d, "--out");
    const want = try wheel.fileName(alloc, x.in.name, x.in.version, x.in.tag);
    if (!std.mem.eql(u8, std.fs.path.basename(out), want)) return diag.refuse(d, alloc, "name: --out is {s}, but the wheel is named {s}", .{ out, want });
    const bytes = try wheel.build(alloc, d, x.in, try zip.stampOf(alloc, d, x.stamp.timestamp_ms));
    if (std.fs.path.dirname(out)) |dir| std.fs.cwd().makePath(dir) catch |err|
        return diag.refuse(d, alloc, "cannot create {s}: {s}", .{ dir, @errorName(err) });
    try writeOut(alloc, d, out, bytes);
}

fn cmdCheck(alloc: Alloc, d: *diag.Diag, argv: []const []const u8) diag.Refused!void {
    const a = try cli.parse(alloc, d, argv, &.{ "--wheel", "--require-stamped", "--twin", "--out" });
    const x = try cli.input(alloc, d, a);
    const path = try a.one(alloc, d, "--wheel");
    const twin = if (try a.opt(alloc, d, "--twin")) |p| try cli.readFile(alloc, d, p) else null;
    const stamped = try cli.flagBool(alloc, d, "--require-stamped", try a.one(alloc, d, "--require-stamped"));
    try check.check(alloc, d, x.in, x.stamp, std.fs.path.basename(path), try cli.readFile(alloc, d, path), stamped, twin);
    try writeOut(alloc, d, try a.one(alloc, d, "--out"), "ok\n");
}

/// The files `komira_wheel libs` names, read from the file system.
const Disk = struct {
    pub fn read(_: Disk, alloc: Alloc, d: *diag.Diag, path: []const u8) diag.Refused![]const u8 {
        return cli.readFile(alloc, d, path);
    }
};

fn cmdLibs(alloc: Alloc, d: *diag.Diag, argv: []const []const u8) diag.Refused!void {
    const r = try libs.command(alloc, d, argv, Disk{});
    try writeOut(alloc, d, r.out, r.marker);
}

fn cmdSame(alloc: Alloc, d: *diag.Diag, argv: []const []const u8) diag.Refused!void {
    const r = try compare.command(alloc, d, argv, Disk{});
    try writeOut(alloc, d, r.out, r.marker);
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
        .libs => cmdLibs(alloc, &d, rest.items),
        .same => cmdSame(alloc, &d, rest.items),
    } else |err| err;
    result catch |err| {
        switch (err) {
            error.Refused => std.debug.print("komira_wheel: {s}\n", .{d.msg}),
            error.OutOfMemory => std.debug.print("komira_wheel: out of memory\n", .{}),
        }
        std.process.exit(2);
    };
}
