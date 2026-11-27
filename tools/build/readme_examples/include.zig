//! The examples of a source-first README (docs/design/documentation_tests.md,
//! "Include, `fill` and freshness"): each ```mojo fence shows a file of the
//! `examples/` directory beside the README, named by the include marker on
//! the line before it, and a test runs that file. Pure: no I/O.
//!
//!   - An include is the line `<!-- include examples/<name>.mojo -->`,
//!     whole, at the start of a line, directly before a fence that also
//!     starts its line. The fence's word is `mojo` and its body is the file
//!     less one final line feed. When the file holds a line that would close
//!     the fence, the fence is longer than that line's run (`fill` makes it
//!     so).
//!   - A file shown so is not empty and holds no byte order mark, no
//!     carriage return and no line that ends in a space or a tab.
//!   - Every file the library lists (`readme_examples` in its BUCK file) is
//!     shown by exactly one include, and every ```mojo fence (`mojo module`
//!     too) is an include: no example of a source-first README is inline.
//!   - A ```text fence directly after an included fence, with only blank
//!     lines between, is output no run printed, so it says why:
//!     `<!-- not-tested: <reason> -->` on the line before it. A not-tested
//!     marker stands on the line just before a fence, and gives a reason.
//!   - Other fences stay inline: `text` sketches, `sh` commands, and (in
//!     this tier) `python`, which a README includes once it shows `.py`
//!     files.
//!   - The inline model's hidden lines (`<!-- mojo-hidden`) are refused: the
//!     lines go in the file, where the reader sees them. So is a comment that
//!     misspells a marker (`<!--include`, `<!-- Include`, `<!-- not-tested -->`,
//!     text after the `-->`): it would hide nothing and show nothing.
//!
//! `check` returns every refusal of those rules and the README as `fill`
//! writes it: the body of every include rewritten from its file (and the
//! fence lengthened when the file needs it), every other byte as it was. The
//! freshness check is the rules plus "fill changes no byte".
//!
//! `dropMarkers` is what a renderer that draws HTML comments as text must
//! drop (a block whose first word is one of MARKER_WORDS);
//! marker_comments.json holds its cases, shared with the package site's
//! renderer.

const std = @import("std");
const md = @import("markdown");
const task_page = @import("task_page.zig");
const Allocator = std.mem.Allocator;

/// The marker words, spelled once (task_page.zig).
pub const MARKERS = task_page.MARKERS;

/// The first word of an HTML comment block that makes it a marker comment,
/// which a renderer drops: an include, a not-tested reason, and the inline
/// model's hidden lines (refused in a new README, still read in a published
/// one).
pub const MARKER_WORDS = [_][]const u8{ "include", "not-tested:", "mojo-hidden" };

/// Where the files of a README's includes are, relative to the README.
pub const DIR = "examples/";
pub const EXT = ".mojo";

/// The stale refusal's last words: how the author mends it.
pub const FILL_HINT = "build the library's [tests][readme][fill] sub-target and apply the patch it writes with git apply";

/// A file the library lists: its path as an include names it
/// (`examples/<name>.mojo`) and its bytes.
pub const Listed = struct {
    path: []const u8,
    data: []const u8,
};

pub const Checked = struct {
    /// Every refusal, one line each, in README line order (those naming no
    /// line last): `<display>:<line>: ...` or `<display>: ...`.
    refusals: []const []const u8,
    /// The README as `fill` writes it. `text` itself when not `fillable`.
    filled: []const u8,
    /// False when an include cannot be filled (a refusal says why).
    fillable: bool,
    /// How many listed files an include shows.
    shown: usize,
};

const Refusal = struct { line: usize, text: []const u8 };

const NO_LINE = std.math.maxInt(usize);

fn byLine(_: void, a: Refusal, b: Refusal) bool {
    return a.line < b.line;
}

