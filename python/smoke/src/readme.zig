//! pypi_smoke: the docs show the quickstart. A `Shown` names a Markdown document and the file one of its
//! fenced blocks must equal; `docShowsBlock` holds the document to it: the document must contain a line that is
//! exactly "```<fence>", then lines whose concatenation (each with its line feed) is the file's text byte for
//! byte, then a line that is exactly "```". A document with CRLF line ends, a trailing space or another line in
//! the block is not equal.
//!
//! Four are checked on the real files (readme_shows_quickstart_test.zig, install_page_shows_quickstart_test.zig):
//! the README's "What works" block is python/examples/quickstart.py (`readmeShowsExample`) and the README shows
//! what it prints (`readme_output`), and the install page, docs/install.md, shows the same program
//! (`install_page_example`) and what it prints (`install_page_output`): python/examples/quickstart.expected with
//! `<version>` the newest release of python/CHANGELOG.md (`newestRelease`) and `<abi_version>` the engine's C ABI
//! version. The docs leave `<cwd>` as written (they explain it), so the files are compared with the literal
//! `<cwd>` put in for the directory.
const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;

/// A document and the file one of its blocks must be.
pub const Shown = struct {
    /// The document's path, as the refusal names it.
    doc: []const u8,
    /// What the refusal calls the document.
    doc_noun: []const u8,
    /// The fence's info word: "python" for "```python".
    fence: []const u8,
    /// The path of the file the block must equal.
    source: []const u8,
    /// What the refusal calls that file.
    source_noun: []const u8,
};

pub const readme_example: Shown = .{
    .doc = "python/README.md",
    .doc_noun = "the README",
    .fence = "python",
    .source = "python/examples/quickstart.py",
    .source_noun = "the example",
};

pub const readme_output: Shown = .{
    .doc = "python/README.md",
    .doc_noun = "the README",
    .fence = "text",
    .source = "python/examples/quickstart.expected",
    .source_noun = "the expected output",
};

pub const install_page_example: Shown = .{
    .doc = "docs/install.md",
    .doc_noun = "the page",
    .fence = "python",
    .source = "python/examples/quickstart.py",
    .source_noun = "the example",
};

pub const install_page_output: Shown = .{
    .doc = "docs/install.md",
    .doc_noun = "the page",
    .fence = "text",
    .source = "python/examples/quickstart.expected",
    .source_noun = "the expected output",
};

fn lines(a: Allocator, text: []const u8) ![]const []const u8 {
    var list = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try list.append(a, line);
    return list.items;
}

/// null when the document holds `want_text` as a ```<fence> block; else the refusal, naming the first line where
/// the block that agrees with `want_text` for the most lines differs from it.
pub fn docShowsBlock(a: Allocator, shown: Shown, doc_text: []const u8, want_text: []const u8) !?[]const u8 {
    const head = try std.fmt.allocPrint(a, "{s} shows no ```{s} block equal to {s}: ", .{ shown.doc, shown.fence, shown.source });
    const open = try std.fmt.allocPrint(a, "```{s}", .{shown.fence});
    if (want_text.len == 0 or want_text[want_text.len - 1] != '\n')
        return try std.fmt.allocPrint(a, "{s}{s} does not end with a line feed", .{ head, shown.source_noun });
    const want = try lines(a, want_text[0 .. want_text.len - 1]);
    // A document that ends with a line feed has no empty last line.
    const all = try lines(a, if (std.mem.endsWith(u8, doc_text, "\n")) doc_text[0 .. doc_text.len - 1] else doc_text);
    var best: ?usize = null; // the number of lines the closest block agrees on
    var best_have: []const u8 = "";
    var best_want: []const u8 = "";
    var best_line: usize = 0;
    var i: usize = 0;
    while (i < all.len) : (i += 1) {
        if (!std.mem.eql(u8, all[i], open)) continue;
        var j = i + 1;
        while (j < all.len and !std.mem.eql(u8, all[j], "```")) j += 1;
        const body = all[i + 1 .. j];
        const closed = j < all.len;
        var k: usize = 0;
        while (k < body.len and k < want.len and std.mem.eql(u8, body[k], want[k])) k += 1;
        if (closed and body.len == want.len and k == want.len) return null;
        if (best == null or k > best.?) {
            best = k;
            best_line = k + 1;
            best_have = if (k < body.len) body[k] else if (closed) "(the block ends)" else try std.fmt.allocPrint(a, "({s} ends)", .{shown.doc_noun});
            best_want = if (k < want.len) want[k] else try std.fmt.allocPrint(a, "({s} ends)", .{shown.source_noun});
        }
    }
    if (best == null) return try std.fmt.allocPrint(a, "{s}{s} has no line that is exactly {s}", .{ head, shown.doc_noun, open });
    return try std.fmt.allocPrint(a, "{s}line {d} of the closest block reads '{s}', {s}'s reads '{s}'", .{ head, best_line, best_have, shown.source_noun, best_want });
}

/// null when the README holds the example as a ```python block; else the refusal (`docShowsBlock`).
pub fn readmeShowsExample(a: Allocator, readme_text: []const u8, example_text: []const u8) !?[]const u8 {
    return docShowsBlock(a, readme_example, readme_text, example_text);
}

/// The version of the newest release `changelog_text` (the changelog at `path`) lists: its first second-level
/// heading other than `## Unreleased`, which must be exactly `## <version>`, the version being numbers joined by
/// dots (`0.1.1512`), as the release workflow spells a release.
pub fn newestRelease(a: Allocator, why: *[]const u8, path: []const u8, changelog_text: []const u8) common.Error![]const u8 {
    var it = std.mem.splitScalar(u8, changelog_text, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "## ")) continue;
        if (std.mem.eql(u8, line, "## Unreleased")) continue;
        const version = line["## ".len..];
        if (releaseVersion(version)) return version;
        return common.refuse(a, why, "{s}: the newest release's heading is '{s}', not `## <version>` (numbers joined by dots)", .{ path, line });
    }
    return common.refuse(a, why, "{s} lists no release: no heading `## <version>`", .{path});
}

fn releaseVersion(text: []const u8) bool {
    var parts = std.mem.splitScalar(u8, text, '.');
    var n: usize = 0;
    while (parts.next()) |part| : (n += 1) {
        if (part.len == 0) return false;
        for (part) |c| if (!std.ascii.isDigit(c)) return false;
    }
    return n >= 2;
}
