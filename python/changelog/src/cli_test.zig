//! The cases of the command line (cli.zig): `assemble` and `description` over a root directory write the file
//! and exit 0; an input that is refused or cannot be read exits 1 with the reason on stderr and writes nothing;
//! a usage error exits 2 and reads and writes nothing. A stamped description pins its links to `main` to the
//! commit given with `--commit`, and a stamp without a commit, or a commit without a stamp, exits 1.
const std = @import("std");
const lib = @import("changelog_lib");
const t = std.testing;
const Alloc = std.mem.Allocator;

const CHANGELOG = "# Changelog\n\nWhat each release added.\n\n## 0.1.1512\n\n- **Platforms.** Linux.\n";
const README = "# komira\n\nSQL over local files.\n";
const COMMIT = "0123456789abcdef0123456789abcdef01234567";

const Run = struct { code: u8, err: []const u8 };

fn exec(a: Alloc, args: []const []const u8) !Run {
    var err = std.Io.Writer.Allocating.init(a);
    const code = try lib.cli.run(a, args, &err.writer);
    return .{ .code = code, .err = err.written() };
}

fn path(a: Alloc, tmp: *t.TmpDir, rel: []const u8) ![]u8 {
    const root = try tmp.dir.realpathAlloc(a, ".");
    return std.fs.path.join(a, &.{ root, rel });
}

/// A root directory holding CHANGELOG.md and, in changelog.d, the given fragments; and a README beside it.
fn setup(tmp: *t.TmpDir, fragments: []const [2][]const u8) !void {
    try tmp.dir.makePath("root");
    try tmp.dir.writeFile(.{ .sub_path = "root/CHANGELOG.md", .data = CHANGELOG });
    try tmp.dir.writeFile(.{ .sub_path = "README.md", .data = README });
    if (fragments.len != 0) try tmp.dir.makePath("root/changelog.d");
    for (fragments) |f| {
        const rel = try std.fmt.allocPrint(t.allocator, "root/changelog.d/{s}", .{f[0]});
        defer t.allocator.free(rel);
        try tmp.dir.writeFile(.{ .sub_path = rel, .data = f[1] });
    }
}

const TWO = [_][2][]const u8{
    .{ "b-second.md", "- **Second.** two\n" },
    .{ "a-first.md", "- **First.** one\n  continued\n" },
};

fn assembleArgs(a: Alloc, tmp: *t.TmpDir, stamp: []const u8) ![]const []const u8 {
    return a.dupe([]const u8, &.{ "assemble", "--root", try path(a, tmp, "root"), "--prefix", "python/", "--stamp", stamp, "--out", try path(a, tmp, "out.md") });
}

/// `description` over the scratch root, with `--commit commit` when it is given.
fn descriptionArgs(a: Alloc, tmp: *t.TmpDir, stamp: []const u8, commit: ?[]const u8) ![]const []const u8 {
    var args = std.ArrayList([]const u8).empty;
    try args.appendSlice(a, &.{ "description", "--root", try path(a, tmp, "root"), "--prefix", "python/", "--stamp", stamp });
    if (commit) |c| try args.appendSlice(a, &.{ "--commit", c });
    try args.appendSlice(a, &.{ "--readme", try path(a, tmp, "README.md"), "--out", try path(a, tmp, "out.md") });
    return args.toOwnedSlice(a);
}

fn written(a: Alloc, tmp: *t.TmpDir) ![]u8 {
    return tmp.dir.readFileAlloc(a, "out.md", 1 << 20);
}

fn notWritten(tmp: *t.TmpDir) !void {
    try t.expectError(error.FileNotFound, tmp.dir.access("out.md", .{}));
}

test "assemble writes the changelog with the stamped section and exits 0" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try setup(&tmp, &TWO);
    const r = try exec(a, try assembleArgs(a, &tmp, "1600"));
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("", r.err);
    try t.expectEqualStrings("# Changelog\n\nWhat each release added.\n\n## 0.1.1600\n\n- **First.** one\n  continued\n- **Second.** two\n\n## 0.1.1512\n\n- **Platforms.** Linux.\n", try written(a, &tmp));
}

test "an unstamped build writes the section as Unreleased" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try setup(&tmp, &TWO);
    const r = try exec(a, try assembleArgs(a, &tmp, "0"));
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expect(std.mem.indexOf(u8, try written(a, &tmp), "\n## Unreleased\n\n- **First.** one\n") != null);
}

test "a root with no changelog.d gets a section saying nothing is listed" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try setup(&tmp, &.{});
    const r = try exec(a, try assembleArgs(a, &tmp, "1600"));
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("# Changelog\n\nWhat each release added.\n\n## 0.1.1600\n\n" ++ lib.changelog.no_entries ++ "\n\n## 0.1.1512\n\n- **Platforms.** Linux.\n", try written(a, &tmp));
}

