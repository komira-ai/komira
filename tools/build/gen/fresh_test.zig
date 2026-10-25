//! Unit tests of fresh.zig: the comparison of the committed directory with the
//! generator's output, and the message. The tool's process behaviour is
//! tests//functional/gen_fresh; the gate it is in is `<name>_fresh` of every
//! generated library.
const std = @import("std");
const F = @import("fresh.zig");
const U = @import("act_util");
const t = std.testing;

const Rig = struct {
    gen: std.testing.TmpDir,
    committed: std.testing.TmpDir,

    fn init() Rig {
        return .{ .gen = t.tmpDir(.{ .iterate = true }), .committed = t.tmpDir(.{ .iterate = true }) };
    }

    fn deinit(self: *Rig) void {
        self.gen.cleanup();
        self.committed.cleanup();
    }

    /// Both directories hold the file.
    fn both(self: *Rig, name: []const u8, data: []const u8) !void {
        try U.makeParent(self.gen.dir, name);
        try U.makeParent(self.committed.dir, name);
        try U.writeAll(self.gen.dir, name, data);
        try U.writeAll(self.committed.dir, name, data);
    }
};

test "judge: the same files with the same bytes are in sync, subdirectories included" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = Rig.init();
    defer r.deinit();
    try r.both("__init__.mojo", "# header\n");
    try r.both("svc.mojo", "struct A:\n    pass\n");
    try r.both("sub/deep.mojo", "x\n");
    const rep = try F.judge(a, r.gen.dir, r.committed.dir);
    try t.expect(rep.inSync());
}

test "judge: a committed file with other bytes differs, at its first different line" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = Rig.init();
    defer r.deinit();
    try r.both("__init__.mojo", "# header\n");
    try U.writeAll(r.gen.dir, "svc.mojo", "one\ntwo\nthree\n");
    try U.writeAll(r.committed.dir, "svc.mojo", "one\ntwo edited by hand\nthree\n");
    const rep = try F.judge(a, r.gen.dir, r.committed.dir);
    try t.expect(!rep.inSync());
    try t.expectEqual(@as(usize, 0), rep.missing.len);
    try t.expectEqual(@as(usize, 0), rep.stale.len);
    try t.expectEqual(@as(usize, 1), rep.differ.len);
    try t.expectEqualStrings("svc.mojo", rep.differ[0].name);
    try t.expectEqual(@as(usize, 2), rep.differ[0].line);
    try t.expectEqualStrings("two edited by hand", rep.differ[0].committed);
    try t.expectEqualStrings("two", rep.differ[0].generated);
}

test "judge: a file the generator writes and nobody committed is missing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = Rig.init();
    defer r.deinit();
    try r.both("__init__.mojo", "# header\n");
    try U.writeAll(r.gen.dir, "new_module.mojo", "x\n");
    const rep = try F.judge(a, r.gen.dir, r.committed.dir);
    try t.expectEqual(@as(usize, 1), rep.missing.len);
    try t.expectEqualStrings("new_module.mojo", rep.missing[0]);
    try t.expectEqual(@as(usize, 0), rep.stale.len);
    try t.expectEqual(@as(usize, 0), rep.differ.len);
}

test "judge: a committed file the generator no longer writes is stale" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = Rig.init();
    defer r.deinit();
    try r.both("__init__.mojo", "# header\n");
    try U.writeAll(r.committed.dir, "old_module.mojo", "x\n");
    try r.committed.dir.makePath("leftover");
    try U.writeAll(r.committed.dir, "leftover/a.mojo", "y\n");
    const rep = try F.judge(a, r.gen.dir, r.committed.dir);
    try t.expectEqual(@as(usize, 2), rep.stale.len);
    try t.expectEqualStrings("leftover/a.mojo", rep.stale[0]);
    try t.expectEqualStrings("old_module.mojo", rep.stale[1]);
}

test "judge: all three at once, each reported in sorted order" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = Rig.init();
    defer r.deinit();
    try U.writeAll(r.gen.dir, "b.mojo", "1\n");
    try U.writeAll(r.gen.dir, "a.mojo", "1\n");
    try U.writeAll(r.gen.dir, "c.mojo", "new\n");
    try U.writeAll(r.committed.dir, "c.mojo", "old\n");
    try U.writeAll(r.committed.dir, "z.mojo", "1\n");
    const rep = try F.judge(a, r.gen.dir, r.committed.dir);
    try t.expectEqual(@as(usize, 2), rep.missing.len);
    try t.expectEqualStrings("a.mojo", rep.missing[0]);
    try t.expectEqualStrings("b.mojo", rep.missing[1]);
    try t.expectEqualStrings("z.mojo", rep.stale[0]);
    try t.expectEqualStrings("c.mojo", rep.differ[0].name);
}

test "judge: an empty committed directory misses every generated file" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = Rig.init();
    defer r.deinit();
    try U.writeAll(r.gen.dir, "a.mojo", "1\n");
    try U.writeAll(r.gen.dir, "__init__.mojo", "1\n");
    const rep = try F.judge(a, r.gen.dir, r.committed.dir);
    try t.expectEqual(@as(usize, 2), rep.missing.len);
}

test "judge: a difference past the last line (a missing final newline) is still a difference" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = Rig.init();
    defer r.deinit();
    try U.writeAll(r.gen.dir, "a.mojo", "one\n");
    try U.writeAll(r.committed.dir, "a.mojo", "one");
    const rep = try F.judge(a, r.gen.dir, r.committed.dir);
    try t.expectEqual(@as(usize, 1), rep.differ.len);
    try t.expectEqual(@as(usize, 2), rep.differ[0].line);
}

