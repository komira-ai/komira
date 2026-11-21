//! The supported Pythons as the workflows read them: the two JSON lists of `//python:supported_pythons`
//! (python/pythons.bzl, HOSTED), `[linux-x86_64]` and `[macos-arm64]`, from which the build jobs of release.yml
//! and pypi.yml write the job matrix of every job that installs the wheel once per Python (`pypi_smoke matrix`). The files are the test's data, under KOMIRA_TEST_WORK. `check` holds them:
//!  - each is a JSON list of `<major>.<minor>.<micro>` strings;
//!  - each names its minors once each, oldest first;
//!  - both name the same minors: a platform's jobs are the same supported Pythons at that platform's
//!    patch releases;
//!  - each is exactly the versions written out below (LINUX, MACOS), in order.
//! The real files must pass, and `matrix` (matrix.zig) must take each for its platform, so a list that would fail
//! the workflow step fails here first; each defect, written into a copy of them, is refused with its message.
const std = @import("std");
const lib = @import("pypi_smoke_lib");
const t = std.testing;

const LINUX = [_][]const u8{ "3.11.17", "3.12.15", "3.13.16", "3.14.8" };
const MACOS = [_][]const u8{ "3.11.9", "3.12.10", "3.13.16", "3.14.8" };

fn readData(a: std.mem.Allocator, name: []const u8) ![]u8 {
    const work = try std.process.getEnvVarOwned(a, "KOMIRA_TEST_WORK");
    const path = try std.fs.path.join(a, &.{ work, name });
    return std.fs.cwd().readFileAlloc(a, path, 1 << 20);
}

/// The minor of a `<major>.<minor>.<micro>` version: its first two numbers, or null if it is not one.
fn minorOf(v: []const u8) ?[2]u32 {
    var parts = std.mem.splitScalar(u8, v, '.');
    var nums: [3]u32 = undefined;
    var n: usize = 0;
    while (parts.next()) |p| {
        if (n == 3 or p.len == 0) return null;
        nums[n] = std.fmt.parseInt(u32, p, 10) catch return null;
        n += 1;
    }
    if (n != 3) return null;
    return .{ nums[0], nums[1] };
}

/// The versions of one platform's file, or the refusal in `why`.
fn versions(a: std.mem.Allocator, platform: []const u8, text: []const u8, why: *?[]const u8) ![]const []const u8 {
    const parsed = std.json.parseFromSlice([]const []const u8, a, text, .{}) catch {
        why.* = try std.fmt.allocPrint(a, "the {s} list is not a JSON list of strings", .{platform});
        return &.{};
    };
    for (parsed.value) |v| {
        if (minorOf(v) == null) {
            why.* = try std.fmt.allocPrint(a, "the {s} list holds \"{s}\", not a <major>.<minor>.<micro> version", .{ platform, v });
            return &.{};
        }
    }
    return parsed.value;
}

fn joined(a: std.mem.Allocator, vs: []const []const u8) ![]const u8 {
    return std.mem.join(a, ",", vs);
}

fn sameList(x: []const []const u8, y: []const []const u8) bool {
    if (x.len != y.len) return false;
    for (x, y) |p, q| if (!std.mem.eql(u8, p, q)) return false;
    return true;
}

/// Null if the two files hold the contract, else why not.
fn check(a: std.mem.Allocator, linux_text: []const u8, macos_text: []const u8) !?[]const u8 {
    var why: ?[]const u8 = null;
    const linux = try versions(a, "Linux", linux_text, &why);
    if (why) |w| return w;
    const macos = try versions(a, "macOS", macos_text, &why);
    if (why) |w| return w;
    for ([_]struct { []const u8, []const []const u8 }{ .{ "Linux", linux }, .{ "macOS", macos } }) |pv| {
        var i: usize = 1;
        while (i < pv[1].len) : (i += 1) {
            const prev = minorOf(pv[1][i - 1]).?;
            const cur = minorOf(pv[1][i]).?;
            if (cur[0] < prev[0] or (cur[0] == prev[0] and cur[1] <= prev[1]))
                return try std.fmt.allocPrint(a, "the {s} list {s} does not name each minor once, oldest first", .{ pv[0], try joined(a, pv[1]) });
        }
    }
    var same = linux.len == macos.len;
    if (same) {
        for (linux, macos) |l, m| {
            const lm = minorOf(l).?;
            const mm = minorOf(m).?;
            if (lm[0] != mm[0] or lm[1] != mm[1]) same = false;
        }
    }
    if (!same) return try std.fmt.allocPrint(a, "the Linux list {s} and the macOS list {s} do not name the same minors", .{ try joined(a, linux), try joined(a, macos) });
    if (!sameList(linux, &LINUX)) return try std.fmt.allocPrint(a, "the Linux list is {s}, not {s}", .{ try joined(a, linux), try joined(a, &LINUX) });
    if (!sameList(macos, &MACOS)) return try std.fmt.allocPrint(a, "the macOS list is {s}, not {s}", .{ try joined(a, macos), try joined(a, &MACOS) });
    return null;
}

