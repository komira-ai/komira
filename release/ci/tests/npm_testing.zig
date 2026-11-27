//! Helpers of the cases of npm_smoke: tarballs and sets made in memory, an npm that answers from rules, and
//! scratch paths. Nothing here touches the network, a clock or a real process.
const std = @import("std");
const lib = @import("npm_smoke_lib");
const t = std.testing;

const Alloc = std.mem.Allocator;

pub const MAIN = "@komira-ai/komira";
pub const LINUX = "@komira-ai/komira-linux-x64-gnu";
pub const DARWIN = "@komira-ai/komira-darwin-arm64";
pub const VERSION = "0.1.7";

/// The bytes of a stand-in tarball of `name` (any bytes do: the set hashes them, nothing unpacks them).
pub fn tarball(a: Alloc, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "the tarball of {s}\n", .{name});
}

/// Writes the stand-in tarballs of `names` at `version` into `dir` (made if absent) and returns the inputs
/// of `set build` for them.
pub fn writeTarballs(a: Alloc, tmp: *t.TmpDir, dir: []const u8, names: []const []const u8, version: []const u8) ![]lib.set.Input {
    try tmp.dir.makePath(dir);
    var out = std.ArrayList(lib.set.Input).empty;
    for (names) |n| {
        const file = try lib.set.tarballName(a, n, version);
        const rel = try std.fs.path.join(a, &.{ dir, file });
        const bytes = try tarball(a, n);
        try tmp.dir.writeFile(.{ .sub_path = rel, .data = bytes });
        try out.append(a, .{ .name = n, .path = try path(a, tmp, rel), .bytes = bytes });
    }
    return out.toOwnedSlice(a);
}

/// The set of the main package and the linux-x64 package at `version`, its tarballs and npm_set.json written
/// into `dir`; returns the set.
pub fn writeSet(a: Alloc, tmp: *t.TmpDir, dir: []const u8, version: []const u8) !lib.set.Set {
    const inputs = try writeTarballs(a, tmp, dir, &.{ MAIN, LINUX }, version);
    var why: []const u8 = "";
    const set = try lib.set.build(a, &why, MAIN, inputs, false);
    try tmp.dir.writeFile(.{ .sub_path = try std.fs.path.join(a, &.{ dir, lib.set.file_name }), .data = try lib.set.render(a, set) });
    return set;
}

/// A package-lock.json as npm writes it for the smoke's project: the root, then `entries`.
pub const LockEntry = struct {
    path: []const u8,
    version: []const u8 = VERSION,
    integrity: []const u8,
    install_script: bool = false,
};

pub fn lockJson(a: Alloc, entries: []const LockEntry) ![]const u8 {
    var w = std.Io.Writer.Allocating.init(a);
    try w.writer.writeAll("{\"name\":\"komira-npm-smoke\",\"lockfileVersion\":3,\"requires\":true,\"packages\":{\"\":{\"name\":\"komira-npm-smoke\",\"dependencies\":{\"@komira-ai/komira\":\"0.1.7\"}}");
    for (entries) |e| {
        try w.writer.print(",\"{s}\":{{\"version\":\"{s}\",\"resolved\":\"https://registry.npmjs.org/x.tgz\",\"integrity\":\"{s}\",\"license\":\"Apache-2.0\"", .{ e.path, e.version, e.integrity });
        if (e.install_script) try w.writer.writeAll(",\"hasInstallScript\":true");
        try w.writer.writeAll("}");
    }
    try w.writer.writeAll(",\"node_modules/apache-arrow\":{\"version\":\"21.2.0\",\"integrity\":\"sha512-AA==\",\"peer\":true}}}\n");
    return w.written();
}

/// The lock npm writes when it installed `set` as a user's machine has it: the main package, the linux-x64
/// package and apache-arrow.
pub fn goodLock(a: Alloc, set: lib.set.Set) ![]const u8 {
    return lockJson(a, &.{
        .{ .path = "node_modules/" ++ MAIN, .integrity = set.find(MAIN).?.integrity },
        .{ .path = "node_modules/" ++ LINUX, .integrity = set.find(LINUX).?.integrity },
    });
}

/// What a command of a `FakeNpm` answers when its line contains `contains`.
pub const Rule = struct {
    contains: []const u8,
    code: ?u8 = 1,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    /// The runner's error: the command cannot be started.
    spawn: ?anyerror = null,
    /// How many commands the rule applies to; then they fall through to the defaults.
    times: usize = std.math.maxInt(usize),
};

