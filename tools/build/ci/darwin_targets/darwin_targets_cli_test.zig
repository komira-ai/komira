//! The cases of darwin_targets' executable, //tools/build/ci:darwin_targets_cli_cases: each runs the
//! built tool (`DARWIN_TARGETS`, an exec tool) as pr.yml's step `the macOS targets to build` runs
//! it, with its flags, in a directory of the case's own under KOMIRA_TEST_WORK, over a recorded log
//! of darwin.bxl:select (fixtures/, darwin_targets_test.zig says what each is). Each checks the exit
//! code, stderr by exact equality, the targets file and the step output file byte for byte. What
//! the reading of a log holds is in darwin_targets_test.zig; these hold what only the executable
//! does: its flags, its exit codes, what it prints and the files it writes.
//! What the cases catch:
//!  - some libraries exit 0, write their targets and append `any=true` after the step output's
//!    earlier lines;
//!  - none exits 0, writes an empty targets file and leaves the step output as it was, so the
//!    build step is skipped;
//!  - a failed selection's log exits 1 with its `::error::` line and writes neither file;
//!  - wrong usage, a log that cannot be read, a targets file or a step output that cannot be
//!    written, exit 2 with their line.
const std = @import("std");
const t = std.testing;

const some = @embedFile("fixtures/select_some.log");
const none = @embedFile("fixtures/select_none.log");
const broken = @embedFile("fixtures/select_broken.log");

const USAGE = "usage: darwin_targets --log <buck2-farm.log> --out <darwin_targets.txt> --github-output <file>\n";
const EARLIER = "path=/opt/tool\n";

const Outcome = struct { code: u8, stderr: []const u8 };

var case_no: usize = 0;

/// A directory of the case's own holding `buck2-farm.log` (`log`) and `github_output` holding an
/// earlier step's line.
fn caseDir(ar: std.mem.Allocator, log: []const u8) ![]const u8 {
    case_no += 1;
    const dir = try std.fmt.allocPrint(ar, "{s}/case{d}", .{ try std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK"), case_no });
    try std.fs.cwd().makePath(dir);
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fs.path.join(ar, &.{ dir, "buck2-farm.log" }), .data = log });
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fs.path.join(ar, &.{ dir, "github_output" }), .data = EARLIER });
    return dir;
}

fn path(ar: std.mem.Allocator, dir: []const u8, rel: []const u8) ![]const u8 {
    return std.fs.path.join(ar, &.{ dir, rel });
}

/// Runs the built tool with `args` in `dir`, with an empty environment.
fn runTool(ar: std.mem.Allocator, dir: []const u8, args: []const []const u8) !Outcome {
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(ar, try std.process.getEnvVarOwned(ar, "DARWIN_TARGETS"));
    try argv.appendSlice(ar, args);
    var env = std.process.EnvMap.init(ar);
    const r = try std.process.Child.run(.{ .allocator = ar, .argv = argv.items, .cwd = dir, .env_map = &env });
    const code: u8 = switch (r.term) {
        .Exited => |c| c,
        else => 255,
    };
    try t.expectEqualStrings("", r.stdout);
    return .{ .code = code, .stderr = r.stderr };
}

/// The step's flags, with the files of `dir`.
fn stepArgs(ar: std.mem.Allocator, dir: []const u8) ![]const []const u8 {
    return ar.dupe([]const u8, &.{
        "--log",           try path(ar, dir, "buck2-farm.log"),
        "--out",           try path(ar, dir, "darwin_targets.txt"),
        "--github-output", try path(ar, dir, "github_output"),
    });
}

fn read(ar: std.mem.Allocator, dir: []const u8, rel: []const u8) ![]const u8 {
    return std.fs.cwd().readFileAlloc(ar, try path(ar, dir, rel), 1 << 20);
}

fn expectAbsent(ar: std.mem.Allocator, dir: []const u8, rel: []const u8) !void {
    try t.expectError(error.FileNotFound, std.fs.cwd().access(try path(ar, dir, rel), .{}));
}

