//! The cases of the dist step (meta.zig): the wheel the build made is named as the index will name it, the
//! wheels that cannot be named are refused by defect, and the dist directory holds that one file alone.
const std = @import("std");
const lib = @import("pypi_smoke_lib");
const h = @import("testing.zig");
const meta = lib.meta;
const t = std.testing;

fn parse(a: std.mem.Allocator, why: *[]const u8, spec: h.WheelSpec) !meta.Wheel {
    return meta.parseWheel(a, why, try h.makeWheel(a, spec));
}

test "a wheel with one dist-info, one Name, one Version and one Tag is read and named as the index names it" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";
    const bytes = try h.makeWheel(a, .{});
    const w = try meta.parseWheel(a, &why, bytes);
    try t.expectEqualStrings("komira", w.name);
    try t.expectEqualStrings("0.1.7", w.version);
    try t.expectEqualStrings("py3-none-manylinux_2_34_x86_64", w.tag);
    try t.expectEqualStrings("komira-0.1.7-py3-none-manylinux_2_34_x86_64.whl", w.file_name);
    try t.expectEqualStrings(">=3.13", w.requires_python.?);
    try t.expectEqual(@as(usize, 1), w.requires_dist.len);
    try t.expectEqualStrings("mojo-compiler==1.0.0", w.requires_dist[0]);
    try t.expectEqualStrings(try h.hex(a, bytes), &w.sha256);
    try t.expectEqualSlices(u8, bytes, w.bytes);
}

test "a wheel with no Requires-Python and several Requires-Dist keeps their order" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";
    const w = try parse(a, &why, .{ .requires_python = null, .requires_dist = &.{ "zeta>=1", "alpha==2" } });
    try t.expect(w.requires_python == null);
    try t.expectEqual(@as(usize, 2), w.requires_dist.len);
    try t.expectEqualStrings("zeta>=1", w.requires_dist[0]);
    try t.expectEqualStrings("alpha==2", w.requires_dist[1]);
}

test "a name is normalised by turning each run of dashes, underscores and dots into one underscore and lowercasing" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("a_b_c_d", try meta.normalizeName(a, "A--b.C__d"));
    try t.expectEqualStrings("komira", try meta.normalizeName(a, "komira"));
    var why: []const u8 = "";
    const w = try parse(a, &why, .{ .name = "My.Pkg_-Name", .version = "1.0", .tag = "py3-none-any" });
    try t.expectEqualStrings("My.Pkg_-Name", w.name);
    try t.expectEqualStrings("my_pkg_name-1.0-py3-none-any.whl", w.file_name);
}

test "a wheel with two top-level dist-info directories is refused, naming both" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";
    try t.expectError(error.Refused, parse(a, &why, .{ .with_second_info = true }));
    try t.expectEqualStrings("the wheel has 2 top-level .dist-info directories (komira-0.1.7.dist-info, other-1.0.dist-info); exactly one is wanted", why);
}

test "a wheel with no dist-info directory, or one without METADATA or WHEEL, is refused" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";
    var d: lib.common.Diag = .{};
    const bare = try h.zip.write(a, &d, &.{.{ .name = "komira/__init__.py", .data = "x" }}, .{});
    try t.expectError(error.Refused, meta.parseWheel(a, &why, bare));
    try t.expectEqualStrings("the wheel has no top-level .dist-info directory", why);

    try t.expectError(error.Refused, parse(a, &why, .{ .with_metadata = false }));
    try t.expectEqualStrings("komira-0.1.7.dist-info holds no METADATA", why);

    const no_wheel = try h.zip.write(a, &d, &.{.{ .name = "komira-0.1.7.dist-info/METADATA", .data = "Name: komira\nVersion: 0.1.7\n" }}, .{});
    try t.expectError(error.Refused, meta.parseWheel(a, &why, no_wheel));
    try t.expectEqualStrings("komira-0.1.7.dist-info holds no WHEEL", why);
}

