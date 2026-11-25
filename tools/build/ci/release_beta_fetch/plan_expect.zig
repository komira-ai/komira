//! plan_expect: the interface of `release_staged_verify expect`, which its cases (plan_expect_test.zig) are
//! written against. This version checks nothing: every expectation is read as given and every plan has no
//! difference from it, which is what release.yml does today (nothing holds the staged plan to the set the
//! release builds). The check itself follows in the next commit.
const std = @import("std");
const rbf = @import("release_beta_fetch.zig");

const Allocator = std.mem.Allocator;

pub const max_expect_bytes: usize = 1024 * 1024;

pub const Expected = struct {
    name: []const u8,
    subdirs: []const []const u8 = &.{},
};

pub const Expectation = struct {
    members: []const Expected = &.{},
};

pub const Report = struct {
    members: usize,
    files: usize,
    subdirs: []const SubdirCount,
};

pub const SubdirCount = struct { subdir: []const u8, files: usize };

pub fn parseExpectation(a: Allocator, why: *[]const u8, text: []const u8) rbf.Error!Expectation {
    return std.json.parseFromSliceLeaky(Expectation, a, text, .{ .ignore_unknown_fields = true }) catch |e| {
        why.* = try std.fmt.allocPrint(a, "the expectation does not parse: {s}", .{@errorName(e)});
        return error.Refused;
    };
}

pub fn differences(a: Allocator, plan: rbf.Plan, exp: Expectation) ![]const []const u8 {
    _ = a;
    _ = plan;
    _ = exp;
    return &.{};
}

pub const usage = "usage: release_staged_verify expect --staged <dir> --expect <file>\n";

pub fn cliExpect(a: Allocator, args: []const []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    _ = a;
    _ = args;
    _ = out;
    _ = err;
    return 0;
}
