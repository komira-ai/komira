//! The examples of every document that shows files
//! (docs/design/documentation_tests.md, "Include, `fill` and freshness"):
//! a package README and a task page alike. Each fence that shows a file is
//! named by the include marker on the line before it, a test runs that
//! file, and the document is held to the file byte for byte. What differs
//! between the two is a row of KINDS, and nothing else. Pure: no I/O.
//!
//!   - An include is the line `<!-- include <path> -->`, whole, at the
//!     start of a line, directly before a fence that also starts its line.
//!     `<path>` is relative to the document: the kind's directory, a plain
//!     name (no `/`, no `..`) and one of the kind's extensions, each of
//!     which names the fence word (KINDS). The fence's word is that word and
//!     its body is the file less one final line feed. When the file holds a
//!     line that would close the fence, the fence is longer than that
//!     line's run (`fill` makes it so).
//!   - A file shown so is not empty, ends in a line feed, and holds no byte
//!     order mark, no carriage return and no line that ends in a space or a
//!     tab.
//!   - Every file the document must show is shown by exactly one include
//!     (a README: each `.mojo` its library lists; a task page: `example.py`
//!     and `expected_output.txt`), and no file is shown twice.
//!   - A fence of the kind's code word (`mojo`, `mojo module` too, for a
//!     README; `python` for a task page) is an include; a task page may
//!     instead give `<!-- not-tested: <reason> -->` on the line before it.
//!   - A ```text fence directly after code (a fence whose word is not
//!     `text`) or after an included fence, with only blank lines between,
//!     is output no run printed unless it is itself an include, so it says
//!     why: `<!-- not-tested: <reason> -->` on the line before it. A
//!     not-tested marker stands on the line just before a fence, and gives
//!     a reason.
//!   - The inline model's hidden lines (`<!-- mojo-hidden`) are refused: the
//!     lines go in the file, where the reader sees them. So is a comment that
//!     misspells a marker (`<!--include`, `<!-- Include`, `<!-- not-tested -->`,
//!     text after the `-->`): it would hide nothing and show nothing.
//!   - A README's `examples/<name>.expected_output.txt` is what
//!     `examples/<name>.mojo` prints (its welded test compares the two,
//!     output.zig); the README may show it, and lists it only beside that
//!     `.mojo`.
//!
//! `check` returns every refusal of those rules and the document as `fill`
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
const markers = @import("markers.zig");
const Allocator = std.mem.Allocator;

/// The marker words, spelled once (markers.zig).
pub const MARKERS = markers.MARKERS;

/// The first word of an HTML comment block that makes it a marker comment,
/// which a renderer drops: an include, a not-tested reason, and the inline
/// model's hidden lines (refused in a new README, still read in a published
/// one).
pub const MARKER_WORDS = [_][]const u8{ "include", "not-tested:", "mojo-hidden" };

/// Where the files of a README's includes are, relative to the README, and
/// the extension of an example (migrate.zig names its files so).
pub const DIR = "examples/";
pub const EXT = ".mojo";
/// The extension of a README example's expected output, beside its `.mojo`.
pub const EXPECTED_EXT = ".expected_output.txt";

/// An extension an include may name, and the fence word that shows it.
pub const Ext = struct {
    ext: []const u8,
    word: []const u8,
    /// Every listed file of this extension is shown by an include.
    shown: bool,
    /// The extension of the file this one is the output of, which must be
    /// listed beside it (`<name>` the same), or null.
    output_of: ?[]const u8 = null,
};

/// A kind of document that shows files: one row of the rule table
/// (docs/design/documentation_tests.md, "Source-first for every kind that
/// shows code"). Every rule of `check` is the same for every kind; a row
/// says only where the files are, how each is fenced, which must be shown,
/// and how a refusal names them.
pub const Kind = struct {
    /// Its name, as `check --kind` and `fill --kind` take it.
    name: []const u8,
    /// The document, as a refusal names it.
    doc: []const u8,
    /// The directory, relative to the document, of the files it shows (""
    /// for the document's own).
    dir: []const u8,
    /// The extensions an include may name, each with its fence word.
    exts: []const Ext,
    /// What an include names, as a refusal says it.
    pattern: []const u8,
    /// The files every document of the kind shows, when they are listed.
    required: []const []const u8,
    /// Whether a listed file of no extension of `exts` must be shown too
    /// (and so is refused, since no include can show it): a README's list
    /// is its examples alone, a task directory's every file it holds.
    show_unknown: bool,
    /// The fence word whose fences are code a run must back.
    code: []const u8,
    /// Whether a not-tested reason may stand for an include on such a fence.
    untested_code: bool,
    /// The refusal of a code fence that shows no file, after its fence.
    code_rule: []const u8,
    /// Where the files are listed, as the refusal of an unlisted include
    /// says it (the path follows).
    unlisted: []const u8,
    /// The refusal of a file that must be shown and is not, after its path
    /// (`and no <!-- include ... --> shows it` follows).
    unshown: []const u8,
    /// The stale refusal's last words: how the author mends it.
    fill_hint: []const u8,
};