const Ctx = struct {
    alloc: Allocator,
    display: []const u8,
    out: *std.ArrayList(Refusal),

    /// Records a refusal naming README line `line` (from 1), or none.
    fn refuse(self: Ctx, line: ?usize, comptime f: []const u8, args: anytype) Allocator.Error!void {
        const what = try std.fmt.allocPrint(self.alloc, f, args);
        const text = if (line) |l|
            try std.fmt.allocPrint(self.alloc, "{s}:{d}: {s}", .{ self.display, l, what })
        else
            try std.fmt.allocPrint(self.alloc, "{s}: {s}", .{ self.display, what });
        try self.out.append(self.alloc, .{ .line = line orelse NO_LINE, .text = text });
    }
};

/// A line of a text as md.splitLines cuts it: its bytes are
/// `text[start..end]`, and the next line starts at `next` (after this one's
/// line ending, which is `text[end..next]`).
pub const Span = struct { start: usize, end: usize, next: usize };

/// The lines of `text`, cut exactly where md.splitLines cuts them ("\n",
/// "\r\n" or a lone "\r"; a final line ending starts no empty line).
pub fn spans(alloc: Allocator, text: []const u8) Allocator.Error![]Span {
    var out = std.ArrayList(Span).empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c != '\n' and c != '\r') continue;
        const end = i;
        if (c == '\r' and i + 1 < text.len and text[i + 1] == '\n') i += 1;
        try out.append(alloc, .{ .start = start, .end = end, .next = i + 1 });
        start = i + 1;
    }
    if (start < text.len) try out.append(alloc, .{ .start = start, .end = text.len, .next = text.len });
    return out.toOwnedSlice(alloc);
}

/// The info string up to its first space or tab.
pub fn firstWord(info: []const u8) []const u8 {
    var k: usize = 0;
    while (k < info.len and info[k] != ' ' and info[k] != '\t') k += 1;
    return info[0..k];
}

pub fn isBlank(s: []const u8) bool {
    return md.indentOf(s) == s.len;
}

fn lower(alloc: Allocator, s: []const u8) Allocator.Error![]const u8 {
    const out = try alloc.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

/// The text of a comment block's opening line after `<!--`, without the
/// whitespace around it. `line` holds `<!--` after its indent.
fn commentText(line: []const u8) []const u8 {
    return md.strip(md.strip(line)[4..]);
}

/// The first word of a comment's text: up to whitespace or `-->`.
fn commentWord(text: []const u8) []const u8 {
    var k: usize = 0;
    while (k < text.len and !md.isSpace(text[k])) : (k += 1) {
        if (std.mem.startsWith(u8, text[k..], "-->")) break;
    }
    return text[0..k];
}

/// Whether the comment block that opens on `line` is a marker comment: its
/// first word is one of MARKER_WORDS, exactly.
pub fn isMarkerComment(line: []const u8) bool {
    const w = commentWord(commentText(line));
    for (MARKER_WORDS) |m| {
        if (std.mem.eql(u8, w, m)) return true;
    }
    return false;
}

/// `text` without the lines of its marker comments: what a renderer that
/// draws HTML comments as text shows (and what one that hides them, as
/// GitHub does, shows anyway). Every other byte is kept.
pub fn dropMarkers(alloc: Allocator, text: []const u8) Allocator.Error![]const u8 {
    const lines = try md.splitLines(alloc, text);
    const sp = try spans(alloc, text);
    const mask = try md.codeMask(alloc, lines);
    const drop = try alloc.alloc(bool, lines.len);
    @memset(drop, false);
    for (try md.htmlComments(alloc, lines, mask)) |c| {
        if (!isMarkerComment(lines[c.open_line])) continue;
        const last = c.close_line orelse lines.len - 1;
        @memset(drop[c.open_line .. last + 1], true);
    }
    var out = std.ArrayList(u8).empty;
    for (sp, 0..) |s, i| {
        if (!drop[i]) try out.appendSlice(alloc, text[s.start..s.next]);
    }
    return out.toOwnedSlice(alloc);
}

/// Whether a comment whose text is `text`, on a line that is no marker,
/// starts with a word a misspelt include or not-tested marker starts with,
/// in any case (`Include`, `not_tested:`, `not tested`, `Mojo-hidden`).
fn nearMiss(alloc: Allocator, text: []const u8) Allocator.Error!bool {
    var w = try lower(alloc, commentWord(text));
    if (std.mem.endsWith(u8, w, ":")) w = w[0 .. w.len - 1];
    const words = [_][]const u8{ "include", "not-tested", "not_tested", "nottested", "mojo-hidden", "mojo_hidden", "mojohidden" };
    for (words) |n| {
        if (std.mem.eql(u8, w, n)) return true;
    }
    if (std.mem.eql(u8, w, "not")) {
        const rest = md.strip(text[3..]);
        return std.ascii.startsWithIgnoreCase(rest, "tested");
    }
    return false;
}

/// The path an include names, when it is `examples/<name>.mojo` with a
/// plain name (no `/`, no `..`).
pub fn validPath(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, DIR) or !std.mem.endsWith(u8, path, EXT)) return false;
    if (path.len <= DIR.len + EXT.len) return false;
    const name = path[DIR.len .. path.len - EXT.len];
    if (std.mem.indexOfScalar(u8, name, '/') != null) return false;
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    return true;
}

