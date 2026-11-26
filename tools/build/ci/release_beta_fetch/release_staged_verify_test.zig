//! The cases of release_staged_verify (release_staged_verify.zig, prod_add.zig). Each test is a defect the prod
//! publish of release.yml would otherwise let through: tests that ran on other bytes than the registry will
//! publish, a staged directory with a file that was changed, lost or never listed, a smoke check that reads the
//! wrong channel or stops at the first lagging answer, a yank hint that names something that is not a group, and
//! a user's `mopm add` from prod that fails, locks another version, a flat name or the global channel, or
//! installs other bytes than the plan's.
const std = @import("std");
const rsv = @import("release_staged_verify.zig");
const rbf = @import("release_beta_fetch.zig");
const pa = @import("prod_add.zig");
const t = std.testing;

const CONFIG_URL = "https://api.mopm.dev/index/config.json";
const CONFIG_OK = "{\"channel_url\":\"https://conda.mopm.dev/\",\"stage\":\"prod\"}";
const BYTES_A = "package a bytes";
const BYTES_B = "package b bytes, a little longer";
const FILE_A = "mojo-ns.pa-0.1.9-mojo1.0.0_0.conda";
const FILE_B = "mojo-ns.pb-0.1.9-mojo1.0.0_0.conda";
const URL_A = "https://conda.mopm.dev/ns/linux-64/" ++ FILE_A;
const URL_B = "https://conda.mopm.dev/ns/linux-64/" ++ FILE_B;

fn sha(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    const hex = std.fmt.bytesToHex(d, .lower);
    return a.dupe(u8, &hex);
}

fn planText(a: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(a,
        \\{{"version":2,"members":[
        \\ {{"name":"ns/pa","version":"0.1.9","action":"upload","readme":"ns/pa/README.md",
        \\   "files":[{{"subdir":"linux-64","filename":"{s}","sha256":"{s}","size":{d}}}]}},
        \\ {{"name":"ns/pb","version":"0.1.9","action":"upload","readme":"ns/pb/README.md",
        \\   "files":[{{"subdir":"linux-64","filename":"{s}","sha256":"{s}","size":{d}}}]}}
        \\]}}
    , .{ FILE_A, try sha(a, BYTES_A), BYTES_A.len, FILE_B, try sha(a, BYTES_B), BYTES_B.len });
}

/// A staged directory as `mopm publish --staged --no-commit` leaves it, in `tmp`.
fn stage(a: std.mem.Allocator, tmp: *t.TmpDir) !void {
    try tmp.dir.makePath("staged/linux-64");
    try tmp.dir.makePath("staged/ns/pa");
    try tmp.dir.makePath("staged/ns/pb");
    try tmp.dir.writeFile(.{ .sub_path = "staged/plan.json", .data = try planText(a) });
    try tmp.dir.writeFile(.{ .sub_path = "staged/linux-64/" ++ FILE_A, .data = BYTES_A });
    try tmp.dir.writeFile(.{ .sub_path = "staged/linux-64/" ++ FILE_B, .data = BYTES_B });
    try tmp.dir.writeFile(.{ .sub_path = "staged/ns/pa/README.md", .data = "# pa\n" });
    try tmp.dir.writeFile(.{ .sub_path = "staged/ns/pb/README.md", .data = "# pb\n" });
    try tmp.dir.writeFile(.{ .sub_path = "staged/state.json", .data = "{\"group_id\":\"grp_abc-123\",\"staged\":true}" });
    try tmp.dir.writeFile(.{ .sub_path = "staged/report.json", .data = "{\"outcome\":\"staged\"}" });
}

fn path(a: std.mem.Allocator, tmp: *t.TmpDir, rel: []const u8) ![]u8 {
    const root = try tmp.dir.realpathAlloc(a, ".");
    return std.fs.path.join(a, &.{ root, rel });
}

fn exists(tmp: *t.TmpDir, rel: []const u8) bool {
    tmp.dir.access(rel, .{}) catch return false;
    return true;
}

fn sink() std.Io.Writer.Allocating {
    return std.Io.Writer.Allocating.init(t.allocator);
}

fn refusedWith(why: *const []const u8, r: anytype, needle: []const u8) !void {
    if (r) |_| return error.TestExpectedRefusal else |e| {
        try t.expect(e == error.Refused);
        if (std.mem.indexOf(u8, why.*, needle) == null) {
            std.debug.print("refusal was '{s}', wanted '{s}'\n", .{ why.*, needle });
            return error.TestWrongRefusal;
        }
    }
}

// ---- verify -----------------------------------------------------------------------------

test "verify writes the plan, the READMEs and the verified files, and leaves state.json and report.json out" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stage(a, &tmp);
    try tmp.dir.writeFile(.{ .sub_path = "staged/linux-64/not-in-the-plan.conda", .data = "stray" });
    var log = sink();
    defer log.deinit();
    var why: []const u8 = "";
    const rep = try rsv.verify(a, &why, try path(a, &tmp, "staged"), try path(a, &tmp, "out"), &log.writer);
    try t.expectEqual(@as(usize, 2), rep.members);
    try t.expectEqual(@as(usize, 2), rep.files);
    try t.expect(exists(&tmp, "out/plan.json"));
    try t.expect(exists(&tmp, "out/ns/pa/README.md"));
    try t.expect(exists(&tmp, "out/linux-64/" ++ FILE_B));
    const got = try tmp.dir.readFileAlloc(a, "out/linux-64/" ++ FILE_A, 1024);
    try t.expectEqualStrings(BYTES_A, got);
    try t.expect(!exists(&tmp, "out/state.json"));
    try t.expect(!exists(&tmp, "out/report.json"));
    try t.expect(!exists(&tmp, "out/linux-64/not-in-the-plan.conda"));
}

test "verify: one altered byte of the same size is a sha256 mismatch, only that file is named, and nothing is written" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stage(a, &tmp);
    try tmp.dir.writeFile(.{ .sub_path = "staged/linux-64/" ++ FILE_A, .data = "package a byteX" });
    var log = sink();
    defer log.deinit();
    var why: []const u8 = "";
    try refusedWith(&why, rsv.verify(a, &why, try path(a, &tmp, "staged"), try path(a, &tmp, "out"), &log.writer), "sha256");
    try t.expect(std.mem.indexOf(u8, why, "1 of 2 file(s)") != null);
    try t.expect(std.mem.indexOf(u8, why, FILE_B) == null);
    try t.expect(!exists(&tmp, "out"));
}

test "verify: a missing file, a shorter file and a longer file are each reported, all in one run" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stage(a, &tmp);
    try tmp.dir.deleteFile("staged/linux-64/" ++ FILE_A);
    try tmp.dir.writeFile(.{ .sub_path = "staged/linux-64/" ++ FILE_B, .data = BYTES_B ++ " and more" });
    var log = sink();
    defer log.deinit();
    var why: []const u8 = "";
    try refusedWith(&why, rsv.verify(a, &why, try path(a, &tmp, "staged"), try path(a, &tmp, "out"), &log.writer), "2 of 2 file(s)");
    try t.expect(std.mem.indexOf(u8, why, "cannot read") != null);
    try t.expect(std.mem.indexOf(u8, why, "larger than the plan's") != null);
    try t.expect(!exists(&tmp, "out"));
}

test "verify: a plan with a skip member is refused before any file is read, and a missing README fails the run" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stage(a, &tmp);
    var log = sink();
    defer log.deinit();
    var why: []const u8 = "";
    try tmp.dir.deleteFile("staged/ns/pb/README.md");
    try refusedWith(&why, rsv.verify(a, &why, try path(a, &tmp, "staged"), try path(a, &tmp, "out"), &log.writer), "README.md");
    try t.expect(!exists(&tmp, "out"));
    const skip = "{\"members\":[{\"name\":\"ns/pa\",\"version\":\"0.1.9\",\"action\":\"skip\",\"reason\":\"held\"}]}";
    try tmp.dir.writeFile(.{ .sub_path = "staged/plan.json", .data = skip });
    try refusedWith(&why, rsv.verify(a, &why, try path(a, &tmp, "staged"), try path(a, &tmp, "out"), &log.writer), "not 'upload'");
}

test "verify: an --out that holds something is refused, and one that holds only its BUCK is used beside it" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stage(a, &tmp);
    try tmp.dir.makePath("out");
    try tmp.dir.writeFile(.{ .sub_path = "out/leftover", .data = "x" });
    var log = sink();
    defer log.deinit();
    var why: []const u8 = "";
    try refusedWith(&why, rsv.verify(a, &why, try path(a, &tmp, "staged"), try path(a, &tmp, "out"), &log.writer), "not empty");
    try tmp.dir.deleteFile("out/leftover");
    try tmp.dir.writeFile(.{ .sub_path = "out/BUCK", .data = "# kept\n" });
    _ = try rsv.verify(a, &why, try path(a, &tmp, "staged"), try path(a, &tmp, "out"), &log.writer);
    try t.expect(exists(&tmp, "out/BUCK"));
    try t.expect(exists(&tmp, "out/plan.json"));
}

