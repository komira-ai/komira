//! The helper library's unit tests, over output captured from buck2
//! 2026-09-15 (`audit providers` of the execution platforms, `audit
//! execution-platform-resolution`, `audit config --json`, `log what-ran`).
//! Welded: `:lib` is a `zig_test`, and every scenario's binary is built
//! behind it (defs.bzl).
const std = @import("std");
const lib = @import("lib.zig");
const t = std.testing;

test "the command line: a scenario name, the buck2, the expected executor" {
    const p = try lib.args.parse(&.{ "--scenario", "exec_platforms", "--buck2", "/b/buck2", "--buck2-zst", "/b/buck2.zst", "--expect", "remote" });
    try t.expectEqualStrings("/b/buck2.zst", p.buck2_zst);
    try t.expectEqualStrings("exec_platforms", p.scenario);
    try t.expectEqualStrings("/b/buck2", p.buck2);
    try t.expectEqual(lib.args.Expect.remote, p.expect);
    try t.expect(!p.nested);
    try t.expect(!p.keep_scratch);
}

test "the command line: --nested is read, never ignored" {
    const p = try lib.args.parse(&.{ "--scenario", "x", "--buck2", "b", "--buck2-zst", "z", "--expect", "local", "--nested" });
    try t.expect(p.nested);
    try t.expectEqual(lib.args.Expect.local, p.expect);
}

test "the command line: refusals" {
    try t.expectError(error.UnknownArgument, lib.args.parse(&.{ "--scenario", "x", "--buck2", "b", "--buck2-zst", "z", "--expect", "remote", "--nestedx" }));
    try t.expectError(error.MissingValue, lib.args.parse(&.{"--scenario"}));
    try t.expectError(error.MissingBuck2, lib.args.parse(&.{ "--scenario", "x", "--buck2-zst", "z", "--expect", "remote" }));
    try t.expectError(error.MissingScenario, lib.args.parse(&.{ "--buck2", "b", "--buck2-zst", "z", "--expect", "remote" }));
    try t.expectError(error.MissingExpect, lib.args.parse(&.{ "--scenario", "x", "--buck2", "b", "--buck2-zst", "z" }));
    try t.expectError(error.MissingBuck2Zst, lib.args.parse(&.{ "--scenario", "x", "--buck2", "b", "--expect", "remote" }));
    try t.expectError(error.BadExpect, lib.args.parse(&.{ "--scenario", "x", "--buck2", "b", "--buck2-zst", "z", "--expect", "hybrid" }));
    try t.expectError(error.BadScenarioName, lib.args.parse(&.{ "--scenario", "../x", "--buck2", "b", "--buck2-zst", "z", "--expect", "remote" }));
    try t.expectError(error.BadScenarioName, lib.args.parse(&.{ "--scenario", "X", "--buck2", "b", "--buck2-zst", "z", "--expect", "remote" }));
}

test "the guard refuses --nested and any client but Linux x86_64" {
    try t.expect(lib.guard.nestedRefusal(true) != null);
    try t.expect(lib.guard.nestedRefusal(false) == null);
    try t.expect(lib.guard.clientRefusal("Linux", "x86_64") == null);
    try t.expect(lib.guard.clientRefusal("Darwin", "arm64") != null);
    try t.expect(lib.guard.clientRefusal("Linux", "aarch64") != null);
    try t.expect(lib.guard.clientRefusal("linux", "x86_64") != null);
}

