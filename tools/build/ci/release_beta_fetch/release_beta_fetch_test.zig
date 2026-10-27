//! The cases of release_beta_fetch (release_beta_fetch.zig). Each test is a defect the
//! download-and-check that the prod publish shares with this file would otherwise let through: a registry that serves other bytes than were
//! staged, a package that was never published, a plan that cannot be checked, a check that
//! read the staged bytes instead of the published ones, a half-written set, or a client that
//! follows a redirect or talks plain http to the world.
const std = @import("std");
const rbf = @import("release_beta_fetch.zig");
const t = std.testing;

const CONFIG_URL = "https://api.example.test/index/config.json";
const CHANNEL = "https://conda.example.test/";
const CONFIG_OK = "{\"api_url\":\"https://api.example.test/api/v1\",\"channel_url\":\"https://conda.example.test/\",\"stage\":\"beta\"}";

const BYTES_A = "package a bytes";
const BYTES_B = "package b bytes, a little longer";

fn sha(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    const hex = std.fmt.bytesToHex(d, .lower);
    return a.dupe(u8, &hex);
}

fn planText(a: std.mem.Allocator, a_bytes: []const u8, b_bytes: []const u8) ![]u8 {
    return std.fmt.allocPrint(a,
        \\{{"version":1,"members":[
        \\ {{"name":"pa","version":"0.1.9","action":"upload","manifest_sha256":"x","readme":"pa/README.md",
        \\   "files":[{{"subdir":"linux-64","filename":"mojo-pa-0.1.9-mojo1.0.0_0.conda","sha256":"{s}","size":{d}}}]}},
        \\ {{"name":"pb","version":"0.1.9","action":"upload","readme":"pb/README.md",
        \\   "files":[{{"subdir":"linux-64","filename":"mojo-pb-0.1.9-mojo1.0.0_0.conda","sha256":"{s}","size":{d}}}]}}
        \\]}}
    , .{ try sha(a, a_bytes), a_bytes.len, try sha(a, b_bytes), b_bytes.len });
}

const Route = struct { url: []const u8, got: rbf.Got };

/// A registry in memory: a URL not in the table is HTTP 404.
const Fake = struct {
    routes: []const Route,
    hits: usize = 0,

    fn fetcher(self: *Fake) rbf.Fetcher {
        return .{ .ctx = self, .getFn = get };
    }

    fn get(ctx: *anyopaque, _: std.mem.Allocator, url: []const u8, _: usize) rbf.Got {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.hits += 1;
        for (self.routes) |r| if (std.mem.eql(u8, r.url, url)) return r.got;
        return .{ .status = 404 };
    }
};

const URL_A = CHANNEL ++ "linux-64/mojo-pa-0.1.9-mojo1.0.0_0.conda";
const URL_B = CHANNEL ++ "linux-64/mojo-pb-0.1.9-mojo1.0.0_0.conda";

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(t.allocator);
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

fn parseRefused(plan: []const u8, needle: []const u8) !void {
    var ar = arena();
    defer ar.deinit();
    var why: []const u8 = "";
    try refusedWith(&why, parsePlanWhy(ar.allocator(), &why, plan), needle);
}

fn parsePlanWhy(a: std.mem.Allocator, why: *[]const u8, plan: []const u8) rbf.Error!rbf.Plan {
    return rbf.parsePlan(a, why, plan);
}

// ---- the plan ---------------------------------------------------------------------------

test "a plan of uploads with a file and a README each is read" {
    var ar = arena();
    defer ar.deinit();
    var why: []const u8 = "";
    const plan = try rbf.parsePlan(ar.allocator(), &why, try planText(ar.allocator(), BYTES_A, BYTES_B));
    try t.expectEqual(@as(usize, 2), plan.members.len);
    try t.expectEqualStrings("0.1.9", plan.members[1].version);
    try t.expectEqual(@as(u64, BYTES_B.len), plan.members[1].files[0].size);
}

