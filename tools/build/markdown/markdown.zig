//! What a Markdown file holds as code, and its links. Pure: no I/O.
//!
//! The README examples tool and the doc link check read Markdown through
//! this module, so they agree on what is code and what is a link.
//!
//! Lines. A document is split on its line endings, as CommonMark's: "\n",
//! "\r\n" or a lone "\r". A final line ending ends the last line rather
//! than starting an empty one. Line numbers are 0-based indexes into those
//! lines.
//!
//! Fences follow CommonMark: a run of three or more backticks or tildes opens
//! a fenced block, and only a run of the SAME character, at least as long,
//! with nothing but whitespace after it, closes it. So a ```` fence may quote
//! ```, and a ~~~ block may quote a ``` line. A backtick fence's info string
//! may not hold a backtick (that line is not a fence). A block left open runs
//! to the end of the document. Container blocks are not modelled: a fence is
//! recognised at any indentation, because a fence inside a list item is
//! indented. Fences are read before HTML comments, so a fence line inside
//! `<!-- -->` still opens a block.
//!
//! Code spans follow CommonMark within one line: a run of N backticks opens
//! a span that the next run of exactly N backticks closes; a run with no
//! such partner is literal text. A span never crosses a line here.
//!
//! Links: the target of every inline link or image `[text](target)`, with an
//! optional `<...>` around the target and an optional title ("...", '...' or
//! (...)) after whitespace, and of every reference definition `[id]: target`
//! (up to three spaces before it, `<...>` around the target optional). Links
//! are not read in fenced blocks, in code spans, or in an HTML block that
//! opens with `<!--` (CommonMark type 2: from that line to the first line
//! holding `-->`, the opening line included, so `<!-->` is a whole block),
//! which is raw HTML, never Markdown.
//!
//! Whitespace is CommonMark's: space, tab, line feed, line tabulation, form
//! feed, carriage return (bytes 32 and 9..13).
//!
//! Where this differs from CommonMark, it reports a link CommonMark would
//! not, never the reverse, except for empty and unmodelled targets below
//! (a link checker that over-reports asks for a fix; one that under-reports
//! lets a broken link through):
//! - A reference definition is read on any line, also one that would
//!   continue a paragraph (CommonMark: a definition cannot interrupt a
//!   paragraph, so `x\n[r]: r.md` is one paragraph there).
//! - Indented code blocks and container blocks (lists, block quotes) are not
//!   modelled: a line indented four spaces is prose here.
//! - An HTML comment opener that is not first on its line, and every other
//!   kind of raw HTML, hides nothing.
//! - What follows a reference definition's target on its line is not
//!   checked (CommonMark: only a title may follow, or the line is no
//!   definition).
//! - An empty target, `[e]()` or `[r]: <>`, is no link (CommonMark: a link
//!   to the empty destination).
//! Not modelled, so not read as CommonMark reads them: brackets nested more
//! than one level in link text; parentheses in a target (`[a](f(x).md)`
//! reads `f(x`); a `<...>` target holding whitespace (`<a b.md>`, no link
//! here); backslash escapes and entity references (a target is the bytes
//! as written); links, titles and definitions spanning lines; reference
//! links `[text][id]` themselves (their definition is read instead).
//!
//! Every slice a function returns either points into its input or was
//! allocated with the allocator it was given; callers pass an arena.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ---- text ------------------------------------------------------------------

pub fn isSpace(c: u8) bool {
    return c == ' ' or (c >= 9 and c <= 13);
}

/// The number of leading whitespace bytes.
pub fn indentOf(line: []const u8) usize {
    var i: usize = 0;
    while (i < line.len and isSpace(line[i])) i += 1;
    return i;
}

/// `s` without leading and trailing whitespace.
pub fn strip(s: []const u8) []const u8 {
    var a: usize = 0;
    while (a < s.len and isSpace(s[a])) a += 1;
    var z = s.len;
    while (z > a and isSpace(s[z - 1])) z -= 1;
    return s[a..z];
}

