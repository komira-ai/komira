//! Unit tests of python_act's pure parts. Its process behaviour (the unpack,
//! the refusals, the interpreter run) is tests//functional/python_act; the
//! python_dist targets run through it too.
const std = @import("std");
const P = @import("python_act.zig");
const U = @import("act_util");
const t = std.testing;

test "clearSitePackages: every entry of every lib/python3.*/site-packages, hidden entries and other directories kept" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("lib/python3.13/site-packages/pip/_vendor");
    try tmp.dir.makePath("lib/python3.13t/site-packages");
    try tmp.dir.makePath("lib/python3.13/lib-dynload");
    try tmp.dir.makePath("lib/python2.7/site-packages");
    try tmp.dir.makePath("lib/other/site-packages");
    try U.writeAll(tmp.dir, "lib/python3.13/site-packages/pip/_vendor/x.py", "x");
    try U.writeAll(tmp.dir, "lib/python3.13/site-packages/README.txt", "r");
    try U.writeAll(tmp.dir, "lib/python3.13/site-packages/.keep", "k");
    try U.writeAll(tmp.dir, "lib/python3.13t/site-packages/setuptools.py", "s");
    try U.writeAll(tmp.dir, "lib/python3.13/lib-dynload/mod.so", "m");
    try U.writeAll(tmp.dir, "lib/python2.7/site-packages/two.py", "2");
    try U.writeAll(tmp.dir, "lib/other/site-packages/o.py", "o");
    try tmp.dir.symLink("README.txt", "lib/python3.13/site-packages/link", .{});
    try P.clearSitePackages(a, tmp.dir);
    try t.expectError(error.FileNotFound, tmp.dir.statFile("lib/python3.13/site-packages/pip"));
    try t.expectError(error.FileNotFound, tmp.dir.statFile("lib/python3.13/site-packages/README.txt"));
    try t.expectError(error.FileNotFound, tmp.dir.statFile("lib/python3.13t/site-packages/setuptools.py"));
    var buf: [64]u8 = undefined;
    try t.expectError(error.FileNotFound, tmp.dir.readLink("lib/python3.13/site-packages/link", &buf));
    // kept
    _ = try tmp.dir.statFile("lib/python3.13/site-packages/.keep");
    _ = try tmp.dir.statFile("lib/python3.13/lib-dynload/mod.so");
    _ = try tmp.dir.statFile("lib/python2.7/site-packages/two.py");
    _ = try tmp.dir.statFile("lib/other/site-packages/o.py");
    // no lib at all is fine
    var empty = t.tmpDir(.{ .iterate = true });
    defer empty.cleanup();
    try P.clearSitePackages(a, empty.dir);
}

test "version_program prints the version and t for a free-threaded build" {
    try t.expect(std.mem.indexOf(u8, P.version_program, "Py_GIL_DISABLED") != null);
    try t.expect(std.mem.indexOf(u8, P.version_program, "sys.version_info[:3]") != null);
}
