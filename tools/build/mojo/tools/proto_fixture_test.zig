//! Unit tests of proto_fixture.zig's parts: the hex format, the schema read
//! from protoc's descriptor-set text, the top-level wire walk, the decode checks
//! of legs 2 and 5, and the diff of leg 1. The whole tool, with a real protoc, is
//! run by proto_fixture_testdata (its `proto_fixture_case` targets plant one
//! defect per leg) and every proto_fixture_check in the repository.
const std = @import("std");
const F = @import("proto_fixture.zig");
const t = std.testing;

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(t.allocator);
}

test "hexdigits: white space dropped, A-F lowercased" {
    var ar = arena();
    defer ar.deinit();
    try t.expectEqualStrings("0a1bff", try F.hexdigits(ar.allocator(), " 0A\t1B\r\nFf\n"));
    try t.expectEqualStrings("", try F.hexdigits(ar.allocator(), " \n\t"));
}

test "unhex: bytes, or why not" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualSlices(u8, &.{ 0x00, 0x0a, 0xff }, (try F.unhex(a, "00 0A\nfF")).bytes);
    try t.expectEqualStrings("holds no bytes", (try F.unhex(a, " \n")).why);
    try t.expectEqualStrings("holds an odd number of hex digits (3)", (try F.unhex(a, "0a1")).why);
    try t.expectEqualStrings("holds a character that is neither a hex digit nor white space", (try F.unhex(a, "0a 0g")).why);
    try t.expectEqualStrings("holds a character that is neither a hex digit nor white space", (try F.unhex(a, "0a-0b")).why);
}

test "tohex: lowercase, 64 digits a line, a line break at the end" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("0aff\n", try F.tohex(a, &.{ 0x0a, 0xff }));
    try t.expectEqualStrings("\n", try F.tohex(a, &.{}));
    const bytes = [_]u8{0xab} ** 33;
    const got = try F.tohex(a, &bytes);
    try t.expectEqual(@as(usize, 64 + 1 + 2 + 1), got.len);
    try t.expectEqual(@as(u8, '\n'), got[64]);
    const exact = [_]u8{0x01} ** 32;
    const g2 = try F.tohex(a, &exact);
    try t.expectEqual(@as(usize, 65), g2.len);
    try t.expectEqual(@as(u8, '\n'), g2[64]);
}

test "txtpbRoot: the first line names the root" {
    try t.expectEqualStrings("a.b.C", F.txtpbRoot("# proto-message: a.b.C\nid: 1\n").?);
    try t.expect(F.txtpbRoot("# proto-message:  a.b.C\n") == null);
    try t.expect(F.txtpbRoot("# proto-message: a.b C\n") == null);
    try t.expect(F.txtpbRoot("# proto-message: \n") == null);
    try t.expect(F.txtpbRoot("id: 1\n# proto-message: a.B\n") == null);
    try t.expect(F.txtpbRoot("") == null);
    try t.expectEqualStrings("A", F.txtpbRoot("# proto-message: A").?);
}

test "firstLine, dropFirstLine, head, indent" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("one\n", F.firstLine("one\ntwo\n"));
    try t.expectEqualStrings("only", F.firstLine("only"));
    try t.expectEqualStrings("two\n", F.dropFirstLine("one\ntwo\n"));
    try t.expectEqualStrings("", F.dropFirstLine("one"));
    try t.expectEqualStrings("a\nb\n", F.head("a\nb\nc\n", 2));
    try t.expectEqualStrings("a\nb", F.head("a\nb", 5));
    try t.expectEqualStrings("        x\n        y\n", try F.indent(a, "x\ny\n"));
    try t.expectEqualStrings("        x\n", try F.indent(a, "x"));
    try t.expectEqualStrings("", try F.indent(a, ""));
}

const descriptor_text =
    "file {\n" ++
    "  name: \"example/fixture/v1/selftest.proto\"\n" ++
    "  package: \"example.fixture.v1\"\n" ++
    "  message_type {\n" ++
    "    name: \"Sample\"\n" ++
    "    field {\n      name: \"id\"\n      number: 1\n      label: LABEL_OPTIONAL\n      type: TYPE_INT64\n    }\n" ++
    "    field {\n      name: \"values\"\n      number: 2\n      label: LABEL_REPEATED\n      type: TYPE_INT32\n    }\n" ++
    "    field {\n      name: \"kind\"\n      number: 3\n      label: LABEL_OPTIONAL\n      type: TYPE_ENUM\n      type_name: \".example.fixture.v1.Kind\"\n    }\n" ++
    "    field {\n      name: \"inner\"\n      number: 4\n      label: LABEL_OPTIONAL\n      type: TYPE_MESSAGE\n      type_name: \".example.fixture.v1.Sample.Inner\"\n      options {\n        deprecated: true\n      }\n    }\n" ++
    "    nested_type {\n      name: \"Inner\"\n      field {\n        name: \"kind\"\n        number: 1\n        label: LABEL_OPTIONAL\n        type: TYPE_ENUM\n        type_name: \".example.fixture.v1.Kind\"\n      }\n    }\n" ++
    "  }\n" ++
    "  enum_type {\n    name: \"Kind\"\n    value {\n      name: \"KIND_A\"\n      number: 0\n    }\n  }\n" ++
    "}\n" ++
    "file {\n  name: \"other.proto\"\n  message_type {\n    name: \"NoPackage\"\n    field {\n      name: \"x\"\n      number: 1\n      label: LABEL_OPTIONAL\n      type: TYPE_STRING\n    }\n  }\n}\n";

