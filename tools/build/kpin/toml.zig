//! The TOML subset pins.toml is written in: `[a.b.c]` table headers,
//! `key = "string"` and `key = 123` lines, `#` comments, blank lines. No
//! escapes, arrays, inline tables or multi-line strings: a file using one is
//! refused with its line number, not half understood.

const std = @import("std");
const Diag = @import("diag.zig").Diag;

pub const Value = union(enum) {
    string: []const u8,
    int: u64,
};

pub const Entry = struct {
    key: []const u8,
    value: Value,
    line: usize,
};

pub const Table = struct {
    path: []const u8,
    line: usize,
    entries: std.ArrayListUnmanaged(Entry) = .{},

    pub fn get(self: *const Table, key: []const u8) ?Entry {
        for (self.entries.items) |e| if (std.mem.eql(u8, e.key, key)) return e;
        return null;
    }
};

fn keyChar(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '-' or c == '_';
}

fn validSegment(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!keyChar(c)) return false;
    return true;
}

/// The line without its comment, trimmed. A `#` inside a string is text.
pub fn stripComment(line: []const u8) []const u8 {
    var in_str = false;
    for (line, 0..) |c, i| {
        if (c == '"') in_str = !in_str;
        if (c == '#' and !in_str) return std.mem.trim(u8, line[0..i], " \t\r");
    }
    return std.mem.trim(u8, line, " \t\r");
}

/// Parses `text`. Problems go to `diag` (each with its line); the result is
/// `error.Parse` if there was any.
pub fn parse(a: std.mem.Allocator, text: []const u8, diag: *Diag) error{Parse}![]Table {
    const before = diag.count();
    var tables = std.ArrayListUnmanaged(Table){};
    var cur: ?usize = null;
    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        line_no += 1;
        const line = stripComment(raw);
        if (line.len == 0) continue;
        if (line[0] == '[') {
            if (line.len < 3 or line[line.len - 1] != ']') {
                diag.add("line {d}: malformed table header", .{line_no});
                continue;
            }
            const path = line[1 .. line.len - 1];
            var ok = true;
            var segs = std.mem.splitScalar(u8, path, '.');
            while (segs.next()) |s| {
                if (!validSegment(s)) ok = false;
            }
            if (!ok) {
                diag.add("line {d}: table name `{s}` has an empty or unsupported segment (letters, digits, - and _ only)", .{ line_no, path });
                continue;
            }
            for (tables.items) |t| {
                if (std.mem.eql(u8, t.path, path)) {
                    diag.add("line {d}: table [{s}] is defined twice (first at line {d})", .{ line_no, path, t.line });
                    ok = false;
                }
            }
            if (!ok) continue;
            tables.append(a, .{ .path = path, .line = line_no }) catch return error.Parse;
            cur = tables.items.len - 1;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            diag.add("line {d}: expected `key = value` or a [table] header", .{line_no});
            continue;
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (!validSegment(key)) {
            diag.add("line {d}: key `{s}` is empty or has unsupported characters", .{ line_no, key });
            continue;
        }
        const ti = cur orelse {
            diag.add("line {d}: `{s}` is before any [table]", .{ line_no, key });
            continue;
        };
        var value: Value = undefined;
        if (val.len >= 2 and val[0] == '"') {
            if (val[val.len - 1] != '"') {
                diag.add("line {d}: string for `{s}` is not closed (and nothing may follow it)", .{ line_no, key });
                continue;
            }
            const inner = val[1 .. val.len - 1];
            if (std.mem.indexOfAny(u8, inner, "\"\\") != null) {
                diag.add("line {d}: string for `{s}` has a quote or backslash; escapes are not supported", .{ line_no, key });
                continue;
            }
            value = .{ .string = inner };
        } else {
            const n = std.fmt.parseInt(u64, val, 10) catch {
                diag.add("line {d}: value for `{s}` is neither a \"string\" nor a non-negative integer", .{ line_no, key });
                continue;
            };
            value = .{ .int = n };
        }
        if (tables.items[ti].get(key) != null) {
            diag.add("line {d}: `{s}` is set twice in [{s}]", .{ line_no, key, tables.items[ti].path });
            continue;
        }
        tables.items[ti].entries.append(a, .{ .key = key, .value = value, .line = line_no }) catch return error.Parse;
    }
    if (diag.count() != before) return error.Parse;
    return tables.toOwnedSlice(a) catch error.Parse;
}
