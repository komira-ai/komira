const std = @import("std");
const layout = @import("layout.zig");
const sri = @import("sri.zig");
const tartest = @import("tartest.zig");

const Pkg = struct {
    path: []const u8,
    name: []const u8,
    version: []const u8,
    /// More members of the lockfile entry, each starting with a comma.
    extra: []const u8 = "",
    files: []const tartest.Entry = &.{},
    /// The tarball's bytes when they are not the ones the integrity is of.
    other_bytes: ?[]const u8 = null,
    no_tarball: bool = false,
    /// The pinned lock's sri512 when it is not the lockfile's.
    pinned: ?[]const u8 = null,
    no_lock_entry_integrity: bool = false,
};

const Result = struct {
    failed: bool,
    msg: []const u8,
    tmp: std.testing.TmpDir,
    out: std.fs.Dir,

    fn deinit(r: *Result) void {
        r.out.close();
        r.tmp.cleanup();
    }
};

fn lay(a: std.mem.Allocator, pkgs: []const Pkg) !Result {
    var tmp = std.testing.tmpDir(.{});
    const base = try tmp.dir.realpathAlloc(a, ".");
    var lock = std.ArrayList(u8).empty;
    try lock.appendSlice(a, "{\"lockfileVersion\":3,\"packages\":{\"\":{\"name\":\"root\"}");
    var spec = layout.Spec{
        .lockfile = "",
        .tarballs = std.StringHashMap([]const u8).init(a),
        .sri512 = std.StringHashMap([]const u8).init(a),
    };
    for (pkgs, 0..) |p, i| {
        const good = try tartest.tgz(a, p.name, p.version, p.files);
        const integrity = try sri.of(a, good);
        const key = try std.fmt.allocPrint(a, "{s}@{s}", .{ p.name, p.version });
        const integ_json = if (p.no_lock_entry_integrity) "" else try std.fmt.allocPrint(a, ",\"integrity\":\"{s}\"", .{integrity});
        try lock.writer(a).print(",\"{s}\":{{\"version\":\"{s}\"{s}{s}", .{ p.path, p.version, integ_json, p.extra });
        try lock.appendSlice(a, "}");
        if (std.mem.indexOf(u8, p.extra, "\"name\"") == null and !std.mem.endsWith(u8, p.path, p.name)) {
            // an alias or a path whose last segment is not the name needs "name"
            return error.TestFixture;
        }
        if (!p.no_tarball) {
            const file = try std.fmt.allocPrint(a, "t{d}.tgz", .{i});
            try tmp.dir.writeFile(.{ .sub_path = file, .data = p.other_bytes orelse good });
            try spec.tarballs.put(key, try std.fs.path.join(a, &.{ base, file }));
        }
        try spec.sri512.put(key, p.pinned orelse integrity);
    }
    try lock.appendSlice(a, "}}");
    spec.lockfile = lock.items;
    try tmp.dir.makePath("out");
    const out = try tmp.dir.openDir("out", .{ .iterate = true });
    const out_path = try std.fs.path.join(a, &.{ base, "out" });
    var msg = std.ArrayList(u8).empty;
    var failed = false;
    layout.assemble(a, spec, out, out_path, msg.writer(a)) catch |e| switch (e) {
        error.Failed => failed = true,
        else => return e,
    };
    return .{ .failed = failed, .msg = msg.items, .tmp = tmp, .out = out };
}

fn expectMsg(r: Result, needle: []const u8) !void {
    try std.testing.expect(r.failed);
    if (std.mem.indexOf(u8, r.msg, needle) == null) {
        std.debug.print("message:\n{s}\nwant: {s}\n", .{ r.msg, needle });
        return error.TestExpectedMessage;
    }
}

fn read(a: std.mem.Allocator, r: *Result, path: []const u8) ![]u8 {
    return r.out.readFileAlloc(a, path, 1 << 20);
}