// ---- smoke ------------------------------------------------------------------------------

const Route = struct { url: []const u8, got: rbf.Got };

/// A registry in memory: a URL not in the table is HTTP 404. `lag` answers the first n file requests
/// with 404 (a channel whose cache has not caught up).
const Fake = struct {
    routes: []const Route,
    hits: usize = 0,
    file_hits: usize = 0,
    lag: usize = 0,

    fn fetcher(self: *Fake) rbf.Fetcher {
        return .{ .ctx = self, .getFn = get };
    }

    fn get(ctx: *anyopaque, _: std.mem.Allocator, url: []const u8, _: usize) rbf.Got {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.hits += 1;
        if (!std.mem.eql(u8, url, CONFIG_URL)) {
            self.file_hits += 1;
            if (self.file_hits <= self.lag) return .{ .status = 404 };
        }
        for (self.routes) |r| if (std.mem.eql(u8, r.url, url)) return r.got;
        return .{ .status = 404 };
    }
};

fn good() [3]Route {
    return .{
        .{ .url = CONFIG_URL, .got = .{ .body = @constCast(CONFIG_OK) } },
        .{ .url = URL_A, .got = .{ .body = @constCast(BYTES_A) } },
        .{ .url = URL_B, .got = .{ .body = @constCast(BYTES_B) } },
    };
}

test "smoke passes when the prod channel serves the staged bytes" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stage(a, &tmp);
    var routes = good();
    var fake = Fake{ .routes = &routes };
    var log = sink();
    defer log.deinit();
    var why: []const u8 = "";
    const rep = try rsv.smoke(a, &why, try path(a, &tmp, "staged"), fake.fetcher(), CONFIG_URL, 3, 0, &log.writer);
    try t.expectEqual(@as(usize, 2), rep.files);
    try t.expectEqual(@as(usize, 3), fake.hits);
}

test "smoke fails on a changed byte, tries every attempt, and names the file" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stage(a, &tmp);
    var routes = good();
    routes[1].got = .{ .body = @constCast("package a byteX") };
    var fake = Fake{ .routes = &routes };
    var log = sink();
    defer log.deinit();
    var why: []const u8 = "";
    try refusedWith(&why, rsv.smoke(a, &why, try path(a, &tmp, "staged"), fake.fetcher(), CONFIG_URL, 3, 0, &log.writer), "sha256");
    try t.expect(std.mem.indexOf(u8, why, "1 of 2 file(s)") != null);
    try t.expect(std.mem.indexOf(u8, why, FILE_A) != null);
    // three passes: the index and the two files each time
    try t.expectEqual(@as(usize, 9), fake.hits);
}

test "smoke: a channel that lags the commit passes on a later attempt, and fails when the attempts run out" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stage(a, &tmp);
    var routes = good();
    var log = sink();
    defer log.deinit();
    var why: []const u8 = "";
    var lagging = Fake{ .routes = &routes, .lag = 2 };
    _ = try rsv.smoke(a, &why, try path(a, &tmp, "staged"), lagging.fetcher(), CONFIG_URL, 2, 0, &log.writer);
    try t.expect(std.mem.indexOf(u8, log.written(), "attempt 1 of 2 failed") != null);
    var stuck = Fake{ .routes = &routes, .lag = 100 };
    try refusedWith(&why, rsv.smoke(a, &why, try path(a, &tmp, "staged"), stuck.fetcher(), CONFIG_URL, 2, 0, &log.writer), "not published");
}

test "smoke refuses an index of another stage and a channel that is not the prod one, before any file is fetched" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stage(a, &tmp);
    var log = sink();
    defer log.deinit();
    var why: []const u8 = "";
    var routes = good();
    routes[0].got = .{ .body = @constCast("{\"channel_url\":\"https://conda.mopm.dev/\",\"stage\":\"beta\"}") };
    var fake = Fake{ .routes = &routes };
    try refusedWith(&why, rsv.smoke(a, &why, try path(a, &tmp, "staged"), fake.fetcher(), CONFIG_URL, 1, 0, &log.writer), "wanted 'prod'");
    try t.expectEqual(@as(usize, 1), fake.hits);
    routes[0].got = .{ .body = @constCast("{\"channel_url\":\"https://conda.beta.mopm.dev/\",\"stage\":\"prod\"}") };
    var other = Fake{ .routes = &routes };
    try refusedWith(&why, rsv.smoke(a, &why, try path(a, &tmp, "staged"), other.fetcher(), CONFIG_URL, 1, 0, &log.writer), "not the pinned channel");
    try t.expectEqual(@as(usize, 1), other.hits);
}

test "smoke reads the plan only: a missing plan.json fails the run before any request" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("staged");
    var routes = good();
    var fake = Fake{ .routes = &routes };
    var log = sink();
    defer log.deinit();
    var why: []const u8 = "";
    try refusedWith(&why, rsv.smoke(a, &why, try path(a, &tmp, "staged"), fake.fetcher(), CONFIG_URL, 1, 0, &log.writer), "plan.json");
    try t.expectEqual(@as(usize, 0), fake.hits);
}

// ---- the yank hint ----------------------------------------------------------------------

test "the yank hint names the group of state.json, and only a plain group id" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const cmd = (try rsv.yankCommand(a, "{\"registry\":\"x\",\"group_id\":\"grp_abc-123\",\"committed\":true}", "prod")).?;
    try t.expectEqualStrings("mopm yank --group grp_abc-123 --registry prod --reason \"the release smoke check failed\"", cmd);
    try t.expect((try rsv.yankCommand(a, "{\"staged\":true}", "prod")) == null);
    try t.expect((try rsv.yankCommand(a, "", "prod")) == null);
    try t.expect((try rsv.yankCommand(a, "not json", "prod")) == null);
    try t.expect((try rsv.yankCommand(a, "{\"group_id\":\"g; rm -rf ~\"}", "prod")) == null);
    try t.expect((try rsv.yankCommand(a, "{\"group_id\":\"$(id)\"}", "prod")) == null);
}

// ---- add --------------------------------------------------------------------------------

const RUN = "0.1.9";
const PROD_NS = "https://conda.mopm.dev/komira-ai/";
/// The two Mojo versions this release's files are built for, and the one `mopm init` writes (mopm's default, older).
const RELEASE_MOJO = "1.1.0";
const NEXT_MOJO = "1.2.0";
const INIT_MOJO = "1.0.0";
/// The mopm.toml `mopm init --name release-check/prod_add` writes (mopm's template).
const INIT_TOML = "[package]\nname = \"release-check/prod_add\"\nversion = \"0.1.0\"\n\n[toolchain]\nmojo = \"" ++ INIT_MOJO ++
    "\"\n\n[dependencies]\n\n[targets]\nlib = { path = \"src/prod_add\" }\ntests = [\"tests\"]\n";

/// A package a channel serves: its full name, version, the Mojo it is built for and the bytes of its one linux-64 file.
const Pkg = struct {
    name: []const u8,
    version: []const u8 = RUN,
    mojo: []const u8 = RELEASE_MOJO,
    bytes: []const u8,
    deps: []const []const u8 = &.{},
};

/// The packages that ship a native archive (`RELEASE_NATIVES` of release/BUCK), in the order `add` adds them;
/// //tools/build/ci:prod_add_set_cases holds `add_set` to the real table.
const NATIVES = [_][]const u8{
    "komira-ai/async_api",
    "komira-ai/awslc",
    "komira-ai/compression",
    "komira-ai/crypto",
    "komira-ai/libc",
    "komira-ai/log",
    "komira-ai/metrics",
};

/// The prod channel of this release in memory: the names of `add_set` (json, uuid and every native package),
/// and uuid's dependency clock. uuid also depends on awslc, which is added by its own name too.
const SERVED = [_]Pkg{
    .{ .name = "komira-ai/async_api", .bytes = "async_api bytes and its archive" },
    .{ .name = "komira-ai/awslc", .bytes = "awslc bytes and its archive" },
    .{ .name = "komira-ai/clock", .bytes = "clock bytes" },
    .{ .name = "komira-ai/compression", .bytes = "compression bytes and its archive" },
    .{ .name = "komira-ai/crypto", .bytes = "crypto bytes and its archive" },
    .{ .name = "komira-ai/json", .bytes = "json bytes, no dependency" },
    .{ .name = "komira-ai/libc", .bytes = "libc bytes and its archive" },
    .{ .name = "komira-ai/log", .bytes = "log bytes and its archive" },
    .{ .name = "komira-ai/metrics", .bytes = "metrics bytes and its archive" },
    .{ .name = "komira-ai/uuid", .bytes = "uuid bytes", .deps = &.{ "komira-ai/clock", "komira-ai/awslc" } },
};