test "parseSchema: messages with their package and nesting, fields with their rows" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const s = try F.parseSchema(a, descriptor_text);
    try t.expectEqual(@as(usize, 3), s.messages.len);
    try t.expectEqualStrings("example.fixture.v1.Sample", s.messages[0]);
    try t.expectEqualStrings("example.fixture.v1.Sample.Inner", s.messages[1]);
    try t.expectEqualStrings("NoPackage", s.messages[2]);
    try t.expectEqual(@as(usize, 6), s.fields.len);
    try t.expectEqual(@as(usize, 6), F.fieldBlocks(descriptor_text));
    try t.expect(F.rowsComplete(s));
    const kind = s.fields[2];
    try t.expectEqualStrings("example.fixture.v1.Sample", kind.msg);
    try t.expectEqualStrings("kind", kind.name);
    try t.expectEqualStrings("3", kind.num);
    try t.expectEqualStrings("LABEL_OPTIONAL", kind.label);
    try t.expectEqualStrings("TYPE_ENUM", kind.typ);
    try t.expectEqualStrings("example.fixture.v1.Kind", kind.type_name);
    try t.expectEqualStrings("-", s.fields[0].type_name);
    try t.expectEqualStrings("example.fixture.v1.Sample.Inner", s.fields[4].msg);
    try t.expectEqualStrings("NoPackage", s.fields[5].msg);
    // The table text: messages, then fields.
    const table = try F.tableText(a, s);
    try t.expect(std.mem.startsWith(u8, table, "M example.fixture.v1.Sample\nM example.fixture.v1.Sample.Inner\nM NoPackage\nF example.fixture.v1.Sample id 1 LABEL_OPTIONAL TYPE_INT64 -\n"));
}

test "rowsComplete: an incomplete row is refused" {
    const good = F.Field{ .msg = "m.M", .name = "f", .num = "1", .label = "LABEL_OPTIONAL", .typ = "TYPE_INT32", .type_name = "-" };
    try t.expect(F.rowsComplete(.{ .messages = &.{"m.M"}, .fields = &.{good} }));
    var bad = good;
    bad.num = "";
    try t.expect(!F.rowsComplete(.{ .messages = &.{"m.M"}, .fields = &.{bad} }));
    bad = good;
    bad.num = "1x";
    try t.expect(!F.rowsComplete(.{ .messages = &.{"m.M"}, .fields = &.{bad} }));
    bad = good;
    bad.typ = "INT32";
    try t.expect(!F.rowsComplete(.{ .messages = &.{"m.M"}, .fields = &.{bad} }));
    bad = good;
    bad.name = "";
    try t.expect(!F.rowsComplete(.{ .messages = &.{"m.M"}, .fields = &.{bad} }));
}

fn tagsOf(a: std.mem.Allocator, bytes: []const u8) ![]F.Tag {
    return F.topTags(a, bytes);
}

test "topTags: varints, length-delimited values stepped over, fixed widths, a group skipped whole" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    // id (1) = 1, id (1) = 150, name (2) "abc", name (2) "de", f64 (3), f32 (4), a group 5 { 1: 7 }, 1: 2
    const bytes = [_]u8{
        0x08, 0x01, 0x08, 0x96, 0x01,
        0x12, 0x03, 'a', 'b', 'c', 0x12, 0x02, 'd', 'e',
        0x19, 1, 2, 3, 4, 5, 6, 7, 8,
        0x25, 1, 2, 3, 4,
        0x2b, 0x08, 0x07, 0x2c,
        0x08, 0x02,
    };
    const tags = try tagsOf(a, &bytes);
    try t.expectEqual(@as(usize, 5), tags.len);
    try t.expectEqual(@as(u64, 1), tags[0].num);
    try t.expectEqual(@as(usize, 3), tags[0].count);
    try t.expectEqual(@as(u64, 2), tags[1].num);
    try t.expectEqual(@as(usize, 2), tags[1].count);
    try t.expectEqual(@as(u64, 3), tags[2].num);
    try t.expectEqual(@as(u64, 4), tags[3].num);
    try t.expectEqual(@as(u64, 5), tags[4].num);
    try t.expectEqual(@as(usize, 1), tags[4].count);
}

test "topTags: bytes that are not a message stop the walk" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    // a length that runs past the end: nothing counted for it
    const trunc = try tagsOf(a, &.{ 0x08, 0x01, 0x12, 0x09, 'a' });
    try t.expectEqual(@as(usize, 1), trunc.len);
    try t.expectEqual(@as(u64, 1), trunc[0].num);
    // wire type 7 is not a wire type
    try t.expectEqual(@as(usize, 0), (try tagsOf(a, &.{0x0f})).len);
    // a varint that never ends
    try t.expectEqual(@as(usize, 0), (try tagsOf(a, &.{ 0x08, 0xff, 0xff })).len);
    try t.expectEqual(@as(usize, 0), (try tagsOf(a, &.{})).len);
}

