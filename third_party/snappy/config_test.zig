//! The cases of snappy's per-cpu config.h, //third_party/snappy:config_cases: a `zig_test` run as a
//! build action. The subjects are the two headers, snappy's own cmake/config.h.in (the list of macros
//! CMake writes) and the BUCK file's select (the zig_test's `data`, under KOMIRA_TEST_WORK).
//!
//! Why a test and not only a build: the macOS platform is not in the pull request check (the check set
//! holds no macOS build), so a config.h that switched x86 intrinsics on for an arm64 compile, which is a
//! compile error on that platform (`emmintrin.h: This header is only meant to be used on x86`), would
//! pass every Linux build. These cases read the headers instead.
//! What the cases catch:
//!  - a macro of config.h.in missing from a config (an undefined macro is 0 in an `#if`, so a missing
//!    feature macro silently turns the feature off), or a macro in a config that config.h.in does not have
//!    (stale after a pin moved), or a value other than 0 or 1;
//!  - config_arm64.h with an x86 feature on (SSSE3, X86_CRC32, BMI2), or without NEON; the arm64 compile
//!    is zig's generic CPU, which has no CRC32 extension, so NEON_CRC32 must be 0;
//!  - config_x86_64.h with a NEON feature on, or an x86 feature off (it is the x86-64-v3 compile);
//!  - the two configs differing in a macro that does not depend on the cpu (the sys/ headers, builtins,
//!    endianness), which the select by cpu alone assumes;
//!  - the BUCK file selecting a config for the wrong cpu, or no longer selecting by cpu.

const std = @import("std");
const t = std.testing;

const Define = struct { name: []const u8, value: []const u8 };

// The macros that say what the cpu has. Every other macro must be equal in the two configs.
const x86_features = [_][]const u8{ "SNAPPY_HAVE_SSSE3", "SNAPPY_HAVE_X86_CRC32", "SNAPPY_HAVE_BMI2" };
const arm_features = [_][]const u8{ "SNAPPY_HAVE_NEON", "SNAPPY_HAVE_NEON_CRC32" };

fn readData(ar: std.mem.Allocator, name: []const u8) ![]const u8 {
    const w = try std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK");
    return std.fs.cwd().readFileAlloc(ar, try std.fs.path.join(ar, &.{ w, name }), 1 << 20);
}

/// The `#define NAME VALUE` lines of a header (the include guard has no value and is left out).
fn defines(ar: std.mem.Allocator, text: []const u8) ![]Define {
    var out = std.ArrayList(Define).empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const l = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, l, "#define ")) continue;
        var it = std.mem.tokenizeAny(u8, l["#define ".len..], " \t");
        const name = it.next() orelse continue;
        const value = it.next() orelse continue;
        try out.append(ar, .{ .name = name, .value = value });
    }
    return out.items;
}

/// The names of the `#cmakedefine01 NAME` lines of config.h.in: what CMake writes.
fn templateNames(ar: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    const key = "#cmakedefine01 ";
    while (lines.next()) |line| {
        const l = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, l, key)) continue;
        try out.append(ar, std.mem.trim(u8, l[key.len..], " \t"));
    }
    return out.items;
}

fn find(ds: []const Define, name: []const u8) ?[]const u8 {
    for (ds) |d| {
        if (std.mem.eql(u8, d.name, name)) return d.value;
    }
    return null;
}

fn listed(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

fn expectValue(ds: []const Define, file: []const u8, name: []const u8, want: []const u8) !void {
    const got = find(ds, name) orelse {
        std.debug.print("{s}: {s} is not defined\n", .{ file, name });
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("{s}: {s} is {s}, want {s}\n", .{ file, name, got, want });
        return error.TestUnexpectedResult;
    }
}

const Subjects = struct {
    arm: []Define,
    x86: []Define,
    template: [][]const u8,
};

fn subjects(ar: std.mem.Allocator) !Subjects {
    return .{
        .arm = try defines(ar, try readData(ar, "config_arm64.h")),
        .x86 = try defines(ar, try readData(ar, "config_x86_64.h")),
        .template = try templateNames(ar, try readData(ar, "config.h.in")),
    };
}

test "each config defines exactly the macros of snappy's config.h.in, as 0 or 1" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const s = try subjects(arena.allocator());
    // The template is the ground truth: a pin that stops listing macros would make this vacuous.
    try t.expect(s.template.len >= 20);
    const files = [_]struct { name: []const u8, ds: []const Define }{
        .{ .name = "config_arm64.h", .ds = s.arm },
        .{ .name = "config_x86_64.h", .ds = s.x86 },
    };
    for (files) |f| {
        for (s.template) |name| {
            const v = find(f.ds, name) orelse {
                std.debug.print("{s}: {s} (config.h.in) is not defined\n", .{ f.name, name });
                return error.TestUnexpectedResult;
            };
            if (!std.mem.eql(u8, v, "0") and !std.mem.eql(u8, v, "1")) {
                std.debug.print("{s}: {s} is {s}, want 0 or 1\n", .{ f.name, name, v });
                return error.TestUnexpectedResult;
            }
        }
        for (f.ds) |d| {
            if (!listed(s.template, d.name)) {
                std.debug.print("{s}: {s} is not a macro of config.h.in\n", .{ f.name, d.name });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "config_arm64.h: NEON on, no x86 feature, no CRC32 extension" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const s = try subjects(arena.allocator());
    for (x86_features) |name| try expectValue(s.arm, "config_arm64.h", name, "0");
    try expectValue(s.arm, "config_arm64.h", "SNAPPY_HAVE_NEON", "1");
    // zig's generic arm64 CPU (the macOS arm64 compile and the linux-arm64 row) has no CRC32
    // extension: <arm_acle.h> declares no __crc32cw, and 1 here would not compile.
    try expectValue(s.arm, "config_arm64.h", "SNAPPY_HAVE_NEON_CRC32", "0");
    try expectValue(s.arm, "config_arm64.h", "SNAPPY_IS_BIG_ENDIAN", "0");
}

test "config_x86_64.h: the x86-64-v3 features on, no NEON" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const s = try subjects(arena.allocator());
    for (x86_features) |name| try expectValue(s.x86, "config_x86_64.h", name, "1");
    for (arm_features) |name| try expectValue(s.x86, "config_x86_64.h", name, "0");
    try expectValue(s.x86, "config_x86_64.h", "SNAPPY_IS_BIG_ENDIAN", "0");
}

test "the two configs differ only in the macros that say what the cpu has" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const s = try subjects(arena.allocator());
    for (s.arm) |d| {
        if (listed(&x86_features, d.name) or listed(&arm_features, d.name)) continue;
        try expectValue(s.x86, "config_x86_64.h", d.name, d.value);
    }
}

fn selectLine(text: []const u8, cpu: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"prelude//cpu/constraints:") != null and
            std.mem.indexOf(u8, line, cpu) != null) return line;
    }
    return null;
}

test "BUCK selects config_arm64 for arm64 and config_x86_64 for x86_64, by cpu" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const buck = try readData(ar, "BUCK");
    const arm = selectLine(buck, "constraints:arm64\"") orelse return error.NoArm64Key;
    const x86 = selectLine(buck, "constraints:x86_64\"") orelse return error.NoX86Key;
    try t.expect(std.mem.indexOf(u8, arm, ":config_arm64[config_arm64.h]") != null);
    try t.expect(std.mem.indexOf(u8, arm, "x86") == null);
    try t.expect(std.mem.indexOf(u8, x86, ":config_x86_64[config_x86_64.h]") != null);
    try t.expect(std.mem.indexOf(u8, x86, "arm64") == null);
}
