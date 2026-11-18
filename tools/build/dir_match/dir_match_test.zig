//! Unit tests of dir_match.zig.
const std = @import("std");
const m = @import("dir_match.zig");
const t = std.testing;

test "holdsDir: the directory alone, under it, quoted, after a flag, a variable or a URL scheme" {
    for ([_][]const u8{
        "/work",
        "debug info: /work/crate/src/lib.rs",
        "\x00/work\x00",
        "PWD=\"/work\"",
        "-I/work/inc",
        "x -L/work/lib",
        "PWD=/work",
        "file:///work/x",
        "/work:/usr/lib",
        "/work /other",
    }) |hay| {
        t.expect(m.holdsDir(hay, "/work")) catch |e| {
            std.debug.print("not held: {s}\n", .{hay});
            return e;
        };
    }
}

test "holdsDir: a longer name that starts with the directory's bytes does not count" {
    for ([_][]const u8{
        "komira_async/runtime/worker.mojo",
        "/workspaces/w1/review-policy",
        "/work.d /work_1 /work-a /work+b /work~ /work@c /work9",
        "/work\xc3\xa9",
        "",
        "/wor",
    }) |hay| {
        t.expect(!m.holdsDir(hay, "/work")) catch |e| {
            std.debug.print("held: {s}\n", .{hay});
            return e;
        };
    }
}

test "holdsDir: the directory as a later component of another absolute path does not count" {
    for ([_][]const u8{
        "/home/someone/work/buck-out/v2/gen",
        "\x00/a/work\x00",
        "/x.y-z/work",
        "/caf\xc3\xa9/work",
    }) |hay| {
        t.expect(!m.holdsDir(hay, "/work")) catch |e| {
            std.debug.print("held: {s}\n", .{hay});
            return e;
        };
    }
    // A relative path: nothing before its first name says it is a path.
    try t.expect(m.holdsDir("pkg/work/x", "/work"));
    try t.expect(m.holdsDir("\x00pkg/work\x00", "/work"));
}

test "holdsDir: a later match counts after earlier ones that do not" {
    try t.expect(m.holdsDir("runtime/worker.mojo and /work/x", "/work"));
    try t.expect(m.holdsDir("/worker:/work", "/work"));
    // Under `/worker`, the second `/work` is a later component of that path.
    try t.expect(!m.holdsDir("/worker/work", "/work"));
    try t.expect(m.holdsDir("/home/someone/work /work", "/work"));
    try t.expect(!m.holdsDir("/worker /home/someone/work /workspaces", "/work"));
}

test "holdsDir: a directory ending in / has no name to continue; an empty one never counts" {
    try t.expect(m.holdsDir("/work/er", "/work/"));
    try t.expect(!m.holdsDir("/a/work/er", "/work/"));
    try t.expect(!m.holdsDir("/work", "/work/"));
    try t.expect(!m.holdsDir("/work", ""));
}

test "heldAt: the bytes before and after one match" {
    try t.expect(m.heldAt("/work", "/work", 0));
    try t.expect(!m.heldAt("/worker", "/work", 0));
    try t.expect(m.heldAt("x/work", "/work", 1));
    try t.expect(!m.heldAt("/x/work", "/work", 2));
    try t.expect(m.heldAt("//work", "/work", 1));
}

test "continuesName: name bytes and the bytes that end a name" {
    for ("az09AZ._-+~@\x80\xff") |c| try t.expect(m.continuesName(c));
    for ("/\x00\"' =:;,\n\t") |c| try t.expect(!m.continuesName(c));
}

test "holdsAnyDir: any of the directories, none of an empty list" {
    try t.expect(m.holdsAnyDir("x /real/dir/y", &.{ "/work", "/real/dir" }));
    try t.expect(!m.holdsAnyDir("runtime/worker.mojo", &.{ "/work", "/real/dir" }));
    try t.expect(!m.holdsAnyDir("/work", &.{}));
}
