// Why Zig: build tools are Zig (tools/build/README.md). git_check replaces
// git_check.sh, the checks of the git oracle (README.md "Checks"), so that
// validation runs no shell. (git_build.sh stays: it runs git's own make, which
// needs one.)
//! git_check: the checks of the git oracle, one build action of the `git_check`
//! validation (defs.bzl).
//!
//!   git_check --busybox <busybox> --report <dir> --git <dist> --lfs <git-lfs>
//!             --version <v> --lfs-version <v>
//!
//! Exits 1 on the first wrong result, naming it; otherwise writes
//! <report>/validation.json, the validation result. The glibc floor and what
//! the loader maps for each program, read from the ELF files, are the
//! validation :git_closure (//tools/build/toolchains/loader_closure).
//!
//! Every git command runs with PATH set to a directory of decoys ahead of the
//! busybox applets: programs named git, git-upload-pack, git-receive-pack,
//! git-remote-http and git-lfs that record that they ran and fail (this very
//! program, run under one of those names). git finds its own programs through
//! its exec path (RUNTIME_PREFIX), which it puts ahead of PATH, so a decoy runs
//! only if git, or this check, reaches for a git other than the one under test.
//!   1. The distribution holds bin/git, the programs of libexec/git-core and
//!      the licence files, and no shared library.
//!   2. `git --version` prints `git version <version>`.
//!   3. `git --exec-path` is the distribution's libexec/git-core.
//!   4. The object ids git computes are the SHA-1s of the object bytes: a
//!      blob, the empty tree, and a commit with fixed identities and dates.
//!   5. Clone over the pack protocol (file://, git-upload-pack) and push
//!      (git-receive-pack) carry that commit; fsck --strict passes on both.
//!   6. The HTTP transport is compiled in and HTTPS is not: ls-remote to a
//!      closed port on 127.0.0.1 fails in libcurl's connect, and to an https
//!      URL fails as a disabled protocol (libcurl's whole messages).
//!   7. `git-lfs version` prints `git-lfs/<lfs_version> `, and `git lfs
//!      version`, which git runs as git-lfs from PATH, prints the same line.
//!      git-lfs runs `git` from PATH, so a run of git-lfs itself puts the
//!      distribution's bin/ first on PATH, as this check does.
//!   8. No decoy ran.

const std = @import("std");
const U = @import("act_util");

const prog = "git_check";

pub const decoys = [_][]const u8{ "git", "git-upload-pack", "git-receive-pack", "git-remote-http", "git-lfs" };

pub fn isDecoy(name: []const u8) bool {
    for (decoys) |d| {
        if (std.mem.eql(u8, d, name)) return true;
    }
    return false;
}

/// The directory a decoy was run from: the one of `argv0` when it names a
/// path, else the first directory of `path` (a colon-separated list) that holds
/// a file of that name, which is where the shell or execvp found it.
pub fn decoyDir(a: std.mem.Allocator, argv0: []const u8, path: ?[]const u8) !?[]const u8 {
    if (std.mem.indexOfScalar(u8, argv0, '/') != null) return std.fs.path.dirname(argv0) orelse ".";
    var it = std.mem.splitScalar(u8, path orelse return null, ':');
    while (it.next()) |d| {
        if (d.len == 0) continue;
        const cand = try std.fs.path.join(a, &.{ d, argv0 });
        if (std.fs.cwd().access(cand, .{})) |_| return d else |_| {}
    }
    return null;
}

/// What a decoy does, run as `<decoys>/<name> args...`: appends `<name> args...`
/// to `<decoys>/../decoy_ran` and exits 97.
fn decoyMain(a: std.mem.Allocator, argv: []const [:0]u8) noreturn {
    var line = std.ArrayList(u8).init(a);
    line.appendSlice(std.fs.path.basename(argv[0])) catch {};
    for (argv[1..]) |x| {
        line.append(' ') catch {};
        line.appendSlice(x) catch {};
    }
    line.append('\n') catch {};
    const dir = decoyDir(a, argv[0], std.posix.getenv("PATH")) catch null;
    if (dir) |d| {
        const log_path = std.fs.path.join(a, &.{ d, "..", "decoy_ran" }) catch std.process.exit(97);
        if (std.fs.cwd().openFile(log_path, .{ .mode = .write_only })) |f| {
            defer f.close();
            f.seekFromEnd(0) catch {};
            f.writeAll(line.items) catch {};
        } else |_| {
            if (std.fs.cwd().createFile(log_path, .{})) |f| {
                defer f.close();
                f.writeAll(line.items) catch {};
            } else |_| {}
        }
    }
    std.process.exit(97);
}