/// The path `display` names a README's example by: the README's directory
/// and `path`.
pub fn fileDisplay(alloc: Allocator, display: []const u8, path: []const u8) Allocator.Error![]const u8 {
    const dir = std.fs.path.dirname(display) orelse return path;
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, path });
}

/// Why the file named `name` (as a message names it) with bytes `data`
/// cannot be shown in a fence, or null.
pub fn fileRefusal(alloc: Allocator, name: []const u8, data: []const u8) Allocator.Error!?[]const u8 {
    if (data.len == 0 or std.mem.eql(u8, data, "\n")) return try std.fmt.allocPrint(alloc, "{s} is empty", .{name});
    if (std.mem.startsWith(u8, data, "\xEF\xBB\xBF")) return try std.fmt.allocPrint(alloc, "{s} starts with a byte order mark", .{name});
    if (std.mem.indexOfScalar(u8, data, '\r') != null) return try std.fmt.allocPrint(alloc, "{s} holds a carriage return", .{name});
    var it = std.mem.splitScalar(u8, data, '\n');
    var n: usize = 0;
    while (it.next()) |l| {
        n += 1;
        if (l.len > 0 and (l[l.len - 1] == ' ' or l[l.len - 1] == '\t')) {
            return try std.fmt.allocPrint(alloc, "{s}:{d}: the line ends in a space or a tab", .{ name, n });
        }
    }
    return null;
}

/// The lines of a fence that shows the file `data`: the file less one final
/// line feed, cut at each line feed.
pub fn bodyOf(alloc: Allocator, data: []const u8) Allocator.Error![]const []const u8 {
    const t = if (data.len > 0 and data[data.len - 1] == '\n') data[0 .. data.len - 1] else data;
    var out = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, t, '\n');
    while (it.next()) |l| try out.append(alloc, l);
    return out.toOwnedSlice(alloc);
}

/// The length a fence of `char` must have to hold `body`: at least `have`,
/// and longer than any run of `char` in a body line that would close it.
pub fn fenceLength(body: []const []const u8, char: u8, have: usize) usize {
    var need: usize = @max(have, 3);
    for (body) |l| {
        if (!md.closes(l, char, 3)) continue;
        const i = md.indentOf(l);
        var run: usize = 0;
        while (i + run < l.len and l[i + run] == char) run += 1;
        if (run + 1 > need) need = run + 1;
    }
    return need;
}

