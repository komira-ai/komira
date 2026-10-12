//! The cases of markdown.zig: what is code, and which links are relative.
//! `zig test` of this file runs them (BUCK: `:markdown_unit`).

const std = @import("std");
const md = @import("markdown.zig");

const eq = std.testing.expectEqual;
const eqs = std.testing.expectEqualStrings;

var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const A = arena_state.allocator();

fn lines(text: []const u8) []const []const u8 {
    return md.splitLines(A, text) catch unreachable;
}

/// One character per line: C for code, . for prose.
fn mask(text: []const u8) []const u8 {
    const m = md.codeMask(A, lines(text)) catch unreachable;
    const s = A.alloc(u8, m.len) catch unreachable;
    for (m, 0..) |c, i| s[i] = if (c) 'C' else '.';
    return s;
}

/// The relative links of `text`, one "<line>:<target>" per link, joined by
/// spaces.
fn links(text: []const u8) []const u8 {
    const ls = md.relativeLinks(A, lines(text)) catch unreachable;
    var out = std.ArrayList(u8).init(A);
    for (ls, 0..) |l, i| {
        if (i > 0) out.append(' ') catch unreachable;
        out.writer().print("{d}:{s}", .{ l.line, l.target }) catch unreachable;
    }
    return out.items;
}

fn one(text: []const u8) !md.Fence {
    const fs = try md.fences(A, lines(text));
    try eq(@as(usize, 1), fs.len);
    return fs[0];
}

// ---- the cases of the Mojo reader's tests ------------------------------------

test "a fence closes only on its own character" {
    // A ~~~ block quoting ``` is ONE block: the ``` lines inside it neither
    // open nor close anything. (A reader toggling on every fence line sees
    // the link line as prose.)
    try eqs(".CCCCC.", mask("a\n~~~\n```\n[x](missing.md)\n```\n~~~\nb\n"));
    try eqs("CCC.", mask("```\n~~~\n```\n[y](y.md)\n"));
}

test "a closing fence is at least as long" {
    try eqs("CCCC.", mask("````\n```\nx\n````\nz\n"));
    try eqs("CCC.", mask("```\nx\n`````\nz\n"));
}

test "a closing fence has no info string" {
    // "```mojo" inside an open ``` block is content, not its end.
    try eqs("CCCC.", mask("```\n```mojo\nx\n```\ny\n"));
}

test "a backtick info string holds no backtick" {
    // "``` a`b" is not a fence (CommonMark), so it opens nothing.
    try eqs("..", mask("``` a`b\nx\n"));
    try eqs("CCC", mask("~~~ a`b\nx\n~~~\n"));
}

test "two characters are not a fence" {
    try eqs("...", mask("``\nx\n``\n"));
}

test "an open fence runs to the end" {
    try eqs(".CCC", mask("a\n```\nb\nc\n"));
    try eq(@as(?usize, null), (try one("a\n```mojo\nb\n")).close_line);
}

test "fence fields" {
    const f = try one("x\n  ~~~~ mojo  \n  y\n  ~~~~\n");
    try eq(@as(usize, 1), f.open_line);
    try eq(@as(?usize, 3), f.close_line);
    try eq(@as(usize, 2), f.indent);
    try eq(@as(u8, '~'), f.char);
    try eq(@as(usize, 4), f.length);
    try eqs("mojo", f.info);
}

test "relative links skip code and urls" {
    try eqs("0:a.md 0:#top 6:f.md 7:g.md#h", links(
        "[a](a.md) and `[b](b.md)` and [c](https://example.org/c) and [d](#top)\n" ++
            "~~~\n```\n[e](e.md)\n```\n~~~\n" ++
            "[ref]: <f.md>\n" ++
            "![img](//cdn/x.png) [g](g.md#h)\n",
    ));
}

test "relative links skip html comments" {
    // An HTML block that opens with `<!--` is raw HTML up to the line holding
    // `-->` (CommonMark), never Markdown: a README's mojo-hidden code such as
    // `Span[UInt8](bytes)` is no link. A link after the comment still counts.
    try eqs("6:kept.md", links(
        "<!-- mojo-hidden\nvar s = Span[UInt8](bytes)\n-->\n" ++
            "<!-- one line [x](gone.md) -->\n" ++
            "  <!-- indented [y](gone2.md)\n -->\n" ++
            "after [z](kept.md)\n",
    ));
}

// ---- fence close -------------------------------------------------------------

test "a closing fence may be indented and followed by whitespace only" {
    try eqs("CCC.", mask("```\nx\n   ``` \t\ny\n"));
    try eqs("CCC.", mask("~~~\nx\n~~~~~~\ny\n"));
    // Text after the run: content, so the block runs on to the next close.
    try eqs("CCCC.", mask("~~~\n~~~ x\ny\n~~~\nz\n"));
}