test "a plan that cannot be checked is refused, naming why" {
    const f = "\"files\":[{\"subdir\":\"linux-64\",\"filename\":\"f.conda\",\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"size\":1}]";
    try parseRefused("not json", "does not parse");
    try parseRefused("{\"members\":[]}", "no member");
    try parseRefused("{\"members\":[{\"name\":\"p\",\"version\":\"0.1.1\",\"action\":\"skip\",\"readme\":\"p/README.md\"," ++ f ++ "}]}", "not 'upload'");
    try parseRefused("{\"members\":[{\"name\":\"p\",\"version\":\"0.1.1\",\"action\":\"refuse\",\"readme\":\"p/README.md\"," ++ f ++ "}]}", "not 'upload'");
    try parseRefused("{\"members\":[{\"name\":\"p\",\"version\":\"0.1.1\",\"action\":\"upload\",\"readme\":\"p/README.md\"}]}", "no file");
    try parseRefused("{\"members\":[{\"name\":\"p\",\"version\":\"0.1.1\",\"action\":\"upload\"," ++ f ++ "}]}", "no readme");
    try parseRefused("{\"members\":[{\"name\":\"p\",\"version\":\"\",\"action\":\"upload\",\"readme\":\"p/README.md\"," ++ f ++ "}]}", "no version");
    try parseRefused("{\"members\":[{\"name\":\"p\",\"version\":\"0.1.1\",\"action\":\"upload\",\"readme\":\"../README.md\"," ++ f ++ "}]}", "leaves the set");
    try parseRefused("{\"members\":[{\"name\":\"p\",\"version\":\"0.1.1\",\"action\":\"upload\",\"readme\":\"/etc/passwd\"," ++ f ++ "}]}", "leaves the set");
    try parseRefused("{\"members\":[{\"name\":\"..\",\"version\":\"0.1.1\",\"action\":\"upload\",\"readme\":\"p/README.md\"," ++ f ++ "}]}", "plain name");
    try parseRefused("{\"members\":[{\"name\":\"p\",\"version\":\"0.1.1\",\"action\":\"upload\",\"readme\":\"p/README.md\",\"files\":[{\"subdir\":\"linux-64\",\"filename\":\"../x.conda\",\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"size\":1}]}]}", "plain subdir");
    try parseRefused("{\"members\":[{\"name\":\"p\",\"version\":\"0.1.1\",\"action\":\"upload\",\"readme\":\"p/README.md\",\"files\":[{\"subdir\":\"linux-64\",\"filename\":\"f.conda\",\"sha256\":\"ABC\",\"size\":1}]}]}", "64 lowercase hex");
    try parseRefused("{\"members\":[{\"name\":\"p\",\"version\":\"0.1.1\",\"action\":\"upload\",\"readme\":\"p/README.md\",\"files\":[{\"subdir\":\"linux-64\",\"filename\":\"f.conda\",\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"size\":1},{\"subdir\":\"linux-64\",\"filename\":\"f.conda\",\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"size\":1}]}]}", "listed twice");
    const m = "{\"name\":\"p\",\"version\":\"0.1.1\",\"action\":\"upload\",\"readme\":\"p/README.md\"," ++ f ++ "}";
    try parseRefused("{\"members\":[" ++ m ++ "," ++ m ++ "]}", "listed twice");
    try parseRefused("{\"members\":[" ++ m ++ ",{\"name\":\"q\",\"version\":\"0.1.1\",\"action\":\"upload\",\"readme\":\"q/README.md\"," ++ f ++ "}]}", "is a file of");
}

// ---- the channel ------------------------------------------------------------------------

fn channel(config: rbf.Got, stage: []const u8) !void {
    var ar = arena();
    defer ar.deinit();
    var fake = Fake{ .routes = &.{.{ .url = CONFIG_URL, .got = config }} };
    var why: []const u8 = "";
    const got = rbf.channelOf(ar.allocator(), &why, fake.fetcher(), CONFIG_URL, stage, null);
    if (got) |c| {
        try t.expectEqualStrings(CHANNEL, c);
    } else |_| return error.Refused;
}

fn channelRefused(config: rbf.Got, stage: []const u8, needle: []const u8) !void {
    var ar = arena();
    defer ar.deinit();
    var fake = Fake{ .routes = &.{.{ .url = CONFIG_URL, .got = config }} };
    var why: []const u8 = "";
    try refusedWith(&why, rbf.channelOf(ar.allocator(), &why, fake.fetcher(), CONFIG_URL, stage, null), needle);
}

test "the channel is the one the beta index names" {
    try channel(.{ .body = @constCast(CONFIG_OK) }, "beta");
}

test "a channel_url without its closing slash gets one" {
    var ar = arena();
    defer ar.deinit();
    var fake = Fake{ .routes = &.{.{ .url = CONFIG_URL, .got = .{ .body = @constCast("{\"channel_url\":\"https://c.example.test/x\",\"stage\":\"beta\"}") } }} };
    var why: []const u8 = "";
    try t.expectEqualStrings("https://c.example.test/x/", try rbf.channelOf(ar.allocator(), &why, fake.fetcher(), CONFIG_URL, "beta", null));
}

test "an index of another stage is refused: a beta check cannot read prod" {
    try channelRefused(.{ .body = @constCast(CONFIG_OK) }, "prod", "says stage 'beta', wanted 'prod'");
    try channelRefused(.{ .body = @constCast("{\"channel_url\":\"https://c.example.test/\"}") }, "beta", "says stage ''");
}

test "an index that is unreachable, empty of a channel or not https is refused" {
    try channelRefused(.{ .status = 503 }, "beta", "HTTP 503");
    try channelRefused(.{ .transport = error.ConnectionRefused }, "beta", "ConnectionRefused");
    try channelRefused(.too_large, "beta", "larger than");
    try channelRefused(.bad_url, "beta", "not an https URL");
    try channelRefused(.{ .body = @constCast("{\"stage\":\"beta\"}") }, "beta", "channel_url ''");
    try channelRefused(.{ .body = @constCast("{\"channel_url\":\"http://c.example.test/\",\"stage\":\"beta\"}") }, "beta", "not an https URL");
    try channelRefused(.{ .body = @constCast("{\"channel_url\":\"https://u@c.example.test/\",\"stage\":\"beta\"}") }, "beta", "not an https URL");
    try channelRefused(.{ .body = @constCast("[1]") }, "beta", "does not parse");
}

