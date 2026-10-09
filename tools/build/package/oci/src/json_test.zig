//! The JSON reader and writer's cases (json.zig).

const std = @import("std");
const C = @import("common.zig");
const J = @import("json.zig");
const F = @import("tar_fixture.zig");

const Value = J.Value;
const eqs = std.testing.expectEqualStrings;

fn s(x: []const u8) Value {
    return .{ .str = x };
}

fn n(x: []const u8) Value {
    return .{ .num = x };
}

fn arr(items: []const Value) Value {
    return .{ .arr = C.a().dupe(Value, items) catch C.oom() };
}

fn obj(members: []const J.Member) Value {
    return .{ .obj = C.a().dupe(J.Member, members) catch C.oom() };
}

fn same(want: Value, got: Value) !void {
    if (!want.eql(got)) {
        std.debug.print("want {s}, got {s}\n", .{ want.toJson(), got.toJson() });
        return error.TestUnexpectedResult;
    }
}

test "json: reads_an_oci_manifest_shape" {
    const v = try F.ok(J.parse(" {\"config\":{\"digest\":\"sha256:ab\",\"size\":12},\"layers\":[{\"digest\":\"d1\"},{\"digest\":\"d2\"}],\"n\":-1.5e+3,\"t\":true,\"z\":null} "));
    try same(s("sha256:ab"), v.get("config").?.get("digest").?);
    const l = v.get("layers").?.asArr().?;
    try std.testing.expectEqual(@as(usize, 2), l.len);
    try eqs("d1", l[0].get("digest").?.asStr().?);
    try eqs("d2", l[1].get("digest").?.asStr().?);
    try same(n("-1.5e+3"), v.get("n").?);
    try same(.{ .boolean = true }, v.get("t").?);
    try same(.nul, v.get("z").?);
    try std.testing.expect(v.get("missing") == null);
}

test "json: decodes_escapes_and_surrogate_pairs" {
    try same(s("a\"\\/\n\u{e9}\u{1F600}"), try F.ok(J.parse("\"a\\\"\\\\\\/\\n\\u00e9\\ud83d\\ude00\"")));
}

test "json: writes_compact_with_sorted_keys_and_reads_it_back" {
    var v = obj(&.{
        .{ .k = "z", .v = arr(&.{ n("1"), n("-2.5e3"), .{ .boolean = true }, .nul }) },
        .{ .k = "a", .v = obj(&.{ .{ .k = "y", .v = s("q\"\\\n\x01/") }, .{ .k = "b", .v = obj(&.{}) } }) },
        .{ .k = "M", .v = s("x") },
    });
    const want = "{\"M\":\"x\",\"a\":{\"b\":{},\"y\":\"q\\\"\\\\\\n\\u0001/\"},\"z\":[1,-2.5e3,true,null]}";
    try eqs(want, v.toJson());
    try eqs(want, (try F.ok(J.parse(want))).toJson());
    try F.ok(v.set("M", s("y")));
    try F.ok(v.set("new", n("2")));
    v.remove("z");
    try std.testing.expect(C.startsWith(v.toJson(), "{\"M\":\"y\",\"a\":"));
    try std.testing.expect(C.endsWith(v.toJson(), "},\"new\":2}"));
    var x = s("x");
    try F.expectFailPrefix(x.set("k", .nul), "");
    // One spelling: lower-case hex below 0x20, DEL as it is.
    try eqs("\"\\u001f\x7f\"", s("\x1f\x7f").toJson());
}

test "json: refuses_what_is_not_json" {
    const bad = [_][]const u8{
        "{\"a\":1,\"a\":2}",
        "{\"a\":1,}",
        "[1 2]",
        "\"\\ud83d\"",
        "\"\\x\"",
        "\"a\nb\"",
        "01",
        "1.",
        "{\"a\":1} x",
        "tru",
        "\"open",
        "",
    };
    for (bad) |b| try F.expectFailPrefix(J.parse(b), "");
    try F.expectFailPrefix(J.parse(C.fmt("{s}{s}", .{ F.rep("[", 65), F.rep("]", 65) })), "");
    _ = try F.ok(J.parse(C.fmt("{s}{s}", .{ F.rep("[", 64), F.rep("]", 64) })));
}

