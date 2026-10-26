//! The release tools' cases (release/ci/check_release_ref.zig and
//! release_json.zig), run by the zig_test //release/ci/tests:test_release as a
//! build action: building a tool is running them. The release set's own cases
//! are test_set_json.zig, part of the same target.
//!
//! git is a script in these cases (the build worker has none, and a case must
//! not depend on a checkout): a command the script does not name answers
//! exit 99, so a tool that asks git something else, or the same thing of
//! another commit, is red. Each case names the defect it would catch.
//!
//! - the guard (ref_guard.zig): the rules of the release workflow's guard as
//!   the retired release machine held them, one row each: a push of main's
//!   history, the checkout that is not the commit, the ref in another case,
//!   a manual run's reason, the skip of a commit with nothing to release.
//! - the stamp (stamp.zig): the commit, the build number and the time of the
//!   release_version.sh rule, and each of its refusals.
//! - the artifacts file (artifacts.zig): the names and the metapackage's
//!   arguments the set is held to.
//! - the flags (util.zig).
const std = @import("std");
const lib = @import("release_lib");
const t = std.testing;

const util = lib.util;
const guard = lib.ref_guard;
const stamp = lib.stamp;
const artifacts = lib.artifacts;

test {
    _ = @import("test_set_json.zig");
}

const SHA = "0123456789abcdef0123456789abcdef01234567";
const OTHER = "89abcdef0123456789abcdef0123456789abcdef";

const Step = struct { cmd: []const u8, code: u8 = 0, out: []const u8 = "", err: []const u8 = "" };

const FakeGit = struct {
    steps: []const Step,

    pub fn run(self: FakeGit, a: std.mem.Allocator, args: []const []const u8) anyerror!util.GitOut {
        const cmd = try std.mem.join(a, " ", args);
        for (self.steps) |s| {
            if (std.mem.eql(u8, s.cmd, cmd)) return .{ .code = s.code, .stdout = s.out, .stderr = s.err };
        }
        return .{ .code = 99, .stdout = "", .stderr = cmd };
    }
};

const HEAD_OK = Step{ .cmd = "rev-parse --verify HEAD", .out = SHA ++ "\n" };
const ON_MAIN = Step{ .cmd = "merge-base --is-ancestor " ++ SHA ++ " refs/remotes/origin/main" };

fn push(artifacts_exist: bool) guard.Input {
    return .{ .event = "push", .ref = "refs/heads/main", .sha = SHA, .artifacts = "release/artifacts.textproto", .artifacts_exist = artifacts_exist };
}

fn manual(reason: []const u8) guard.Input {
    return .{ .event = "workflow_dispatch", .ref = "refs/heads/work", .sha = SHA, .reason = reason, .actor = "octocat", .artifacts = "release/artifacts.textproto", .artifacts_exist = true };
}

fn refusal(o: guard.Outcome, needle: []const u8) !void {
    switch (o) {
        .refuse => |why| if (std.mem.indexOf(u8, why, needle) == null) {
            std.debug.print("refusal '{s}' does not say '{s}'\n", .{ why, needle });
            return error.TestWrongRefusal;
        },
        else => return error.TestExpectedRefusal,
    }
}

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(t.allocator);
}

// ---- the guard ----------------------------------------------------------------

test "a push to main of a commit on main's history is a release, and says nothing" {
    var ar = arena();
    defer ar.deinit();
    const o = try guard.decide(ar.allocator(), push(true), FakeGit{ .steps = &.{ HEAD_OK, ON_MAIN } });
    try t.expect(o == .release);
    try t.expect(o.release == null);
}

test "a push whose commit is not on main's history is refused; so is one git cannot tell" {
    var ar = arena();
    defer ar.deinit();
    const off = Step{ .cmd = ON_MAIN.cmd, .code = 1 };
    try refusal(try guard.decide(ar.allocator(), push(true), FakeGit{ .steps = &.{ HEAD_OK, off } }), "is not on main's history");
    const broken = Step{ .cmd = ON_MAIN.cmd, .code = 128, .err = "fatal: Not a valid object name refs/remotes/origin/main" };
    try refusal(try guard.decide(ar.allocator(), push(true), FakeGit{ .steps = &.{ HEAD_OK, broken } }), "cannot be told");
}