/// Lines without their line endings ("\n", "\r\n" or a lone "\r"). A
/// final line ending ends the last line rather than starting an empty one.
pub fn splitLines(alloc: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var out = std.ArrayList([]const u8).init(alloc);
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c != '\n' and c != '\r') continue;
        try out.append(text[start..i]);
        if (c == '\r' and i + 1 < text.len and text[i + 1] == '\n') i += 1;
        start = i + 1;
    }
    if (start < text.len) try out.append(text[start..]);
    return out.toOwnedSlice();
}

// ---- fences ----------------------------------------------------------------

pub const Fence = struct {
    open_line: usize,
    /// The closing fence's line; null when the document ends first.
    close_line: ?usize,
    /// Whitespace bytes before the opening fence.
    indent: usize,
    /// '`' or '~'.
    char: u8,
    length: usize,
    /// The info string, without surrounding whitespace (a slice of the line).
    info: []const u8,
};

/// The opening fence a line holds, without its line numbers.
pub const Opening = struct {
    indent: usize,
    char: u8,
    length: usize,
    info: []const u8,
};

fn runOf(line: []const u8, start: usize) usize {
    var k = start;
    while (k < line.len and line[k] == line[start]) k += 1;
    return k - start;
}

/// Whether `line` opens a fenced block, and how.
pub fn openingFence(line: []const u8) ?Opening {
    const i = indentOf(line);
    if (i >= line.len) return null;
    const c = line[i];
    if (c != '`' and c != '~') return null;
    const run = runOf(line, i);
    if (run < 3) return null;
    const info = strip(line[i + run ..]);
    if (c == '`' and std.mem.indexOfScalar(u8, info, '`') != null) return null;
    return .{ .indent = i, .char = c, .length = run, .info = info };
}

/// Whether `line` closes a block opened by a run of `length` `char`s.
pub fn closes(line: []const u8, char: u8, length: usize) bool {
    const i = indentOf(line);
    if (i >= line.len or line[i] != char) return false;
    const run = runOf(line, i);
    if (run < length) return false;
    for (line[i + run ..]) |c| {
        if (!isSpace(c)) return false;
    }
    return true;
}

/// Every fenced block, in document order.
pub fn fences(alloc: Allocator, lines: []const []const u8) Allocator.Error![]Fence {
    var out = std.ArrayList(Fence).init(alloc);
    var i: usize = 0;
    while (i < lines.len) {
        const o = openingFence(lines[i]) orelse {
            i += 1;
            continue;
        };
        var j = i + 1;
        while (j < lines.len and !closes(lines[j], o.char, o.length)) j += 1;
        try out.append(.{
            .open_line = i,
            .close_line = if (j < lines.len) j else null,
            .indent = o.indent,
            .char = o.char,
            .length = o.length,
            .info = o.info,
        });
        i = j + 1;
    }
    return out.toOwnedSlice();
}

/// For each line: true when it is a fence line or inside a fenced block.
pub fn codeMask(alloc: Allocator, lines: []const []const u8) Allocator.Error![]bool {
    const mask = try alloc.alloc(bool, lines.len);
    @memset(mask, false);
    const fs = try fences(alloc, lines);
    for (fs) |f| {
        const last = f.close_line orelse lines.len - 1;
        @memset(mask[f.open_line .. last + 1], true);
    }
    return mask;
}

pub const Comment = struct {
    /// The line whose first non-whitespace bytes are `<!--`.
    open_line: usize,
    /// The first line from `open_line` on holding `-->` (`open_line` itself
    /// when it holds one); null when the document ends first.
    close_line: ?usize,
};

