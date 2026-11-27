//! The cases of `release_staged_verify served` (served.zig), against a registry in memory and scratch directories.
//! Each is a way the README e2e after a commit could run on something other than what the registry serves: a file
//! the channel does not serve or serves with another byte, a README the API does not serve, serves for another
//! version or state, or serves with another byte or length, an index that names another registry, a set written
//! when something differed, and a command line that is not one.
const std = @import("std");
const sv = @import("served.zig");
const rbf = @import("release_beta_fetch.zig");
const t = std.testing;

const BYTES_A = "package a bytes";
const BYTES_B = "package b bytes, a little longer";
const FILE_A = "mojo-ns.pa-0.1.9-mojo1.0.0_0.conda";
const FILE_B = "mojo-ns.pb-0.1.9-mojo1.0.0_0.conda";
const README_A = "# pa\n\n```mojo\nfrom pa import x\n```\n";
const README_B = "# pb\n";

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

/// The set `mopm-stage` kept, in `tmp/staged`: the plan, the READMEs and the `.conda` files (never read by `served`;
/// they hold other bytes here, so a test that passes proves the written files are the served ones).
fn stage(a: std.mem.Allocator, tmp: *t.TmpDir) !void {
    try tmp.dir.makePath("staged/linux-64");
    try tmp.dir.makePath("staged/ns/pa");
    try tmp.dir.makePath("staged/ns/pb");
    try tmp.dir.writeFile(.{ .sub_path = "staged/plan.json", .data = try planText(a) });
    try tmp.dir.writeFile(.{ .sub_path = "staged/linux-64/" ++ FILE_A, .data = "not the served bytes" });
    try tmp.dir.writeFile(.{ .sub_path = "staged/ns/pa/README.md", .data = README_A });
    try tmp.dir.writeFile(.{ .sub_path = "staged/ns/pb/README.md", .data = README_B });
}

fn path(a: std.mem.Allocator, tmp: *t.TmpDir, rel: []const u8) ![]u8 {
    const root = try tmp.dir.realpathAlloc(a, ".");
    return std.fs.path.join(a, &.{ root, rel });
}