/// A package README (src/<pkg>/README.md; tools/build/mojo/readme.bzl).
pub const README = Kind{
    .name = "readme",
    .doc = "a source-first README",
    .dir = DIR,
    .exts = &.{
        .{ .ext = EXT, .word = "mojo", .shown = true },
        .{ .ext = EXPECTED_EXT, .word = "text", .shown = false, .output_of = EXT },
    },
    .pattern = "examples/<name>.mojo",
    .required = &.{},
    .show_unknown = true,
    .code = "mojo",
    .untested_code = false,
    .code_rule = "every example of a source-first README is a file of examples/, shown by <!-- include examples/<name>.mojo --> on the line before its fence",
    .unlisted = "no such example: the library's readme_examples (its BUCK file) lists no",
    .unshown = "is listed in readme_examples",
    .fill_hint = "build the library's [tests][readme][fill] sub-target and apply the patch it writes with git apply",
};

/// A task page (python/docs/tasks/<rank>-<slug>/page.md; tasks.zig,
/// python/task_examples.bzl).
pub const TASK = Kind{
    .name = "task",
    .doc = "a task page",
    .dir = "",
    .exts = &.{
        .{ .ext = ".py", .word = "python", .shown = false },
        .{ .ext = ".txt", .word = "text", .shown = false },
    },
    .pattern = "<file>",
    .required = &.{ "example.py", "expected_output.txt" },
    .show_unknown = false,
    .code = "python",
    .untested_code = true,
    .code_rule = "put <!-- include <file> --> or <!-- not-tested: <reason> --> on the line before it",
    .unlisted = "the task directory has no",
    .unshown = "is a file every task page shows",
    .fill_hint = "build the [fill] sub-target of the task pages' check (:pages of the tree's BUCK file) and apply the patch it writes with git apply",
};

/// Every kind, the rule table.
pub const KINDS = [_]*const Kind{ &README, &TASK };

/// The kind named `name`, or null.
pub fn kindNamed(name: []const u8) ?*const Kind {
    for (KINDS) |k| {
        if (std.mem.eql(u8, k.name, name)) return k;
    }
    return null;
}

/// The README kind's stale hint (the README tests name it).
pub const FILL_HINT = README.fill_hint;

/// A file the document may show: its path as an include names it
/// (`examples/<name>.mojo`, `example.py`) and its bytes.
pub const Listed = struct {
    path: []const u8,
    data: []const u8,
};