test "the checkout must be the commit the run started on" {
    var ar = arena();
    defer ar.deinit();
    const moved = Step{ .cmd = HEAD_OK.cmd, .out = OTHER ++ "\n" };
    try refusal(try guard.decide(ar.allocator(), push(true), FakeGit{ .steps = &.{ moved, ON_MAIN } }), "is not " ++ SHA);
    try refusal(try guard.decide(ar.allocator(), manual("why"), FakeGit{ .steps = &.{moved} }), "is not " ++ SHA);
    const none = Step{ .cmd = HEAD_OK.cmd, .code = 128, .err = "fatal: not a git repository" };
    try refusal(try guard.decide(ar.allocator(), push(true), FakeGit{ .steps = &.{none} }), "failed (128)");
}

test "only a push to main and a manual run build a release" {
    var ar = arena();
    defer ar.deinit();
    const git = FakeGit{ .steps = &.{ HEAD_OK, ON_MAIN } };
    var in = push(true);
    in.event = "pull_request";
    try refusal(try guard.decide(ar.allocator(), in, git), "a pull_request of refs/heads/main");
    in = push(true);
    in.ref = "refs/heads/other";
    try refusal(try guard.decide(ar.allocator(), in, git), "a push of refs/heads/other");
    in = push(true);
    in.event = "schedule";
    try refusal(try guard.decide(ar.allocator(), in, git), "a schedule of");
}

test "a ref that is main in another case is refused for every event" {
    var ar = arena();
    defer ar.deinit();
    const git = FakeGit{ .steps = &.{ HEAD_OK, ON_MAIN } };
    var in = push(true);
    in.ref = "refs/heads/MAIN";
    try refusal(try guard.decide(ar.allocator(), in, git), "main in another case");
    in = manual("why");
    in.ref = "refs/heads/Main";
    try refusal(try guard.decide(ar.allocator(), in, git), "main in another case");
}

test "what the run is must be known, and the sha a full commit id" {
    var ar = arena();
    defer ar.deinit();
    const git = FakeGit{ .steps = &.{ HEAD_OK, ON_MAIN } };
    var in = push(true);
    in.event = "";
    try refusal(try guard.decide(ar.allocator(), in, git), "cannot be told");
    in = push(true);
    in.ref = "";
    try refusal(try guard.decide(ar.allocator(), in, git), "cannot be told");
    in = push(true);
    in.sha = SHA[0..8];
    try refusal(try guard.decide(ar.allocator(), in, git), "not a full commit id");
    in = push(true);
    in.sha = "0123456789ABCDEF0123456789abcdef01234567";
    try refusal(try guard.decide(ar.allocator(), in, git), "not a full commit id");
}

test "a manual run is break-glass: its reason is recorded in the first summary line" {
    var ar = arena();
    defer ar.deinit();
    const o = try guard.decide(ar.allocator(), manual("  rebuild after a farm outage  "), FakeGit{ .steps = &.{HEAD_OK} });
    try t.expect(o == .release);
    try t.expectEqualStrings("BREAK-GLASS: refs/heads/work 01234567 by octocat: rebuild after a farm outage", o.release.?);
}

test "a manual run's reason is 1 to 200 bytes on one line, once trimmed" {
    var ar = arena();
    defer ar.deinit();
    const git = FakeGit{ .steps = &.{HEAD_OK} };
    try refusal(try guard.decide(ar.allocator(), manual(""), git), "needs --reason");
    try refusal(try guard.decide(ar.allocator(), manual("   \t "), git), "needs --reason");
    try refusal(try guard.decide(ar.allocator(), manual("a" ** 201), git), "201 bytes");
    // a second line is a forged line of the job summary
    try refusal(try guard.decide(ar.allocator(), manual("ok\n### forged"), git), "more than one line");
    const edge = try guard.decide(ar.allocator(), manual("a" ** 200), git);
    try t.expect(edge == .release);
}