/// Every HTML block that opens with `<!--` (after any whitespace) on a line
/// that is not code, in document order: CommonMark's type 2, from that line
/// to the first line holding `-->`, or to the end. Two blocks on adjacent
/// lines are two entries.
pub fn htmlComments(alloc: Allocator, lines: []const []const u8, code: []const bool) Allocator.Error![]Comment {
    var out = std.ArrayList(Comment).init(alloc);
    var i: usize = 0;
    while (i < lines.len) {
        if (code[i] or !std.mem.startsWith(u8, strip(lines[i]), "<!--")) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < lines.len and std.mem.indexOf(u8, lines[j], "-->") == null) j += 1;
        try out.append(.{ .open_line = i, .close_line = if (j < lines.len) j else null });
        i = j + 1;
    }
    return out.toOwnedSlice();
}

/// For each line: true when it is in one of `htmlComments`. Such a block is
/// raw HTML, never Markdown: it holds no link.
pub fn htmlCommentMask(alloc: Allocator, lines: []const []const u8, code: []const bool) Allocator.Error![]bool {
    const mask = try alloc.alloc(bool, lines.len);
    @memset(mask, false);
    for (try htmlComments(alloc, lines, code)) |c| {
        const last = c.close_line orelse lines.len - 1;
        @memset(mask[c.open_line .. last + 1], true);
    }
    return mask;
}

// ---- links -----------------------------------------------------------------

/// `line` with each inline code span replaced by two backticks.
pub fn maskCodeSpans(alloc: Allocator, line: []const u8) Allocator.Error![]const u8 {
    var out = std.ArrayList(u8).init(alloc);
    var start: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] != '`') {
            i += 1;
            continue;
        }
        const n = runOf(line, i);
        // The next run of exactly n backticks closes the span.
        var j = i + n;
        const close: ?usize = while (j < line.len) {
            if (line[j] != '`') {
                j += 1;
                continue;
            }
            const m = runOf(line, j);
            if (m == n) break j;
            j += m;
        } else null;
        if (close) |c| {
            try out.appendSlice(line[start..i]);
            try out.appendSlice("``");
            i = c + n;
            start = i;
        } else {
            i += n;
        }
    }
    try out.appendSlice(line[start..]);
    return out.toOwnedSlice();
}

const Match = struct { end: usize, target: []const u8 };

/// `!?[text](target title?)` at `p`.
fn inlineAt(line: []const u8, p: usize) ?Match {
    if (p < line.len and line[p] == '!') return inlineAt(line, p + 1);
    if (p >= line.len or line[p] != '[') return null;
    var i = p + 1;
    while (i < line.len) {
        const c = line[i];
        if (c == ']') break;
        if (c == '[') {
            // One level of brackets inside the text.
            var j = i + 1;
            while (j < line.len and line[j] != ']') j += 1;
            if (j >= line.len) return null;
            i = j + 1;
            continue;
        }
        i += 1;
    }
    if (i >= line.len or line[i] != ']') return null;
    i += 1;
    if (i >= line.len or line[i] != '(') return null;
    i += 1;
    while (i < line.len and isSpace(line[i])) i += 1;
    return inlineRest(line, i);
}

/// The end of a link title at `p` ("...", '...' or (...); a (...) title
/// holds no `(`), or null when `p` opens none.
fn titleEnd(line: []const u8, p: usize) ?usize {
    if (p >= line.len) return null;
    const close: u8 = switch (line[p]) {
        '"' => '"',
        '\'' => '\'',
        '(' => ')',
        else => return null,
    };
    var k = p + 1;
    while (k < line.len and line[k] != close) : (k += 1) {
        if (close == ')' and line[k] == '(') return null;
    }
    return if (k < line.len) k + 1 else null;
}