/// An npm and a node in memory: records each command (the work directory shown as `W`) and its directory
/// (the same), answers from `rules`, and otherwise succeeds: `npm view` with no output (the version is
/// absent), `npm install` writing `lock` into its directory, and `node smoke.mjs` printing `query_output`.
pub const FakeNpm = struct {
    alloc: Alloc,
    work: []const u8,
    rules: []const Rule = &.{},
    hits: std.ArrayList(usize) = .empty,
    calls: std.ArrayList([]const u8) = .empty,
    cwds: std.ArrayList([]const u8) = .empty,
    lock: ?[]const u8 = null,
    query_output: []const u8 = "0.1.7 n 1\n",

    pub fn runner(self: *FakeNpm) lib.npm.Runner {
        return .{ .ctx = self, .runFn = run };
    }

    fn run(ctx: *anyopaque, a: Alloc, argv: []const []const u8, cwd: []const u8) anyerror!lib.npm.Ran {
        const self: *FakeNpm = @ptrCast(@alignCast(ctx));
        const line = try std.mem.replaceOwned(u8, self.alloc, try std.mem.join(a, " ", argv), self.work, "W");
        try self.calls.append(self.alloc, line);
        try self.cwds.append(self.alloc, try std.mem.replaceOwned(u8, self.alloc, cwd, self.work, "W"));
        while (self.hits.items.len < self.rules.len) try self.hits.append(self.alloc, 0);
        for (self.rules, 0..) |r, i| {
            if (self.hits.items[i] >= r.times or std.mem.indexOf(u8, line, r.contains) == null) continue;
            self.hits.items[i] += 1;
            if (r.spawn) |e| return e;
            return .{ .code = r.code, .stdout = r.stdout, .stderr = r.stderr };
        }
        if (std.mem.indexOf(u8, line, " install ") != null) {
            if (self.lock) |l| try std.fs.cwd().writeFile(.{ .sub_path = try std.fs.path.join(a, &.{ cwd, "package-lock.json" }), .data = l });
            return .{ .code = 0 };
        }
        if (std.mem.endsWith(u8, line, " smoke.mjs")) return .{ .code = 0, .stdout = self.query_output };
        return .{ .code = 0 };
    }
};

/// The flags every npm command of the cases ends with, `W` the work directory.
pub const NPM_FLAGS = "--registry=https://registry.npmjs.org/ --userconfig=W/npmrc --globalconfig=W/npmrc-global --cache=W/npm-cache --no-update-notifier --no-audit --no-fund --loglevel=warn";

/// The absolute path of `rel` in the scratch directory.
pub fn path(a: Alloc, tmp: *t.TmpDir, rel: []const u8) ![]u8 {
    const root = try tmp.dir.realpathAlloc(a, ".");
    return std.fs.path.join(a, &.{ root, rel });
}

pub fn readAll(a: Alloc, tmp: *t.TmpDir, rel: []const u8) ![]u8 {
    return tmp.dir.readFileAlloc(a, rel, 1 << 28);
}

/// Whether `rel` exists in the scratch directory.
pub fn exists(tmp: *t.TmpDir, rel: []const u8) bool {
    tmp.dir.access(rel, .{}) catch return false;
    return true;
}

/// A pause that only counts how often it was asked and for how long in all.
pub const CountingPause = struct {
    times: usize = 0,
    ms: u64 = 0,

    pub fn pause(self: *CountingPause) lib.smoke.Pause {
        return .{ .ctx = self, .pauseFn = count };
    }

    fn count(ctx: *anyopaque, ms: u64) void {
        const self: *CountingPause = @ptrCast(@alignCast(ctx));
        self.times += 1;
        self.ms += ms;
    }
};

pub const Result = struct { code: u8, out: []const u8, err: []const u8 };

/// Runs the command line `args` with `fake` as npm and node, and `pause` between attempts.
pub fn exec(a: Alloc, args: []const []const u8, fake: *FakeNpm, pause: *CountingPause) !Result {
    var out = std.Io.Writer.Allocating.init(a);
    var err = std.Io.Writer.Allocating.init(a);
    const code = try lib.cli.run(a, args, .{ .runner = fake.runner(), .pause = pause.pause() }, &out.writer, &err.writer);
    return .{ .code = code, .out = out.written(), .err = err.written() };
}

/// The lines of `calls`, each exactly as given.
pub fn expectCalls(want: []const []const u8, got: []const []const u8) !void {
    if (want.len != got.len) {
        for (got) |g| std.debug.print("call: {s}\n", .{g});
    }
    try t.expectEqual(want.len, got.len);
    for (want, got) |w, g| try t.expectEqualStrings(w, g);
}
