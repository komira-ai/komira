//! dlopen_probe: load an installed shared library by path with RTLD_NOW and
//! say where its runtime libraries came from.
//!
//! usage: dlopen_probe --prefix P --lib NAME --out MARKER
//!            [--symbol S]... [--version-symbol S --min-version N]
//!            [--runtime LIB]... [--require LIB]...
//!
//! Loads P/lib/NAME with RTLD_NOW (an unresolved symbol fails here, not at
//! the first call), looks up each --symbol, and, with --version-symbol, calls
//! that `int32_t (*)(void)` and requires at least N. It then reads the
//! loader's own record of the process (/proc/self/maps): every mapped file
//! whose name starts with a --runtime library must lie under P, and every
//! --require library must be mapped there. A library the loader took from
//! anywhere else (the host's, the build's) is refused, so a pass means the
//! prefix alone was enough.
//!
//! LD_LIBRARY_PATH must be unset or empty: with it set, the load does not show
//! what the library's own run path finds. Exit status 2 on any refusal, and
//! MARKER is written only on a pass.

const std = @import("std");

extern "c" fn dlopen(path: [*:0]const u8, flags: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
extern "c" fn dlerror() ?[*:0]const u8;

/// RTLD_NOW of glibc on linux.
const RTLD_NOW: c_int = 2;

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("dlopen_probe: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

/// The path of a /proc/<pid>/maps line (`addr perms offset dev inode path`),
/// or null for an anonymous mapping.
fn mappedPath(line: []const u8) ?[]const u8 {
    var at: usize = 0;
    var field: usize = 0;
    while (field < 5) : (field += 1) {
        while (at < line.len and line[at] == ' ') at += 1;
        while (at < line.len and line[at] != ' ') at += 1;
    }
    while (at < line.len and line[at] == ' ') at += 1;
    if (at >= line.len or line[at] != '/') return null;
    return line[at..];
}

fn baseName(path: []const u8) []const u8 {
    return path[(std.mem.lastIndexOfScalar(u8, path, '/') orelse 0) + 1 ..];
}

fn under(path: []const u8, prefix: []const u8) bool {
    return path.len > prefix.len and std.mem.startsWith(u8, path, prefix) and path[prefix.len] == '/';
}

/// Why the process's mappings do not show a load from `prefix` alone, or null.
/// Every mapped file whose name starts with a `runtime` library must be under
/// `prefix`, and each `require`d library must be mapped there.
pub fn refusal(alloc: std.mem.Allocator, maps: []const u8, prefix: []const u8, runtime: []const []const u8, require: []const []const u8) !?[]const u8 {
    const seen = try alloc.alloc(bool, require.len);
    @memset(seen, false);
    var lines = std.mem.splitScalar(u8, maps, '\n');
    while (lines.next()) |line| {
        const path = mappedPath(line) orelse continue;
        const base = baseName(path);
        for (runtime) |r| {
            if (!std.mem.startsWith(u8, base, r)) continue;
            if (!under(path, prefix)) return try std.fmt.allocPrint(alloc, "{s} was loaded from {s}, outside the prefix {s}", .{ r, path, prefix });
        }
        for (require, 0..) |r, i| {
            if (std.mem.startsWith(u8, base, r) and under(path, prefix)) seen[i] = true;
        }
    }
    for (require, seen) |r, ok| {
        if (!ok) return try std.fmt.allocPrint(alloc, "{s} is not mapped from the prefix {s}", .{ r, prefix });
    }
    return null;
}

/// The mapped files under `prefix`, one path per line, once each.
fn loadedUnder(alloc: std.mem.Allocator, maps: []const u8, prefix: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var last: []const u8 = "";
    var lines = std.mem.splitScalar(u8, maps, '\n');
    while (lines.next()) |line| {
        const path = mappedPath(line) orelse continue;
        if (!under(path, prefix) or std.mem.eql(u8, path, last)) continue;
        last = path;
        try out.writer(alloc).print("loaded {s}\n", .{path});
    }
    return out.toOwnedSlice(alloc);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const argv = try std.process.argsAlloc(alloc);

    var prefix_arg: ?[]const u8 = null;
    var lib: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var version_symbol: ?[]const u8 = null;
    var min_version: i32 = 0;
    var symbols = std.ArrayList([]const u8).empty;
    var runtime = std.ArrayList([]const u8).empty;
    var require = std.ArrayList([]const u8).empty;
    var i: usize = 1;
    while (i < argv.len) : (i += 2) {
        if (i + 1 >= argv.len) fail("{s} needs a value", .{argv[i]});
        const k = argv[i];
        const v: []const u8 = argv[i + 1];
        if (std.mem.eql(u8, k, "--prefix")) {
            prefix_arg = v;
        } else if (std.mem.eql(u8, k, "--lib")) {
            lib = v;
        } else if (std.mem.eql(u8, k, "--out")) {
            out_path = v;
        } else if (std.mem.eql(u8, k, "--symbol")) {
            try symbols.append(alloc, v);
        } else if (std.mem.eql(u8, k, "--version-symbol")) {
            version_symbol = v;
        } else if (std.mem.eql(u8, k, "--min-version")) {
            min_version = std.fmt.parseInt(i32, v, 10) catch fail("--min-version `{s}` is not an integer", .{v});
        } else if (std.mem.eql(u8, k, "--runtime")) {
            try runtime.append(alloc, v);
        } else if (std.mem.eql(u8, k, "--require")) {
            try require.append(alloc, v);
        } else fail("unknown argument {s}", .{k});
    }
    const prefix_in = prefix_arg orelse fail("missing --prefix", .{});
    const name = lib orelse fail("missing --lib", .{});
    const out = out_path orelse fail("missing --out", .{});
    if (std.mem.indexOfScalar(u8, name, '/') != null) fail("--lib `{s}` is not a file name", .{name});

    if (std.process.getEnvVarOwned(alloc, "LD_LIBRARY_PATH")) |v| {
        if (v.len != 0) fail("LD_LIBRARY_PATH is set; the load would not show what the library's run path finds", .{});
    } else |_| {}

    const prefix = try std.fs.cwd().realpathAlloc(alloc, prefix_in);
    const path = try std.fmt.allocPrintSentinel(alloc, "{s}/lib/{s}", .{ prefix, name }, 0);
    const handle = dlopen(path.ptr, RTLD_NOW) orelse
        fail("dlopen({s}, RTLD_NOW): {s}", .{ path, if (dlerror()) |e| std.mem.span(e) else "no reason given" });

    for (symbols.items) |s| {
        const z = try alloc.dupeZ(u8, s);
        if (dlsym(handle, z.ptr) == null) fail("{s} has no symbol {s}", .{ path, s });
    }
    var version_line: []const u8 = "";
    if (version_symbol) |s| {
        const z = try alloc.dupeZ(u8, s);
        const f: *const fn () callconv(.c) i32 = @ptrCast(dlsym(handle, z.ptr) orelse fail("{s} has no symbol {s}", .{ path, s }));
        const v = f();
        if (v < min_version) fail("{s}() returned {d}, below {d}", .{ s, v, min_version });
        version_line = try std.fmt.allocPrint(alloc, "{s} {d}\n", .{ s, v });
    }

    const maps = try std.fs.cwd().readFileAlloc(alloc, "/proc/self/maps", 1 << 24);
    if (try refusal(alloc, maps, prefix, runtime.items, require.items)) |why| fail("{s}", .{why});

    var marker = std.ArrayList(u8).empty;
    try marker.writer(alloc).print("dlopen RTLD_NOW ok {s}\n{s}", .{ path, version_line });
    try marker.appendSlice(alloc, try loadedUnder(alloc, maps, prefix));
    try std.fs.cwd().writeFile(.{ .sub_path = out, .data = marker.items });
    std.debug.print("dlopen_probe: {s} ok\n", .{path});
}

// ---- tests ---------------------------------------------------------------
//
// Each test names the defect it catches. They run as a build action
// (`:dlopen_probe_unit`), and the probe is not built unless they pass.

const testing = std.testing;

const maps_ok =
    "7f0000000000-7f0000001000 r-xp 00000000 08:01 11 /env/lib/libkomira.so\n" ++
    "7f0000002000-7f0000003000 r-xp 00000000 08:01 12 /env/lib/libKGENCompilerRTShared.so\n" ++
    "7f0000004000-7f0000005000 r-xp 00000000 08:01 13 /env/lib/libstdc++.so.6\n" ++
    "7f0000006000-7f0000007000 r-xp 00000000 08:01 14 /usr/lib/x86_64-linux-gnu/libc.so.6\n" ++
    "7f0000008000-7f0000009000 rw-p 00000000 00:00 0 \n" ++
    "7f000000a000-7f000000b000 rw-p 00000000 00:00 0 [heap]\n";

const test_runtime = [_][]const u8{ "libKGENCompilerRTShared.so", "libstdc++.so.6" };

test "a load whose runtime came from the prefix passes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try refusal(arena.allocator(), maps_ok, "/env", &test_runtime, &.{ "libkomira.so", "libKGENCompilerRTShared.so" });
    try testing.expectEqual(@as(?[]const u8, null), r);
}

test "a runtime library loaded from outside the prefix is refused, by any file name it has" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // The host's libstdc++ carries its full version in its file name.
    const host = maps_ok ++ "7f000000c000-7f000000d000 r-xp 00000000 08:01 15 /usr/lib/x86_64-linux-gnu/libstdc++.so.6.0.30\n";
    const r = (try refusal(alloc, host, "/env", &test_runtime, &.{})).?;
    try testing.expect(std.mem.indexOf(u8, r, "libstdc++.so.6 was loaded from /usr/lib/x86_64-linux-gnu/libstdc++.so.6.0.30") != null);
    // A prefix that merely starts with the same characters is not the prefix.
    const sibling = "7f0000002000-7f0000003000 r-xp 00000000 08:01 12 /env2/lib/libKGENCompilerRTShared.so\n";
    try testing.expect((try refusal(alloc, sibling, "/env", &test_runtime, &.{})) != null);
}

test "a required library that is not mapped from the prefix is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = (try refusal(arena.allocator(), maps_ok, "/env", &test_runtime, &.{"libMSupportGlobals.so"})).?;
    try testing.expect(std.mem.indexOf(u8, r, "libMSupportGlobals.so is not mapped from the prefix /env") != null);
}

test "an anonymous mapping and a pseudo-path name no library" {
    try testing.expectEqual(@as(?[]const u8, null), mappedPath("7f0000008000-7f0000009000 rw-p 00000000 00:00 0 "));
    try testing.expectEqual(@as(?[]const u8, null), mappedPath("7f000000a000-7f000000b000 rw-p 00000000 00:00 0 [heap]"));
    try testing.expectEqualStrings("/env/lib/libkomira.so", mappedPath("7f0000000000-7f0000001000 r-xp 00000000 08:01 11 /env/lib/libkomira.so").?);
}