/// The same names built for the second Mojo: the release holds one build of every package per Mojo, at the same
/// version (the two builds `mopm stage --artifacts 1.1.0=... --artifacts 1.2.0=...` packs).
const SERVED_NEXT = blk: {
    var out: [SERVED.len]Pkg = undefined;
    for (SERVED, 0..) |p, i| out[i] = .{ .name = p.name, .mojo = NEXT_MOJO, .bytes = p.bytes ++ ", second Mojo", .deps = p.deps };
    break :blk out;
};
const BOTH = SERVED ++ SERVED_NEXT;

/// What prod also holds: the release before, built for the Mojo `mopm init` writes, one for each of `SERVED`.
const PRIOR = blk: {
    var out: [SERVED.len]Pkg = undefined;
    for (SERVED, 0..) |p, i| out[i] = .{ .name = p.name, .version = "0.1.8", .mojo = INIT_MOJO, .bytes = p.name ++ " of the release before", .deps = p.deps };
    break :blk out;
};

/// `base` without the package `name`.
fn without(a: std.mem.Allocator, base: []const Pkg, name: []const u8) ![]Pkg {
    var out = std.ArrayList(Pkg).empty;
    for (base) |p| if (!std.mem.eql(u8, p.name, name)) try out.append(a, p);
    try t.expectEqual(base.len - 1, out.items.len);
    return out.items;
}

/// `base` with the package of `p`'s name replaced by `p`, or `p` added when `base` has no such package.
fn with(a: std.mem.Allocator, base: []const Pkg, p: Pkg) ![]Pkg {
    var out = std.ArrayList(Pkg).empty;
    var replaced = false;
    for (base) |q| {
        const same = std.mem.eql(u8, q.name, p.name);
        replaced = replaced or same;
        try out.append(a, if (same) p else q);
    }
    if (!replaced) try out.append(a, p);
    return out.items;
}

fn fileName(a: std.mem.Allocator, name: []const u8, version: []const u8, mojo: []const u8) ![]u8 {
    const slash = std.mem.indexOfScalar(u8, name, '/').?;
    return std.fmt.allocPrint(a, "mojo-{s}.{s}-{s}-mojo{s}_0.conda", .{ name[0..slash], name[slash + 1 ..], version, mojo });
}

/// The committed set of this release (plan.json and the READMEs) for the names of `SERVED`, at version RUN, each with
/// a linux-64 file for every Mojo of `BOTH`.
fn stageAdd(a: std.mem.Allocator, tmp: *t.TmpDir) !void {
    return stageAddWithout(a, tmp, null);
}

/// `stageAdd` with the package `skip` left out of the plan, as a release that did not publish it.
fn stageAddWithout(a: std.mem.Allocator, tmp: *t.TmpDir, skip: ?[]const u8) !void {
    var plan = std.Io.Writer.Allocating.init(a);
    try plan.writer.writeAll("{\"version\":2,\"members\":[");
    var i: usize = 0;
    for (SERVED) |p| {
        if (skip != null and std.mem.eql(u8, skip.?, p.name)) continue;
        defer i += 1;
        try plan.writer.print("{s}{{\"name\":\"{s}\",\"version\":\"{s}\",\"action\":\"upload\",\"readme\":\"{s}/README.md\",", .{ if (i == 0) "" else ",", p.name, RUN, p.name });
        try plan.writer.writeAll("\"files\":[");
        var first = true;
        for (BOTH) |q| {
            if (!std.mem.eql(u8, q.name, p.name)) continue;
            try plan.writer.print("{s}{{\"subdir\":\"linux-64\",\"filename\":\"{s}\",\"sha256\":\"{s}\",\"size\":{d}}}", .{ if (first) "" else ",", try fileName(a, q.name, RUN, q.mojo), try sha(a, q.bytes), q.bytes.len });
            first = false;
        }
        try plan.writer.writeAll("]}");
        try tmp.dir.makePath(try std.fmt.allocPrint(a, "committed/{s}", .{p.name}));
        try tmp.dir.writeFile(.{ .sub_path = try std.fmt.allocPrint(a, "committed/{s}/README.md", .{p.name}), .data = "# readme\n" });
    }
    try plan.writer.writeAll("]}");
    try tmp.dir.writeFile(.{ .sub_path = "committed/plan.json", .data = plan.written() });
}

/// mopm in memory, against a channel of `served` and `prior`. `init`, `add` and `sync` do what mopm does to the
/// project directory: `init` writes `init_toml`, `add` exits 1 for a name the channel lacks or has no version of
/// for the project's Mojo (the `mojo =` line of its mopm.toml), `sync` writes mopm.lock (lock 3) for the closure of
/// the added names, each at its newest version built for that Mojo, keeps each file in `.mopm/pkgs` and installs
/// its record and metadata into `.mopm/env`. The other fields make it a mopm, or a registry, that does something
/// else.
const FakeMopm = struct {
    served: []const Pkg = &BOTH,
    prior: []const Pkg = &PRIOR,
    /// What `init` writes as mopm.toml; null writes none.
    init_toml: ?[]const u8 = INIT_TOML,
    /// `add` and `sync` resolve for this Mojo, not the project's: a mopm that ignores the project's `mojo`.
    lock_mojo: ?[]const u8 = null,
    /// Every command line, joined by spaces, without the binary.
    calls: std.ArrayList([]const u8) = .empty,
    added: std.ArrayList([]const u8) = .empty,
    /// The command (`argv[1]`) that exits `code` with `stderr` instead of running.
    fail: ?[]const u8 = null,
    code: ?u8 = 1,
    stderr: []const u8 = "",
    /// The runner's error: mopm cannot be started.
    spawn: ?anyerror = null,
    /// The lock records this full name flat (its name part only).
    flat: ?[]const u8 = null,
    /// The lock records this full name under the channel root, not its namespace's channel.
    global: ?[]const u8 = null,
    /// The lock's `channels` and `lock_version`.
    roots: []const u8 = "\"https://conda.mopm.dev/\"",
    lock_version: u32 = 3,
    /// An added name `sync` leaves out of the lock.
    drop: ?[]const u8 = null,
    /// This full name's file in `.mopm/pkgs` holds other bytes than the lock pins.
    kept_other: ?[]const u8 = null,
    /// This full name's record in `.mopm/env/conda-meta` names another sha256.
    record_other: ?[]const u8 = null,
    /// This full name's `lib/mojo/<import name>.mopm.json` is not installed.
    no_meta: ?[]const u8 = null,

    fn is(field: ?[]const u8, name: []const u8) bool {
        return field != null and std.mem.eql(u8, field.?, name);
    }

    fn runner(self: *FakeMopm) pa.Runner {
        return .{ .ctx = self, .runFn = run };
    }

    fn known(self: *FakeMopm, name: []const u8) bool {
        for ([_][]const Pkg{ self.served, self.prior }) |set| for (set) |p| if (std.mem.eql(u8, p.name, name)) return true;
        return false;
    }

    /// The newest version of `name` built for `mojo`, from `served` and `prior`.
    fn lookup(self: *FakeMopm, name: []const u8, mojo: []const u8) ?Pkg {
        var best: ?Pkg = null;
        for ([_][]const Pkg{ self.served, self.prior }) |set| for (set) |p| {
            if (!std.mem.eql(u8, p.name, name) or !std.mem.eql(u8, p.mojo, mojo)) continue;
            if (best == null or std.mem.order(u8, p.version, best.?.version) == .gt) best = p;
        };
        return best;
    }

    /// The Mojo the project resolves for: `lock_mojo`, or the value of the `mojo = "..."` line of its mopm.toml.
    fn projectMojo(self: *FakeMopm, a: std.mem.Allocator, dir: std.fs.Dir) ![]const u8 {
        if (self.lock_mojo) |m| return m;
        const toml = try dir.readFileAlloc(a, "mopm.toml", 1 << 20);
        const at = std.mem.indexOf(u8, toml, "\nmojo = \"").? + "\nmojo = \"".len;
        return toml[at .. at + std.mem.indexOfScalar(u8, toml[at..], '"').?];
    }

    fn run(ctx: *anyopaque, a: std.mem.Allocator, argv: []const []const u8, cwd: []const u8) anyerror!pa.Ran {
        const self: *FakeMopm = @ptrCast(@alignCast(ctx));
        try t.expectEqualStrings("/pinned/mopm", argv[0]);
        try self.calls.append(a, try std.mem.join(a, " ", argv[1..]));
        if (self.spawn) |e| return e;
        if (self.fail) |f| if (std.mem.eql(u8, f, argv[1])) return .{ .code = self.code, .stderr = self.stderr };
        var dir = try std.fs.cwd().openDir(cwd, .{});
        defer dir.close();
        if (std.mem.eql(u8, argv[1], "init")) {
            if (self.init_toml) |toml| try dir.writeFile(.{ .sub_path = "mopm.toml", .data = toml });
        } else if (std.mem.eql(u8, argv[1], "add")) {
            if (!self.known(argv[2])) return .{ .code = 1, .stderr = try std.fmt.allocPrint(a, "mopm add: {s} (required by mopm.toml) is not in the registry's index\n", .{argv[2]}) };
            const mojo = try self.projectMojo(a, dir);
            if (self.lookup(argv[2], mojo) == null) return .{ .code = 1, .stderr = try std.fmt.allocPrint(a, "mopm add: no version of {s} is built for mojo {s}\n", .{ argv[2], mojo }) };
            try self.added.append(a, argv[2]);
        } else if (std.mem.eql(u8, argv[1], "sync")) {
            try self.sync(a, dir);
        } else return .{ .code = 2, .stderr = "usage" };
        return .{ .code = 0, .stdout = "done\n" };
    }

    fn sync(self: *FakeMopm, a: std.mem.Allocator, dir: std.fs.Dir) !void {
        const mojo = try self.projectMojo(a, dir);
        var closure = std.ArrayList(Pkg).empty;
        var todo = std.ArrayList([]const u8).empty;
        for (self.added.items) |n| if (self.drop == null or !std.mem.eql(u8, n, self.drop.?)) try todo.append(a, n);
        while (todo.pop()) |n| {
            var seen = false;
            for (closure.items) |p| seen = seen or std.mem.eql(u8, p.name, n);
            if (seen) continue;
            const p = self.lookup(n, mojo).?;
            try closure.append(a, p);
            for (p.deps) |d| try todo.append(a, d);
        }
        // the lock's order: by full name
        std.mem.sort(Pkg, closure.items, {}, struct {
            fn lt(_: void, x: Pkg, y: Pkg) bool {
                return std.mem.lessThan(u8, x.name, y.name);
            }
        }.lt);
        var lock = std.Io.Writer.Allocating.init(a);
        try lock.writer.print("{{\"lock_version\":{d},\"mojo\":[\"{s}\"],\"channels\":[{s}],\"packages\":[", .{ self.lock_version, mojo, self.roots });
        try dir.makePath(".mopm/pkgs");
        try dir.makePath(".mopm/env/conda-meta");
        try dir.makePath(".mopm/env/lib/mojo");
        for (closure.items, 0..) |p, i| {
            const file = try fileName(a, p.name, p.version, p.mojo);
            const slash = std.mem.indexOfScalar(u8, p.name, '/').?;
            const is_flat = self.flat != null and std.mem.eql(u8, self.flat.?, p.name);
            const is_global = self.global != null and std.mem.eql(u8, self.global.?, p.name);
            const channel = if (is_global) "https://conda.mopm.dev/" else PROD_NS;
            try lock.writer.print("{s}{{\"name\":\"{s}\",\"version\":\"{s}\",\"subdir\":\"linux-64\",\"channel\":\"{s}\",", .{ if (i == 0) "" else ",", if (is_flat) p.name[slash + 1 ..] else p.name, p.version, channel });
            try lock.writer.print("\"artifacts\":{{\"{s}\":{{\"build\":\"mojo{s}_0\",\"url\":\"{s}linux-64/{s}\",\"sha256\":\"{s}\",\"size\":{d}}}}}}}", .{ mojo, p.mojo, channel, file, try sha(a, p.bytes), p.bytes.len });
            const other = self.kept_other != null and std.mem.eql(u8, self.kept_other.?, p.name);
            try dir.writeFile(.{ .sub_path = try std.fmt.allocPrint(a, ".mopm/pkgs/{s}", .{file}), .data = if (other) "other bytes" else p.bytes });
            const stem = file[0 .. file.len - ".conda".len];
            const recorded = if (is(self.record_other, p.name)) "0" ** 64 else try sha(a, p.bytes);
            try dir.writeFile(.{ .sub_path = try std.fmt.allocPrint(a, ".mopm/env/conda-meta/{s}.json", .{stem}), .data = try std.fmt.allocPrint(a, "{{\"sha256\":\"{s}\"}}", .{recorded}) });
            if (!is(self.no_meta, p.name)) try dir.writeFile(.{ .sub_path = try std.fmt.allocPrint(a, ".mopm/env/lib/mojo/{s}.mopm.json", .{p.name[slash + 1 ..]}), .data = "{}" });
        }
        try lock.writer.writeAll("]}");
        try dir.writeFile(.{ .sub_path = "mopm.lock", .data = lock.written() });
    }
};

