//! dir_match: whether a build output holds a directory as a path. The output
//! checks of mojo_compile (exit 4), rustc_launch (exit 4) and `cov_branch
//! link` refuse an output that holds the action's working directory; they
//! ask this module, so the three agree.
//!
//! A match of the directory's bytes counts unless it is part of another name:
//!   * after it: the next byte continues a name (`continuesName`), so
//!     `/worker.mojo` and `/workspaces` are not `/work`;
//!   * before it: the bytes before it are the end of an earlier component of
//!     another path, a run of name bytes that follows a `/`, so
//!     `/home/someone/work/x` is not `/work`.
//! So with the directory `/work`, `/work`, `/work/x.mojo`, `"/work"`,
//! `-I/work/inc`, `PWD=/work` and `file:///work` count. A relative path with
//! a component of the same name (`pkg/work/x`) counts too: nothing before
//! `pkg` says it is a path. A directory that ends in `/` has no name to
//! continue, so only the bytes before it are read. The bytes around a match
//! are all this reads: a string stored with no delimiter, right before or
//! after a name byte of another record, can hide `/work` itself; any path
//! under it still shows, since a `/` follows the directory.

const std = @import("std");

/// Whether `c` can be part of a path name: an ASCII letter or digit, `.`,
/// `_`, `-`, `+`, `~`, `@`, or a byte of a multi-byte UTF-8 sequence.
pub fn continuesName(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80 or switch (c) {
        '.', '_', '-', '+', '~', '@' => true,
        else => false,
    };
}

/// Whether the match of `dir` at `at` in `hay` is the directory itself, not
/// part of another name (see the file comment). `dir` is not empty and
/// `hay[at..]` starts with it.
pub fn heldAt(hay: []const u8, dir: []const u8, at: usize) bool {
    std.debug.assert(dir.len > 0 and std.mem.startsWith(u8, hay[at..], dir));
    const end = at + dir.len;
    if (dir[dir.len - 1] != '/' and end < hay.len and continuesName(hay[end])) return false;
    // The run of name bytes just before the match, and what precedes it.
    var start = at;
    while (start > 0 and continuesName(hay[start - 1])) start -= 1;
    return start == at or start == 0 or hay[start - 1] != '/';
}

/// Whether `hay` holds `dir` as a path. An empty `dir` is never held.
pub fn holdsDir(hay: []const u8, dir: []const u8) bool {
    if (dir.len == 0) return false;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, hay, from, dir)) |at| {
        if (heldAt(hay, dir, at)) return true;
        from = at + 1;
    }
    return false;
}

/// Whether `hay` holds any of `dirs` as a path.
pub fn holdsAnyDir(hay: []const u8, dirs: []const []const u8) bool {
    for (dirs) |d| {
        if (holdsDir(hay, d)) return true;
    }
    return false;
}
