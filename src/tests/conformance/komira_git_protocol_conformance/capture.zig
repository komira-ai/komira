// Why Zig: build tools are Zig (tools/build/README.md). This replaces capture.sh (a
// busybox shell script that drove git and wrote its files with awk) and the sh
// wrappers it started as the server.
//! capture: records what the pinned git (//third_party/git) says on the wire, one
//! build action of the `git_transcripts` rule (defs.bzl).
//!
//! usage: capture <git_dir> <out_dir>
//!
//! Every exchange runs real git on both ends. The client is told to reach the
//! server through this program as its ssh (GIT_SSH, GIT_SSH_VARIANT=ssh): git
//! passes it the command to run on the "remote" side, and it starts the pinned
//! git's upload-pack or receive-pack itself, copying the bytes each way, so each
//! scenario directory holds the exact bytes:
//!   conn<n>.req   everything the git client wrote on its n-th connection
//!   conn<n>.resp  everything the git server wrote back on it
//! and the server repository's state just before the exchange (the inputs a
//! server under test needs to answer the same requests):
//!   refs.txt     <id> <refname> <peeled id or -> for every ref
//!   head.txt     what HEAD names (`git symbolic-ref HEAD`)
//!   objects.txt  <id> <type> for every object
//!   parents.txt  <commit> <parent>... for every commit (`git rev-list --all --parents`)
//!   tags.txt     <tag id> <object id> for every annotated tag
//! Fetch scenarios add the client's shallow list before and after
//! (shallow_before.txt, shallow_after.txt); push scenarios add the server's
//! repository after the push (parents_after.txt) and its settings (settings.txt:
//! push-options, deny-non-fast-forwards).
//!
//! Scenarios (protocol v2 for fetch; receive-pack is always v0):
//!   v2_clone      clone of a repository with two branches and two tags
//!   v2_fetch      fetch of one new commit, with haves and a server option
//!   v2_shallow    clone --depth 1
//!   v2_deepen     fetch --deepen 1 in that shallow clone
//!   v2_since      clone --single-branch of main with --shallow-since and
//!                 --shallow-exclude (deepen-since, deepen-not)
//!   v2_unborn     clone of an empty repository (ls-refs unborn)
//!   v2_negotiate  fetch --negotiate-only (wait-for-done)
//!   push_atomic   push --atomic with push options: an update, a create, a delete
//!   push_reject   push --atomic --force refused by receive.denyNonFastForwards
//!   push_delete   a delete-only push (no pack), default advertisement
//!   push_ff       with receive.denyNonFastForwards: a fast-forward of
//!                 refs/heads/main and a forced update of refs/review/side, both
//!                 accepted (git refuses non-fast-forwards under refs/heads/ only)
//!   push_empty    the first push into an empty repository
//!
//! Called by git as its ssh (KGC_SHIM_GIT names the git to run), the program is the
//! server side of one connection: `<ssh> [-o <option>]... <host> <command>`, where
//! the command is `git-upload-pack '<path>'` or `git-receive-pack '<path>'`. It
//! writes conn<n>.req and conn<n>.resp in $KGC_CAPTURE when that names a
//! directory, and exits 0 whatever the server did.
//!
//! Exit status 1 on the first command that fails, naming it.

const std = @import("std");
const A = std.mem.Allocator;

// ---- the server side ------------------------------------------------------

/// The words of `s` as git quotes them for a shell (`sq_quote_buf`): runs of
/// bare characters, `'...'` groups and `\x` escapes, joined when adjacent;
/// words are split at blanks outside quotes.
pub fn shellWords(a: A, s: []const u8) ![][]const u8 {
    var words = std.ArrayList([]const u8).empty;
    var cur = std.ArrayList(u8).empty;
    var have = false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        switch (c) {
            ' ', '\t', '\n' => {
                if (have) {
                    try words.append(a, try cur.toOwnedSlice(a));
                    cur = std.ArrayList(u8).empty;
                    have = false;
                }
            },
            '\'' => {
                have = true;
                i += 1;
                while (i < s.len and s[i] != '\'') : (i += 1) try cur.append(a, s[i]);
                if (i >= s.len) return error.UnterminatedQuote;
            },
            '\\' => {
                have = true;
                i += 1;
                if (i >= s.len) return error.TrailingBackslash;
                try cur.append(a, s[i]);
            },
            else => {
                have = true;
                try cur.append(a, c);
            },
        }
    }
    if (have) try words.append(a, try cur.toOwnedSlice(a));
    return words.toOwnedSlice(a);
}