/// Runs `add` for `add_set` with `fake` in a fresh `tmp` holding the committed set; `work` is `<tmp>/work`.
fn runAdd(a: std.mem.Allocator, tmp: *t.TmpDir, fake: *FakeMopm, why: *[]const u8, log: *std.Io.Writer) !pa.Report {
    return runAddFor(a, tmp, fake, why, log, RELEASE_MOJO);
}

fn runAddFor(a: std.mem.Allocator, tmp: *t.TmpDir, fake: *FakeMopm, why: *[]const u8, log: *std.Io.Writer, mojo: []const u8) !pa.Report {
    return pa.add(a, why, try path(a, tmp, "committed"), "/pinned/mopm", try path(a, tmp, "work"), &pa.add_set, "linux-64", mojo, fake.runner(), log);
}

test "add: prod serves the set; init, an add per package, then sync, and the lock and installed files are the plan's" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stageAdd(a, &tmp);
    var fake = FakeMopm{};
    var log = sink();
    defer log.deinit();
    var why: []const u8 = "";
    const rep = try runAdd(a, &tmp, &fake, &why, &log.writer);
    try t.expectEqual(@as(usize, 9), rep.members);
    try t.expectEqual(@as(usize, 10), rep.entries);
    const cache = try path(a, &tmp, "work/cache");
    const want = [_][]const u8{
        "init --name release-check/prod_add",
        "add komira-ai/json --registry prod",
        "add komira-ai/uuid --registry prod",
        "add komira-ai/async_api --registry prod",
        "add komira-ai/awslc --registry prod",
        "add komira-ai/compression --registry prod",
        "add komira-ai/crypto --registry prod",
        "add komira-ai/libc --registry prod",
        "add komira-ai/log --registry prod",
        "add komira-ai/metrics --registry prod",
        try std.fmt.allocPrint(a, "sync --registry prod --cache {s}", .{cache}),
    };
    try t.expectEqual(want.len, fake.calls.items.len);
    for (want, fake.calls.items) |w, got| try t.expectEqualStrings(w, got);
    // uuid's dependency clock is installed and checked too
    const clock = try std.fmt.allocPrint(a, "installed {s} komira-ai/clock 0.1.9 mojo-komira-ai.clock-0.1.9-mojo1.1.0_0.conda\n", .{try sha(a, "clock bytes")});
    try t.expect(std.mem.indexOf(u8, log.written(), clock) != null);
    try t.expect(exists(&tmp, "work/project/mopm.toml"));
}

test "add: every native package is added by its own name, and its kept file, record and metadata are checked" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    {
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        try stageAdd(a, &tmp);
        var fake = FakeMopm{};
        var log = sink();
        defer log.deinit();
        var why: []const u8 = "";
        _ = try runAdd(a, &tmp, &fake, &why, &log.writer);
        for (NATIVES) |n| {
            const call = try std.fmt.allocPrint(a, "add {s} --registry prod", .{n});
            var called = false;
            for (fake.calls.items) |c| called = called or std.mem.eql(u8, c, call);
            if (!called) std.debug.print("no `mopm {s}`\n", .{call});
            try t.expect(called);
            var bytes: []const u8 = "";
            for (SERVED) |p| if (std.mem.eql(u8, p.name, n)) {
                bytes = p.bytes;
            };
            const line = try std.fmt.allocPrint(a, "installed {s} {s} 0.1.9 {s}\n", .{ try sha(a, bytes), n, try fileName(a, n, RUN, RELEASE_MOJO) });
            try t.expect(std.mem.indexOf(u8, log.written(), line) != null);
        }
    }
    // each native package's installed files are read: another file in .mopm/pkgs, or no metadata, names it
    for (NATIVES) |n| {
        var bytes: []const u8 = "";
        for (SERVED) |p| if (std.mem.eql(u8, p.name, n)) {
            bytes = p.bytes;
        };
        const file = try fileName(a, n, RUN, RELEASE_MOJO);
        const label = try std.fmt.allocPrint(a, "{s} 0.1.9", .{n});

        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        try stageAdd(a, &tmp);
        var fake = FakeMopm{ .kept_other = n };
        var log = sink();
        defer log.deinit();
        var why: []const u8 = "";
        try t.expectError(error.Refused, runAdd(a, &tmp, &fake, &why, &log.writer));
        const want = try std.fmt.allocPrint(a, "2 problem(s) with what `mopm add` installed from prod:\n" ++
            "  {s}: .mopm/pkgs/{s} has size 11, the plan says {d}\n" ++
            "  {s}: .mopm/pkgs/{s} has sha256 {s}, the plan says {s}", .{ label, file, bytes.len, label, file, try sha(a, "other bytes"), try sha(a, bytes) });
        try t.expectEqualStrings(want, why);

        var tmp2 = t.tmpDir(.{});
        defer tmp2.cleanup();
        try stageAdd(a, &tmp2);
        var no_meta = FakeMopm{ .no_meta = n };
        try t.expectError(error.Refused, runAdd(a, &tmp2, &no_meta, &why, &log.writer));
        const import = n["komira-ai/".len..];
        const want_meta = try std.fmt.allocPrint(a, "1 problem(s) with what `mopm add` installed from prod:\n  {s}: .mopm/env/lib/mojo/{s}.mopm.json FileNotFound", .{ label, import });
        try t.expectEqualStrings(want_meta, why);
    }
}

