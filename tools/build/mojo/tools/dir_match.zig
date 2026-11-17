//! dir_match: whether a compile output holds a directory as a path, for the
//! output check of mojo_compile.zig (exit 4). A match of the directory's bytes
//! counts only where its last path name ends: at the end of the data, or
//! before a byte that cannot continue a file name (`/`, NUL, a quote, a
//! space, `=`, `:` and the like). So with the working directory `/work`,
//! `/work/x.mojo`, `"/work"` and `-I/work/inc` count, and
//! `komira_async/runtime/worker.mojo` (a relative source path the compiler
//! records) does not. A directory that ends in `/` counts wherever it is.
//! Only the byte after a match is read: a relative path with a component of
//! the same name (`pkg/work/x.mojo` under `/work`) still counts.

const std = @import("std");

/// Whether `c`, after a match, continues the last name of the path: an ASCII
/// letter or digit, `.`, `_`, `-`, `+`, `~`, `@`, or a byte of a multi-byte
/// UTF-8 sequence. The same set as tools/build/rust/rustc_launch.zig's
/// (that launcher is built from its one file): a change to one is made to both.
pub fn continuesName(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80 or switch (c) {
        '.', '_', '-', '+', '~', '@' => true,
        else => false,
    };
}

/// Whether the match of `dir` at `at` in `hay` ends where a path name ends.
fn endsName(hay: []const u8, dir: []const u8, at: usize) bool {
    const end = at + dir.len;
    return dir[dir.len - 1] == '/' or end == hay.len or !continuesName(hay[end]);
}

/// Whether `hay` holds `dir` as a path (see the file comment). An empty
/// `dir` is never held.
pub fn holdsDir(hay: []const u8, dir: []const u8) bool {
    if (dir.len == 0) return false;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, hay, from, dir)) |at| {
        if (endsName(hay, dir, at)) return true;
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

const t = std.testing;

test "holdsDir: the directory alone, under it, and quoted or after a flag count" {
    try t.expect(holdsDir("/work", "/work"));
    try t.expect(holdsDir("debug info: /work/crate/src/lib.rs", "/work"));
    try t.expect(holdsDir("\x00/work\x00", "/work"));
    try t.expect(holdsDir("PWD=\"/work\"", "/work"));
    try t.expect(holdsDir("-I/work/inc", "/work"));
    try t.expect(holdsDir("/work:/usr/lib", "/work"));
    try t.expect(holdsDir("/work /other", "/work"));
}

test "holdsDir: a longer name that starts with the directory's bytes does not count" {
    try t.expect(!holdsDir("komira_async/runtime/worker.mojo", "/work"));
    try t.expect(!holdsDir("/workspace/x", "/work"));
    try t.expect(!holdsDir("/work.d /work_1 /work-a /work+b /work~ /work@c /work9", "/work"));
    try t.expect(!holdsDir("/work\xc3\xa9", "/work"));
    try t.expect(!holdsDir("", "/work"));
    try t.expect(!holdsDir("/wor", "/work"));
}

test "holdsDir: a later match counts after an earlier one that does not" {
    try t.expect(holdsDir("runtime/worker.mojo and /work/x", "/work"));
    try t.expect(holdsDir("/worker/work", "/work"));
}

test "holdsDir: a directory ending in / counts wherever it is; an empty one never" {
    try t.expect(holdsDir("/work/er", "/work/"));
    try t.expect(!holdsDir("/work", "/work/"));
    try t.expect(!holdsDir("/work", ""));
}

test "continuesName: name bytes and the bytes that end a name" {
    for ("az09AZ._-+~@\x80\xff") |c| try t.expect(continuesName(c));
    for ("/\x00\"' =:;,\n\t") |c| try t.expect(!continuesName(c));
}

test "holdsAnyDir: any of the directories, none of an empty list" {
    try t.expect(holdsAnyDir("x /real/dir/y", &.{ "/work", "/real/dir" }));
    try t.expect(!holdsAnyDir("runtime/worker.mojo", &.{ "/work", "/real/dir" }));
    try t.expect(!holdsAnyDir("/work", &.{}));
}
