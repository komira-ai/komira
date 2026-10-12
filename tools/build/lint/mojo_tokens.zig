//! mojo_tokens: a line-at-a-time lexer of Mojo source text, shared by the
//! lint tools that read Mojo as code (pointer_lint.zig).
//!
//! `Lexer.scan` splits one line into spans: code, a string literal (`"..."`
//! or `'...'`, a backslash escaping the next byte; one left open runs to the
//! end of the line), a triple-quoted string (`"""` or `'''`, which may span
//! lines: the lexer carries it open to the next `scan`), and a comment (`#`
//! outside a string, to the end of the line). A `#` or a quote inside a
//! string, and a quote inside a comment, start nothing.
//!
//! `view` turns the spans back into text for a reader that matches code:
//! comments dropped, each string literal reduced to its two quotes (or kept
//! whole), and each triple-quoted string to `""` on the line it opens on and
//! to nothing on the others. Brackets nest across lines: `depth` and
//! `closing` count `(` and `[` against `)` and `]` in such a view.

const std = @import("std");

pub const Kind = enum { code, string, long_string, comment };

pub const Span = struct {
    kind: Kind,
    start: usize,
    end: usize,
    /// A long_string span holding the string's opening quotes.
    opens: bool = false,
};

pub const Lexer = struct {
    /// The quote byte of the triple-quoted string still open after the
    /// last line scanned, or 0.
    long_quote: u8 = 0,

    /// The spans of `line` (no newline), in order, covering it; empty for
    /// an empty line.
    pub fn scan(self: *Lexer, line: []const u8, spans: *std.ArrayList(Span)) !void {
        spans.clearRetainingCapacity();
        var i: usize = 0;
        if (self.long_quote != 0) {
            if (closeLong(line, 0, self.long_quote)) |e| {
                try spans.append(.{ .kind = .long_string, .start = 0, .end = e });
                self.long_quote = 0;
                i = e;
            } else {
                if (line.len > 0) try spans.append(.{ .kind = .long_string, .start = 0, .end = line.len });
                return;
            }
        }
        var code_start = i;
        while (i < line.len) {
            const c = line[i];
            if (c == '#') {
                try addCode(spans, code_start, i);
                try spans.append(.{ .kind = .comment, .start = i, .end = line.len });
                return;
            }
            if (c != '"' and c != '\'') {
                i += 1;
                continue;
            }
            try addCode(spans, code_start, i);
            if (i + 2 < line.len and line[i + 1] == c and line[i + 2] == c) {
                if (closeLong(line, i + 3, c)) |e| {
                    try spans.append(.{ .kind = .long_string, .start = i, .end = e, .opens = true });
                    i = e;
                } else {
                    try spans.append(.{ .kind = .long_string, .start = i, .end = line.len, .opens = true });
                    self.long_quote = c;
                    return;
                }
            } else {
                var j = i + 1;
                while (j < line.len and line[j] != c) : (j += 1) {
                    if (line[j] == '\\') j += 1;
                }
                const e = if (j < line.len) j + 1 else line.len;
                try spans.append(.{ .kind = .string, .start = i, .end = e });
                i = e;
            }
            code_start = i;
        }
        try addCode(spans, code_start, line.len);
    }
};

fn addCode(spans: *std.ArrayList(Span), start: usize, end: usize) !void {
    if (end > start) try spans.append(.{ .kind = .code, .start = start, .end = end });
}

/// The index just past the triple quote `q` that closes a string whose body
/// starts at `from`, or null when the line does not close it.
fn closeLong(line: []const u8, from: usize, q: u8) ?usize {
    var j = from;
    while (j < line.len) : (j += 1) {
        if (line[j] == '\\') {
            j += 1;
            continue;
        }
        if (line[j] == q and j + 2 < line.len and line[j + 1] == q and line[j + 2] == q) return j + 3;
    }
    return null;
}

pub const Strings = enum { blank, keep };

/// Appends `line` as code to `out`: comments dropped, a string literal as
/// its two quotes (`.blank`) or whole (`.keep`), a triple-quoted string as
/// `""` where it opens and nothing elsewhere.
pub fn view(line: []const u8, spans: []const Span, strings: Strings, out: *std.ArrayList(u8)) !void {
    for (spans) |s| switch (s.kind) {
        .code => try out.appendSlice(line[s.start..s.end]),
        .string => if (strings == .keep) {
            try out.appendSlice(line[s.start..s.end]);
        } else {
            try out.append(line[s.start]);
            try out.append(line[s.start]);
        },
        .long_string => if (s.opens) try out.appendSlice("\"\""),
        .comment => {},
    };
}

/// Opening brackets (`(`, `[`) less closing ones (`)`, `]`) in `text`.
pub fn depth(text: []const u8) i64 {
    var d: i64 = 0;
    for (text) |c| switch (c) {
        '(', '[' => d += 1,
        ')', ']' => d -= 1,
        else => {},
    };
    return d;
}

