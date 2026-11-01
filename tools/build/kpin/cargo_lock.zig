//! Cargo.lock, versions 3 and 4: the checksum of every registry package.
//! Cargo owns the resolution (it runs, with a network, outside the build);
//! kpin reads what it wrote. Only the keys kpin needs are read, line by line:
//! a package's `name`, `version`, `source` and `checksum`. Its `dependencies`
//! list is skipped (the dependency graph is `cargo metadata`'s, with the
//! features Cargo resolved).

const std = @import("std");
const valid = @import("valid.zig");
const Diag = @import("diag.zig").Diag;

pub const Entry = struct {
    name: []const u8 = "",
    version: []const u8 = "",
    /// `registry+https://...`, or empty for a path package (a workspace member).
    source: []const u8 = "",
    /// Lower-case hex sha256 of the `.crate` file, or empty.
    checksum: []const u8 = "",
};

/// `key = "value"`: the value, when the line is exactly that.
fn stringValue(line: []const u8, key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, key)) return null;
    var rest = line[key.len..];
    if (!std.mem.startsWith(u8, rest, " = \"")) return null;
    rest = rest[4..];
    if (rest.len < 1 or rest[rest.len - 1] != '"') return null;
    return rest[0 .. rest.len - 1];
}

/// The packages of the lock, in file order. Refused (each into `diag`): a lock
/// version other than 3 and 4, a quote or backslash inside a value, a package
/// with no name or version.
pub fn parse(a: std.mem.Allocator, label: []const u8, text: []const u8, diag: *Diag) error{Invalid}![]Entry {
    const before = diag.count();
    var list = std.ArrayList(Entry).empty;
    var cur: ?Entry = null;
    var skipping = false;
    var lock_version: ?u64 = null;
    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        line_no += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (skipping) {
            if (std.mem.eql(u8, line, "]")) skipping = false;
            continue;
        }
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.eql(u8, line, "[[package]]")) {
            if (cur) |c| list.append(a, c) catch return error.Invalid;
            cur = .{};
            continue;
        }
        if (line[0] == '[') {
            // [metadata] is the checksum table of lock versions 1 and 2; a
            // v3 lock has none, and nothing else follows the packages.
            if (cur) |c| list.append(a, c) catch return error.Invalid;
            cur = null;
            continue;
        }
        if (std.mem.indexOf(u8, line, "\\") != null) {
            diag.add("{s}:{d}: a backslash in a value; kpin reads plain strings only", .{ label, line_no });
            continue;
        }
        if (cur == null) {
            if (std.mem.startsWith(u8, line, "version = ")) {
                lock_version = std.fmt.parseInt(u64, line["version = ".len..], 10) catch null;
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "dependencies = [") and !std.mem.endsWith(u8, line, "]")) {
            skipping = true;
        } else if (stringValue(line, "name")) |v| {
            cur.?.name = v;
        } else if (stringValue(line, "version")) |v| {
            cur.?.version = v;
        } else if (stringValue(line, "source")) |v| {
            cur.?.source = v;
        } else if (stringValue(line, "checksum")) |v| {
            cur.?.checksum = v;
        }
    }
    if (cur) |c| list.append(a, c) catch return error.Invalid;
    if (lock_version == null) {
        diag.add("{s}: no `version = N` line before the packages (lock version 1 or 2); run a current cargo, which rewrites the lock as version 3 or 4", .{label});
    } else if (lock_version.? != 3 and lock_version.? != 4) {
        diag.add("{s}: lock version {d} is not 3 or 4", .{ label, lock_version.? });
    }
    for (list.items) |e| {
        if (e.name.len == 0 or e.version.len == 0) {
            diag.add("{s}: a [[package]] without a name or a version", .{label});
        } else if (!valid.isCrateName(e.name) or !valid.isVersion(e.version)) {
            diag.add("{s}: package `{s}` `{s}` has a name or version with unsupported characters", .{ label, e.name, e.version });
        }
    }
    if (diag.count() != before) return error.Invalid;
    return list.toOwnedSlice(a) catch error.Invalid;
}