test "a push of a commit without the artifacts file is skipped; a manual run of one is refused" {
    var ar = arena();
    defer ar.deinit();
    const o = try guard.decide(ar.allocator(), push(false), FakeGit{ .steps = &.{ HEAD_OK, ON_MAIN } });
    try t.expect(o == .skip);
    try t.expectEqualStrings("nothing to release: " ++ SHA ++ " has no release/artifacts.textproto", o.skip);
    var in = manual("why");
    in.artifacts_exist = false;
    try refusal(try guard.decide(ar.allocator(), in, FakeGit{ .steps = &.{HEAD_OK} }), "a manual run asked for a release");
}

test "a push off main is refused before the artifacts file is looked at" {
    var ar = arena();
    defer ar.deinit();
    var in = push(false);
    in.ref = "refs/heads/other";
    try refusal(try guard.decide(ar.allocator(), in, FakeGit{ .steps = &.{ HEAD_OK, ON_MAIN } }), "a push of refs/heads/other");
}

// ---- the stamp ----------------------------------------------------------------

const S = "fedcba9876543210fedcba9876543210fedcba98";

const STAMP_STEPS = [_]Step{
    .{ .cmd = "rev-parse --is-shallow-repository", .out = "false\n" },
    HEAD_OK,
    .{ .cmd = "status --porcelain --untracked-files=no" },
    // the newest commit that touches more than documentation is not the revision
    .{ .cmd = "log -1 --first-parent --format=%H " ++ SHA ++ " -- . :(exclude)docs :(exclude)*.md :(exclude).github", .out = S ++ "\n" },
    .{ .cmd = "rev-list --count --first-parent " ++ S, .out = "1234\n" },
    .{ .cmd = "log -1 --format=%ct " ++ S, .out = "1790000000\n" },
};

fn stampWith(ar: std.mem.Allocator, replace: []const Step) !stamp.Result {
    var steps: [STAMP_STEPS.len]Step = STAMP_STEPS;
    for (replace) |r| {
        for (&steps) |*s| {
            if (std.mem.eql(u8, s.cmd, r.cmd)) s.* = r;
        }
    }
    return stamp.derive(ar, FakeGit{ .steps = &steps }, SHA);
}

fn stampRefusal(r: stamp.Result, needle: []const u8) !void {
    switch (r) {
        .refuse => |why| if (std.mem.indexOf(u8, why, needle) == null) {
            std.debug.print("refusal '{s}' does not say '{s}'\n", .{ why, needle });
            return error.TestWrongRefusal;
        },
        .ok => return error.TestExpectedRefusal,
    }
}

test "the stamp is the source commit, its first-parent count and its commit time in milliseconds" {
    var ar = arena();
    defer ar.deinit();
    const r = try stampWith(ar.allocator(), &.{});
    try t.expectEqualStrings(S, r.ok.source_commit);
    try t.expectEqual(@as(u64, 1234), r.ok.build_number);
    try t.expectEqual(@as(u64, 1790000000000), r.ok.timestamp_ms);
}

test "the count and the time are those of the source commit, not of the revision" {
    // the script has no answer for the revision's own count: a tool that
    // counted the revision gets exit 99 and is refused
    var ar = arena();
    defer ar.deinit();
    const r = try stampWith(ar.allocator(), &.{});
    try t.expect(r == .ok);
    try t.expect(!std.mem.eql(u8, r.ok.source_commit, SHA));
}

test "a shallow clone, another HEAD, modified files and a history of documentation alone are refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try stampRefusal(try stampWith(a, &.{.{ .cmd = "rev-parse --is-shallow-repository", .out = "true\n" }}), "shallow clone");
    try stampRefusal(try stampWith(a, &.{.{ .cmd = HEAD_OK.cmd, .out = OTHER ++ "\n" }}), "is not the revision");
    try stampRefusal(try stampWith(a, &.{.{ .cmd = "status --porcelain --untracked-files=no", .out = " M BUCK\n" }}), "modified tracked files");
    try stampRefusal(try stampWith(a, &.{.{ .cmd = STAMP_STEPS[3].cmd, .out = "\n" }}), "touches anything but documentation");
}

