//! The small subset of sed that cov_plant's expressions use, run on a text: `s`
//! commands separated by `;`, any delimiter, a basic regular expression made of
//! literal characters, `.` (any one character), `^` and `$` anchors and `\` escapes,
//! the first match of each line replaced, `&` and `\&` in the replacement. A
//! construct outside that subset is refused, so an expression that needs more
//! fails at once instead of planting something else.

const std = @import("std");
const A = std.mem.Allocator;

pub const Piece = union(enum) { lit: u8, any };

pub const Command = struct {
    pattern: []const Piece,
    anchored_start: bool,
    anchored_end: bool,
    /// Literal text and `&` (the matched text) in the replacement.
    replacement: []const RepPiece,
};

pub const RepPiece = union(enum) { text: []const u8, matched };

/// The commands of `expr`.
pub fn parse(a: A, expr: []const u8) ![]Command {
    var cmds = std.ArrayList(Command).init(a);
    var i: usize = 0;
    while (true) {
        while (i < expr.len and (expr[i] == ' ' or expr[i] == ';' or expr[i] == '\n')) i += 1;
        if (i >= expr.len) break;
        if (expr[i] != 's' or i + 1 >= expr.len) return error.UnsupportedSed;
        const delim = expr[i + 1];
        if (delim == '\\' or delim == '\n') return error.UnsupportedSed;
        i += 2;
        const pat = try field(a, expr, &i, delim);
        const rep = try field(a, expr, &i, delim);
        // Flags: none are supported.
        while (i < expr.len and expr[i] != ';' and expr[i] != ' ' and expr[i] != '\n') return error.UnsupportedSed;
        try cmds.append(try command(a, pat, rep));
    }
    if (cmds.items.len == 0) return error.UnsupportedSed;
    return cmds.toOwnedSlice();
}

/// Reads up to the next unescaped `delim`; `\<delim>` is the delimiter itself,
/// every other escape is kept for the caller.
fn field(a: A, s: []const u8, i: *usize, delim: u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    while (i.* < s.len) : (i.* += 1) {
        const c = s[i.*];
        if (c == '\\' and i.* + 1 < s.len) {
            if (s[i.* + 1] == delim) {
                try out.append(delim);
            } else {
                try out.append('\\');
                try out.append(s[i.* + 1]);
            }
            i.* += 1;
        } else if (c == delim) {
            i.* += 1;
            return out.toOwnedSlice();
        } else try out.append(c);
    }
    return error.UnsupportedSed;
}

fn command(a: A, pat: []const u8, rep: []const u8) !Command {
    var pieces = std.ArrayList(Piece).init(a);
    var start = false;
    var end = false;
    var i: usize = 0;
    if (pat.len > 0 and pat[0] == '^') {
        start = true;
        i = 1;
    }
    while (i < pat.len) : (i += 1) {
        const c = pat[i];
        switch (c) {
            '\\' => {
                i += 1;
                if (i >= pat.len) return error.UnsupportedSed;
                const e = pat[i];
                // A backslash before a character BRE gives no special meaning to
                // here makes it literal; `\(`, `\{` and `\n` and friends are not supported.
                if (std.mem.indexOfScalar(u8, ".*[]^$\\&/|#,\"'-:;", e) == null) return error.UnsupportedSed;
                try pieces.append(.{ .lit = e });
            },
            '.' => try pieces.append(.any),
            '$' => {
                if (i + 1 != pat.len) return error.UnsupportedSed;
                end = true;
            },
            '*', '[' => return error.UnsupportedSed,
            else => try pieces.append(.{ .lit = c }),
        }
    }
    var reps = std.ArrayList(RepPiece).init(a);
    var text = std.ArrayList(u8).init(a);
    var j: usize = 0;
    while (j < rep.len) : (j += 1) {
        const c = rep[j];
        if (c == '\\') {
            j += 1;
            if (j >= rep.len) return error.UnsupportedSed;
            const e = rep[j];
            if (std.mem.indexOfScalar(u8, "&\\/|#,\"'-:;.*[]^$", e) == null) return error.UnsupportedSed;
            try text.append(e);
        } else if (c == '&') {
            if (text.items.len > 0) try reps.append(.{ .text = try text.toOwnedSlice() });
            text = std.ArrayList(u8).init(a);
            try reps.append(.matched);
        } else try text.append(c);
    }
    if (text.items.len > 0) try reps.append(.{ .text = try text.toOwnedSlice() });
    return .{ .pattern = try pieces.toOwnedSlice(), .anchored_start = start, .anchored_end = end, .replacement = try reps.toOwnedSlice() };
}

fn matchAt(c: Command, line: []const u8, at: usize) ?usize {
    if (at + c.pattern.len > line.len) return null;
    for (c.pattern, 0..) |p, k| {
        switch (p) {
            .lit => |x| if (line[at + k] != x) return null,
            .any => {},
        }
    }
    const e = at + c.pattern.len;
    if (c.anchored_end and e != line.len) return null;
    return e;
}

/// One line with the first match of `c` replaced.
fn applyLine(a: A, c: Command, line: []const u8, out: *std.ArrayList(u8)) !void {
    var at: usize = 0;
    while (at <= line.len) : (at += 1) {
        if (c.anchored_start and at != 0) break;
        if (matchAt(c, line, at)) |e| {
            try out.appendSlice(line[0..at]);
            for (c.replacement) |r| switch (r) {
                .text => |t| try out.appendSlice(t),
                .matched => try out.appendSlice(line[at..e]),
            };
            try out.appendSlice(line[e..]);
            return;
        }
    }
    _ = a;
    try out.appendSlice(line);
}

/// `text` with the commands of `expr` applied to each line, in order.
pub fn run(a: A, expr: []const u8, text: []const u8) ![]u8 {
    const cmds = try parse(a, expr);
    var cur = try a.dupe(u8, text);
    for (cmds) |c| {
        var out = std.ArrayList(u8).init(a);
        var i: usize = 0;
        while (i < cur.len) {
            const e = if (std.mem.indexOfScalarPos(u8, cur, i, '\n')) |n| n else cur.len;
            try applyLine(a, c, cur[i..e], &out);
            if (e < cur.len) try out.append('\n');
            i = e + 1;
        }
        cur = try out.toOwnedSlice();
    }
    return cur;
}
