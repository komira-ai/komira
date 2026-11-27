//! `migrate`: a README of the inline model (examples.zig: each example a
//! fence, its setup in hidden comments) made source-first (include.zig):
//! each example becomes a file, `examples/example_<n>.mojo` in README order,
//! and its fence and hidden comments become an include marker and the filled
//! fence (docs/design/documentation_tests.md, "The migration of today's
//! READMEs"). Pure: no I/O.
//!
//! The file is the program the README gate runs today for that fence
//! (program.zig), moved:
//!
//!   - ```mojo: the leading run of `from` and `import` lines (hidden or shown,
//!     a parenthesised one with its continuation lines, blank lines between
//!     them) goes above `def main() raises:`, after two blank lines; the rest
//!     of the hidden lines and the body follow, each indented four spaces
//!     (blank lines stay empty), and `pass` when none of them is code. An
//!     example that is all imports keeps them in `main`, as today.
//!   - ```mojo module: its hidden lines and its body, as they are.
//!
//! Blank lines at the start and the end are dropped. The README keeps every
//! other byte: each example's lines, from the first line of its hidden
//! comment before to the last of its hidden comment after, become the marker,
//! the fence (same character and length, longer when the file needs it,
//! word `mojo`) and the file's lines.
//!
//! `migrate` refuses a README the inline reader refuses, one that already
//! holds an include marker, an example indented in a list item (a marker
//! starts its line) and an example line ending in a space or a tab (a shown
//! file may not).
//!
//! `verify` is `migrate --verify`, the proof of a migration: the migrated
//! README is fresh against the files (include.zig); the files are exactly
//! `example_1` to `example_<n>`; each file is the program `generate` writes
//! today for its fence, but for blank lines, the moved imports, the
//! `def main() raises:` line and the four-space indent; and the README
//! differs from the old one only inside the examples, where marker and
//! fence stand for the hidden comments and the fence, holding the same code
//! but for those same differences.

const std = @import("std");
const md = @import("markdown");
const examples = @import("examples.zig");
const program = @import("program.zig");
const include = @import("include.zig");
const Allocator = std.mem.Allocator;

pub const Migrated = struct {
    readme: []const u8,
    /// `examples/example_<n>.mojo` and its bytes, in README order.
    files: []const include.Listed,
};

pub const Result = union(enum) {
    migrated: Migrated,
    /// Every refusal, one per line.
    refused: []const u8,
};

/// `examples/example_<n>.mojo`.
pub fn fileName(alloc: Allocator, n: usize) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}example_{d}{s}", .{ include.DIR, n, include.EXT });
}

/// Whether a code line holds code: not blank and not a comment.
fn holdsCode(lines: []const []const u8) bool {
    for (lines) |l| {
        const t = md.strip(l);
        if (t.len > 0 and t[0] != '#') return true;
    }
    return false;
}

fn isImport(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "from ") or std.mem.startsWith(u8, line, "import ");
}

/// The parentheses `line` opens and does not close, before any `#`.
fn parenDepth(line: []const u8) i64 {
    var d: i64 = 0;
    for (line) |ch| {
        switch (ch) {
            '#' => break,
            '(' => d += 1,
            ')' => d -= 1,
            else => {},
        }
    }
    return d;
}

/// The number of leading lines of `code` that are the leading run of
/// imports: import lines, their continuation lines, and the blank lines
/// between them, ending on an import's last line.
pub fn importRun(code: []const []const u8) usize {
    var end: usize = 0;
    var depth: i64 = 0;
    var k: usize = 0;
    while (k < code.len) : (k += 1) {
        const l = code[k];
        if (depth > 0) {
            depth += parenDepth(l);
            if (depth <= 0) {
                depth = 0;
                end = k + 1;
            }
            continue;
        }
        if (include.isBlank(l)) continue;
        if (!isImport(l)) break;
        depth = parenDepth(l);
        if (depth <= 0) {
            depth = 0;
            end = k + 1;
        }
    }
    return end;
}

/// `lines` without blank lines at the start and the end.
fn trimBlank(lines: []const []const u8) []const []const u8 {
    var a: usize = 0;
    var z = lines.len;
    while (a < z and include.isBlank(lines[a])) a += 1;
    while (z > a and include.isBlank(lines[z - 1])) z -= 1;
    return lines[a..z];
}