/// The index of the bracket closing the one at `at`, or null.
pub fn closing(text: []const u8, at: usize) ?usize {
    var d: i64 = 0;
    var i = at;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '(', '[' => d += 1,
            ')', ']' => {
                d -= 1;
                if (d == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

// ---- tests (`zig test mojo_tokens.zig`; BUCK: :mojo_tokens_test) ----

const testing = std.testing;

/// Scans `lines` in turn and returns each line's code view, joined by `|`.
fn views(lines: []const []const u8, strings: Strings) ![]u8 {
    var lx = Lexer{};
    var spans = std.ArrayList(Span).init(testing.allocator);
    defer spans.deinit();
    var out = std.ArrayList(u8).init(testing.allocator);
    errdefer out.deinit();
    for (lines, 0..) |l, n| {
        if (n > 0) try out.append('|');
        try lx.scan(l, &spans);
        try view(l, spans.items, strings, &out);
    }
    return out.toOwnedSlice();
}

fn expectViews(lines: []const []const u8, strings: Strings, want: []const u8) !void {
    const got = try views(lines, strings);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "a comment is dropped; a # in a string starts none" {
    try expectViews(&.{"x = f(1)  # MutAnyOrigin"}, .blank, "x = f(1)  ");
    try expectViews(&.{"x = \"#\" + y  # c"}, .blank, "x = \"\" + y  ");
    try expectViews(&.{"x = '#' + y  # c"}, .keep, "x = '#' + y  ");
}

test "an escaped quote does not close a string" {
    // The string is `"\"#"`: the `#` after the escaped quote is inside it.
    try expectViews(&.{"call(1, \"\\\"#\", 0)  # not read"}, .blank, "call(1, \"\", 0)  ");
    try expectViews(&.{"call(1, \"\\\"#\", 0)  # not read"}, .keep, "call(1, \"\\\"#\", 0)  ");
}

test "each quote kind closes only its own string" {
    try expectViews(&.{"a = \"it's\" + 'say \"hi\"'"}, .blank, "a = \"\" + ''");
}

test "a triple quote inside a string or a comment opens nothing" {
    try expectViews(&.{ "a = \"'''\"", "b = MutAnyOrigin" }, .blank, "a = \"\"|b = MutAnyOrigin");
    try expectViews(&.{ "x = 1  # a \"\"\" here", "y = 2" }, .blank, "x = 1  |y = 2");
}

test "a triple-quoted string spans lines and becomes one pair of quotes" {
    try expectViews(&.{ "\"\"\"Doc naming", "MutAnyOrigin and # not a comment", "\"\"\" + x  # c" }, .blank, "\"\"|| + x  ");
    try expectViews(&.{ "    '''single", "    quoted'''", "pass" }, .keep, "    \"\"||pass");
}

test "a triple-quoted string closed on its own line leaves the rest as code" {
    try expectViews(&.{"s = \"\"\"a\"\"\" + \"b\""}, .blank, "s = \"\" + \"\"");
    try expectViews(&.{"s = \"\"\"a\"\"\" + \"b\""}, .keep, "s = \"\" + \"b\"");
}

test "an empty string literal is not a triple quote" {
    try expectViews(&.{ "a = \"\"", "b = 1" }, .blank, "a = \"\"|b = 1");
    try expectViews(&.{ "a = \"\" + x", "b = 1" }, .blank, "a = \"\" + x|b = 1");
}

test "an escaped quote does not close a triple-quoted string" {
    try expectViews(&.{ "\"\"\"a \\\"\"\" b", "c\"\"\"", "d" }, .blank, "\"\"||d");
}

test "an unterminated string runs to the end of its line only" {
    try expectViews(&.{ "a = \"open # x", "b = 1" }, .blank, "a = \"\"|b = 1");
}

test "the lexer's open string is carried until it closes" {
    var lx = Lexer{};
    var spans = std.ArrayList(Span).init(testing.allocator);
    defer spans.deinit();
    try lx.scan("x = '''", &spans);
    try testing.expectEqual(@as(u8, '\''), lx.long_quote);
    try lx.scan("\"\"\" inside", &spans);
    try testing.expectEqual(@as(u8, '\''), lx.long_quote);
    try testing.expectEqual(@as(usize, 1), spans.items.len);
    try testing.expectEqual(Kind.long_string, spans.items[0].kind);
    try lx.scan("''' # c", &spans);
    try testing.expectEqual(@as(u8, 0), lx.long_quote);
    try testing.expectEqual(Kind.comment, spans.items[spans.items.len - 1].kind);
}

test "brackets nest: depth and the closing bracket" {
    try testing.expectEqual(@as(i64, 2), depth("f(a[1], (b"));
    try testing.expectEqual(@as(i64, -1), depth(")"));
    try testing.expectEqual(@as(?usize, 9), closing("f(a[1], b)", 1));
    try testing.expectEqual(@as(?usize, 5), closing("f(a[1], b)", 3));
    try testing.expectEqual(@as(?usize, null), closing("f(a[1]", 1));
}
