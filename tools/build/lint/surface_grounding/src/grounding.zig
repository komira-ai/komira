//! The half of the surface capability matrix lint that reads files
//! (docs/surface_capability_matrix.md; the rule is
//! tools/build/lint/surface_capability_matrix.bzl, whose analysis refuses
//! every malformed or lying row before this runs).
//!
//! A grounding file declares an identifier at column 0 as a `comptime`
//! constant. `comptime <ID>: UInt8 = ...` and `comptime <ID> = UInt8(...)`
//! declare a tag; with another type annotation (`comptime <ID>: Int = ...`)
//! the constant is no tag and is not read; any other form (no annotation and
//! no `UInt8(`) is unread. An identifier is a family identifier when it
//! starts with one of its file's prefixes.
//!
//! Findings, each one line of the report, in this order:
//!   1. a family identifier declared in an unread form (never skipped
//!      silently);
//!   2. a grounding identifier (of a capability or a not_capabilities row)
//!      that no grounding file declares as a tag;
//!   3. a family tag that no capability and no not_capabilities row names;
//!   4. a census file (the matrix or the report the analysis wrote) that
//!      differs from the expected file a fixture names, with the differing
//!      lines.

const std = @import("std");
const Alloc = std.mem.Allocator;

pub const Form = enum { tag, unread };

pub const Decl = struct {
    id: []const u8,
    form: Form,
};

fn isIdStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn skipBlank(s: []const u8, from: usize) usize {
    var i = from;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    return i;
}

/// `s` starts with `word`, then blanks, then `next`; the index after `next`.
fn wordThen(s: []const u8, from: usize, word: []const u8, next: u8) ?usize {
    if (!std.mem.startsWith(u8, s[from..], word)) return null;
    const i = skipBlank(s, from + word.len);
    if (i >= s.len or s[i] != next) return null;
    return i + 1;
}

/// The constant `line` declares at column 0, or null when it declares none
/// that is read (no `comptime`, or a type annotation other than UInt8).
pub fn declaration(line: []const u8) ?Decl {
    const kw = "comptime";
    if (!std.mem.startsWith(u8, line, kw)) return null;
    var i = kw.len;
    if (i >= line.len or (line[i] != ' ' and line[i] != '\t')) return null;
    i = skipBlank(line, i);
    if (i >= line.len or !isIdStart(line[i])) return null;
    const start = i;
    while (i < line.len and isIdChar(line[i])) i += 1;
    const id = line[start..i];
    i = skipBlank(line, i);
    if (i < line.len and line[i] == ':') {
        if (wordThen(line, skipBlank(line, i + 1), "UInt8", '=') != null) return .{ .id = id, .form = .tag };
        return null;
    }
    if (i < line.len and line[i] == '=') {
        if (wordThen(line, skipBlank(line, i + 1), "UInt8", '(') != null) return .{ .id = id, .form = .tag };
    }
    return .{ .id = id, .form = .unread };
}

pub const Family = struct {
    /// The file's path in the tree.
    path: []const u8,
    prefixes: []const []const u8,
    data: []const u8,
};

pub const Named = struct {
    /// Who names it: `capability <name>` or `not_capabilities row <n>`.
    what: []const u8,
    id: []const u8,
};

const Tag = struct {
    id: []const u8,
    path: []const u8,
    line: usize,
};

fn hasPrefix(id: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, id, p)) return true;
    }
    return false;
}

/// Findings 1 to 3, one line each to `out`; returns their count.
pub fn check(alloc: Alloc, families: []const Family, named: []const Named, out: *std.ArrayList(u8)) !usize {
    const w = out.writer();
    var findings: usize = 0;
    var declared = std.StringHashMap(void).init(alloc);
    var family_tags = std.ArrayList(Tag).init(alloc);
    for (families) |f| {
        var lines = std.mem.splitScalar(u8, f.data, '\n');
        var n: usize = 0;
        while (lines.next()) |line| {
            n += 1;
            const d = declaration(line) orelse continue;
            const fam = hasPrefix(d.id, f.prefixes);
            if (d.form == .unread) {
                if (fam) {
                    try w.print("{s}:{d}: {s} is a constant of a grounding family in a form this lint cannot read; declare it as `comptime {s}: UInt8 = <n>`\n", .{ f.path, n, d.id, d.id });
                    findings += 1;
                }
                continue;
            }
            try declared.put(d.id, {});
            if (fam) try family_tags.append(.{ .id = d.id, .path = f.path, .line = n });
        }
    }
    var is_named = std.StringHashMap(void).init(alloc);
    for (named) |x| {
        try is_named.put(x.id, {});
        if (!declared.contains(x.id)) {
            try w.print("{s}: grounding `{s}` is declared by no grounding file (as comptime {s}: UInt8)\n", .{ x.what, x.id, x.id });
            findings += 1;
        }
    }
    for (family_tags.items) |t| {
        if (is_named.contains(t.id)) continue;
        try w.print("{s}:{d}: {s} is a plan constant that no capability and no not_capabilities row names; ground a capability on it, or say in not_capabilities why it is none\n", .{ t.path, t.line, t.id });
        findings += 1;
    }
    return findings;
}

/// The most lines of one comparison's difference written to the report.
pub const max_diff_lines = 60;

fn splitLines(alloc: Alloc, s: []const u8) ![]const []const u8 {
    var list = std.ArrayList([]const u8).init(alloc);
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |l| try list.append(l);
    return list.items;
}

/// Finding 4: when `got` differs from `want` (the expected file named
/// `name`), a heading line and the differing lines (`-` expected, `+` got,
/// at most `max_diff_lines`) to `out`; returns the count of lines written.
pub fn compare(alloc: Alloc, got: []const u8, want: []const u8, name: []const u8, out: *std.ArrayList(u8)) !usize {
    if (std.mem.eql(u8, got, want)) return 0;
    const w = out.writer();
    try w.print("the census differs from {s} (- expected, + got):\n", .{name});
    var written: usize = 1;
    const g = try splitLines(alloc, got);
    const e = try splitLines(alloc, want);
    var head: usize = 0;
    while (head < g.len and head < e.len and std.mem.eql(u8, g[head], e[head])) head += 1;
    var tail: usize = 0;
    while (tail < g.len - head and tail < e.len - head and std.mem.eql(u8, g[g.len - 1 - tail], e[e.len - 1 - tail])) tail += 1;
    try w.print("@@ line {d} @@\n", .{head + 1});
    written += 1;
    var budget: usize = max_diff_lines;
    for (e[head .. e.len - tail]) |l| {
        if (budget == 0) break;
        try w.print("-{s}\n", .{l});
        written += 1;
        budget -= 1;
    }
    for (g[head .. g.len - tail]) |l| {
        if (budget == 0) break;
        try w.print("+{s}\n", .{l});
        written += 1;
        budget -= 1;
    }
    return written;
}
