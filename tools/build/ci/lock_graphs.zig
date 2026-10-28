//! lock_graphs: the action behind lock_graphs.bxl.
//!
//! usage: lock_graphs <result.json> (<package> <mojo> <mopm.lock> <held>)...
//!
//! A package built with buildrules' `mojo_package` commits one unit graph per
//! platform subdir in `buildrules.mojo.lock.bzl` (`GRAPHS`). `buildrules mojo
//! sync` plans a graph for linux-64 and for each of linux-aarch64 and osx-arm64
//! that the package's `mopm.lock` records a toolchain for, under the Mojo
//! version the package builds with: `{"toolchain": {"1.0.0": {"linux-64": ...,
//! "osx-arm64": ...}}}`. This tool holds the committed table to that.
//!
//! For each quadruple, <package> is the label (findings name it), <mojo> the
//! Mojo version, <mopm.lock> the package's lock and <held> the subdirs the
//! table holds a graph for, comma separated ("" for linux-64 alone; linux-64
//! is always held). It fails, printing a finding for each subdir the lock
//! records and the table lacks, and for each subdir the table holds that the
//! lock does not record. A lock that is not JSON, or has no toolchain row for
//! <mojo>, is a finding too. Writes <result.json> only when it finds nothing.

const std = @import("std");
const Alloc = std.mem.Allocator;

/// The subdirs `buildrules mojo sync` asks mopm for beside linux-64, in the
/// order it writes them (cli/src/mojo_lock.zig `extra_subdirs`).
pub const extra_subdirs = [_][]const u8{ "linux-aarch64", "osx-arm64" };

pub const Pkg = struct {
    label: []const u8,
    mojo: []const u8,
    lock_path: []const u8,
    held_csv: []const u8,
};

/// The subdirs of `extra_subdirs` the lock text records a toolchain for under `mojo`; null (with `why` set) when the text is not a lock that has
/// a toolchain row for `mojo`.
pub fn recorded(a: Alloc, lock_text: []const u8, mojo: []const u8, why: *[]const u8) !?[]const []const u8 {
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, lock_text, .{}) catch {
        why.* = "it is not JSON";
        return null;
    };
    if (root != .object) {
        why.* = "it is not a JSON object";
        return null;
    }
    const tc = root.object.get("toolchain") orelse {
        why.* = "it has no \"toolchain\" member";
        return null;
    };
    if (tc != .object) {
        why.* = "its \"toolchain\" is not an object";
        return null;
    }
    const row = tc.object.get(mojo) orelse {
        why.* = try std.fmt.allocPrint(a, "its \"toolchain\" has no row for Mojo {s}", .{mojo});
        return null;
    };
    if (row != .object) {
        why.* = try std.fmt.allocPrint(a, "its toolchain row for Mojo {s} is not an object", .{mojo});
        return null;
    }
    var out = std.ArrayList([]const u8).empty;
    for (extra_subdirs) |sd| {
        if (row.object.get(sd) != null) try out.append(a, sd);
    }
    return try out.toOwnedSlice(a);
}

fn contains(list: []const []const u8, x: []const u8) bool {
    for (list) |l| if (std.mem.eql(u8, l, x)) return true;
    return false;
}

/// The findings for one package: `lock_text` is its mopm.lock.
pub fn check(a: Alloc, p: Pkg, lock_text: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var why: []const u8 = "";
    const want = (try recorded(a, lock_text, p.mojo, &why)) orelse {
        try out.append(a, try std.fmt.allocPrint(a, "{s}: cannot tell which subdirs its graphs must cover: {s} is unusable ({s})", .{ p.label, p.lock_path, why }));
        return try out.toOwnedSlice(a);
    };
    var held = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, p.held_csv, ',');
    while (it.next()) |s| {
        if (s.len > 0) try held.append(a, s);
    }
    for (want) |sd| {
        if (!contains(held.items, sd))
            try out.append(a, try std.fmt.allocPrint(a, "{s}: its mopm.lock records a toolchain for {s} (Mojo {s}) but GRAPHS of buildrules.mojo.lock.bzl holds no graph for it, so a build for that platform has none to use and the committed table is not what `buildrules mojo sync` writes: run `buildrules mojo sync` for the package", .{ p.label, sd, p.mojo }));
    }
    for (held.items) |sd| {
        if (std.mem.eql(u8, sd, "linux-64")) continue;
        if (!contains(want, sd))
            try out.append(a, try std.fmt.allocPrint(a, "{s}: GRAPHS of buildrules.mojo.lock.bzl holds a graph for {s} but its mopm.lock records no toolchain for {s} under Mojo {s}, so `buildrules mojo sync` would not write it: run `buildrules mojo sync` for the package", .{ p.label, sd, sd, p.mojo }));
    }
    return try out.toOwnedSlice(a);
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("lock_graphs: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len < 2 or (argv.len - 2) % 4 != 0) die("usage: lock_graphs <result.json> (<package> <mojo> <mopm.lock> <held>)...", .{});
    const n = (argv.len - 2) / 4;
    if (n == 0) die("checked nothing: no package given", .{});
    var report = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const base = 2 + 4 * i;
        const p = Pkg{ .label = argv[base], .mojo = argv[base + 1], .lock_path = argv[base + 2], .held_csv = argv[base + 3] };
        const text = std.fs.cwd().readFileAlloc(a, p.lock_path, 1 << 26) catch |e| die("{s}: cannot read {s}: {s}", .{ p.label, p.lock_path, @errorName(e) });
        for (try check(a, p, text)) |f| {
            try report.appendSlice(a, f);
            try report.append(a, '\n');
        }
    }
    if (report.items.len > 0) {
        std.debug.print("lock_graphs: {d} finding(s)\n{s}", .{ std.mem.count(u8, report.items, "\n"), report.items });
        std.process.exit(1);
    }
    const f = std.fs.cwd().createFile(argv[1], .{}) catch |e| die("cannot create {s}: {s}", .{ argv[1], @errorName(e) });
    defer f.close();
    try f.deprecatedWriter().print("{{\"version\": 1, \"data\": {{\"status\": \"success\", \"message\": \"lock_graphs: {d} packages checked\"}}}}\n", .{n});
}
