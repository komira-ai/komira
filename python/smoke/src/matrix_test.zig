//! The cases of the list of supported Pythons (matrix.zig): a list with comments and empty lines gives its rows
//! in file order and the job matrix as one line of JSON; a row that is not two fields, a platform whose wheel is
//! not built on every merge, a Python that is not `3.<minor>`, a CRLF line end and a row given twice are refused
//! naming the line; a list with no row for the platform is refused, since its job matrix would have no entry.
const std = @import("std");
const lib = @import("pypi_smoke_lib");
const t = std.testing;
const m = lib.matrix;

const PATH = "python/supported_pythons.tsv";
const LINUX = m.platformNamed("linux-x86_64").?;

fn rowsOf(a: std.mem.Allocator, text: []const u8) ![]m.Row {
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

test "a list with comments and empty lines gives its rows in file order and the job matrix as one line of JSON" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const rows = try rowsOf(a, "# platform\tpython\n\nlinux-x86_64\t3.14\n# the oldest\nlinux-x86_64\t3.13\n");
    try t.expectEqual(@as(usize, 2), rows.len);
    try t.expectEqualStrings("3.14", rows[0].python);
    try t.expectEqual(@as(usize, 3), rows[0].line);
    try t.expectEqualStrings("3.13", rows[1].python);
    try t.expectEqual(@as(usize, 5), rows[1].line);
    var why: []const u8 = "";
    const own = try m.forPlatform(a, &why, PATH, rows, LINUX);
    try t.expectEqualStrings(
        "{\"include\":[{\"platform\":\"linux-x86_64\",\"python\":\"3.14\",\"runner\":\"ubuntu-24.04\"},{\"platform\":\"linux-x86_64\",\"python\":\"3.13\",\"runner\":\"ubuntu-24.04\"}]}",
        try m.json(a, own),
    );
}

test "the bounds of a Python's minor are accepted: one digit, zero, and three digits" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const rows = try rowsOf(a, "linux-x86_64\t3.0\nlinux-x86_64\t3.9\nlinux-x86_64\t3.999\n");
    try t.expectEqual(@as(usize, 3), rows.len);
    try t.expectEqualStrings("3.999", rows[2].python);
}

test "a row that is not two fields separated by a tab is refused naming its line" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("line 2 of " ++ PATH ++ " is 'linux-x86_64', not `<platform><TAB><python>`", try refusal(a, "# c\nlinux-x86_64\n"));
    try t.expectEqualStrings("line 1 of " ++ PATH ++ " is 'linux-x86_64 3.13', not `<platform><TAB><python>`", try refusal(a, "linux-x86_64 3.13\n"));
    try t.expectEqualStrings("line 1 of " ++ PATH ++ " is 'linux-x86_64\t3.13\tubuntu-24.04', not `<platform><TAB><python>`", try refusal(a, "linux-x86_64\t3.13\tubuntu-24.04\n"));
    // a line of spaces is no empty line
    try t.expectEqualStrings("line 1 of " ++ PATH ++ " is '  ', not `<platform><TAB><python>`", try refusal(a, "  \nlinux-x86_64\t3.13\n"));
}

test "a platform whose wheel no workflow builds on every merge is refused, naming the platforms there are" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("line 2 of " ++ PATH ++ " names the platform 'macos-arm64', whose wheel no workflow builds and installs on every merge (the platforms: linux-x86_64)", try refusal(a, "linux-x86_64\t3.13\nmacos-arm64\t3.13\n"));
    try t.expectEqualStrings("line 1 of " ++ PATH ++ " names the platform 'Linux-x86_64', whose wheel no workflow builds and installs on every merge (the platforms: linux-x86_64)", try refusal(a, "Linux-x86_64\t3.13\n"));
    try t.expectEqualStrings("line 1 of " ++ PATH ++ " names the platform '', whose wheel no workflow builds and installs on every merge (the platforms: linux-x86_64)", try refusal(a, "\t3.13\n"));
}

test "a Python that is not 3.<minor> is refused naming its line, a CRLF line end included" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const bad = [_][]const u8{ "", "3", "3.", "3.13.1", "3.013", "3.1000", "py3.13", "2.7", "3.x", "3.13 ", "3.13\r" };
    for (bad) |v| {
        const text = try std.fmt.allocPrint(a, "linux-x86_64\t{s}\n", .{v});
        try t.expectEqualStrings(try std.fmt.allocPrint(a, "line 1 of " ++ PATH ++ " names the Python '{s}', not `3.<minor>`", .{v}), try refusal(a, text));
    }
}

test "a row given twice is refused naming both lines" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("line 4 of " ++ PATH ++ " repeats line 1 (linux-x86_64, Python 3.13)", try refusal(a, "linux-x86_64\t3.13\nlinux-x86_64\t3.14\n# again\nlinux-x86_64\t3.13\n"));
}

test "a list with no row for the platform is refused: its job matrix would have no entry" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    for ([_][]const u8{ "", "# platform\tpython\n", "\n\n" }) |text| {
        const rows = try rowsOf(a, text);
        try t.expectEqual(@as(usize, 0), rows.len);
        var why: []const u8 = "";
        try t.expectError(error.Refused, m.forPlatform(a, &why, PATH, rows, LINUX));
        try t.expectEqualStrings(PATH ++ " has no row for the platform linux-x86_64: its user test would have no job", why);
    }
}

test "a platform is named exactly, and every platform has a hosted runner" {
    try t.expect(m.platformNamed("linux-x86_64") != null);
    try t.expect(m.platformNamed("linux_x86_64") == null);
    try t.expect(m.platformNamed("") == null);
    for (m.platforms) |p| try t.expect(p.runner.len != 0);
}
