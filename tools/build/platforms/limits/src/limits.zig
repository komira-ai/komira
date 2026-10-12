//! The limits of the build: every place it says it builds for one platform
//! only is declared at its site and listed in limits.tsv with the PR that
//! retires it (tools/build/platforms/README.md, "Limits, and the golden").
//!
//! limits.tsv is `#` comment lines, blank lines, a header row whose first
//! field is `id`, and rows of exactly three tab-separated fields: an id
//! (lowercase words joined by dashes), `retired_by` (`never` or
//! `native-pr:<n>`, `<n>` a number with an optional letter) and a reason
//! (starting `product:` for `never`). A line is a newline-terminated line,
//! plus a last line without one.
//!
//! `checkTree` holds the rows against the files of a tree. Findings, each one
//! line of the report:
//!   1. a malformed row (field count, id, `retired_by`, a `never` reason), a
//!      second row for an id, or no row at all;
//!   2. a line holding `target_compatible_with` and no `komira-limit:` marker;
//!   3. a marker `komira-limit:<id>` naming no row, and a row no marker names.
//! `checkMerged` holds the rows against commit subjects, the one thing a build
//! action cannot read:
//!   4. a row whose retiring PR has merged (a subject holds
//!      `native-pr:<n>` followed by no further digit or letter). By 3 every row
//!      has its marker, so such a row is a limit somebody forgot to delete.
//!
//! The files of a tree are every regular file (or link to one) but the paths
//! `excludes` names (a path, or a directory prefix ending in `/`), Markdown
//! (`*.md`, prose about limits) and binary data (a NUL byte in the first 8000
//! bytes, as git decides).

const std = @import("std");
const Alloc = std.mem.Allocator;

pub const File = struct {
    path: []const u8,
    data: []const u8,
};

pub const Row = struct {
    id: []const u8,
    by: []const u8,
    line: usize,
    marked: bool = false,
};

pub const Result = struct {
    /// Well-formed rows.
    limits: usize,
    /// Finding lines written to the report.
    findings: usize,
};

pub const marker = "komira-limit:";
pub const restriction = "target_compatible_with";

const max_file = 1 << 30;
const binary_probe = 8000;

fn isWordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9');
}

/// The length of the longest prefix of `s` matching `[a-z0-9]+(-[a-z0-9]+)*`,
/// 0 when none does.
pub fn idPrefix(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len and isWordChar(s[i])) i += 1;
    if (i == 0) return 0;
    while (i + 1 < s.len and s[i] == '-' and isWordChar(s[i + 1])) {
        i += 1;
        while (i < s.len and isWordChar(s[i])) i += 1;
    }
    return i;
}

/// Whether `s` is lowercase words joined by dashes.
pub fn isId(s: []const u8) bool {
    return s.len > 0 and idPrefix(s) == s.len;
}

/// Whether `s` is `never` or `native-pr:<digits>[letter]`.
pub fn isRetiredBy(s: []const u8) bool {
    if (std.mem.eql(u8, s, "never")) return true;
    const p = "native-pr:";
    if (!std.mem.startsWith(u8, s, p)) return false;
    const n = s[p.len..];
    var i: usize = 0;
    while (i < n.len and std.ascii.isDigit(n[i])) i += 1;
    if (i == 0) return false;
    if (i < n.len and n[i] >= 'a' and n[i] <= 'z') i += 1;
    return i == n.len;
}

pub const Parsed = struct {
    rows: []Row,
    findings: usize,
};

/// The well-formed rows of `text` (the limits file named `name`); every
/// malformed one is a finding written to `w`.
pub fn parseRows(alloc: Alloc, name: []const u8, text: []const u8, w: anytype) !Parsed {
    var rows = std.ArrayList(Row).init(alloc);
    var seen = std.StringHashMap(void).init(alloc);
    var findings: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (lines.next()) |raw| {
        n += 1;
        const line = std.mem.trimRight(u8, raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields: [3][]const u8 = undefined;
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, line, '\t');
        while (it.next()) |f| : (count += 1) {
            if (count < 3) fields[count] = f;
        }
        if (count >= 1 and std.mem.eql(u8, fields[0], "id")) continue;
        if (count != 3 or fields[2].len == 0) {
            try w.print("{s} line {d}: want exactly three tab-separated columns (id, retired_by, reason)\n", .{ name, n });
            findings += 1;
            continue;
        }
        const id = fields[0];
        const by = fields[1];
        if (!isId(id)) {
            try w.print("{s} line {d}: id `{s}` is not lowercase words joined by dashes\n", .{ name, n, id });
            findings += 1;
            continue;
        }
        if (seen.contains(id)) {
            try w.print("{s} line {d}: id `{s}` appears twice\n", .{ name, n, id });
            findings += 1;
            continue;
        }
        if (!isRetiredBy(by)) {
            try w.print("{s} line {d} ({s}): retired_by `{s}` is neither `never` nor `native-pr:<n>`\n", .{ name, n, id, by });
            findings += 1;
            continue;
        }
        if (std.mem.eql(u8, by, "never") and !std.mem.startsWith(u8, fields[2], "product:")) {
            try w.print("{s} line {d} ({s}): a limit that is never retired needs a reason starting `product:`\n", .{ name, n, id });
            findings += 1;
            continue;
        }
        try seen.put(id, {});
        try rows.append(.{ .id = id, .by = by, .line = n });
    }
    if (rows.items.len == 0) {
        try w.print("{s} lists no limit: an empty list is indistinguishable from an unchecked tree\n", .{name});
        findings += 1;
    }
    return .{ .rows = rows.items, .findings = findings };
}

