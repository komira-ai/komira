//! The rules of a task page (`page.md` of a task directory; tasks.zig
//! checks the directory and the catalogue, docs/tasks/README.md says how a
//! page is written). A page shows its files through markers, and the check
//! reads the markers; it never guesses which fence shows which file.
//!
//!   - The first line is `# ` and the task's question.
//!   - An include is the line `<!-- include <file> -->` at the start of a
//!     line, directly before a fence that also starts its line. `<file>` is
//!     a file of the task directory, named by its file name alone (no `/`,
//!     so no `..` and no absolute path). The fence's word is the one its
//!     extension names (EXTENSIONS: `.py` python, `.txt` text), and its body
//!     is the file byte for byte, each body line ended by a line feed. A
//!     file shown so holds no carriage return.
//!   - The page includes `example.py` and `expected_output.txt`.
//!   - A fence that shows no file says why: the line before it is
//!     `<!-- not-tested: <reason> -->`, with a reason. A `python` fence
//!     needs one or an include. So does a `text` fence that directly follows
//!     a code fence (one with a word other than `text`) or an included
//!     fence, with only blank lines between: output a page shows was printed by a run,
//!     or it says it was not.
//!
//! Each refusal names `<page>:<line>`. The marker words are MARKERS, the
//! one place they are spelled.

const std = @import("std");
const md = @import("markdown");
const Allocator = std.mem.Allocator;

/// A file of a task directory: its name and its bytes, null for a
/// subdirectory.
pub const File = struct {
    name: []const u8,
    data: ?[]const u8,
};

/// The marker words: an include, and a fence that shows no file.
pub const MARKERS = struct {
    pub const open = "<!-- ";
    pub const close = " -->";
    pub const include = "include ";
    pub const not_tested = "not-tested: ";
};

/// The fence word of each extension a page may include.
pub const EXTENSIONS = [_]struct { ext: []const u8, word: []const u8 }{
    .{ .ext = ".py", .word = "python" },
    .{ .ext = ".txt", .word = "text" },
};

/// The files every page includes.
pub const SHOWN = [_][]const u8{ "example.py", "expected_output.txt" };

/// The argument of the marker `word` that `line` is, whole, or null when
/// it is not that marker.
fn marker(line: []const u8, comptime word: []const u8) ?[]const u8 {
    const head = MARKERS.open ++ word;
    if (!std.mem.startsWith(u8, line, head) or !std.mem.endsWith(u8, line, MARKERS.close)) return null;
    if (line.len < head.len + MARKERS.close.len) return null;
    return line[head.len .. line.len - MARKERS.close.len];
}

fn wordOf(name: []const u8) ?[]const u8 {
    for (EXTENSIONS) |e| {
        if (std.mem.endsWith(u8, name, e.ext) and name.len > e.ext.len) return e.word;
    }
    return null;
}

fn find(files: []const File, name: []const u8) ?File {
    for (files) |f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

/// The line (from 1) of the first difference between the fence body
/// `lines` and the file `data`, compared as lines.
fn firstDifference(alloc: Allocator, lines: []const []const u8, data: []const u8) Allocator.Error!usize {
    const want = try md.splitLines(alloc, data);
    var n: usize = 0;
    while (n < lines.len and n < want.len and std.mem.eql(u8, lines[n], want[n])) n += 1;
    return n + 1;
}

const Ctx = struct {
    alloc: Allocator,
    refusals: *std.ArrayList([]const u8),
    /// The page's name in a refusal, `<dir>/page.md`.
    page: []const u8,

    fn refuse(self: Ctx, line: ?usize, comptime f: []const u8, args: anytype) Allocator.Error!void {
        const what = try std.fmt.allocPrint(self.alloc, f, args);
        const text = if (line) |l|
            try std.fmt.allocPrint(self.alloc, "{s}:{d}: {s}", .{ self.page, l, what })
        else
            try std.fmt.allocPrint(self.alloc, "{s}: {s}", .{ self.page, what });
        try self.refusals.append(self.alloc, text);
    }
};

fn checkInclude(c: Ctx, lines: []const []const u8, f: md.Fence, name: []const u8, files: []const File) Allocator.Error!bool {
    const at = f.open_line; // the marker's line, from 1
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null or std.mem.eql(u8, name, "..")) {
        try c.refuse(at, "include \"{s}\" is not the name of a file of the task directory", .{name});
        return false;
    }
    const file = find(files, name) orelse {
        try c.refuse(at, "include {s}: the task directory has no such file", .{name});
        return false;
    };
    const data = file.data orelse {
        try c.refuse(at, "include {s}: a directory, not a file", .{name});
        return false;
    };
    const word = wordOf(name) orelse {
        try c.refuse(at, "include {s}: a page includes only .py and .txt files", .{name});
        return false;
    };
    if (f.indent != 0) {
        try c.refuse(at, "include {s}: the fence after it does not start its line", .{name});
        return false;
    }
    if (!std.mem.eql(u8, f.info, word)) {
        try c.refuse(f.open_line + 1, "include {s} is shown in a ```{s} fence; a {s} file is shown in ```{s}", .{ name, f.info, std.fs.path.extension(name), word });
        return false;
    }
    if (std.mem.indexOfScalar(u8, data, '\r') != null) {
        try c.refuse(at, "include {s}: the file holds a carriage return", .{name});
        return false;
    }
    const close = f.close_line orelse {
        try c.refuse(f.open_line + 1, "include {s}: the fence is not closed", .{name});
        return false;
    };
    const body = lines[f.open_line + 1 .. close];
    var text = std.ArrayList(u8).empty;
    for (body) |l| {
        try text.appendSlice(c.alloc, l);
        try text.append(c.alloc, '\n');
    }
    if (!std.mem.eql(u8, text.items, data)) {
        try c.refuse(f.open_line + 1, "include {s} is stale (first difference at line {d} of {s})", .{ name, try firstDifference(c.alloc, body, data), name });
        return false;
    }
    return true;
}

