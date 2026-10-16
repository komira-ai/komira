// Why Zig: build tools are Zig (tools/build/README.md). This replaces gen_packs.sh (a
// busybox shell script that drove git and generated the files with awk).
//! gen_packs: writes the packs komira_git_pack_conformance reads, with the pinned
//! git (//third_party/git), in one build action of the `git_packs` rule (defs.bzl).
//!
//! usage: gen_packs <out_dir> <git_dist>
//!
//! Two repositories get the same history (`generate`): one in the sha1 object
//! format, one in sha256. Thirty commits, each at a fixed date, change a 400-line
//! file in one line, grow a 70 to 110 KB file and edit lines of it, append to a
//! third file, add a file every fifth commit and delete one every tenth, and an
//! annotated tag lands every seventh. The objects stay loose in the repositories;
//! every pack is written outside them, so each is made from the objects alone (no
//! delta is reused from an earlier pack).
//!
//! <out_dir> holds, for each pack <name>:
//!   <name>.pack     what `git pack-objects` wrote
//!   <name>.idx      what `git index-pack` writes for <name>.pack
//!   <name>.verify   `git verify-pack -v`'s object lines, one per entry, as
//!                   `<id> <type> <size> <size-in-pack> <offset> <depth> <base>`
//!                   (depth 0 and base `-` for a non-delta)
//! The sha1 packs, all of every object of the repository:
//!   ofs       --delta-base-offset, window 10, depth 50 (OFS_DELTA entries)
//!   ref       window 10, depth 50, no --delta-base-offset (REF_DELTA entries)
//!   nodelta   window 0 (no delta)
//!   deep      --delta-base-offset, window 250, depth 4095
//!   narrow    --delta-base-offset, window 2, depth 3
//!   stored    as ofs, at --compression=0 (zlib stored blocks)
//! and also:
//!   ofs_large.idx   `git index-pack --index-version=2,0x40` of ofs.pack: every
//!                   offset over 0x40 in the eight-byte table
//!   thin.pack       `--thin --stdout` of main~10..main (REF_DELTAs on objects
//!                   main~10 has; no .idx: git index-pack refuses it too)
//!   thin.ids        the ids it carries (`git rev-list --objects`), sorted
//!   objects.batch   `git cat-file --batch-all-objects --batch` of the repository:
//!                   `<id> <type> <size>\n<payload>\n` per object
//! The sha256 repository: sha256.pack/.idx/.verify (as ofs) and objects256.batch.
//!
//! pack.threads is 1, so the delta search, and with it every byte written, is the
//! same on every run. Exit status 1 on the first git command that fails, naming
//! it and showing the last lines of its output.

const std = @import("std");
const A = std.mem.Allocator;

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// ---- the history ----------------------------------------------------------

/// src/a.txt at commit `i`: 400 lines, one of each thirty carrying the revision.
pub fn fileA(a: A, i: usize) ![]u8 {
    var o = std.ArrayList(u8).init(a);
    var k: usize = 1;
    while (k <= 400) : (k += 1) try o.writer().print("line {d} of a.txt, revision {d}\n", .{ k, if (k % 30 == i % 30) i else 0 });
    return o.toOwnedSlice();
}

/// src/deep/er/big.txt at commit `i`: 5000 + 100 i lines.
pub fn fileBig(a: A, i: usize) ![]u8 {
    var o = std.ArrayList(u8).init(a);
    var k: usize = 1;
    while (k <= 5000 + 100 * i) : (k += 1) try o.writer().print("{d:0>8} {s}\n", .{ (k * 7919) % 100000, if (k % 97 == i) "edited" else "same" });
    return o.toOwnedSlice();
}

/// src/n<i>.txt: 20 i lines.
pub fn fileNew(a: A, i: usize) ![]u8 {
    var o = std.ArrayList(u8).init(a);
    var k: usize = 1;
    while (k <= 20 * i) : (k += 1) try o.writer().print("new file {d}, line {d}\n", .{ i, k });
    return o.toOwnedSlice();
}

/// The date of commit `i`: `<seconds> +0000`.
pub fn date(a: A, i: usize) ![]u8 {
    return std.fmt.allocPrint(a, "{d} +0000", .{1790000000 + 60 * i});
}