test "description writes the README and then the assembled changelog one level down" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try setup(&tmp, &TWO);
    const r = try exec(a, try descriptionArgs(a, &tmp, "1600", COMMIT));
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("", r.err);
    try t.expectEqualStrings(README ++ "\n## Changelog\n\nWhat each release added.\n\n### 0.1.1600\n\n- **First.** one\n  continued\n- **Second.** two\n\n### 0.1.1512\n\n- **Platforms.** Linux.\n", try written(a, &tmp));
}

test "a malformed fragment exits 1 naming its path, and nothing is written" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try setup(&tmp, &.{ .{ "good.md", "- **Good.** ok\n" }, .{ "bad.md", "- **Bad.** ok\nstray text\n" } });
    const r = try exec(a, try assembleArgs(a, &tmp, "1600"));
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expectEqualStrings("changelog: FAILED: python/changelog.d/bad.md:2: the line is neither a bullet (`- `) nor a continuation indented two spaces\n", r.err);
    try notWritten(&tmp);
}

test "a stamped description links to the files of its commit, and an unstamped one to main" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try setup(&tmp, &.{.{ "a.md", "- **A.** [the page](https://github.com/komira-ai/komira/blob/main/docs/install.md)\n" }});
    try tmp.dir.writeFile(.{ .sub_path = "README.md", .data = "# komira\n\n[docs](https://github.com/komira-ai/komira/tree/main/python/docs/)\n" });
    var r = try exec(a, try descriptionArgs(a, &tmp, "1600", COMMIT));
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("", r.err);
    try t.expectEqualStrings("# komira\n\n[docs](https://github.com/komira-ai/komira/tree/" ++ COMMIT ++ "/python/docs/)\n\n## Changelog\n\nWhat each release added.\n\n### 0.1.1600\n\n- **A.** [the page](https://github.com/komira-ai/komira/blob/" ++ COMMIT ++ "/docs/install.md)\n\n### 0.1.1512\n\n- **Platforms.** Linux.\n", try written(a, &tmp));

    r = try exec(a, try descriptionArgs(a, &tmp, "0", null));
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("# komira\n\n[docs](https://github.com/komira-ai/komira/tree/main/python/docs/)\n\n## Changelog\n\nWhat each release added.\n\n### Unreleased\n\n- **A.** [the page](https://github.com/komira-ai/komira/blob/main/docs/install.md)\n\n### 0.1.1512\n\n- **Platforms.** Linux.\n", try written(a, &tmp));
}

test "a description whose stamp and commit do not go together exits 1, and nothing is written" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try setup(&tmp, &TWO);
    const cases = [_]struct { stamp: []const u8, commit: ?[]const u8, err: []const u8 }{
        .{ .stamp = "1600", .commit = null, .err = "changelog: FAILED: the stamp `1600` is given with no commit: a stamped description pins its links to the commit the wheel is built from\n" },
        .{ .stamp = "0", .commit = COMMIT, .err = "changelog: FAILED: the commit `" ++ COMMIT ++ "` is given for an unstamped build, whose description links to `main`: a commit needs a stamp\n" },
        .{ .stamp = "1600", .commit = "", .err = "changelog: FAILED: the commit `` is not 40 lower-case hexadecimal digits\n" },
        .{ .stamp = "1600", .commit = "0123456789ABCDEF0123456789abcdef01234567", .err = "changelog: FAILED: the commit `0123456789ABCDEF0123456789abcdef01234567` is not 40 lower-case hexadecimal digits\n" },
    };
    for (cases) |c| {
        const r = try exec(a, try descriptionArgs(a, &tmp, c.stamp, c.commit));
        try t.expectEqual(@as(u8, 1), r.code);
        try t.expectEqualStrings(c.err, r.err);
        try notWritten(&tmp);
    }
}

test "a fragment that is not named as a slug exits 1 in the description too" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try setup(&tmp, &.{.{ "Bad_Name.md", "- **A.** a\n" }});
    const r = try exec(a, try descriptionArgs(a, &tmp, "1600", COMMIT));
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expectEqualStrings("changelog: FAILED: python/changelog.d/Bad_Name.md: the name is not `<slug>.md` with a slug of lower-case letters, digits and hyphens that does not start with a hyphen\n", r.err);
    try notWritten(&tmp);
}

test "a directory in changelog.d is refused by name" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try setup(&tmp, &TWO);
    try tmp.dir.makePath("root/changelog.d/nested");
    const r = try exec(a, try assembleArgs(a, &tmp, "1600"));
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expectEqualStrings("changelog: FAILED: python/changelog.d/nested: not a file: fragments are files directly in python/changelog.d/\n", r.err);
    try notWritten(&tmp);
}