test "a WHEEL with no Tag line is refused" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";
    try t.expectError(error.Refused, parse(a, &why, .{ .tags = &.{} }));
    try t.expectEqualStrings("WHEEL has 0 Tag line(s); exactly one is wanted", why);
}

test "a WHEEL with two Tag lines is refused" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";
    try t.expectError(error.Refused, parse(a, &why, .{ .tags = &.{ "py3-none-any", "py3-none-manylinux_2_34_x86_64" } }));
    try t.expectEqualStrings("WHEEL has 2 Tag line(s); exactly one is wanted", why);
}

test "a METADATA with two Name lines, or no Version line, is refused" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";
    var d: lib.common.Diag = .{};
    const two_names = try h.zip.write(a, &d, &.{
        .{ .name = "komira-0.1.7.dist-info/METADATA", .data = "Name: komira\nName: other\nVersion: 0.1.7\n" },
        .{ .name = "komira-0.1.7.dist-info/WHEEL", .data = "Tag: py3-none-any\n" },
    }, .{});
    try t.expectError(error.Refused, meta.parseWheel(a, &why, two_names));
    try t.expectEqualStrings("METADATA has 2 Name line(s); exactly one is wanted", why);
    const no_version = try h.zip.write(a, &d, &.{
        .{ .name = "komira-0.1.7.dist-info/METADATA", .data = "Name: komira\n" },
        .{ .name = "komira-0.1.7.dist-info/WHEEL", .data = "Tag: py3-none-any\n" },
    }, .{});
    try t.expectError(error.Refused, meta.parseWheel(a, &why, no_version));
    try t.expectEqualStrings("METADATA has 0 Version line(s); exactly one is wanted", why);
}

test "a Requires-Dist after the blank line that ends the METADATA headers is not a requirement" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";
    var d: lib.common.Diag = .{};
    const bytes = try h.zip.write(a, &d, &.{
        .{ .name = "komira-0.1.7.dist-info/METADATA", .data = "Name: komira\nVersion: 0.1.7\n\nRequires-Dist: in-the-description\n" },
        .{ .name = "komira-0.1.7.dist-info/WHEEL", .data = "Tag: py3-none-any\n" },
    }, .{});
    const w = try meta.parseWheel(a, &why, bytes);
    try t.expectEqual(@as(usize, 0), w.requires_dist.len);
}

test "a dist-info directory that METADATA's name and version do not make is refused" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";
    try t.expectError(error.Refused, parse(a, &why, .{ .info = "komira-0.1.8.dist-info" }));
    try t.expectEqualStrings("the .dist-info directory is komira-0.1.8.dist-info; METADATA's Name and Version make it komira-0.1.7.dist-info", why);
}

test "a version or a tag that a file name cannot hold is refused" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";
    try t.expectError(error.Refused, parse(a, &why, .{ .version = "0.1 7" }));
    try t.expectEqualStrings("Version '0.1 7' is empty or has a character a wheel file name cannot hold", why);
    try t.expectError(error.Refused, parse(a, &why, .{ .tag = "py3/none/any" }));
    try t.expectEqualStrings("Tag 'py3/none/any' is empty or has a character a wheel file name cannot hold", why);
}

test "bytes that are not a zip are refused with the zip reader's reason" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";
    try t.expectError(error.Refused, meta.parseWheel(a, &why, "not a zip"));
    try t.expectEqualStrings("not a wheel this tool reads: no end-of-central-directory record in the last 22 bytes (a comment, or not a zip)", why);
}