test "a count or a time that is not a positive number, a git that fails and a short revision are refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try stampRefusal(try stampWith(a, &.{.{ .cmd = STAMP_STEPS[4].cmd, .out = "0\n" }}), "not a positive number");
    try stampRefusal(try stampWith(a, &.{.{ .cmd = STAMP_STEPS[4].cmd, .out = "many\n" }}), "not a positive number");
    try stampRefusal(try stampWith(a, &.{.{ .cmd = STAMP_STEPS[5].cmd, .out = "0\n" }}), "not a positive number");
    try stampRefusal(try stampWith(a, &.{.{ .cmd = STAMP_STEPS[5].cmd, .code = 128, .err = "fatal: bad object" }}), "failed (128)");
    try stampRefusal(try stampWith(a, &.{.{ .cmd = STAMP_STEPS[4].cmd, .out = "1\n2\n" }}), "more than one line");
    try stampRefusal(try stamp.derive(a, FakeGit{ .steps = &STAMP_STEPS }, SHA[0..12]), "full commit id");
}

// ---- the artifacts file --------------------------------------------------------

const FILE =
    \\# the file's own comments
    \\schema_version: 1
    \\
    \\build_systems {
    \\  name: "buck2"
    \\  executable: "buck2"
    \\  args: "build"
    \\}
    \\
    \\artifacts {
    \\  name: "lib_a"
    \\  build_system: "buck2"
    \\  args: "//src/lib_a:lib_a_conda[release]"
    \\  targets: "//src/lib_a:lib_a_conda"
    \\}
    \\
    \\artifacts {
    \\  name: "lib_b"
    \\  build_system: "buck2"
    \\  args: "//src/lib_b:lib_b_conda[release]"
    \\}
    \\
    \\artifacts {
    \\  name: "all"
    \\  build_system: "komira_pack"
    \\  args: "conda-meta"
    \\  args: "--name"
    \\  args: "all"
    \\  args: "--member-manifest"
    \\  args: "{release_dir}/lib_a/manifest.json"
    \\  args: "--member-manifest"
    \\  args: "{release_dir}/lib_b/manifest.json"
    \\  args: "--license"
    \\  args: "Apache-2.0"
    \\  args: "--summary"
    \\  args: "Every library."
    \\  args: "--home"
    \\  args: "https://example.org/komira"
    \\  args: "--extra-file"
    \\  args: "info/licenses/LICENSE=LICENSE"
    \\  args: "--label"
    \\  args: "release {revision_id}"
    \\  args: "--out-dir"
    \\  args: "{out_dir}"
    \\}
    \\
;

const EXPECT = artifacts.Expect{
    .members = &.{ "lib_a", "lib_b" },
    .metapackage = "all",
    .license = "Apache-2.0",
    .summary = "Every library.",
    .home = "https://example.org/komira",
    .extra_file = "info/licenses/LICENSE=LICENSE",
    .label_prefix = "release ",
};

fn disagrees(a: std.mem.Allocator, text: []const u8, e: artifacts.Expect, needle: []const u8) !void {
    const why = (try artifacts.disagreement(a, text, e)) orelse return error.TestExpectedDisagreement;
    if (std.mem.indexOf(u8, why, needle) == null) {
        std.debug.print("'{s}' does not say '{s}'\n", .{ why, needle });
        return error.TestWrongDisagreement;
    }
}

test "the artifacts file is read as artifacts only: build systems and comments are not" {
    var ar = arena();
    defer ar.deinit();
    const arts = try artifacts.parse(ar.allocator(), FILE);
    try t.expectEqual(@as(usize, 3), arts.len);
    try t.expectEqualStrings("lib_a", arts[0].name);
    try t.expectEqualStrings("lib_b", arts[1].name);
    try t.expectEqualStrings("all", arts[2].name);
    try t.expectEqual(@as(usize, 1), arts[0].args.len);
}

test "a release set that is the file's agrees" {
    var ar = arena();
    defer ar.deinit();
    try t.expect((try artifacts.disagreement(ar.allocator(), FILE, EXPECT)) == null);
}