fn excluded(path: []const u8, excludes: []const []const u8) bool {
    if (std.mem.endsWith(u8, path, ".md")) return true;
    for (excludes) |e| {
        if (std.mem.endsWith(u8, e, "/")) {
            if (std.mem.startsWith(u8, path, e)) return true;
        } else if (std.mem.eql(u8, path, e)) return true;
    }
    return false;
}

fn lessThan(_: void, a: File, b: File) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

/// The files of `dir` (opened with `.iterate = true`) that the check reads,
/// sorted by path. A symbolic link is followed.
pub fn collect(alloc: Alloc, dir: std.fs.Dir, excludes: []const []const u8) ![]File {
    var list = std.ArrayList(File).init(alloc);
    var walker = try dir.walk(alloc);
    defer walker.deinit();
    while (try walker.next()) |e| {
        switch (e.kind) {
            .file, .sym_link => {},
            else => continue,
        }
        if (excluded(e.path, excludes)) continue;
        const data = dir.readFileAlloc(alloc, e.path, max_file) catch |err| switch (err) {
            error.IsDir => continue,
            else => return err,
        };
        if (std.mem.indexOfScalar(u8, data[0..@min(data.len, binary_probe)], 0) != null) continue;
        try list.append(.{ .path = try alloc.dupe(u8, e.path), .data = data });
    }
    const files = try list.toOwnedSlice();
    std.mem.sort(File, files, {}, lessThan);
    return files;
}

/// Checks the rows of `text` (the limits file named `name`) against `files`
/// (rules 1 to 3), writing one line per finding to `out`.
pub fn checkTree(alloc: Alloc, name: []const u8, text: []const u8, files: []const File, out: *std.ArrayList(u8)) !Result {
    const w = out.writer();
    const parsed = try parseRows(alloc, name, text, w);
    var findings = parsed.findings;
    var by_id = std.StringHashMap(usize).init(alloc);
    for (parsed.rows, 0..) |r, i| try by_id.put(r.id, i);

    var unknown = std.ArrayList(u8).init(alloc);
    const uw = unknown.writer();
    for (files) |f| {
        var lines = std.mem.splitScalar(u8, f.data, '\n');
        var n: usize = 0;
        while (lines.next()) |line| {
            n += 1;
            const has_marker = std.mem.indexOf(u8, line, marker) != null;
            if (!has_marker) {
                if (std.mem.indexOf(u8, line, restriction) != null) {
                    try w.print("undeclared limit (a `" ++ restriction ++ "` with no `" ++ marker ++ "<id>` marker): {s}:{d}\n", .{ f.path, n });
                    findings += 1;
                }
                continue;
            }
            var at: usize = 0;
            while (std.mem.indexOfPos(u8, line, at, marker)) |m| {
                const start = m + marker.len;
                const len = idPrefix(line[start..]);
                at = start;
                if (len == 0) continue;
                const id = line[start .. start + len];
                if (by_id.get(id)) |i| {
                    parsed.rows[i].marked = true;
                } else {
                    try uw.print("marker `" ++ marker ++ "{s}` at {s}:{d} has no row in {s}\n", .{ id, f.path, n, name });
                    findings += 1;
                }
            }
        }
    }
    try w.writeAll(unknown.items);
    for (parsed.rows) |r| {
        if (r.marked) continue;
        try w.print("row `{s}` ({s} line {d}) has no marker in the tree: its limit is gone, delete the row\n", .{ r.id, name, r.line });
        findings += 1;
    }
    return .{ .limits = parsed.rows.len, .findings = findings };
}

/// Whether a line of `subjects` names `native-pr:<pr>` with no digit or
/// lowercase letter after it (`native-pr:44` and `native-pr:4b` are not 4).
pub fn merged(subjects: []const u8, pr: []const u8) bool {
    const p = "native-pr:";
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, subjects, at, p)) |i| {
        const start = i + p.len;
        at = start;
        if (!std.mem.startsWith(u8, subjects[start..], pr)) continue;
        const end = start + pr.len;
        if (end == subjects.len or !isWordChar(subjects[end])) return true;
    }
    return false;
}

/// Checks the rows of `text` against `subjects`, the commit subjects of the
/// main branch one per line (rule 4; malformed rows are findings too).
pub fn checkMerged(alloc: Alloc, name: []const u8, text: []const u8, subjects: []const u8, out: *std.ArrayList(u8)) !Result {
    const w = out.writer();
    const parsed = try parseRows(alloc, name, text, w);
    var findings = parsed.findings;
    for (parsed.rows) |r| {
        if (std.mem.eql(u8, r.by, "never")) continue;
        if (merged(subjects, r.by["native-pr:".len..])) {
            try w.print("limit `{s}` is retired by {s}, whose PR has merged (a commit subject names it), but its row is still in {s} line {d}, so it is still declared at its site\n", .{ r.id, r.by, name, r.line });
            findings += 1;
        }
    }
    return .{ .limits = parsed.rows.len, .findings = findings };
}
