//! The rules of a task page (`page.md` of a task directory; tasks.zig
//! checks the directory and the catalogue, docs/tasks/README.md says how a
//! page is written). A page shows its files through include markers, held
//! by the same rules, from the same code, as a package README's: the TASK
//! row of include.zig's rule table (its files are those of the task
//! directory, named alone; `.py` is shown in ```python and `.txt` in
//! ```text; it shows `example.py` and `expected_output.txt`; a ```python
//! fence that shows no file gives a not-tested reason). Its own rule is the
//! first line: `# ` and the task's question.
//!
//! Each refusal names `<page>:<line>`. The marker words are markers.zig's,
//! the one place they are spelled.

const std = @import("std");
const md = @import("markdown");
const include = @import("include.zig");
const Allocator = std.mem.Allocator;

/// A file of a task directory: its name and its bytes, null for a
/// subdirectory.
pub const File = struct {
    name: []const u8,
    data: ?[]const u8,
};

/// The marker words (markers.zig).
pub const MARKERS = include.MARKERS;

/// The files of a task directory a page may show: every file, by its name
/// (a subdirectory is none; tasks.zig refuses it).
pub fn listed(alloc: Allocator, files: []const File) Allocator.Error![]const include.Listed {
    var out = std.ArrayList(include.Listed).empty;
    for (files) |f| {
        const data = f.data orelse continue;
        try out.append(alloc, .{ .path = f.name, .data = data });
    }
    return out.toOwnedSlice(alloc);
}

/// Appends to `refusals` each refusal of the page text `page`, named
/// `page_name`, for the task whose question is `question` and whose
/// directory holds `files`.
pub fn check(alloc: Allocator, refusals: *std.ArrayList([]const u8), page_name: []const u8, question: []const u8, page: []const u8, files: []const File) Allocator.Error!void {
    const lines = try md.splitLines(alloc, page);
    const title = try std.mem.concat(alloc, u8, &.{ "# ", question });
    if (lines.len == 0 or !std.mem.eql(u8, lines[0], title)) {
        try refusals.append(alloc, try std.fmt.allocPrint(alloc, "{s}:1: the first line is not \"{s}\"", .{ page_name, title }));
    }
    const c = try include.check(alloc, &include.TASK, page, page_name, try listed(alloc, files));
    try refusals.appendSlice(alloc, c.refusals);
}
