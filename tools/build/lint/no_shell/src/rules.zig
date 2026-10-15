//! The no-shell list: no build file starts a shell, and no shell script sits
//! outside a place the list names. Both are counted against a TSV of rows, so
//! what remains of the repository's shell is written down, and the list only
//! shrinks.
//!
//! Two things are checked in a tree of files at their paths:
//!   - the build files (BUCK, `.bzl`, `.bxl`) are scanned (scan.zig says for
//!     what): a `use` row (path, category, count) says how many sites of the
//!     category the file has. More sites than the row says is a new use of a
//!     shell; fewer is a row to lower; none is a row to remove; a file with
//!     sites and no row is a finding.
//!   - the shell scripts of the tree (a `.sh`, `.bash`, `.zsh` or `.ksh` file,
//!     or a first line `#!` running a shell, directly, through `env` or through
//!     `busybox`) each need either a `script` row (the file's path: a script
//!     that is still an action's or test's, to be ported) or to be under a
//!     `human` row (a path, or a directory prefix ending in `/`: the places
//!     where scripts that only people and CI runners run may live, never a
//!     build or test action). A `script` row or `human` row naming nothing is
//!     a finding.
//!
//! The list is a TSV file: `#` comment lines, blank lines, and rows of exactly
//! five tab-separated fields: kind (`use`, `script` or `human`), path, category
//! (a `use` row's, else `-`), count (a `use` row's, a positive integer, else
//! `-`) and a reason (not empty). What review holds, not this tool: a row is
//! never added for a new site without a reason review accepts.

const std = @import("std");
const scan = @import("scan.zig");
const Alloc = std.mem.Allocator;

pub const Result = struct {
    /// Build files with at least one site.
    build_files: usize,
    /// Shell scripts found.
    scripts: usize,
    /// Finding lines written to the report.
    findings: usize,
};

pub const BuildFile = struct {
    path: []const u8,
    counts: scan.Counts,
};

pub const Script = struct {
    path: []const u8,
    why: []const u8,
};

pub const Collected = struct {
    build_files: []const BuildFile,
    scripts: []const Script,
};

const shell_extensions = [_][]const u8{ "sh", "bash", "zsh", "ksh" };
const shell_programs = [_][]const u8{ "sh", "bash", "ash", "dash", "ksh", "mksh", "zsh" };

/// Bytes read from each file to look for a `#!` line.
pub const head_len = 512;

/// The base name of the program the `#!` first line of `head` runs, looking
/// through `env` (its options, the argument of `-u`/`-C`, and its
/// `NAME=value` words) and `busybox` (its applet); null when the first line
/// is not a `#!` line or names nothing. A slice of `head`. (The same reading
/// as the interpreter list's, which counts more kinds of interpreter.)
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

/// Why the file at `path`, whose first bytes are `head`, is a shell script
/// (allocated), or null when it is not one.
pub fn classify(alloc: Alloc, path: []const u8, head: []const u8) !?[]const u8 {
    const base = std.fs.path.basenamePosix(path);
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| {
        const ext = base[dot + 1 ..];
        for (shell_extensions) |e| {
            if (std.ascii.eqlIgnoreCase(ext, e)) return try std.fmt.allocPrint(alloc, "a `.{s}` file", .{ext});
        }
    }
    const prog = shebangProgram(head) orelse return null;
    for (shell_programs) |s| {
        if (std.mem.eql(u8, prog, s)) return try std.fmt.allocPrint(alloc, "its `#!` line runs `{s}`", .{prog});
    }
    return null;
}

fn byPathBuild(_: void, a: BuildFile, b: BuildFile) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

fn byPathScript(_: void, a: Script, b: Script) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

/// The build files with sites and the shell scripts under `dir` (opened with
/// `.iterate = true`), sorted by path. A symbolic link is followed.
pub fn collect(alloc: Alloc, dir: std.fs.Dir) !Collected {
    var builds = std.ArrayList(BuildFile).init(alloc);
    var scripts = std.ArrayList(Script).init(alloc);
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
        if (scan.isBuildFile(e.path)) {
            const text = f.readToEndAlloc(alloc, 1 << 24) catch |err| switch (err) {
                error.IsDir => continue,
                else => return err,
            };
            const counts = scan.scan(text);
            if (scan.total(counts) > 0) try builds.append(.{ .path = try alloc.dupe(u8, e.path), .counts = counts });
            continue;
        }
        const n = f.readAll(&head) catch |err| switch (err) {
            error.IsDir => continue,
            else => return err,
        };
        const why = try classify(alloc, e.path, head[0..n]) orelse continue;
        try scripts.append(.{ .path = try alloc.dupe(u8, e.path), .why = why });
    }
    const b = try builds.toOwnedSlice();
    const s = try scripts.toOwnedSlice();
    std.mem.sort(BuildFile, b, {}, byPathBuild);
    std.mem.sort(Script, s, {}, byPathScript);
    return .{ .build_files = b, .scripts = s };
}

const Kind = enum { use, script, human };

const Row = struct {
    kind: Kind,
    path: []const u8,
    category: ?scan.Category,
    count: usize,
    line: usize,
    seen: bool = false,
};

/// Whether the `human` row path `row` covers `path`: the same path, or a
/// directory prefix (ending in `/`).
pub fn covers(row: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, row, path)) return true;
    return row[row.len - 1] == '/' and std.mem.startsWith(u8, path, row);
}