test "json: each_refusal_names_its_reason" {
    const deep = C.fmt("{s}{s}", .{ F.rep("[", 65), F.rep("]", 65) });
    const cases = [_][2][]const u8{
        .{ "{\"a\":1} x", "bytes after the value" },
        .{ "{\"a\" 1}", "expected `:`" },
        .{ "tru", "not a JSON literal" },
        .{ "fals", "not a JSON literal" },
        .{ "nul", "not a JSON literal" },
        .{ "x", "expected a value" },
        .{ "", "expected a value" },
        .{ "[1,]", "expected a value" },
        .{ "[1 2]", "expected `,` or `]`" },
        .{ "{\"a\":1 \"b\":2}", "expected `,` or `}`" },
        .{ "{1:2}", "expected a key" },
        .{ "{\"a\":1,\"a\":2}", "key `a` given twice" },
        .{ "-", "a number without digits" },
        .{ "-x", "a number without digits" },
        .{ "1.", "no digits after `.`" },
        .{ "1e", "no digits in the exponent" },
        .{ "1e+", "no digits in the exponent" },
        .{ "\"\\u12\"", "a short \\u escape" },
        .{ "\"\\u12G4\"", "a bad \\u escape" },
        // Four bytes that are not UTF-8, and a sign before three hex digits.
        .{ "\"\\u\xff\xff\xff\xff\"", "a bad \\u escape" },
        .{ "\"\\u+041\"", "a bad \\u escape" },
        .{ "\"\\u-041\"", "a bad \\u escape" },
        .{ "\"\\ud83d\\u+e00\"", "a bad \\u escape" },
        .{ "\"\\ud83d\"", "a lone high surrogate" },
        .{ "\"\\ud83dx\"", "a lone high surrogate" },
        .{ "\"\\ud83d\\u0041\"", "a bad low surrogate" },
        .{ "\"\\ud800\\ue000\"", "a bad low surrogate" },
        .{ "\"\\ud800\\udbff\"", "a bad low surrogate" },
        .{ "\"\\udc00\"", "a lone surrogate" },
        .{ "\"\\x\"", "an unknown escape" },
        .{ "\"a\x1fb\"", "a control character in a string" },
        .{ "\"\x00\"", "a control character in a string" },
        .{ "\"\xff\"", "a string that is not UTF-8" },
        .{ "\"open", "an unterminated string" },
        .{ "\"a\\", "an unterminated escape" },
        .{ deep, "nested too deep" },
    };
    for (cases) |c| try F.expectFailPrefix(J.parse(c[0]), C.fmt("JSON: {s} at byte ", .{c[1]}));
    // Each boundary's first accepted value.
    try same(s(" ~"), try F.ok(J.parse("\"\x20~\"")));
    try same(s("\u{10000}\u{10FFFF}\u{E000}\u{D7FF}"), try F.ok(J.parse("\"\\ud800\\udc00\\udbff\\udfff\\ue000\\ud7ff\"")));
    for ([_][]const u8{ "0", "-0", "0.5", "1e5", "1E-5", "12.25e+3" }) |x| try same(n(x), try F.ok(J.parse(x)));
    try same(arr(&.{}), try F.ok(J.parse(" \t\r\n[ ] ")));
    try eqs("{\"a\":[1,{}]}", (try F.ok(J.parse("{ \"a\" : [ 1 , { } ] }"))).toJson());
}

test "json: every_escape_literal_and_digit_both_ways" {
    // Every character below 0x20, then the two after it and the ones
    // next to each short escape: each spelled once, and read back.
    var text = C.list(u8);
    for (0..0x20) |b| C.push(u8, &text, @intCast(b));
    C.add(&text, " !\"#\\]/");
    const json = "\"\\u0000\\u0001\\u0002\\u0003\\u0004\\u0005\\u0006\\u0007\\b\\t\\n\\u000b\\f\\r\\u000e\\u000f" ++
        "\\u0010\\u0011\\u0012\\u0013\\u0014\\u0015\\u0016\\u0017\\u0018\\u0019\\u001a\\u001b\\u001c\\u001d\\u001e\\u001f !\\\"#\\\\]/\"";
    try eqs(json, s(text.items).toJson());
    try same(s(text.items), try F.ok(J.parse(json)));
    // Each short escape read on its own; `\/` too.
    const short = [_][2][]const u8{ .{ "\\\"", "\"" }, .{ "\\\\", "\\" }, .{ "\\/", "/" }, .{ "\\b", "\x08" }, .{ "\\f", "\x0c" }, .{ "\\n", "\n" }, .{ "\\r", "\r" }, .{ "\\t", "\t" } };
    for (short) |e| try same(s(e[1]), try F.ok(J.parse(C.fmt("\"{s}\"", .{e[0]}))));
    for ([_][]const u8{ "\\a", "\\c", "\\e", "\\g", "\\m", "\\o", "\\q", "\\s", "\\v", "\\0" }) |e| {
        try F.expectFailContains(J.parse(C.fmt("\"{s}\"", .{e})), "an unknown escape");
    }
    const lits = arr(&.{ .{ .boolean = true }, .{ .boolean = false }, .nul });
    try eqs("[true,false,null]", lits.toJson());
    try same(lits, try F.ok(J.parse("[true,false,null]")));
    // Every digit, in every place a digit may stand.
    for ([_][]const u8{ "1234567890", "9", "-90", "0.0123456789", "1e0", "1E19", "9.9e-09" }) |x| try same(n(x), try F.ok(J.parse(x)));
    // Only space, tab, CR and LF are whitespace.
    for ([_][]const u8{ "\x0b", "\x0c", "\u{a0}" }) |w| try F.expectFailPrefix(J.parse(C.fmt("{s}1", .{w})), "");
}

test "json: depth_counts_nesting_not_containers" {
    // 65 siblings of each shape in one array are nested two deep; each
    // closing bracket, of an empty container too, gives its level back.
    for ([_][]const u8{ "[1]", "{\"a\":1}", "{}", "[]" }) |one| {
        var doc = C.list(u8);
        C.add(&doc, "[");
        for (0..65) |i| {
            if (i > 0) C.add(&doc, ",");
            C.add(&doc, one);
        }
        C.add(&doc, "]");
        const v = try F.ok(J.parse(doc.items));
        try std.testing.expectEqual(@as(usize, 65), v.asArr().?.len);
    }
    // The deepest level reached twice, one after the other.
    const d63 = C.fmt("{s}{s}", .{ F.rep("[", 63), F.rep("]", 63) });
    _ = try F.ok(J.parse(C.fmt("[{s},{s}]", .{ d63, d63 })));
    const d64 = C.fmt("{s}{s}", .{ F.rep("[", 64), F.rep("]", 64) });
    try F.expectFailContains(J.parse(C.fmt("[{s}]", .{d64})), "nested too deep");
}
