//! Unit tests of `cov_branch run` (cov_branch_run.zig), run by `zig test`
//! as a build action (`:cov_branch_unit`). Each process step is a stand-in
//! (`Fake`, a Runner) that writes what the real program would (gate_runner's
//! stderr and the raw profiles, llvm-profdata's log and output), so every
//! decision of the subcommand is reached without a test binary or LLVM. What
//! a real run does end to end is test 47's (tools/build/tests/coverage_runs.md).

const std = @import("std");
const br = @import("bounded_run.zig");
const r = @import("cov_branch_run.zig");
const testing = std.testing;

const Raw = struct { name: []const u8, bytes: []const u8 };

fn header(version: u32, flags: u32) [16]u8 {
    var b: [16]u8 = undefined;
    std.mem.writeInt(u64, b[0..8], r.RAW_MAGIC, .little);
    std.mem.writeInt(u32, b[8..12], version, .little);
    std.mem.writeInt(u32, b[12..16], flags, .little);
    return b;
}

const good = header(11, 0x01000000);

const SHOW_OK = "Instrumentation level: IR  entry_first = 0\nTotal functions: 549\nMaximum function count: 1\n";

const Fake = struct {
    alloc: std.mem.Allocator,
    gate_status: br.Status = .{ .exited = 0 },
    gate_err: []const u8 = "",
    raws: []const Raw = &.{.{ .name = "100.profraw", .bytes = &good }},
    merge_status: br.Status = .{ .exited = 0 },
    merge_log: []const u8 = "",
    show_status: br.Status = .{ .exited = 0 },
    show_text: []const u8 = SHOW_OK,
    calls: std.ArrayList(br.Spec),

    fn init(alloc: std.mem.Allocator) Fake {
        return .{ .alloc = alloc, .calls = std.ArrayList(br.Spec).init(alloc) };
    }

    fn runner(self: *Fake) r.Runner {
        return .{ .ptr = self, .runFn = &run };
    }

    fn write(path: []const u8, data: []const u8) !void {
        var f = try std.fs.cwd().createFile(path, .{});
        defer f.close();
        try f.writeAll(data);
    }

    fn run(ptr: *anyopaque, alloc: std.mem.Allocator, spec: br.Spec) anyerror!br.Outcome {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        // The spec's slices outlive the call only in the arena: copy them.
        var copy = spec;
        copy.argv = try alloc.dupe([]const u8, spec.argv);
        copy.env = try alloc.dupe([]const u8, spec.env);
        try self.calls.append(copy);
        var status: br.Status = .{ .exited = 0 };
        if (spec.argv.len > 1 and std.mem.eql(u8, spec.argv[1], "sh")) {
            try write(spec.stderr_path.?, self.gate_err);
            // Where LLVM_PROFILE_FILE points: <dir>/%p.profraw.
            const last = spec.argv[spec.argv.len - 1];
            const dir = std.fs.path.dirname(last["LLVM_PROFILE_FILE=".len..]).?;
            for (self.raws) |raw| {
                const p = try std.fs.path.join(alloc, &.{ dir, raw.name });
                if (std.fs.path.dirname(p)) |d| try std.fs.cwd().makePath(d);
                try write(p, raw.bytes);
            }
            status = self.gate_status;
        } else if (std.mem.eql(u8, spec.argv[1], "merge")) {
            try write(spec.stdout_path.?, self.merge_log);
            status = self.merge_status;
            if (status == .exited and status.exited == 0) try write(spec.argv[3], "indexed");
        } else if (std.mem.eql(u8, spec.argv[1], "show")) {
            try write(spec.stdout_path.?, self.show_text);
            status = self.show_status;
        } else return error.UnknownStep;
        return .{ .status = status, .timed_out = false, .pgid = 1, .survivors = &.{} };
    }
};

