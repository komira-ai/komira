//! The `[file_name]` of the wheel rule (wheel.bzl), //:wheel_file_name_cases: a `zig_test` run as a
//! build action over two fixtures the rule built at the test stamp (BUCK, `wheel_fixture` and
//! `wheel_fixture_macosx_tag`). Each fixture's `[file_name]` and its `[release]` wheel are the test's
//! data, under KOMIRA_TEST_WORK/<linux|macosx>.file_name and .whl.
//!
//! What it holds: the file name is one line, exactly the name written out below (the distribution,
//! the stamp's version and the platform row's tag); and the wheel the same target wrote agrees with
//! it: its one `.dist-info` directory is `<distribution>-<version>.dist-info`, its METADATA's Version
//! is the name's version and its WHEEL's Tag is the name's tag. A name that does not agree with the
//! wheel (the other fixture's) is refused, so the agreement is read and not assumed.

const std = @import("std");
const diag = @import("native_policy").diag;
const zip = @import("zip.zig");
const t = std.testing;

fn readData(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    const work = try std.process.getEnvVarOwned(a, "KOMIRA_TEST_WORK");
    return std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ work, name }), 1 << 26);
}

/// Why the wheel `bytes` is not the wheel the one-line `name_file` names, or null when it is.
fn disagreement(a: std.mem.Allocator, name_file: []const u8, bytes: []const u8) !?[]const u8 {
    if (!std.mem.endsWith(u8, name_file, ".whl\n") or std.mem.indexOfScalar(u8, name_file, '\n').? != name_file.len - 1)
        return "the file name is not one line ending in .whl";
    const name = name_file[0 .. name_file.len - ".whl\n".len];
    const first = std.mem.indexOfScalar(u8, name, '-') orelse return "the file name has no version";
    const second = std.mem.indexOfScalarPos(u8, name, first + 1, '-') orelse return "the file name has no tag";
    const dist = name[0..first];
    const version = name[first + 1 .. second];
    const tag = name[second + 1 ..];

    var d = diag.Diag{};
    const members = try zip.read(a, &d, bytes);
    const info = try std.fmt.allocPrint(a, "{s}-{s}.dist-info/", .{ dist, version });
    var metadata: ?[]const u8 = null;
    var wheel: ?[]const u8 = null;
    for (members) |m| {
        if (std.mem.endsWith(u8, m.name, ".dist-info/METADATA") or std.mem.endsWith(u8, m.name, ".dist-info/WHEEL")) {
            if (!std.mem.startsWith(u8, m.name, info)) return try std.fmt.allocPrint(a, "the wheel's dist-info member {s} is not under {s}", .{ m.name, info });
            if (std.mem.endsWith(u8, m.name, "METADATA")) metadata = m.data else wheel = m.data;
        }
    }
    const meta = metadata orelse return "the wheel has no METADATA";
    const whl = wheel orelse return "the wheel has no WHEEL";
    if (std.mem.indexOf(u8, meta, try std.fmt.allocPrint(a, "\nVersion: {s}\n", .{version})) == null)
        return try std.fmt.allocPrint(a, "METADATA's Version is not the file name's {s}", .{version});
    if (std.mem.indexOf(u8, whl, try std.fmt.allocPrint(a, "\nTag: {s}\n", .{tag})) == null)
        return try std.fmt.allocPrint(a, "WHEEL's Tag is not the file name's {s}", .{tag});
    return null;
}

const LINUX = "komira_wheel_fixture-0.1.999999999-py3-none-manylinux_2_34_x86_64.whl\n";
const MACOSX = "komira_wheel_fixture-0.1.999999999-py3-none-macosx_11_0_arm64.whl\n";

test "the file name of each fixture is the one line of its distribution, the stamp's version and its platform's tag" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings(LINUX, try readData(a, "linux.file_name"));
    try t.expectEqualStrings(MACOSX, try readData(a, "macosx.file_name"));
}

test "each fixture's wheel agrees with its file name: dist-info directory, Version and Tag" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expect((try disagreement(a, try readData(a, "linux.file_name"), try readData(a, "linux.whl"))) == null);
    try t.expect((try disagreement(a, try readData(a, "macosx.file_name"), try readData(a, "macosx.whl"))) == null);
}

test "a file name that does not agree with the wheel is refused, naming what differs" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mac = try readData(a, "macosx.whl");
    try t.expectEqualStrings("WHEEL's Tag is not the file name's py3-none-manylinux_2_34_x86_64", (try disagreement(a, LINUX, mac)).?);
    try t.expectEqualStrings("the wheel's dist-info member komira_wheel_fixture-0.1.999999999.dist-info/METADATA is not under komira_wheel_fixture-0.1.1.dist-info/", (try disagreement(a, "komira_wheel_fixture-0.1.1-py3-none-macosx_11_0_arm64.whl\n", mac)).?);
    try t.expectEqualStrings("the wheel's dist-info member komira_wheel_fixture-0.1.999999999.dist-info/METADATA is not under other-0.1.999999999.dist-info/", (try disagreement(a, "other-0.1.999999999-py3-none-macosx_11_0_arm64.whl\n", mac)).?);
    try t.expectEqualStrings("the file name is not one line ending in .whl", (try disagreement(a, MACOSX ++ "\n", mac)).?);
}