fn exists(tmp: *t.TmpDir, rel: []const u8) bool {
    tmp.dir.access(rel, .{}) catch return false;
    return true;
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn refusedWith(why: *const []const u8, r: anytype, needle: []const u8) !void {
    if (r) |_| return error.TestExpectedRefusal else |e| {
        try t.expect(e == error.Refused);
        if (!contains(why.*, needle)) {
            std.debug.print("refusal was '{s}', wanted '{s}'\n", .{ why.*, needle });
            return error.TestWrongRefusal;
        }
    }
}

const Route = struct { url: []const u8, got: rbf.Got };

/// A registry in memory: a URL not in the table is HTTP 404. `lag` answers the first n requests other than the index
/// with 404 (a channel and an API whose cache has not caught up with the commit).
const Fake = struct {
    routes: []const Route,
    config_url: []const u8,
    hits: usize = 0,
    other_hits: usize = 0,
    lag: usize = 0,

    fn fetcher(self: *Fake) rbf.Fetcher {
        return .{ .ctx = self, .getFn = get };
    }

    fn get(ctx: *anyopaque, _: std.mem.Allocator, url: []const u8, _: usize) rbf.Got {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.hits += 1;
        if (!std.mem.eql(u8, url, self.config_url)) {
            self.other_hits += 1;
            if (self.other_hits <= self.lag) return .{ .status = 404 };
        }
        for (self.routes) |r| if (std.mem.eql(u8, r.url, url)) return r.got;
        return .{ .status = 404 };
    }
};

fn body(s: []const u8) rbf.Got {
    return .{ .body = @constCast(s) };
}

fn configOf(a: std.mem.Allocator, p: sv.Pins) ![]u8 {
    return std.fmt.allocPrint(a, "{{\"index_version\":1,\"stage\":\"{s}\",\"channel_url\":\"{s}\",\"api_v2_url\":\"{s}\",\"read_only\":false}}", .{ p.stage, p.channel, p.api_v2 });
}

/// A `getVersion` answer for `name` at 0.1.9, published, with `readme` written into the JSON as it is (escape it).
fn detail(a: std.mem.Allocator, name: []const u8, readme_json: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{{\"name\":\"{s}\",\"version\":\"0.1.9\",\"state\":\"published\",\"files\":[],\"readme\":{s},\"readme_html\":null}}", .{ name, readme_json });
}

fn jsonString(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var w = std.Io.Writer.Allocating.init(a);
    try std.json.Stringify.value(s, .{}, &w.writer);
    return w.written();
}

const Registry = struct {
    routes: [5]Route,

    const config = 0;
    const file_a = 1;
    const file_b = 2;
    const version_a = 3;
    const version_b = 4;
};

/// Every route of a registry `p` that serves the plan: the index, both files, both versions with their READMEs.
fn registry(a: std.mem.Allocator, p: sv.Pins) !Registry {
    return .{ .routes = .{
        .{ .url = p.config_url, .got = body(try configOf(a, p)) },
        .{ .url = try std.fmt.allocPrint(a, "{s}ns/linux-64/{s}", .{ p.channel, FILE_A }), .got = body(BYTES_A) },
        .{ .url = try std.fmt.allocPrint(a, "{s}ns/linux-64/{s}", .{ p.channel, FILE_B }), .got = body(BYTES_B) },
        .{ .url = try std.fmt.allocPrint(a, "{s}/packages/ns/pa/0.1.9", .{p.api_v2}), .got = body(try detail(a, "ns/pa", try jsonString(a, README_A))) },
        .{ .url = try std.fmt.allocPrint(a, "{s}/packages/ns/pb/0.1.9", .{p.api_v2}), .got = body(try detail(a, "ns/pb", try jsonString(a, README_B))) },
    } };
}

fn run(a: std.mem.Allocator, tmp: *t.TmpDir, fake: *Fake, p: sv.Pins, attempts: u32, why: *[]const u8, log: *std.Io.Writer) !sv.Report {
    return sv.served(a, t.allocator, why, try path(a, tmp, "staged"), fake.fetcher(), p, try path(a, tmp, "out"), attempts, 0, log);
}

test "served writes the plan, the READMEs and the files each registry serves, after one request for each" {
    for ([_]sv.Pins{ sv.beta, sv.prod }) |p| {
        var ar = std.heap.ArenaAllocator.init(t.allocator);
        defer ar.deinit();
        const a = ar.allocator();
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        try stage(a, &tmp);
        const reg = try registry(a, p);
        var fake = Fake{ .routes = &reg.routes, .config_url = p.config_url };
        var log = std.Io.Writer.Allocating.init(a);
        var why: []const u8 = "";
        const rep = try run(a, &tmp, &fake, p, 3, &why, &log.writer);
        try t.expectEqual(@as(usize, 2), rep.members);
        try t.expectEqual(@as(usize, 2), rep.files);
        try t.expectEqual(@as(usize, 2), rep.readmes);
        // the index, two files, two versions: once each
        try t.expectEqual(@as(usize, 5), fake.hits);
        try t.expectEqualStrings(try planText(a), try tmp.dir.readFileAlloc(a, "out/plan.json", 1 << 16));
        try t.expectEqualStrings(BYTES_A, try tmp.dir.readFileAlloc(a, "out/linux-64/" ++ FILE_A, 1024));
        try t.expectEqualStrings(BYTES_B, try tmp.dir.readFileAlloc(a, "out/linux-64/" ++ FILE_B, 1024));
        try t.expectEqualStrings(README_A, try tmp.dir.readFileAlloc(a, "out/ns/pa/README.md", 1024));
        try t.expectEqualStrings(README_B, try tmp.dir.readFileAlloc(a, "out/ns/pb/README.md", 1024));
        try t.expect(contains(log.written(), "ok readme"));
        try t.expect(contains(log.written(), "ns/pb 0.1.9"));
    }
}

test "served: a member with a build for each of two Mojo versions has both files fetched, checked and written, and the second alone differing refuses" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const first = "mojo-ns.pa-0.1.9-mojo1.1.0_0.conda";
    const second = "mojo-ns.pa-0.1.9-mojo1.2.0_0.conda";
    const bytes_second = "package a, built with the second Mojo";
    const plan = try std.fmt.allocPrint(a,
        \\{{"version":2,"members":[
        \\ {{"name":"ns/pa","version":"0.1.9","action":"upload","readme":"ns/pa/README.md",
        \\   "files":[{{"subdir":"linux-64","filename":"{s}","sha256":"{s}","size":{d}}},
        \\            {{"subdir":"linux-64","filename":"{s}","sha256":"{s}","size":{d}}}]}}
        \\]}}
    , .{ first, try sha(a, BYTES_A), BYTES_A.len, second, try sha(a, bytes_second), bytes_second.len });
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("staged/ns/pa");
    try tmp.dir.writeFile(.{ .sub_path = "staged/plan.json", .data = plan });
    try tmp.dir.writeFile(.{ .sub_path = "staged/ns/pa/README.md", .data = README_A });
    const p = sv.beta;
    var routes = [_]Route{
        .{ .url = p.config_url, .got = body(try configOf(a, p)) },
        .{ .url = try std.fmt.allocPrint(a, "{s}ns/linux-64/{s}", .{ p.channel, first }), .got = body(BYTES_A) },
        .{ .url = try std.fmt.allocPrint(a, "{s}ns/linux-64/{s}", .{ p.channel, second }), .got = body("package a, built with another") },
        .{ .url = try std.fmt.allocPrint(a, "{s}/packages/ns/pa/0.1.9", .{p.api_v2}), .got = body(try detail(a, "ns/pa", try jsonString(a, README_A))) },
    };
    var fake = Fake{ .routes = &routes, .config_url = p.config_url };
    var log = std.Io.Writer.Allocating.init(a);
    var why: []const u8 = "";
    try refusedWith(&why, run(a, &tmp, &fake, p, 1, &why, &log.writer), "the registry beta does not serve what the plan staged: 1 of 2 file(s) and 0 of 1 readme(s) differ:");
    try t.expect(contains(why, second));
    try t.expect(!contains(why, first));
    try t.expect(!exists(&tmp, "out"));
    // served as staged, both builds are written, and the one README once
    routes[2].got = body(bytes_second);
    fake = Fake{ .routes = &routes, .config_url = p.config_url };
    const rep = try run(a, &tmp, &fake, p, 1, &why, &log.writer);
    try t.expectEqual(@as(usize, 1), rep.members);
    try t.expectEqual(@as(usize, 2), rep.files);
    try t.expectEqualStrings(BYTES_A, try tmp.dir.readFileAlloc(a, "out/linux-64/" ++ first, 1024));
    try t.expectEqualStrings(bytes_second, try tmp.dir.readFileAlloc(a, "out/linux-64/" ++ second, 1024));
}

test "served: a file the channel does not serve is named, all differences are reported at once, and nothing is written" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stage(a, &tmp);
    var reg = try registry(a, sv.beta);
    reg.routes[Registry.file_a].got = .{ .status = 404 };
    reg.routes[Registry.version_b].got = body(try detail(a, "ns/pb", "\"# pb changed\\n\""));
    var fake = Fake{ .routes = &reg.routes, .config_url = sv.beta.config_url };
    var log = std.Io.Writer.Allocating.init(a);
    var why: []const u8 = "";
    try refusedWith(&why, run(a, &tmp, &fake, sv.beta, 1, &why, &log.writer), "the registry beta does not serve what the plan staged: 1 of 2 file(s) and 1 of 2 readme(s) differ:");
    try t.expect(contains(why, "ns/pa 0.1.9 linux-64/" ++ FILE_A ++ ": GET https://conda.beta.mopm.dev/ns/linux-64/" ++ FILE_A ++ ": HTTP 404 (not published)"));
    try t.expect(contains(why, "ns/pb 0.1.9 ns/pb/README.md: the served readme is not the plan's"));
    try t.expect(!contains(why, FILE_B));
    try t.expect(!exists(&tmp, "out"));
}

