//! rules_parity: rules.bzl (read by affected.bxl) and rules.txt (read by the
//! Mojo selector) hold the same widen and inert rows, in the same order, with
//! the same reasons. A BXL script cannot read a text file, so the rows are
//! written twice until the Mojo selector is gone; this test is what keeps the
//! two copies one rule. `universe` rows are not compared: the BXL selector's
//! check set is deliberately narrower (rules.bzl says why).
//!
//! The files are zig_test `data`, under KOMIRA_TEST_WORK.

const std = @import("std");

const a = std.testing.allocator;

const Rules = struct {
    widen: std.ArrayList([2][]const u8) = .empty,
    inert: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *Rules) void {
        self.widen.deinit(a);
        self.inert.deinit(a);
    }
};

/// The widen and inert rows of rules.txt: `widen <pattern> <reason>`, `inert <pattern>`.
/// Slices point into `text`.
fn parseTxt(text: []const u8) !Rules {
    var r = Rules{};
    errdefer r.deinit();
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var words = std.mem.tokenizeAny(u8, line, " \t");
        const kind = words.next().?;
        const pattern = words.next() orelse continue;
        if (std.mem.eql(u8, kind, "widen")) {
            try r.widen.append(a, .{ pattern, std.mem.trim(u8, words.rest(), " \t") });
        } else if (std.mem.eql(u8, kind, "inert")) {
            try r.inert.append(a, pattern);
        }
    }
    return r;
}

/// The text between the first and the second `"` of `s`, or null.
fn quoted(s: []const u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, s, '"') orelse return null;
    const rest = s[open + 1 ..];
    const close = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..close];
}

/// The rows of the WIDEN and INERT lists of rules.bzl: one row a line,
/// `("pattern", "reason"),` and `"pattern",`.
fn parseBzl(text: []const u8) !Rules {
    var r = Rules{};
    errdefer r.deinit();
    const Section = enum { none, widen, inert };
    var section: Section = .none;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "WIDEN = [")) {
            section = .widen;
        } else if (std.mem.startsWith(u8, line, "INERT = [")) {
            section = .inert;
        } else if (std.mem.eql(u8, line, "]")) {
            section = .none;
        } else if (section == .widen and line.len > 0 and line[0] == '(') {
            const pattern = quoted(line).?;
            const after = line[1 + std.mem.indexOfScalar(u8, line, '"').? + pattern.len + 1 ..];
            try r.widen.append(a, .{ pattern, quoted(after).? });
        } else if (section == .inert and line.len > 0 and line[0] == '"') {
            try r.inert.append(a, quoted(line).?);
        }
    }
    return r;
}

/// The first difference between two rule sets, or null.
fn firstDifference(x: Rules, y: Rules, buf: []u8) !?[]const u8 {
    if (x.widen.items.len != y.widen.items.len) {
        return try std.fmt.bufPrint(buf, "{d} widen rows in rules.txt, {d} in rules.bzl", .{ x.widen.items.len, y.widen.items.len });
    }
    for (x.widen.items, y.widen.items, 0..) |p, q, i| {
        if (!std.mem.eql(u8, p[0], q[0])) return try std.fmt.bufPrint(buf, "widen row {d}: pattern `{s}` vs `{s}`", .{ i, p[0], q[0] });
        if (!std.mem.eql(u8, p[1], q[1])) return try std.fmt.bufPrint(buf, "widen row {d} (`{s}`): reason `{s}` vs `{s}`", .{ i, p[0], p[1], q[1] });
    }
    if (x.inert.items.len != y.inert.items.len) {
        return try std.fmt.bufPrint(buf, "{d} inert rows in rules.txt, {d} in rules.bzl", .{ x.inert.items.len, y.inert.items.len });
    }
    for (x.inert.items, y.inert.items, 0..) |p, q, i| {
        if (!std.mem.eql(u8, p, q)) return try std.fmt.bufPrint(buf, "inert row {d}: `{s}` vs `{s}`", .{ i, p, q });
    }
    return null;
}

