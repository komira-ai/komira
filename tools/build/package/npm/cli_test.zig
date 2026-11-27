//! The command line and the files it names: flags parsed, an unknown,
//! valueless or repeated one refused; `<name>=<value>` split at the first
//! `=`; a file or a directory staged at its path, a symbolic link or a
//! missing file refused; a whole input read from flags and files with the
//! stamp's version, for a package with no platform, for a linux one and
//! with optional dependencies; a platform given by halves refused; and the
//! commands, another one refused with the usage line.

const std = @import("std");
const diag = @import("native_policy").diag;
const cli = @import("cli.zig");
const npm = @import("npm.zig");
const t = std.testing;
const Alloc = std.mem.Allocator;

test "flags: pairs, an unknown, valueless or repeated one refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const args = try cli.parse(a, &d, &.{ "--name", "komira", "--file", "A=a", "--file", "B=b", "--out", "x" }, &.{"--out"});
    try t.expectEqualStrings("komira", try args.one(a, &d, "--name"));
    try t.expectEqual(@as(usize, 2), (try args.all(a, "--file")).len);
    try t.expect((try args.opt(a, &d, "--glibc")) == null);
    try t.expectError(error.Refused, args.one(a, &d, "--file"));
    try t.expectEqualStrings("--file is given 2 times", d.msg);
    try t.expectError(error.Refused, args.one(a, &d, "--manifest"));
    try t.expectEqualStrings("missing --manifest", d.msg);
    try t.expectError(error.Refused, cli.parse(a, &d, &.{ "--out", "x" }, &.{}));
    try t.expectEqualStrings("unknown argument --out", d.msg);
    try t.expectError(error.Refused, cli.parse(a, &d, &.{"--name"}, &.{}));
    try t.expectEqualStrings("--name needs a value", d.msg);
}

test "<name>=<value> and true or false" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const kv = try cli.named(a, &d, "native=buck-out/a=b", "--file");
    try t.expectEqualStrings("native", kv[0]);
    try t.expectEqualStrings("buck-out/a=b", kv[1]);
    for ([_][]const u8{ "native", "=x", "x=" }) |bad| {
        try t.expectError(error.Refused, cli.named(a, &d, bad, "--file"));
        try t.expectEqualStrings(try std.fmt.allocPrint(a, "--file `{s}` is not <name>=<value>", .{bad}), d.msg);
    }
    try t.expect(try cli.flagBool(a, &d, "--require-stamped", "true"));
    try t.expect(!try cli.flagBool(a, &d, "--require-stamped", "false"));
    try t.expectError(error.Refused, cli.flagBool(a, &d, "--require-stamped", "1"));
    try t.expectEqualStrings("--require-stamped is `1`, not true or false", d.msg);
}

fn writeFile(dir: std.fs.Dir, path: []const u8, data: []const u8) !void {
    try dir.writeFile(.{ .sub_path = path, .data = data });
}

fn lessFile(_: void, x: npm.File, y: npm.File) bool {
    return std.mem.lessThan(u8, x.path, y.path);
}

test "a file or a directory staged at its path; a link or a missing file refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("dist/lib");
    try tmp.dir.makePath("dist/empty");
    try writeFile(tmp.dir, "dist/index.js", "a");
    try writeFile(tmp.dir, "dist/lib/x.js", "b");
    try writeFile(tmp.dir, "NOTICE", "n\n");
    const root = try tmp.dir.realpathAlloc(a, ".");
    var d = diag.Diag{};
    var files = std.ArrayList(npm.File).empty;
    try cli.stage(a, &d, "NOTICE", try std.fs.path.join(a, &.{ root, "NOTICE" }), &files);
    try cli.stage(a, &d, "dist", try std.fs.path.join(a, &.{ root, "dist" }), &files);
    std.mem.sort(npm.File, files.items, {}, lessFile);
    try t.expectEqual(@as(usize, 3), files.items.len);
    try t.expectEqualStrings("NOTICE", files.items[0].path);
    try t.expectEqualStrings("n\n", files.items[0].data);
    try t.expectEqualStrings("dist/index.js", files.items[1].path);
    try t.expectEqualStrings("dist/lib/x.js", files.items[2].path);
    try t.expectEqualStrings("b", files.items[2].data);

    try tmp.dir.symLink("index.js", "dist/link.js", .{});
    const dist = try std.fs.path.join(a, &.{ root, "dist" });
    try t.expectError(error.Refused, cli.stage(a, &d, "dist", dist, &files));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/link.js: not a regular file or directory (sym_link)", .{dist}), d.msg);
    const gone = try std.fs.path.join(a, &.{ root, "gone" });
    try t.expectError(error.Refused, cli.stage(a, &d, "x", gone, &files));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "cannot stat {s}: FileNotFound", .{gone}), d.msg);
    try t.expectError(error.Refused, cli.readFile(a, &d, gone));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "cannot read {s}: FileNotFound", .{gone}), d.msg);
}

