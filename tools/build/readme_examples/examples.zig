//! The examples of a README. Pure: no I/O.
//!
//! A fenced block whose info string is `mojo` or `mojo module` is an
//! EXAMPLE, and every example runs: there is no skip word. A sketch that
//! cannot run is fenced ```text. The info string is the example's mode, and
//! nothing else is: `mojo` (statements, pasted into a `main`) or `mojo module`
//! (a whole program with its own `main`; program.zig), wherever the fence
//! sits (a fence in a list item is indented, and keeps its mode). The
//! vocabulary after `mojo` is closed and holds `module` alone, so `mojo skip`
//! (or any other word after `mojo`) is refused, and so is a near miss of the
//! language word (`Mojo`, `mojo,`, `.mojo`, the fire emoji): a typo can never
//! turn an example into prose that silently does not run.
//!
//! Hidden lines: an HTML comment `<!-- mojo-hidden ... -->` that ends on the
//! line just before an example's opening fence is prepended to it; one that
//! starts on the line just after its closing fence is appended. Either a
//! whole comment on one line (`<!-- mojo-hidden assert_equal(x, 1) -->`) or
//! the opening on its own line, code lines, and `-->` on the last. GitHub does
//! not render an HTML comment, so the page shows the example clean; every raw
//! view shows the hidden lines. A `mojo-hidden` comment next to no example,
//! and a comment that spells the marker differently (`mojo_hidden`,
//! `Mojo-hidden`), are refused: hidden code that never runs is the defect
//! this guards.
//!
//! What is code, a fence and a link is the shared Markdown reader's
//! (`@import("markdown")`, tools/build/markdown). Every refusal names
//! `<readme>:<line>` (1-based), and all of them are reported at once, in
//! line order.

const std = @import("std");
const md = @import("markdown");
const Allocator = std.mem.Allocator;

pub const Example = struct {
    /// 1-based README line of the opening fence.
    line: usize,
    /// The fence says `mojo module`: a whole program, copied as it is.
    module: bool,
    /// The code: hidden lines before, the block's lines, hidden lines after.
    code: []const []const u8,
    /// 1-based README line of each entry of `code`.
    code_lines: []const usize,
};

/// The examples of a README, or every refusal of it, one per line.
pub const Extracted = union(enum) {
    examples: []const Example,
    refused: []const u8,
};

const Hidden = struct {
    /// 0-based first and last lines of the comment.
    first: usize,
    last: usize,
    code: std.ArrayList([]const u8),
    code_lines: std.ArrayList(usize),
};

const Refusal = struct { line: usize, text: []const u8 };

const FIRE = "\u{1F525}";
const MARK = "mojo-hidden";
pub const MODULE_WORD = "module";

/// The info string up to its first space or tab.
fn firstWord(info: []const u8) []const u8 {
    var k: usize = 0;
    while (k < info.len and info[k] != ' ' and info[k] != '\t') k += 1;
    return info[0..k];
}

/// What follows the leading `mojo` of `info`, without surrounding space.
fn afterMojo(info: []const u8) []const u8 {
    return md.strip(info[@min(4, info.len)..]);
}

fn lowerStartsWith(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    for (prefix, 0..) |c, i| {
        if (std.ascii.toLower(s[i]) != c) return false;
    }
    return true;
}

fn lowerContains(s: []const u8, needle: []const u8) bool {
    if (s.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= s.len) : (i += 1) {
        if (lowerStartsWith(s[i..], needle)) return true;
    }
    return false;
}

/// Why `info` may not open a fence of a README, or null when it may. An
/// info string of `mojo` or `mojo module` is an example; any other word is
/// prose.
pub fn infoRefusal(alloc: Allocator, info: []const u8) Allocator.Error!?[]const u8 {
    const word = firstWord(info);
    if (std.mem.eql(u8, word, "mojo")) {
        const rest = afterMojo(info);
        if (rest.len > 0 and !std.mem.eql(u8, rest, MODULE_WORD)) {
            return try std.fmt.allocPrint(alloc, "`{s}`: an example's info string is `mojo` or `mojo module`; nothing else may follow `mojo`" ++
                " (there is no skip word: fence a sketch that cannot run as ```text)", .{info});
        }
        return null;
    }
    if (lowerContains(word, "mojo") or std.mem.indexOf(u8, word, FIRE) != null) {
        return try std.fmt.allocPrint(alloc, "`{s}` is not `mojo`: write ```mojo for an example that runs, or ```text for a sketch", .{word});
    }
    return null;
}

