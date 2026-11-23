//! The macOS Python harness step of release-macos.yml builds the list pr.yml analyses: part of
//! //:release_macos_cases (release_macos_test.zig imports it). The subjects are the bytes of
//! release-macos.yml and release/darwin_libs.bzl (the zig_test's `data`).
//!
//! pr.yml's last step analyses, for darwin-arm64, the macOS set and DARWIN_PYTHON_HARNESS of
//! darwin_libs.bzl (release/darwin_analysis.bxl): a target of their closure that fails analysis, or
//! that runs a Zig tool built for another platform than its action's, fails in its pull request
//! instead of on a macOS worker after the merge. That holds only while the list is what the step
//! `build the macOS Python harness tests` builds. What the cases catch:
//!  - the step builds, for `--target-platforms komira//tools/build/platforms:darwin-arm64` with
//!    `--keep-going`, exactly the targets of DARWIN_PYTHON_HARNESS, in its order: a target added to
//!    or dropped from the step but not the list, or another platform, is refused;
//!  - the step is there once, with one `args:` line;
//!  - the list is there and names at least one target (an empty list would make the step build
//!    nothing that is analysed).
//! Every defect above is written into the real text and must be refused with its message.

const std = @import("std");
const t = std.testing;

const STEP = "      - name: build the macOS Python harness tests";
const ARGS = "          args: build --target-platforms komira//tools/build/platforms:darwin-arm64 --keep-going ";
const LIST = "DARWIN_PYTHON_HARNESS = [";

/// The targets of DARWIN_PYTHON_HARNESS in `bzl`, one `    "<label>",` line each, or null when the
/// list is not there or names none.
fn harnessList(ar: std.mem.Allocator, bzl: []const u8) !?[]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var in_list = false;
    var it = std.mem.splitScalar(u8, bzl, '\n');
    while (it.next()) |line| {
        if (!in_list) {
            in_list = std.mem.eql(u8, line, LIST);
            continue;
        }
        if (std.mem.eql(u8, line, "]")) return if (out.items.len == 0) null else out.items;
        const s = std.mem.trim(u8, line, " ");
        if (s.len < 4 or s[0] != '"' or !std.mem.endsWith(u8, s, "\",")) return null;
        try out.append(ar, s[1 .. s.len - 2]);
    }
    return null;
}

/// Null when release-macos.yml's harness step builds exactly DARWIN_PYTHON_HARNESS for darwin-arm64,
/// else the refusal.
pub fn harnessRefusal(ar: std.mem.Allocator, workflow: []const u8, bzl: []const u8) !?[]const u8 {
    const list = (try harnessList(ar, bzl)) orelse return "release/darwin_libs.bzl has no DARWIN_PYTHON_HARNESS list naming a target: pr.yml's analysis would analyse none of the harness tests";
    var steps: usize = 0;
    var args: ?[]const u8 = null;
    var arg_lines: usize = 0;
    var in_step = false;
    var it = std.mem.splitScalar(u8, workflow, '\n');
    while (it.next()) |line| {
        if (std.mem.eql(u8, line, STEP)) {
            steps += 1;
            in_step = true;
            continue;
        }
        if (std.mem.startsWith(u8, line, "      - ") or (line.len > 0 and !std.mem.startsWith(u8, line, "      "))) in_step = false;
        if (in_step and std.mem.startsWith(u8, line, "          args:")) {
            arg_lines += 1;
            args = line;
        }
    }
    if (steps != 1) return "release-macos.yml does not have the step `build the macOS Python harness tests` exactly once";
    if (arg_lines != 1) return "the step `build the macOS Python harness tests` does not have exactly one `args:` line";
    const want = try std.mem.concat(ar, u8, &.{ ARGS, try std.mem.join(ar, " ", list) });
    if (!std.mem.eql(u8, args.?, want))
        return try std.fmt.allocPrint(ar, "the step `build the macOS Python harness tests` is `{s}`, not a build of DARWIN_PYTHON_HARNESS (release/darwin_libs.bzl) for darwin-arm64, `{s}`: pr.yml's analysis (release/darwin_analysis.bxl) would not analyse what it builds", .{ std.mem.trim(u8, args.?, " "), std.mem.trim(u8, want, " ") });
    return null;
}

fn readData(ar: std.mem.Allocator, rel: []const []const u8) ![]const u8 {
    const w = try std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK");
    var parts = std.ArrayList([]const u8).empty;
    try parts.append(ar, w);
    try parts.appendSlice(ar, rel);
    return std.fs.cwd().readFileAlloc(ar, try std.fs.path.join(ar, parts.items), 1 << 22);
}

fn replacedOnce(ar: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8) ![]const u8 {
    if (std.mem.count(u8, text, from) != 1) {
        std.debug.print("the fixture edit expects `{s}` exactly once\n", .{from});
        return error.FixtureEditNotUnique;
    }
    return std.mem.replaceOwned(u8, ar, text, from, to);
}

fn expectRefusal(ar: std.mem.Allocator, workflow: []const u8, bzl: []const u8, want: []const u8) !void {
    const got = (try harnessRefusal(ar, workflow, bzl)) orelse {
        std.debug.print("accepted; want the refusal `{s}`\n", .{want});
        return error.NotRefused;
    };
    try t.expectEqualStrings(want, got);
}

