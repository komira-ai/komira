//! The JSON reader's cases (json.zig): values, key order, and each refusal
//! with the byte it names.

const std = @import("std");
const C = @import("common.zig");
const J = @import("json.zig");

const eqs = std.testing.expectEqualStrings;
const expect = std.testing.expect;

fn ok(doc: []const u8) !J.Value {
    return J.parse(doc) catch {
        std.debug.print("{s}: {s}\n", .{ doc, C.msg });
        return error.TestUnexpectedResult;
    };
}

fn refused(doc: []const u8, why: []const u8) !void {
    if (J.parse(doc)) |_| {
        std.debug.print("{s}: parsed; want {s}\n", .{ doc, why });
        return error.TestUnexpectedResult;
    } else |_| {
        eqs(why, C.msg) catch |e| {
            std.debug.print("document: {s}\n", .{doc});
            return e;
        };
    }
}

test "json: values_and_order" {
    const v = try ok(" {\"b\": [1, -2.5e1, true, false, null], \"a\": \"x\\n\\u00e9\\ud83d\\ude00\"} ");
    const o = v.obj;
    try std.testing.expectEqual(@as(usize, 2), o.len);
    try eqs("b", o[0].k);
    try eqs("a", o[1].k);
    const arr = o[0].v.arr;
    try std.testing.expectEqual(@as(usize, 5), arr.len);
    try std.testing.expectEqual(@as(f64, 1), arr[0].num);
    try std.testing.expectEqual(@as(f64, -25), arr[1].num);
    try expect(arr[2].boolean);
    try expect(!arr[3].boolean);
    try expect(arr[4] == .nul);
    try eqs("x\n\u{e9}\u{1f600}", o[1].v.str);
    try std.testing.expectEqual(@as(usize, 0), (try ok("{}")).obj.len);
    try std.testing.expectEqual(@as(usize, 0), (try ok("[ ]")).arr.len);
    try eqs("\"\\/\x08\x0c\r\t", (try ok("\"\\\"\\\\\\/\\b\\f\\r\\t\"")).str);
    try eqs("\u{ffff}\u{10ffff}", (try ok("\"\\uFFFF\\udbff\\udfff\"")).str);
    try std.testing.expectEqual(@as(f64, 0), (try ok("0")).num);
    try std.testing.expectEqual(@as(f64, 100), (try ok("1E+2")).num);
    try std.testing.expectEqual(@as(f64, 0.015), (try ok("1.5e-2")).num);
}

test "json: refusals" {
    const cases = [_][2][]const u8{
        .{ "{\"a\":1,\"a\":2}", "byte 10: key 'a' written twice" },
        .{ "NaN", "byte 0: not a JSON value" },
        .{ "Infinity", "byte 0: not a JSON value" },
        .{ "1e999", "byte 5: number out of range" },
        .{ "-1e999", "byte 6: number out of range" },
        .{ "{} x", "byte 3: trailing input after the value" },
        .{ "01", "byte 2: leading zero" },
        .{ "1.", "byte 2: expected a digit after '.'" },
        .{ "1e", "byte 2: expected a digit in the exponent" },
        .{ "-", "byte 1: expected a digit" },
        .{ "[1 2]", "byte 3: expected ',' or ']'" },
        .{ "{\"a\" 1}", "byte 5: expected ':'" },
        .{ "{\"a\":1 \"b\"}", "byte 7: expected ',' or '}'" },
        .{ "{1:2}", "byte 1: expected a key" },
        .{ "\"a", "byte 2: unterminated string" },
        .{ "\"a\\", "byte 3: unterminated string" },
        .{ "\"\\x\"", "byte 3: bad escape" },
        .{ "\"\\u12\"", "byte 3: short \\u escape" },
        .{ "\"\\uzzzz\"", "byte 3: bad \\u escape" },
        .{ "\"\\u+123\"", "byte 3: bad \\u escape" },
        .{ "\"\\u1_23\"", "byte 3: bad \\u escape" },
        .{ "\"\\ud800x\"", "byte 7: unpaired surrogate" },
        .{ "\"\\ud800\\u0041\"", "byte 13: unpaired surrogate" },
        .{ "\"\\udc00\"", "byte 7: unpaired surrogate" },
        .{ "\"\x01\"", "byte 1: control character in a string" },
        .{ "tru", "byte 0: not a JSON value" },
        .{ "", "byte 0: unexpected end of input" },
        .{ "@", "byte 0: not a JSON value" },
    };
    for (cases) |c| try refused(c[0], c[1]);
    const deep = "[" ** 66 ++ "]" ** 66;
    try refused(deep, "byte 65: nesting deeper than 64");
    _ = try ok("[" ** 65 ++ "]" ** 65);
}

test "json: kinds" {
    const docs = [_][]const u8{ "null", "true", "1", "\"s\"", "[]", "{}" };
    const want = [_][]const u8{ "null", "a boolean", "a number", "a string", "an array", "an object" };
    for (docs, want) |d, w| try eqs(w, (try ok(d)).kind());
}