pub const Checked = struct {
    /// Every refusal, one line each, in document line order (those naming
    /// no line last): `<display>:<line>: ...` or `<display>: ...`.
    refusals: []const []const u8,
    /// The document as `fill` writes it. `text` itself when not `fillable`.
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

/// The extension of `kind` that the path an include names has, when the
/// path is the kind's directory, a plain name (no `/`, no `..`) and that
/// extension; null otherwise.
pub fn extOf(kind: *const Kind, path: []const u8) ?*const Ext {
    if (!std.mem.startsWith(u8, path, kind.dir)) return null;
    const rest = path[kind.dir.len..];
    if (std.mem.indexOfScalar(u8, rest, '/') != null or std.mem.indexOf(u8, rest, "..") != null) return null;
    for (kind.exts) |*e| {
        if (std.mem.endsWith(u8, rest, e.ext) and rest.len > e.ext.len) return e;
    }
    return null;
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
    if (data[data.len - 1] != '\n') return try std.fmt.allocPrint(alloc, "{s} does not end in a line feed", .{name});
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

/// Whether the last non-blank line before `line` (an index) closes a code
/// fence (one whose word is not `text`, nor empty) or an included fence.
fn followsCode(lines: []const []const u8, fences: []const md.Fence, included: []const bool, line: usize) bool {
    var i = line;
    while (i > 0) {
        i -= 1;
        if (isBlank(lines[i])) continue;
        for (fences, 0..) |g, k| {
            const cl = g.close_line orelse continue;
            if (cl != i) continue;
            const word = firstWord(g.info);
            return included[k] or (word.len > 0 and !std.mem.eql(u8, word, "text"));
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

/// The refusals of the document `text` of kind `kind` (named `display`),
/// whose files are `listed`, and the document as `fill` writes it.
pub fn check(alloc: Allocator, kind: *const Kind, text: []const u8, display: []const u8, listed: []const Listed) Allocator.Error!Checked {
    const lines = try md.splitLines(alloc, text);
    const sp = try spans(alloc, text);
    const fences = try md.fences(alloc, lines);
    const mask = try md.codeMask(alloc, lines);
    var refusals = std.ArrayList(Refusal).empty;
    const c = Ctx{ .alloc = alloc, .display = display, .out = &refusals };
    // The document line of the include that shows each listed file; 0 for none.
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
        if (markers.marker(lines[i], MARKERS.include)) |path| {
            const k_fence = fenceAt(fences, i + 1) orelse {
                try c.refuse(at, "the include of {s} is not on the line just before a fence", .{path});
                fillable = false;
                continue;
            };
            const f = fences[k_fence];
            // Shown, even when refused below: its refusal is the one to mend.
            included[k_fence] = true;
            const ext = extOf(kind, path) orelse {
                try c.refuse(at, "include \"{s}\": {s} shows {s}", .{ path, kind.doc, try shapes(alloc, kind) });
                fillable = false;
                continue;
            };
            const k = findListed(listed, path) orelse {
                try c.refuse(at, "include {s}: {s} {s}", .{ path, kind.unlisted, path });
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
            if (!std.mem.eql(u8, f.info, ext.word)) {
                try c.refuse(f.open_line + 1, "include {s} is shown in a ```{s} fence; a {s} file is shown in ```{s}", .{ path, f.info, ext.ext, ext.word });
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
                .open_text = if (length == f.length) lines[f.open_line] else try std.mem.concat(alloc, u8, &.{ fence, ext.word }),
                .body = want,
                .close_text = if (length == f.length) lines[close] else fence,
            });
            const have = lines[f.open_line + 1 .. close];
            if (length != f.length) {
                try c.refuse(f.open_line + 1, "include {s}: {s} holds a line that closes a fence of {d}, so its fence is {d} long; {s}", .{ path, name, f.length, length, kind.fill_hint });
            } else if (!eqlLines(have, want)) {
                const d = firstDifference(have, want);
                try c.refuse(f.open_line + 2 + d, "include {s} is stale: this line is not line {d} of {s}; {s}", .{ path, d + 1, name, kind.fill_hint });
            }
            continue;
        }
        if (markers.marker(lines[i], MARKERS.not_tested)) |why| {
            if (md.strip(why).len == 0) try c.refuse(at, "a not-tested marker gives no reason", .{});
            if (fenceAt(fences, i + 1) == null) try c.refuse(at, "a not-tested marker is not on the line just before a fence", .{});
            continue;
        }
        if (std.mem.eql(u8, commentWord(body), "mojo-hidden")) {
            try c.refuse(at, "hidden lines (`<!-- mojo-hidden`) are the inline model's: {s} shows the whole file, so the lines go in the example's file", .{kind.doc});
            continue;
        }
        if (try nearMiss(alloc, body)) {
            try c.refuse(at, "`{s}` is not a marker: an include is the whole line `<!-- include {s} -->` and a reason the whole line `<!-- not-tested: <reason> -->`, each at the start of its line", .{ md.strip(lines[i]), kind.pattern });
        }
    }

    for (fences, 0..) |f, k| {
        if (included[k]) continue;
        const word = firstWord(f.info);
        const reason = f.open_line > 0 and markers.marker(lines[f.open_line - 1], MARKERS.not_tested) != null;
        if (std.mem.eql(u8, word, kind.code)) {
            if (!(reason and kind.untested_code)) try c.refuse(f.open_line + 1, "a ```{s} fence that shows no file: {s}", .{ f.info, kind.code_rule });
            continue;
        }
        if (!std.mem.eql(u8, word, "text")) continue;
        if (!reason and followsCode(lines, fences, included, f.open_line)) {
            try c.refuse(f.open_line + 1, "a ```text fence right after code shows output no run printed: include its file, or put <!-- not-tested: <reason> --> on the line before it", .{});
        }
    }

    var shown: usize = 0;
    for (listed, shown_at) |l, at| {
        if (at != 0) {
            shown += 1;
            continue;
        }
        const must = if (extOf(kind, l.path)) |e| e.shown or isRequired(kind, l.path) else kind.show_unknown;
        if (must) try c.refuse(null, "{s} {s} and no <!-- include {s} --> shows it", .{ l.path, kind.unshown, l.path });
    }
    for (listed) |l| {
        const e = extOf(kind, l.path) orelse continue;
        const of = e.output_of orelse continue;
        const program = try std.mem.concat(alloc, u8, &.{ l.path[0 .. l.path.len - e.ext.len], of });
        if (findListed(listed, program) == null) try c.refuse(null, "{s} is the expected output of {s}, which is not listed", .{ l.path, program });
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

fn isRequired(kind: *const Kind, path: []const u8) bool {
    for (kind.required) |r| {
        if (std.mem.eql(u8, r, path)) return true;
    }
    return false;
}

/// What an include of `kind` may name, for its refusal:
/// `examples/<name>.mojo or examples/<name>.expected_output.txt, a file of
/// examples/ beside it` or `<name>.py or <name>.txt, a file beside it`.
fn shapes(alloc: Allocator, kind: *const Kind) Allocator.Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (kind.exts, 0..) |e, k| {
        if (k > 0) try out.appendSlice(alloc, " or ");
        try out.writer(alloc).print("{s}<name>{s}", .{ kind.dir, e.ext });
    }
    if (kind.dir.len > 0) {
        try out.writer(alloc).print(", a file of {s} beside it", .{kind.dir});
    } else {
        try out.appendSlice(alloc, ", a file beside it named alone");
    }
    return out.toOwnedSlice(alloc);
}
