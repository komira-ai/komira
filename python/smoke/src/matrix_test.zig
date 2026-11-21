//! The cases of the list of supported Pythons as the `matrix` command reads it (matrix.zig): a JSON list of exact
//! versions gives the job matrix of a platform as one line of JSON, in list order, with that platform's runner;
//! text that is not a JSON list of strings, a version that is not `3.<minor>.<micro>`, a minor twice or out of
//! order, and an empty list are refused, each naming the file and, for an entry, its place.
const std = @import("std");
const lib = @import("pypi_smoke_lib");
const t = std.testing;
const m = lib.matrix;

const PATH = "pythons.json";
const LINUX = m.platformNamed("linux-x86_64").?;
const MACOS = m.platformNamed("macos-arm64").?;

fn versionsOf(a: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var why: []const u8 = "";
    return m.parse(a, &why, PATH, text) catch |e| {
        std.debug.print("refused: {s}\n", .{why});
        return e;
    };
}

fn refusal(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var why: []const u8 = "";
    _ = m.parse(a, &why, PATH, text) catch |e| {
        if (e == error.Refused) return why;
        return e;
    };
    return error.TestExpectedRefusal;
}

test "a list gives its versions in order and the job matrix of a platform as one line of JSON" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const vs = try versionsOf(a, "[\"3.11.17\", \"3.14.8\"]\n");
    try t.expectEqual(@as(usize, 2), vs.len);
    try t.expectEqualStrings("3.11.17", vs[0]);
    try t.expectEqualStrings("3.14.8", vs[1]);
    try t.expectEqualStrings(
        "{\"include\":[{\"platform\":\"linux-x86_64\",\"python\":\"3.11.17\",\"runner\":\"ubuntu-24.04\"},{\"platform\":\"linux-x86_64\",\"python\":\"3.14.8\",\"runner\":\"ubuntu-24.04\"}]}",
        try m.json(a, LINUX, vs),
    );
    try t.expectEqualStrings(
        "{\"include\":[{\"platform\":\"macos-arm64\",\"python\":\"3.11.17\",\"runner\":\"macos-15\"},{\"platform\":\"macos-arm64\",\"python\":\"3.14.8\",\"runner\":\"macos-15\"}]}",
        try m.json(a, MACOS, vs),
    );
}

test "the bounds of a version's numbers are accepted: one digit, zero, and three digits" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const vs = try versionsOf(a, "[\"3.0.0\",\"3.9.999\",\"3.999.1\"]");
    try t.expectEqual(@as(usize, 3), vs.len);
    try t.expectEqualStrings("3.999.1", vs[2]);
}

test "text that is not a JSON list of strings is refused naming the file" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    for ([_][]const u8{ "", "linux-x86_64\t3.13\n", "{\"linux-x86_64\":[\"3.13.16\"]}", "[3.13]", "[\"3.13.16\"", "\"3.13.16\"" }) |text| {
        try t.expectEqualStrings(PATH ++ " is not a JSON list of strings", try refusal(a, text));
    }
}

test "a version that is not 3.<minor>.<micro> is refused naming its entry" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const bad = [_][]const u8{ "", "3", "3.13", "3.13.", "3.13.1.2", "3.013.1", "3.13.01", "3.1000.1", "py3.13.1", "2.7.18", "3.x.1", "3.13.1 ", "3.13.1rc1" };
    for (bad) |v| {
        const text = try std.fmt.allocPrint(a, "[\"3.11.17\",\"{s}\"]", .{v});
        try t.expectEqualStrings(try std.fmt.allocPrint(a, "entry 2 of " ++ PATH ++ " is '{s}', not `3.<minor>.<micro>`", .{v}), try refusal(a, text));
    }
}

test "a minor twice, or out of order, is refused naming the entry and the one before it" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("entry 3 of " ++ PATH ++ " is '3.12.14', after '3.12.15': each minor once, oldest first", try refusal(a, "[\"3.11.17\",\"3.12.15\",\"3.12.14\"]"));
    try t.expectEqualStrings("entry 2 of " ++ PATH ++ " is '3.11.17', after '3.13.16': each minor once, oldest first", try refusal(a, "[\"3.13.16\",\"3.11.17\"]"));
}

test "an empty list is refused: its job matrix would have no entry" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    for ([_][]const u8{ "[]", " [ ]\n" }) |text| {
        try t.expectEqualStrings(PATH ++ " names no Python: its jobs would be none", try refusal(a, text));
    }
}

test "a platform is named exactly, and every platform has a hosted runner" {
    try t.expect(m.platformNamed("linux-x86_64") != null);
    try t.expect(m.platformNamed("macos-arm64") != null);
    try t.expect(m.platformNamed("linux_x86_64") == null);
    try t.expect(m.platformNamed("") == null);
    for (m.platforms) |p| try t.expect(p.runner.len != 0);
}