const Case = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    root: []const u8 = "",
    err: std.ArrayList(u8) = undefined,

    fn init() !Case {
        var c = Case{ .arena = std.heap.ArenaAllocator.init(testing.allocator), .tmp = testing.tmpDir(.{}) };
        c.root = try c.tmp.dir.realpathAlloc(c.arena.allocator(), ".");
        return c;
    }

    fn deinit(self: *Case) void {
        self.tmp.cleanup();
        self.arena.deinit();
    }

    fn a(self: *Case) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn where(self: *Case) !r.Where {
        return .{
            .cwd = self.root,
            .k = try std.fmt.allocPrint(self.a(), "{s}/scratch/cov_branch_run", .{self.root}),
            .env = &.{ "HOME=/home/user", "LC_ALL=fr_FR.UTF-8", "PATH=/usr/bin:/bin", "ZED=1" },
        };
    }

    fn args(_: *Case) r.Args {
        return .{
            .busybox = "tc/busybox",
            .gate_runner = "mojo/gate_runner.sh",
            .compiler = "tc/compiler",
            .label = "//p:lib:tests/test_one.mojo [branch coverage]",
            .profdata = "run/llvm/bin/llvm-profdata",
            .raw_version = 11,
            .binary = "root/bin/test_one",
            .out = "out/test_one.profdata",
            .env = &.{ "A=1", "B=two words" },
        };
    }

    /// Runs the subcommand against `fake`; its exit status.
    fn go(self: *Case, fake: *Fake) !u8 {
        self.err = std.ArrayList(u8).init(self.a());
        try self.tmp.dir.makePath("out");
        return r.runAll(self.a(), self.args(), try self.where(), fake.runner(), &self.err);
    }

    fn has(self: *Case, text: []const u8) bool {
        return std.mem.indexOf(u8, self.err.items, text) != null;
    }
};

fn hasEntry(env: []const []const u8, e: []const u8) bool {
    for (env) |x| if (std.mem.eql(u8, x, e)) return true;
    return false;
}

fn countPrefix(env: []const []const u8, p: []const u8) usize {
    var n: usize = 0;
    for (env) |x| {
        if (std.mem.startsWith(u8, x, p)) n += 1;
    }
    return n;
}

test "a passing run: the gate's command line, the environments, the merge of every profile, and no message" {
    var c = try Case.init();
    defer c.deinit();
    var fake = Fake.init(c.a());
    fake.raws = &.{ .{ .name = "200.profraw", .bytes = &good }, .{ .name = "100.profraw", .bytes = &good } };
    try testing.expectEqual(@as(u8, 0), try c.go(&fake));
    try testing.expectEqualStrings("", c.err.items);
    try testing.expectEqual(@as(usize, 3), fake.calls.items.len);
    const k = (try c.where()).k;
    const ab = struct {
        fn f(cc: *Case, p: []const u8) []const u8 {
            return std.fmt.allocPrint(cc.a(), "{s}/{s}", .{ cc.root, p }) catch unreachable;
        }
    }.f;
    // 1. gate_runner, as the release gate runs it, then LLVM_PROFILE_FILE.
    const gate = fake.calls.items[0];
    const want = [_][]const u8{
        ab(&c, "tc/busybox"),                                                         "sh",
        ab(&c, "mojo/gate_runner.sh"),                                                ab(&c, "tc/busybox"),
        "tc/compiler",                                                                "//p:lib:tests/test_one.mojo [branch coverage]",
        ab(&c, "root/bin/test_one"),                                                  try std.fmt.allocPrint(c.a(), "{s}/gate.passed", .{k}),
        "--env",                                                                      "A=1",
        "--env",                                                                      "B=two words",
        "--env",                                                                      try std.fmt.allocPrint(c.a(), "LLVM_PROFILE_FILE={s}/prof/%p.profraw", .{k}),
    };
    try testing.expectEqual(want.len, gate.argv.len);
    for (want, gate.argv) |w, g| try testing.expectEqualStrings(w, g);
    try testing.expectEqualStrings(try std.fmt.allocPrint(c.a(), "{s}/gate.err", .{k}), gate.stderr_path.?);
    try testing.expect(gate.stdout_path == null and gate.limit_ms == null);
    // The gate's environment: this tool's, PATH an empty directory, no LC_ALL
    // of its own (the test gets the gate's environment).
    try testing.expect(hasEntry(gate.env, try std.fmt.allocPrint(c.a(), "PATH={s}/bin", .{k})));
    try testing.expectEqual(@as(usize, 1), countPrefix(gate.env, "PATH="));
    try testing.expect(hasEntry(gate.env, "LC_ALL=fr_FR.UTF-8"));
    try testing.expect(hasEntry(gate.env, "HOME=/home/user") and hasEntry(gate.env, "ZED=1"));
    // 4. The merge of both profiles, sorted, into the absolute output.
    const merge = fake.calls.items[1];
    const out = ab(&c, "out/test_one.profdata");
    try testing.expectEqual(@as(usize, 6), merge.argv.len);
    try testing.expectEqualStrings("run/llvm/bin/llvm-profdata", merge.argv[0]);
    try testing.expectEqualStrings("merge", merge.argv[1]);
    try testing.expectEqualStrings("-o", merge.argv[2]);
    try testing.expectEqualStrings(out, merge.argv[3]);
    try testing.expect(std.mem.endsWith(u8, merge.argv[4], "/prof/100.profraw"));
    try testing.expect(std.mem.endsWith(u8, merge.argv[5], "/prof/200.profraw"));
    try testing.expect(merge.stderr_to_stdout);
    try testing.expect(hasEntry(merge.env, "LC_ALL=C"));
    try testing.expectEqual(@as(usize, 1), countPrefix(merge.env, "LC_ALL="));
    const show = fake.calls.items[2];
    try testing.expectEqual(@as(usize, 3), show.argv.len);
    try testing.expectEqualStrings("show", show.argv[1]);
    try testing.expectEqualStrings(out, show.argv[2]);
    // The scratch directory is removed after a success.
    try testing.expectError(error.FileNotFound, std.fs.cwd().access(k, .{}));
}