test "nested, hoisted, scoped and aliased packages land at their lockfile paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = try lay(a, &.{
        .{ .path = "node_modules/fx-a", .name = "fx-a", .version = "1.0.0", .files = &.{.{ .name = "package/index.js", .data = "a1" }} },
        .{ .path = "node_modules/fx-a/node_modules/fx-b", .name = "fx-b", .version = "2.0.0", .files = &.{.{ .name = "package/index.js", .data = "b2" }} },
        .{ .path = "node_modules/fx-b", .name = "fx-b", .version = "1.0.0", .files = &.{.{ .name = "package/index.js", .data = "b1" }} },
        .{ .path = "node_modules/@fx/scoped", .name = "@fx/scoped", .version = "3.0.0", .files = &.{.{ .name = "package/index.js", .data = "s3" }} },
        .{ .path = "node_modules/alias-b", .name = "fx-b", .version = "1.0.0", .extra = ",\"name\":\"fx-b\"", .files = &.{.{ .name = "package/index.js", .data = "b1" }} },
    });
    defer r.deinit();
    try std.testing.expect(!r.failed);
    try std.testing.expectEqualStrings("a1", try read(a, &r, "fx-a/index.js"));
    try std.testing.expectEqualStrings("b2", try read(a, &r, "fx-a/node_modules/fx-b/index.js"));
    try std.testing.expectEqualStrings("b1", try read(a, &r, "fx-b/index.js"));
    try std.testing.expectEqualStrings("s3", try read(a, &r, "@fx/scoped/index.js"));
    try std.testing.expectEqualStrings("b1", try read(a, &r, "alias-b/index.js"));
    const report = try read(a, &r, ".komira-node-modules.json");
    try std.testing.expect(std.mem.indexOf(u8, report, "\"installed\": 5") != null);
}

test "bin: a relative link in the node_modules that holds the package, to an executable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = try lay(a, &.{
        .{ .path = "node_modules/tool", .name = "tool", .version = "1.0.0", .extra = ",\"bin\":{\"tool\":\"./bin/tool.js\"}", .files = &.{.{ .name = "package/bin/tool.js", .mode = 0o644, .data = "x" }} },
        .{ .path = "node_modules/tool/node_modules/inner", .name = "inner", .version = "1.0.0", .extra = ",\"bin\":\"cli.js\"", .files = &.{.{ .name = "package/cli.js", .data = "y" }} },
        .{ .path = "node_modules/@s/scoped", .name = "@s/scoped", .version = "1.0.0", .extra = ",\"bin\":\"cli.js\"", .files = &.{.{ .name = "package/cli.js", .data = "z" }} },
    });
    defer r.deinit();
    try std.testing.expect(!r.failed);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("../tool/bin/tool.js", try r.out.readLink(".bin/tool", &buf));
    try std.testing.expectEqualStrings("../inner/cli.js", try r.out.readLink("tool/node_modules/.bin/inner", &buf));
    try std.testing.expectEqualStrings("../@s/scoped/cli.js", try r.out.readLink(".bin/scoped", &buf));
    const st = try r.out.statFile(".bin/tool");
    try std.testing.expect(st.mode & 0o111 != 0);
}

test "bin: a name two packages want goes to the shallowest, then the first by path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = try lay(a, &.{
        .{ .path = "node_modules/b", .name = "b", .version = "1.0.0", .extra = ",\"bin\":{\"x\":\"x.js\"}", .files = &.{.{ .name = "package/x.js", .data = "b" }} },
        .{ .path = "node_modules/a", .name = "a", .version = "1.0.0", .extra = ",\"bin\":{\"x\":\"x.js\"}", .files = &.{.{ .name = "package/x.js", .data = "a" }} },
    });
    defer r.deinit();
    try std.testing.expect(!r.failed);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("../a/x.js", try r.out.readLink(".bin/x", &buf));
}