test "add: a native package missing from the plan is refused with its name, before anything is made or run" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    for (NATIVES) |n| {
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        try stageAddWithout(a, &tmp, n);
        var fake = FakeMopm{};
        var log = sink();
        defer log.deinit();
        var why: []const u8 = "";
        try t.expectError(error.Refused, runAdd(a, &tmp, &fake, &why, &log.writer));
        const want = try std.fmt.allocPrint(a, "{s} is not a member of plan.json: this release did not publish it, so it cannot be added from prod", .{n});
        try t.expectEqualStrings(want, why);
        try t.expectEqual(@as(usize, 0), fake.calls.items.len);
        try t.expect(!exists(&tmp, "work"));
    }
}

test "add: prod also holds the release before, built for the Mojo init writes; the project is set to the Mojo of the run and locks this release" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stageAdd(a, &tmp);
    var fake = FakeMopm{};
    var log = sink();
    defer log.deinit();
    var why: []const u8 = "";
    const rep = try runAdd(a, &tmp, &fake, &why, &log.writer);
    try t.expectEqual(@as(usize, 10), rep.entries);
    // init's mopm.toml with only the [toolchain] mojo line changed
    const want = try std.mem.replaceOwned(u8, a, INIT_TOML, "mojo = \"" ++ INIT_MOJO ++ "\"", "mojo = \"" ++ RELEASE_MOJO ++ "\"");
    try t.expectEqualStrings(want, try tmp.dir.readFileAlloc(a, "work/project/mopm.toml", 1 << 20));
    try t.expect(std.mem.indexOf(u8, log.written(), "set [toolchain] mojo = \"1.1.0\" in mopm.toml: the Mojo this run checks\n") != null);
    const lock = try tmp.dir.readFileAlloc(a, "work/project/mopm.lock", 1 << 20);
    try t.expect(std.mem.indexOf(u8, lock, "\"mojo\":[\"1.1.0\"]") != null);
    try t.expect(std.mem.indexOf(u8, lock, "0.1.8") == null);
}

test "add: a mopm that locks for the Mojo init wrote gets the release before, and fails naming both Mojo versions and every version" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stageAdd(a, &tmp);
    var fake = FakeMopm{ .lock_mojo = INIT_MOJO };
    var log = sink();
    defer log.deinit();
    var why: []const u8 = "";
    try t.expectError(error.Refused, runAdd(a, &tmp, &fake, &why, &log.writer));
    try t.expectEqualStrings("11 problem(s) with what `mopm add` installed from prod:\n" ++
        "  mopm.lock is locked for mojo [1.0.0]; this run checks mojo 1.1.0\n" ++
        "  komira-ai/async_api: the lock records version 0.1.8; this release published 0.1.9\n" ++
        "  komira-ai/awslc: the lock records version 0.1.8; this release published 0.1.9\n" ++
        "  komira-ai/clock: the lock records version 0.1.8; this release published 0.1.9\n" ++
        "  komira-ai/compression: the lock records version 0.1.8; this release published 0.1.9\n" ++
        "  komira-ai/crypto: the lock records version 0.1.8; this release published 0.1.9\n" ++
        "  komira-ai/json: the lock records version 0.1.8; this release published 0.1.9\n" ++
        "  komira-ai/libc: the lock records version 0.1.8; this release published 0.1.9\n" ++
        "  komira-ai/log: the lock records version 0.1.8; this release published 0.1.9\n" ++
        "  komira-ai/metrics: the lock records version 0.1.8; this release published 0.1.9\n" ++
        "  komira-ai/uuid: the lock records version 0.1.8; this release published 0.1.9", why);
}

test "add: a channel with no build of a member for the Mojo of the run fails at its `mopm add`, naming it" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stageAdd(a, &tmp);
    var fake = FakeMopm{ .served = try without(a, &SERVED, "komira-ai/libc") };
    var log = sink();
    defer log.deinit();
    var why: []const u8 = "";
    try t.expectError(error.Refused, runAdd(a, &tmp, &fake, &why, &log.writer));
    try t.expectEqualStrings("`mopm add komira-ai/libc --registry prod` exited with 1: mopm add: no version of komira-ai/libc is built for mojo 1.1.0", why);
    try t.expectEqual(@as(usize, 8), fake.calls.items.len);
}

test "add: a mopm.toml from init with no [toolchain] mojo line, two of them, or none at all is refused before `mopm add` runs" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var log = sink();
    defer log.deinit();
    var why: []const u8 = "";
    const Case = struct { toml: ?[]const u8, want: []const u8 };
    const cases = [_]Case{
        .{ .toml = "[package]\nname = \"release-check/prod_add\"\nmojo = [\"1.0.0\"]\n", .want = "the mopm.toml `mopm init` wrote has 0 `mojo =` line(s) in [toolchain]; add sets exactly one to the Mojo this run checks, 1.1.0" },
        .{ .toml = "[toolchain]\nmojo = \"1.0.0\"\nmojo = \"1.1.0\"\n", .want = "the mopm.toml `mopm init` wrote has 2 `mojo =` line(s) in [toolchain]; add sets exactly one to the Mojo this run checks, 1.1.0" },
        .{ .toml = null, .want = "" },
    };
    for (cases) |c| {
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        try stageAdd(a, &tmp);
        var fake = FakeMopm{ .init_toml = c.toml };
        try t.expectError(error.Refused, runAdd(a, &tmp, &fake, &why, &log.writer));
        if (c.toml == null) {
            const want = try std.fmt.allocPrint(a, "the mopm.toml `mopm init` wrote in {s}: FileNotFound", .{try path(a, &tmp, "work/project")});
            try t.expectEqualStrings(want, why);
        } else try t.expectEqualStrings(c.want, why);
        try t.expectEqual(@as(usize, 1), fake.calls.items.len);
    }
}

test "add: setMojo changes only the mojo line of [toolchain], with or without spaces, and keeps every other byte" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";
    try t.expectEqualStrings("[toolchain]\nmojo = \"1.1.0\"", try pa.setMojo(a, &why, "[toolchain]\nmojo=\"1.0.0\"", "1.1.0"));
    const before = "# mojo = \"0\"\n[package]\nmojo_x = 1\nmojo = \"9\"\n[toolchain]\r\n  mojo   = \"1.0.0\"  \r\nmojox = 2\n\n";
    const after = "# mojo = \"0\"\n[package]\nmojo_x = 1\nmojo = \"9\"\n[toolchain]\r\nmojo = \"1.1.0\"\r\nmojox = 2\n\n";
    try t.expectEqualStrings(after, try pa.setMojo(a, &why, before, "1.1.0"));
}