// `buck2 audit providers komira//tools/build/platforms/default:default`,
// cut to the executor lines: two remote platforms (linux and darwin keys set).
const REMOTE_TWO =
    \\          executor_config=CommandExecutorConfig {
    \\              executor: RemoteEnabled(
    \\                  RemoteEnabledExecutorOptions {
    \\                      executor: Remote(
    \\          executor_config=CommandExecutorConfig {
    \\              executor: RemoteEnabled(
    \\                  RemoteEnabledExecutorOptions {
    \\                      executor: Remote(
;
// The same with `-c komira.execution=local`: one local platform.
const LOCAL_ONE =
    \\        executor_config=CommandExecutorConfig {
    \\            executor: Local(
;
const MIXED = REMOTE_TWO ++ "\n" ++ LOCAL_ONE;

test "the guard: every registered platform remote, or every one local for expect = local" {
    const remote = lib.parse.executors(REMOTE_TWO);
    try t.expectEqual(@as(usize, 2), remote.platforms);
    try t.expectEqual(@as(usize, 2), remote.remote);
    try t.expect(lib.guard.platformsRefusal(remote, .remote) == null);
    try t.expect(lib.guard.platformsRefusal(remote, .local) != null);
    const local = lib.parse.executors(LOCAL_ONE);
    try t.expect(lib.guard.platformsRefusal(local, .remote) != null);
    try t.expect(lib.guard.platformsRefusal(local, .local) == null);
    const mixed = lib.parse.executors(MIXED);
    try t.expect(lib.guard.platformsRefusal(mixed, .remote) != null);
    try t.expect(lib.guard.platformsRefusal(mixed, .local) != null);
    try t.expect(lib.guard.platformsRefusal(lib.parse.executors(""), .remote) != null);
    try t.expect(lib.guard.platformsRefusal(lib.parse.executors(""), .local) != null);
    // An executor_config whose executor is neither kind.
    try t.expect(lib.guard.platformsRefusal(lib.parse.executors("executor_config=X {\n executor: Hybrid(\n"), .remote) != null);
}

test "audit config --json: the value of the key" {
    const j = "{\"build.execution_platforms\":\"komira//tools/build/platforms/default:default\"}";
    try t.expectEqualStrings("komira//tools/build/platforms/default:default", lib.parse.configValue(j, "build.execution_platforms").?);
    try t.expect(lib.parse.configValue(j, "build.execution") == null);
    try t.expect(lib.parse.configValue("{\"build.execution_platforms\": 3}", "build.execution_platforms") == null);
    try t.expectEqualStrings("v", lib.parse.configValue("{\"k\" : \"v\"}", "k").?);
}

const RESOLUTION =
    \\Checking each target against execution platforms defined by komira//tools/build/platforms/default:default
    \\komira//tools/build/examples:hello (komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be):
    \\  Execution platform: komira//tools/build/platforms:linux-x86_64
    \\    Execution platform configuration: komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be
    \\    Execution deps:
    \\    Toolchain deps:
    \\      toolchains//:mojo (komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be) (komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be)
    \\    Configuration deps:
    \\komira//tools/build/toolchains:zig (komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be):
    \\  Failed to configure: no execution platform
    \\komira//tools/build/toolchains:mojo_runtime (komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be):
    \\  Execution platform: komira//tools/build/platforms:darwin-arm64
    \\
;

test "audit execution-platform-resolution: one line per target, FAILED for a target that failed" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const got = try lib.parse.resolution(arena.allocator(), RESOLUTION);
    try t.expectEqual(@as(usize, 3), got.len);
    try t.expectEqualStrings("komira//tools/build/examples:hello komira//tools/build/platforms:linux-x86_64", got[0]);
    try t.expectEqualStrings("komira//tools/build/toolchains:zig FAILED", got[1]);
    try t.expectEqualStrings("komira//tools/build/toolchains:mojo_runtime komira//tools/build/platforms:darwin-arm64", got[2]);
}

test "buck2 targets: the names, sorted" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const got = try lib.parse.targetNames(arena.allocator(), "komira//tools/build/platforms:linux-x86_64\nkomira//tools/build/platforms:doc_tree\nkomira//tools/build/platforms:host\n");
    try t.expect(lib.text.eqlLists(&.{ "doc_tree", "host", "linux-x86_64" }, got));
}

test "a cquery line configured for a platform" {
    const out = "komira//tools/build/toolchains:conda_unpack (komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be)\n";
    try t.expect(lib.parse.configuredFor(out, "komira//tools/build/platforms:linux-x86_64"));
    try t.expect(!lib.parse.configuredFor(out, "komira//tools/build/platforms:darwin-arm64"));
    try t.expect(!lib.parse.configuredFor("x (komira//tools/build/platforms:linux-x86_64#)", "komira//tools/build/platforms:linux-x86_64"));
    try t.expect(!lib.parse.configuredFor("x (komira//tools/build/platforms:linux-x86_64)", "komira//tools/build/platforms:linux-x86_64"));
}

test "a line, exactly" {
    try t.expect(lib.parse.hasLine("a\ntoolchains//:cxx_no_default_deps\nb", "toolchains//:cxx_no_default_deps"));
    try t.expect(!lib.parse.hasLine("toolchains//:cxx_no_default_deps_x\n", "toolchains//:cxx_no_default_deps"));
    try t.expect(!lib.parse.hasLine(" toolchains//:cxx_no_default_deps\n", "toolchains//:cxx_no_default_deps"));
}

// `buck2 log what-ran` after a warm build of //tools/build/package/oci:komira_oci.
const WHATRAN_CACHE =
    "build\tkomira//tools/build/toolchains:zig (komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be) (zig_unpack)\tcache\tc74a55b0eb25f62e8f470a5d47bc44716bbfc4d87237e61d60c1ecd585bca9ad:141\n" ++
    "build\tkomira//tools/build/package/oci:komira_oci (komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be) (zig_build_exe)\tre(pool=mojo-sized)\tc1f07a47:142\n";

test "what-ran: farm runs and cache hits pass, a local action and an empty list do not" {
    const ok = lib.whatran.read(WHATRAN_CACHE);
    try t.expectEqual(@as(usize, 2), ok.actions);
    try t.expect(ok.first_local == null);
    const local = lib.whatran.read(WHATRAN_CACHE ++ "build\tkomira//x:y (cfg) (mojo_build)\tlocal\tenv -- mojo\n");
    try t.expectEqual(@as(usize, 3), local.actions);
    try t.expectEqual(@as(usize, 1), local.locals);
    try t.expectEqualStrings("komira//x:y (cfg) (mojo_build)", local.first_local.?);
    try t.expectEqual(@as(usize, 0), lib.whatran.read("").actions);
    try t.expect(!lib.whatran.remoteExecutor("worker"));
    try t.expect(!lib.whatran.remoteExecutor("remote_dep_file_cache_local"));
}

// `buck2 log what-ran` of a warm build of //tools/build/examples/libgate_ok
// rebuilt with `-c komira.rerun=komira//tools/build/examples/libgate_ok:libgate_ok#<n>`.
const LIBGATE = "komira//tools/build/examples/libgate_ok:libgate_ok";
const WHATRAN_RERUN =
    "build\tkomira//tools/build/examples/libgate_ok:libgate_ok (komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be) (mojo_gated_test test_payload_passes)\tre(pool=mojo-sized)\t2d3bb7f140485d25b0d946f3e996da3965d4fc7846d0aaf65be397610fd16319:141\n";

test "what-ran of a rerun: only the named target's actions, each executed on the farm" {
    const ok = lib.whatran.rerun(WHATRAN_RERUN, &.{LIBGATE});
    try t.expect(ok.ok());
    try t.expectEqual(@as(usize, 1), ok.ran);
    // The helper salting every target: another target's test ran too.
    const salted = lib.whatran.rerun(WHATRAN_RERUN ++ "build\tkomira//tools/build/markdown:markdown_unit (komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be) (zig_test)\tre(pool=mojo-sized)\tab:141\n", &.{LIBGATE});
    try t.expect(!salted.ok());
    try t.expectEqual(@as(usize, 1), salted.others);
    try t.expectEqualStrings("komira//tools/build/markdown:markdown_unit (komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be) (zig_test)", salted.first_other.?);
    // A rule that does not call rerun_env: nothing re-ran.
    try t.expect(!lib.whatran.rerun("", &.{LIBGATE}).ok());
    // The same <n> again: the action was a cache hit, not a fresh run.
    const cached = lib.whatran.rerun("build\tkomira//tools/build/examples/libgate_ok:libgate_ok (cfg) (mojo_gated_test x)\tcache\tab:141\n", &.{LIBGATE});
    try t.expect(!cached.ok());
    try t.expectEqual(@as(usize, 1), cached.stale);
    // A target whose label the named one's is a prefix of is another target.
    try t.expect(!lib.whatran.ofTarget("komira//tools/build/examples/libgate_ok:libgate_ok_x (cfg) (mojo_gated_test x)", LIBGATE));
    try t.expect(lib.whatran.ofTarget("komira//tools/build/examples/libgate_ok:libgate_ok (cfg) (mojo_gated_test x)", LIBGATE));
    // Several targets named: each one's runs are counted, an unnamed one is another.
    const two = WHATRAN_RERUN ++ "build\tkomira//tools/build/markdown:markdown_unit (cfg) (zig_test)\tre(pool=mojo-sized)\tab:141\n";
    try t.expect(lib.whatran.rerun(two, &.{ LIBGATE, "komira//tools/build/markdown:markdown_unit" }).ok());
    try t.expectEqual(@as(usize, 1), lib.whatran.ranOf(two, "komira//tools/build/markdown:markdown_unit"));
    try t.expectEqual(@as(usize, 0), lib.whatran.ranOf(two, "komira//tools/build/markdown:importer_unit"));
}

test "a refusal passes only when the command failed with the exact text" {
    const want = "pointer_lint tests//negative/pointer_lint:no_tree: name the files in exactly one of `tree` and `files`";
    try t.expectEqual(lib.refusals.Verdict.refused, lib.refusals.verdict(false, "", "Caused by:\n  " ++ want ++ "\n", want, &.{}));
    try t.expectEqual(lib.refusals.Verdict.analysed, lib.refusals.verdict(true, want, "", want, &.{}));
    try t.expectEqual(lib.refusals.Verdict.other_failure, lib.refusals.verdict(false, "", "name the files in exactly one of `tree` and files", want, &.{}));
    try t.expectEqual(lib.refusals.Verdict.other_failure, lib.refusals.verdict(false, "", "", want, &.{}));
    // Every `also` text is required too, and an empty text never matches.
    try t.expectEqual(lib.refusals.Verdict.refused, lib.refusals.verdict(false, "", "dep x (cfg#1) provides neither", "provides neither", &.{"dep x ("}));
    try t.expectEqual(lib.refusals.Verdict.other_failure, lib.refusals.verdict(false, "", "dep y (cfg#1) provides neither", "provides neither", &.{"dep x ("}));
    try t.expectEqual(lib.refusals.Verdict.other_failure, lib.refusals.verdict(false, "", "anything", "", &.{}));
}

test "the runner's argv: isolation dir in the checkout, the inner key before `--`" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try lib.runner.argv(a, "/b/buck2", "selftest_x", &.{ "bxl", "//f.bxl:check", "--", "--check", "//g:h" }, .{ .cfg = &.{"komira.coverage=yes"}, .target_platforms = "//p:q" });
    try t.expect(lib.text.eqlLists(&.{ "/b/buck2", "--isolation-dir", "selftest_x", "bxl", "//f.bxl:check", "-c", "komira_selftest.inner=true", "-c", "komira.coverage=yes", "--target-platforms", "//p:q", "--", "--check", "//g:h" }, got));
    const kill = try lib.runner.argv(a, "/b/buck2", null, &.{"kill"}, .{ .configured = false });
    try t.expect(lib.text.eqlLists(&.{ "/b/buck2", "kill" }, kill));
    const plain = try lib.runner.argv(a, "/b/buck2", "selftest_x", &.{ "audit", "providers", "//a:b" }, .{});
    try t.expect(lib.text.eqlLists(&.{ "/b/buck2", "--isolation-dir", "selftest_x", "audit", "providers", "//a:b", "-c", "komira_selftest.inner=true" }, plain));
}

test "a report that asserted nothing is red; one failure is red" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var empty = lib.expect.Report.init(arena.allocator(), "x");
    try t.expectEqual(lib.expect.Report.Outcome.asserted_nothing, empty.outcome());
    var r = lib.expect.Report.init(arena.allocator(), "x");
    r.passes = 3;
    try t.expectEqual(lib.expect.Report.Outcome.passed, r.outcome());
    r.fails = 1;
    try t.expectEqual(lib.expect.Report.Outcome.failed, r.outcome());
}

test "text helpers" {
    try t.expectEqual(@as(usize, 2), lib.text.count("executor: Remote( executor: Remote(", "executor: Remote("));
    try t.expectEqualStrings("c\nd", lib.text.tail("a\nb\nc\nd\n", 2));
    try t.expectEqualStrings("a\nb", lib.text.tail("a\nb", 5));
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const z = try lib.scratch.splitZ(arena.allocator(), "a/BUCK\x00b c.txt\x00");
    try t.expect(lib.text.eqlLists(&.{ "a/BUCK", "b c.txt" }, z));
}

// tools/build/buck2's layout, cut to the fields the guard reads.
const PIN =
    \\  "platforms": {
    \\    "linux-x86_64": {
    \\      "size": 39587698,
    \\      "digest": "1268fce33fb61273091dd5dd8c60b65de1521a3caa36b88983813e882b7ffd89",
    \\    },
    \\    "macos-aarch64": {
    \\      "digest": "aacdf7cabe34b9b5dc74866b8dcf7410cdbae3ad2dccef45b7ee9851cb781528",
    \\    }
;

test "the guard reads the linux-x86_64 pin of tools/buck2, and only it" {
    try t.expectEqualStrings("1268fce33fb61273091dd5dd8c60b65de1521a3caa36b88983813e882b7ffd89", lib.guard.pinnedDigest(PIN).?);
    try t.expect(lib.guard.pinnedDigest("\"linux-x86_64\": {\n },\n \"macos-aarch64\": {\n \"digest\": \"aacdf7cabe34b9b5dc74866b8dcf7410cdbae3ad2dccef45b7ee9851cb781528\"") == null);
    try t.expect(lib.guard.pinnedDigest("\"linux-x86_64\": {\n \"digest\": \"1268\"\n}") == null);
    try t.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &lib.guard.sha256Hex("abc"));
}

test "the pinned hash of a row of table.bzl" {
    const table = "ROWS = {\n    \"linux-x86_64\": {\n        \"golden_config_hash\": \"03cc1a891c89e4be\",\n    },\n    \"darwin-arm64\": {\n        \"golden_config_hash\": \"7fd7ccfd5d5f8024\",\n    },\n    \"linux-arm64\": {\n    },\n}\n";
    try std.testing.expectEqualStrings("03cc1a891c89e4be", lib.parse.goldenHash(table, "linux-x86_64").?);
    try std.testing.expectEqualStrings("7fd7ccfd5d5f8024", lib.parse.goldenHash(table, "darwin-arm64").?);
    try std.testing.expect(lib.parse.goldenHash(table, "linux-arm64") == null);
}