/// Whether `info` opens an example in module mode. The tag alone decides,
/// wherever the fence sits.
pub fn isModule(info: []const u8) bool {
    return std.mem.eql(u8, afterMojo(info), MODULE_WORD);
}

fn refuse(alloc: Allocator, out: *std.ArrayList(Refusal), display: []const u8, line: usize, comptime f: []const u8, args: anytype) Allocator.Error!void {
    const head = try std.fmt.allocPrint(alloc, "{s}:{d}: ", .{ display, line });
    const body = try std.fmt.allocPrint(alloc, f, args);
    try out.append(.{ .line = line, .text = try std.mem.concat(alloc, u8, &.{ head, body }) });
}

fn isBlank(s: []const u8) bool {
    return md.indentOf(s) == s.len;
}

// The comments that may hold hidden lines, each with its own line range: a
// comment opens on a line that is not code and whose text starts with
// `<!--`, and ends on the first line after it holding `-->`.
// TODO: take each comment's line range from the Markdown module's
// per-comment function once it has one, and keep only the marker reading
// here (markdown.zig's htmlCommentMask merges adjacent comments, so it cannot
// give the range of one).
fn hiddenComments(alloc: Allocator, lines: []const []const u8, mask: []const bool, display: []const u8, refusals: *std.ArrayList(Refusal)) Allocator.Error![]Hidden {
    var out = std.ArrayList(Hidden).init(alloc);
    var i: usize = 0;
    const n = lines.len;
    while (i < n) {
        if (mask[i]) {
            i += 1;
            continue;
        }
        const t = md.strip(lines[i]);
        if (!std.mem.startsWith(u8, t, "<!--")) {
            i += 1;
            continue;
        }
        const body = md.strip(t[4..]);
        const L = MARK.len;
        const marked = std.mem.startsWith(u8, body, MARK) and !(body.len > L and body[L] != ' ' and body[L] != '\t' and
            !std.mem.startsWith(u8, body[L..], "-->"));
        if (!marked) {
            if (lowerStartsWith(body, "mojo")) {
                try refuse(alloc, refusals, display, i + 1, "`<!-- {s}`: the hidden-lines marker is exactly `<!-- mojo-hidden`", .{firstWord(body)});
            }
            i += 1;
            continue;
        }
        const rest = body[L..];
        var h = Hidden{
            .first = i,
            .last = i,
            .code = std.ArrayList([]const u8).init(alloc),
            .code_lines = std.ArrayList(usize).init(alloc),
        };
        if (std.mem.indexOf(u8, rest, "-->")) |end| {
            // One line: `<!-- mojo-hidden CODE -->`.
            const code = md.strip(rest[0..end]);
            if (md.strip(rest[end + 3 ..]).len > 0) {
                try refuse(alloc, refusals, display, i + 1, "text after `-->` on a mojo-hidden line", .{});
            }
            if (code.len > 0) {
                try h.code.append(code);
                try h.code_lines.append(i + 1);
            }
            try out.append(h);
            i += 1;
            continue;
        }
        if (md.strip(rest).len > 0) {
            try refuse(alloc, refusals, display, i + 1, "a multi-line mojo-hidden comment holds nothing after `<!-- mojo-hidden` on its first line", .{});
        }
        var j = i + 1;
        var closed = false;
        while (j < n) : (j += 1) {
            if (std.mem.indexOf(u8, lines[j], "-->")) |e| {
                const tail = lines[j][0..e];
                if (!isBlank(tail)) {
                    try h.code.append(tail);
                    try h.code_lines.append(j + 1);
                }
                if (md.strip(lines[j][e + 3 ..]).len > 0) {
                    try refuse(alloc, refusals, display, j + 1, "text after `-->` on a mojo-hidden line", .{});
                }
                closed = true;
                break;
            }
            try h.code.append(lines[j]);
            try h.code_lines.append(j + 1);
        }
        if (!closed) {
            try refuse(alloc, refusals, display, i + 1, "a mojo-hidden comment is never closed with `-->`", .{});
            break;
        }
        h.last = j;
        try out.append(h);
        i = j + 1;
    }
    return out.toOwnedSlice();
}