/// Whether the last non-blank line before `line` (an index) is an include
/// marker, or closes a code fence or a fence an include fills.
fn followsCode(lines: []const []const u8, fences: []const md.Fence, line: usize) bool {
    var i = line;
    while (i > 0) {
        i -= 1;
        if (md.strip(lines[i]).len == 0) continue;
        if (marker(lines[i], MARKERS.include) != null) return true;
        for (fences) |g| {
            const cl = g.close_line orelse continue;
            if (cl != i) continue;
            const code = g.info.len > 0 and !std.mem.eql(u8, g.info, "text");
            const included = g.open_line > 0 and marker(lines[g.open_line - 1], MARKERS.include) != null;
            return code or included;
        }
        return false;
    }
    return false;
}

/// Appends to `refusals` each refusal of the page text `page`, named
/// `page_name`, for the task whose question is `question` and whose
/// directory holds `files`.
pub fn check(alloc: Allocator, refusals: *std.ArrayList([]const u8), page_name: []const u8, question: []const u8, page: []const u8, files: []const File) Allocator.Error!void {
    const c = Ctx{ .alloc = alloc, .refusals = refusals, .page = page_name };
    const lines = try md.splitLines(alloc, page);
    const title = try std.mem.concat(alloc, u8, &.{ "# ", question });
    if (lines.len == 0 or !std.mem.eql(u8, lines[0], title)) {
        try c.refuse(1, "the first line is not \"{s}\"", .{title});
    }
    const fences = try md.fences(alloc, lines);
    var shown = [_]bool{false} ** SHOWN.len;
    for (fences) |f| {
        const before: ?[]const u8 = if (f.open_line > 0) lines[f.open_line - 1] else null;
        if (before) |b| {
            if (marker(b, MARKERS.include)) |name| {
                // Shown, even when the include is refused: its refusal is the one to fix.
                for (SHOWN, 0..) |s, k| {
                    if (std.mem.eql(u8, s, name)) shown[k] = true;
                }
                _ = try checkInclude(c, lines, f, name, files);
                continue;
            }
            if (marker(b, MARKERS.not_tested)) |why| {
                if (md.strip(why).len == 0) try c.refuse(f.open_line, "a not-tested marker gives no reason", .{});
                continue;
            }
        }
        if (std.mem.eql(u8, f.info, "python")) {
            try c.refuse(f.open_line + 1, "a ```python fence that shows no file: put <!-- include <file> --> or <!-- not-tested: <reason> --> on the line before it", .{});
        } else if (std.mem.eql(u8, f.info, "text") and followsCode(lines, fences, f.open_line)) {
            try c.refuse(f.open_line + 1, "a ```text fence after code shows output no run printed: include its file, or put <!-- not-tested: <reason> --> on the line before it", .{});
        }
    }
    for (SHOWN, shown) |s, ok| {
        // A file that does not exist is the directory check's refusal.
        if (!ok and find(files, s) != null) try c.refuse(null, "the page does not show {s}: no <!-- include {s} --> before a fence", .{ s, s });
    }
}