// ---- the files --------------------------------------------------------------------------

/// Runs `checkFiles` over the two-member plan against `routes`; returns the failures.
fn check(ar: std.mem.Allocator, routes: []const Route, plan_a: []const u8, plan_b: []const u8) !rbf.Outcome {
    var why: []const u8 = "";
    const plan = try rbf.parsePlan(ar, &why, try planText(ar, plan_a, plan_b));
    var fake = Fake{ .routes = routes };
    var sink = std.Io.Writer.Allocating.init(ar);
    return rbf.checkFiles(ar, plan, fake.fetcher(), CHANNEL, &sink.writer);
}

fn mentionsOne(lines: []const []const u8, needle: []const u8) !void {
    var n: usize = 0;
    for (lines) |l| {
        if (std.mem.indexOf(u8, l, needle) != null) n += 1;
    }
    if (n != 1) {
        std.debug.print("{d} failure line(s) mention '{s}':\n", .{ n, needle });
        for (lines) |l| std.debug.print("  {s}\n", .{l});
        return error.TestWrongFailures;
    }
}

test "files that are the staged bytes pass, and are kept for the set" {
    var ar = arena();
    defer ar.deinit();
    const o = try check(ar.allocator(), &.{ .{ .url = URL_A, .got = .{ .body = @constCast(BYTES_A) } }, .{ .url = URL_B, .got = .{ .body = @constCast(BYTES_B) } } }, BYTES_A, BYTES_B);
    try t.expectEqual(@as(usize, 0), o.failures.len);
    try t.expectEqual(@as(usize, 2), o.checked.len);
    try t.expectEqualStrings(BYTES_B, o.checked[1].bytes);
}

test "one altered byte of the same size is a sha256 mismatch, and only that file is reported" {
    var ar = arena();
    defer ar.deinit();
    const o = try check(ar.allocator(), &.{ .{ .url = URL_A, .got = .{ .body = @constCast("package a bytez") } }, .{ .url = URL_B, .got = .{ .body = @constCast(BYTES_B) } } }, BYTES_A, BYTES_B);
    try t.expectEqual(@as(usize, 1), o.failures.len);
    try mentionsOne(o.failures, "pa 0.1.9 linux-64/mojo-pa-0.1.9-mojo1.0.0_0.conda: sha256");
    try t.expectEqual(@as(usize, 1), o.checked.len);
}

test "a published file of another size is a size mismatch (and a hash one)" {
    var ar = arena();
    defer ar.deinit();
    const o = try check(ar.allocator(), &.{ .{ .url = URL_A, .got = .{ .body = @constCast("short") } }, .{ .url = URL_B, .got = .{ .body = @constCast(BYTES_B) } } }, BYTES_A, BYTES_B);
    try mentionsOne(o.failures, "size 5, the plan says 15");
    try mentionsOne(o.failures, "sha256");
}

test "a plan whose size is wrong for the right bytes is a size mismatch alone" {
    var ar = arena();
    defer ar.deinit();
    var why: []const u8 = "";
    const text = try std.mem.replaceOwned(u8, ar.allocator(), try planText(ar.allocator(), BYTES_A, BYTES_B), "\"size\":15}", "\"size\":16}");
    const plan = try rbf.parsePlan(ar.allocator(), &why, text);
    var fake = Fake{ .routes = &.{ .{ .url = URL_A, .got = .{ .body = @constCast(BYTES_A) } }, .{ .url = URL_B, .got = .{ .body = @constCast(BYTES_B) } } } };
    var sink = std.Io.Writer.Allocating.init(ar.allocator());
    const o = try rbf.checkFiles(ar.allocator(), plan, fake.fetcher(), CHANNEL, &sink.writer);
    try t.expectEqual(@as(usize, 1), o.failures.len);
    try mentionsOne(o.failures, "size 15, the plan says 16");
}

test "a package the registry does not hold is reported as not published" {
    var ar = arena();
    defer ar.deinit();
    const o = try check(ar.allocator(), &.{.{ .url = URL_B, .got = .{ .body = @constCast(BYTES_B) } }}, BYTES_A, BYTES_B);
    try t.expectEqual(@as(usize, 1), o.failures.len);
    try mentionsOne(o.failures, "HTTP 404 (not published)");
}

test "every failure is reported, not the first" {
    var ar = arena();
    defer ar.deinit();
    const o = try check(ar.allocator(), &.{ .{ .url = URL_A, .got = .too_large }, .{ .url = URL_B, .got = .{ .transport = error.TruncatedBody } } }, BYTES_A, BYTES_B);
    try t.expectEqual(@as(usize, 2), o.failures.len);
    try mentionsOne(o.failures, "more than the plan's 15 bytes");
    try mentionsOne(o.failures, "TruncatedBody");
    try t.expectEqual(@as(usize, 0), o.checked.len);
}