test "a failing test: its exit status, its output without gate_runner's banner, this run's message" {
    var c = try Case.init();
    defer c.deinit();
    var fake = Fake.init(c.a());
    fake.gate_status = .{ .exited = 1 };
    fake.gate_err = "==================================================================\n" ++
        "GATED TEST FAILED: //p:lib:tests/test_one.mojo [branch coverage] (exit 1)\n" ++
        "The library's package is not produced until this test passes.\n" ++
        "------------------------------------------------------------------ output\n" ++
        "assert failed: LLVM_PROFILE_FILE is set\n" ++
        "==================================================================\n";
    try testing.expectEqual(@as(u8, 1), try c.go(&fake));
    try testing.expect(!c.has("GATED TEST FAILED"));
    try testing.expect(!c.has("package is not produced"));
    try testing.expect(c.has("------------------------------------------------------------------ output\nassert failed: LLVM_PROFILE_FILE is set\n"));
    try testing.expect(c.has("BRANCH COVERAGE RUN FAILED: //p:lib:tests/test_one.mojo [branch coverage]\nThe test failed instrumented for branch coverage (exit 1). A branch coverage run builds the test at -O0"));
    // Nothing after the gate ran.
    try testing.expectEqual(@as(usize, 1), fake.calls.items.len);
}

test "a test killed by a signal fails with 128 + N" {
    var c = try Case.init();
    defer c.deinit();
    var fake = Fake.init(c.a());
    fake.gate_status = .{ .signaled = 9 };
    try testing.expectEqual(@as(u8, 137), try c.go(&fake));
    try testing.expect(c.has("The test failed instrumented for branch coverage (exit 137)."));
}

test "the banner is dropped once, and only as its pair of lines" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var out = std.ArrayList(u8).init(arena.allocator());
    const h = "GATED TEST FAILED: L (exit 2)";
    const p = "The library's package is not produced until this test passes.";
    try r.gateFailure(arena.allocator(), &out, "L", 2, h ++ "\nnot the second line\n" ++ h ++ "\n" ++ p ++ "\n" ++ h ++ "\n" ++ p ++ "\n");
    const want = h ++ "\nnot the second line\n" ++ h ++ "\n" ++ p ++ "\n";
    try testing.expect(std.mem.startsWith(u8, out.items, want));
    try testing.expect(std.mem.indexOf(u8, out.items, "BRANCH COVERAGE RUN FAILED: L\n") != null);
    // Another label's banner is kept.
    out.clearRetainingCapacity();
    try r.gateFailure(arena.allocator(), &out, "L", 2, "GATED TEST FAILED: M (exit 2)\n" ++ p ++ "\n");
    try testing.expect(std.mem.startsWith(u8, out.items, "GATED TEST FAILED: M (exit 2)\n" ++ p ++ "\n"));
}