test "render: names each finding and ends with the regenerate command and the directory to commit" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rep = F.Report{
        .missing = &.{"m.mojo"},
        .stale = &.{"s.mojo"},
        .differ = &.{.{ .name = "d.mojo", .line = 7, .committed = "old", .generated = "new" }},
    };
    const text = try F.render(a, rep, "komira//src/x:x", "src/x/generated/x", "./buck2 run komira//tools/build/gen:regen -- komira//src/x:x");
    try t.expect(std.mem.indexOf(u8, text, "the committed generated sources of komira//src/x:x are out of date (src/x/generated/x/)") != null);
    try t.expect(std.mem.indexOf(u8, text, "missing, generated now but not committed: m.mojo\n") != null);
    try t.expect(std.mem.indexOf(u8, text, "stale, committed but no longer generated: s.mojo\n") != null);
    try t.expect(std.mem.indexOf(u8, text, "differs: d.mojo, first at line 7:\n    committed: old\n    generated: new\n") != null);
    try t.expect(std.mem.endsWith(u8, text, "Regenerate with:\n    ./buck2 run komira//tools/build/gen:regen -- komira//src/x:x\nand commit src/x/generated/x/.\n"));
}

test "render: a very long line is quoted cut" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = Rig.init();
    defer r.deinit();
    const long = "x" ** 500;
    try U.writeAll(r.gen.dir, "a.mojo", long ++ "\n");
    try U.writeAll(r.committed.dir, "a.mojo", "y\n");
    const rep = try F.judge(a, r.gen.dir, r.committed.dir);
    try t.expect(rep.differ[0].generated.len < 200);
    try t.expect(std.mem.endsWith(u8, rep.differ[0].generated, "..."));
}

test "judge: a line-ending difference alone (CRLF against LF) is a difference" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = Rig.init();
    defer r.deinit();
    try U.writeAll(r.gen.dir, "a.mojo", "one\ntwo\n");
    try U.writeAll(r.committed.dir, "a.mojo", "one\r\ntwo\r\n");
    const rep = try F.judge(a, r.gen.dir, r.committed.dir);
    try t.expect(!rep.inSync());
    try t.expectEqual(@as(usize, 1), rep.differ.len);
    try t.expectEqual(@as(usize, 1), rep.differ[0].line);
    // The message shows the carriage return, so the two lines do not read alike.
    try t.expectEqualStrings("one\\r", rep.differ[0].committed);
    try t.expectEqualStrings("one", rep.differ[0].generated);
}

test "render: a tab and a carriage return in a quoted line are written out" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = Rig.init();
    defer r.deinit();
    try U.writeAll(r.gen.dir, "a.mojo", "x\ty\n");
    try U.writeAll(r.committed.dir, "a.mojo", "x y\r\n");
    const rep = try F.judge(a, r.gen.dir, r.committed.dir);
    const text = try F.render(a, rep, "l", "d", "cmd");
    try t.expect(std.mem.indexOf(u8, text, "committed: x y\\r\n") != null);
    try t.expect(std.mem.indexOf(u8, text, "generated: x\\ty\n") != null);
}

test "judge: a symbolic link in the committed directory is refused, even to a file with the right bytes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = Rig.init();
    defer r.deinit();
    var other = t.tmpDir(.{ .iterate = true });
    defer other.cleanup();
    try U.writeAll(other.dir, "real.mojo", "same\n");
    try U.writeAll(r.gen.dir, "a.mojo", "same\n");
    const target = try other.dir.realpathAlloc(a, "real.mojo");
    try r.committed.dir.symLink(target, "a.mojo", .{});
    const rep = try F.judge(a, r.gen.dir, r.committed.dir);
    try t.expect(!rep.inSync());
    try t.expectEqual(@as(usize, 1), rep.links.len);
    try t.expectEqualStrings("a.mojo", rep.links[0]);
    const text = try F.render(a, rep, "l", "d", "cmd");
    try t.expect(std.mem.indexOf(u8, text, "not a regular file (a symbolic link?): a.mojo") != null);
}

test "judge: a symbolic link to a directory is refused and not walked into" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = Rig.init();
    defer r.deinit();
    var other = t.tmpDir(.{ .iterate = true });
    defer other.cleanup();
    try U.writeAll(other.dir, "x.mojo", "x\n");
    try U.writeAll(r.gen.dir, "a.mojo", "a\n");
    try U.writeAll(r.committed.dir, "a.mojo", "a\n");
    const target = try other.dir.realpathAlloc(a, ".");
    try r.committed.dir.symLink(target, "_parts", .{ .is_directory = true });
    const rep = try F.judge(a, r.gen.dir, r.committed.dir);
    try t.expectEqual(@as(usize, 1), rep.links.len);
    try t.expectEqualStrings("_parts", rep.links[0]);
}

test "judge: a one-line file whose only difference is the line ending is a difference" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = Rig.init();
    defer r.deinit();
    try U.writeAll(r.gen.dir, "a.mojo", "one\n");
    try U.writeAll(r.committed.dir, "a.mojo", "one\r\n");
    const rep = try F.judge(a, r.gen.dir, r.committed.dir);
    try t.expectEqual(@as(usize, 1), rep.differ.len);
    try t.expectEqualStrings("one\\r", rep.differ[0].committed);
}