// ---- pure helpers ------------------------------------------------------------

/// The id git gives an object: the SHA-1 of `<kind> <size>\0<content>`.
pub fn objectId(kind: []const u8, content: []const u8) [40]u8 {
    var h = std.crypto.hash.Sha1.init(.{});
    var head: [64]u8 = undefined;
    const prefix = std.fmt.bufPrint(&head, "{s} {d}\x00", .{ kind, content.len }) catch unreachable;
    h.update(prefix);
    h.update(content);
    var d: [20]u8 = undefined;
    h.final(&d);
    return std.fmt.bytesToHex(d, .lower);
}

/// The commit the check asks git to make: fixed identities and dates.
pub fn commitBody(a: std.mem.Allocator, tree: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "tree {s}\nauthor A U Thor <author@example.com> 1790000000 +0000\ncommitter C O Mitter <committer@example.com> 1790000000 +0000\n\nsmoke\n", .{tree});
}

/// `text` with, on each line, the first ` after <digits> ms: ` written
/// ` after <ms> ms: ` (`sed -e 's/ after [0-9]* ms: / after <ms> ms: /'`).
pub fn msSubst(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var b = std.ArrayList(u8).init(a);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try b.append('\n');
        first = false;
        var from: usize = 0;
        var done = false;
        while (std.mem.indexOfPos(u8, line, from, " after ")) |at| {
            var e = at + " after ".len;
            while (e < line.len and line[e] >= '0' and line[e] <= '9') e += 1;
            if (std.mem.startsWith(u8, line[e..], " ms: ")) {
                try b.appendSlice(line[0..at]);
                try b.appendSlice(" after <ms> ms: ");
                try b.appendSlice(line[e + " ms: ".len ..]);
                done = true;
                break;
            }
            from = at + 1;
        }
        if (!done) try b.appendSlice(line);
    }
    return b.toOwnedSlice();
}

/// The last `n` lines of `text` (`tail -n`).
pub fn lastLines(text: []const u8, n: usize) []const u8 {
    if (n == 0 or text.len == 0) return text[text.len..];
    var end = text.len;
    if (text[end - 1] == '\n') end -= 1;
    var start = end;
    var seen: usize = 0;
    while (start > 0) {
        if (text[start - 1] == '\n') {
            seen += 1;
            if (seen == n) break;
        }
        start -= 1;
    }
    return text[start..];
}

/// The files the distribution must hold, each not empty.
pub const required = [_][]const u8{
    "bin/git",
    "libexec/git-core/git-remote-http",
    "libexec/git-core/git-upload-pack",
    "libexec/git-core/git-receive-pack",
    "share/licenses/NOTICE",
    "share/licenses/git/COPYING",
    "share/licenses/git/LGPL-2.1",
    "share/licenses/curl/COPYING",
    "share/licenses/zlib/LICENSE",
};

/// The shared libraries under `dir` (`find -name '*.so' -o -name '*.so.*'`), by
/// path relative to `prefix`'s name, sorted.
pub fn sharedLibraries(a: std.mem.Allocator, dir: std.fs.Dir, prefix: []const u8) ![][]const u8 {
    var walker = try dir.walk(a);
    defer walker.deinit();
    var list = std.ArrayList([]const u8).init(a);
    while (try walker.next()) |e| {
        const base = e.basename;
        if (std.mem.endsWith(u8, base, ".so") or std.mem.indexOf(u8, base, ".so.") != null) {
            try list.append(try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, e.path }));
        }
    }
    const items = try list.toOwnedSlice();
    std.mem.sort([]const u8, items, {}, U.lessBytes);
    return items;
}