test "served: one changed byte of a served file is a sha256 mismatch naming that file alone" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stage(a, &tmp);
    var reg = try registry(a, sv.prod);
    reg.routes[Registry.file_b].got = body("package b bytes, a little longeR");
    var fake = Fake{ .routes = &reg.routes, .config_url = sv.prod.config_url };
    var log = std.Io.Writer.Allocating.init(a);
    var why: []const u8 = "";
    try refusedWith(&why, run(a, &tmp, &fake, sv.prod, 1, &why, &log.writer), "1 of 2 file(s) and 0 of 2 readme(s) differ");
    try t.expect(contains(why, "ns/pb 0.1.9 linux-64/" ++ FILE_B ++ ": sha256 "));
    try t.expect(!contains(why, FILE_A));
    try t.expect(!exists(&tmp, "out"));
}

test "served: a readme that differs from the plan's is refused with the exact difference, and nothing is written" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stage(a, &tmp);
    var log = std.Io.Writer.Allocating.init(a);
    var why: []const u8 = "";
    const changed = "# pX\n";
    const cases = [_]struct { served: []const u8, at: usize }{
        // one byte, the same length
        .{ .served = changed, .at = 3 },
        // a byte more at the end (a newline the registry added)
        .{ .served = README_B ++ "\n", .at = README_B.len },
        // a byte less at the end (a trailing newline the registry trimmed)
        .{ .served = "# pb", .at = 4 },
        // empty
        .{ .served = "", .at = 0 },
    };
    for (cases) |c| {
        var reg = try registry(a, sv.beta);
        reg.routes[Registry.version_b].got = body(try detail(a, "ns/pb", try jsonString(a, c.served)));
        var fake = Fake{ .routes = &reg.routes, .config_url = sv.beta.config_url };
        try refusedWith(&why, run(a, &tmp, &fake, sv.beta, 1, &why, &log.writer), "0 of 2 file(s) and 1 of 2 readme(s) differ");
        const want = try std.fmt.allocPrint(a, "\n  ns/pb 0.1.9 ns/pb/README.md: the served readme is not the plan's: {d} bytes (sha256 {s}), the plan's {d} bytes (sha256 {s}), first different at byte {d}", .{ c.served.len, try sha(a, c.served), README_B.len, try sha(a, README_B), c.at });
        try t.expect(std.mem.endsWith(u8, why, want));
        try t.expect(!exists(&tmp, "out"));
    }
}