/// The lines of `verify-pack -v` that name an object, reshaped as
/// `<id> <type> <size> <size-in-pack> <offset> <depth> <base>`.
pub fn verifyLines(a: A, text: []const u8) ![]u8 {
    var o = std.ArrayList(u8).init(a);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        var f = std.ArrayList([]const u8).init(a);
        var it = std.mem.tokenizeAny(u8, l, " \t");
        while (it.next()) |x| try f.append(x);
        if (f.items.len < 5) continue;
        const id = f.items[0];
        if (id.len != 40 and id.len != 64) continue;
        var hex = true;
        for (id) |c| {
            if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) hex = false;
        }
        if (!hex) continue;
        try o.writer().print("{s} {s} {s} {s} {s}", .{ id, f.items[1], f.items[2], f.items[3], f.items[4] });
        if (f.items.len >= 7) try o.writer().print(" {s} {s}\n", .{ f.items[5], f.items[6] }) else try o.appendSlice(" 0 -\n");
    }
    return o.toOwnedSlice();
}

/// The first `width` bytes of each line of `text`, sorted, each followed by a newline.
pub fn sortedPrefixes(a: A, text: []const u8, width: usize) ![]u8 {
    var ids = std.ArrayList([]const u8).init(a);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        if (lines.peek() == null and l.len == 0) break;
        try ids.append(l[0..@min(width, l.len)]);
    }
    std.mem.sort([]const u8, ids.items, {}, lessThan);
    var o = std.ArrayList(u8).init(a);
    for (ids.items) |x| try o.writer().print("{s}\n", .{x});
    return o.toOwnedSlice();
}

// ---- running git ----------------------------------------------------------

const Git = struct {
    a: A,
    exe: []const u8,
    env: std.process.EnvMap,
    /// The output of the last command, for the failure message.
    log: []const u8 = "",

    fn fail(self: *Git, comptime fmt: []const u8, args: anytype) noreturn {
        std.debug.print("gen_packs: " ++ fmt ++ "\n", args);
        if (self.log.len > 0) {
            std.debug.print("--- log:\n", .{});
            var lines = std.ArrayList([]const u8).init(self.a);
            var it = std.mem.splitScalar(u8, self.log, '\n');
            while (it.next()) |x| {
                if (it.peek() == null and x.len == 0) break;
                lines.append(x) catch {};
            }
            const from = if (lines.items.len > 40) lines.items.len - 40 else 0;
            for (lines.items[from..]) |x| std.debug.print("{s}\n", .{x});
        }
        std.process.exit(1);
    }

    /// Runs `git <args>`; its stdout, or a failure naming `what`.
    fn run(self: *Git, args: []const []const u8, extra: []const [2][]const u8, stdin: ?[]const u8, what: []const u8) []u8 {
        var argv = std.ArrayList([]const u8).init(self.a);
        argv.append(self.exe) catch @panic("oom");
        argv.appendSlice(args) catch @panic("oom");
        var env = std.process.EnvMap.init(self.a);
        var it = self.env.iterator();
        while (it.next()) |e| env.put(e.key_ptr.*, e.value_ptr.*) catch @panic("oom");
        for (extra) |kv| env.put(kv[0], kv[1]) catch @panic("oom");
        var child = std.process.Child.init(argv.items, self.a);
        child.env_map = &env;
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.spawn() catch |e| self.fail("cannot run git: {s}", .{@errorName(e)});
        if (stdin) |s| child.stdin.?.writeAll(s) catch {};
        child.stdin.?.close();
        child.stdin = null;
        var out = std.ArrayList(u8).init(self.a);
        var err = std.ArrayList(u8).init(self.a);
        child.collectOutput(&out, &err, 1 << 30) catch |e| self.fail("cannot read git's output: {s}", .{@errorName(e)});
        const term = child.wait() catch |e| self.fail("cannot wait for git: {s}", .{@errorName(e)});
        self.log = err.items;
        switch (term) {
            .Exited => |c| if (c != 0) self.fail("{s} failed", .{what}),
            else => self.fail("{s} did not exit", .{what}),
        }
        return out.items;
    }
};

fn writeFile(path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try std.fs.cwd().makePath(d);
    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(data);
}

fn appendFile(path: []const u8, data: []const u8) !void {
    const f = std.fs.cwd().openFile(path, .{ .mode = .write_only }) catch try std.fs.cwd().createFile(path, .{});
    defer f.close();
    try f.seekFromEnd(0);
    try f.writeAll(data);
}