// ---- the check ----------------------------------------------------------------

const Red = error{Red};

const Check = struct {
    a: std.mem.Allocator,
    exe: []const u8,
    busybox: []const u8,
    report: []const u8,
    dist: []const u8,
    lfs: []const u8,
    version: []const u8,
    lfs_version: []const u8,
    t: []const u8,
    env: std.process.EnvMap,
    git: []const u8,
    n: usize = 0,
    log: []const u8 = "",

    fn red(self: *Check, comptime fmt: []const u8, args: anytype) Red {
        std.debug.print("git_check RED: " ++ fmt ++ "\n", args);
        if (self.log.len > 0) std.debug.print("--- log:\n{s}", .{lastLines(self.log, 40)});
        if (self.log.len > 0 and self.log[self.log.len - 1] != '\n') std.debug.print("\n", .{});
        return error.Red;
    }

    fn pass(self: *Check) void {
        self.n += 1;
    }

    fn path(self: *Check, rel: []const u8) []const u8 {
        return std.fs.path.join(self.a, &.{ self.t, rel }) catch @panic("oom");
    }

    /// Runs git (or another program) with the check's environment. The output
    /// is stdout then stderr (`2>&1`), stripped of trailing newlines as `$(...)`
    /// strips them; `log` is the output (what the script kept in $T/log).
    const Out = struct { code: u8, text: []const u8, stdout: []const u8, raw: []const u8 };

    fn run(self: *Check, argv: []const []const u8, env: ?*const std.process.EnvMap) !Out {
        const r = try U.runCapture(self.a, argv, env orelse &self.env, null);
        const both = try std.mem.concat(self.a, u8, &.{ r.stdout, r.stderr });
        self.log = both;
        return .{ .code = r.code, .text = U.trimNewlines(both), .stdout = U.trimNewlines(r.stdout), .raw = both };
    }

    fn gitC(self: *Check, dir: []const u8, rest: []const []const u8) !Out {
        var argv = std.ArrayList([]const u8).init(self.a);
        try argv.appendSlice(&.{ self.git, "-C", dir });
        try argv.appendSlice(rest);
        return self.run(argv.items, null);
    }
};

fn setup(c: *Check) !void {
    const a = c.a;
    const cwd = std.fs.cwd();
    for ([_][]const u8{ "bin", "home", "decoy", "lfs" }) |d| try cwd.makePath(c.path(d));
    // The busybox applets: a PATH for the programs git runs besides itself.
    const inst = try U.runCapture(a, &.{ c.busybox, "--install", "-s", c.path("bin") }, null, null);
    if (inst.code != 0) return error.BusyboxInstallFailed;
    for (decoys) |d| try cwd.symLink(c.exe, try std.fs.path.join(a, &.{ c.path("decoy"), d }), .{});
    const lfs_copy = c.path("lfs/git-lfs");
    try cwd.copyFile(c.lfs, cwd, lfs_copy, .{});
    const f = try cwd.openFile(lfs_copy, .{});
    defer f.close();
    try f.chmod(0o755);
}