fn eqlLines(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

/// The index of the first line where `a` and `b` differ (the shorter one's
/// length when one is a prefix of the other).
pub fn firstDifference(a: []const []const u8, b: []const []const u8) usize {
    var n: usize = 0;
    while (n < a.len and n < b.len and std.mem.eql(u8, a[n], b[n])) n += 1;
    return n;
}

fn repeat(alloc: Allocator, c: u8, n: usize) Allocator.Error![]const u8 {
    const out = try alloc.alloc(u8, n);
    @memset(out, c);
    return out;
}

/// What `fill` writes over the lines `open`..`close` (0-based, the fence's
/// own lines) of an include.
pub const Fill = struct {
    open: usize,
    close: usize,
    open_text: []const u8,
    body: []const []const u8,
    close_text: []const u8,
};

fn fenceAt(fences: []const md.Fence, line: usize) ?usize {
    for (fences, 0..) |f, k| {
        if (f.open_line == line) return k;
    }
    return null;
}

fn findListed(listed: []const Listed, path: []const u8) ?usize {
    for (listed, 0..) |l, k| {
        if (std.mem.eql(u8, l.path, path)) return k;
    }
    return null;
}

/// Whether the last non-blank line before `line` (an index) closes an
/// included fence.
fn followsInclude(lines: []const []const u8, fences: []const md.Fence, included: []const bool, line: usize) bool {
    var i = line;
    while (i > 0) {
        i -= 1;
        if (isBlank(lines[i])) continue;
        for (fences, 0..) |g, k| {
            if (included[k] and g.close_line != null and g.close_line.? == i) return true;
        }
        return false;
    }
    return false;
}

/// `text` with each include's fence written as `fills` says (in document
/// order), every other byte as it was.
pub fn render(alloc: Allocator, text: []const u8, sp: []const Span, fills: []const Fill) Allocator.Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    var li: usize = 0;
    for (fills) |f| {
        if (li < f.open) try out.appendSlice(alloc, text[sp[li].start..sp[f.open].start]);
        const open_end = text[sp[f.open].end..sp[f.open].next];
        const nl = if (open_end.len == 0) "\n" else open_end;
        try out.appendSlice(alloc, f.open_text);
        try out.appendSlice(alloc, nl);
        for (f.body) |l| {
            try out.appendSlice(alloc, l);
            try out.appendSlice(alloc, nl);
        }
        try out.appendSlice(alloc, f.close_text);
        try out.appendSlice(alloc, text[sp[f.close].end..sp[f.close].next]);
        li = f.close + 1;
    }
    if (li < sp.len) try out.appendSlice(alloc, text[sp[li].start..]);
    return out.toOwnedSlice(alloc);
}

