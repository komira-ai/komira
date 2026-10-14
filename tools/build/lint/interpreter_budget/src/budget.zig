//! The interpreter list: every interpreter file of a tree (shell, Python,
//! Perl, awk, sed, Ruby) has a row in the allowlist, and every row names an
//! interpreter file of the tree. It checks existence only: a file's size is
//! never read, so editing a listed file never touches the list.
//!
//! A file is an interpreter file when its name ends with one of `extensions`
//! (compared ignoring ASCII case), or when its first line is a `#!` line whose
//! program is one of `interpreters` or any `python*`: directly
//! (`#!/bin/sh`), through `env`, its options and its `NAME=value` words
//! (`#!/usr/bin/env -S python3 -u`), or through `busybox` (`#!/bin/busybox sh`).
//! The `#!` line closes the loophole of a file without the extension.
//! A `#!` line naming any other program (`node`, `dotslash`, a data format's
//! marker such as `#! komira-plan-conformance v1`) is not counted.
//!
//! A scope (a list of path prefixes; empty: the whole tree) limits what is
//! counted: a file outside every prefix is not an interpreter file of the
//! check, and a row outside every prefix is a finding.
//!
//! The allowlist is a TSV file: `#` comment lines, blank lines, and rows of
//! exactly two tab-separated fields: the file's path in the tree, and why it
//! is still an interpreter file (not empty).
//!
//! Findings, each one line of the report:
//!   - a malformed row, or a second row for one path;
//!   - a row outside the scope;
//!   - an interpreter file with no row (it is named, with why it counts);
//!   - a row naming no interpreter file of the tree (the file was deleted or
//!     is no longer an interpreter file): the row is removed with it, so the
//!     list only shrinks.
//! What review holds, not this tool: a row is never added for a new file
//! without a reason review accepts.

const std = @import("std");
const Alloc = std.mem.Allocator;

pub const Result = struct {
    /// Interpreter files found in the tree, in the scope.
    files: usize,
    /// Finding lines written to the report.
    findings: usize,
};

/// One interpreter file: its path in the tree, and why it counts.
pub const Found = struct {
    path: []const u8,
    why: []const u8,
};

/// Name endings (after the last `.`, ignoring ASCII case) that make a file an
/// interpreter file whatever its first line says.
pub const extensions = [_][]const u8{ "sh", "bash", "zsh", "ksh", "py", "pyw", "pl", "pm", "awk", "sed", "rb" };

/// The programs a `#!` line may name (besides any `python*`).
pub const interpreters = [_][]const u8{
    "sh", "bash", "ash", "dash", "ksh", "mksh", "zsh", "awk", "gawk", "mawk", "nawk", "sed", "perl", "ruby",
};

/// Bytes read from each file to look for a `#!` line.
pub const head_len = 512;

/// Whether a `#!` line naming the program `name` (a base name) runs an interpreter.
pub fn isInterpreter(name: []const u8) bool {
    for (interpreters) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return std.mem.startsWith(u8, name, "python");
}

/// The base name of the program the `#!` first line of `head` runs, looking
/// through `env` (its options, the argument of `-u`/`-C`, and its
/// `NAME=value` words) and `busybox` (its applet); null when the first line
/// is not a `#!` line or names nothing. A slice of `head`.
pub fn shebangProgram(head: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, head, "#!")) return null;
    const end = std.mem.indexOfScalar(u8, head, '\n') orelse head.len;
    var it = std.mem.tokenizeAny(u8, head[2..end], " \t\r");
    var tok = it.next() orelse return null;
    while (true) {
        const name = std.fs.path.basenamePosix(tok);
        if (std.mem.eql(u8, name, "env")) {
            while (true) {
                tok = it.next() orelse return null;
                if (std.mem.eql(u8, tok, "-u") or std.mem.eql(u8, tok, "-C") or
                    std.mem.eql(u8, tok, "--unset") or std.mem.eql(u8, tok, "--chdir"))
                {
                    _ = it.next() orelse return null;
                    continue;
                }
                if (tok[0] == '-' or std.mem.indexOfScalar(u8, tok, '=') != null) continue;
                break;
            }
        } else if (std.mem.eql(u8, name, "busybox")) {
            tok = it.next() orelse return null;
        } else return name;
    }
}

/// The extension of `path`'s base name that makes it an interpreter file, or null.
pub fn interpreterExtension(path: []const u8) ?[]const u8 {
    const base = std.fs.path.basenamePosix(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return null;
    const ext = base[dot + 1 ..];
    for (extensions) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return ext;
    }
    return null;
}

/// Why the file at `path`, whose first bytes are `head`, is an interpreter
/// file (allocated), or null when it is not one.
pub fn classify(alloc: Alloc, path: []const u8, head: []const u8) !?[]const u8 {
    if (interpreterExtension(path)) |ext| return try std.fmt.allocPrint(alloc, "a `.{s}` file", .{ext});
    const prog = shebangProgram(head) orelse return null;
    if (!isInterpreter(prog)) return null;
    return try std.fmt.allocPrint(alloc, "its `#!` line runs `{s}`", .{prog});
}