// ---- the whole job, on disk -------------------------------------------------------------

const Scene = struct {
    tmp: std.testing.TmpDir,
    staged: []const u8,
    out: []const u8,

    fn init(a: std.mem.Allocator, plan: []const u8) !Scene {
        var tmp = std.testing.tmpDir(.{});
        const root = try tmp.dir.realpathAlloc(a, ".");
        try tmp.dir.makePath("staged/pa");
        try tmp.dir.makePath("staged/pb");
        try tmp.dir.writeFile(.{ .sub_path = "staged/plan.json", .data = plan });
        try tmp.dir.writeFile(.{ .sub_path = "staged/pa/README.md", .data = "readme a\n" });
        try tmp.dir.writeFile(.{ .sub_path = "staged/pb/README.md", .data = "readme b\n" });
        return .{ .tmp = tmp, .staged = try std.fs.path.join(a, &.{ root, "staged" }), .out = try std.fs.path.join(a, &.{ root, "out" }) };
    }

    fn read(self: *Scene, a: std.mem.Allocator, rel: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(a, rel, 1 << 20);
    }

    fn outExists(self: *Scene) bool {
        self.tmp.dir.access("out", .{}) catch return false;
        return true;
    }
};

fn runScene(a: std.mem.Allocator, s: *Scene, fake: *Fake, why: *[]const u8) !rbf.Report {
    var sink = std.Io.Writer.Allocating.init(a);
    return rbf.run(a, why, s.staged, fake.fetcher(), CONFIG_URL, "beta", null, s.out, &sink.writer);
}

fn goodRoutes() [3]Route {
    return .{
        .{ .url = CONFIG_URL, .got = .{ .body = @constCast(CONFIG_OK) } },
        .{ .url = URL_A, .got = .{ .body = @constCast(BYTES_A) } },
        .{ .url = URL_B, .got = .{ .body = @constCast(BYTES_B) } },
    };
}

test "the set written is the plan, the READMEs and the published bytes" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const plan = try planText(a, BYTES_A, BYTES_B);
    var s = try Scene.init(a, plan);
    defer s.tmp.cleanup();
    // a staged .conda is in the staged directory and is never what is written
    try s.tmp.dir.makePath("staged/linux-64");
    try s.tmp.dir.writeFile(.{ .sub_path = "staged/linux-64/mojo-pa-0.1.9-mojo1.0.0_0.conda", .data = "STAGED COPY, NOT PUBLISHED" });
    const routes = goodRoutes();
    var fake = Fake{ .routes = &routes };
    var why: []const u8 = "";
    const rep = try runScene(a, &s, &fake, &why);
    try t.expectEqual(@as(usize, 2), rep.members);
    try t.expectEqual(@as(usize, 2), rep.files);
    try t.expectEqualStrings(plan, try s.read(a, "out/plan.json"));
    try t.expectEqualStrings("readme a\n", try s.read(a, "out/pa/README.md"));
    try t.expectEqualStrings("readme b\n", try s.read(a, "out/pb/README.md"));
    try t.expectEqualStrings(BYTES_A, try s.read(a, "out/linux-64/mojo-pa-0.1.9-mojo1.0.0_0.conda"));
    try t.expectEqualStrings(BYTES_B, try s.read(a, "out/linux-64/mojo-pb-0.1.9-mojo1.0.0_0.conda"));
}

test "a mismatch fails the run, names the file and writes nothing" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var s = try Scene.init(a, try planText(a, BYTES_A, BYTES_B));
    defer s.tmp.cleanup();
    var routes = goodRoutes();
    routes[2].got = .{ .body = @constCast("package b bytes, a little longez") };
    var fake = Fake{ .routes = &routes };
    var why: []const u8 = "";
    try refusedWith(&why, runScene(a, &s, &fake, &why), "1 of 2 file(s) are not what the plan staged");
    try t.expect(std.mem.indexOf(u8, why, "pb 0.1.9") != null);
    try t.expect(!s.outExists());
}

test "a plan a member of which was skipped is refused before any request is made" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const plan = try std.mem.replaceOwned(u8, a, try planText(a, BYTES_A, BYTES_B), "\"upload\",\"readme\":\"pb", "\"skip\",\"readme\":\"pb");
    var s = try Scene.init(a, plan);
    defer s.tmp.cleanup();
    const routes = goodRoutes();
    var fake = Fake{ .routes = &routes };
    var why: []const u8 = "";
    try refusedWith(&why, runScene(a, &s, &fake, &why), "not 'upload'");
    try t.expectEqual(@as(usize, 0), fake.hits);
}

test "a missing README or plan fails the run and writes nothing" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var s = try Scene.init(a, try planText(a, BYTES_A, BYTES_B));
    defer s.tmp.cleanup();
    try s.tmp.dir.deleteFile("staged/pb/README.md");
    const routes = goodRoutes();
    var fake = Fake{ .routes = &routes };
    var why: []const u8 = "";
    try refusedWith(&why, runScene(a, &s, &fake, &why), "pb/README.md");
    try t.expect(!s.outExists());
    try s.tmp.dir.deleteFile("staged/plan.json");
    try refusedWith(&why, runScene(a, &s, &fake, &why), "plan.json");
}

