//! Parsers of buck2's client output.
const std = @import("std");
const text = @import("text.zig");

/// `buck2 audit execution-platform-resolution` as `<target> <platform>`
/// lines, `<target> FAILED` for a target that failed to configure. Its
/// output holds, per target, a header `<label> (<configuration>):` and
/// then `  Execution platform: <label>` or `  Failed to configure ...`.
pub fn resolution(a: std.mem.Allocator, out: []const u8) ![][]const u8 {
    var res = std.ArrayList([]const u8).init(a);
    var target: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (line.len > 0 and line[0] != ' ' and std.mem.endsWith(u8, line, "):") and text.contains(line, " (")) {
            target = line[0 .. std.mem.indexOfScalar(u8, line, ' ') orelse line.len];
            continue;
        }
        const t = target orelse continue;
        const ep = "  Execution platform: ";
        if (std.mem.startsWith(u8, line, ep)) {
            var rest = std.mem.tokenizeScalar(u8, line[ep.len..], ' ');
            try res.append(try std.fmt.allocPrint(a, "{s} {s}", .{ t, rest.next() orelse "" }));
            target = null;
        } else if (std.mem.startsWith(u8, line, "  Failed to configure")) {
            try res.append(try std.fmt.allocPrint(a, "{s} FAILED", .{t}));
            target = null;
        }
    }
    return res.toOwnedSlice();
}

/// The value of `key` in `buck2 audit config --json <key>` output
/// (`{"<key>": "<value>"}`), or null.
pub fn configValue(json: []const u8, key: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    const want = std.fmt.bufPrint(&buf, "\"{s}\"", .{key}) catch return null;
    const at = std.mem.indexOf(u8, json, want) orelse return null;
    var i = at + want.len;
    while (i < json.len and (json[i] == ' ' or json[i] == ':')) : (i += 1) {}
    if (i >= json.len or json[i] != '"') return null;
    const end = std.mem.indexOfScalarPos(u8, json, i + 1, '"') orelse return null;
    return json[i + 1 .. end];
}

/// The names of the targets `buck2 targets <pkg>:` printed (the part after
/// the last `:` of each line), sorted.
pub fn targetNames(a: std.mem.Allocator, out: []const u8) ![][]const u8 {
    var res = std.ArrayList([]const u8).init(a);
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        const l = std.mem.trim(u8, line, " \r");
        if (l.len == 0) continue;
        const c = std.mem.lastIndexOfScalar(u8, l, ':') orelse continue;
        try res.append(l[c + 1 ..]);
    }
    const s = try res.toOwnedSlice();
    text.sort(s);
    return s;
}

/// Executors of the execution platforms `buck2 audit providers <platforms>`
/// printed: one `executor_config=` per platform, each `executor: Local(` or
/// `executor: Remote(`.
pub const Executors = struct { platforms: usize, local: usize, remote: usize };

pub fn executors(out: []const u8) Executors {
    return .{
        .platforms = text.count(out, "executor_config="),
        .local = text.count(out, "executor: Local("),
        .remote = text.count(out, "executor: Remote("),
    };
}

/// Whether `out` holds the line `want` exactly.
pub fn hasLine(out: []const u8, want: []const u8) bool {
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| if (std.mem.eql(u8, std.mem.trimRight(u8, line, "\r"), want)) return true;
    return false;
}

/// Whether `out` holds `<label>#<hex>`: a target configured for the
/// platform `label` (`buck2 cquery` prints `<target> (<platform>#<hash>)`).
pub fn configuredFor(out: []const u8, label: []const u8) bool {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, out, pos, label)) |i| {
        pos = i + label.len;
        if (pos < out.len and out[pos] == '#') {
            var j = pos + 1;
            while (j < out.len and std.ascii.isHex(out[j])) : (j += 1) {}
            if (j > pos + 1) return true;
        }
    }
    return false;
}

/// The `golden_config_hash` of `row` in table.bzl's text, or null.
pub fn goldenHash(table: []const u8, row: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    const head = std.fmt.bufPrint(&buf, "\n    \"{s}\": {{", .{row}) catch return null;
    const at = std.mem.indexOf(u8, table, head) orelse return null;
    const key = "\"golden_config_hash\": \"";
    const k = std.mem.indexOfPos(u8, table, at, key) orelse return null;
    const end = std.mem.indexOfPos(u8, table, at + head.len, "\n    \"") orelse table.len;
    if (k > end) return null;
    const v = k + key.len;
    const q = std.mem.indexOfScalarPos(u8, table, v, '"') orelse return null;
    if (q - v != 16) return null;
    return table[v..q];
}