fn readWork(sub: []const u8) ![]u8 {
    const w = std.process.getEnvVarOwned(a, "KOMIRA_TEST_WORK") catch |e| {
        std.debug.print("KOMIRA_TEST_WORK is not in the environment (the zig_test's data)\n", .{});
        return e;
    };
    defer a.free(w);
    const path = try std.fs.path.join(a, &.{ w, sub });
    defer a.free(path);
    return std.fs.cwd().readFileAlloc(a, path, 1 << 20);
}

test "the shipped rules.txt and rules.bzl are the same widen and inert rows" {
    const txt = try readWork("rules.txt");
    defer a.free(txt);
    const bzl = try readWork("rules.bzl");
    defer a.free(bzl);
    var x = try parseTxt(txt);
    defer x.deinit();
    var y = try parseBzl(bzl);
    defer y.deinit();
    // Not vacuous: the rows the build system cannot be without are read.
    try std.testing.expect(x.widen.items.len >= 7);
    try std.testing.expect(x.inert.items.len >= 4);
    var buf: [512]u8 = undefined;
    if (try firstDifference(x, y, &buf)) |why| {
        std.debug.print("rules.txt and rules.bzl differ: {s}\n", .{why});
        return error.RulesDiffer;
    }
}

const txt_sample =
    \\# comment
    \\universe //...
    \\widen .buckconfig       the configuration
    \\widen tools/build/**    the build system
    \\inert *.md
    \\
;

const bzl_sample =
    \\WIDEN = [
    \\    (".buckconfig", "the configuration"),
    \\    ("tools/build/**", "the build system"),
    \\]
    \\
    \\INERT = [
    \\    "*.md",
    \\]
    \\
;

test "the parsers read one row a line and the comparison names the first difference" {
    var buf: [512]u8 = undefined;
    var x = try parseTxt(txt_sample);
    defer x.deinit();
    var y = try parseBzl(bzl_sample);
    defer y.deinit();
    try std.testing.expectEqual(@as(usize, 2), x.widen.items.len);
    try std.testing.expectEqual(@as(usize, 1), y.inert.items.len);
    try std.testing.expect((try firstDifference(x, y, &buf)) == null);
}

test "a row changed in one copy is a difference" {
    var buf: [512]u8 = undefined;
    var x = try parseTxt(txt_sample);
    defer x.deinit();

    var other_pattern = try parseBzl(
        \\WIDEN = [
        \\    (".buckconfig", "the configuration"),
        \\    ("tools/**", "the build system"),
        \\]
        \\INERT = [
        \\    "*.md",
        \\]
    );
    defer other_pattern.deinit();
    try std.testing.expect((try firstDifference(x, other_pattern, &buf)) != null);

    var other_reason = try parseBzl(
        \\WIDEN = [
        \\    (".buckconfig", "a different reason"),
        \\    ("tools/build/**", "the build system"),
        \\]
        \\INERT = [
        \\    "*.md",
        \\]
    );
    defer other_reason.deinit();
    try std.testing.expect((try firstDifference(x, other_reason, &buf)) != null);

    var missing_row = try parseBzl(
        \\WIDEN = [
        \\    (".buckconfig", "the configuration"),
        \\]
        \\INERT = [
        \\    "*.md",
        \\]
    );
    defer missing_row.deinit();
    try std.testing.expect((try firstDifference(x, missing_row, &buf)) != null);

    var extra_inert = try parseBzl(
        \\WIDEN = [
        \\    (".buckconfig", "the configuration"),
        \\    ("tools/build/**", "the build system"),
        \\]
        \\INERT = [
        \\    "*.md",
        \\    "LICENSE",
        \\]
    );
    defer extra_inert.deinit();
    try std.testing.expect((try firstDifference(x, extra_inert, &buf)) != null);
}
