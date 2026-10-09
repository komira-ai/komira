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

test "json: boundaries_that_pass" {
    // Each end of the \u escape's hex ranges; the last code point below the
    // surrogates and the first above them; the lowest surrogate pair; a space,
    // the first byte that is not a control character; the largest double,
    // written just below the point where it would round to infinity.
    // Every case runs; each one refused or read otherwise is named.
    const cases = [_][2][]const u8{
        .{ "\"\\uaaaa\"", "\u{aaaa}" },
        .{ "\"\\uAAAA\"", "\u{aaaa}" },
        .{ "\"\\ud7ff\"", "\u{d7ff}" },
        .{ "\"\\ue000\"", "\u{e000}" },
        .{ "\"\\ud800\\udc00\"", "\u{10000}" },
        .{ "\" \"", " " },
    };
    var bad: usize = 0;
    for (cases) |c| {
        const got = J.parse(c[0]) catch {
            std.debug.print("{s}: refused: {s}\n", .{ c[0], C.msg });
            bad += 1;
            continue;
        };
        if (got != .str or !C.eql(got.str, c[1])) {
            std.debug.print("{s}: not read as {s}\n", .{ c[0], c[1] });
            bad += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), bad);
    try std.testing.expectEqual(std.math.floatMax(f64), (try ok("1.7976931348623158e308")).num);
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
        // Just past each boundary: the first double past the largest (it rounds
        // to infinity); four hex digits that end the input; the byte next to
        // each end of the hex ranges; a high surrogate followed by the code
        // unit below and the one above the low surrogates; a low surrogate
        // that a second one follows, and the highest low surrogate alone; the
        // last control character.
        .{ "1.7976931348623159e308", "byte 22: number out of range" },
        .{ "\"\\u0041", "byte 7: unterminated string" },
        .{ "\"\\u000/\"", "byte 3: bad \\u escape" },
        .{ "\"\\u000:\"", "byte 3: bad \\u escape" },
        .{ "\"\\u000`\"", "byte 3: bad \\u escape" },
        .{ "\"\\u000g\"", "byte 3: bad \\u escape" },
        .{ "\"\\u000@\"", "byte 3: bad \\u escape" },
        .{ "\"\\u000G\"", "byte 3: bad \\u escape" },
        .{ "\"\\ud800\\udbff\"", "byte 13: unpaired surrogate" },
        .{ "\"\\ud800\\ue000\"", "byte 13: unpaired surrogate" },
        .{ "\"\\udc00\\udc00\"", "byte 7: unpaired surrogate" },
        .{ "\"\\udfff\"", "byte 7: unpaired surrogate" },
        .{ "\"\x1f\"", "byte 1: control character in a string" },
    };
    // Every case runs; each one that parses or fails otherwise is named.
    var bad: usize = 0;
    for (cases) |c| refused(c[0], c[1]) catch {
        bad += 1;
    };
    try std.testing.expectEqual(@as(usize, 0), bad);
    const deep = "[" ** 66 ++ "]" ** 66;
    try refused(deep, "byte 65: nesting deeper than 64");
    _ = try ok("[" ** 65 ++ "]" ** 65);
}

test "json: kinds" {
    const docs = [_][]const u8{ "null", "true", "1", "\"s\"", "[]", "{}" };
    const want = [_][]const u8{ "null", "a boolean", "a number", "a string", "an array", "an object" };
    for (docs, want) |d, w| try eqs(w, (try ok(d)).kind());
}