fn expectRefused(a: std.mem.Allocator, linux: []const u8, macos: []const u8, want: []const u8) !void {
    const got = (try check(a, linux, macos)) orelse {
        std.debug.print("accepted lists that must be refused with: {s}\n", .{want});
        return error.Accepted;
    };
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("refused with \"{s}\", wanted \"{s}\"\n", .{ got, want });
        return error.WrongRefusal;
    }
}

test "the built lists are the supported Pythons, the same minors on both platforms" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    if (try check(a, try readData(a, "linux-x86_64.json"), try readData(a, "macos-arm64.json"))) |why| {
        std.debug.print("{s}\n", .{why});
        return error.Refused;
    }
}

test "the matrix step takes each platform's list, and every platform it knows has one" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    for (lib.matrix.platforms) |p| {
        const name = try std.fmt.allocPrint(a, "{s}.json", .{p.name});
        var why: []const u8 = "";
        const vs = lib.matrix.parse(a, &why, name, try readData(a, name)) catch |e| {
            std.debug.print("{s}\n", .{why});
            return e;
        };
        try t.expectEqual(LINUX.len, vs.len);
    }
}

test "lists that are not the supported Pythons are refused with their message" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const linux = try readData(a, "linux-x86_64.json");
    const macos = try readData(a, "macos-arm64.json");
    // the two files swapped
    try expectRefused(a, macos, linux, "the Linux list is 3.11.9,3.12.10,3.13.16,3.14.8, not 3.11.17,3.12.15,3.13.16,3.14.8");
    // a minor left out of one platform, then of both
    try expectRefused(a, "[\"3.11.17\",\"3.13.16\",\"3.14.8\"]", macos, "the Linux list 3.11.17,3.13.16,3.14.8 and the macOS list 3.11.9,3.12.10,3.13.16,3.14.8 do not name the same minors");
    try expectRefused(a, "[\"3.12.15\",\"3.13.16\",\"3.14.8\"]", "[\"3.12.10\",\"3.13.16\",\"3.14.8\"]", "the Linux list is 3.12.15,3.13.16,3.14.8, not 3.11.17,3.12.15,3.13.16,3.14.8");
    // another patch release on one platform
    try expectRefused(a, linux, "[\"3.11.9\",\"3.12.10\",\"3.13.17\",\"3.14.8\"]", "the macOS list is 3.11.9,3.12.10,3.13.17,3.14.8, not 3.11.9,3.12.10,3.13.16,3.14.8");
    // out of order, a minor twice
    try expectRefused(a, "[\"3.12.15\",\"3.11.17\",\"3.13.16\",\"3.14.8\"]", macos, "the Linux list 3.12.15,3.11.17,3.13.16,3.14.8 does not name each minor once, oldest first");
    try expectRefused(a, linux, "[\"3.11.9\",\"3.11.9\",\"3.13.16\",\"3.14.8\"]", "the macOS list 3.11.9,3.11.9,3.13.16,3.14.8 does not name each minor once, oldest first");
    // not a list of versions: a minor alone, a word, an object, a list of numbers
    try expectRefused(a, "[\"3.11\",\"3.12.15\",\"3.13.16\",\"3.14.8\"]", macos, "the Linux list holds \"3.11\", not a <major>.<minor>.<micro> version");
    try expectRefused(a, linux, "[\"3.11.9\",\"latest\"]", "the macOS list holds \"latest\", not a <major>.<minor>.<micro> version");
    try expectRefused(a, "{\"linux-x86_64\":[\"3.11.17\"]}", macos, "the Linux list is not a JSON list of strings");
    try expectRefused(a, linux, "[3.11,3.12]", "the macOS list is not a JSON list of strings");
}