test "a library the file lacks, one it adds, another order and another name are each named" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var e = EXPECT;
    e.members = &.{ "lib_a", "lib_b", "lib_c" };
    try disagrees(a, FILE, e, "artifact 3 of the artifacts file is 'all', and the release set's is 'lib_c'");
    e.members = &.{"lib_a"};
    try disagrees(a, FILE, e, "artifact 2 of the artifacts file is 'lib_b', and the release set's is 'all'");
    e.members = &.{ "lib_b", "lib_a" };
    try disagrees(a, FILE, e, "artifact 1 of the artifacts file is 'lib_a'");
    e = EXPECT;
    e.metapackage = "everything";
    try disagrees(a, FILE, e, "'everything'");
}

test "the file declaring one more, or one less, than the set builds is named" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const extra = FILE ++ "artifacts {\n  name: \"late\"\n}\n";
    try disagrees(a, extra, EXPECT, "declares 'late', which the release set does not build");
    var e = EXPECT;
    e.members = &.{ "lib_a", "lib_b" };
    const short = "artifacts {\n  name: \"lib_a\"\n}\n";
    try disagrees(a, short, e, "builds 'lib_b', which the artifacts file does not declare");
}

test "the metapackage's arguments are the set's: licence, summary, home, label, a member's manifest" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var e = EXPECT;
    e.license = "MIT";
    try disagrees(a, FILE, e, "is 'Apache-2.0', and the release set gives 'MIT'");
    e = EXPECT;
    e.summary = "Another summary.";
    try disagrees(a, FILE, e, "'Another summary.'");
    e = EXPECT;
    e.home = "https://example.org/other";
    try disagrees(a, FILE, e, "https://example.org/other");
    e = EXPECT;
    e.label_prefix = "kci run ";
    try disagrees(a, FILE, e, "kci run {revision_id}");
    e = EXPECT;
    e.extra_file = "info/licenses/LICENSE=OTHER";
    try disagrees(a, FILE, e, "LICENSE=OTHER");
    // a member manifest the file's metapackage does not list
    const dropped = try std.mem.replaceOwned(u8, a, FILE, "  args: \"--member-manifest\"\n  args: \"{release_dir}/lib_b/manifest.json\"\n", "");
    try disagrees(a, dropped, EXPECT, "argument 6 of the metapackage 'all'");
}

test "a value with a backslash or a line that is not a field is refused, not read wrongly" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectError(error.BadLine, artifacts.parse(a, "artifacts {\n  name: \"a\\\"b\"\n}\n"));
    try t.expectError(error.BadLine, artifacts.parse(a, "artifacts {\n  name: a\n}\n"));
    try t.expectError(error.NoName, artifacts.parse(a, "artifacts {\n  args: \"x\"\n}\n"));
    try t.expectError(error.NestedBlock, artifacts.parse(a, "artifacts {\n  artifacts {\n  }\n}\n"));
}

// ---- ids and flags -----------------------------------------------------------

test "a commit id is 40 lowercase hex, a sha256 64" {
    try t.expect(util.isFullCommitId(SHA));
    try t.expect(!util.isFullCommitId(SHA[0..39]));
    try t.expect(!util.isFullCommitId("0123456789ABCDEF0123456789abcdef01234567"));
    try t.expect(!util.isFullCommitId("g123456789abcdef0123456789abcdef01234567"));
    try t.expect(util.isSha256Hex("a" ** 64));
    try t.expect(!util.isSha256Hex("A" ** 64));
    try t.expect(!util.isSha256Hex("a" ** 63));
}

test "flags: a name once, with a value; an unknown name, a missing value and a repeat are refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const names = [_][]const u8{ "--x", "--y" };
    var bad: []const u8 = "";
    const f = try util.Flags.parse(a, &.{ "--x", "1" }, &names, &bad);
    try t.expectEqualStrings("1", f.get("--x").?);
    try t.expect(f.get("--y") == null);
    try t.expectEqualStrings("", f.getOr("--y"));
    try t.expectError(error.UnknownFlag, util.Flags.parse(a, &.{ "--z", "1" }, &names, &bad));
    try t.expectEqualStrings("--z", bad);
    try t.expectError(error.MissingValue, util.Flags.parse(a, &.{"--x"}, &names, &bad));
    try t.expectError(error.DuplicateFlag, util.Flags.parse(a, &.{ "--x", "1", "--x", "2" }, &names, &bad));
}