/// Checks `found` against `list`, the text of the file named `name`, and
/// writes one line per finding to `out`.
pub fn check(alloc: Alloc, name: []const u8, list: []const u8, found: Collected, out: *std.ArrayList(u8)) !Result {
    const w = out.writer();
    var findings: usize = 0;
    var rows = std.ArrayList(Row).init(alloc);
    defer rows.deinit();
    var keys = std.StringHashMap(usize).init(alloc);
    defer keys.deinit();

    var lines = std.mem.splitScalar(u8, list, '\n');
    var lineno: usize = 0;
    while (lines.next()) |raw| {
        lineno += 1;
        const line = std.mem.trimRight(u8, raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields: [5][]const u8 = undefined;
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, line, '\t');
        while (it.next()) |field| : (count += 1) {
            if (count < 5) fields[count] = field;
        }
        if (count != 5) {
            try w.print("{s}:{d}: {d} field(s), not 5 (kind, path, category, count, reason, tab-separated)\n", .{ name, lineno, count });
            findings += 1;
            continue;
        }
        const kind = std.meta.stringToEnum(Kind, fields[0]) orelse {
            try w.print("{s}:{d}: the kind `{s}` is not use, script or human\n", .{ name, lineno, fields[0] });
            findings += 1;
            continue;
        };
        const path = fields[1];
        if (path.len == 0 or path[0] == '/') {
            try w.print("{s}:{d}: the path `{s}` is not a path in the repository\n", .{ name, lineno, path });
            findings += 1;
            continue;
        }
        if (std.mem.trim(u8, fields[4], " ").len == 0) {
            try w.print("{s}:{d}: {s}: no reason\n", .{ name, lineno, path });
            findings += 1;
            continue;
        }
        var category: ?scan.Category = null;
        var n: usize = 0;
        if (kind == .use) {
            category = scan.parseCategory(fields[2]) orelse {
                try w.print("{s}:{d}: {s}: `{s}` is not a category of shell use\n", .{ name, lineno, path, fields[2] });
                findings += 1;
                continue;
            };
            n = std.fmt.parseInt(usize, fields[3], 10) catch 0;
            if (n == 0) {
                try w.print("{s}:{d}: {s}: the count `{s}` is not a positive integer\n", .{ name, lineno, path, fields[3] });
                findings += 1;
                continue;
            }
        } else if (!std.mem.eql(u8, fields[2], "-") or !std.mem.eql(u8, fields[3], "-")) {
            try w.print("{s}:{d}: {s}: a {s} row has `-` for category and count\n", .{ name, lineno, path, fields[0] });
            findings += 1;
            continue;
        } else if (kind == .script and path[path.len - 1] == '/') {
            try w.print("{s}:{d}: {s}: a script row names one file\n", .{ name, lineno, path });
            findings += 1;
            continue;
        }
        const key = try std.fmt.allocPrint(alloc, "{s}\x00{s}\x00{s}", .{ fields[0], path, if (category) |c| @tagName(c) else "-" });
        const slot = try keys.getOrPut(key);
        if (slot.found_existing) {
            try w.print("{s}:{d}: {s}: a second row (the first is line {d})\n", .{ name, lineno, path, rows.items[slot.value_ptr.*].line });
            findings += 1;
            continue;
        }
        slot.value_ptr.* = rows.items.len;
        try rows.append(.{ .kind = kind, .path = path, .category = category, .count = n, .line = lineno });
    }

    var build_files: usize = 0;
    for (found.build_files) |bf| {
        build_files += 1;
        for (bf.counts, 0..) |n, ci| {
            if (n == 0) continue;
            const cat: scan.Category = @enumFromInt(ci);
            var hit: ?*Row = null;
            for (rows.items) |*row| {
                if (row.kind == .use and row.category.? == cat and std.mem.eql(u8, row.path, bf.path)) hit = row;
            }
            const row = hit orelse {
                try w.print("{s}: {d} `{s}` site(s) with no row in {s}: start no shell (write the action in Zig), or add a row review accepts\n", .{ bf.path, n, @tagName(cat), name });
                findings += 1;
                continue;
            };
            row.seen = true;
            if (n > row.count) {
                try w.print("{s}:{d}: {s}: {d} `{s}` site(s), the row says {d}: a new use of a shell\n", .{ name, row.line, bf.path, n, @tagName(cat), row.count });
                findings += 1;
            } else if (n < row.count) {
                try w.print("{s}:{d}: {s}: {d} `{s}` site(s) remain, the row says {d}: lower the row\n", .{ name, row.line, bf.path, n, @tagName(cat), row.count });
                findings += 1;
            }
        }
    }

    for (found.scripts) |s| {
        var listed = false;
        for (rows.items) |*row| {
            switch (row.kind) {
                .script => if (std.mem.eql(u8, row.path, s.path)) {
                    row.seen = true;
                    listed = true;
                },
                .human => if (covers(row.path, s.path)) {
                    row.seen = true;
                    listed = true;
                },
                .use => {},
            }
        }
        if (!listed) {
            try w.print("{s}: a shell script ({s}) outside the places {s} names: write it in Zig, or add a row review accepts\n", .{ s.path, s.why, name });
            findings += 1;
        }
    }

    for (rows.items) |row| {
        if (row.seen) continue;
        switch (row.kind) {
            .use => try w.print("{s}:{d}: {s}: no `{s}` site in this file: remove the row\n", .{ name, row.line, row.path, @tagName(row.category.?) }),
            .script => try w.print("{s}:{d}: {s}: no shell script at this path: remove the row\n", .{ name, row.line, row.path }),
            .human => try w.print("{s}:{d}: {s}: no shell script here: remove the row\n", .{ name, row.line, row.path }),
        }
        findings += 1;
    }
    return .{ .build_files = build_files, .scripts = found.scripts.len, .findings = findings };
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
    _ = @import("scan_test.zig");
    _ = @import("rules_test.zig");
}