test "a CHANGELOG.md with an Unreleased heading exits 1 naming the file and the line" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try setup(&tmp, &TWO);
    try tmp.dir.writeFile(.{ .sub_path = "root/CHANGELOG.md", .data = "# Changelog\n\n## Unreleased\n\n- **X.** x\n\n## 0.1.1512\n" });
    const r = try exec(a, try assembleArgs(a, &tmp, "1600"));
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expectEqualStrings("changelog: FAILED: python/CHANGELOG.md:3: a `## Unreleased` heading: entries go in python/changelog.d/ as files, and the release writes its section\n", r.err);
    try notWritten(&tmp);
}

test "a stamp that is no build number exits 1" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try setup(&tmp, &TWO);
    const r = try exec(a, try assembleArgs(a, &tmp, "07"));
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expectEqualStrings("changelog: FAILED: the stamp `07` is not a positive number without leading zeros\n", r.err);
    try notWritten(&tmp);
}

test "a root, a CHANGELOG.md, a README or an output that cannot be used is refused by name" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const missing = try path(a, &tmp, "nothing");
    var r = try exec(a, &.{ "assemble", "--root", missing, "--prefix", "python/", "--stamp", "1", "--out", try path(a, &tmp, "out.md") });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "changelog: FAILED: --root {s}: cannot open it: FileNotFound\n", .{missing}), r.err);

    try tmp.dir.makePath("empty");
    r = try exec(a, &.{ "assemble", "--root", try path(a, &tmp, "empty"), "--prefix", "python/", "--stamp", "1", "--out", try path(a, &tmp, "out.md") });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expectEqualStrings("changelog: FAILED: python/CHANGELOG.md: cannot read it: FileNotFound\n", r.err);

    try setup(&tmp, &TWO);
    const no_readme = try path(a, &tmp, "no-readme.md");
    r = try exec(a, &.{ "description", "--root", try path(a, &tmp, "root"), "--prefix", "python/", "--stamp", "1", "--commit", COMMIT, "--readme", no_readme, "--out", try path(a, &tmp, "out.md") });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "changelog: FAILED: {s}: cannot read it: FileNotFound\n", .{no_readme}), r.err);

    const no_dir = try path(a, &tmp, "no-dir/out.md");
    r = try exec(a, &.{ "assemble", "--root", try path(a, &tmp, "root"), "--prefix", "python/", "--stamp", "1", "--out", no_dir });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "changelog: FAILED: --out {s}: cannot write it: FileNotFound\n", .{no_dir}), r.err);
}

test "a usage error exits 2 and writes nothing" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try setup(&tmp, &TWO);
    const root = try path(a, &tmp, "root");
    const out = try path(a, &tmp, "out.md");
    const cases = [_]struct { args: []const []const u8, line: []const u8 }{
        .{ .args = &.{}, .line = "usage: changelog assemble" },
        .{ .args = &.{"publish"}, .line = "usage: changelog assemble" },
        .{ .args = &.{ "assemble", "--root", root, "--prefix", "p/", "--stamp", "1" }, .line = "usage: changelog assemble" },
        .{ .args = &.{ "description", "--root", root, "--prefix", "p/", "--stamp", "1", "--out", out }, .line = "usage: changelog assemble" },
        .{ .args = &.{ "assemble", "--root", root, "--prefix", "p/", "--stamp", "1", "--out", out, "--readme", "R" }, .line = "changelog: unknown argument --readme\n" },
        .{ .args = &.{ "assemble", "--root", root, "--prefix", "p/", "--stamp", "1", "--out", out, "--commit", COMMIT }, .line = "changelog: unknown argument --commit\n" },
        .{ .args = &.{ "description", "--root", root, "--prefix", "p/", "--stamp", "1", "--commit", COMMIT, "--commit", COMMIT, "--readme", "R", "--out", out }, .line = "changelog: --commit needs one value, given once\n" },
        .{ .args = &.{ "assemble", "--root", root, "--prefix", "p/", "--stamp", "1", "--out", out, "--extra", "x" }, .line = "changelog: unknown argument --extra\n" },
        .{ .args = &.{ "assemble", "--root", root, "--prefix", "p/", "--stamp", "1", "--out" }, .line = "changelog: --out needs one value, given once\n" },
        .{ .args = &.{ "assemble", "--root", root, "--root", root, "--prefix", "p/", "--stamp", "1", "--out", out }, .line = "changelog: --root needs one value, given once\n" },
    };
    for (cases) |c| {
        const r = try exec(a, c.args);
        try t.expectEqual(@as(u8, 2), r.code);
        try t.expect(std.mem.startsWith(u8, r.err, c.line));
        try notWritten(&tmp);
    }
}