const HELLO = "komira//tools/build/examples/python_binding:hello";

test "the real release-macos.yml builds exactly DARWIN_PYTHON_HARNESS for darwin-arm64" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const workflow = try readData(ar, &.{ "workflows", "release-macos.yml" });
    const bzl = try readData(ar, &.{"darwin_libs.bzl"});
    if (try harnessRefusal(ar, workflow, bzl)) |r| {
        std.debug.print("{s}\n", .{r});
        return error.Refused;
    }
    // the list is read, not skipped: the hello test is in it
    const list = (try harnessList(ar, bzl)).?;
    try t.expect(list.len >= 1);
    try t.expectEqualStrings(HELLO, list[0]);
}

test "each edit of the real harness step or list that makes them differ is refused with its message" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const workflow = try readData(ar, &.{ "workflows", "release-macos.yml" });
    const bzl = try readData(ar, &.{"darwin_libs.bzl"});
    const list = (try harnessList(ar, bzl)).?;
    const real = try std.mem.concat(ar, u8, &.{ ARGS, try std.mem.join(ar, " ", list) });
    const real_shown = std.mem.trim(u8, real, " ");

    // a target added to the step but not the list
    const added = try std.mem.concat(ar, u8, &.{ real, " komira//tools/build/examples/python_binding:extra" });
    try expectRefusal(ar, try replacedOnce(ar, workflow, real, added), bzl, try std.fmt.allocPrint(ar, "the step `build the macOS Python harness tests` is `{s}`, not a build of DARWIN_PYTHON_HARNESS (release/darwin_libs.bzl) for darwin-arm64, `{s}`: pr.yml's analysis (release/darwin_analysis.bxl) would not analyse what it builds", .{ std.mem.trim(u8, added, " "), real_shown }));
    // a target dropped from the step but not the list
    const dropped = try replacedOnce(ar, real, " " ++ HELLO, "");
    try expectRefusal(ar, try replacedOnce(ar, workflow, real, dropped), bzl, try std.fmt.allocPrint(ar, "the step `build the macOS Python harness tests` is `{s}`, not a build of DARWIN_PYTHON_HARNESS (release/darwin_libs.bzl) for darwin-arm64, `{s}`: pr.yml's analysis (release/darwin_analysis.bxl) would not analyse what it builds", .{ std.mem.trim(u8, dropped, " "), real_shown }));
    // a target added to the list but not the step
    const longer = try replacedOnce(ar, bzl, "    \"" ++ HELLO ++ "\",\n", "    \"" ++ HELLO ++ "\",\n    \"komira//tools/build/examples/python_binding:extra\",\n");
    try t.expect((try harnessRefusal(ar, workflow, longer)) != null);
    // another platform, or no --keep-going
    const linux = try replacedOnce(ar, workflow, "darwin-arm64 --keep-going " ++ HELLO, "linux-x86_64 --keep-going " ++ HELLO);
    try t.expect((try harnessRefusal(ar, linux, bzl)) != null);
    const no_keep = try replacedOnce(ar, workflow, "darwin-arm64 --keep-going " ++ HELLO, "darwin-arm64 " ++ HELLO);
    try t.expect((try harnessRefusal(ar, no_keep, bzl)) != null);
    // the step renamed away, or there twice
    try expectRefusal(ar, try replacedOnce(ar, workflow, STEP ++ "\n", "      - name: build the harness\n"), bzl, "release-macos.yml does not have the step `build the macOS Python harness tests` exactly once");
    try expectRefusal(ar, try replacedOnce(ar, workflow, STEP ++ "\n", STEP ++ "\n" ++ STEP ++ "\n"), bzl, "release-macos.yml does not have the step `build the macOS Python harness tests` exactly once");
    // the step with a second args line, or none
    const real_line = try std.mem.concat(ar, u8, &.{ real, "\n" });
    try expectRefusal(ar, try replacedOnce(ar, workflow, real_line, try std.mem.concat(ar, u8, &.{ real_line, real_line })), bzl, "the step `build the macOS Python harness tests` does not have exactly one `args:` line");
    try expectRefusal(ar, try replacedOnce(ar, workflow, real_line, ""), bzl, "the step `build the macOS Python harness tests` does not have exactly one `args:` line");
    // the list emptied, renamed, or with a line that is no label
    const none = "release/darwin_libs.bzl has no DARWIN_PYTHON_HARNESS list naming a target: pr.yml's analysis would analyse none of the harness tests";
    const list_at = std.mem.indexOf(u8, bzl, LIST).?;
    const list_end = std.mem.indexOfPos(u8, bzl, list_at, "\n]\n").?;
    try expectRefusal(ar, workflow, try std.mem.concat(ar, u8, &.{ bzl[0..list_at], LIST, bzl[list_end..] }), none);
    try expectRefusal(ar, workflow, try replacedOnce(ar, bzl, LIST, "PYTHON_HARNESS = ["), none);
    try expectRefusal(ar, workflow, try replacedOnce(ar, bzl, "    \"" ++ HELLO ++ "\",\n", "    HELLO,\n"), none);
}