test "duplicates: a singular field of the root written twice; a repeated one is fine" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const s = try F.parseSchema(a, descriptor_text);
    const tags = [_]F.Tag{ .{ .num = 1, .count = 2 }, .{ .num = 2, .count = 3 }, .{ .num = 3, .count = 1 }, .{ .num = 9, .count = 4 } };
    try t.expectEqualStrings("id (field 1) written 2 times\n", try F.duplicates(a, s, "example.fixture.v1.Sample", &tags));
    try t.expectEqualStrings("", try F.duplicates(a, s, "NoPackage", tags[2..]));
}

test "unknownFields: bare field numbers at any depth, with line numbers" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const decoded = "id: 150\ninner {\n  9: 1\n}\n99 {\n}\n99: 2\n  kind: KIND_A\nname: \"7: x\"\n";
    try t.expectEqualStrings("3:  9: 1\n5:99 {\n7:99: 2\n", try F.unknownFields(a, decoded));
    try t.expectEqualStrings("", try F.unknownFields(a, "id: 1\nkind: 3\n"));
}

test "walkEnums: a number where a name should be is found; a line the schema cannot place is reported" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const s = try F.parseSchema(a, descriptor_text);
    const root = "example.fixture.v1.Sample";
    const ok = try F.walkEnums(a, s, root, "id: 5\nkind: KIND_A\ninner {\n  kind: KIND_A\n}\n");
    try t.expectEqualStrings("", ok.unplaced);
    try t.expectEqualStrings("", ok.enums);
    const bad = try F.walkEnums(a, s, root, "kind: 99\ninner {\n  kind: -1\n}\nid: 7\n");
    try t.expectEqualStrings("", bad.unplaced);
    try t.expectEqualStrings("1: kind: 99    (example.fixture.v1.Sample.kind, example.fixture.v1.Kind)\n3:   kind: -1    (example.fixture.v1.Sample.Inner.kind, example.fixture.v1.Kind)\n", bad.enums);
    const lost = try F.walkEnums(a, s, root, "mystery: 1\nthing {\n  kind: 99\n}\n[ext.x] {\n  kind: 99\n}\nkind: KIND_A\n");
    try t.expectEqualStrings("1: `mystery` in example.fixture.v1.Sample\n2: `thing` in example.fixture.v1.Sample\n", lost.unplaced);
    // Nothing inside an unplaced or extension block is judged.
    try t.expectEqualStrings("", lost.enums);
}

test "unifiedDiff: null when equal; the changed lines with context otherwise" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try t.expect((try F.unifiedDiff(a, "x", "y", "a\nb\n", "a\nb\n")) == null);
    const d = (try F.unifiedDiff(a, "want.txtpb", "protoc --decode", "id: 1\nname: \"a\"\nkind: K\n", "id: 1\nname: \"b\"\nkind: K\n")).?;
    try t.expectEqualStrings(
        "--- want.txtpb\n+++ protoc --decode\n@@ -1,3 +1,3 @@\n id: 1\n-name: \"a\"\n+name: \"b\"\n kind: K\n",
        d,
    );
}

test "unifiedDiff: added and removed lines, and two hunks far apart" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const add = (try F.unifiedDiff(a, "a", "b", "1\n2\n", "1\n2\n3\n")).?;
    try t.expect(std.mem.indexOf(u8, add, "+3\n") != null);
    try t.expect(std.mem.indexOf(u8, add, "@@ -1,2 +1,3 @@\n") != null);
    const rm = (try F.unifiedDiff(a, "a", "b", "1\n2\n3\n", "1\n3\n")).?;
    try t.expect(std.mem.indexOf(u8, rm, "-2\n") != null);
    var left = std.ArrayList(u8).empty;
    var right = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        try left.writer(a).print("line {d}\n", .{i});
        try right.writer(a).print("line {d}\n", .{i});
    }
    // Change line 2 and line 27.
    const l = try std.mem.replaceOwned(u8, a, left.items, "line 2\n", "two\n");
    const l2 = try std.mem.replaceOwned(u8, a, l, "line 27\n", "twenty-seven\n");
    const two = (try F.unifiedDiff(a, "a", "b", right.items, l2)).?;
    try t.expectEqual(@as(usize, 2), std.mem.count(u8, two, "@@ -"));
    // Everything different: no common lines at all.
    const all = (try F.unifiedDiff(a, "a", "b", "x\n", "y\n")).?;
    try t.expectEqualStrings("--- a\n+++ b\n@@ -1,1 +1,1 @@\n-x\n+y\n", all);
}

test "exitCodeOf" {
    try t.expectEqual(@as(u8, 2), F.exitCodeOf(.{ .Exited = 2 }));
    try t.expectEqual(@as(u8, 137), F.exitCodeOf(.{ .Signal = 9 }));
}