test "add: checkMojo needs a file of every name built for the asked Mojo, allows files of the other Mojo versions, and refuses a file named otherwise or no file" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";
    const f = struct {
        fn file(subdir: []const u8, filename: []const u8) rbf.File {
            return .{ .subdir = subdir, .filename = filename, .sha256 = "0" ** 64, .size = 1 };
        }
    }.file;
    const json = rbf.Member{ .name = "komira-ai/json", .version = "0.1.9", .action = "upload", .files = &.{ f("linux-64", "mojo-komira-ai.json-0.1.9-mojo1.1.0_0.conda"), f("osx-arm64", "mojo-komira-ai.json-0.1.9-mojo1.1.0_0.conda"), f("linux-64", "mojo-komira-ai.json-0.1.9-mojo1.2.0_0.conda"), f("osx-arm64", "mojo-komira-ai.json-0.1.9-mojo1.2.0_0.conda") } };
    const uuid = rbf.Member{ .name = "komira-ai/uuid", .version = "0.1.9", .action = "upload", .files = &.{ f("linux-64", "mojo-komira-ai.uuid-0.1.9-mojo1.1.0_12.conda"), f("linux-64", "mojo-komira-ai.uuid-0.1.9-mojo1.2.0_12.conda") } };
    const plan = rbf.Plan{ .members = &.{ json, uuid } };
    const names = [_][]const u8{ "komira-ai/json", "komira-ai/uuid" };
    try pa.checkMojo(a, &why, plan, &names, "1.1.0");
    try pa.checkMojo(a, &why, plan, &names, "1.2.0");
    try t.expectError(error.Refused, pa.checkMojo(a, &why, plan, &names, "1.3.0"));
    try t.expectEqualStrings("plan.json lists no file of komira-ai/json built for Mojo 1.3.0", why);

    const Case = struct { file: []const u8, want: []const u8 };
    const bad = [_]Case{
        .{ .file = "mojo-komira-ai.uuid-0.1.9-mojo1.1.0.conda", .want = "komira-ai/uuid: mojo-komira-ai.uuid-0.1.9-mojo1.1.0.conda is not named mojo-komira-ai.uuid-0.1.9-mojo<mojo>_<n>.conda, so it names no Mojo version" },
        .{ .file = "mojo-komira-ai.uuid-0.1.9-mojo1.1.0_.conda", .want = "komira-ai/uuid: mojo-komira-ai.uuid-0.1.9-mojo1.1.0_.conda is not named mojo-komira-ai.uuid-0.1.9-mojo<mojo>_<n>.conda, so it names no Mojo version" },
        .{ .file = "mojo-komira-ai.uuid-0.1.9-mojo_0.conda", .want = "komira-ai/uuid: mojo-komira-ai.uuid-0.1.9-mojo_0.conda is not named mojo-komira-ai.uuid-0.1.9-mojo<mojo>_<n>.conda, so it names no Mojo version" },
        .{ .file = "mojo-komira-ai.uuid-0.1.8-mojo1.1.0_0.conda", .want = "komira-ai/uuid: mojo-komira-ai.uuid-0.1.8-mojo1.1.0_0.conda is not named mojo-komira-ai.uuid-0.1.9-mojo<mojo>_<n>.conda, so it names no Mojo version" },
        .{ .file = "mojo-komira-ai.uuid-0.1.9-mojo1.1.0_0.tar.bz2", .want = "komira-ai/uuid: mojo-komira-ai.uuid-0.1.9-mojo1.1.0_0.tar.bz2 is not named mojo-komira-ai.uuid-0.1.9-mojo<mojo>_<n>.conda, so it names no Mojo version" },
        .{ .file = "mojo-komira-ai.uuid-0.1.9-mojo1.0.0_0.conda", .want = "plan.json lists no file of komira-ai/uuid built for Mojo 1.1.0" },
    };
    for (bad) |c| {
        const other = rbf.Member{ .name = "komira-ai/uuid", .version = "0.1.9", .action = "upload", .files = &.{f("linux-64", c.file)} };
        try t.expectError(error.Refused, pa.checkMojo(a, &why, .{ .members = &.{ json, other } }, &names, "1.1.0"));
        try t.expectEqualStrings(c.want, why);
    }
    const empty = rbf.Member{ .name = "komira-ai/libc", .version = "0.1.9", .action = "upload" };
    try t.expectError(error.Refused, pa.checkMojo(a, &why, .{ .members = &.{empty} }, &.{"komira-ai/libc"}, "1.1.0"));
    try t.expectEqualStrings("plan.json lists no file of komira-ai/libc built for Mojo 1.1.0", why);
    try t.expectError(error.Refused, pa.checkMojo(a, &why, plan, &.{"komira-ai/gone"}, "1.1.0"));
    try t.expectEqualStrings("komira-ai/gone is not a member of plan.json", why);
}

test "add: isMojoVersion accepts digits and dots and refuses anything else" {
    for ([_][]const u8{ "1.1.0", "1.2.0", "10.0.12", "1" }) |ok| try t.expect(pa.isMojoVersion(ok));
    for ([_][]const u8{ "", ".1.0", "1.0.", "1.1.0\"", "1.1.0-rc1", "mojo1.1.0", "1 .0", "1.1.0\n[x]" }) |bad| try t.expect(!pa.isMojoVersion(bad));
}

test "add: a plan with two builds of every package (both Mojo versions) is checked once per Mojo, each in a project set to that Mojo, each locking and installing that Mojo's bytes" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stageAdd(a, &tmp);
    const Case = struct { mojo: []const u8, work: []const u8 };
    for ([_]Case{
        .{ .mojo = "1.1.0", .work = "work" },
        .{ .mojo = "1.2.0", .work = "work2" },
    }) |c| {
        var fake = FakeMopm{};
        var log = sink();
        defer log.deinit();
        var why: []const u8 = "";
        const rep = try pa.add(a, &why, try path(a, &tmp, "committed"), "/pinned/mopm", try path(a, &tmp, c.work), &pa.add_set, "linux-64", c.mojo, fake.runner(), &log.writer);
        try t.expectEqual(@as(usize, 9), rep.members);
        try t.expectEqual(@as(usize, 10), rep.entries);
        const want = try std.mem.replaceOwned(u8, a, INIT_TOML, "mojo = \"" ++ INIT_MOJO ++ "\"", try std.fmt.allocPrint(a, "mojo = \"{s}\"", .{c.mojo}));
        try t.expectEqualStrings(want, try tmp.dir.readFileAlloc(a, try std.fmt.allocPrint(a, "{s}/project/mopm.toml", .{c.work}), 1 << 20));
        const lock = try tmp.dir.readFileAlloc(a, try std.fmt.allocPrint(a, "{s}/project/mopm.lock", .{c.work}), 1 << 20);
        try t.expect(std.mem.indexOf(u8, lock, try std.fmt.allocPrint(a, "\"mojo\":[\"{s}\"]", .{c.mojo})) != null);
        const mine = try std.fmt.allocPrint(a, "mojo{s}_0.conda", .{c.mojo});
        const theirs = try std.fmt.allocPrint(a, "mojo{s}_0.conda", .{if (std.mem.eql(u8, c.mojo, "1.1.0")) "1.2.0" else "1.1.0"});
        try t.expect(std.mem.indexOf(u8, log.written(), mine) != null);
        try t.expect(std.mem.indexOf(u8, log.written(), theirs) == null);
    }
}

test "add: for the second Mojo every native package is added by its own name and installed with that Mojo's bytes" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stageAdd(a, &tmp);
    var fake = FakeMopm{};
    var log = sink();
    defer log.deinit();
    var why: []const u8 = "";
    _ = try runAddFor(a, &tmp, &fake, &why, &log.writer, NEXT_MOJO);
    for (NATIVES) |n| {
        const call = try std.fmt.allocPrint(a, "add {s} --registry prod", .{n});
        var called = false;
        for (fake.calls.items) |c| called = called or std.mem.eql(u8, c, call);
        try t.expect(called);
        var bytes: []const u8 = "";
        for (SERVED_NEXT) |p| if (std.mem.eql(u8, p.name, n)) {
            bytes = p.bytes;
        };
        const line = try std.fmt.allocPrint(a, "installed {s} {s} 0.1.9 {s}\n", .{ try sha(a, bytes), n, try fileName(a, n, RUN, NEXT_MOJO) });
        try t.expect(std.mem.indexOf(u8, log.written(), line) != null);
    }
}

test "add: a native package with no build for the second Mojo is refused with its name, before anything is made or run" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    for (NATIVES) |n| {
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        try stageAdd(a, &tmp);
        const text = try tmp.dir.readFileAlloc(a, "committed/plan.json", 1 << 20);
        const old = try fileName(a, n, RUN, NEXT_MOJO);
        const lacking = try std.mem.replaceOwned(u8, a, text, old, try fileName(a, n, RUN, "1.0.0"));
        try tmp.dir.writeFile(.{ .sub_path = "committed/plan.json", .data = lacking });
        var fake = FakeMopm{};
        var log = sink();
        defer log.deinit();
        var why: []const u8 = "";
        try t.expectError(error.Refused, runAddFor(a, &tmp, &fake, &why, &log.writer, NEXT_MOJO));
        try t.expectEqualStrings(try std.fmt.allocPrint(a, "plan.json lists no file of {s} built for Mojo {s}", .{ n, NEXT_MOJO }), why);
        try t.expectEqual(@as(usize, 0), fake.calls.items.len);
    }
}

test "add: a plan with no build of the packages for the asked Mojo is refused before anything is made or run" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stageAdd(a, &tmp);
    const text = try tmp.dir.readFileAlloc(a, "committed/plan.json", 1 << 20);
    const lacking = try std.mem.replaceOwned(u8, a, text, "mojo-komira-ai.libc-0.1.9-mojo1.2.0_0.conda", "mojo-komira-ai.libc-0.1.9-mojo1.0.0_0.conda");
    try tmp.dir.writeFile(.{ .sub_path = "committed/plan.json", .data = lacking });
    var fake = FakeMopm{};
    var log = sink();
    defer log.deinit();
    var why: []const u8 = "";
    try t.expectError(error.Refused, runAddFor(a, &tmp, &fake, &why, &log.writer, NEXT_MOJO));
    try t.expectEqualStrings("plan.json lists no file of komira-ai/libc built for Mojo 1.2.0", why);
    try t.expectError(error.Refused, runAddFor(a, &tmp, &fake, &why, &log.writer, "1.1.0\n[x]"));
    try t.expectEqualStrings("--mojo 1.1.0\n[x] is not a Mojo version (digits and dots, as in 1.1.0)", why);
    try t.expectEqual(@as(usize, 0), fake.calls.items.len);
    try t.expect(!exists(&tmp, "work"));
}

test "add: a channel that lacks a member fails at its `mopm add`, naming it, and nothing is synced" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stageAdd(a, &tmp);
    var fake = FakeMopm{ .served = try without(a, &SERVED, "komira-ai/libc"), .prior = &.{} };
    var log = sink();
    defer log.deinit();
    var why: []const u8 = "";
    try t.expectError(error.Refused, runAdd(a, &tmp, &fake, &why, &log.writer));
    try t.expectEqualStrings("`mopm add komira-ai/libc --registry prod` exited with 1: mopm add: komira-ai/libc (required by mopm.toml) is not in the registry's index", why);
    try t.expectEqual(@as(usize, 8), fake.calls.items.len);
}