fn checks(c: *Check) !void {
    const a = c.a;
    // 1. The files.
    var dist = try std.fs.cwd().openDir(c.dist, .{ .iterate = true });
    defer dist.close();
    for (required) |f| {
        const st = dist.statFile(f) catch return c.red("the distribution has no {s}", .{f});
        if (st.size == 0) return c.red("the distribution has no {s}", .{f});
    }
    const so = try sharedLibraries(a, dist, c.dist);
    if (so.len > 0) {
        const joined = try std.mem.join(a, "\n", so);
        return c.red("the distribution holds shared libraries: {s}", .{joined});
    }
    c.pass();

    // 2. The version.
    {
        const r = try c.run(&.{ c.git, "--version" }, null);
        if (r.code != 0) return c.red("git --version failed: {s}", .{r.text});
        const want = try std.fmt.allocPrint(a, "git versions {s}", .{c.version});
        if (!std.mem.eql(u8, r.text, want)) return c.red("git --version printed '{s}', want 'git version {s}'", .{ r.text, c.version });
    }
    c.pass();

    // 3. The exec path is the distribution's own.
    {
        const r = try c.run(&.{ c.git, "--exec-path" }, null);
        if (r.code != 0) return c.red("git --exec-path failed: {s}", .{r.text});
        const got = std.fs.cwd().realpathAlloc(a, r.text) catch "";
        const want = std.fs.cwd().realpathAlloc(a, try std.fs.path.join(a, &.{ c.dist, "libexec/git-core" })) catch "(missing)";
        if (!std.mem.eql(u8, got, want)) return c.red("git --exec-path is '{s}', not the distribution's libexec/git-core", .{r.text});
    }
    c.pass();

    // 4. Object ids against the SHA-1 of the object bytes.
    const repo = c.path("repo");
    {
        const r = try c.run(&.{ c.git, "init", "-q", "-b", "main", repo }, null);
        if (r.code != 0) return c.red("git init failed", .{});
    }
    try U.writeAll(std.fs.cwd(), try std.fs.path.join(a, &.{ repo, "hello.txt" }), "hello\n");
    {
        const r = try c.gitC(repo, &.{ "hash-object", "-w", "hello.txt" });
        if (r.code != 0) return c.red("git hash-object failed", .{});
        const want = objectId("blob", "hello\n");
        if (!std.mem.eql(u8, r.stdout, &want)) return c.red("hash-object of 'hello\\n' is {s}, want {s}", .{ r.stdout, &want });
    }
    var tree: []const u8 = "";
    {
        const argv = [_][]const u8{ c.git, "-C", repo, "mktree" };
        const r = try c.run(&argv, null);
        if (r.code != 0) return c.red("git mktree failed", .{});
        tree = r.stdout;
        const want = objectId("tree", "");
        if (!std.mem.eql(u8, tree, &want)) return c.red("the empty tree is {s}, want {s}", .{ tree, &want });
    }
    const body = try commitBody(a, tree);
    var commit: []const u8 = "";
    {
        var env = try U.cloneEnv(a, c.env);
        try env.put("GIT_AUTHOR_NAME", "A U Thor");
        try env.put("GIT_AUTHOR_EMAIL", "author@example.com");
        try env.put("GIT_AUTHOR_DATE", "1790000000 +0000");
        try env.put("GIT_COMMITTER_NAME", "C O Mitter");
        try env.put("GIT_COMMITTER_EMAIL", "committer@example.com");
        try env.put("GIT_COMMITTER_DATE", "1790000000 +0000");
        const r = try c.run(&.{ c.git, "-C", repo, "commit-tree", "-m", "smoke", tree }, &env);
        if (r.code != 0) return c.red("git commit-tree failed", .{});
        commit = r.stdout;
        const want = objectId("commit", body);
        if (!std.mem.eql(u8, commit, &want)) return c.red("commit-tree gave {s}, want {s}", .{ commit, &want });
    }
    {
        const r = try c.gitC(repo, &.{ "update-ref", "refs/heads/main", commit });
        if (r.code != 0) return c.red("git update-ref failed", .{});
    }
    c.pass();

    // 5. The pack protocol, both ways.
    const clone = c.path("clone");
    const bare = c.path("bare.git");
    {
        const url = try std.fmt.allocPrint(a, "file://{s}", .{repo});
        const r = try c.run(&.{ c.git, "clone", "-q", "--no-local", url, clone }, null);
        if (r.code != 0) return c.red("git clone over file:// failed", .{});
        const h = try c.gitC(clone, &.{ "rev-parse", "HEAD" });
        if (h.code != 0) return c.red("rev-parse in the clone failed", .{});
        if (!std.mem.eql(u8, h.stdout, commit)) return c.red("the clone's HEAD is {s}, want {s}", .{ h.stdout, commit });
        const fk = try c.gitC(clone, &.{ "fsck", "--strict" });
        if (fk.code != 0) return c.red("fsck --strict of the clone failed", .{});
        const ib = try c.run(&.{ c.git, "init", "-q", "--bare", bare }, null);
        if (ib.code != 0) return c.red("git init --bare failed", .{});
        const purl = try std.fmt.allocPrint(a, "file://{s}", .{bare});
        const p = try c.gitC(repo, &.{ "push", "-q", purl, "main" });
        if (p.code != 0) return c.red("git push over file:// failed", .{});
        const bh = try c.gitC(bare, &.{ "rev-parse", "refs/heads/main" });
        if (bh.code != 0) return c.red("rev-parse in the bare repository failed", .{});
        if (!std.mem.eql(u8, bh.stdout, commit)) return c.red("the pushed main is {s}, want {s}", .{ bh.stdout, commit });
        const bf = try c.gitC(bare, &.{ "fsck", "--strict" });
        if (bf.code != 0) return c.red("fsck --strict of the pushed repository failed", .{});
    }
    c.pass();

    // 6. The HTTP transport. Port 1 on the loopback has no listener.
    {
        const r = try c.run(&.{ c.git, "ls-remote", "http://127.0.0.1:1/r" }, null);
        if (r.code == 0) return c.red("ls-remote to a closed port succeeded", .{});
        // libcurl's message, with the milliseconds it waited written <ms>.
        const got = U.trimNewlines(try msSubst(a, r.raw));
        const want = "fatal: unable to access 'http://127.0.0.1:1/r/': Failed to connect to 127.0.0.1:1 after <ms> ms: Could not connect to server";
        if (!std.mem.eql(u8, got, want)) return c.red("ls-remote http:// printed '{s}', want '{s}'", .{ got, want });
        const r2 = try c.run(&.{ c.git, "ls-remote", "https://127.0.0.1:1/r" }, null);
        if (r2.code == 0) return c.red("ls-remote to an https URL succeeded", .{});
        const want2 = "fatal: unable to access 'https://127.0.0.1:1/r/': Protocol \"https\" is disabled";
        if (!std.mem.eql(u8, r2.text, want2)) return c.red("ls-remote https:// printed '{s}', want '{s}'", .{ r2.text, want2 });
    }
    c.pass();

    // 7. git-lfs, alone and through git. git-lfs runs `git` from PATH, so run
    // alone it gets the distribution's bin/ first on PATH; run by git, it finds
    // git through the exec path git puts first.
    {
        var env = try U.cloneEnv(a, c.env);
        const base_path = c.env.get("PATH") orelse "";
        try env.put("PATH", try std.fmt.allocPrint(a, "{s}/bin:{s}", .{ c.dist, base_path }));
        const lfs = try c.run(&.{c.path("lfs/git-lfs"), "version"}, &env);
        if (lfs.code != 0) return c.red("git-lfs version failed: {s}", .{lfs.text});
        const want_head = try std.fmt.allocPrint(a, "git-lfs/{s} ", .{c.lfs_version});
        if (!std.mem.startsWith(u8, lfs.text, want_head)) return c.red("git-lfs version printed '{s}', want 'git-lfs/{s} ...'", .{ lfs.text, c.lfs_version });
        var env2 = try U.cloneEnv(a, c.env);
        try env2.put("PATH", try std.fmt.allocPrint(a, "{s}:{s}", .{ c.path("lfs"), base_path }));
        const via = try c.run(&.{ c.git, "lfs", "version" }, &env2);
        if (via.code != 0) return c.red("git lfs version failed: {s}", .{via.text});
        if (!std.mem.eql(u8, via.text, lfs.text)) return c.red("git lfs version printed '{s}', want '{s}'", .{ via.text, lfs.text });
    }
    c.pass();

    // 8. No decoy ran.
    if (std.fs.cwd().readFileAlloc(a, c.path("decoy_ran"), 1 << 20)) |ran| {
        const flat = try a.dupe(u8, ran);
        for (flat) |*ch| {
            if (ch.* == '\n') ch.* = ' ';
        }
        return c.red("a git from PATH ran instead of the distribution's: {s}", .{flat});
    } else |_| {}
    c.pass();
}