pub const Remote = struct { service: []const u8, path: []const u8 };

/// The server command of an ssh invocation `[-o <option>]... <host> <command>`:
/// the service (`upload-pack` or `receive-pack`) and the repository path.
pub fn parseSsh(a: A, args: []const []const u8) !Remote {
    var i: usize = 0;
    while (i < args.len and args[i].len > 0 and args[i][0] == '-') {
        // Options that take a value: -o, -p, -l, -i, -F.
        if (args[i].len == 2 and std.mem.indexOfScalar(u8, "opliF", args[i][1]) != null) i += 1;
        i += 1;
    }
    if (i + 1 >= args.len) return error.NoCommand;
    const words = try shellWords(a, args[i + 1]);
    if (words.len != 2) return error.BadCommand;
    const cmd = words[0];
    const prefix = "git-";
    if (!std.mem.startsWith(u8, cmd, prefix)) return error.BadCommand;
    const service = cmd[prefix.len..];
    if (!std.mem.eql(u8, service, "upload-pack") and !std.mem.eql(u8, service, "receive-pack")) return error.BadCommand;
    return .{ .service = service, .path = words[1] };
}

const Pump = struct {
    from: std.fs.File,
    to: std.fs.File,
    tee: ?std.fs.File,
    close_to: bool,

    fn run(self: Pump) void {
        var buf: [65536]u8 = undefined;
        while (true) {
            const n = self.from.read(&buf) catch break;
            if (n == 0) break;
            if (self.tee) |t| t.writeAll(buf[0..n]) catch {};
            self.to.writeAll(buf[0..n]) catch break;
        }
        if (self.close_to) self.to.close();
    }
};

