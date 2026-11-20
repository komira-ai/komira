//! komira_wheel: the Python package's wheel, byte for byte reproducible, and
//! its read-back check (tools/build/package/wheel.bzl runs both).
//!
//! usage:
//!   komira_wheel wheel --name <distribution> --pyproject <pyproject.toml> --readme <name>=<file>
//!       --version-base <compiler version> --stamp <N> --tag py3-none-<platform>
//!       --platform <release platform> [--runtime-requires <requirement>]...
//!       --import-name <name> --package-dir <dir> --native-dir <dir>
//!       --native-lib <file name> [--native-drop <file name>]...
//!       [--license-file <name>=<file>]... --out-dir <dir>
//!   komira_wheel check --dir <out dir> (the same flags but --package-dir,
//!       --native-dir and --out-dir) --commit <sha or ""> --require-stamped true|false
//!       [--twin-dir <the out dir of the same wheel built again>] --out <marker>
//!
//! `wheel` writes three files into --out-dir: the wheel
//! (`<dist>-<version>-<tag>.whl`), its METADATA, and manifest.json, the
//! release's artifact manifest of a PYTHON artifact (wheel.zig `manifest`).
//! The version is `<version-base>.post<stamp>`; --name must be the
//! pyproject's name (the rule states it to name the wheel's file). --package-dir holds the import
//! package at its path in the wheel (`<import-name>/...`); --native-dir is the
//! library's runnable directory (the library, and lib/ of the libraries it
//! loads), copied to `<import-name>/_lib/` without each `lib/<native-drop>`.
//! Every file of --native-dir is written with mode 0755 (they are shared
//! libraries); a package file keeps 0755 only if it has an exec bit.
//!
//! `check` reads the directory back (wheel_check.zig says what it holds) and
//! writes `ok` to --out only if nothing is refused; each --native-drop name
//! is then a file name no member may have.
//!
//! A static executable: no shell, no PATH, no network, no clock. Exit status 2
//! on any refusal, with the reason.
//!
//! This file only forwards. Sections: wheel_project.zig (the pyproject's
//! [project]), wheel_zip.zig (the zip), wheel.zig (the wheel's members and
//! manifest), wheel_check.zig (the check), wheel_fs.zig (flags and files).

const std = @import("std");
const common = @import("common.zig");
const project = @import("wheel_project.zig");
const wheel = @import("wheel.zig");
const check = @import("wheel_check.zig");
const fs = @import("wheel_fs.zig");
const Alloc = std.mem.Allocator;
const fail = common.fail;
const need = common.need;
const one = common.one;

const Diag = project.Diag;

fn orFail(d: *const Diag, err: project.Refused) noreturn {
    switch (err) {
        error.Refused => fail("{s}", .{d.msg}),
        error.OutOfMemory => fail("out of memory", .{}),
    }
}

const Common = struct {
    project: project.Project,
    readme_name: []const u8,
    readme: []const u8,
    version_base: []const u8,
    stamp: []const u8,
    tag: []const u8,
    platform: []const u8,
    runtime_requires: []const []const u8,
    import_name: []const u8,
    native_lib: []const u8,
    native_drop: []const []const u8,
    licenses: []wheel.File,
};

fn readCommon(alloc: Alloc, a: common.Args, d: *Diag) project.Refused!Common {
    const pr = try project.parse(alloc, d, common.readAll(alloc, need(one(a, "--pyproject"), "--pyproject")));
    try fs.checkDistribution(alloc, d, need(a.name, "--name"), pr);
    const readme = try fs.named(alloc, d, need(one(a, "--readme"), "--readme"), "--readme");
    const runtime = try common.all(alloc, a, "--runtime-requires");
    try fs.checkRequirements(alloc, d, runtime);
    const drop = try common.all(alloc, a, "--native-drop");
    for (drop) |n| _ = common.plain(n, "--native-drop", "");
    var lics = std.ArrayList(wheel.File).empty;
    for (try common.all(alloc, a, "--license-file")) |arg| {
        const kv = try fs.named(alloc, d, arg, "--license-file");
        try lics.append(alloc, .{ .path = kv[0], .data = common.readAll(alloc, kv[1]) });
    }
    return .{
        .project = pr,
        .readme_name = readme[0],
        .readme = common.readAll(alloc, readme[1]),
        .version_base = need(one(a, "--version-base"), "--version-base"),
        .stamp = need(one(a, "--stamp"), "--stamp"),
        .tag = need(one(a, "--tag"), "--tag"),
        .platform = common.plain(need(one(a, "--platform"), "--platform"), "--platform", ""),
        .runtime_requires = runtime,
        .import_name = need(one(a, "--import-name"), "--import-name"),
        .native_lib = common.plain(need(one(a, "--native-lib"), "--native-lib"), "--native-lib", ""),
        .native_drop = drop,
        .licenses = try lics.toOwnedSlice(alloc),
    };
}

