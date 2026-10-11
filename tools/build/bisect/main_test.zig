//! The command line's cases.
const std = @import("std");
const main = @import("main.zig");
const t = std.testing;

test "every flag, repeated flags, and the targets after --" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const r = try main.parseArgs(arena.allocator(), &.{
        "--good",       "g",     "--bad",   "b",               "--work-dir", "w",      "--repo",       "r",
        "--verb",       "test",  "--buck2", "./buck2",         "--git",      "/x/git", "--copy",       ".buckconfig.local",
        "--copy",       "a/b",   "--submodules", "--buck2-arg", "-c",        "--buck2-arg", "k.v=1", "--timeout-s",
        "60",           "--",    "//a:b",   "//c/...",
    });
    try t.expectEqualStrings("g", r.good);
    try t.expectEqualStrings("b", r.bad);
    try t.expectEqualStrings("w", r.work_dir);
    try t.expectEqualStrings("r", r.repo);
    try t.expectEqual(@import("classify.zig").Verb.@"test", r.verb);
    try t.expectEqualStrings("./buck2", r.buck2);
    try t.expectEqualStrings("/x/git", r.git);
    try t.expectEqual(@as(usize, 2), r.copies.len);
    try t.expect(r.submodules);
    try t.expectEqual(@as(usize, 2), r.buck2_args.len);
    try t.expectEqualStrings("k.v=1", r.buck2_args[1]);
    try t.expectEqual(@as(u32, 60), r.timeout_s);
    try t.expectEqual(@as(usize, 2), r.targets.len);
}

test "refusals: each is a usage error before anything runs" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectError(error.NoTargets, main.parseArgs(a, &.{ "--good", "g", "--bad", "b", "--work-dir", "w" }));
    try t.expectError(error.NoTargets, main.parseArgs(a, &.{ "--good", "g", "--bad", "b", "--work-dir", "w", "--" }));
    try t.expectError(error.MissingGood, main.parseArgs(a, &.{ "--bad", "b", "--work-dir", "w", "--", "//a:b" }));
    try t.expectError(error.MissingBad, main.parseArgs(a, &.{ "--good", "g", "--work-dir", "w", "--", "//a:b" }));
    try t.expectError(error.MissingWorkDir, main.parseArgs(a, &.{ "--good", "g", "--bad", "b", "--", "//a:b" }));
    try t.expectError(error.MissingValue, main.parseArgs(a, &.{"--good"}));
    try t.expectError(error.UnknownArgument, main.parseArgs(a, &.{ "--goodx", "g" }));
    try t.expectError(error.BadVerb, main.parseArgs(a, &.{ "--verb", "run" }));
    try t.expectError(error.BadTimeout, main.parseArgs(a, &.{ "--timeout-s", "x" }));
    try t.expectError(error.BadTimeout, main.parseArgs(a, &.{ "--good", "g", "--bad", "b", "--work-dir", "w", "--timeout-s", "0", "--", "//a:b" }));
    try t.expectError(error.BadCopy, main.parseArgs(a, &.{ "--copy", "/etc/x" }));
    try t.expectError(error.BadCopy, main.parseArgs(a, &.{ "--copy", "../x" }));
}