test "the fence after a closed block opens a new one" {
    const fs = try md.fences(A, lines("```a\n```\n~~~b\nx\n~~~\n```c\n"));
    try eq(@as(usize, 3), fs.len);
    try eqs("a", fs[0].info);
    try eq(@as(?usize, 1), fs[0].close_line);
    try eq(@as(usize, 2), fs[1].open_line);
    try eq(@as(?usize, 4), fs[1].close_line);
    try eq(@as(usize, 5), fs[2].open_line);
    try eq(@as(?usize, null), fs[2].close_line);
}

// ---- info string -------------------------------------------------------------

test "the info string is the rest of the line, stripped" {
    try eqs("mojo module", (try one("```   mojo module \t\nx\n```\n")).info);
    try eqs("", (try one("```\nx\n```\n")).info);
    try eqs("a`b", (try one("~~~a`b\n~~~\n")).info);
    try eqs("mojo", (try one("```mojo\n```\n")).info);
    // A backtick anywhere in a backtick fence's info string: not a fence.
    try eq(@as(?md.Opening, null), md.openingFence("```mojo `x`"));
    try eq(@as(?md.Opening, null), md.openingFence("````mojo`"));
}

// ---- indent ------------------------------------------------------------------

test "a fence opens at any indentation, which it records" {
    // Container blocks are not modelled: four spaces still open a fence
    // (a fence nested in a list item).
    const f = try one("      ```mojo\n      x\n      ```\n");
    try eq(@as(usize, 6), f.indent);
    try eq(@as(usize, 3), f.length);
    // A tab is one whitespace byte.
    try eq(@as(usize, 1), (try one("\t~~~\n~~~\n")).indent);
    // A whitespace-only line opens nothing.
    try eqs("..", mask("   \nx\n"));
}

// ---- unclosed fence ----------------------------------------------------------

test "an unclosed fence swallows later fences of the other character" {
    const fs = try md.fences(A, lines("x\n````\n```\n~~~\ny\n"));
    try eq(@as(usize, 1), fs.len);
    try eq(@as(usize, 1), fs[0].open_line);
    try eq(@as(?usize, null), fs[0].close_line);
    try eqs(".CCCC", mask("x\n````\n```\n~~~\ny"));
    try eqs("", mask(""));
}

// ---- code spans --------------------------------------------------------------

test "a code span closes on a run of the same length" {
    // CommonMark: `` opens a span that only `` closes, so a link inside it is
    // code, and a single backtick inside it is text.
    try eqs("", links("``[a](a.md)``\n"));
    try eqs("", links("`` x ` [b](b.md) ``\n"));
    try eqs("x ``  y", try md.maskCodeSpans(A, "x ``a`b``  y"));
    try eqs("``", try md.maskCodeSpans(A, "`[c](c.md)`"));
}

test "a backtick run with no partner is text" {
    // The unmatched `` is literal, and the link after it is read; a later
    // pair still makes a span.
    try eqs("0:a.md", links("`` [a](a.md) `[b](b.md)`\n"));
    try eqs("x ``` y ``", try md.maskCodeSpans(A, "x ``` y `z`"));
}

// ---- link targets ------------------------------------------------------------

test "inline link and image targets" {
    const t = try md.inlineTargets(A, "[a](<b.md>) ![i](p.png \"T\") [n [x] m](d.md) [s]( e.md  ) [e]() [sp] (no.md) [h](f.md#x)");
    try eq(@as(usize, 5), t.len);
    try eqs("b.md", t[0]);
    try eqs("p.png", t[1]);
    try eqs("d.md", t[2]);
    try eqs("e.md", t[3]);
    try eqs("f.md#x", t[4]);
    // A target with a space, or text after it that is not a title, is no link.
    try eq(@as(usize, 0), (try md.inlineTargets(A, "[a](b c) [d](e.md x)")).len);
    // An outer `[` whose text never closes is no link; the inner one is.
    const inner = try md.inlineTargets(A, "[a [b](c.md)");
    try eq(@as(usize, 1), inner.len);
    try eqs("c.md", inner[0]);
}

test "reference definitions" {
    try eqs("f.md", md.refdefTarget("[ref]: <f.md>").?);
    try eqs("g.md#x", md.refdefTarget("   [r]:g.md#x \"title\"").?);
    try eqs("a>", md.refdefTarget("[r]: a>").?);
    try eq(@as(?[]const u8, null), md.refdefTarget("    [r]: four-spaces.md"));
    try eq(@as(?[]const u8, null), md.refdefTarget("[]: empty-label.md"));
    try eq(@as(?[]const u8, null), md.refdefTarget("[r]:   "));
    try eq(@as(?[]const u8, null), md.refdefTarget("[r] : spaced.md"));
    try eqs("1:r.md", links("x\n[r]: r.md\n"));
}