fn usage(comptime fmt: []const u8, args: anytype) u8 {
    std.debug.print(prog ++ ": " ++ fmt ++ "\n", args);
    return 2;
}

pub fn main() u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = std.process.argsAlloc(a) catch return 2;
    if (isDecoy(std.fs.path.basename(argv[0]))) decoyMain(a, argv);
    const plain = a.alloc([]const u8, argv.len - 1) catch return 2;
    for (argv[1..], 0..) |s, i| plain[i] = s;
    const spec = [_]U.Spec{
        .{ .name = "busybox" }, .{ .name = "report" }, .{ .name = "git" }, .{ .name = "lfs" }, .{ .name = "version" }, .{ .name = "lfs-version" },
    };
    var bad: []const u8 = "";
    const f = U.parseFlags(a, plain, &spec, &bad) catch |e| return usage("{s}: {s}", .{ @errorName(e), bad });
    const cwd = std.fs.cwd().realpathAlloc(a, ".") catch return 2;
    const exe = std.fs.selfExePathAlloc(a) catch return 2;
    const dist = U.abs(a, cwd, f.need("git") catch return usage("needs --git", .{})) catch return 2;
    // Private scratch: the directory buck2 names (BUCK_SCRATCH_PATH), else a
    // hidden one beside the inputs (an action that runs here shares the root).
    const buck = std.posix.getenv("BUCK_SCRATCH_PATH") orelse "";
    const t = if (buck.len == 0)
        std.fs.path.join(a, &.{ cwd, ".git_check" }) catch return 2
    else
        std.fs.path.join(a, &.{ cwd, buck, "git_check" }) catch return 2;
    std.fs.cwd().deleteTree(t) catch {};
    std.fs.cwd().makePath(t) catch return 2;
    defer std.fs.cwd().deleteTree(t) catch {};

    var c = Check{
        .a = a,
        .exe = exe,
        .busybox = U.abs(a, cwd, f.need("busybox") catch return usage("needs --busybox", .{})) catch return 2,
        .report = U.abs(a, cwd, f.need("report") catch return usage("needs --report", .{})) catch return 2,
        .dist = dist,
        .lfs = U.abs(a, cwd, f.need("lfs") catch return usage("needs --lfs", .{})) catch return 2,
        .version = f.need("version") catch return usage("needs --version", .{}),
        .lfs_version = f.need("lfs-version") catch return usage("needs --lfs-version", .{}),
        .t = t,
        .env = std.process.getEnvMap(a) catch return 2,
        .git = std.fs.path.join(a, &.{ dist, "bin/git" }) catch return 2,
    };
    c.env.put("PATH", std.fmt.allocPrint(a, "{s}/decoy:{s}/bin", .{ t, t }) catch return 2) catch return 2;
    c.env.put("HOME", std.fs.path.join(a, &.{ t, "home" }) catch return 2) catch return 2;
    for ([_][2][]const u8{ .{ "LC_ALL", "C" }, .{ "GIT_CONFIG_NOSYSTEM", "1" }, .{ "GIT_TERMINAL_PROMPT", "0" }, .{ "GIT_PAGER", "cat" } }) |kv| c.env.put(kv[0], kv[1]) catch return 2;
    std.fs.cwd().makePath(c.report) catch return 2;
    setup(&c) catch |e| return usage("cannot set up: {s}", .{@errorName(e)});
    checks(&c) catch |e| {
        if (e == error.Red) return 1;
        return usage("{s}", .{@errorName(e)});
    };
    const json = std.fmt.allocPrint(a, "{{\"version\": 1, \"data\": {{\"status\": \"success\", \"message\": \"git_check: {d} checks passed\"}}}}\n", .{c.n}) catch return 2;
    U.writeAll(std.fs.cwd(), std.fs.path.join(a, &.{ c.report, "validation.json" }) catch return 2, json) catch return 2;
    std.debug.print("git_check GREEN: {d} checks\n", .{c.n});
    return 0;
}