test "served: a readme with quotes, escapes and non-ASCII text is compared as the decoded bytes, not the JSON text" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stage(a, &tmp);
    const text = "# pb \"q\" \\ tab\there é ✓\r\n";
    try tmp.dir.writeFile(.{ .sub_path = "staged/ns/pb/README.md", .data = text });
    var reg = try registry(a, sv.beta);
    // \u escapes, as a registry may write them, decode to the same bytes
    reg.routes[Registry.version_b].got = body(try detail(a, "ns/pb", "\"# pb \\\"q\\\" \\\\ tab\\there \\u00e9 \\u2713\\r\\n\""));
    var fake = Fake{ .routes = &reg.routes, .config_url = sv.beta.config_url };
    var log = std.Io.Writer.Allocating.init(a);
    var why: []const u8 = "";
    _ = try run(a, &tmp, &fake, sv.beta, 1, &why, &log.writer);
    try t.expectEqualStrings(text, try tmp.dir.readFileAlloc(a, "out/ns/pb/README.md", 1024));
}

test "served: a version not served, without a readme, of another version or name, not published, or unreadable is refused by name" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stage(a, &tmp);
    var log = std.Io.Writer.Allocating.init(a);
    var why: []const u8 = "";
    const url = "https://api.beta.mopm.dev/api/v2/packages/ns/pa/0.1.9";
    const cases = [_]struct { got: rbf.Got, want: []const u8 }{
        .{ .got = .{ .status = 404 }, .want = "ns/pa 0.1.9 ns/pa/README.md: GET " ++ url ++ ": HTTP 404 (the version is not served)" },
        .{ .got = body("{\"name\":\"ns/pa\",\"version\":\"0.1.9\",\"state\":\"published\"}"), .want = "ns/pa 0.1.9 ns/pa/README.md: the registry serves no readme for the version" },
        .{ .got = body("{\"name\":\"ns/pa\",\"version\":\"0.1.9\",\"state\":\"published\",\"readme\":null}"), .want = "ns/pa 0.1.9 ns/pa/README.md: the registry serves no readme for the version" },
        .{ .got = body("{\"name\":\"ns/pa\",\"version\":\"0.1.8\",\"state\":\"published\",\"readme\":\"x\"}"), .want = "ns/pa 0.1.9 ns/pa/README.md: GET " ++ url ++ " answers ns/pa 0.1.8, not the plan's member" },
        .{ .got = body("{\"name\":\"ns/pz\",\"version\":\"0.1.9\",\"state\":\"published\",\"readme\":\"x\"}"), .want = "ns/pa 0.1.9 ns/pa/README.md: GET " ++ url ++ " answers ns/pz 0.1.9, not the plan's member" },
        .{ .got = body("{\"name\":\"ns/pa\",\"version\":\"0.1.9\",\"state\":\"yanked\",\"readme\":\"x\"}"), .want = "ns/pa 0.1.9 ns/pa/README.md: the registry serves the version in the state 'yanked', not 'published'" },
        .{ .got = body("{\"name\":"), .want = "ns/pa 0.1.9 ns/pa/README.md: GET " ++ url ++ ": the answer does not parse: " },
        .{ .got = .too_large, .want = "ns/pa 0.1.9 ns/pa/README.md: GET " ++ url ++ ": the body is larger than 1048576 bytes" },
        .{ .got = .bad_url, .want = "ns/pa 0.1.9 ns/pa/README.md: " ++ url ++ " is not a URL this tool fetches" },
        .{ .got = .{ .transport = error.ConnectionResetByPeer }, .want = "ns/pa 0.1.9 ns/pa/README.md: GET " ++ url ++ ": ConnectionResetByPeer" },
    };
    for (cases) |c| {
        var reg = try registry(a, sv.beta);
        reg.routes[Registry.version_a].got = c.got;
        var fake = Fake{ .routes = &reg.routes, .config_url = sv.beta.config_url };
        try refusedWith(&why, run(a, &tmp, &fake, sv.beta, 1, &why, &log.writer), c.want);
        try t.expect(contains(why, "0 of 2 file(s) and 1 of 2 readme(s) differ"));
        try t.expect(!exists(&tmp, "out"));
    }
}