test "an optional package for another os is skipped and reported, a required one fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = try lay(a, &.{
        .{ .path = "node_modules/mac", .name = "mac", .version = "1.0.0", .extra = ",\"optional\":true,\"os\":[\"darwin\"]" },
        .{ .path = "node_modules/lin", .name = "lin", .version = "1.0.0", .extra = ",\"os\":[\"linux\"],\"cpu\":[\"x64\"],\"libc\":[\"glibc\"]" },
        .{ .path = "node_modules/musl", .name = "musl", .version = "1.0.0", .extra = ",\"optional\":true,\"libc\":[\"musl\"]" },
    });
    defer r.deinit();
    try std.testing.expect(!r.failed);
    try std.testing.expectError(error.FileNotFound, r.out.statFile("mac"));
    try std.testing.expectError(error.FileNotFound, r.out.statFile("musl"));
    _ = try r.out.statFile("lin/package.json");
    const report = try read(a, &r, ".komira-node-modules.json");
    try std.testing.expect(std.mem.indexOf(u8, report, "node_modules/mac mac@1.0.0: optional, os [\\\"darwin\\\"] excludes linux") != null);

    var r2 = try lay(a, &.{.{ .path = "node_modules/mac", .name = "mac", .version = "1.0.0", .extra = ",\"os\":[\"darwin\"]" }});
    defer r2.deinit();
    try expectMsg(r2, "needs os [\"darwin\"] and is not optional");
}

test "a package with an install script is installed, the script is listed and nothing runs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = try lay(a, &.{
        .{ .path = "node_modules/native", .name = "native", .version = "1.0.0", .extra = ",\"hasInstallScript\":true", .files = &.{.{ .name = "package/install.js", .data = "throw 1" }} },
    });
    defer r.deinit();
    try std.testing.expect(!r.failed);
    const report = try read(a, &r, ".komira-node-modules.json");
    try std.testing.expect(std.mem.indexOf(u8, report, "\"node_modules/native native@1.0.0\"") != null);
}

test "bundled: present in the parent's tarball is fine, absent is an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = try lay(a, &.{
        .{ .path = "node_modules/host", .name = "host", .version = "1.0.0", .files = &.{.{ .name = "package/node_modules/inner/package.json", .data = "{\"name\":\"inner\",\"version\":\"1.0.0\"}" }} },
        .{ .path = "node_modules/host/node_modules/inner", .name = "inner", .version = "1.0.0", .extra = ",\"inBundle\":true", .no_tarball = true, .no_lock_entry_integrity = true },
    });
    defer r.deinit();
    try std.testing.expect(!r.failed);
    _ = try r.out.statFile("host/node_modules/inner/package.json");

    var r2 = try lay(a, &.{
        .{ .path = "node_modules/host", .name = "host", .version = "1.0.0" },
        .{ .path = "node_modules/host/node_modules/inner", .name = "inner", .version = "1.0.0", .extra = ",\"inBundle\":true", .no_tarball = true, .no_lock_entry_integrity = true },
    });
    defer r2.deinit();
    try expectMsg(r2, "is bundled but its parent's tarball holds no node_modules/host/node_modules/inner/package.json");
}

test "a lockfile package with no pinned tarball names the package" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = try lay(a, &.{.{ .path = "node_modules/x", .name = "x", .version = "1.0.0", .no_tarball = true }});
    defer r.deinit();
    try expectMsg(r, "x@1.0.0 (node_modules/x) has no pinned tarball");
}

test "the pinned lock's integrity must be the lockfile's" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const other = "sha512-" ++ "Q" ** 86 ++ "==";
    var r = try lay(a, &.{.{ .path = "node_modules/x", .name = "x", .version = "1.0.0", .pinned = other }});
    defer r.deinit();
    try expectMsg(r, "x@1.0.0: the lockfile says sha512-");
    try expectMsg(r, "the pinned lock says " ++ other);
}

test "a tarball whose bytes are not the lockfile's integrity is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const other = try tartest.tgz(a, "x", "1.0.0", &.{.{ .name = "package/extra.js", .data = "tampered" }});
    var r = try lay(a, &.{.{ .path = "node_modules/x", .name = "x", .version = "1.0.0", .other_bytes = other }});
    defer r.deinit();
    try expectMsg(r, "x@1.0.0: the tarball is sha512-");
    try std.testing.expectError(error.FileNotFound, r.out.statFile("x/extra.js"));
}

