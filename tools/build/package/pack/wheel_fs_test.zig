//! What the command reads from flags and the file system: a directory's files
//! with their modes (a native file 0755, a package file by its exec bit), a
//! symbolic link refused; an output directory's names and its one wheel; and
//! the flag values held against the pyproject, each refused with its reason.

const std = @import("std");
const project = @import("wheel_project.zig");
const fs = @import("wheel_fs.zig");
const fixture = @import("wheel_testing.zig");
const t = std.testing;

fn writeFile(dir: std.fs.Dir, path: []const u8, data: []const u8, mode: std.fs.File.Mode) !void {
    var f = try dir.createFile(path, .{ .mode = mode });
    defer f.close();
    try f.writeAll(data);
    try f.chmod(mode);
}

fn find(files: anytype, path: []const u8) ?usize {
    for (files, 0..) |f, i| if (std.mem.eql(u8, f.path, path)) return i;
    return null;
}

test "a directory's files, at their relative paths, with their modes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("komira/sub");
    try tmp.dir.makePath("empty");
    try writeFile(tmp.dir, "komira/__init__.py", "x = 1\n", 0o644);
    try writeFile(tmp.dir, "komira/sub/tool", "#!", 0o755);
    const root = try tmp.dir.realpathAlloc(a, ".");
    var d = project.Diag{};

    const pkg = try fs.walk(a, &d, root, false);
    try t.expectEqual(@as(usize, 2), pkg.len);
    const init = pkg[find(pkg, "komira/__init__.py").?];
    try t.expectEqualStrings("x = 1\n", init.data);
    try t.expectEqual(@as(u32, 0o644), init.mode);
    try t.expectEqual(@as(u32, 0o755), pkg[find(pkg, "komira/sub/tool").?].mode);

    // Every file of a native directory is a shared library: 0755.
    const native = try fs.walk(a, &d, root, true);
    try t.expectEqual(@as(u32, 0o755), native[find(native, "komira/__init__.py").?].mode);
}

test "a symbolic link, or a directory that is not there, is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "lib.so", "x", 0o755);
    try tmp.dir.symLink("lib.so", "link.so", .{});
    const root = try tmp.dir.realpathAlloc(a, ".");
    var d = project.Diag{};
    try t.expectError(error.Refused, fs.walk(a, &d, root, true));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/link.so: not a regular file or directory (sym_link)", .{root}), d.msg);

    const gone = try std.fmt.allocPrint(a, "{s}/gone", .{root});
    try t.expectError(error.Refused, fs.walk(a, &d, gone, false));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "cannot open {s}: FileNotFound", .{gone}), d.msg);
    try t.expectError(error.Refused, fs.listDir(a, &d, gone));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "cannot open {s}: FileNotFound", .{gone}), d.msg);
}

test "an output directory: its names and its one wheel; none, two, or a subdirectory refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    var d = project.Diag{};

    try writeFile(tmp.dir, "manifest.json", "{}", 0o644);
    try t.expectError(error.Refused, fs.listDir(a, &d, root));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "{s} holds no wheel", .{root}), d.msg);

    try writeFile(tmp.dir, "a.whl", "", 0o644);
    const one = try fs.listDir(a, &d, root);
    try t.expectEqualStrings("a.whl", one.wheel_name);
    try t.expectEqual(@as(usize, 2), one.names.len);

    try writeFile(tmp.dir, "b.whl", "", 0o644);
    try t.expectError(error.Refused, fs.listDir(a, &d, root));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "{s} holds two wheels", .{root}), d.msg);

    try tmp.dir.deleteFile("b.whl");
    try tmp.dir.makePath("sub");
    try t.expectError(error.Refused, fs.listDir(a, &d, root));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/sub: not a regular file", .{root}), d.msg);
}

test "flag values: <name>=<file>, true or false, the distribution's name, the requirements" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = project.Diag{};
    const kv = try fs.named(a, &d, "LICENSE=a/b=c", "--license-file");
    try t.expectEqualStrings("LICENSE", kv[0]);
    try t.expectEqualStrings("a/b=c", kv[1]);
    for ([_][]const u8{ "LICENSE", "=x", "LICENSE=" }) |bad| {
        try t.expectError(error.Refused, fs.named(a, &d, bad, "--license-file"));
        try t.expectEqualStrings(try std.fmt.allocPrint(a, "--license-file `{s}` is not <name>=<file>", .{bad}), d.msg);
    }

    try t.expect(try fs.flagBool(a, &d, "--require-stamped", "true"));
    try t.expect(!try fs.flagBool(a, &d, "--require-stamped", "false"));
    try t.expectError(error.Refused, fs.flagBool(a, &d, "--require-stamped", "yes"));
    try t.expectEqualStrings("--require-stamped is `yes`, not true or false", d.msg);

    const p = try fixture.parsed(a);
    try fs.checkDistribution(a, &d, "komira", p);
    try t.expectError(error.Refused, fs.checkDistribution(a, &d, "komira-ai", p));
    try t.expectEqualStrings("--name is `komira-ai`, but the pyproject's name is `komira`", d.msg);

    try fs.checkRequirements(a, &d, &.{"mojo-compiler==1.0.0"});
    try t.expectError(error.Refused, fs.checkRequirements(a, &d, &.{""}));
    try t.expectEqualStrings("--runtime-requires `` is empty or holds a line break", d.msg);
    try t.expectError(error.Refused, fs.checkRequirements(a, &d, &.{"a\nRequires-Dist: b"}));
}