/// The target from `p` (`<target>`, or bytes up to whitespace or `)` that
/// do not start with `<`), then an optional title after whitespace, then
/// `)`.
fn inlineRest(line: []const u8, p: usize) ?Match {
    var i = p;
    var t: []const u8 = undefined;
    if (i < line.len and line[i] == '<') {
        i += 1;
        while (i < line.len and line[i] != '>' and line[i] != '<' and !isSpace(line[i])) i += 1;
        if (i >= line.len or line[i] != '>') return null;
        t = line[p + 1 .. i];
        i += 1;
    } else {
        while (i < line.len and line[i] != ')' and !isSpace(line[i])) i += 1;
        t = line[p..i];
    }
    if (t.len == 0) return null;
    // An optional title, after whitespace.
    var j = i;
    while (j < line.len and isSpace(line[j])) j += 1;
    if (j > i) {
        if (titleEnd(line, j)) |k| {
            var m = k;
            while (m < line.len and isSpace(line[m])) m += 1;
            if (m < line.len and line[m] == ')') return .{ .end = m + 1, .target = t };
        }
    }
    if (j < line.len and line[j] == ')') return .{ .end = j + 1, .target = t };
    return null;
}

/// The target of every inline link and image on `line`, left to right
/// (slices of `line`).
pub fn inlineTargets(alloc: Allocator, line: []const u8) Allocator.Error![]const []const u8 {
    var out = std.ArrayList([]const u8).init(alloc);
    var p: usize = 0;
    while (p < line.len) {
        if (inlineAt(line, p)) |m| {
            try out.append(m.target);
            p = m.end;
        } else {
            p += 1;
        }
    }
    return out.toOwnedSlice();
}

/// The target of a reference definition `[id]: target` at the start of
/// `line` (up to three whitespace bytes before it): `<target>` without its
/// `<` `>`, or the bytes up to whitespace when they do not start with `<`;
/// a slice of `line`. An empty target is none.
pub fn refdefTarget(line: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < 3 and i < line.len and isSpace(line[i])) i += 1;
    if (i >= line.len or line[i] != '[') return null;
    const j = std.mem.indexOfScalarPos(u8, line, i + 1, ']') orelse return null;
    if (j == i + 1 or j + 1 >= line.len or line[j + 1] != ':') return null;
    var k = j + 2;
    while (k < line.len and isSpace(line[k])) k += 1;
    const start = k;
    while (k < line.len and !isSpace(line[k])) k += 1;
    const t = line[start..k];
    if (t.len > 0 and t[0] == '<') {
        // `<` ... `>` with no `<` inside.
        if (t.len < 3 or t[t.len - 1] != '>') return null;
        const inner = t[1 .. t.len - 1];
        if (std.mem.indexOfAny(u8, inner, "<>") != null) return null;
        return inner;
    }
    if (t.len == 0) return null;
    return t;
}

/// A URL with a scheme (`x:`, `x+y-z.w:`), or a scheme-relative `//host`.
pub fn isExternal(t: []const u8) bool {
    if (std.mem.startsWith(u8, t, "//")) return true;
    if (t.len == 0 or !std.ascii.isAlphabetic(t[0])) return false;
    for (t[1..]) |d| {
        if (d == ':') return true;
        if (!(std.ascii.isAlphanumeric(d) or d == '+' or d == '.' or d == '-')) return false;
    }
    return false;
}

pub const Link = struct {
    /// 0-based index of the line holding the link.
    line: usize,
    target: []const u8,
};

/// Every link outside code (fenced blocks and code spans) and outside an
/// HTML comment block whose target has no scheme: a path, a path with a
/// `#fragment`, or a bare `#fragment`. In document order; on a line, the
/// inline links left to right, then a reference definition.
pub fn relativeLinks(alloc: Allocator, lines: []const []const u8) Allocator.Error![]Link {
    var out = std.ArrayList(Link).init(alloc);
    const code = try codeMask(alloc, lines);
    const comments = try htmlCommentMask(alloc, lines, code);
    for (lines, 0..) |raw, li| {
        if (code[li] or comments[li]) continue;
        const line = try maskCodeSpans(alloc, raw);
        for (try inlineTargets(alloc, line)) |t| {
            if (!isExternal(t)) try out.append(.{ .line = li, .target = t });
        }
        if (refdefTarget(line)) |t| {
            if (!isExternal(t)) try out.append(.{ .line = li, .target = t });
        }
    }
    return out.toOwnedSlice();
}
