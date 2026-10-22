//! mopm_publish: the publish of the packages that have mopm targets
//! (.github/workflows/release.yml, docs/ci.md, "release.yml"). The packages
//! are built by Buck2 (//release:mopm_set); this program runs the pinned
//! `mopm publish` over them (release_lib/mopm_publish.zig has the rules).
//!
//!   mopm_publish --mode <dry-run|publish> --set <dir> --mopm <binary> --repo <dir>
//!       --registry <prod|gamma|beta|url> [--summary-file <file>]
//!       --set      the built //release:mopm_set: a directory `<name>/` per
//!                  package, each with `<name>.mojoc` and the `.conda`
//!       --repo     the checkout root: `<repo>/src/<name>/mopm.toml` is each
//!                  package's manifest, and every `src/*/mopm.toml` must name
//!                  a package of the set (and the reverse)
//!       dry-run    `mopm publish --dry-run` for each package: nothing is
//!                  sent, no token is read
//!       publish    then `mopm publish`, which needs $MOPM_TOKEN (refused
//!                  here when it is empty); a version the registry already
//!                  has is skipped
//!
//! One line per package on standard output (and the summary file). Exit 0
//! when every package passed, 1 when any did not (every package is tried,
//! the reasons are on standard error), 2 on a usage error.
const std = @import("std");
const lib = @import("release_lib");

const util = lib.util;
const mp = lib.mopm_publish;

const NAMES = [_][]const u8{ "--mode", "--set", "--mopm", "--repo", "--registry", "--summary-file" };

const USAGE =
    \\usage: mopm_publish --mode <dry-run|publish> --set <dir> --mopm <binary> --repo <dir>
    \\                    --registry <prod|gamma|beta|url> [--summary-file <file>]
    \\
;

fn die(code: u8, comptime fmt: []const u8, args: anytype) noreturn {
    std.fs.File.stderr().deprecatedWriter().print("mopm_publish: " ++ fmt ++ "\n", args) catch {};
    std.process.exit(code);
}

pub fn main() void {
    run() catch |e| die(1, "{s}", .{@errorName(e)});
}

