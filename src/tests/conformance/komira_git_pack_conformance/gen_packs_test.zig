//! Unit tests of gen_packs.zig's generators and readers: the file contents that
//! make the history (so the packs git writes from them are the packs the tests
//! read), the verify-pack reshaping, and the id list. The packs themselves are
//! :packs, read by every test of the package.
const std = @import("std");
const G = @import("gen_packs.zig");
const t = std.testing;

test "fileA: 400 lines; the revision shows on the lines whose number matches the commit mod 30" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const text = try G.fileA(a, 7);
    var lines = std.mem.splitScalar(u8, text, '\n');
    try t.expectEqualStrings("line 1 of a.txt, revision 0", lines.next().?);
    var n: usize = 1;
    var hit: usize = 0;
    while (lines.next()) |l| {
        if (l.len == 0) break;
        n += 1;
        if (std.mem.endsWith(u8, l, "revision 7")) hit += 1;
    }
    try t.expectEqual(@as(usize, 399), n - 1 + 0 * n);
    try t.expectEqual(@as(usize, 14), hit); // 7, 37, ..., 397 (k % 30 == 7)
    try t.expect(std.mem.endsWith(u8, text, "line 400 of a.txt, revision 0\n"));
    // Thirty commits later the pattern repeats, with its own number.
    try t.expectEqual(@as(usize, 13), std.mem.count(u8, try G.fileA(a, 30), "revision 30\n"));
}

test "fileBig: 5000 + 100 i lines of eight digits and a word" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const text = try G.fileBig(a, 2);
    try t.expect(std.mem.startsWith(u8, text, "00007919 same\n00015838 edited\n"));
    try t.expectEqual(@as(usize, 5200), std.mem.count(u8, text, "\n"));
    // k % 97 == 2: k = 2, 99, 196, ... ; the first is the second line.
    var lines = std.mem.splitScalar(u8, text, '\n');
    _ = lines.next();
    try t.expectEqualStrings("00015838 edited", lines.next().?);
}

test "fileNew and date" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("new file 5, line 1\nnew file 5, line 2\n", (try G.fileNew(a, 5))[0..38]);
    try t.expectEqual(@as(usize, 100), std.mem.count(u8, try G.fileNew(a, 5), "\n"));
    try t.expectEqualStrings("1790000060 +0000", try G.date(a, 1));
    try t.expectEqualStrings("1790001800 +0000", try G.date(a, 30));
}

test "verifyLines: object lines only, depth and base given or zero and a dash" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const id1 = "0123456789abcdef0123456789abcdef01234567";
    const id2 = "fedcba9876543210fedcba9876543210fedcba98";
    const text = id1 ++ " commit 200 150 12\n" ++
        id2 ++ " blob   3000 800 162 2 " ++ id1 ++ "\n" ++
        "non delta: 1 object\n" ++
        "chain length = 2: 1 object\n" ++
        "pack.pack: ok\n" ++
        "XYZ456789abcdef0123456789abcdef01234567 blob 1 1 1\n";
    const out = try G.verifyLines(a, text);
    try t.expectEqualStrings(id1 ++ " commit 200 150 12 0 -\n" ++ id2 ++ " blob 3000 800 162 2 " ++ id1 ++ "\n", out);
    // A 64-digit id (sha256) is an object, a 41-digit one is not.
    const id64 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try t.expect((try G.verifyLines(a, id64 ++ " tree 10 10 12\n")).len > 0);
    try t.expectEqual(@as(usize, 0), (try G.verifyLines(a, id1 ++ "0 tree 10 10 12\n")).len);
}

test "sortedPrefixes: the first bytes of each line, sorted, duplicates kept" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("aaaa\nbbbb\nbbbb\n", try G.sortedPrefixes(a, "bbbb path/x\nbbbb\naaaa y\n", 4));
    try t.expectEqualStrings("", try G.sortedPrefixes(a, "", 4));
}