const common_flags = [_][]const u8{
    "--pyproject",        "--readme",      "--version-base", "--stamp",       "--tag",          "--platform",
    "--runtime-requires", "--import-name", "--native-lib",   "--native-drop", "--license-file",
};

fn cmdWheel(alloc: Alloc, a: common.Args, d: *Diag) project.Refused!void {
    common.allow(a, &(common_flags ++ [_][]const u8{ "--package-dir", "--native-dir", "--out-dir" }));
    const c = try readCommon(alloc, a, d);
    const ver = try wheel.version(alloc, d, c.version_base, c.stamp);
    const built = try wheel.build(alloc, d, .{
        .project = c.project,
        .readme_name = c.readme_name,
        .readme = c.readme,
        .version = ver,
        .tag = c.tag,
        .runtime_requires = c.runtime_requires,
        .import_name = c.import_name,
        .package_files = try fs.walk(alloc, d, need(one(a, "--package-dir"), "--package-dir"), false),
        .native_files = try fs.walk(alloc, d, need(one(a, "--native-dir"), "--native-dir"), true),
        .native_lib = c.native_lib,
        .native_drop = c.native_drop,
        .licenses = c.licenses,
    });
    const out_dir = need(one(a, "--out-dir"), "--out-dir");
    std.fs.cwd().makePath(out_dir) catch |err| fail("cannot create {s}: {s}", .{ out_dir, @errorName(err) });
    var out = std.fs.cwd().openDir(out_dir, .{}) catch |err| fail("cannot open {s}: {s}", .{ out_dir, @errorName(err) });
    defer out.close();
    const manifest = try wheel.manifest(alloc, c.project.name, ver, c.platform, built.file_name, &common.sha256Hex(built.wheel));
    for ([_][2][]const u8{ .{ built.file_name, built.wheel }, .{ "METADATA", built.metadata }, .{ "manifest.json", manifest } }) |f| {
        common.writeFile(out, f[0], f[1]) catch |err| fail("cannot write {s}/{s}: {s}", .{ out_dir, f[0], @errorName(err) });
    }
}

fn cmdCheck(alloc: Alloc, a: common.Args, d: *Diag) project.Refused!void {
    common.allow(a, &(common_flags ++ [_][]const u8{ "--dir", "--commit", "--require-stamped", "--twin-dir" }));
    const c = try readCommon(alloc, a, d);
    const stamped = try fs.flagBool(alloc, d, "--require-stamped", need(one(a, "--require-stamped"), "--require-stamped"));
    const dir = need(one(a, "--dir"), "--dir");
    const listing = try fs.listDir(alloc, d, dir);
    const wn = listing.wheel_name;
    const twin = if (one(a, "--twin-dir")) |p| common.readAll(alloc, try std.fs.path.join(alloc, &.{ p, wn })) else null;
    try check.check(alloc, d, .{
        .project = c.project,
        .readme = c.readme,
        .version_base = c.version_base,
        .stamp = c.stamp,
        .commit = one(a, "--commit") orelse "",
        .tag = c.tag,
        .platform = c.platform,
        .runtime_requires = c.runtime_requires,
        .import_name = c.import_name,
        .native_lib = c.native_lib,
        .forbid = c.native_drop,
        .licenses = c.licenses,
        .require_stamped = stamped,
    }, .{
        .names = listing.names,
        .manifest = common.readAll(alloc, try std.fs.path.join(alloc, &.{ dir, "manifest.json" })),
        .metadata = common.readAll(alloc, try std.fs.path.join(alloc, &.{ dir, "METADATA" })),
        .wheel_name = wn,
        .wheel = common.readAll(alloc, try std.fs.path.join(alloc, &.{ dir, wn })),
    }, twin);
    common.writeFile(std.fs.cwd(), need(a.out, "--out"), "ok\n") catch |err| fail("cannot write the marker: {s}", .{@errorName(err)});
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const argv = try std.process.argsAlloc(alloc);
    if (argv.len < 2) fail("usage: komira_wheel wheel|check --flag value ...", .{});
    const a = try common.parseArgs(alloc, argv);
    var d = Diag{};
    if (std.mem.eql(u8, argv[1], "wheel")) {
        cmdWheel(alloc, a, &d) catch |err| orFail(&d, err);
    } else if (std.mem.eql(u8, argv[1], "check")) {
        cmdCheck(alloc, a, &d) catch |err| orFail(&d, err);
    } else fail("unknown command {s}", .{argv[1]});
}
