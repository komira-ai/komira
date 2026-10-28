//! lock_graphs: the action behind lock_graphs.bxl.
//!
//! usage: lock_graphs <result.json> (<package> <mojo> <mopm.lock> <held> <dir>)...
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
//!
//! The same run holds the package's system libraries to its lock. A library the
//! package opens by its bare name at run time is declared in `mopm.toml`
//! (`[native-dependencies] <name> = { ..., mode = "load" }`, of the package or of
//! a path dependency) and, from a mopm that writes `system_libs`, pinned in
//! `mopm.lock` for every platform subdir the lock records a toolchain for;
//! buildrules gives a test run the pinned files, and a lock without the pins
//! leaves the test run to find a library on the machine. <dir> is the package's
//! directory (its `mopm.toml`, its `src/`, and the directories of its path
//! dependencies relative to it). A finding is a declared load with no pins, a
//! subdir with none, and a library opened in the sources that no manifest declares.

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
    /// The package's directory (see the header); "" when system libraries are not checked.
    dir: []const u8 = "",
};

/// True when a mopm.toml text declares a native dependency with `mode = "load"` in its `[native-dependencies]` table.
pub fn declaresLoad(text: []const u8) bool {
    var in_native = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_native = std.mem.eql(u8, line, "[native-dependencies]");
            continue;
        }
        if (!in_native) continue;
        var squeezed: [512]u8 = undefined;
        var n: usize = 0;
        for (line) |c| {
            if (c == ' ' or c == '\t') continue;
            if (n == squeezed.len) break;
            squeezed[n] = c;
            n += 1;
        }
        if (std.mem.indexOf(u8, squeezed[0..n], "mode=\"load\"") != null) return true;
    }
    return false;
}

/// True when a Mojo source text opens a shared library at run time: a non-comment line that calls `OwnedDLHandle(`, `DLHandle(` or `dlopen(`.
pub fn opensLibrary(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.indexOf(u8, line, "OwnedDLHandle(") != null or std.mem.indexOf(u8, line, "DLHandle(") != null or std.mem.indexOf(u8, line, "dlopen(") != null) return true;
    }
    return false;
}

/// The findings of the system libraries of one package. `lock_text` is its mopm.lock; `declared` says whether the manifest of the package or of
/// a path dependency declares a load; `opens` whether a source of the package opens a library; `mojo` and `label` as in `Pkg`.
pub fn checkSystemLibs(a: Alloc, label: []const u8, mojo: []const u8, lock_text: []const u8, declared: bool, opens: bool) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    if (opens and !declared) {
        try out.append(a, try std.fmt.allocPrint(a, "{s}: a source of the package opens a shared library at run time, but no `[native-dependencies]` entry of its mopm.toml (or of a path dependency) has `mode = \"load\"`, so its lock pins no system library and a test run would find one on the machine: declare the library and run `mopm lock` and `buildrules mojo sync`", .{label}));
    }
    if (!declared) return try out.toOwnedSlice(a);
    var why: []const u8 = "";
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, lock_text, .{}) catch return try out.toOwnedSlice(a);
    if (root != .object) return try out.toOwnedSlice(a);
    var subdirs = std.ArrayList([]const u8).empty;
    try subdirs.append(a, "linux-64");
    if (try recorded(a, lock_text, mojo, &why)) |extra| try subdirs.appendSlice(a, extra);
    const libs = root.object.get("system_libs") orelse {
        try out.append(a, try std.fmt.allocPrint(a, "{s}: its mopm.toml declares a native dependency with `mode = \"load\"` but its mopm.lock has no `system_libs`, so its tests run with whatever library the machine has (a lock written by a mopm older than 0.0.83 pins none): run `mopm lock` with mopm 0.0.83 or later and `buildrules mojo sync`", .{label}));
        return try out.toOwnedSlice(a);
    };
    for (subdirs.items) |sd| {
        const ok = libs == .object and blk: {
            const list = libs.object.get(sd) orelse break :blk false;
            break :blk list == .array and list.array.items.len > 0;
        };
        if (!ok)
            try out.append(a, try std.fmt.allocPrint(a, "{s}: its mopm.lock `system_libs` pins no library for {s}, which its lock records a toolchain for, so a test run on that platform would use the machine's library: run `mopm lock` and `buildrules mojo sync`", .{ label, sd }));
    }
    return try out.toOwnedSlice(a);
}

/// The path dependencies a lock records (`"source": "path"`), as paths relative to the package.
fn pathDeps(a: Alloc, lock_text: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, lock_text, .{}) catch return try out.toOwnedSlice(a);
    if (root != .object) return try out.toOwnedSlice(a);
    const pk = root.object.get("packages") orelse return try out.toOwnedSlice(a);
    if (pk != .array) return try out.toOwnedSlice(a);
    for (pk.array.items) |row| {
        if (row != .object) continue;
        const src = row.object.get("source") orelse continue;
        const path = row.object.get("path") orelse continue;
        if (src == .string and path == .string and std.mem.eql(u8, src.string, "path")) try out.append(a, path.string);
    }
    return try out.toOwnedSlice(a);
}

/// Reads the package directory `dir`: whether its manifest or a path dependency's declares a load, and whether a source opens a library.
pub fn scanPackage(a: Alloc, dir: []const u8, lock_text: []const u8, declared: *bool, opens: *bool) !void {
    const own = try std.fmt.allocPrint(a, "{s}/mopm.toml", .{dir});
    const own_text = try std.fs.cwd().readFileAlloc(a, own, 1 << 22);
    if (declaresLoad(own_text)) declared.* = true;
    for (try pathDeps(a, lock_text)) |rel| {
        const dep = try std.fmt.allocPrint(a, "{s}/{s}/mopm.toml", .{ dir, rel });
        const text = std.fs.cwd().readFileAlloc(a, dep, 1 << 22) catch continue;
        if (declaresLoad(text)) declared.* = true;
    }
    const src = try std.fmt.allocPrint(a, "{s}/src", .{dir});
    var d = std.fs.cwd().openDir(src, .{ .iterate = true }) catch return;
    defer d.close();
    var walker = try d.walk(a);
    while (try walker.next()) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.path, ".mojo")) continue;
        const text = try d.readFileAlloc(a, e.path, 1 << 24);
        if (opensLibrary(text)) {
            opens.* = true;
            return;
        }
    }
}

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
    if (argv.len < 2 or (argv.len - 2) % 5 != 0) die("usage: lock_graphs <result.json> (<package> <mojo> <mopm.lock> <held> <dir>)...", .{});
    const n = (argv.len - 2) / 5;
    if (n == 0) die("checked nothing: no package given", .{});
    var report = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const base = 2 + 5 * i;
        const p = Pkg{ .label = argv[base], .mojo = argv[base + 1], .lock_path = argv[base + 2], .held_csv = argv[base + 3], .dir = argv[base + 4] };
        const text = std.fs.cwd().readFileAlloc(a, p.lock_path, 1 << 26) catch |e| die("{s}: cannot read {s}: {s}", .{ p.label, p.lock_path, @errorName(e) });
        for (try check(a, p, text)) |f| {
            try report.appendSlice(a, f);
            try report.append(a, '\n');
        }
        var declared = false;
        var opens = false;
        scanPackage(a, p.dir, text, &declared, &opens) catch |e| die("{s}: cannot read the package directory {s}: {s}", .{ p.label, p.dir, @errorName(e) });
        for (try checkSystemLibs(a, p.label, p.mojo, text, declared, opens)) |f| {
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