/// The file of example `ex` (see the header).
pub fn exampleFile(alloc: Allocator, ex: examples.Example) Allocator.Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    if (ex.module) {
        for (trimBlank(ex.code)) |l| {
            try out.appendSlice(alloc, if (include.isBlank(l)) "" else l);
            try out.append(alloc, '\n');
        }
        return out.toOwnedSlice(alloc);
    }
    var run = importRun(ex.code);
    if (!holdsCode(ex.code[run..])) run = 0;
    const imports = ex.code[0..run];
    const rest = trimBlank(ex.code[run..]);
    for (imports) |l| {
        try out.appendSlice(alloc, if (include.isBlank(l)) "" else l);
        try out.append(alloc, '\n');
    }
    if (imports.len > 0) try out.appendSlice(alloc, "\n\n");
    try out.appendSlice(alloc, "def main() raises:\n");
    for (rest) |l| {
        if (!include.isBlank(l)) {
            try out.appendSlice(alloc, "    ");
            try out.appendSlice(alloc, l);
        }
        try out.append(alloc, '\n');
    }
    if (!holdsCode(rest)) try out.appendSlice(alloc, "    pass\n");
    return out.toOwnedSlice(alloc);
}

/// The lines of one example in its README: from the first line of its hidden
/// comment before (its opening fence when there is none) to the last line of
/// its hidden comment after (its closing fence), 0-based.
pub const Region = struct {
    first: usize,
    last: usize,
    fence: md.Fence,
};

fn isHidden(line: []const u8) bool {
    const t = md.strip(md.strip(line)[4..]);
    return std.mem.startsWith(u8, t, "mojo-hidden");
}

fn fenceOpening(fences: []const md.Fence, line: usize) ?md.Fence {
    for (fences) |g| {
        if (g.open_line == line) return g;
    }
    return null;
}

/// The region of each example of `exs` (which the inline reader read from
/// `lines`), or null for an example whose fence is not there.
fn regions(alloc: Allocator, lines: []const []const u8, exs: []const examples.Example) Allocator.Error![]?Region {
    const fences = try md.fences(alloc, lines);
    const mask = try md.codeMask(alloc, lines);
    const comments = try md.htmlComments(alloc, lines, mask);
    const out = try alloc.alloc(?Region, exs.len);
    for (exs, 0..) |ex, k| {
        out[k] = null;
        const f = fenceOpening(fences, ex.line - 1) orelse continue;
        const close = f.close_line orelse continue;
        var r = Region{ .first = f.open_line, .last = close, .fence = f };
        for (comments) |c| {
            if (!isHidden(lines[c.open_line])) continue;
            const c_last = c.close_line orelse continue;
            if (f.open_line > 0 and c_last == f.open_line - 1) r.first = c.open_line;
            if (c.open_line == close + 1) r.last = c_last;
        }
        out[k] = r;
    }
    return out;
}

fn refuseLine(alloc: Allocator, out: *std.ArrayList(u8), display: []const u8, line: usize, comptime f: []const u8, args: anytype) Allocator.Error!void {
    if (out.items.len > 0) try out.append(alloc, '\n');
    try out.writer(alloc).print("{s}:{d}: ", .{ display, line });
    try out.writer(alloc).print(f, args);
}

/// README `text` (named `display`) migrated, or every refusal of it.
pub fn migrate(alloc: Allocator, text: []const u8, display: []const u8) Allocator.Error!Result {
    const lines = try md.splitLines(alloc, text);
    const sp = try include.spans(alloc, text);
    const mask = try md.codeMask(alloc, lines);
    var why = std.ArrayList(u8).empty;
    for (lines, 0..) |l, i| {
        if (!mask[i] and examples.isInclude(l)) {
            try refuseLine(alloc, &why, display, i + 1, "the README holds an include marker already: migrate reads a README of the inline model", .{});
        }
    }
    if (why.items.len > 0) return .{ .refused = why.items };
    const exs = switch (try examples.extract(alloc, text, display, false)) {
        .examples => |e| e,
        .refused => |r| return .{ .refused = r },
    };
    const found = try regions(alloc, lines, exs);
    var fills = std.ArrayList(include.Fill).empty;
    var files = std.ArrayList(include.Listed).empty;
    for (exs, found, 0..) |ex, maybe, k| {
        const r = maybe orelse {
            try refuseLine(alloc, &why, display, ex.line, "the example's fence is not closed", .{});
            continue;
        };
        if (r.fence.indent != 0) {
            try refuseLine(alloc, &why, display, ex.line, "the example is indented (in a list item, say): an include marker starts its line, so move the fence out first", .{});
            continue;
        }
        var bad = false;
        for (ex.code, ex.code_lines) |l, n| {
            if (l.len > 0 and !include.isBlank(l) and (l[l.len - 1] == ' ' or l[l.len - 1] == '\t')) {
                try refuseLine(alloc, &why, display, n, "the line ends in a space or a tab, which a shown file may not", .{});
                bad = true;
            }
        }
        if (bad) continue;
        const path = try fileName(alloc, k + 1);
        const data = try exampleFile(alloc, ex);
        try files.append(alloc, .{ .path = path, .data = data });
        const body = try include.bodyOf(alloc, data);
        const length = include.fenceLength(body, r.fence.char, r.fence.length);
        const fence = try alloc.alloc(u8, length);
        @memset(fence, r.fence.char);
        // The region's lines become the marker, the fence and the file's lines.
        try fills.append(alloc, .{
            .open = r.first,
            .close = r.last,
            .open_text = try std.fmt.allocPrint(alloc, "{s}{s}{s}{s}\n{s}mojo", .{ include.MARKERS.open, include.MARKERS.include, path, include.MARKERS.close, fence }),
            .body = body,
            .close_text = fence,
        });
    }
    if (why.items.len > 0) return .{ .refused = why.items };
    return .{ .migrated = .{ .readme = try include.render(alloc, text, sp, fills.items), .files = files.items } };
}