test "served refuses an index of another stage, channel or API root, or none, before anything else is fetched" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stage(a, &tmp);
    var log = std.Io.Writer.Allocating.init(a);
    var why: []const u8 = "";
    const cfg = sv.beta.config_url;
    const cases = [_]struct { got: rbf.Got, want: []const u8 }{
        .{ .got = body("{\"stage\":\"prod\",\"channel_url\":\"https://conda.beta.mopm.dev/\",\"api_v2_url\":\"https://api.beta.mopm.dev/api/v2\"}"), .want = cfg ++ " says stage 'prod', wanted 'beta'" },
        .{ .got = body("{\"stage\":\"beta\",\"channel_url\":\"https://conda.mopm.dev/\",\"api_v2_url\":\"https://api.beta.mopm.dev/api/v2\"}"), .want = cfg ++ ": channel_url 'https://conda.mopm.dev/' is not the pinned channel https://conda.beta.mopm.dev/" },
        .{ .got = body("{\"stage\":\"beta\",\"channel_url\":\"https://conda.beta.mopm.dev/\",\"api_v2_url\":\"https://api.mopm.dev/api/v2\"}"), .want = cfg ++ ": api_v2_url 'https://api.mopm.dev/api/v2' is not the pinned API root https://api.beta.mopm.dev/api/v2" },
        .{ .got = body("{\"stage\":\"beta\",\"channel_url\":\"https://conda.beta.mopm.dev/\"}"), .want = cfg ++ ": api_v2_url '' is not the pinned API root" },
        .{ .got = body("not json"), .want = cfg ++ " does not parse: " },
        .{ .got = .{ .status = 503 }, .want = "GET " ++ cfg ++ ": HTTP 503" },
        .{ .got = .too_large, .want = "GET " ++ cfg ++ ": the body is larger than 65536 bytes" },
    };
    for (cases) |c| {
        var reg = try registry(a, sv.beta);
        reg.routes[Registry.config].got = c.got;
        var fake = Fake{ .routes = &reg.routes, .config_url = cfg };
        try refusedWith(&why, run(a, &tmp, &fake, sv.beta, 1, &why, &log.writer), c.want);
        try t.expectEqual(@as(usize, 1), fake.hits);
        try t.expect(!exists(&tmp, "out"));
    }
}