test "an --out that holds something is refused, and an empty one is used" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var s = try Scene.init(a, try planText(a, BYTES_A, BYTES_B));
    defer s.tmp.cleanup();
    try s.tmp.dir.makePath("out");
    try s.tmp.dir.writeFile(.{ .sub_path = "out/old", .data = "x" });
    const routes = goodRoutes();
    var fake = Fake{ .routes = &routes };
    var why: []const u8 = "";
    try refusedWith(&why, runScene(a, &s, &fake, &why), "is not empty");
    try s.tmp.dir.deleteFile("out/old");
    _ = try runScene(a, &s, &fake, &why);
}

test "a registry of the wrong stage stops the run before any package is fetched" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var s = try Scene.init(a, try planText(a, BYTES_A, BYTES_B));
    defer s.tmp.cleanup();
    var routes = goodRoutes();
    routes[0].got = .{ .body = @constCast("{\"channel_url\":\"https://conda.example.test/\",\"stage\":\"prod\"}") };
    var fake = Fake{ .routes = &routes };
    var why: []const u8 = "";
    try refusedWith(&why, runScene(a, &s, &fake, &why), "wanted 'beta'");
    try t.expectEqual(@as(usize, 1), fake.hits);
}

// ---- the real client, against a socket on loopback --------------------------------------

const Served = struct {
    path: []const u8,
    status: u16 = 200,
    body: []const u8 = "",
    location: ?[]const u8 = null,
    /// Promise this many bytes and send `body` only.
    claim: ?usize = null,
};

const Loopback = struct {
    server: std.net.Server,
    thread: std.Thread = undefined,
    served: []const Served,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    port: u16 = 0,

    fn start(a: std.mem.Allocator, served: []const Served) !*Loopback {
        const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
        const self = try a.create(Loopback);
        self.* = .{ .server = try addr.listen(.{ .reuse_address = true }), .served = served };
        self.port = self.server.listen_address.getPort();
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    fn stop(self: *Loopback) void {
        self.stopping.store(true, .release);
        if (std.net.tcpConnectToAddress(self.server.listen_address)) |c| c.close() else |_| {}
        self.thread.join();
        self.server.deinit();
    }

    fn url(self: *Loopback, a: std.mem.Allocator, path: []const u8) ![]u8 {
        return std.fmt.allocPrint(a, "http://127.0.0.1:{d}{s}", .{ self.port, path });
    }

    fn serve(self: *Loopback) void {
        while (!self.stopping.load(.acquire)) {
            const conn = self.server.accept() catch continue;
            defer conn.stream.close();
            if (self.stopping.load(.acquire)) return;
            var rbuf: [8192]u8 = undefined;
            var wbuf: [1024]u8 = undefined;
            var reader = conn.stream.reader(&rbuf);
            var writer = conn.stream.writer(&wbuf);
            const w = &writer.interface;
            var srv = std.http.Server.init(reader.interface(), w);
            const req = srv.receiveHead() catch continue;
            var hit: ?Served = null;
            for (self.served) |r| if (std.mem.eql(u8, r.path, req.head.target)) {
                hit = r;
            };
            var head: [512]u8 = undefined;
            if (hit) |r| {
                const text = std.fmt.bufPrint(&head, "HTTP/1.1 {d} X\r\nContent-Length: {d}\r\nConnection: close\r\n{s}{s}{s}\r\n", .{
                    r.status,
                    r.claim orelse r.body.len,
                    if (r.location != null) "Location: " else "",
                    r.location orelse "",
                    if (r.location != null) "\r\n" else "",
                }) catch continue;
                w.writeAll(text) catch continue;
                w.writeAll(r.body) catch continue;
            } else {
                w.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch continue;
            }
            w.flush() catch continue;
        }
    }
};

fn httpGet(a: std.mem.Allocator, srv: *Loopback, path: []const u8, max: usize) !rbf.Got {
    var http = rbf.Http{ .allow_loopback = true };
    return http.fetcher().get(a, try srv.url(a, path), max);
}

test "the client reads a body, reports a status, a redirect it does not follow, a short body and a long one" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const srv = try Loopback.start(a, &.{
        .{ .path = "/ok", .body = "hello bytes" },
        .{ .path = "/moved", .status = 302, .location = "/ok" },
        .{ .path = "/short", .body = "abc", .claim = 10 },
        .{ .path = "/empty" },
    });
    defer srv.stop();
    switch (try httpGet(a, srv, "/ok", 1000)) {
        .body => |b| try t.expectEqualStrings("hello bytes", b),
        else => return error.TestWrongResult,
    }
    switch (try httpGet(a, srv, "/empty", 1000)) {
        .body => |b| try t.expectEqual(@as(usize, 0), b.len),
        else => return error.TestWrongResult,
    }
    switch (try httpGet(a, srv, "/absent", 1000)) {
        .status => |s| try t.expectEqual(@as(u16, 404), s),
        else => return error.TestWrongResult,
    }
    switch (try httpGet(a, srv, "/moved", 1000)) {
        .status => |s| try t.expectEqual(@as(u16, 302), s),
        else => return error.TestWrongResult,
    }
    switch (try httpGet(a, srv, "/short", 1000)) {
        .transport => {},
        else => return error.TestWrongResult,
    }
    switch (try httpGet(a, srv, "/ok", 10)) {
        .too_large => {},
        else => return error.TestWrongResult,
    }
    // the exact size is allowed
    switch (try httpGet(a, srv, "/ok", 11)) {
        .body => {},
        else => return error.TestWrongResult,
    }
}