test "a whole input read from flags and files, with the stamp's version, with no platform, for linux and with optional dependencies" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "package.json", "{}\n");
    try writeFile(tmp.dir, "NOTICE", "n\n");
    const root = try tmp.dir.realpathAlloc(a, ".");
    const manifest = try std.fs.path.join(a, &.{ root, "package.json" });
    const notice = try std.fmt.allocPrint(a, "NOTICE={s}", .{try std.fs.path.join(a, &.{ root, "NOTICE" })});
    var d = diag.Diag{};
    const base = [_][]const u8{
        "--name",         "@komira-ai/komira",
        "--manifest",     manifest,
        "--license",      "Apache-2.0",
        "--file",         notice,
        "--stamp",        "57",
        "--commit",       "7e57c0de1f2e3d4c5b6a79880a1b2c3d4e5f6071",
        "--timestamp-ms", "86400000",
    };
    const in = try cli.input(a, &d, try cli.parse(a, &d, &base, &.{}));
    try t.expectEqualStrings("0.1.57", in.version);
    try t.expect(in.stamped);
    try t.expectEqualStrings("{}\n", in.manifest);
    try t.expectEqualStrings("NOTICE", in.files[0].path);
    try t.expect(in.glibc == null and in.macos == null and in.platform.os == null);

    const linux = base ++ [_][]const u8{ "--os", "linux", "--cpu", "x64", "--libc", "glibc", "--glibc", "2.35", "--arch", "x86_64", "--max-glibcxx", "3.4.30" };
    const l = try cli.input(a, &d, try cli.parse(a, &d, &linux, &.{}));
    try t.expectEqualStrings("glibc", l.platform.libc.?);
    try t.expectEqualStrings("2.35", l.glibc.?);
    try t.expectEqualStrings("3.4.30", l.max_glibcxx.?);
    try t.expect(l.max_cxxabi == null);
    try t.expectEqual(@as(usize, 0), l.optional.len);

    // The optional dependencies the package names, in the order given.
    const with_optional = base ++ [_][]const u8{ "--optional-dependency", "@komira-ai/komira-linux-x64-gnu", "--optional-dependency", "@komira-ai/komira-darwin-arm64" };
    const m = try cli.input(a, &d, try cli.parse(a, &d, &with_optional, &.{}));
    try t.expectEqual(@as(usize, 2), m.optional.len);
    try t.expectEqualStrings("@komira-ai/komira-linux-x64-gnu", m.optional[0]);
    try t.expectEqualStrings("@komira-ai/komira-darwin-arm64", m.optional[1]);

    const dev = [_][]const u8{
        "--name",         "@komira-ai/komira",
        "--manifest",     manifest,
        "--license",      "Apache-2.0",
        "--stamp",        "0",
        "--commit",       "",
        "--timestamp-ms", "0",
    };
    const u = try cli.input(a, &d, try cli.parse(a, &d, &dev, &.{}));
    try t.expectEqualStrings("0.0.0", u.version);
    try t.expect(!u.stamped);
    try t.expectEqual(@as(usize, 0), u.files.len);
}

test "a platform given by halves is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const base = [_][]const u8{ "--stamp", "0", "--commit", "", "--timestamp-ms", "0" };
    const both = "--glibc and --macos are both given: a package is for one platform";
    const pair = "--glibc and --arch go together: the floor and the machine of a Linux package";
    const named_ = "--os and --cpu are given exactly when --glibc or --macos is: a platform package names its platform to npm and to the native policy";
    const cases = [_]struct { args: []const []const u8, msg: []const u8 }{
        .{ .args = &.{ "--glibc", "2.35", "--macos", "11.0", "--arch", "x86_64", "--os", "linux", "--cpu", "x64" }, .msg = both },
        .{ .args = &.{ "--glibc", "2.35", "--os", "linux", "--cpu", "x64" }, .msg = pair },
        .{ .args = &.{ "--arch", "x86_64" }, .msg = pair },
        .{ .args = &.{ "--glibc", "2.35", "--arch", "x86_64", "--os", "linux" }, .msg = named_ },
        .{ .args = &.{ "--macos", "11.0" }, .msg = named_ },
        .{ .args = &.{ "--os", "linux", "--cpu", "x64" }, .msg = named_ },
        .{ .args = &.{ "--libc", "glibc" }, .msg = named_ },
    };
    for (cases) |c| {
        const argv = try std.mem.concat(a, []const u8, &.{ &base, c.args });
        try t.expectError(error.Refused, cli.input(a, &d, try cli.parse(a, &d, argv, &.{})));
        try t.expectEqualStrings(c.msg, d.msg);
    }
}

test "the commands are write and check; another name is refused with the usage line" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    try t.expectEqual(cli.Command.write, try cli.subcommand(a, &d, "write"));
    try t.expectEqual(cli.Command.check, try cli.subcommand(a, &d, "check"));
    for ([_][]const u8{ "pack", "", "Write", "check " }) |name| {
        d = diag.Diag{};
        try t.expectError(error.Refused, cli.subcommand(a, &d, name));
        try t.expectEqualStrings("usage: komira_npm write|check --flag value ...", d.msg);
    }
}
