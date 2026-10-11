//! The shell budget: every shell script of a tree has a row in the allowlist,
//! and is no longer than that row's cap, which is exactly its line count.
//!
//! A file is a shell script when its name ends with `.sh` or `.bash`, or when
//! its first line is a `#!` line naming a shell (sh, bash, ash, dash, ksh,
//! mksh, zsh), directly (`#!/bin/sh`), through `env` and its options
//! (`#!/usr/bin/env -S bash -e`) or through `busybox` (`#!/bin/busybox sh`).
//! The shebang closes the loophole of a script without the extension.
//!
//! The allowlist is a TSV file: `#` comment lines, blank lines, and rows of
//! exactly three tab-separated fields: the script's path in the tree, its cap
//! (`max_lines`, a decimal number above 0), and why it is still shell (not
//! empty). A line is a newline-terminated line, plus a last line without one.
//!
//! Findings, each one line of the report:
//!   - a malformed row, or a second row for one path;
//!   - a shell script with no row (it is named);
//!   - a script with more lines than its cap;
//!   - a cap above the script's line count: the cap must come down with the
//!     script, so a cap is always the script's size and only ever goes down;
//!   - a row naming no shell script of the tree (the file was deleted or is no
//!     longer shell): the row is removed with it.
//! What review holds, not this tool: a row is never added for a new script
//! without a reason review accepts, and a cap is never raised.

const std = @import("std");
const Alloc = std.mem.Allocator;

pub const File = struct {
    path: []const u8,
    data: []const u8,
};

pub const Result = struct {
    /// Shell scripts found in the tree.
    scripts: usize,
    /// Finding lines written to the report.
    findings: usize,
};

const shells = [_][]const u8{ "sh", "bash", "ash", "dash", "ksh", "mksh", "zsh" };

/// Bytes read from each file to look for a `#!` line.
pub const head_len = 512;

/// The largest file read whole.
const max_file = 1 << 30;

fn isShellName(name: []const u8) bool {
    for (shells) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

/// Whether `head`, the start of a file, is a `#!` line naming a shell.
pub fn shebangShell(head: []const u8) bool {
    if (!std.mem.startsWith(u8, head, "#!")) return false;
    const end = std.mem.indexOfScalar(u8, head, '\n') orelse head.len;
    var it = std.mem.tokenizeAny(u8, head[2..end], " \t\r");
    var tok = it.next() orelse return false;
    var name = std.fs.path.basenamePosix(tok);
    if (std.mem.eql(u8, name, "env")) {
        // Past env's options (-S, -i, ...) and its NAME=value assignments.
        while (true) {
            tok = it.next() orelse return false;
            if (tok[0] == '-' or std.mem.indexOfScalar(u8, tok, '=') != null) continue;
            break;
        }
        name = std.fs.path.basenamePosix(tok);
    }
    if (std.mem.eql(u8, name, "busybox")) {
        tok = it.next() orelse return false;
        name = std.fs.path.basenamePosix(tok);
    }
    return isShellName(name);
}

/// Whether the file at `path`, whose first bytes are `head`, is a shell script.
pub fn isShell(path: []const u8, head: []const u8) bool {
    return std.mem.endsWith(u8, path, ".sh") or std.mem.endsWith(u8, path, ".bash") or shebangShell(head);
}

/// Newline-terminated lines, plus a last line without a newline.
pub fn countLines(data: []const u8) u64 {
    var n: u64 = std.mem.count(u8, data, "\n");
    if (data.len > 0 and data[data.len - 1] != '\n') n += 1;
    return n;
}

fn lessThan(_: void, a: File, b: File) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

/// The shell scripts under `dir` (opened with `.iterate = true`), each with
/// its path from `dir` and its contents, sorted by path. Every other file is
/// read only for its first `head_len` bytes. A symbolic link is followed.
pub fn collect(alloc: Alloc, dir: std.fs.Dir) ![]File {
    var list = std.ArrayList(File).init(alloc);
    var walker = try dir.walk(alloc);
    defer walker.deinit();
    var head: [head_len]u8 = undefined;
    while (try walker.next()) |e| {
        switch (e.kind) {
            .file, .sym_link => {},
            else => continue,
        }
        const f = dir.openFile(e.path, .{}) catch |err| switch (err) {
            error.IsDir => continue,
            else => return err,
        };
        defer f.close();
        const n = f.readAll(&head) catch |err| switch (err) {
            error.IsDir => continue,
            else => return err,
        };
        if (!isShell(e.path, head[0..n])) continue;
        try f.seekTo(0);
        try list.append(.{
            .path = try alloc.dupe(u8, e.path),
            .data = try f.readToEndAlloc(alloc, max_file),
        });
    }
    const files = try list.toOwnedSlice();
    std.mem.sort(File, files, {}, lessThan);
    return files;
}

const Row = struct {
    path: []const u8,
    max: u64,
    line: usize,
    seen: bool = false,
};

/// Checks `scripts` (the shell scripts of the tree) against `allowlist`, the
/// text of the file named `name`, and writes one line per finding to `out`.
pub fn check(alloc: Alloc, name: []const u8, allowlist: []const u8, scripts: []const File, out: *std.ArrayList(u8)) !Result {
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
        var fields: [3][]const u8 = undefined;
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, line, '\t');
        while (it.next()) |field| : (count += 1) {
            if (count < 3) fields[count] = field;
        }
        if (count != 3) {
            try w.print("{s}:{d}: {d} field(s), not 3 (path, max_lines, reason, tab-separated)\n", .{ name, lineno, count });
            findings += 1;
            continue;
        }
        const path = fields[0];
        if (path.len == 0 or path[0] == '/') {
            try w.print("{s}:{d}: the path `{s}` is not a path in the repository\n", .{ name, lineno, path });
            findings += 1;
            continue;
        }
        const max = std.fmt.parseUnsigned(u64, fields[1], 10) catch 0;
        if (max == 0) {
            try w.print("{s}:{d}: {s}: max_lines `{s}` is not a number above 0\n", .{ name, lineno, path, fields[1] });
            findings += 1;
            continue;
        }
        if (std.mem.trim(u8, fields[2], " ").len == 0) {
            try w.print("{s}:{d}: {s}: no reason\n", .{ name, lineno, path });
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
        try rows.append(.{ .path = path, .max = max, .line = lineno });
    }

    for (scripts) |s| {
        const n = countLines(s.data);
        const i = by_path.get(s.path) orelse {
            try w.print("{s}: a shell script ({d} lines) with no row in {s}: write it in Zig, or add a row review accepts\n", .{ s.path, n, name });
            findings += 1;
            continue;
        };
        const row = &rows.items[i];
        row.seen = true;
        if (n > row.max) {
            try w.print("{s}: {d} lines, over its cap of {d} ({s}:{d})\n", .{ s.path, n, row.max, name, row.line });
            findings += 1;
        } else if (n < row.max) {
            try w.print("{s}: {d} lines, under its cap of {d}: lower the cap to {d} ({s}:{d}); caps only go down\n", .{ s.path, n, row.max, n, name, row.line });
            findings += 1;
        }
    }

    for (rows.items) |row| {
        if (row.seen) continue;
        try w.print("{s}:{d}: {s}: no shell script at this path: remove the row\n", .{ name, row.line, row.path });
        findings += 1;
    }
    return .{ .scripts = scripts.len, .findings = findings };
}

test {
    _ = @import("budget_test.zig");
}