test "served: a registry that lags the commit passes on a later attempt, and fails naming the difference when the attempts run out" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stage(a, &tmp);
    const reg = try registry(a, sv.prod);
    var log = std.Io.Writer.Allocating.init(a);
    var why: []const u8 = "";
    var stuck = Fake{ .routes = &reg.routes, .config_url = sv.prod.config_url, .lag = 100 };
    try refusedWith(&why, run(a, &tmp, &stuck, sv.prod, 2, &why, &log.writer), "2 of 2 file(s) and 2 of 2 readme(s) differ");
    // two passes of the index, two files and two versions
    try t.expectEqual(@as(usize, 10), stuck.hits);
    try t.expect(!exists(&tmp, "out"));
    // the first pass's four requests are not served yet; the second pass's are
    var lagging = Fake{ .routes = &reg.routes, .config_url = sv.prod.config_url, .lag = 4 };
    _ = try run(a, &tmp, &lagging, sv.prod, 2, &why, &log.writer);
    try t.expect(contains(log.written(), "attempt 1 of 2 failed, trying again: the registry prod does not serve what the plan staged"));
    try t.expectEqualStrings(README_A, try tmp.dir.readFileAlloc(a, "out/ns/pa/README.md", 1024));
    // an index that is refused on every pass is retried too, and its refusal is the last pass's
    var reg2 = try registry(a, sv.prod);
    reg2.routes[Registry.config].got = .{ .status = 502 };
    var down = Fake{ .routes = &reg2.routes, .config_url = sv.prod.config_url };
    var tmp2 = t.tmpDir(.{});
    defer tmp2.cleanup();
    try stage(a, &tmp2);
    try refusedWith(&why, run(a, &tmp2, &down, sv.prod, 3, &why, &log.writer), "GET https://api.mopm.dev/index/config.json: HTTP 502");
    try t.expectEqual(@as(usize, 3), down.hits);
    try t.expect(contains(log.written(), "attempt 2 of 3 failed, trying again: GET https://api.mopm.dev/index/config.json: HTTP 502"));
}

