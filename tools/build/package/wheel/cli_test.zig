//! The command line and the files it names: flags parsed, an unknown or
//! valueless one refused; `<name>=<value>` split at the first `=`; a file or
//! a directory staged at its path with its mode, a symbolic link refused; and
//! a whole input read from files, the stamp's version in it, the README
//! as the description alone; the command names, another one refused with
//! the usage line.

const std = @import("std");
const diag = @import("native_policy").diag;
const cli = @import("cli.zig");
const wheel = @import("wheel.zig");
const t = std.testing;

test "flags: pairs, an unknown, valueless or repeated one refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const args = try cli.parse(a, &d, &.{ "--name", "komira", "--classifier", "A", "--classifier", "B", "--out", "x" }, &.{"--out"});
    try t.expectEqualStrings("komira", try args.one(a, &d, "--name"));
    try t.expectEqual(@as(usize, 2), (try args.all(a, "--classifier")).len);
    try t.expect((try args.opt(a, &d, "--max-glibcxx")) == null);
    try t.expectError(error.Refused, args.one(a, &d, "--classifier"));
    try t.expectEqualStrings("--classifier is given 2 times", d.msg);
    try t.expectError(error.Refused, args.one(a, &d, "--summary"));
    try t.expectEqualStrings("missing --summary", d.msg);
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
    const kv = try cli.named(a, &d, "Homepage=https://example.com/?a=b", "--project-url");
    try t.expectEqualStrings("Homepage", kv[0]);
    try t.expectEqualStrings("https://example.com/?a=b", kv[1]);
    for ([_][]const u8{ "Homepage", "=x", "x=" }) |bad| {
        try t.expectError(error.Refused, cli.named(a, &d, bad, "--project-url"));
        try t.expectEqualStrings(try std.fmt.allocPrint(a, "--project-url `{s}` is not <name>=<value>", .{bad}), d.msg);
    }
    try t.expect(try cli.flagBool(a, &d, "--require-stamped", "true"));
    try t.expect(!try cli.flagBool(a, &d, "--require-stamped", "false"));
    try t.expectError(error.Refused, cli.flagBool(a, &d, "--require-stamped", "yes"));
    try t.expectEqualStrings("--require-stamped is `yes`, not true or false", d.msg);
}

fn writeFile(dir: std.fs.Dir, path: []const u8, data: []const u8) !void {
    try dir.writeFile(.{ .sub_path = path, .data = data });
}

test "a file or a directory staged at its path with its mode; a link or a missing file refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("lib/lib");
    try tmp.dir.makePath("lib/empty");
    try writeFile(tmp.dir, "lib/libkomira.so", "\x7fELF a");
    try writeFile(tmp.dir, "lib/lib/libowner.so.1", "\x7fELF b");
    try writeFile(tmp.dir, "init.py", "x = 1\n");
    const root = try tmp.dir.realpathAlloc(a, ".");
    var d = diag.Diag{};
    var files = std.ArrayList(wheel.File).empty;
    try cli.stage(a, &d, "komira/__init__.py", try std.fs.path.join(a, &.{ root, "init.py" }), 0o644, &files);
    try cli.stage(a, &d, "komira/_lib", try std.fs.path.join(a, &.{ root, "lib" }), 0o755, &files);
    try t.expectEqual(@as(usize, 3), files.items.len);
    try t.expectEqualStrings("komira/__init__.py", files.items[0].path);
    try t.expectEqualStrings("x = 1\n", files.items[0].data);
    try t.expectEqual(@as(u32, 0o644), files.items[0].mode);
    var seen: usize = 0;
    for (files.items[1..]) |f| {
        try t.expectEqual(@as(u32, 0o755), f.mode);
        if (std.mem.eql(u8, f.path, "komira/_lib/libkomira.so") or std.mem.eql(u8, f.path, "komira/_lib/lib/libowner.so.1")) seen += 1;
    }
    try t.expectEqual(@as(usize, 2), seen);

    try tmp.dir.symLink("libkomira.so", "lib/link.so", .{});
    const lib = try std.fs.path.join(a, &.{ root, "lib" });
    try t.expectError(error.Refused, cli.stage(a, &d, "komira/_lib", lib, 0o755, &files));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/link.so: not a regular file or directory (sym_link)", .{lib}), d.msg);
    const gone = try std.fs.path.join(a, &.{ root, "gone" });
    try t.expectError(error.Refused, cli.stage(a, &d, "x", gone, 0o644, &files));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "cannot stat {s}: FileNotFound", .{gone}), d.msg);
    try t.expectError(error.Refused, cli.readFile(a, &d, gone));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "cannot read {s}: FileNotFound", .{gone}), d.msg);
}