fn shim(a: A, git: []const u8, args: []const []const u8) !u8 {
    // The client may close its end while the server still writes.
    const ignore = std.posix.Sigaction{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(std.posix.SIG.PIPE, &ignore, null);
    const remote = try parseSsh(a, args);
    var req: ?std.fs.File = null;
    var resp: ?std.fs.File = null;
    if (std.process.getEnvVarOwned(a, "KGC_CAPTURE")) |dir| {
        var n: usize = 1;
        while (true) : (n += 1) {
            const rp = try std.fmt.allocPrint(a, "{s}/conn{d}.req", .{ dir, n });
            std.fs.cwd().access(rp, .{}) catch {
                req = try std.fs.cwd().createFile(rp, .{});
                resp = try std.fs.cwd().createFile(try std.fmt.allocPrint(a, "{s}/conn{d}.resp", .{ dir, n }), .{});
                break;
            };
        }
    } else |_| {}
    var child = std.process.Child.init(&.{ git, remote.service, remote.path }, a);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();
    const feed = Pump{ .from = std.fs.File.stdin(), .to = child.stdin.?, .tee = req, .close_to = true };
    child.stdin = null;
    const t = try std.Thread.spawn(.{}, Pump.run, .{feed});
    t.detach();
    const back = Pump{ .from = child.stdout.?, .to = std.fs.File.stdout(), .tee = resp, .close_to = false };
    back.run();
    _ = child.wait() catch {};
    return 0;
}

// ---- the driver -----------------------------------------------------------

const Cap = struct {
    a: A,
    git: []const u8,
    self_exe: []const u8,
    t: []const u8,
    out: []const u8,
    env: std.process.EnvMap,
    n: usize = 0,
    log: []const u8 = "",

    fn red(self: *Cap, comptime fmt: []const u8, args: anytype) noreturn {
        std.debug.print("git capture RED: " ++ fmt ++ "\n", args);
        if (self.log.len > 0) {
            std.debug.print("--- log:\n", .{});
            var lines = std.ArrayList([]const u8).empty;
            var it = std.mem.splitScalar(u8, self.log, '\n');
            while (it.next()) |x| {
                if (it.peek() == null and x.len == 0) break;
                lines.append(self.a, x) catch {};
            }
            const from = if (lines.items.len > 40) lines.items.len - 40 else 0;
            for (lines.items[from..]) |x| std.debug.print("{s}\n", .{x});
        }
        std.process.exit(1);
    }

    fn pf(self: *Cap, comptime fmt: []const u8, args: anytype) []u8 {
        return std.fmt.allocPrint(self.a, fmt, args) catch @panic("oom");
    }

    fn join(self: *Cap, parts: []const []const u8) []u8 {
        return std.fs.path.join(self.a, parts) catch @panic("oom");
    }

    /// Runs `git <args>`; `capture` names the scenario directory the exchange is
    /// recorded in (the client then reaches its server through this program).
    /// Returns (exit ok, stdout).
    fn tryGit(self: *Cap, args: []const []const u8, extra: []const [2][]const u8, capture: ?[]const u8) struct { ok: bool, out: []u8 } {
        var env = std.process.EnvMap.init(self.a);
        var it = self.env.iterator();
        while (it.next()) |e| env.put(e.key_ptr.*, e.value_ptr.*) catch @panic("oom");
        for (extra) |kv| env.put(kv[0], kv[1]) catch @panic("oom");
        if (capture) |dir| env.put("KGC_CAPTURE", dir) catch @panic("oom");
        var argv = std.ArrayList([]const u8).empty;
        argv.append(self.a, self.git) catch @panic("oom");
        argv.appendSlice(self.a, args) catch @panic("oom");
        var child = std.process.Child.init(argv.items, self.a);
        child.env_map = &env;
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.spawn() catch |e| self.red("cannot run git: {s}", .{@errorName(e)});
        var out = std.ArrayList(u8).empty;
        var err = std.ArrayList(u8).empty;
        child.collectOutput(self.a, &out, &err, 1 << 30) catch |e| self.red("cannot read git's output: {s}", .{@errorName(e)});
        const term = child.wait() catch |e| self.red("cannot wait for git: {s}", .{@errorName(e)});
        self.log = err.items;
        const ok = switch (term) {
            .Exited => |c| c == 0,
            else => false,
        };
        return .{ .ok = ok, .out = out.items };
    }

    fn git_(self: *Cap, args: []const []const u8, what: []const u8) []u8 {
        const r = self.tryGit(args, &.{}, null);
        if (!r.ok) self.red("{s}", .{what});
        return r.out;
    }

    /// A git command whose exchange is recorded in `dir`.
    fn gitCap(self: *Cap, dir: []const u8, args: []const []const u8, what: []const u8) void {
        const r = self.tryGit(args, &.{}, dir);
        if (!r.ok) self.red("{s}", .{what});
    }

    fn write(self: *Cap, path: []const u8, data: []const u8) void {
        if (std.fs.path.dirname(path)) |d| std.fs.cwd().makePath(d) catch {};
        const f = std.fs.cwd().createFile(path, .{}) catch |e| self.red("cannot create {s}: {s}", .{ path, @errorName(e) });
        defer f.close();
        f.writeAll(data) catch |e| self.red("cannot write {s}: {s}", .{ path, @errorName(e) });
    }

    /// Commit n: one new file, author and committer dates 1790000000 + 60n.
    fn commit(self: *Cap, repo: []const u8, msg: []const u8) void {
        self.n += 1;
        const name = self.pf("f{d}.txt", .{self.n});
        self.write(self.join(&.{ repo, name }), self.pf("{s}\n", .{msg}));
        _ = self.git_(&.{ "-C", repo, "add", name }, self.pf("git add in {s}", .{repo}));
        const d = self.pf("{d} +0000", .{1790000000 + 60 * self.n});
        const r = self.tryGit(&.{ "-C", repo, "commit", "-q", "-m", msg }, &.{ .{ "GIT_AUTHOR_DATE", d }, .{ "GIT_COMMITTER_DATE", d } }, null);
        if (!r.ok) self.red("git commit '{s}' in {s}", .{ msg, repo });
    }

    /// The state of repository `repo` into scenario directory `dir`.
    fn state(self: *Cap, repo: []const u8, dir: []const u8) void {
        const refs = self.git_(&.{ "-C", repo, "for-each-ref", "--format=%(objectname) %(refname) %(*objectname)" }, self.pf("for-each-ref in {s}", .{repo}));
        self.write(self.join(&.{ dir, "refs.txt" }), refsText(self.a, refs) catch @panic("oom"));
        self.write(self.join(&.{ dir, "head.txt" }), self.git_(&.{ "-C", repo, "symbolic-ref", "HEAD" }, self.pf("symbolic-ref HEAD in {s}", .{repo})));
        const objects = self.git_(&.{ "-C", repo, "cat-file", "--batch-all-objects", "--batch-check=%(objectname) %(objecttype)" }, self.pf("cat-file --batch-all-objects in {s}", .{repo}));
        self.write(self.join(&.{ dir, "objects.txt" }), objects);
        self.write(self.join(&.{ dir, "parents.txt" }), self.git_(&.{ "-C", repo, "rev-list", "--all", "--parents" }, self.pf("rev-list in {s}", .{repo})));
        var tags = std.ArrayList(u8).empty;
        var lines = std.mem.splitScalar(u8, objects, '\n');
        while (lines.next()) |l| {
            var f = std.mem.tokenizeScalar(u8, l, ' ');
            const id = f.next() orelse continue;
            const kind = f.next() orelse continue;
            if (!std.mem.eql(u8, kind, "tag")) continue;
            const body = self.git_(&.{ "-C", repo, "cat-file", "tag", id }, self.pf("cat-file tag {s}", .{id}));
            const first = if (std.mem.indexOfScalar(u8, body, '\n')) |e| body[0..e] else body;
            var w = std.mem.tokenizeScalar(u8, first, ' ');
            _ = w.next();
            const target = w.next() orelse "";
            tags.writer(self.a).print("{s} {s}\n", .{ id, target }) catch @panic("oom");
        }
        self.write(self.join(&.{ dir, "tags.txt" }), tags.items);
    }

    fn shallowOf(self: *Cap, repo: []const u8) []const u8 {
        return std.fs.cwd().readFileAlloc(self.a, self.join(&.{ repo, ".git/shallow" }), 1 << 20) catch "";
    }

    fn scenario(self: *Cap, name: []const u8) []u8 {
        const dir = self.join(&.{ self.out, name });
        std.fs.cwd().makePath(dir) catch {};
        return dir;
    }

    fn finish(self: *Cap, name: []const u8, dir: []const u8) void {
        const req = std.fs.cwd().statFile(self.join(&.{ dir, "conn1.req" })) catch null;
        if (req == null or req.?.size == 0) self.red("{s}: the client wrote nothing", .{name});
        const resp = std.fs.cwd().statFile(self.join(&.{ dir, "conn1.resp" })) catch null;
        if (resp == null or resp.?.size == 0) self.red("{s}: the server wrote nothing", .{name});
    }

    /// `ssh://localhost<path>`: the URL of a repository reached through the shim.
    fn url(self: *Cap, path: []const u8) []u8 {
        return self.pf("ssh://localhost{s}", .{path});
    }
};

/// `<id> <refname> <peeled id or ->` per line of for-each-ref's
/// `%(objectname) %(refname) %(*objectname)`.
pub fn refsText(a: A, text: []const u8) ![]u8 {
    var o = std.ArrayList(u8).empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        var f = std.mem.tokenizeScalar(u8, l, ' ');
        const id = f.next() orelse continue;
        const name = f.next() orelse continue;
        try o.writer(a).print("{s} {s} {s}\n", .{ id, name, f.next() orelse "-" });
    }
    return o.toOwnedSlice(a);
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    if (std.process.getEnvVarOwned(a, "KGC_SHIM_GIT")) |git| {
        std.process.exit(try shim(a, git, argv[1..]));
    } else |_| {}
    if (argv.len != 3) {
        std.debug.print("usage: capture <git_dir> <out_dir>\n", .{});
        std.process.exit(2);
    }
    const dist = try std.fs.cwd().realpathAlloc(a, argv[1]);
    try std.fs.cwd().makePath(argv[2]);
    const out = try std.fs.cwd().realpathAlloc(a, argv[2]);
    const scratch_base = std.process.getEnvVarOwned(a, "BUCK_SCRATCH_PATH") catch try a.dupe(u8, ".git_capture");
    const t0 = if (std.process.hasEnvVarConstant("BUCK_SCRATCH_PATH")) try std.fs.path.join(a, &.{ scratch_base, "git_capture" }) else scratch_base;
    try std.fs.cwd().deleteTree(t0);
    try std.fs.cwd().makePath(try std.fs.path.join(a, &.{ t0, "home" }));
    const t = try std.fs.cwd().realpathAlloc(a, t0);
    var self_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_exe = try a.dupe(u8, try std.fs.selfExePath(&self_buf));
    const git = try std.fs.path.join(a, &.{ dist, "bin/git" });
    var env = std.process.EnvMap.init(a);
    try env.put("PATH", try std.fs.path.join(a, &.{ dist, "bin" }));
    try env.put("LC_ALL", "C");
    try env.put("HOME", try std.fs.path.join(a, &.{ t, "home" }));
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("GIT_TERMINAL_PROMPT", "0");
    try env.put("GIT_PAGER", "cat");
    try env.put("GIT_AUTHOR_NAME", "A U Thor");
    try env.put("GIT_AUTHOR_EMAIL", "author@example.com");
    try env.put("GIT_COMMITTER_NAME", "C O Mitter");
    try env.put("GIT_COMMITTER_EMAIL", "committer@example.com");
    // The client reaches its server through this program (the shim above).
    try env.put("GIT_SSH", self_exe);
    try env.put("GIT_SSH_VARIANT", "ssh");
    try env.put("KGC_SHIM_GIT", git);
    var c = Cap{ .a = a, .git = git, .self_exe = self_exe, .t = t, .out = out, .env = env };
    // The shim variable must reach git's ssh child only, not this program's own
    // later runs of git as a client; it does, as git passes its environment on.
    scenarios(&c);
}