test "no raw profile written fails, naming where they were to be" {
    var c = try Case.init();
    defer c.deinit();
    var fake = Fake.init(c.a());
    fake.raws = &.{.{ .name = "default.profdata", .bytes = &good }};
    try testing.expectEqual(@as(u8, 1), try c.go(&fake));
    const k = (try c.where()).k;
    try testing.expect(c.has(try std.fmt.allocPrint(c.a(), "BRANCH COVERAGE RUN FAILED: //p:lib:tests/test_one.mojo [branch coverage]\nThe test passed but wrote no .profraw under {s}/prof (LLVM_PROFILE_FILE): the profile runtime did not run its exit handler, or the variable did not reach the test.\n", .{k})));
    try testing.expectEqual(@as(usize, 1), fake.calls.items.len);
}

test "raw profiles are found at any depth, and only *.profraw files" {
    var c = try Case.init();
    defer c.deinit();
    try c.tmp.dir.makePath("p/sub");
    try c.tmp.dir.makePath("p/d.profraw");
    try c.tmp.dir.writeFile("p/b.profraw", "");
    try c.tmp.dir.writeFile("p/sub/a.profraw", "");
    try c.tmp.dir.writeFile("p/c.profraw.tmp", "");
    const p = try std.fs.path.join(c.a(), &.{ c.root, "p" });
    const got = try r.listRaws(c.a(), p);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expect(std.mem.endsWith(u8, got[0], "/p/b.profraw"));
    try testing.expect(std.mem.endsWith(u8, got[1], "/p/sub/a.profraw"));
}

test "a raw profile of another version is refused before the merge" {
    var c = try Case.init();
    defer c.deinit();
    var fake = Fake.init(c.a());
    const v12 = header(12, 0x01000000);
    fake.raws = &.{ .{ .name = "1.profraw", .bytes = &good }, .{ .name = "2.profraw", .bytes = &v12 } };
    try testing.expectEqual(@as(u8, 1), try c.go(&fake));
    try testing.expect(c.has("2.profraw has raw profile version 12, not 11, the version the pinned llvm-profdata reads (toolchains/llvm_branch/README.md, The version coupling).\n"));
    try testing.expectEqual(@as(usize, 1), fake.calls.items.len);
}

test "a raw profile without the IR bit is refused" {
    var c = try Case.init();
    defer c.deinit();
    var fake = Fake.init(c.a());
    const plain = header(11, 0x00000000);
    fake.raws = &.{.{ .name = "7.profraw", .bytes = &plain }};
    try testing.expectEqual(@as(u8, 1), try c.go(&fake));
    try testing.expect(c.has("7.profraw has variant flags 0x00000000, without the IR-instrumentation bit 0x01000000: its version word is the profile runtime's default, not the instrumenter's"));
    try testing.expectEqual(@as(usize, 1), fake.calls.items.len);
}

fn refusal(r_: ?[]const u8) ![]const u8 {
    return r_ orelse error.TestExpectedRefusal;
}

test "checkRaw: the magic, the version and the IR bit, each alone" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();
    try testing.expect((try r.checkRaw(al, "f", &good, 11)) == null);
    // Other variant bits next to the IR bit are fine.
    const more = header(11, 0x05000000);
    try testing.expect((try r.checkRaw(al, "f", &more, 11)) == null);
    var bad = good;
    bad[0] = 0x80;
    try testing.expectEqualStrings("f does not start with the 64-bit raw profile magic (got 'ff6c70726f667280')", try refusal(try r.checkRaw(al, "f", &bad, 11)));
    // A file shorter than the magic is refused as one without it.
    try testing.expect(std.mem.indexOf(u8, try refusal(try r.checkRaw(al, "f", good[0..4], 11)), "does not start with the 64-bit raw profile magic") != null);
    try testing.expect(std.mem.indexOf(u8, try refusal(try r.checkRaw(al, "f", &good, 10)), "has raw profile version 11, not 10") != null);
    try testing.expect(std.mem.indexOf(u8, try refusal(try r.checkRaw(al, "f", good[0..12], 11)), "has variant flags 0x00000000") != null);
    const ir_only_high = header(11, 0x02000000);
    try testing.expect(std.mem.indexOf(u8, try refusal(try r.checkRaw(al, "f", &ir_only_high, 11)), "has variant flags 0x02000000, without") != null);
}