test "the job over the real client: published bytes pass, one altered byte fails" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var served = [_]Served{
        .{ .path = "/index/config.json", .body = "" },
        .{ .path = "/linux-64/mojo-pa-0.1.9-mojo1.0.0_0.conda", .body = BYTES_A },
        .{ .path = "/linux-64/mojo-pb-0.1.9-mojo1.0.0_0.conda", .body = BYTES_B },
    };
    const srv = try Loopback.start(a, &served);
    defer srv.stop();
    served[0].body = try std.fmt.allocPrint(a, "{{\"channel_url\":\"http://127.0.0.1:{d}/\",\"stage\":\"beta\"}}", .{srv.port});

    // http to loopback is a test-only allowance: the production policy refuses the channel
    var strict = rbf.Http{};
    var why: []const u8 = "";
    const plan = try rbf.parsePlan(a, &why, try planText(a, BYTES_A, BYTES_B));
    var sink = std.Io.Writer.Allocating.init(a);
    const refused = try rbf.checkFiles(a, plan, strict.fetcher(), try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/", .{srv.port}), &sink.writer);
    try t.expectEqual(@as(usize, 2), refused.failures.len);
    try mentionsOne(refused.failures, "mojo-pa-0.1.9-mojo1.0.0_0.conda: http://127.0.0.1");

    var http = rbf.Http{ .allow_loopback = true };
    const channel_url = try rbf.channelOf(a, &why, http.fetcher(), try srv.url(a, "/index/config.json"), "beta", null);
    const good = try rbf.checkFiles(a, plan, http.fetcher(), channel_url, &sink.writer);
    try t.expectEqual(@as(usize, 0), good.failures.len);
    try t.expectEqual(@as(usize, 2), good.checked.len);

    served[2].body = "package b bytes, a little longez";
    const bad = try rbf.checkFiles(a, plan, http.fetcher(), channel_url, &sink.writer);
    try t.expectEqual(@as(usize, 1), bad.checked.len);
    try mentionsOne(bad.failures, "pb 0.1.9");
}

test "which URLs the client fetches" {
    try t.expect(rbf.urlAllowed("https://conda.beta.mopm.dev/", false));
    try t.expect(!rbf.urlAllowed("http://conda.beta.mopm.dev/", false));
    try t.expect(!rbf.urlAllowed("http://conda.beta.mopm.dev/", true));
    try t.expect(!rbf.urlAllowed("http://127.0.0.1:80/x", false));
    try t.expect(rbf.urlAllowed("http://127.0.0.1:80/x", true));
    try t.expect(!rbf.urlAllowed("http://127.0.0.1.evil.test/x", true));
    try t.expect(!rbf.urlAllowed("https://user@host.test/", false));
    try t.expect(!rbf.urlAllowed("https:///x", false));
    try t.expect(!rbf.urlAllowed("ftp://host.test/", false));
    try t.expect(!rbf.urlAllowed("", false));
}

// ---- round 2: collisions, pinned channel, size cap, atomic write, file counts ------------

const ZERO = "0000000000000000000000000000000000000000000000000000000000000000";

fn memberJson(a: std.mem.Allocator, name: []const u8, readme: []const u8, subdir: []const u8, filename: []const u8, size: u64) ![]u8 {
    return std.fmt.allocPrint(a, "{{\"name\":\"{s}\",\"version\":\"0.1.1\",\"action\":\"upload\",\"readme\":\"{s}\",\"files\":[{{\"subdir\":\"{s}\",\"filename\":\"{s}\",\"sha256\":\"{s}\",\"size\":{d}}}]}}", .{ name, readme, subdir, filename, ZERO, size });
}