test "served reads the set before any request: no plan.json, a README the set lacks, a used --out, each refused with nothing fetched" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var log = std.Io.Writer.Allocating.init(a);
    var why: []const u8 = "";
    const reg = try registry(a, sv.beta);
    {
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.makePath("staged");
        var fake = Fake{ .routes = &reg.routes, .config_url = sv.beta.config_url };
        try refusedWith(&why, run(a, &tmp, &fake, sv.beta, 1, &why, &log.writer), "plan.json");
        try t.expectEqual(@as(usize, 0), fake.hits);
    }
    {
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        try stage(a, &tmp);
        try tmp.dir.deleteFile("staged/ns/pb/README.md");
        var fake = Fake{ .routes = &reg.routes, .config_url = sv.beta.config_url };
        try refusedWith(&why, run(a, &tmp, &fake, sv.beta, 1, &why, &log.writer), "ns/pb/README.md");
        try t.expectEqual(@as(usize, 0), fake.hits);
    }
    {
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        try stage(a, &tmp);
        try tmp.dir.makePath("out");
        try tmp.dir.writeFile(.{ .sub_path = "out/leftover", .data = "x" });
        var fake = Fake{ .routes = &reg.routes, .config_url = sv.beta.config_url };
        try refusedWith(&why, run(a, &tmp, &fake, sv.beta, 1, &why, &log.writer), "not empty");
        try t.expectEqual(@as(usize, 0), fake.hits);
        // the checked-in BUCK of release/staged_set is the one file kept, and the set is written beside it
        try tmp.dir.deleteFile("out/leftover");
        try tmp.dir.writeFile(.{ .sub_path = "out/BUCK", .data = "# kept\n" });
        _ = try run(a, &tmp, &fake, sv.beta, 1, &why, &log.writer);
        try t.expectEqualStrings("# kept\n", try tmp.dir.readFileAlloc(a, "out/BUCK", 64));
        try t.expect(exists(&tmp, "out/plan.json"));
    }
    {
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        try stage(a, &tmp);
        const skip = "{\"members\":[{\"name\":\"ns/pa\",\"version\":\"0.1.9\",\"action\":\"skip\",\"reason\":\"held\"}]}";
        try tmp.dir.writeFile(.{ .sub_path = "staged/plan.json", .data = skip });
        var fake = Fake{ .routes = &reg.routes, .config_url = sv.beta.config_url };
        try refusedWith(&why, run(a, &tmp, &fake, sv.beta, 1, &why, &log.writer), "not 'upload'");
        try t.expectEqual(@as(usize, 0), fake.hits);
    }
}

test "the pins name each registry's index, channel and API root, and no other stage has any" {
    try t.expectEqualStrings("https://api.beta.mopm.dev/index/config.json", sv.pinsOf("beta").?.config_url);
    try t.expectEqualStrings("https://conda.beta.mopm.dev/", sv.pinsOf("beta").?.channel);
    try t.expectEqualStrings("https://api.beta.mopm.dev/api/v2", sv.pinsOf("beta").?.api_v2);
    try t.expectEqualStrings("https://api.mopm.dev/index/config.json", sv.pinsOf("prod").?.config_url);
    try t.expectEqualStrings("https://conda.mopm.dev/", sv.pinsOf("prod").?.channel);
    try t.expectEqualStrings("https://api.mopm.dev/api/v2", sv.pinsOf("prod").?.api_v2);
    for ([_][]const u8{ "gamma", "Beta", "prod ", "" }) |s| try t.expect(sv.pinsOf(s) == null);
}

test "the first difference of two texts is the first unequal byte, or the shorter length" {
    try t.expectEqual(@as(usize, 0), sv.firstDifference("a", "b"));
    try t.expectEqual(@as(usize, 2), sv.firstDifference("abc", "abd"));
    try t.expectEqual(@as(usize, 3), sv.firstDifference("abc", "abcd"));
    try t.expectEqual(@as(usize, 3), sv.firstDifference("abcd", "abc"));
    try t.expectEqual(@as(usize, 0), sv.firstDifference("", "x"));
    try t.expectEqual(@as(usize, 3), sv.firstDifference("abc", "abc"));
}