fn usage(comptime fmt: []const u8, args: anytype) noreturn {
    std.fs.File.stderr().deprecatedWriter().print("mopm_publish: " ++ fmt ++ "\n{s}", args ++ .{USAGE}) catch {};
    std.process.exit(2);
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

/// The packages of the set directory, by name.
fn readSet(a: std.mem.Allocator, set: []const u8) ![]mp.Package {
    var dir = try std.fs.cwd().openDir(set, .{ .iterate = true });
    defer dir.close();
    var names = std.ArrayList([]const u8).empty;
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (e.kind != .directory) die(1, "{s}/{s} is not a package directory", .{ set, e.name });
        try names.append(a, try a.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    var pkgs = std.ArrayList(mp.Package).empty;
    for (names.items) |name| {
        const pdir = try std.fmt.allocPrint(a, "{s}/{s}", .{ set, name });
        var d = try std.fs.cwd().openDir(pdir, .{ .iterate = true });
        defer d.close();
        var conda: ?[]const u8 = null;
        var mojoc = false;
        var files = d.iterate();
        while (try files.next()) |f| {
            if (std.mem.endsWith(u8, f.name, ".conda")) {
                if (conda != null) die(1, "{s} has more than one .conda file", .{pdir});
                conda = try a.dupe(u8, f.name);
            } else if (std.mem.eql(u8, f.name, try std.fmt.allocPrint(a, "{s}.mojoc", .{name}))) {
                mojoc = true;
            } else die(1, "{s}/{s} is not part of a package of the set", .{ pdir, f.name });
        }
        const conda_file = conda orelse die(1, "{s} has no .conda file", .{pdir});
        if (!mojoc) die(1, "{s} has no {s}.mojoc", .{ pdir, name });
        const bytes = try d.readFileAlloc(a, conda_file, 1 << 28);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        try pkgs.append(a, .{
            .name = name,
            .mojoc = try std.fmt.allocPrint(a, "{s}/{s}.mojoc", .{ pdir, name }),
            .conda_file = conda_file,
            .conda_sha256 = try a.dupe(u8, &hex),
        });
    }
    return pkgs.items;
}

/// The directories of `<repo>/src` that have a mopm.toml.
fn manifestDirs(a: std.mem.Allocator, repo: []const u8) ![]const []const u8 {
    var src = try std.fs.cwd().openDir(try std.fmt.allocPrint(a, "{s}/src", .{repo}), .{ .iterate = true });
    defer src.close();
    var found = std.ArrayList([]const u8).empty;
    var it = src.iterate();
    while (try it.next()) |e| {
        if (e.kind != .directory) continue;
        src.access(try std.fmt.allocPrint(a, "{s}/mopm.toml", .{e.name}), .{}) catch continue;
        try found.append(a, try a.dupe(u8, e.name));
    }
    return found.items;
}

fn run() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);
    var bad: []const u8 = "";
    const flags = util.Flags.parse(a, argv[1..], &NAMES, &bad) catch |e| usage("{s}: {s}", .{ @errorName(e), bad });
    for ([_][]const u8{ "--mode", "--set", "--mopm", "--repo", "--registry" }) |need| {
        if (flags.get(need) == null) usage("{s} is required", .{need});
    }
    const mode = flags.get("--mode").?;
    const dry_run = if (std.mem.eql(u8, mode, "dry-run")) true else if (std.mem.eql(u8, mode, "publish")) false else usage("--mode is dry-run or publish, not '{s}'", .{mode});
    const repo = flags.get("--repo").?;
    if (!dry_run) {
        const token: []const u8 = std.process.getEnvVarOwned(a, "MOPM_TOKEN") catch "";
        if (std.mem.trim(u8, token, " \t\r\n").len == 0) die(1, "publish mode needs $MOPM_TOKEN (the job's publish token); it is empty", .{});
    }

    const pkgs = try readSet(a, flags.get("--set").?);
    if (pkgs.len == 0) die(1, "the set has no package: nothing to publish is a misconfiguration", .{});
    var listed = std.ArrayList([]const u8).empty;
    for (pkgs) |p| try listed.append(a, p.name);
    if (try mp.checkSync(a, listed.items, try manifestDirs(a, repo))) |why| die(1, "{s}", .{why});

    const opts = mp.Options{ .mopm = flags.get("--mopm").?, .registry = flags.get("--registry").?, .repo = repo, .dry_run = dry_run };
    var failed: usize = 0;
    var report = std.ArrayList(u8).empty;
    for (pkgs) |p| {
        const r = mp.publishOne(a, opts, p, mp.RealRunner{});
        const line = switch (r) {
            .dry_run_ok => try std.fmt.allocPrint(a, "{s}: dry run ok, would upload {s} (sha256 {s}), the built package\n", .{ p.name, p.conda_file, p.conda_sha256 }),
            .published => try std.fmt.allocPrint(a, "{s}: published {s} to {s}\n", .{ p.name, p.conda_file, opts.registry }),
            .already_published => try std.fmt.allocPrint(a, "{s}: {s} is already on {s}: skipped\n", .{ p.name, p.conda_file, opts.registry }),
            .failed => |why| blk: {
                failed += 1;
                std.fs.File.stderr().deprecatedWriter().print("mopm_publish: {s}\n", .{why}) catch {};
                break :blk try std.fmt.allocPrint(a, "{s}: FAILED\n", .{p.name});
            },
        };
        try report.appendSlice(a, line);
    }
    try std.fs.File.stdout().writeAll(report.items);
    if (flags.get("--summary-file")) |s| try util.appendFile(s, try std.fmt.allocPrint(a, "mopm {s} ({s}):\n{s}", .{ opts.registry, mode, report.items }));
    if (failed > 0) die(1, "{d} package(s) failed", .{failed});
}