test "a target with a scheme is external" {
    for ([_][]const u8{ "https://example.org", "mailto:a@b", "a+b-c.d:x", "//cdn/x" }) |t| {
        try std.testing.expect(md.isExternal(t));
    }
    for ([_][]const u8{ "", "a.md", "#top", "1http:x", "a_b:x", "dir/a:b", "/abs" }) |t| {
        try std.testing.expect(!md.isExternal(t));
    }
}

// ---- HTML comments -----------------------------------------------------------

test "an HTML comment block ends on its -->; one left open runs to the end" {
    // The block's last line is all comment, text after --> included.
    try eqs("3:b.md", links("<!-- x\n[a](a.md)\nend --> [z](z.md)\n[b](b.md)\n"));
    try eqs("", links("<!-- never closed\n[a](a.md)\n[b](b.md)\n"));
    // An opener that is not first on its line is no HTML block (an inline
    // comment is not read as raw HTML here).
    try eqs("0:a.md", links("x <!-- [a](a.md) -->\n"));
}

test "a comment opener inside a fence opens no comment" {
    try eqs("3:a.md", links("```\n<!--\n```\n[a](a.md)\n"));
}

// ---- line numbers ------------------------------------------------------------

test "lines split on every CommonMark line ending" {
    const ls = lines("a\r\n\r\nb\rc\n");
    try eq(@as(usize, 4), ls.len);
    try eqs("a", ls[0]);
    try eqs("", ls[1]);
    try eqs("b", ls[2]);
    try eqs("c", ls[3]);
    try eq(@as(usize, 0), lines("").len);
    try eq(@as(usize, 2), lines("x\n\n").len);
    try eq(@as(usize, 1), lines("x").len);
    try eqs("2:c.md", links("```\r\n```\r\n[c](c.md)\r\n"));
}

test "a lone carriage return ends a line; a final one ends the last line" {
    // CommonMark: "\n", "\r\n" and "\r" are line endings.
    const ls = lines("x\ry\r\rz\r");
    try eq(@as(usize, 4), ls.len);
    try eqs("x", ls[0]);
    try eqs("y", ls[1]);
    try eqs("", ls[2]);
    try eqs("z", ls[3]);
    try eqs("2:b.md", links("```\r```\r[b](b.md)\r"));
    // "\r\n" is one line ending, not two.
    try eq(@as(usize, 2), lines("a\r\nb").len);
}

test "a final \\r\\n ends the last line rather than starting an empty one" {
    // Catches a "\r\n" pair read as two endings when it closes the text.
    try eq(@as(usize, 1), lines("x\r\n").len);
    try eq(@as(usize, 2), lines("a\r\nb\r\n").len);
}

// ---- review cases ------------------------------------------------------------

test "whitespace after a title, before the closing parenthesis" {
    const t = try md.inlineTargets(A, "[a](b.md \"t\" )");
    try eq(@as(usize, 1), t.len);
    try eqs("b.md", t[0]);
}

test "a tab before the info string is stripped" {
    try eqs("mojo", (try one("```\tmojo\n```\n")).info);
    try eqs("mojo", (try one("~~~ \t mojo\t\n~~~\n")).info);
}

test "a comment block ends on its first line holding -->, even after another opener" {
    try eqs("2:x.md", links("<!-- a\n<!-- b -->\n[x](x.md)\n"));
}

test "a title may be double-quoted, single-quoted or parenthesised" {
    const t = try md.inlineTargets(A, "[d](e.md 'x') [f](g.md (y z)) [h](i.md \"q\") [j](k.md\t'x'  )");
    try eq(@as(usize, 4), t.len);
    try eqs("e.md", t[0]);
    try eqs("g.md", t[1]);
    try eqs("i.md", t[2]);
    try eqs("k.md", t[3]);
    // A title not separated from a <target>, an unclosed title, a (...)
    // title holding `(`, and mismatched quotes: no link.
    try eq(@as(usize, 0), (try md.inlineTargets(A, "[a](<b.md>'x')")).len);
    try eq(@as(usize, 0), (try md.inlineTargets(A, "[c](d.md 'x)")).len);
    try eq(@as(usize, 0), (try md.inlineTargets(A, "[e](f.md (a(b)))")).len);
    try eq(@as(usize, 0), (try md.inlineTargets(A, "[g](h.md 'x\")")).len);
    // With no whitespace before it, a quote is part of a plain target.
    try eqs("b.md'x'", (try md.inlineTargets(A, "[a](b.md'x')"))[0]);
    try eqs("0:e.md 1:g.md", links("[d](e.md 'x')\n[f](g.md (y))\n"));
}