fn planOf(a: std.mem.Allocator, members: []const []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{{\"members\":[{s}]}}", .{try std.mem.join(a, ",", members)});
}

test "paths of the set that collide are refused: a README on a subdir, on plan.json, on another README or file, in any letter case" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const f = "x.conda";
    // a README whose path is the directory of the packages
    try parseRefused(try planOf(a, &.{try memberJson(a, "p", "linux-64", "linux-64", f, 1)}), "collide");
    // a README under a name that is a file
    try parseRefused(try planOf(a, &.{try memberJson(a, "p", "linux-64/x.conda/README.md", "linux-64", f, 1)}), "collide");
    // a README that is plan.json
    try parseRefused(try planOf(a, &.{try memberJson(a, "p", "plan.json", "linux-64", f, 1)}), "collide");
    try parseRefused(try planOf(a, &.{try memberJson(a, "p", "PLAN.json", "linux-64", f, 1)}), "collide");
    // two members, one README
    try parseRefused(try planOf(a, &.{ try memberJson(a, "p", "r/README.md", "linux-64", "a.conda", 1), try memberJson(a, "q", "r/README.md", "linux-64", "b.conda", 1) }), "collide");
    // case variants of one file, of one README, of one member
    try parseRefused(try planOf(a, &.{ try memberJson(a, "p", "p/README.md", "linux-64", "a.conda", 1), try memberJson(a, "q", "q/README.md", "linux-64", "A.CONDA", 1) }), "collide");
    try parseRefused(try planOf(a, &.{ try memberJson(a, "p", "p/README.md", "linux-64", "a.conda", 1), try memberJson(a, "q", "P/readme.md", "linux-64", "b.conda", 1) }), "collide");
    try parseRefused(try planOf(a, &.{ try memberJson(a, "p", "p/README.md", "linux-64", "a.conda", 1), try memberJson(a, "P", "r/README.md", "linux-64", "b.conda", 1) }), "listed twice");
    // a directory named like a file of another subdir is fine
    var why: []const u8 = "";
    _ = try rbf.parsePlan(a, &why, try planOf(a, &.{ try memberJson(a, "p", "p/README.md", "linux-64", "a.conda", 1), try memberJson(a, "q", "q/README.md", "noarch", "a.conda", 1) }));
}

test "a file size above the cap is refused before any request" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";
    _ = try rbf.parsePlan(a, &why, try planOf(a, &.{try memberJson(a, "p", "p/README.md", "linux-64", "a.conda", rbf.max_file_bytes)}));
    try parseRefused(try planOf(a, &.{try memberJson(a, "p", "p/README.md", "linux-64", "a.conda", rbf.max_file_bytes + 1)}), "cap");
    try parseRefused(try planOf(a, &.{try memberJson(a, "p", "p/README.md", "linux-64", "a.conda", 1099511627776)}), "cap");
}

test "the beta channel is pinned to one URL: another host or path is refused, the exact one is used" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";
    const pin = rbf.beta_channel;
    try t.expectEqualStrings("https://conda.beta.mopm.dev/", pin);
    const route = struct {
        fn of(body: []const u8) Route {
            return .{ .url = CONFIG_URL, .got = .{ .body = @constCast(body) } };
        }
    };
    var ok = Fake{ .routes = &.{route.of("{\"channel_url\":\"https://conda.beta.mopm.dev/\",\"stage\":\"beta\"}")} };
    try t.expectEqualStrings(pin, try rbf.channelOf(a, &why, ok.fetcher(), CONFIG_URL, "beta", pin));
    const bad = [_][]const u8{
        "{\"channel_url\":\"https://conda.mopm.dev/\",\"stage\":\"beta\"}",
        "{\"channel_url\":\"https://conda.beta.mopm.dev.evil.test/\",\"stage\":\"beta\"}",
        "{\"channel_url\":\"https://evil.test/\",\"stage\":\"beta\"}",
        "{\"channel_url\":\"https://conda.beta.mopm.dev/x/\",\"stage\":\"beta\"}",
        "{\"channel_url\":\"https://conda.beta.mopm.dev\",\"stage\":\"beta\"}",
        "{\"channel_url\":\"http://conda.beta.mopm.dev/\",\"stage\":\"beta\"}",
        "{\"channel_url\":\"https://CONDA.beta.mopm.dev/\",\"stage\":\"beta\"}",
    };
    for (bad) |body| {
        var fk = Fake{ .routes = &.{route.of(body)} };
        try refusedWith(&why, rbf.channelOf(a, &why, fk.fetcher(), CONFIG_URL, "beta", pin), "is not the pinned channel");
    }
}

test "a write that fails midway leaves no --out and no partial directory, and says why" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    const out = try std.fs.path.join(a, &.{ root, "out" });
    var why: []const u8 = "";
    const entries = [_]rbf.Entry{
        .{ .rel = "plan.json", .data = "{}" },
        .{ .rel = "linux-64/a.conda", .data = "bytes" },
        .{ .rel = "plan.json/inside", .data = "x" },
    };
    try refusedWith(&why, rbf.writeSet(a, &why, out, &entries), "cannot write");
    try t.expect(why.len != 0);
    var n: usize = 0;
    var d1 = try tmp.dir.openDir(".", .{ .iterate = true });
    defer d1.close();
    var it = d1.iterate();
    while (try it.next()) |_| n += 1;
    try t.expectEqual(@as(usize, 0), n);
    // the same entries without the one under a file are written whole, and an empty --out is replaced
    try tmp.dir.makePath("out");
    try rbf.writeSet(a, &why, out, entries[0..2]);
    try t.expectEqualStrings("bytes", try tmp.dir.readFileAlloc(a, "out/linux-64/a.conda", 100));
    var m: usize = 0;
    var d2 = try tmp.dir.openDir(".", .{ .iterate = true });
    defer d2.close();
    var it2 = d2.iterate();
    while (try it2.next()) |_| m += 1;
    try t.expectEqual(@as(usize, 1), m);
}

