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
        "60",           "--flake-runs", "0", "--rerun-base", "7", "--",    "//a:b",   "//c/...",
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
    try t.expectEqual(@as(u32, 0), r.flake_runs);
    try t.expectEqual(@as(?u64, 7), r.rerun_base);
    try t.expectEqual(main.Mode.bisect, r.mode);
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

test "bisect flake: its flags, and K and the base it measures with" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const r = try main.parseArgs(arena.allocator(), &.{ "flake", "--rev", "HEAD~2", "--runs", "15", "--work-dir", "w", "--rerun-base", "0", "--", "//t:a", "komira//t:b" });
    try t.expectEqual(main.Mode.flake, r.mode);
    try t.expectEqualStrings("HEAD~2", r.rev);
    try t.expectEqual(@as(u32, 15), r.runs);
    try t.expectEqual(@as(?u64, 0), r.rerun_base);
    try t.expectEqual(@as(usize, 2), r.targets.len);
    // No base given: the tool picks one at start (main.run), not the parser.
    const d = try main.parseArgs(arena.allocator(), &.{ "flake", "--rev", "r", "--runs", "1", "--work-dir", "w", "--", "//t:a" });
    try t.expectEqual(@as(?u64, null), d.rerun_base);
    // bisect measures a flake 5 times unless told otherwise.
    const b = try main.parseArgs(arena.allocator(), &.{ "--good", "g", "--bad", "b", "--work-dir", "w", "--", "//t:a" });
    try t.expectEqual(@as(u32, 5), b.flake_runs);
}

test "bisect flake refusals: no rev, no or zero runs, a pattern, the other mode's flags" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectError(error.MissingRev, main.parseArgs(a, &.{ "flake", "--runs", "5", "--work-dir", "w", "--", "//t:a" }));
    try t.expectError(error.BadRuns, main.parseArgs(a, &.{ "flake", "--rev", "r", "--work-dir", "w", "--", "//t:a" }));
    try t.expectError(error.BadRuns, main.parseArgs(a, &.{ "flake", "--rev", "r", "--runs", "0", "--work-dir", "w", "--", "//t:a" }));
    try t.expectError(error.BadRuns, main.parseArgs(a, &.{ "flake", "--rev", "r", "--runs", "x", "--work-dir", "w", "--", "//t:a" }));
    // A rerun names one target: a pattern would match no test action, and
    // every run would replay the cache.
    try t.expectError(error.PatternTarget, main.parseArgs(a, &.{ "flake", "--rev", "r", "--runs", "5", "--work-dir", "w", "--", "//t/..." }));
    try t.expectError(error.PatternTarget, main.parseArgs(a, &.{ "flake", "--rev", "r", "--runs", "5", "--work-dir", "w", "--", "//t:" }));
    try t.expectError(error.PatternTarget, main.parseArgs(a, &.{ "--good", "g", "--bad", "b", "--work-dir", "w", "--", "//t/..." }));
    _ = try main.parseArgs(a, &.{ "--good", "g", "--bad", "b", "--work-dir", "w", "--flake-runs", "0", "--", "//t/..." });
    try t.expectError(error.UnknownArgument, main.parseArgs(a, &.{ "flake", "--good", "g" }));
    try t.expectError(error.UnknownArgument, main.parseArgs(a, &.{ "flake", "--flake-runs", "3" }));
    try t.expectError(error.UnknownArgument, main.parseArgs(a, &.{ "--runs", "3" }));
    try t.expectError(error.UnknownArgument, main.parseArgs(a, &.{ "--rev", "r" }));
    try t.expectError(error.BadRerunBase, main.parseArgs(a, &.{ "flake", "--rev", "r", "--runs", "5", "--work-dir", "w", "--rerun-base", "18446744073709551614", "--", "//t:a" }));
    try t.expectError(error.BadRerunBase, main.parseArgs(a, &.{ "flake", "--rev", "r", "--runs", "5", "--work-dir", "w", "--rerun-base", "-1", "--", "//t:a" }));
}