fn join(a: A, parts: []const []const u8) []u8 {
    return std.fs.path.join(a, parts) catch @panic("oom");
}

fn pf(a: A, comptime f: []const u8, args: anytype) []u8 {
    return std.fmt.allocPrint(a, f, args) catch @panic("oom");
}

/// history <repo> <object format>
fn history(g: *Git, repo: []const u8, format: []const u8) !void {
    const a = g.a;
    _ = g.run(&.{ "init", "-q", "-b", "main", pf(a, "--object-format={s}", .{format}), repo }, &.{}, null, pf(a, "git init {s}", .{format}));
    try std.fs.cwd().makePath(join(a, &.{ repo, "src/deep/er" }));
    try std.fs.cwd().makePath(join(a, &.{ repo, "docs" }));
    try writeFile(join(a, &.{ repo, "empty" }), "");
    var i: usize = 1;
    while (i <= 30) : (i += 1) {
        try writeFile(join(a, &.{ repo, "src/a.txt" }), try fileA(a, i));
        try writeFile(join(a, &.{ repo, "src/deep/er/big.txt" }), try fileBig(a, i));
        try appendFile(join(a, &.{ repo, "docs/log.txt" }), pf(a, "entry {d} of the log\n", .{i}));
        if (i % 5 == 0) try writeFile(join(a, &.{ repo, pf(a, "src/n{d}.txt", .{i}) }), try fileNew(a, i));
        if (i % 10 == 0) std.fs.cwd().deleteFile(join(a, &.{ repo, pf(a, "src/n{d}.txt", .{i - 5}) })) catch {};
        const d = try date(a, i);
        _ = g.run(&.{ "-C", repo, "add", "-A" }, &.{}, null, pf(a, "git add at commit {d}", .{i}));
        _ = g.run(&.{ "-C", repo, "commit", "-q", "-m", pf(a, "commit {d}", .{i}) }, &.{ .{ "GIT_AUTHOR_DATE", d }, .{ "GIT_COMMITTER_DATE", d } }, null, pf(a, "git commit at commit {d}", .{i}));
        if (i % 7 == 0) _ = g.run(&.{ "-C", repo, "tag", "-a", pf(a, "v{d}", .{i}), "-m", pf(a, "tag {d}", .{i}) }, &.{.{ "GIT_COMMITTER_DATE", d }}, null, pf(a, "git tag at commit {d}", .{i}));
    }
}