test "the dist step writes the wheel under its file name into an absent or an empty directory" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var why: []const u8 = "";
    const w = try parse(a, &why, .{});
    try meta.writeDist(a, &why, w, try h.path(a, &tmp, "dist"));
    try t.expectEqualSlices(u8, w.bytes, try h.readAll(a, &tmp, "dist/komira-0.1.7-py3-none-manylinux_2_34_x86_64.whl"));
    try tmp.dir.makePath("empty");
    try meta.writeDist(a, &why, w, try h.path(a, &tmp, "empty"));
    try t.expectEqualSlices(u8, w.bytes, try h.readAll(a, &tmp, "empty/komira-0.1.7-py3-none-manylinux_2_34_x86_64.whl"));
}

test "the dist step refuses an output directory that holds anything" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var why: []const u8 = "";
    const w = try parse(a, &why, .{});
    try tmp.dir.makePath("out");
    try tmp.dir.writeFile(.{ .sub_path = "out/old.whl", .data = "old" });
    const out = try h.path(a, &tmp, "out");
    try t.expectError(error.Refused, meta.writeDist(a, &why, w, out));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "--out {s} is not empty", .{out}), why);
    try t.expectEqualStrings("old", try h.readAll(a, &tmp, "out/old.whl"));
}

fn distWith(a: std.mem.Allocator, tmp: *t.TmpDir, files: []const [2][]const u8) ![]u8 {
    try tmp.dir.makePath("dist");
    for (files) |f| try tmp.dir.writeFile(.{ .sub_path = try std.fmt.allocPrint(a, "dist/{s}", .{f[0]}), .data = f[1] });
    return h.path(a, tmp, "dist");
}

test "a dist directory with the one wheel, named as its metadata says, is read" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try h.makeWheel(a, .{});
    const dir = try distWith(a, &tmp, &.{.{ "komira-0.1.7-py3-none-manylinux_2_34_x86_64.whl", bytes }});
    var why: []const u8 = "";
    const w = try meta.loadDist(a, &why, dir);
    try t.expectEqualStrings("komira-0.1.7-py3-none-manylinux_2_34_x86_64.whl", w.file_name);
    try t.expectEqualSlices(u8, bytes, w.bytes);
}

test "a dist directory with another file beside the wheel, two wheels, none, or a misnamed one is refused" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const bytes = try h.makeWheel(a, .{});
    const good = "komira-0.1.7-py3-none-manylinux_2_34_x86_64.whl";
    var why: []const u8 = "";

    var t1 = t.tmpDir(.{});
    defer t1.cleanup();
    const d1 = try distWith(a, &t1, &.{ .{ good, bytes }, .{ "notes.txt", "x" } });
    try t.expectError(error.Refused, meta.loadDist(a, &why, d1));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "--dist {s} holds notes.txt; one .whl file and nothing else is wanted", .{d1}), why);

    var t2 = t.tmpDir(.{});
    defer t2.cleanup();
    const d2 = try distWith(a, &t2, &.{ .{ good, bytes }, .{ "other-1.0-py3-none-any.whl", bytes } });
    try t.expectError(error.Refused, meta.loadDist(a, &why, d2));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "--dist {s} holds 2 files; exactly one .whl is wanted", .{d2}), why);

    var t3 = t.tmpDir(.{});
    defer t3.cleanup();
    try t3.dir.makePath("dist");
    const d3 = try h.path(a, &t3, "dist");
    try t.expectError(error.Refused, meta.loadDist(a, &why, d3));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "--dist {s} holds 0 files; exactly one .whl is wanted", .{d3}), why);

    var t4 = t.tmpDir(.{});
    defer t4.cleanup();
    const d4 = try distWith(a, &t4, &.{.{ "wrong.whl", bytes }});
    try t.expectError(error.Refused, meta.loadDist(a, &why, d4));
    try t.expectEqualStrings("the file wrong.whl is named komira-0.1.7-py3-none-manylinux_2_34_x86_64.whl by its METADATA and WHEEL", why);

    const missing = try h.path(a, &t4, "no_such_dir");
    try t.expectError(error.Refused, meta.loadDist(a, &why, missing));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "cannot open --dist {s}: FileNotFound", .{missing}), why);
}