test "served on the command line: exit 0 with the summary, 1 with SERVED FAILED and the difference" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try stage(a, &tmp);
    var reg = try registry(a, sv.beta);
    var fake = Fake{ .routes = &reg.routes, .config_url = sv.beta.config_url };
    var out = std.Io.Writer.Allocating.init(a);
    var err = std.Io.Writer.Allocating.init(a);
    const ok_args = [_][]const u8{ "--stage", "beta", "--staged", try path(a, &tmp, "staged"), "--out", try path(a, &tmp, "out"), "--attempts", "1", "--delay", "0" };
    try t.expectEqual(@as(u8, 0), try sv.cliServed(a, t.allocator, &ok_args, fake.fetcher(), &out.writer, &err.writer));
    try t.expect(contains(out.written(), try std.fmt.allocPrint(a, "release_staged_verify: the registry beta serves the 2 file(s) and 2 readme(s) of 2 member(s) as staged (sha256 and size; readmes byte for byte); written to {s}\n", .{try path(a, &tmp, "out")})));
    try t.expectEqualStrings("", err.written());

    reg.routes[Registry.version_a].got = body(try detail(a, "ns/pa", "\"# changed\""));
    var bad = Fake{ .routes = &reg.routes, .config_url = sv.beta.config_url };
    var err2 = std.Io.Writer.Allocating.init(a);
    const bad_args = [_][]const u8{ "--stage", "beta", "--staged", try path(a, &tmp, "staged"), "--out", try path(a, &tmp, "out2"), "--attempts", "1", "--delay", "0" };
    try t.expectEqual(@as(u8, 1), try sv.cliServed(a, t.allocator, &bad_args, bad.fetcher(), &out.writer, &err2.writer));
    try t.expect(std.mem.startsWith(u8, err2.written(), "release_staged_verify: SERVED FAILED: the registry beta does not serve what the plan staged: 0 of 2 file(s) and 1 of 2 readme(s) differ:\n  ns/pa 0.1.9 ns/pa/README.md: the served readme is not the plan's"));
    try t.expect(!exists(&tmp, "out2"));
}

test "served on the command line: every usage error exits 2, naming it, before any request" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const reg = try registry(a, sv.beta);
    var fake = Fake{ .routes = &reg.routes, .config_url = sv.beta.config_url };
    const base = [_][]const u8{ "--stage", "beta", "--staged", "s", "--out", "o" };
    const cases = [_]struct { args: []const []const u8, want: []const u8 }{
        .{ .args = &.{}, .want = sv.usage },
        .{ .args = &.{ "--stage", "beta", "--staged", "s" }, .want = sv.usage },
        .{ .args = &.{ "--staged", "s", "--out", "o" }, .want = sv.usage },
        .{ .args = &.{ "--stage", "beta", "--out", "o" }, .want = sv.usage },
        .{ .args = &(base ++ [_][]const u8{"--config-url"}), .want = "release_staged_verify: unknown argument --config-url\n" ++ sv.usage },
        .{ .args = &(base ++ [_][]const u8{"--attempts"}), .want = "release_staged_verify: --attempts needs one value, given once\n" },
        .{ .args = &(base ++ [_][]const u8{ "--stage", "prod" }), .want = "release_staged_verify: --stage needs one value, given once\n" },
        .{ .args = &.{ "--stage", "gamma", "--staged", "s", "--out", "o" }, .want = "release_staged_verify: --stage is beta or prod, not gamma\n" },
        .{ .args = &(base ++ [_][]const u8{ "--attempts", "0" }), .want = "release_staged_verify: --attempts is a number from 1 to 20\n" },
        .{ .args = &(base ++ [_][]const u8{ "--attempts", "21" }), .want = "release_staged_verify: --attempts is a number from 1 to 20\n" },
        .{ .args = &(base ++ [_][]const u8{ "--attempts", "x" }), .want = "release_staged_verify: --attempts is a number from 1 to 20\n" },
        .{ .args = &(base ++ [_][]const u8{ "--delay", "301" }), .want = "release_staged_verify: --delay is a number of seconds from 0 to 300\n" },
        .{ .args = &(base ++ [_][]const u8{ "--delay", "-1" }), .want = "release_staged_verify: --delay is a number of seconds from 0 to 300\n" },
    };
    for (cases) |c| {
        var out = std.Io.Writer.Allocating.init(a);
        var err = std.Io.Writer.Allocating.init(a);
        try t.expectEqual(@as(u8, 2), try sv.cliServed(a, t.allocator, c.args, fake.fetcher(), &out.writer, &err.writer));
        try t.expectEqualStrings(c.want, err.written());
    }
    try t.expectEqual(@as(usize, 0), fake.hits);
}