test "a merge refused for its version says which version llvm-profdata expects" {
    var c = try Case.init();
    defer c.deinit();
    var fake = Fake.init(c.a());
    fake.raws = &.{ .{ .name = "1.profraw", .bytes = &good }, .{ .name = "2.profraw", .bytes = &good } };
    fake.merge_status = .{ .exited = 1 };
    fake.merge_log = "warning: /k/prof/1.profraw: raw profile version mismatch: Profile uses raw profile format version = 11; expected version = 10\n" ++
        "warning: /k/prof/2.profraw: raw profile version mismatch: Profile uses raw profile format version = 11; expected version = 9\n" ++
        "warning: again; expected version = 10\n" ++
        "error: no profile can be merged\n";
    try testing.expectEqual(@as(u8, 1), try c.go(&fake));
    try testing.expect(c.has("llvm-profdata refused a raw profile of version 11: it expects 10 9: warning: /k/prof/1.profraw: raw profile version mismatch: Profile uses raw profile format version = 11; expected version = 10 warning: /k/prof/2.profraw: raw profile version mismatch: Profile uses raw profile format version = 11; expected version = 9 \n"));
    try testing.expectEqual(@as(usize, 2), fake.calls.items.len);
}

test "a line holding the expected version twice gives its last one with digits" {
    var c = try Case.init();
    defer c.deinit();
    var fake = Fake.init(c.a());
    fake.merge_status = .{ .exited = 1 };
    // As the script's greedy sed: the last "; expected version = " followed
    // by digits, so 10 (not 8) on the first line, and 9 on the second, whose
    // last one has none.
    fake.merge_log = "warning: raw profile version mismatch: x; expected version = 8; expected version = 10\n" ++
        "warning: y; expected version = 9; expected version = \n";
    try testing.expectEqual(@as(u8, 1), try c.go(&fake));
    try testing.expect(c.has("llvm-profdata refused a raw profile of version 11: it expects 10 9: "));
}

test "any other merge failure gives the first three lines of its log" {
    var c = try Case.init();
    defer c.deinit();
    var fake = Fake.init(c.a());
    fake.merge_status = .{ .exited = 1 };
    fake.merge_log = "one\ntwo\nthree\nfour\n";
    try testing.expectEqual(@as(u8, 1), try c.go(&fake));
    try testing.expect(c.has("llvm-profdata merge failed on 1 raw profile(s): one two three \n"));
}

test "a failing show, a profile that is not IR, and one with no function are refused" {
    {
        var c = try Case.init();
        defer c.deinit();
        var fake = Fake.init(c.a());
        fake.show_status = .{ .exited = 1 };
        fake.show_text = "error: bad\nline2\nline3\n";
        try testing.expectEqual(@as(u8, 1), try c.go(&fake));
        try testing.expect(c.has("llvm-profdata show failed on the merged profile: error: bad line2 \n"));
    }
    {
        var c = try Case.init();
        defer c.deinit();
        var fake = Fake.init(c.a());
        fake.show_text = "Instrumentation level: Front-end\nTotal functions: 3\n";
        try testing.expectEqual(@as(u8, 1), try c.go(&fake));
        try testing.expect(c.has("the merged profile is not an IR-instrumentation profile: Instrumentation level: Front-end\n"));
    }
    {
        var c = try Case.init();
        defer c.deinit();
        var fake = Fake.init(c.a());
        fake.show_text = "Instrumentation level: IR\nTotal functions: 0\n";
        try testing.expectEqual(@as(u8, 1), try c.go(&fake));
        try testing.expect(c.has("the merged profile has no function: Instrumentation level: IR Total functions: 0 \n"));
    }
}

