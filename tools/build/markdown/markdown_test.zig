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
    try eq(@as(usize, 0), (try md.inlineTargets(A, "[a](b c) [d](e.md 'x')")).len);
    // An outer `[` whose text never closes is no link; the inner one is.
    const inner = try md.inlineTargets(A, "[a [b](c.md)");
    try eq(@as(usize, 1), inner.len);
    try eqs("c.md", inner[0]);
}

test "reference definitions" {
    try eqs("f.md", md.refdefTarget("[ref]: <f.md>").?);
    try eqs("g.md#x", md.refdefTarget("   [r]:g.md#x \"title\"").?);
    try eqs("<", md.refdefTarget("[r]: <").?);
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

test "lines split on newline and drop a carriage return before it" {
    const ls = lines("a\r\n\r\nb\rc\n");
    try eq(@as(usize, 3), ls.len);
    try eqs("a", ls[0]);
    try eqs("", ls[1]);
    try eqs("b\rc", ls[2]);
    try eq(@as(usize, 0), lines("").len);
    try eq(@as(usize, 2), lines("x\n\n").len);
    try eq(@as(usize, 1), lines("x").len);
    try eqs("2:c.md", links("```\r\n```\r\n[c](c.md)\r\n"));
}
