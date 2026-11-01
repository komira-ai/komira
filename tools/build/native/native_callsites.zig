//! The call-site reader of `native_so` (native_so.zig): every name a Mojo
//! source passes to `external_call[...]`.
//!
//! A call site is the identifier `external_call`, then `[` (spaces, line
//! breaks and `#` comments may come between), then a string literal: the
//! name. Text inside a string literal (docstrings included) or a `#` comment
//! is never a call site, so a name written only in prose is not read. An
//! `external_call[` whose first argument is not a string literal is an
//! error naming the file and line: the reader could not know the name, and
//! a name it misses would be left out of the export list.

const std = @import("std");

pub const Alloc = std.mem.Allocator;

/// Where `scan` stopped on an error: the line, and why.
pub const Failure = struct { line: usize = 0, why: []const u8 = "" };

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

const Scanner = struct {
    s: []const u8,
    i: usize = 0,
    line: usize = 1,

    fn at(p: *Scanner, k: usize) u8 {
        return if (p.i + k < p.s.len) p.s[p.i + k] else 0;
    }

    fn step(p: *Scanner) void {
        if (p.s[p.i] == '\n') p.line += 1;
        p.i += 1;
    }

    fn skipComment(p: *Scanner) void {
        while (p.i < p.s.len and p.s[p.i] != '\n') p.i += 1;
    }

    /// Past a string literal starting at `i` (one quote or three).
    fn skipString(p: *Scanner) void {
        const q = p.s[p.i];
        const triple = p.at(1) == q and p.at(2) == q;
        p.i += if (triple) 3 else 1;
        while (p.i < p.s.len) {
            const c = p.s[p.i];
            if (c == '\\') {
                p.step();
                if (p.i < p.s.len) p.step();
                continue;
            }
            if (triple) {
                if (c == q and p.at(1) == q and p.at(2) == q) {
                    p.i += 3;
                    return;
                }
            } else {
                if (c == q) {
                    p.i += 1;
                    return;
                }
                if (c == '\n') return;
            }
            p.step();
        }
    }

    /// Past spaces, line breaks and comments.
    fn skipBlank(p: *Scanner) void {
        while (p.i < p.s.len) {
            const c = p.s[p.i];
            if (c == '#') {
                p.skipComment();
            } else if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                p.step();
            } else return;
        }
    }
};

/// Appends the call-site names of one source to `out`. On a call site whose
/// name is not a string literal of [A-Za-z0-9_] characters, returns
/// error.CallSite with `fail` set.
pub fn scan(alloc: std.mem.Allocator, src: []const u8, out: *std.ArrayList([]const u8), fail: *Failure) !void {
    var p = Scanner{ .s = src };
    while (p.i < src.len) {
        const c = src[p.i];
        if (c == '#') {
            p.skipComment();
        } else if (c == '"' or c == '\'') {
            p.skipString();
        } else if (isIdent(c)) {
            const start = p.i;
            while (p.i < src.len and isIdent(src[p.i])) p.i += 1;
            if (!std.mem.eql(u8, src[start..p.i], "external_call")) continue;
            const line = p.line;
            p.skipBlank();
            if (p.at(0) != '[') continue; // an import or a mention, not a call
            p.i += 1;
            p.skipBlank();
            if (p.at(0) != '"' or (p.at(1) == '"' and p.at(2) == '"')) {
                fail.* = .{ .line = line, .why = "external_call[ whose first argument is not a string literal" };
                return error.CallSite;
            }
            p.i += 1;
            const name_start = p.i;
            while (p.i < src.len and isIdent(src[p.i])) p.i += 1;
            if (p.at(0) != '"' or p.i == name_start) {
                fail.* = .{ .line = line, .why = "external_call[ whose name is not [A-Za-z0-9_]+" };
                return error.CallSite;
            }
            try out.append(alloc, src[name_start..p.i]);
            p.i += 1;
        } else {
            p.step();
        }
    }
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Sorts `names` and drops repeats, in place; returns the distinct prefix.
pub fn sortUnique(names: [][]const u8) [][]const u8 {
    std.mem.sort([]const u8, names, {}, lessStr);
    var n: usize = 0;
    for (names) |x| {
        if (n > 0 and std.mem.eql(u8, names[n - 1], x)) continue;
        names[n] = x;
        n += 1;
    }
    return names[0..n];
}

/// The distinct, sorted call-site names of every `*.mojo` file under `dir`
/// (a directory, read recursively; symbolic links to files are read).
/// Exits with status 2 naming the file and line on a call site `scan`
/// refuses, or on a directory holding no `.mojo` file.
pub fn scanDir(alloc: Alloc, dir_path: []const u8) ![][]const u8 {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("native_so: cannot open caller sources {s}: {s}\n", .{ dir_path, @errorName(err) });
        std.process.exit(2);
    };
    defer dir.close();
    var walker = try dir.walk(alloc);
    defer walker.deinit();
    var paths = std.ArrayList([]const u8).empty;
    while (try walker.next()) |w| {
        if (w.kind != .file and w.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, w.path, ".mojo")) continue;
        try paths.append(alloc, try alloc.dupe(u8, w.path));
    }
    if (paths.items.len == 0) {
        std.debug.print("native_so: {s} holds no .mojo file (not a mojo_library's [src]?)\n", .{dir_path});
        std.process.exit(2);
    }
    std.mem.sort([]const u8, paths.items, {}, lessStr);
    var names = std.ArrayList([]const u8).empty;
    for (paths.items) |rel| {
        const src = try dir.readFileAlloc(alloc, rel, 1 << 28);
        var fail = Failure{};
        scan(alloc, src, &names, &fail) catch |err| switch (err) {
            error.CallSite => {
                std.debug.print("native_so: {s}/{s}:{d}: {s}\n", .{ dir_path, rel, fail.line, fail.why });
                std.process.exit(2);
            },
            else => return err,
        };
    }
    return sortUnique(names.items);
}