/// The refusals of the source-first README `text` (named `display`) whose
/// library lists `listed`, and the README as `fill` writes it.
pub fn check(alloc: Allocator, text: []const u8, display: []const u8, listed: []const Listed) Allocator.Error!Checked {
    const lines = try md.splitLines(alloc, text);
    const sp = try spans(alloc, text);
    const fences = try md.fences(alloc, lines);
    const mask = try md.codeMask(alloc, lines);
    var refusals = std.ArrayList(Refusal).empty;
    const c = Ctx{ .alloc = alloc, .display = display, .out = &refusals };
    // The README line of the include that shows each listed file; 0 for none.
    const shown_at = try alloc.alloc(usize, listed.len);
    @memset(shown_at, 0);
    const included = try alloc.alloc(bool, fences.len);
    @memset(included, false);
    var fills = std.ArrayList(Fill).empty;
    var fillable = true;

    for (try md.htmlComments(alloc, lines, mask)) |cm| {
        const i = cm.open_line;
        const at = i + 1;
        const body = commentText(lines[i]);
        if (task_page.marker(lines[i], MARKERS.include)) |path| {
            const k_fence = fenceAt(fences, i + 1) orelse {
                try c.refuse(at, "the include of {s} is not on the line just before a fence", .{path});
                fillable = false;
                continue;
            };
            const f = fences[k_fence];
            // Shown, even when refused below: its refusal is the one to mend.
            included[k_fence] = true;
            if (!validPath(path)) {
                try c.refuse(at, "include \"{s}\": a README shows examples/<name>.mojo, a file of the examples directory beside it", .{path});
                fillable = false;
                continue;
            }
            const k = findListed(listed, path) orelse {
                try c.refuse(at, "include {s}: no such example: the library's readme_examples (its BUCK file) lists no {s}", .{ path, path });
                fillable = false;
                continue;
            };
            if (shown_at[k] != 0) {
                try c.refuse(at, "include {s}: line {d} shows it already; each file is shown once", .{ path, shown_at[k] });
            } else {
                shown_at[k] = at;
            }
            if (f.indent != 0) {
                try c.refuse(f.open_line + 1, "include {s}: the fence after it does not start its line", .{path});
                fillable = false;
                continue;
            }
            if (!std.mem.eql(u8, f.info, "mojo")) {
                try c.refuse(f.open_line + 1, "include {s} is shown in a ```{s} fence; a .mojo file is shown in ```mojo", .{ path, f.info });
                fillable = false;
                continue;
            }
            const close = f.close_line orelse {
                try c.refuse(f.open_line + 1, "include {s}: the fence is never closed", .{path});
                fillable = false;
                continue;
            };
            const name = try fileDisplay(alloc, display, path);
            if (try fileRefusal(alloc, name, listed[k].data)) |why| {
                try c.refuse(at, "include {s}: {s}", .{ path, why });
                fillable = false;
                continue;
            }
            const want = try bodyOf(alloc, listed[k].data);
            const length = fenceLength(want, f.char, f.length);
            const fence = try repeat(alloc, f.char, length);
            try fills.append(alloc, .{
                .open = f.open_line,
                .close = close,
                .open_text = if (length == f.length) lines[f.open_line] else try std.mem.concat(alloc, u8, &.{ fence, "mojo" }),
                .body = want,
                .close_text = if (length == f.length) lines[close] else fence,
            });
            const have = lines[f.open_line + 1 .. close];
            if (length != f.length) {
                try c.refuse(f.open_line + 1, "include {s}: {s} holds a line that closes a fence of {d}, so its fence is {d} long; {s}", .{ path, name, f.length, length, FILL_HINT });
            } else if (!eqlLines(have, want)) {
                const d = firstDifference(have, want);
                try c.refuse(f.open_line + 2 + d, "include {s} is stale: this line is not line {d} of {s}; {s}", .{ path, d + 1, name, FILL_HINT });
            }
            continue;
        }
        if (task_page.marker(lines[i], MARKERS.not_tested)) |why| {
            if (md.strip(why).len == 0) try c.refuse(at, "a not-tested marker gives no reason", .{});
            if (fenceAt(fences, i + 1) == null) try c.refuse(at, "a not-tested marker is not on the line just before a fence", .{});
            continue;
        }
        if (std.mem.eql(u8, commentWord(body), "mojo-hidden")) {
            try c.refuse(at, "hidden lines (`<!-- mojo-hidden`) are the inline model's: a source-first README shows the whole file, so the lines go in the example's file", .{});
            continue;
        }
        if (try nearMiss(alloc, body)) {
            try c.refuse(at, "`{s}` is not a marker: an include is the whole line `<!-- include examples/<name>.mojo -->` and a reason the whole line `<!-- not-tested: <reason> -->`, each at the start of its line", .{md.strip(lines[i])});
        }
    }

    for (fences, 0..) |f, k| {
        if (included[k]) continue;
        const word = firstWord(f.info);
        if (std.mem.eql(u8, word, "mojo")) {
            try c.refuse(f.open_line + 1, "a ```{s} fence that shows no file: every example of a source-first README is a file of examples/," ++
                " shown by <!-- include examples/<name>.mojo --> on the line before its fence", .{f.info});
            continue;
        }
        if (!std.mem.eql(u8, word, "text")) continue;
        const reason = f.open_line > 0 and task_page.marker(lines[f.open_line - 1], MARKERS.not_tested) != null;
        if (!reason and followsInclude(lines, fences, included, f.open_line)) {
            try c.refuse(f.open_line + 1, "a ```text fence right after an included example shows output no run printed: put <!-- not-tested: <reason> --> on the line before it", .{});
        }
    }

    var shown: usize = 0;
    for (listed, shown_at) |l, at| {
        if (at != 0) {
            shown += 1;
        } else {
            try c.refuse(null, "{s} is listed in readme_examples and no <!-- include {s} --> shows it", .{ l.path, l.path });
        }
    }

    // Document order; stable, so refusals of one line keep their order.
    std.sort.insertion(Refusal, refusals.items, {}, byLine);
    const texts = try alloc.alloc([]const u8, refusals.items.len);
    for (refusals.items, 0..) |r, k| texts[k] = r.text;
    return .{
        .refusals = texts,
        .filled = if (fillable) try render(alloc, text, sp, fills.items) else text,
        .fillable = fillable,
        .shown = shown,
    };
}