fn scenarios(c: *Cap) void {
    const src = c.join(&.{ c.t, "src" });
    _ = c.git_(&.{ "init", "-q", "-b", "main", src }, "git init src");
    c.commit(src, "c1");
    {
        const r = c.tryGit(&.{ "-C", src, "tag", "-a", "v1", "-m", "release v1" }, &.{.{ "GIT_COMMITTER_DATE", "1790000090 +0000" }}, null);
        if (!r.ok) c.red("git tag -a v1", .{});
    }
    c.commit(src, "c2");
    _ = c.git_(&.{ "-C", src, "branch", "topic" }, "git branch topic");
    c.commit(src, "c3");
    _ = c.git_(&.{ "-C", src, "tag", "light" }, "git tag light");
    _ = c.git_(&.{ "-C", src, "checkout", "-q", "topic" }, "git checkout topic");
    c.commit(src, "c4");
    _ = c.git_(&.{ "-C", src, "checkout", "-q", "main" }, "git checkout main");

    // ---- protocol v2 fetch ----
    const clone = c.join(&.{ c.t, "clone" });
    var dir = c.scenario("v2_clone");
    c.state(src, dir);
    c.gitCap(dir, &.{ "-c", "protocol.version=2", "clone", "-q", c.url(src), clone }, "v2_clone: git clone");
    c.finish("v2_clone", dir);

    dir = c.scenario("v2_fetch");
    c.commit(src, "c5");
    c.state(src, dir);
    c.gitCap(dir, &.{ "-C", clone, "-c", "protocol.version=2", "fetch", "-q", "-o", "opt-a", "origin" }, "v2_fetch: git fetch");
    c.finish("v2_fetch", dir);

    const shallow = c.join(&.{ c.t, "shallow" });
    dir = c.scenario("v2_shallow");
    c.state(src, dir);
    c.gitCap(dir, &.{ "-c", "protocol.version=2", "clone", "-q", "--depth", "1", c.url(src), shallow }, "v2_shallow: git clone --depth 1");
    c.write(c.join(&.{ dir, "shallow_before.txt" }), "");
    c.write(c.join(&.{ dir, "shallow_after.txt" }), c.shallowOf(shallow));
    c.finish("v2_shallow", dir);

    dir = c.scenario("v2_deepen");
    c.state(src, dir);
    c.write(c.join(&.{ dir, "shallow_before.txt" }), c.shallowOf(shallow));
    c.gitCap(dir, &.{ "-C", shallow, "-c", "protocol.version=2", "fetch", "-q", "--deepen", "1", "origin" }, "v2_deepen: git fetch --deepen 1");
    c.write(c.join(&.{ dir, "shallow_after.txt" }), c.shallowOf(shallow));
    c.finish("v2_deepen", dir);

    const since = c.join(&.{ c.t, "since" });
    dir = c.scenario("v2_since");
    c.state(src, dir);
    c.gitCap(dir, &.{ "-c", "protocol.version=2", "clone", "-q", "--single-branch", "--branch", "main", "--shallow-since=@1790000150 +0000", "--shallow-exclude=v1", c.url(src), since }, "v2_since: git clone --shallow-since --shallow-exclude");
    c.write(c.join(&.{ dir, "shallow_before.txt" }), "");
    c.write(c.join(&.{ dir, "shallow_after.txt" }), c.shallowOf(since));
    c.finish("v2_since", dir);

    const empty = c.join(&.{ c.t, "empty.git" });
    dir = c.scenario("v2_unborn");
    _ = c.git_(&.{ "init", "-q", "--bare", "-b", "main", empty }, "git init --bare empty");
    c.state(empty, dir);
    c.gitCap(dir, &.{ "-c", "protocol.version=2", "clone", "-q", c.url(empty), c.join(&.{ c.t, "empty_clone" }) }, "v2_unborn: git clone of an empty repository");
    c.finish("v2_unborn", dir);

    dir = c.scenario("v2_negotiate");
    c.state(src, dir);
    const tip = std.mem.trimRight(u8, c.git_(&.{ "-C", clone, "rev-parse", "refs/remotes/origin/main" }, "rev-parse origin/main"), "\n");
    c.gitCap(dir, &.{ "-C", clone, "-c", "protocol.version=2", "fetch", "--negotiate-only", c.pf("--negotiation-tip={s}", .{tip}), "origin" }, "v2_negotiate: git fetch --negotiate-only");
    c.finish("v2_negotiate", dir);

    // ---- receive-pack ----
    const dst = c.join(&.{ c.t, "dst.git" });
    _ = c.git_(&.{ "init", "-q", "--bare", "-b", "main", dst }, "git init --bare dst");
    _ = c.git_(&.{ "-C", src, "push", "-q", c.url(dst), "main", "topic" }, "seed push to dst");

    dir = c.scenario("push_atomic");
    _ = c.git_(&.{ "-C", dst, "config", "receive.advertisePushOptions", "true" }, "config advertisePushOptions");
    c.write(c.join(&.{ dir, "settings.txt" }), "push-options\n");
    c.state(dst, dir);
    c.commit(src, "c6");
    c.gitCap(dir, &.{ "-C", src, "push", "-q", "--atomic", "-o", "ci.skip", "-o", "note=two", c.url(dst), "main", "main:refs/heads/feature", ":refs/heads/topic" }, "push_atomic: git push --atomic");
    c.write(c.join(&.{ dir, "parents_after.txt" }), c.git_(&.{ "-C", dst, "rev-list", "--all", "--parents" }, "rev-list dst"));
    c.finish("push_atomic", dir);

    dir = c.scenario("push_reject");
    _ = c.git_(&.{ "-C", dst, "config", "receive.denyNonFastForwards", "true" }, "config denyNonFastForwards");
    c.write(c.join(&.{ dir, "settings.txt" }), "push-options\ndeny-non-fast-forwards\n");
    c.state(dst, dir);
    _ = c.git_(&.{ "-C", src, "checkout", "-q", "-b", "side", "topic" }, "git checkout -b side");
    c.commit(src, "c7");
    {
        const r = c.tryGit(&.{ "-C", src, "push", "-q", "--atomic", "--force", c.url(dst), "side:refs/heads/main", "side:refs/heads/fresh" }, &.{}, dir);
        if (r.ok) c.red("push_reject: the non-fast-forward push was accepted", .{});
    }
    c.write(c.join(&.{ dir, "parents_after.txt" }), c.git_(&.{ "-C", dst, "rev-list", "--all", "--parents" }, "rev-list dst"));
    _ = c.git_(&.{ "-C", src, "checkout", "-q", "main" }, "git checkout main");
    c.finish("push_reject", dir);

    dir = c.scenario("push_delete");
    _ = c.git_(&.{ "-C", dst, "config", "receive.advertisePushOptions", "false" }, "config advertisePushOptions");
    c.write(c.join(&.{ dir, "settings.txt" }), "deny-non-fast-forwards\n");
    c.state(dst, dir);
    c.gitCap(dir, &.{ "-C", src, "push", "-q", c.url(dst), ":refs/heads/feature" }, "push_delete: git push of a delete");
    c.write(c.join(&.{ dir, "parents_after.txt" }), c.git_(&.{ "-C", dst, "rev-list", "--all", "--parents" }, "rev-list dst"));
    c.finish("push_delete", dir);

    dir = c.scenario("push_ff");
    c.write(c.join(&.{ dir, "settings.txt" }), "deny-non-fast-forwards\n");
    _ = c.git_(&.{ "-C", src, "push", "-q", c.url(dst), "side:refs/review/side" }, "seed push of refs/review/side");
    c.state(dst, dir);
    c.commit(src, "c8");
    c.gitCap(dir, &.{ "-C", src, "push", "-q", c.url(dst), "main", "+main:refs/review/side" }, "push_ff: git push of a fast-forward and a forced update outside refs/heads/");
    c.write(c.join(&.{ dir, "parents_after.txt" }), c.git_(&.{ "-C", dst, "rev-list", "--all", "--parents" }, "rev-list dst"));
    c.finish("push_ff", dir);

    const empty2 = c.join(&.{ c.t, "empty2.git" });
    dir = c.scenario("push_empty");
    _ = c.git_(&.{ "init", "-q", "--bare", "-b", "main", empty2 }, "git init --bare empty2");
    c.write(c.join(&.{ dir, "settings.txt" }), "");
    c.state(empty2, dir);
    c.gitCap(dir, &.{ "-C", src, "push", "-q", c.url(empty2), "main" }, "push_empty: git push into an empty repository");
    c.write(c.join(&.{ dir, "parents_after.txt" }), c.git_(&.{ "-C", empty2, "rev-list", "--all", "--parents" }, "rev-list empty2"));
    c.finish("push_empty", dir);

    c.write(c.join(&.{ c.out, "git_version.txt" }), c.git_(&.{"--version"}, "git --version"));
    std.fs.cwd().deleteTree(c.t) catch {};
}