/// Whether `path` is in `scope` (a list of path prefixes; empty: every path).
pub fn inScope(scope: []const []const u8, path: []const u8) bool {
    if (scope.len == 0) return true;
    for (scope) |p| {
        if (std.mem.startsWith(u8, path, p)) return true;
    }
    return false;
}

fn lessThan(_: void, a: Found, b: Found) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

/// The interpreter files under `dir` (opened with `.iterate = true`) in
/// `scope`, sorted by path. Each file is read only for its first `head_len`
/// bytes. A symbolic link is followed.
pub fn collect(alloc: Alloc, dir: std.fs.Dir, scope: []const []const u8) ![]const Found {
    var list = std.ArrayList(Found).init(alloc);
    var walker = try dir.walk(alloc);
    defer walker.deinit();
    var head: [head_len]u8 = undefined;
    while (try walker.next()) |e| {
        switch (e.kind) {
            .file, .sym_link => {},
            else => continue,
        }
        if (!inScope(scope, e.path)) continue;
        const f = dir.openFile(e.path, .{}) catch |err| switch (err) {
            error.IsDir => continue,
            else => return err,
        };
        defer f.close();
        const n = f.readAll(&head) catch |err| switch (err) {
            error.IsDir => continue,
            else => return err,
        };
        const why = try classify(alloc, e.path, head[0..n]) orelse continue;
        try list.append(.{ .path = try alloc.dupe(u8, e.path), .why = why });
    }
    const found = try list.toOwnedSlice();
    std.mem.sort(Found, found, {}, lessThan);
    return found;
}

const Row = struct {
    path: []const u8,
    line: usize,
    seen: bool = false,
};

/// Checks `found` (the interpreter files of the tree in `scope`) against
/// `allowlist`, the text of the file named `name`, and writes one line per
/// finding to `out`.
pub fn check(alloc: Alloc, name: []const u8, allowlist: []const u8, scope: []const []const u8, found: []const Found, out: *std.ArrayList(u8)) !Result {
    const w = out.writer();
    var findings: usize = 0;
    var rows = std.ArrayList(Row).init(alloc);
    defer rows.deinit();
    var by_path = std.StringHashMap(usize).init(alloc);
    defer by_path.deinit();

    var lines = std.mem.splitScalar(u8, allowlist, '\n');
    var lineno: usize = 0;
    while (lines.next()) |raw| {
        lineno += 1;
        const line = std.mem.trimRight(u8, raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields: [2][]const u8 = undefined;
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, line, '\t');
        while (it.next()) |field| : (count += 1) {
            if (count < 2) fields[count] = field;
        }
        if (count != 2) {
            try w.print("{s}:{d}: {d} field(s), not 2 (path, reason, tab-separated)\n", .{ name, lineno, count });
            findings += 1;
            continue;
        }
        const path = fields[0];
        if (path.len == 0 or path[0] == '/') {
            try w.print("{s}:{d}: the path `{s}` is not a path in the repository\n", .{ name, lineno, path });
            findings += 1;
            continue;
        }
        if (std.mem.trim(u8, fields[1], " ").len == 0) {
            try w.print("{s}:{d}: {s}: no reason\n", .{ name, lineno, path });
            findings += 1;
            continue;
        }
        if (!inScope(scope, path)) {
            try w.print("{s}:{d}: {s}: outside the scope of the check: remove the row\n", .{ name, lineno, path });
            findings += 1;
            continue;
        }
        const slot = try by_path.getOrPut(path);
        if (slot.found_existing) {
            try w.print("{s}:{d}: {s}: a second row (the first is line {d})\n", .{ name, lineno, path, rows.items[slot.value_ptr.*].line });
            findings += 1;
            continue;
        }
        slot.value_ptr.* = rows.items.len;
        try rows.append(.{ .path = path, .line = lineno });
    }

    for (found) |f| {
        const i = by_path.get(f.path) orelse {
            try w.print("{s}: an interpreter file ({s}) with no row in {s}: write it in Zig, or add a row review accepts\n", .{ f.path, f.why, name });
            findings += 1;
            continue;
        };
        rows.items[i].seen = true;
    }

    for (rows.items) |row| {
        if (row.seen) continue;
        try w.print("{s}:{d}: {s}: no interpreter file at this path: remove the row\n", .{ name, row.line, row.path });
        findings += 1;
    }
    return .{ .files = found.len, .findings = findings };
}

/// The validation's verdict. With no `expect`, it passes when there is no
/// finding. With `expect` (substrings), it passes only when there are
/// findings and the report holds every one of them: a planted defect the
/// check must refuse. `missing` is set to the first expected substring the
/// report lacks.
pub const Verdict = struct {
    ok: bool,
    missing: ?[]const u8 = null,
};

pub fn verdict(r: Result, report: []const u8, expect: []const []const u8) Verdict {
    if (expect.len == 0) return .{ .ok = r.findings == 0 };
    for (expect) |e| {
        if (std.mem.indexOf(u8, report, e) == null) return .{ .ok = false, .missing = e };
    }
    return .{ .ok = r.findings > 0 };
}

test {
    _ = @import("budget_test.zig");
}