test "a package.json of another name or version is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The tarball of y 2.0.0 under x 1.0.0's entry, with the integrity of its own bytes.
    const y = try tartest.tgz(a, "y", "2.0.0", &.{});
    var tmp_pkgs = [_]Pkg{.{ .path = "node_modules/x", .name = "x", .version = "1.0.0", .other_bytes = y, .pinned = null }};
    var r = try lay(a, &tmp_pkgs);
    defer r.deinit();
    // The bytes differ from x's own tarball, so this is refused by the integrity first;
    // the name check is reached with matching integrity (below).
    try expectMsg(r, "the tarball is sha512-");

    var r2 = try layWithBytes(a, "node_modules/x", "x", "1.0.0", y);
    defer r2.deinit();
    try expectMsg(r2, "x@1.0.0: its package.json says y@2.0.0");
    var r3 = try layWithBytes(a, "node_modules/x", "x", "1.0.0", try tartest.tgz(a, "x", "1.0.1", &.{}));
    defer r3.deinit();
    try expectMsg(r3, "x@1.0.0: its package.json says x@1.0.1");
}

/// A lockfile entry whose integrity is that of `bytes`.
fn layWithBytes(a: std.mem.Allocator, path: []const u8, name: []const u8, version: []const u8, bytes: []const u8) !Result {
    var tmp = std.testing.tmpDir(.{});
    const base = try tmp.dir.realpathAlloc(a, ".");
    const integrity = try sri.of(a, bytes);
    const key = try std.fmt.allocPrint(a, "{s}@{s}", .{ name, version });
    var spec = layout.Spec{
        .lockfile = try std.fmt.allocPrint(a, "{{\"lockfileVersion\":3,\"packages\":{{\"{s}\":{{\"version\":\"{s}\",\"integrity\":\"{s}\"}}}}}}", .{ path, version, integrity }),
        .tarballs = std.StringHashMap([]const u8).init(a),
        .sri512 = std.StringHashMap([]const u8).init(a),
    };
    try tmp.dir.writeFile(.{ .sub_path = "t.tgz", .data = bytes });
    try spec.tarballs.put(key, try std.fs.path.join(a, &.{ base, "t.tgz" }));
    try spec.sri512.put(key, integrity);
    try tmp.dir.makePath("out");
    const out = try tmp.dir.openDir("out", .{ .iterate = true });
    var msg = std.ArrayList(u8).empty;
    var failed = false;
    layout.assemble(a, spec, out, try std.fs.path.join(a, &.{ base, "out" }), msg.writer(a)) catch |e| switch (e) {
        error.Failed => failed = true,
        else => return e,
    };
    return .{ .failed = failed, .msg = msg.items, .tmp = tmp, .out = out };
}

test "a tarball entry that leaves the package fails that package" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = try lay(a, &.{.{ .path = "node_modules/x", .name = "x", .version = "1.0.0", .files = &.{.{ .name = "package/../../escape.txt", .data = "x" }} }});
    defer r.deinit();
    try expectMsg(r, "x@1.0.0: PathEscapes");
    try std.testing.expectError(error.FileNotFound, r.tmp.dir.statFile("escape.txt"));
}

test "a lockfile that is not version 3, and workspace entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out = try tmp.dir.makeOpenPath("out", .{});
    defer out.close();
    var msg = std.ArrayList(u8).empty;
    const spec = layout.Spec{ .lockfile = "{\"lockfileVersion\":2,\"packages\":{}}", .tarballs = std.StringHashMap([]const u8).init(a), .sri512 = std.StringHashMap([]const u8).init(a) };
    try std.testing.expectError(error.Failed, layout.assemble(a, spec, out, "/x", msg.writer(a)));
    try std.testing.expect(std.mem.indexOf(u8, msg.items, "not a lockfileVersion 3") != null);

    const ws = layout.Spec{
        .lockfile = "{\"lockfileVersion\":3,\"packages\":{\"\":{},\"packages/w\":{\"version\":\"1.0.0\"},\"node_modules/w\":{\"resolved\":\"packages/w\",\"link\":true}}}",
        .tarballs = std.StringHashMap([]const u8).init(a),
        .sri512 = std.StringHashMap([]const u8).init(a),
    };
    var msg2 = std.ArrayList(u8).empty;
    try layout.assemble(a, ws, out, "/x", msg2.writer(a));
}