test "the summary counts files, not lines: one file with a wrong size and hash is 1 of 2" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var s = try Scene.init(a, try planText(a, BYTES_A, BYTES_B));
    defer s.tmp.cleanup();
    var routes = goodRoutes();
    routes[2].got = .{ .body = @constCast("short") };
    var fake = Fake{ .routes = &routes };
    var why: []const u8 = "";
    try refusedWith(&why, runScene(a, &s, &fake, &why), "1 of 2 file(s) are not what the plan staged");
}

// ---- the checkout state of release/staged_set: --out exists and holds its BUCK ------------------

test "an --out that holds only its BUCK is written beside it, and the BUCK is kept" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var s = try Scene.init(a, try planText(a, BYTES_A, BYTES_B));
    defer s.tmp.cleanup();
    try s.tmp.dir.makePath("out");
    try s.tmp.dir.writeFile(.{ .sub_path = "out/BUCK", .data = "filegroup()\n" });
    const routes = goodRoutes();
    var fake = Fake{ .routes = &routes };
    var why: []const u8 = "";
    _ = try runScene(a, &s, &fake, &why);
    try t.expectEqualStrings("filegroup()\n", try s.read(a, "out/BUCK"));
    try t.expectEqualStrings(BYTES_A, try s.read(a, "out/linux-64/mojo-pa-0.1.9-mojo1.0.0_0.conda"));
    try t.expectEqualStrings("readme b\n", try s.read(a, "out/pb/README.md"));
    try t.expect((try s.read(a, "out/plan.json")).len > 0);
    s.tmp.dir.access("out.partial", .{}) catch return;
    return error.PartialLeft;
}

test "an --out with its BUCK and anything else, or a BUCK that is not a file, is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var s = try Scene.init(a, try planText(a, BYTES_A, BYTES_B));
    defer s.tmp.cleanup();
    try s.tmp.dir.makePath("out");
    try s.tmp.dir.writeFile(.{ .sub_path = "out/BUCK", .data = "x" });
    try s.tmp.dir.writeFile(.{ .sub_path = "out/stale.conda", .data = "x" });
    const routes = goodRoutes();
    var fake = Fake{ .routes = &routes };
    var why: []const u8 = "";
    try refusedWith(&why, runScene(a, &s, &fake, &why), "is not empty");
    try s.tmp.dir.deleteFile("out/stale.conda");
    try s.tmp.dir.deleteFile("out/BUCK");
    try s.tmp.dir.makePath("out/BUCK");
    try refusedWith(&why, runScene(a, &s, &fake, &why), "is not empty");
}

test "a mismatch with --out holding its BUCK leaves the BUCK alone and writes nothing" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var s = try Scene.init(a, try planText(a, BYTES_A, BYTES_B));
    defer s.tmp.cleanup();
    try s.tmp.dir.makePath("out");
    try s.tmp.dir.writeFile(.{ .sub_path = "out/BUCK", .data = "keep" });
    var routes = goodRoutes();
    routes[1].got = .{ .body = @constCast("package a bytez") };
    var fake = Fake{ .routes = &routes };
    var why: []const u8 = "";
    try refusedWith(&why, runScene(a, &s, &fake, &why), "not what the plan staged");
    try t.expectEqualStrings("keep", try s.read(a, "out/BUCK"));
    try t.expectError(error.FileNotFound, s.tmp.dir.access("out/plan.json", .{}));
}

test "a move into an --out with its BUCK that fails midway takes back what it moved" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    const out = try std.fs.path.join(a, &.{ root, "out" });
    try tmp.dir.makePath("out/plan.json/inside"); // a directory where a file must go
    try tmp.dir.writeFile(.{ .sub_path = "out/BUCK", .data = "keep" });
    var why: []const u8 = "";
    const entries = [_]rbf.Entry{
        .{ .rel = "plan.json", .data = "{}" },
        .{ .rel = "linux-64/a.conda", .data = "bytes" },
        .{ .rel = "pa/README.md", .data = "r" },
    };
    try refusedWith(&why, rbf.writeSet(a, &why, out, &entries), "nothing was written");
    try t.expectEqualStrings("keep", try tmp.dir.readFileAlloc(a, "out/BUCK", 100));
    try t.expectError(error.FileNotFound, tmp.dir.access("out/linux-64", .{}));
    try t.expectError(error.FileNotFound, tmp.dir.access("out/pa", .{}));
    try t.expectError(error.FileNotFound, tmp.dir.access("out.partial", .{}));
}

test "a path of the set named BUCK is refused: it would replace the kept file" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try parseRefused(try planOf(a, &.{try memberJson(a, "p", "BUCK", "linux-64", "a.conda", 1)}), "collide");
    try parseRefused(try planOf(a, &.{try memberJson(a, "p", "buck/README.md", "linux-64", "a.conda", 1)}), "collide");
    try parseRefused(try planOf(a, &.{try memberJson(a, "p", "p/README.md", "BUCK", "a.conda", 1)}), "collide");
}