test "add: a channel that serves a member at another version fails, naming the member and both versions" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stageAdd(a, &tmp);
    var fake = FakeMopm{ .served = try with(a, &SERVED, .{ .name = "komira-ai/libc", .version = "0.1.8", .bytes = "libc of the release before" }) };
    var log = sink();
    defer log.deinit();
    var why: []const u8 = "";
    try t.expectError(error.Refused, runAdd(a, &tmp, &fake, &why, &log.writer));
    try t.expectEqualStrings("1 problem(s) with what `mopm add` installed from prod:\n  komira-ai/libc: the lock records version 0.1.8; this release published 0.1.9", why);
}

test "add: an added name the lock leaves out fails, naming it" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stageAdd(a, &tmp);
    var fake = FakeMopm{ .drop = "komira-ai/json" };
    var log = sink();
    defer log.deinit();
    var why: []const u8 = "";
    try t.expectError(error.Refused, runAdd(a, &tmp, &fake, &why, &log.writer));
    try t.expectEqualStrings("1 problem(s) with what `mopm add` installed from prod:\n  komira-ai/json: `mopm add komira-ai/json` left it out of mopm.lock", why);
}

test "add: a lock that records a flat name fails" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stageAdd(a, &tmp);
    var fake = FakeMopm{ .flat = "komira-ai/clock" };
    var log = sink();
    defer log.deinit();
    var why: []const u8 = "";
    try t.expectError(error.Refused, runAdd(a, &tmp, &fake, &why, &log.writer));
    try t.expectEqualStrings("1 problem(s) with what `mopm add` installed from prod:\n  clock: a flat name; lock 3 records the full name <namespace>/<name>", why);
}

test "add: a lock that records the global channel for an entry, or another channel root, fails" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stageAdd(a, &tmp);
    var fake = FakeMopm{ .global = "komira-ai/json" };
    var log = sink();
    defer log.deinit();
    var why: []const u8 = "";
    try t.expectError(error.Refused, runAdd(a, &tmp, &fake, &why, &log.writer));
    try t.expectEqualStrings("1 problem(s) with what `mopm add` installed from prod:\n  komira-ai/json: channel 'https://conda.mopm.dev/'; wanted 'https://conda.mopm.dev/komira-ai/', the channel of its namespace", why);

    var tmp2 = t.tmpDir(.{});
    defer tmp2.cleanup();
    try stageAdd(a, &tmp2);
    var roots = FakeMopm{ .roots = "\"https://conda.mopm.dev/\",\"https://conda.beta.mopm.dev/\"", .lock_version = 2 };
    try t.expectError(error.Refused, runAdd(a, &tmp2, &roots, &why, &log.writer));
    try t.expectEqualStrings("2 problem(s) with what `mopm add` installed from prod:\n" ++
        "  mopm.lock has lock_version 2; lock 3 (full names, a channel per namespace) is the one wanted\n" ++
        "  mopm.lock lists the channel roots [https://conda.mopm.dev/, https://conda.beta.mopm.dev/]; wanted exactly [https://conda.mopm.dev/]", why);
}

test "add: a mopm that exits non-zero fails with the command and the first line of its stderr" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stageAdd(a, &tmp);
    var fake = FakeMopm{ .fail = "sync", .code = 1, .stderr = "\n  \r\nmopm sync: https://conda.mopm.dev/komira-ai/linux-64/repodata.json answered HTTP 503\nsecond line\n" };
    var log = sink();
    defer log.deinit();
    var why: []const u8 = "";
    try t.expectError(error.Refused, runAdd(a, &tmp, &fake, &why, &log.writer));
    const want = try std.fmt.allocPrint(a, "`mopm sync --registry prod --cache {s}` exited with 1: mopm sync: https://conda.mopm.dev/komira-ai/linux-64/repodata.json answered HTTP 503", .{try path(a, &tmp, "work/cache")});
    try t.expectEqualStrings(want, why);
    try t.expect(std.mem.indexOf(u8, log.written(), "second line") != null);
}

test "add: a mopm that fails at init, is killed, writes nothing on stderr, or cannot start fails, naming the command" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var log = sink();
    defer log.deinit();
    var why: []const u8 = "";
    const Case = struct { fake: FakeMopm, want: []const u8, calls: usize };
    const cases = [_]Case{
        .{ .fake = .{ .fail = "init", .code = 2, .stderr = "mopm init: a mopm.toml exists\n" }, .want = "`mopm init --name release-check/prod_add` exited with 2: mopm init: a mopm.toml exists", .calls = 1 },
        .{ .fake = .{ .fail = "add", .code = null, .stderr = "" }, .want = "`mopm add komira-ai/json --registry prod` did not exit (killed by a signal): (nothing on stderr)", .calls = 2 },
        .{ .fake = .{ .fail = "add", .code = 1, .stderr = "" }, .want = "`mopm add komira-ai/json --registry prod` exited with 1: (nothing on stderr)", .calls = 2 },
        .{ .fake = .{ .spawn = error.FileNotFound }, .want = "`mopm init --name release-check/prod_add` could not run /pinned/mopm: FileNotFound", .calls = 1 },
    };
    for (cases) |c| {
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        try stageAdd(a, &tmp);
        var fake = c.fake;
        try t.expectError(error.Refused, runAdd(a, &tmp, &fake, &why, &log.writer));
        try t.expectEqualStrings(c.want, why);
        try t.expectEqual(c.calls, fake.calls.items.len);
    }
}

test "add: an installed file with other bytes than the plan's fails, naming the file" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stageAdd(a, &tmp);
    var fake = FakeMopm{ .kept_other = "komira-ai/uuid" };
    var log = sink();
    defer log.deinit();
    var why: []const u8 = "";
    try t.expectError(error.Refused, runAdd(a, &tmp, &fake, &why, &log.writer));
    const want = try std.fmt.allocPrint(a, "2 problem(s) with what `mopm add` installed from prod:\n" ++
        "  komira-ai/uuid 0.1.9: .mopm/pkgs/mojo-komira-ai.uuid-0.1.9-mojo1.1.0_0.conda has size 11, the plan says 10\n" ++
        "  komira-ai/uuid 0.1.9: .mopm/pkgs/mojo-komira-ai.uuid-0.1.9-mojo1.1.0_0.conda has sha256 {s}, the plan says {s}", .{ try sha(a, "other bytes"), try sha(a, "uuid bytes") });
    try t.expectEqualStrings(want, why);
}

test "add: an environment whose record names another sha256, or that lacks a package's metadata, fails" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stageAdd(a, &tmp);
    var fake = FakeMopm{ .record_other = "komira-ai/json", .no_meta = "komira-ai/libc" };
    var log = sink();
    defer log.deinit();
    var why: []const u8 = "";
    try t.expectError(error.Refused, runAdd(a, &tmp, &fake, &why, &log.writer));
    const want = try std.fmt.allocPrint(a, "2 problem(s) with what `mopm add` installed from prod:\n" ++
        "  komira-ai/json 0.1.9: .mopm/env/conda-meta/mojo-komira-ai.json-0.1.9-mojo1.1.0_0.json records sha256 '{s}', the plan says {s}\n" ++
        "  komira-ai/libc 0.1.9: .mopm/env/lib/mojo/libc.mopm.json FileNotFound", .{ "0" ** 64, try sha(a, "json bytes, no dependency") });
    try t.expectEqualStrings(want, why);
}

test "add: a lock that pins other bytes than the plan's fails, naming the file and both hashes" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stageAdd(a, &tmp);
    var fake = FakeMopm{ .served = try with(a, &SERVED, .{ .name = "komira-ai/json", .bytes = "json bytes, but othe" }) };
    var log = sink();
    defer log.deinit();
    var why: []const u8 = "";
    try t.expectError(error.Refused, runAdd(a, &tmp, &fake, &why, &log.writer));
    const label = "komira-ai/json 0.1.9 linux-64/mojo-komira-ai.json-0.1.9-mojo1.1.0_0.conda";
    const want = try std.fmt.allocPrint(a, "2 problem(s) with what `mopm add` installed from prod:\n" ++
        "  " ++ label ++ ": the lock pins sha256 {s}, the plan says {s}\n" ++
        "  " ++ label ++ ": the lock pins size 20, the plan says 25", .{ try sha(a, "json bytes, but othe"), try sha(a, "json bytes, no dependency") });
    try t.expectEqualStrings(want, why);
}

