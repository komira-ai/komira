//! The cases of the publish gate's reader (release/ci/npm_smoke/gate.zig), part of
//! //release/ci/tests:test_npm_smoke.
const std = @import("std");
const lib = @import("npm_smoke_lib");
const t = std.testing;

const gate = lib.gate;

fn expectRefused(text: []const u8, want: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var why: []const u8 = "";
    try t.expectError(error.Refused, gate.parse(arena.allocator(), &why, "release/npm_publish.txt", text));
    try t.expectEqualStrings(want, why);
}

fn parsed(text: []const u8) !gate.Gate {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var why: []const u8 = "";
    return gate.parse(arena.allocator(), &why, "release/npm_publish.txt", text);
}

test "the gate is off or on, with comments and blank lines around the one line" {
    try t.expectEqual(gate.Gate.off, try parsed("publish: off\n"));
    try t.expectEqual(gate.Gate.on, try parsed("publish: on\n"));
    try t.expectEqual(gate.Gate.off, try parsed("# the owner's go flips this line\n\npublish: off\n# after\n"));
    // no final line feed
    try t.expectEqual(gate.Gate.on, try parsed("publish: on"));
}

test "a gate that is not one off or on line is refused, naming the line, so it never reads as on" {
    try expectRefused("", "release/npm_publish.txt holds no `publish: off` or `publish: on` line");
    try expectRefused("# only a comment\n", "release/npm_publish.txt holds no `publish: off` or `publish: on` line");
    try expectRefused("publish: yes\n", "release/npm_publish.txt:1: \"publish: yes\" is neither `publish: off` nor `publish: on` (nor a comment)");
    try expectRefused("# x\npublish: On\n", "release/npm_publish.txt:2: \"publish: On\" is neither `publish: off` nor `publish: on` (nor a comment)");
    try expectRefused("publish: on \n", "release/npm_publish.txt:1: \"publish: on \" is neither `publish: off` nor `publish: on` (nor a comment)");
    try expectRefused("publish: on\r\n", "release/npm_publish.txt:1: \"publish: on\r\" is neither `publish: off` nor `publish: on` (nor a comment)");
    try expectRefused(" # indented\npublish: off\n", "release/npm_publish.txt:1: \" # indented\" is neither `publish: off` nor `publish: on` (nor a comment)");
    // a merge that kept both sides
    try expectRefused("publish: off\npublish: on\n", "release/npm_publish.txt:2: a second publish line: the file says off or on once");
    try expectRefused("publish: off\npublish: off\n", "release/npm_publish.txt:2: a second publish line: the file says off or on once");
}
