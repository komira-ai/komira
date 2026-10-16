//! Unit tests of capture.zig's readers: the ssh command line git hands its ssh
//! (the server side of a connection), git's shell quoting of the repository path,
//! and the reshaping of for-each-ref. The recorded exchanges themselves are
//! :transcripts, which every test of the package reads; the shim's process
//! behaviour is tests//functional/git_capture.
const std = @import("std");
const C = @import("capture.zig");
const t = std.testing;

test "shellWords: bare words, quoted groups, escaped quotes, adjacent pieces joined" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const w = try C.shellWords(a, "git-upload-pack '/tmp/a b/it'\\''s'  x\\ y");
    try t.expectEqual(@as(usize, 3), w.len);
    try t.expectEqualStrings("git-upload-pack", w[0]);
    try t.expectEqualStrings("/tmp/a b/it's", w[1]);
    try t.expectEqualStrings("x y", w[2]);
    try t.expectEqual(@as(usize, 1), (try C.shellWords(a, "'' ")).len);
    try t.expectError(error.UnterminatedQuote, C.shellWords(a, "x 'abc"));
    try t.expectError(error.TrailingBackslash, C.shellWords(a, "x\\"));
}

test "parseSsh: options with and without values are skipped; the command names a service and a path" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try C.parseSsh(a, &.{ "-o", "SendEnv=GIT_PROTOCOL", "-4", "-p", "2222", "localhost", "git-upload-pack '/r/x.git'" });
    try t.expectEqualStrings("upload-pack", r.service);
    try t.expectEqualStrings("/r/x.git", r.path);
    const p = try C.parseSsh(a, &.{ "localhost", "git-receive-pack '/d'" });
    try t.expectEqualStrings("receive-pack", p.service);
}

test "parseSsh: anything else is refused, so the shim never runs an arbitrary command" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectError(error.NoCommand, C.parseSsh(a, &.{"localhost"}));
    try t.expectError(error.NoCommand, C.parseSsh(a, &.{ "-o", "x" }));
    try t.expectError(error.BadCommand, C.parseSsh(a, &.{ "localhost", "git-shell '/x'" }));
    try t.expectError(error.BadCommand, C.parseSsh(a, &.{ "localhost", "rm '/x'" }));
    try t.expectError(error.BadCommand, C.parseSsh(a, &.{ "localhost", "git-upload-pack '/x' '/y'" }));
    try t.expectError(error.BadCommand, C.parseSsh(a, &.{ "localhost", "git-upload-archive '/x'" }));
}

test "refsText: an annotated tag keeps its peeled id, everything else a dash" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const text = "aaa refs/heads/main \nbbb refs/tags/v1 ccc\nddd refs/tags/light \n";
    try t.expectEqualStrings("aaa refs/heads/main -\nbbb refs/tags/v1 ccc\nddd refs/tags/light -\n", try C.refsText(a, text));
    try t.expectEqualStrings("", try C.refsText(a, ""));
}