test "add: a package the plan does not hold, or a --work that exists, is refused before mopm runs" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stageAdd(a, &tmp);
    var fake = FakeMopm{};
    var log = sink();
    defer log.deinit();
    var why: []const u8 = "";
    const names = [_][]const u8{ "komira-ai/json", "komira-ai/gone" };
    try t.expectError(error.Refused, pa.add(a, &why, try path(a, &tmp, "committed"), "/pinned/mopm", try path(a, &tmp, "work"), &names, "linux-64", RELEASE_MOJO, fake.runner(), &log.writer));
    try t.expectEqualStrings("komira-ai/gone is not a member of plan.json: this release did not publish it, so it cannot be added from prod", why);
    try t.expect(!exists(&tmp, "work"));
    try tmp.dir.makePath("work");
    try t.expectError(error.Refused, runAdd(a, &tmp, &fake, &why, &log.writer));
    try t.expect(std.mem.endsWith(u8, why, "/work exists; add runs in a directory it makes"));
    try t.expectEqual(@as(usize, 0), fake.calls.items.len);
}

test "add: the lock's files are checked for every subdir, and only the host's are read from the environment" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stageAdd(a, &tmp);
    var fake = FakeMopm{};
    var log = sink();
    defer log.deinit();
    var why: []const u8 = "";
    // linux-aarch64: the lock's linux-64 entries are checked against the plan, nothing is installed for this host
    try t.expectError(error.Refused, pa.add(a, &why, try path(a, &tmp, "committed"), "/pinned/mopm", try path(a, &tmp, "work"), &pa.add_set, "linux-aarch64", RELEASE_MOJO, fake.runner(), &log.writer));
    try t.expectEqualStrings("1 problem(s) with what `mopm add` installed from prod:\n  mopm.lock pins no file for linux-aarch64: nothing was installed", why);
}

test "add: the first line of stderr and the host's subdir" {
    try t.expectEqualStrings("mopm: no", pa.firstLine(" \r\n\t\n  mopm: no \r\nyes"));
    try t.expectEqualStrings("(nothing on stderr)", pa.firstLine(""));
    try t.expectEqualStrings("(nothing on stderr)", pa.firstLine("\n \n"));
    try t.expectEqualStrings("linux-64", pa.subdirOf(.linux, .x86_64).?);
    try t.expectEqualStrings("linux-aarch64", pa.subdirOf(.linux, .aarch64).?);
    try t.expectEqualStrings("osx-arm64", pa.subdirOf(.macos, .aarch64).?);
    try t.expect(pa.subdirOf(.macos, .x86_64) == null);
    try t.expect(pa.subdirOf(.linux, .riscv64) == null);
    try t.expect(pa.subdirOf(.windows, .x86_64) == null);
}

test "add: the process runner reports a mopm that is not there as an error, which add names with the binary" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stageAdd(a, &tmp);
    const missing = try path(a, &tmp, "no-such-mopm");
    var proc = pa.Process{};
    try t.expectError(error.FileNotFound, proc.runner().run(a, &.{ missing, "init" }, try path(a, &tmp, ".")));
    var log = sink();
    defer log.deinit();
    var why: []const u8 = "";
    try t.expectError(error.Refused, pa.add(a, &why, try path(a, &tmp, "committed"), missing, try path(a, &tmp, "work"), &pa.add_set, "linux-64", RELEASE_MOJO, proc.runner(), &log.writer));
    const want = try std.fmt.allocPrint(a, "`mopm init --name release-check/prod_add` could not run {s}: FileNotFound", .{missing});
    try t.expectEqualStrings(want, why);
}

test "add: a relative --mopm or --work is refused before anything is made or run" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stageAdd(a, &tmp);
    var fake = FakeMopm{};
    var log = sink();
    defer log.deinit();
    var why: []const u8 = "";
    const staged = try path(a, &tmp, "committed");
    try t.expectError(error.Refused, pa.add(a, &why, staged, "bin/mopm", try path(a, &tmp, "work"), &pa.add_set, "linux-64", RELEASE_MOJO, fake.runner(), &log.writer));
    try t.expectEqualStrings("--mopm bin/mopm is not an absolute path", why);
    try t.expectError(error.Refused, pa.add(a, &why, staged, "/pinned/mopm", "work", &pa.add_set, "linux-64", RELEASE_MOJO, fake.runner(), &log.writer));
    try t.expectEqualStrings("--work work is not an absolute path", why);
    try t.expectEqual(@as(usize, 0), fake.calls.items.len);
    try t.expect(!exists(&tmp, "work"));
}

test "add: a locked dependency this release did not publish fails, naming it" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stageAdd(a, &tmp);
    const uuid = Pkg{ .name = "komira-ai/uuid", .bytes = "uuid bytes", .deps = &.{ "komira-ai/clock", "komira-ai/awslc", "komira-ai/stray" } };
    var fake = FakeMopm{ .served = try with(a, try with(a, &SERVED, uuid), .{ .name = "komira-ai/stray", .bytes = "not in the plan" }) };
    var log = sink();
    defer log.deinit();
    var why: []const u8 = "";
    try t.expectError(error.Refused, runAdd(a, &tmp, &fake, &why, &log.writer));
    try t.expectEqualStrings("1 problem(s) with what `mopm add` installed from prod:\n  komira-ai/stray 0.1.9: not a member of this release's plan.json", why);
}

test "add on the command line: exit 0 and the summary when the checks pass, 1 and ADD FAILED when one does not" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stageAdd(a, &tmp);
    const args = [_][]const u8{ "--staged", try path(a, &tmp, "committed"), "--mopm", "/pinned/mopm", "--work", try path(a, &tmp, "work"), "--mojo", "1.2.0" };
    var fake = FakeMopm{};
    var out = sink();
    defer out.deinit();
    var err = sink();
    defer err.deinit();
    try t.expectEqual(@as(u8, 0), try rsv.cliAdd(a, &args, "linux-64", fake.runner(), &out.writer, &err.writer));
    try t.expect(std.mem.endsWith(u8, out.written(), "release_staged_verify: `mopm add` of 9 package(s) from https://conda.mopm.dev/ locked 10 package(s) of this release for Mojo 1.2.0 and installed the published bytes (sha256 and size)\n"));
    try t.expectEqualStrings("", err.written());
    try t.expectEqual(@as(usize, 11), fake.calls.items.len);

    var tmp2 = t.tmpDir(.{});
    defer tmp2.cleanup();
    try stageAdd(a, &tmp2);
    const args2 = [_][]const u8{ "--work", try path(a, &tmp2, "work"), "--mopm", "/pinned/mopm", "--mojo", "1.1.0", "--staged", try path(a, &tmp2, "committed") };
    var failing = FakeMopm{ .fail = "init", .code = 3, .stderr = "mopm init: refused\n" };
    var err2 = sink();
    defer err2.deinit();
    try t.expectEqual(@as(u8, 1), try rsv.cliAdd(a, &args2, "linux-64", failing.runner(), &out.writer, &err2.writer));
    try t.expectEqualStrings("release_staged_verify: ADD FAILED: `mopm init --name release-check/prod_add` exited with 3: mopm init: refused\n", err2.written());
}

test "add on the command line: a usage error or a host with no toolchain is exit 2, and mopm never runs" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const Case = struct { args: []const []const u8, subdir: ?[]const u8 = "linux-64", want: []const u8 };
    const usage_text = "usage: release_staged_verify verify --staged <dir> --out <dir>\n";
    const cases = [_]Case{
        .{ .args = &.{ "--staged", "/s", "--mopm", "/m", "--work", "/w", "--mojo", "1.1.0", "--out", "/o" }, .want = "release_staged_verify: unknown argument --out\n" ++ usage_text },
        .{ .args = &.{ "--staged", "/s", "--mopm", "/m", "--work", "/w", "--mojo" }, .want = "release_staged_verify: --mojo needs one value, given once\n" },
        .{ .args = &.{ "--staged", "/s", "--mopm", "/m", "--work" }, .want = "release_staged_verify: --work needs one value, given once\n" },
        .{ .args = &.{ "--staged", "/s", "--staged", "/t", "--mopm", "/m", "--work", "/w", "--mojo", "1.1.0" }, .want = "release_staged_verify: --staged needs one value, given once\n" },
        .{ .args = &.{ "--staged", "/s", "--mopm", "/m", "--work", "/w" }, .want = usage_text },
        .{ .args = &.{ "--staged", "/s", "--work", "/w", "--mojo", "1.1.0" }, .want = usage_text },
        .{ .args = &.{}, .want = usage_text },
        .{ .args = &.{ "--staged", "/s", "--mopm", "/m", "--work", "/w", "--mojo", "1.1.0" }, .subdir = null, .want = "release_staged_verify: mopm installs no Mojo toolchain on this host, so add cannot run here\n" },
    };
    for (cases) |c| {
        var fake = FakeMopm{};
        var out = sink();
        defer out.deinit();
        var err = sink();
        defer err.deinit();
        try t.expectEqual(@as(u8, 2), try rsv.cliAdd(a, c.args, c.subdir, fake.runner(), &out.writer, &err.writer));
        try t.expect(std.mem.startsWith(u8, err.written(), c.want));
        try t.expectEqual(@as(usize, 0), fake.calls.items.len);
        try t.expectEqualStrings("", out.written());
    }
}