// ---- verify -------------------------------------------------------------------

/// A line of a normalized program or region, and its 1-based line in the
/// text it came from.
const Norm = struct { text: []const u8, line: usize };

const Kind = enum {
    /// An example's code lines as the README holds them (hidden lines too).
    code,
    /// A program of a ```mojo example: `def main() raises:` wraps the lines.
    statements,
    /// A program of a ```mojo module example: the lines as they are.
    module,
};

/// `lines` (line n of them is line `first + n` of their text) without blank
/// lines and the generator's header; for `statements`, without the first
/// `def main() raises:` line and with four spaces taken off each line after
/// it. Two programs (or a program and an example's code) that normalize to
/// the same lines are the same program but for the differences a migration
/// may make.
fn normalize(alloc: Allocator, lines: []const []const u8, first: usize, kind: Kind) Allocator.Error![]const Norm {
    var out = std.ArrayList(Norm).empty;
    var in_main = false;
    for (lines, 0..) |l, n| {
        if (include.isBlank(l) or std.mem.startsWith(u8, l, program.GENERATED)) continue;
        var t = l;
        if (kind == .statements) {
            if (!in_main and std.mem.eql(u8, l, "def main() raises:")) {
                in_main = true;
                continue;
            }
            if (in_main and std.mem.startsWith(u8, l, "    ")) t = l[4..];
        }
        try out.append(alloc, .{ .text = t, .line = first + n });
    }
    return out.toOwnedSlice(alloc);
}

/// The index of the first entry where `a` and `b` differ (the shorter's
/// length when one is a prefix of the other); null when they are equal.
fn normDifference(a: []const Norm, b: []const Norm) ?usize {
    var n: usize = 0;
    while (n < a.len and n < b.len and std.mem.eql(u8, a[n].text, b[n].text)) n += 1;
    if (n == a.len and n == b.len) return null;
    return n;
}

fn shown(norm: []const Norm, n: usize) []const u8 {
    return if (n < norm.len) norm[n].text else "(nothing: it ends here)";
}

/// An include of the migrated README: its marker's path, the 0-based lines
/// of the marker and of the closing fence, and the fence's body.
const Shown = struct { path: []const u8, first: usize, last: usize, body: []const []const u8, body_first: usize };

fn includesOf(alloc: Allocator, lines: []const []const u8) Allocator.Error![]const Shown {
    const fences = try md.fences(alloc, lines);
    var out = std.ArrayList(Shown).empty;
    for (fences) |f| {
        if (f.open_line == 0) continue;
        const m = lines[f.open_line - 1];
        if (!examples.isInclude(m)) continue;
        const close = f.close_line orelse continue;
        const path = m[include.MARKERS.open.len + include.MARKERS.include.len .. m.len - include.MARKERS.close.len];
        try out.append(alloc, .{ .path = path, .first = f.open_line - 1, .last = close, .body = lines[f.open_line + 1 .. close], .body_first = f.open_line + 2 });
    }
    return out.toOwnedSlice(alloc);
}