/// `line` without up to `indent` leading spaces and tabs.
fn dedent(line: []const u8, indent: usize) []const u8 {
    var k: usize = 0;
    while (k < indent and k < line.len and (line[k] == ' ' or line[k] == '\t')) k += 1;
    return line[k..];
}

fn byLine(_: void, a: Refusal, b: Refusal) bool {
    return a.line < b.line;
}

/// The examples of README `text`, named `display` in every message.
///
/// With `refuse_relative_links` (a README that ships in its package), a
/// relative link outside code is refused too: the installed copy sits where
/// the repository's other files do not. Anchors and absolute URLs pass.
/// Otherwise `.refused` holds every refusal, one per line, in line order.
pub fn extract(alloc: Allocator, text: []const u8, display: []const u8, refuse_relative_links: bool) Allocator.Error!Extracted {
    const lines = try md.splitLines(alloc, text);
    const mask = try md.codeMask(alloc, lines);
    var refusals = std.ArrayList(Refusal).init(alloc);
    const fs = try md.fences(alloc, lines);
    const hidden = try hiddenComments(alloc, lines, mask, display, &refusals);
    const used = try alloc.alloc(bool, hidden.len);
    @memset(used, false);
    var out = std.ArrayList(Example).init(alloc);
    for (fs) |f| {
        const at = f.open_line + 1;
        if (try infoRefusal(alloc, f.info)) |why| {
            try refuse(alloc, &refusals, display, at, "{s}", .{why});
            continue;
        }
        if (!std.mem.eql(u8, firstWord(f.info), "mojo")) continue;
        const close = f.close_line orelse {
            try refuse(alloc, &refusals, display, at, "the ```mojo example is never closed", .{});
            continue;
        };
        var code = std.ArrayList([]const u8).init(alloc);
        var code_lines = std.ArrayList(usize).init(alloc);
        for (hidden, 0..) |h, k| {
            if (f.open_line > 0 and h.last == f.open_line - 1) {
                used[k] = true;
                try code.appendSlice(h.code.items);
                try code_lines.appendSlice(h.code_lines.items);
            }
        }
        for (f.open_line + 1..close) |li| {
            try code.append(dedent(lines[li], f.indent));
            try code_lines.append(li + 1);
        }
        for (hidden, 0..) |h, k| {
            if (h.first == close + 1) {
                if (used[k]) {
                    try refuse(alloc, &refusals, display, h.first + 1, "a mojo-hidden comment both follows one example and precedes another;" ++
                        " put a blank line on one side", .{});
                }
                used[k] = true;
                try code.appendSlice(h.code.items);
                try code_lines.appendSlice(h.code_lines.items);
            }
        }
        try out.append(.{
            .line = at,
            .module = isModule(f.info),
            .code = try code.toOwnedSlice(),
            .code_lines = try code_lines.toOwnedSlice(),
        });
    }
    for (hidden, 0..) |h, k| {
        if (!used[k]) {
            try refuse(alloc, &refusals, display, h.first + 1, "a mojo-hidden comment must end on the line just before a ```mojo fence" ++
                " or start on the line just after its closing fence; this one runs nowhere", .{});
        }
    }
    if (refuse_relative_links) {
        for (try md.relativeLinks(alloc, lines)) |l| {
            if (std.mem.startsWith(u8, l.target, "#")) continue;
            try refuse(alloc, &refusals, display, l.line + 1, "{s}: a relative link in a README that ships in its package; the installed copy" ++
                " has no such file. Link an absolute URL, or an #anchor of this README", .{l.target});
        }
    }
    if (refusals.items.len > 0) {
        // Document order; stable, so refusals of one line keep their order.
        std.sort.insertion(Refusal, refusals.items, {}, byLine);
        var msg = std.ArrayList(u8).init(alloc);
        for (refusals.items, 0..) |r, k| {
            if (k > 0) try msg.append('\n');
            try msg.appendSlice(r.text);
        }
        return .{ .refused = try msg.toOwnedSlice() };
    }
    return .{ .examples = try out.toOwnedSlice() };
}
