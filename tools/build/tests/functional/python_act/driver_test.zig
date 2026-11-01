//! The process behaviour of `python_act dist` (tools/build/python_act/python_act.zig)
//! over archives built in memory and a stand-in interpreter (fake.zig).
const std = @import("std");
const kit = @import("driver_kit");
const tt = @import("node_tartest");
const t = std.testing;
const has = kit.has;

fn newCtx(name: []const u8) !kit.Ctx {
    return kit.Ctx.init(name, "PYTHON_ACT");
}

fn entries(fake: []const u8, prints: []const u8, exe_mode: u32) [11]tt.Entry {
    return .{
        .{ .name = "python/", .kind = '5', .mode = 0o755 },
        .{ .name = "python/bin/python3.13", .mode = exe_mode, .data = fake },
        .{ .name = "python/bin/python3", .kind = '2', .link = "python3.13" },
        .{ .name = "python/PRINTS", .mode = 0o644, .data = prints },
        .{ .name = "python/lib/python3.13/os.py", .mode = 0o644, .data = "OS" },
        .{ .name = "python/lib/python3.13/lib-dynload/m.so", .mode = 0o755, .data = "M" },
        .{ .name = "python/lib/python3.13/site-packages/pip/__init__.py", .mode = 0o644, .data = "PIP" },
        .{ .name = "python/lib/python3.13/site-packages/README.txt", .mode = 0o644, .data = "R" },
        .{ .name = "python/lib/libpython3.13.so", .mode = 0o755, .data = "LIB" },
        .{ .name = "python/share/man/python3.1", .mode = 0o644, .data = "MAN" },
        .{ .name = "other/ignored", .mode = 0o644, .data = "X" },
    };
}

fn tgz(c: *kit.Ctx, es: []const tt.Entry) ![]u8 {
    return tt.gzip(c.alloc(), try tt.tar(c.alloc(), es));
}

fn fakeBytes(c: *kit.Ctx) ![]u8 {
    return std.fs.cwd().readFileAlloc(c.alloc(), try c.env("FAKE"), 1 << 26);
}

test "dist: the whole python/ tree with site-packages emptied; the interpreter runs as -I -S -c and prints the pinned version" {
    var c = try newCtx("dist_ok");
    defer c.deinit();
    try c.write("a.tgz", try tgz(&c, &entries(try fakeBytes(&c), "3.13.1\n", 0o755)), 0o644);
    const r = try c.run(&.{ "dist", "--archive", "a.tgz", "--out", "out", "--exe", "bin/python3.13", "--version", "3.13.1" }, &.{});
    if (r.code != 0) std.debug.print("[python_act stderr] {s}\n", .{r.stderr});
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqual(@as(std.fs.File.Mode, 0o755), try c.mode("out/bin/python3.13"));
    try t.expectEqualStrings("OS", try c.read("out/lib/python3.13/os.py"));
    try t.expectEqualStrings("M", try c.read("out/lib/python3.13/lib-dynload/m.so"));
    try t.expectEqualStrings("LIB", try c.read("out/lib/libpython3.13.so"));
    try t.expectEqualStrings("MAN", try c.read("out/share/man/python3.1"));
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("python3.13", try std.fs.cwd().readLink(try c.path("out/bin/python3"), &buf));
    // pip is gone, the directory stays, and the other top directory was never read
    try t.expect(c.exists("out/lib/python3.13/site-packages"));
    try t.expect(!c.exists("out/lib/python3.13/site-packages/pip"));
    try t.expect(!c.exists("out/lib/python3.13/site-packages/README.txt"));
    try t.expect(!c.exists("out/ignored"));
    try t.expect(!c.exists("ignored"));
}

test "dist: a free-threaded interpreter prints t; a pin without it is refused, and each way the archive is wrong, in words, exit 2" {
    var c = try newCtx("dist_bad");
    defer c.deinit();
    const fake = try fakeBytes(&c);
    // the build says 3.13.1t
    try c.write("a.tgz", try tgz(&c, &entries(fake, "3.13.1t\n", 0o755)), 0o644);
    const ok = try c.run(&.{ "dist", "--archive", "a.tgz", "--out", "o1", "--exe", "bin/python3.13", "--version", "3.13.1t" }, &.{});
    try t.expectEqual(@as(u8, 0), ok.code);
    const r1 = try c.run(&.{ "dist", "--archive", "a.tgz", "--out", "o2", "--exe", "bin/python3.13", "--version", "3.13.1" }, &.{});
    try t.expectEqual(@as(u8, 2), r1.code);
    try t.expect(has(r1.stderr, "python_dist: the interpreter in a.tgz is 3.13.1t, the pin says 3.13.1\n"));
    // an archive without the interpreter, one whose is not executable, one that is no program
    const r2 = try c.run(&.{ "dist", "--archive", "a.tgz", "--out", "o3", "--exe", "bin/python3.14", "--version", "3.14.0" }, &.{});
    try t.expectEqual(@as(u8, 2), r2.code);
    try t.expect(has(r2.stderr, "python_dist: a.tgz holds no python/bin/python3.14\n"));
    try c.write("b.tgz", try tgz(&c, &entries(fake, "3.13.1\n", 0o644)), 0o644);
    const r3 = try c.run(&.{ "dist", "--archive", "b.tgz", "--out", "o4", "--exe", "bin/python3.13", "--version", "3.13.1" }, &.{});
    try t.expectEqual(@as(u8, 2), r3.code);
    try t.expect(has(r3.stderr, "python_dist: b.tgz holds no python/bin/python3.13\n"));
    try c.write("c.tgz", try tgz(&c, &entries("not a program\n", "3.13.1\n", 0o755)), 0o644);
    const r4 = try c.run(&.{ "dist", "--archive", "c.tgz", "--out", "o5", "--exe", "bin/python3.13", "--version", "3.13.1" }, &.{});
    try t.expectEqual(@as(u8, 2), r4.code);
    try t.expect(has(r4.stderr, "python_dist: o5/bin/python3.13 does not run\n"));
    // an archive whose top directory is not python/
    var other = entries(fake, "3.13.1\n", 0o755);
    for (&other) |*e| {
        if (std.mem.startsWith(u8, e.name, "python/")) e.name = try std.fmt.allocPrint(c.alloc(), "py{s}", .{e.name[6..]});
    }
    try c.write("d.tgz", try tgz(&c, &other), 0o644);
    const r5 = try c.run(&.{ "dist", "--archive", "d.tgz", "--out", "o6", "--exe", "bin/python3.13", "--version", "3.13.1" }, &.{});
    try t.expectEqual(@as(u8, 2), r5.code);
    try t.expect(has(r5.stderr, "holds no python/bin/python3.13"));
    try t.expectEqual(@as(u8, 2), (try c.run(&.{ "dist", "--archive", "a.tgz" }, &.{})).code);
    try t.expectEqual(@as(u8, 2), (try c.run(&.{}, &.{})).code);
    try t.expectEqual(@as(u8, 2), (try c.run(&.{"frobnicate"}, &.{})).code);
}