/// Every refusal of the migration of `old` (named `display`) into the README
/// `new` and the files `files` (`examples/<name>`), one per line; empty when
/// it is proven (see the header).
pub fn verify(alloc: Allocator, old: []const u8, display: []const u8, new: []const u8, files: []const include.Listed) Allocator.Error![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    const exs = switch (try examples.extract(alloc, old, display, false)) {
        .examples => |e| e,
        .refused => |r| {
            try out.append(alloc, r);
            return out.toOwnedSlice(alloc);
        },
    };
    // The new README is fresh against the files, every file shown once.
    const checked = try include.check(alloc, &include.README, new, display, files);
    try out.appendSlice(alloc, checked.refusals);

    // The files are example_1 .. example_<n>, one per example.
    const by_example = try alloc.alloc(?include.Listed, exs.len);
    @memset(by_example, null);
    for (files) |f| {
        const at: ?usize = for (0..exs.len) |k| {
            if (std.mem.eql(u8, f.path, try fileName(alloc, k + 1))) break k;
        } else null;
        if (at) |k| {
            by_example[k] = f;
        } else {
            try out.append(alloc, try std.fmt.allocPrint(alloc, "{s}: {s} is no example's file: the old README has {d} examples, so the files are example_1 to example_{d}", .{ display, f.path, exs.len, exs.len }));
        }
    }

    // Each file is the program the gate runs today for its fence.
    for (exs, by_example, 0..) |ex, maybe, k| {
        const name = try fileName(alloc, k + 1);
        const f = maybe orelse {
            try out.append(alloc, try std.fmt.allocPrint(alloc, "{s}: {s}, the example at line {d}, is missing", .{ display, name, ex.line }));
            continue;
        };
        var msg: []const u8 = "";
        const generated = program.exampleProgram(alloc, ex, display, &msg) catch |e| switch (e) {
            error.Refused => {
                try out.append(alloc, msg);
                continue;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        const kind: Kind = if (ex.module) .module else .statements;
        const file_lines = try include.bodyOf(alloc, f.data);
        const want = try normalize(alloc, try include.bodyOf(alloc, generated), 1, kind);
        const got = try normalize(alloc, file_lines, 1, kind);
        if (normDifference(got, want)) |n| {
            const at = if (n < got.len) got[n].line else file_lines.len;
            try out.append(alloc, try std.fmt.allocPrint(alloc, "{s}:{d}: not the program the gate runs today for the example at {s}:{d}: `{s}` where that program has `{s}`", .{ try include.fileDisplay(alloc, display, name), at, display, ex.line, shown(got, n), shown(want, n) }));
        }
    }

    // The README differs only inside the examples.
    const old_lines = try md.splitLines(alloc, old);
    const new_lines = try md.splitLines(alloc, new);
    const found = try regions(alloc, old_lines, exs);
    const shows = try includesOf(alloc, new_lines);
    if (shows.len != exs.len) {
        try out.append(alloc, try std.fmt.allocPrint(alloc, "{s}: the migrated README shows {d} includes for the old one's {d} examples", .{ display, shows.len, exs.len }));
        return out.toOwnedSlice(alloc);
    }
    var o: usize = 0; // the next old line outside a region
    var p: usize = 0; // the next new line outside an include
    for (0..exs.len + 1) |k| {
        const old_end = if (k < exs.len) (if (found[k]) |r| r.first else old_lines.len) else old_lines.len;
        const new_end = if (k < exs.len) shows[k].first else new_lines.len;
        const a = old_lines[o..old_end];
        const b = new_lines[p..new_end];
        const d = include.firstDifference(a, b);
        if (d < a.len or d < b.len) {
            const line = p + d + 1;
            try out.append(alloc, try std.fmt.allocPrint(alloc, "{s}:{d}: the migrated README differs from the old one outside the examples: `{s}` where the old one has `{s}` (its line {d})", .{
                display,
                line,
                if (d < b.len) b[d] else "(nothing)",
                if (d < a.len) a[d] else "(nothing)",
                o + d + 1,
            }));
            break;
        }
        if (k == exs.len) break;
        const r = found[k] orelse {
            try out.append(alloc, try std.fmt.allocPrint(alloc, "{s}:{d}: the example's fence is not closed", .{ display, exs[k].line }));
            break;
        };
        const s = shows[k];
        const want_path = try fileName(alloc, k + 1);
        if (!std.mem.eql(u8, s.path, want_path)) {
            try out.append(alloc, try std.fmt.allocPrint(alloc, "{s}:{d}: the include of the example at old line {d} names {s}, not {s}", .{ display, s.first + 1, exs[k].line, s.path, want_path }));
        }
        const kind: Kind = if (exs[k].module) .module else .statements;
        const want = try normalize(alloc, exs[k].code, 1, .code);
        // The old code lines carry their own README lines; the new ones are
        // numbered from the fence's first body line.
        const got = try normalize(alloc, s.body, s.body_first, kind);
        if (normDifference(got, want)) |n| {
            const at = if (n < got.len) got[n].line else s.last + 1;
            try out.append(alloc, try std.fmt.allocPrint(alloc, "{s}:{d}: the example from old line {d} shows other code than it ran: `{s}` where the old README has `{s}`", .{ display, at, exs[k].line, shown(got, n), shown(want, n) }));
        }
        o = r.last + 1;
        p = s.last + 1;
    }
    return out.toOwnedSlice(alloc);
}