test "a whole input read from flags and files, with the stamp's version" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "README.md", "# k\n");
    try writeFile(tmp.dir, "LICENSE", "lic\n");
    try writeFile(tmp.dir, "init.py", "");
    const root = try tmp.dir.realpathAlloc(a, ".");
    const p = struct {
        fn f(al: std.mem.Allocator, r: []const u8, n: []const u8) ![]const u8 {
            return std.fs.path.join(al, &.{ r, n });
        }
    }.f;
    var d = diag.Diag{};
    const args = try cli.parse(a, &d, &.{
        "--name",               "komira",
        "--summary",            "s",
        "--readme",             try p(a, root, "README.md"),
        "--requires-python",    ">=3.13",
        "--requires-dist",      "pyarrow",
        "--project-url",        "Homepage=https://github.com/komira-ai/komira",
        "--license-expression", "Apache-2.0",
        "--license-file",       try std.fmt.allocPrint(a, "LICENSE={s}", .{try p(a, root, "LICENSE")}),
        "--file",               try std.fmt.allocPrint(a, "komira/__init__.py={s}", .{try p(a, root, "init.py")}),
        "--exec-file",          try std.fmt.allocPrint(a, "komira/x.so={s}", .{try p(a, root, "init.py")}),
        "--tag",                "py3-none-manylinux_2_34_x86_64",
        "--max-glibcxx",        "3.4.30",
        "--external-needed",    "libKGENCompilerRTShared.so",
        "--stamp",              "57",
        "--commit",             "7e57c0de1f2e3d4c5b6a79880a1b2c3d4e5f6071",
        "--timestamp-ms",       "86400000",
    }, &.{});
    const x = try cli.input(a, &d, args);
    try t.expectEqualStrings("0.1.57", x.in.version);
    try t.expect(x.stamp.stamped);
    try t.expectEqualStrings("# k\n", x.in.readme);
    try t.expectEqualStrings("lic\n", x.in.licenses[0].data);
    try t.expectEqualStrings("Homepage", x.in.project_urls[0].label);
    try t.expectEqual(@as(u32, 0o755), x.in.files[1].mode);
    try t.expectEqualStrings("3.4.30", x.in.max_glibcxx.?);
    try t.expect(x.in.max_cxxabi == null);
    try t.expectEqual(@as(usize, 1), x.in.external_needed.len);
}

test "the README is the description as it is, and a readme preface flag is unknown" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "README.md", "# k\n");
    const readme = try std.fs.path.join(a, &.{ try tmp.dir.realpathAlloc(a, "."), "README.md" });
    const base = [_][]const u8{
        "--name",               "komira",
        "--summary",            "s",
        "--readme",             readme,
        "--requires-python",    ">=3.13",
        "--license-expression", "Apache-2.0",
        "--tag",                "py3-none-manylinux_2_34_x86_64",
        "--stamp",              "0",
        "--commit",             "",
        "--timestamp-ms",       "0",
    };
    const args = try cli.parse(a, &d, &base, &.{});
    try t.expectEqualStrings("# k\n", (try cli.input(a, &d, args)).in.readme);
    try t.expectError(error.Refused, cli.parse(a, &d, &(base ++ [_][]const u8{ "--readme-preface", "p" }), &.{}));
    try t.expectEqualStrings("unknown argument --readme-preface", d.msg);
}

test "the commands are write, check, libs and same; another name, runtime-record among them, is refused with the usage line" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    try t.expectEqual(cli.Command.write, try cli.subcommand(a, &d, "write"));
    try t.expectEqual(cli.Command.check, try cli.subcommand(a, &d, "check"));
    try t.expectEqual(cli.Command.libs, try cli.subcommand(a, &d, "libs"));
    try t.expectEqual(cli.Command.same, try cli.subcommand(a, &d, "same"));
    for ([_][]const u8{ "runtime-record", "", "Write", "libs " }) |name| {
        d = diag.Diag{};
        try t.expectError(error.Refused, cli.subcommand(a, &d, name));
        try t.expectEqualStrings("usage: komira_wheel write|check|libs|same --flag value ...", d.msg);
    }
}