/// pack <repo> <name> <pack-objects options...>: every object of the repository,
/// into <name>.pack, .idx and .verify.
fn pack(g: *Git, repo: []const u8, work: []const u8, out: []const u8, name: []const u8, opts: []const []const u8) !void {
    const a = g.a;
    var args = std.ArrayList([]const u8).init(a);
    try args.appendSlice(&.{ "-C", repo, "-c", "pack.threads=1", "pack-objects", "-q", "--all" });
    try args.appendSlice(opts);
    try args.append(join(a, &.{ work, name }));
    const sum = std.mem.trimRight(u8, g.run(args.items, &.{}, "", pf(a, "git pack-objects {s}", .{name})), "\n");
    const made = join(a, &.{ work, pf(a, "{s}-{s}.pack", .{ name, sum }) });
    const pack_path = join(a, &.{ out, pf(a, "{s}.pack", .{name}) });
    try std.fs.cwd().rename(made, pack_path);
    const idx = join(a, &.{ out, pf(a, "{s}.idx", .{name}) });
    _ = g.run(&.{ "-C", repo, "index-pack", "-o", idx, pack_path }, &.{}, null, pf(a, "git index-pack {s}", .{name}));
    const verify = g.run(&.{ "-C", repo, "verify-pack", "-v", idx }, &.{}, null, pf(a, "git verify-pack {s}", .{name}));
    const lines = try verifyLines(a, verify);
    if (lines.len == 0) g.fail("verify-pack {s} listed no object", .{name});
    try writeFile(join(a, &.{ out, pf(a, "{s}.verify", .{name}) }), lines);
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len != 3) {
        std.debug.print("usage: gen_packs <out_dir> <git_dist>\n", .{});
        std.process.exit(2);
    }
    const out = try std.fs.cwd().realpathAlloc(a, blk: {
        try std.fs.cwd().makePath(argv[1]);
        break :blk argv[1];
    });
    const dist = try std.fs.cwd().realpathAlloc(a, argv[2]);
    const scratch_base = std.process.getEnvVarOwned(a, "BUCK_SCRATCH_PATH") catch try a.dupe(u8, ".gen_packs");
    const t0 = if (std.process.hasEnvVarConstant("BUCK_SCRATCH_PATH")) join(a, &.{ scratch_base, "gen_packs" }) else scratch_base;
    try std.fs.cwd().deleteTree(t0);
    try std.fs.cwd().makePath(join(a, &.{ t0, "home" }));
    try std.fs.cwd().makePath(join(a, &.{ t0, "work" }));
    const t = try std.fs.cwd().realpathAlloc(a, t0);
    var env = std.process.EnvMap.init(a);
    try env.put("PATH", join(a, &.{ dist, "bin" }));
    try env.put("LC_ALL", "C");
    try env.put("HOME", join(a, &.{ t, "home" }));
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("GIT_TERMINAL_PROMPT", "0");
    try env.put("GIT_PAGER", "cat");
    try env.put("GIT_AUTHOR_NAME", "A U Thor");
    try env.put("GIT_AUTHOR_EMAIL", "author@example.com");
    try env.put("GIT_COMMITTER_NAME", "C O Mitter");
    try env.put("GIT_COMMITTER_EMAIL", "committer@example.com");
    var g = Git{ .a = a, .exe = join(a, &.{ dist, "bin/git" }), .env = env };
    const work = join(a, &.{ t, "work" });

    const r = join(a, &.{ t, "sha1" });
    try history(&g, r, "sha1");
    try pack(&g, r, work, out, "ofs", &.{ "--delta-base-offset", "--window=10", "--depth=50" });
    try pack(&g, r, work, out, "ref", &.{ "--window=10", "--depth=50" });
    try pack(&g, r, work, out, "nodelta", &.{"--window=0"});
    try pack(&g, r, work, out, "deep", &.{ "--delta-base-offset", "--window=250", "--depth=4095" });
    try pack(&g, r, work, out, "narrow", &.{ "--delta-base-offset", "--window=2", "--depth=3" });
    try pack(&g, r, work, out, "stored", &.{ "--compression=0", "--delta-base-offset", "--window=10", "--depth=50" });
    _ = g.run(&.{ "-C", r, "index-pack", "--index-version=2,0x40", "-o", join(a, &.{ out, "ofs_large.idx" }), join(a, &.{ out, "ofs.pack" }) }, &.{}, null, "git index-pack --index-version=2,0x40");
    try writeFile(join(a, &.{ out, "objects.batch" }), g.run(&.{ "-C", r, "cat-file", "--batch-all-objects", "--batch" }, &.{}, null, "git cat-file --batch"));
    const new = std.mem.trimRight(u8, g.run(&.{ "-C", r, "rev-parse", "main" }, &.{}, null, "git rev-parse main"), "\n");
    const old = std.mem.trimRight(u8, g.run(&.{ "-C", r, "rev-parse", "main~10" }, &.{}, null, "git rev-parse main~10"), "\n");
    const revs = pf(a, "{s}\n^{s}\n", .{ new, old });
    try writeFile(join(a, &.{ out, "thin.pack" }), g.run(&.{ "-C", r, "-c", "pack.threads=1", "pack-objects", "-q", "--revs", "--thin", "--delta-base-offset", "--stdout" }, &.{}, revs, "git pack-objects --thin"));
    const list = g.run(&.{ "-C", r, "rev-list", "--objects", new, pf(a, "^{s}", .{old}) }, &.{}, null, "git rev-list");
    try writeFile(join(a, &.{ out, "thin.ids" }), try sortedPrefixes(a, list, 40));

    const r256 = join(a, &.{ t, "sha256" });
    try history(&g, r256, "sha256");
    try pack(&g, r256, work, out, "sha256", &.{ "--delta-base-offset", "--window=10", "--depth=50" });
    try writeFile(join(a, &.{ out, "objects256.batch" }), g.run(&.{ "-C", r256, "cat-file", "--batch-all-objects", "--batch" }, &.{}, null, "git cat-file --batch (sha256)"));
    try std.fs.cwd().deleteTree(t);
}
