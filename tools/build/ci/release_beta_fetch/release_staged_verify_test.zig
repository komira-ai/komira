//! The cases of release_staged_verify (release_staged_verify.zig). Each test is a defect the prod publish of
//! release.yml would otherwise let through: tests that ran on other bytes than the registry will publish, a
//! staged directory with a file that was changed, lost or never listed, a smoke check that reads the wrong
//! channel or stops at the first lagging answer, a yank hint that names something that is not a group.
const std = @import("std");
const rsv = @import("release_staged_verify.zig");
const rbf = @import("release_beta_fetch.zig");
const t = std.testing;

const CONFIG_URL = "https://api.mopm.dev/index/config.json";
const CONFIG_OK = "{\"channel_url\":\"https://conda.mopm.dev/\",\"stage\":\"prod\"}";
const BYTES_A = "package a bytes";
const BYTES_B = "package b bytes, a little longer";
const FILE_A = "mojo-pa-0.1.9-mojo1.0.0_0.conda";
const FILE_B = "mojo-pb-0.1.9-mojo1.0.0_0.conda";
const URL_A = "https://conda.mopm.dev/linux-64/" ++ FILE_A;
const URL_B = "https://conda.mopm.dev/linux-64/" ++ FILE_B;

fn sha(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    const hex = std.fmt.bytesToHex(d, .lower);
    return a.dupe(u8, &hex);
}

fn planText(a: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(a,
        \\{{"version":1,"members":[
        \\ {{"name":"pa","version":"0.1.9","action":"upload","readme":"pa/README.md",
        \\   "files":[{{"subdir":"linux-64","filename":"{s}","sha256":"{s}","size":{d}}}]}},
        \\ {{"name":"pb","version":"0.1.9","action":"upload","readme":"pb/README.md",
        \\   "files":[{{"subdir":"linux-64","filename":"{s}","sha256":"{s}","size":{d}}}]}}
        \\]}}
    , .{ FILE_A, try sha(a, BYTES_A), BYTES_A.len, FILE_B, try sha(a, BYTES_B), BYTES_B.len });
}

/// A staged directory as `mopm publish --staged --no-commit` leaves it, in `tmp`.
fn stage(a: std.mem.Allocator, tmp: *t.TmpDir) !void {
    try tmp.dir.makePath("staged/linux-64");
    try tmp.dir.makePath("staged/pa");
    try tmp.dir.makePath("staged/pb");
    try tmp.dir.writeFile(.{ .sub_path = "staged/plan.json", .data = try planText(a) });
    try tmp.dir.writeFile(.{ .sub_path = "staged/linux-64/" ++ FILE_A, .data = BYTES_A });
    try tmp.dir.writeFile(.{ .sub_path = "staged/linux-64/" ++ FILE_B, .data = BYTES_B });
    try tmp.dir.writeFile(.{ .sub_path = "staged/pa/README.md", .data = "# pa\n" });
    try tmp.dir.writeFile(.{ .sub_path = "staged/pb/README.md", .data = "# pb\n" });
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
    try t.expect(exists(&tmp, "out/pa/README.md"));
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
    try tmp.dir.deleteFile("staged/pb/README.md");
    try refusedWith(&why, rsv.verify(a, &why, try path(a, &tmp, "staged"), try path(a, &tmp, "out"), &log.writer), "README.md");
    try t.expect(!exists(&tmp, "out"));
    const skip = "{\"members\":[{\"name\":\"pa\",\"version\":\"0.1.9\",\"action\":\"skip\",\"reason\":\"held\"}]}";
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