test "checkShow: exactly one Total functions line, above 0" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect((try r.checkShow(a, SHOW_OK)) == null);
    try testing.expect((try r.checkShow(a, "Instrumentation level: IR\nTotal functions: 007\n")) == null);
    try testing.expect((try r.checkShow(a, "Instrumentation level: IR\n")) != null);
    try testing.expect((try r.checkShow(a, "Instrumentation level: IR\nTotal functions: 3\nTotal functions: 4\n")) != null);
    try testing.expect((try r.checkShow(a, "Instrumentation level: IR\nTotal functions: 3x\n")) != null);
    try testing.expect((try r.checkShow(a, "Instrumentation level: IR\n Total functions: 3\n")) != null);
    try testing.expect((try r.checkShow(a, "Instrumentation level: IR\nTotal functions: \n")) != null);
}

fn usage(argv: []const []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var err = std.ArrayList(u8).init(a);
    const where = r.Where{ .cwd = "/nowhere", .k = "/nowhere/k", .env = &.{} };
    var fake = Fake.init(a);
    const code = try r.cli(a, argv, where, fake.runner(), &err);
    try testing.expectEqual(@as(u8, 2), code);
    try testing.expectEqual(@as(usize, 0), fake.calls.items.len);
    return testing.allocator.dupe(u8, err.items);
}

fn expectUsage(argv: []const []const u8, text: []const u8) !void {
    const got = try usage(argv);
    defer testing.allocator.free(got);
    if (std.mem.indexOf(u8, got, text) == null) {
        std.debug.print("want {s}\ngot {s}\n", .{ text, got });
        return error.TestUnexpectedResult;
    }
}

const full = [_][]const u8{ "--busybox", "b", "--gate-runner", "g", "--compiler", "c", "--label", "l", "--profdata", "/nonexistent/llvm-profdata", "--raw-version", "11", "--binary", "x", "--out", "o" };

test "usage errors: a missing, repeated, empty or unknown flag, a bad version, a missing llvm-profdata" {
    try expectUsage(full[0..14], "usage error: --out is missing");
    try expectUsage(full[0..15], "usage error: --out needs a value");
    try expectUsage(&(full ++ [_][]const u8{ "--label", "m" }), "usage error: --label given twice");
    try expectUsage(&(full ++ [_][]const u8{"--env"}), "usage error: --env needs a value");
    try expectUsage(&(full ++ [_][]const u8{ "--arg", "x" }), "usage error: unknown argument --arg");
    var f = full;
    f[7] = "";
    try expectUsage(&f, "usage error: --label is empty");
    for ([_][]const u8{ "011", "0", "1x", "-1", "99999999999" }) |v| {
        f = full;
        f[11] = v;
        try expectUsage(&f, "is '");
    }
    // Every flag right: llvm-profdata must be there and executable.
    try expectUsage(&full, "cov_branch run: /nonexistent/llvm-profdata is missing");
}

test "parseArgs keeps every --env in order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var why: []const u8 = "";
    const a = (try r.parseArgs(arena.allocator(), &(full ++ [_][]const u8{ "--env", "A=1", "--env", "A=2" }), &why)).?;
    try testing.expectEqual(@as(u32, 11), a.raw_version);
    try testing.expectEqual(@as(usize, 2), a.env.len);
    try testing.expectEqualStrings("A=1", a.env[0]);
    try testing.expectEqualStrings("A=2", a.env[1]);
}

test "the scratch directory follows BUCK_SCRATCH_PATH" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/w/.cov_branch_run", try r.scratchDir(a, "/w", null));
    try testing.expectEqualStrings("/w/.cov_branch_run", try r.scratchDir(a, "/w", ""));
    try testing.expectEqualStrings("/s/cov_branch_run", try r.scratchDir(a, "/w", "/s"));
    try testing.expectEqualStrings("/w/buck-out/tmp/cov_branch_run", try r.scratchDir(a, "/w", "buck-out/tmp"));
}

test "headJoined is head -n N | tr newline space" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("a b ", try r.headJoined(a, "a\nb\nc\n", 2));
    try testing.expectEqualStrings("a b", try r.headJoined(a, "a\nb", 3));
    try testing.expectEqualStrings("", try r.headJoined(a, "", 2));
}