test "some libraries exit 0, write their targets, and append any=true after the earlier lines" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const dir = try caseDir(ar, some);
    const o = try runTool(ar, dir, try stepArgs(ar, dir));
    try t.expectEqualStrings("darwin_targets: SOME: 17 target(s) for macOS\n", o.stderr);
    try t.expectEqual(@as(u8, 0), o.code);
    try t.expectEqualStrings(
        "komira//src/broker_proto:lib\nkomira//src/calendar:lib\nkomira//src/calendar_ics:lib\n" ++
            "komira//src/calendar_proto:lib\nkomira//src/chat_proto:lib\nkomira//src/contacts_proto:lib\n" ++
            "komira//src/crm_proto:lib\nkomira//src/crypto:lib\nkomira//src/encoding:lib\n" ++
            "komira//src/job_report_proto:lib\nkomira//src/mail_message:lib\nkomira//src/managed_mail_proto:lib\n" ++
            "komira//src/mcp_server:lib\nkomira//src/plan_proto:lib\nkomira//src/proto_codec:lib\n" ++
            "komira//src/supervisor_proto:lib\nkomira//src/wkt:lib\n",
        try read(ar, dir, "darwin_targets.txt"),
    );
    try t.expectEqualStrings(EARLIER ++ "any=true\n", try read(ar, dir, "github_output"));
}

test "none exits 0, writes an empty targets file, and leaves the step output as it was" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const dir = try caseDir(ar, none);
    const o = try runTool(ar, dir, try stepArgs(ar, dir));
    try t.expectEqualStrings("darwin_targets: NONE: 0 target(s) for macOS\n", o.stderr);
    try t.expectEqual(@as(u8, 0), o.code);
    try t.expectEqualStrings("", try read(ar, dir, "darwin_targets.txt"));
    try t.expectEqualStrings(EARLIER, try read(ar, dir, "github_output"));
}

test "a failed selection's log exits 1 with its line and writes neither file" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const dir = try caseDir(ar, broken);
    const o = try runTool(ar, dir, try stepArgs(ar, dir));
    try t.expectEqualStrings("::error::the log holds no verdict of darwin.bxl:select: it is not the selection's log, or the selection failed\n", o.stderr);
    try t.expectEqual(@as(u8, 1), o.code);
    try expectAbsent(ar, dir, "darwin_targets.txt");
    try t.expectEqualStrings(EARLIER, try read(ar, dir, "github_output"));
}

test "wrong usage exits 2 with the usage line" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const dir = try caseDir(ar, some);
    const o = try runTool(ar, dir, &.{ "--log", try path(ar, dir, "buck2-farm.log") });
    try t.expectEqualStrings(USAGE, o.stderr);
    try t.expectEqual(@as(u8, 2), o.code);
    try expectAbsent(ar, dir, "darwin_targets.txt");
}

test "a log that cannot be read exits 2 with its line" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const dir = try caseDir(ar, some);
    const missing = try path(ar, dir, "no.log");
    const o = try runTool(ar, dir, &.{ "--log", missing, "--out", try path(ar, dir, "darwin_targets.txt"), "--github-output", try path(ar, dir, "github_output") });
    try t.expectEqualStrings(try std.fmt.allocPrint(ar, "::error::the log {s} cannot be read\n", .{missing}), o.stderr);
    try t.expectEqual(@as(u8, 2), o.code);
    try expectAbsent(ar, dir, "darwin_targets.txt");
}

test "a targets file that cannot be written exits 2 with its line, and the step output is unchanged" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const dir = try caseDir(ar, some);
    const out = try path(ar, dir, "no/darwin_targets.txt");
    const o = try runTool(ar, dir, &.{ "--log", try path(ar, dir, "buck2-farm.log"), "--out", out, "--github-output", try path(ar, dir, "github_output") });
    try t.expectEqualStrings(try std.fmt.allocPrint(ar, "::error::the targets file {s} cannot be written\n", .{out}), o.stderr);
    try t.expectEqual(@as(u8, 2), o.code);
    try t.expectEqualStrings(EARLIER, try read(ar, dir, "github_output"));
}

test "a step output that cannot be written exits 2 with its line" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const dir = try caseDir(ar, some);
    const gh = try path(ar, dir, "no/github_output");
    const o = try runTool(ar, dir, &.{ "--log", try path(ar, dir, "buck2-farm.log"), "--out", try path(ar, dir, "darwin_targets.txt"), "--github-output", gh });
    try t.expectEqualStrings(try std.fmt.allocPrint(ar, "::error::the step output {s} cannot be written\n", .{gh}), o.stderr);
    try t.expectEqual(@as(u8, 2), o.code);
}