test "a pointy target closes with > and a plain one does not start with <" {
    try eq(@as(usize, 0), (try md.inlineTargets(A, "[a](<b) [c](<d<e>) [f](<>) [g](<h> 'x)")).len);
    const t = try md.inlineTargets(A, "[a](b>c) [d](<e.md> 't')");
    try eq(@as(usize, 2), t.len);
    try eqs("b>c", t[0]);
    try eqs("e.md", t[1]);
}

test "a reference definition's <target> must close" {
    try eq(@as(?[]const u8, null), md.refdefTarget("[r]: <"));
    try eq(@as(?[]const u8, null), md.refdefTarget("[r]: <a.md"));
    try eq(@as(?[]const u8, null), md.refdefTarget("[r]: <>"));
    try eq(@as(?[]const u8, null), md.refdefTarget("[r]: <a>b>"));
    try eqs("a.md", md.refdefTarget("[r]: <a.md> \"t\"").?);
}

test "a comment block may close on its opening line: <!--> and <!--->" {
    try eqs("1:a.md", links("<!-->\n[a](a.md)\n"));
    try eqs("1:b.md", links("<!--->\n[b](b.md)\n"));
    try eqs("", links("<!--\n[c](c.md)\n"));
}

test "whitespace is CommonMark's: bytes 28 to 31 are text" {
    for ([_]u8{ ' ', '\t', '\n', 11, 12, '\r' }) |c| try std.testing.expect(md.isSpace(c));
    for ([_]u8{ 0, 8, 14, 28, 29, 30, 31, 'a' }) |c| try std.testing.expect(!md.isSpace(c));
    try eqs("\x1cx\x1f", md.strip(" \x1cx\x1f\t"));
    try eq(@as(usize, 0), md.indentOf("\x1f  x"));
}

// ---- comment blocks ----------------------------------------------------------

fn comments(text: []const u8) []const md.Comment {
    const ls = lines(text);
    return md.htmlComments(A, ls, md.codeMask(A, ls) catch unreachable) catch unreachable;
}

test "each comment block is its own entry, with its first and last line" {
    // Adjacent blocks stay apart (a mask would merge them).
    const cs = comments("<!-- a -->\n<!-- b\nc -->\nx\n  <!-- d\n");
    try eq(@as(usize, 3), cs.len);
    try eq(@as(usize, 0), cs[0].open_line);
    try eq(@as(?usize, 0), cs[0].close_line);
    try eq(@as(usize, 1), cs[1].open_line);
    try eq(@as(?usize, 2), cs[1].close_line);
    try eq(@as(usize, 4), cs[2].open_line);
    try eq(@as(?usize, null), cs[2].close_line);
    // Not code, not mid-line; text after the --> is in the block.
    try eq(@as(usize, 0), comments("```\n<!-- a -->\n```\nx <!-- b -->\n").len);
    try eq(@as(usize, 0), comments("").len);
}

test "the comment mask covers exactly the comment blocks" {
    const ls = lines("<!-- a -->\n<!-- b\nc -->\nx\n  <!-- d\ne\n");
    const m = try md.htmlCommentMask(A, ls, try md.codeMask(A, ls));
    const want = [_]bool{ true, true, true, false, true, true };
    try std.testing.expectEqualSlices(bool, &want, m);
}

fn expectOne(cs: []const md.Comment, open: usize, close: ?usize) !void {
    try eq(@as(usize, 1), cs.len);
    try eq(open, cs[0].open_line);
    try eq(close, cs[0].close_line);
}

test "an opener inside an open block starts no second entry" {
    // CommonMark: one HTML block from line 0 to the first line holding -->.
    try expectOne(comments("<!-- a\n<!-- b -->\n"), 0, 1);
    // Left open, the block runs to the end and swallows a later opener.
    try expectOne(comments("<!-- a\nx\n<!-- b\n"), 0, null);
}

test "a block closing on the document's last line is closed" {
    try expectOne(comments("x\n<!-- a\nb -->"), 1, 2);
    try expectOne(comments("<!-- a -->"), 0, 0);
}

test "only <!-- opens a comment block" {
    try eq(@as(usize, 0), comments("<!- a\n<! -- b\n").len);
}

test "a comment block closes on a --> line that a fence covers" {
    // The fence on line 1 runs to line 3, but the --> on line 2 still ends
    // the block that opened on line 0 (as CommonMark, where the fence lines
    // are inside the HTML block).
    try expectOne(comments("<!-- a\n```\n-->\n```\n"), 0, 2);
}
