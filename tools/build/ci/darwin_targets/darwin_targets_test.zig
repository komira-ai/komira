//! The cases of darwin_targets (darwin_targets.zig), //tools/build/ci:darwin_targets_unit: the tool is
//! built only when they pass. The fixtures are the output of real runs of
//! `./buck2 bxl komira//tools/build/ci/darwin.bxl:select @tools/build/ci/darwin_affected.args @<list>`
//! on the farm, stdout and stderr together as the buck2-farm action logs them (the build id zeroed):
//! the whole set (a list holding `komira//ci:pr`), some libraries (the list of a change to
//! src/encoding), none (a list with no library of the set), and a refused list (a line that is not
//! a label, so darwin.bxl failed). The other cases are those logs with a line added or changed.
//! What the cases catch:
//!  - each verdict of the real selection gives exactly its targets, in its order, and nothing of
//!    buck2's own lines (time-stamped lines, `BXL SUCCEEDED`, file-change notices);
//!  - a failed selection's log, a log with no verdict, two verdicts, or an unknown verdict is refused;
//!  - a NONE with targets and a WHOLE or SOME without any are refused;
//!  - only `[a-z_]+//` followed by a space-free rest is a target;
//!  - the targets file holds each target on its own line, and is empty for none;
//!  - the options are each given once, with a value; each refusal has its own message.
const std = @import("std");
const d = @import("darwin_targets.zig");
const t = std.testing;

const whole = @embedFile("fixtures/select_whole.log");
const some = @embedFile("fixtures/select_some.log");
const none = @embedFile("fixtures/select_none.log");
const broken = @embedFile("fixtures/select_broken.log");

const SOME_TARGETS = [_][]const u8{
    "komira//src/broker_proto:lib",
    "komira//src/calendar:lib",
    "komira//src/calendar_ics:lib",
    "komira//src/calendar_proto:lib",
    "komira//src/chat_proto:lib",
    "komira//src/contacts_proto:lib",
    "komira//src/crm_proto:lib",
    "komira//src/crypto:lib",
    "komira//src/encoding:lib",
    "komira//src/job_report_proto:lib",
    "komira//src/mail_message:lib",
    "komira//src/managed_mail_proto:lib",
    "komira//src/mcp_server:lib",
    "komira//src/plan_proto:lib",
    "komira//src/proto_codec:lib",
    "komira//src/supervisor_proto:lib",
    "komira//src/wkt:lib",
};

fn expectTargets(want: []const []const u8, got: []const []const u8) !void {
    try t.expectEqual(want.len, got.len);
    for (want, got) |w, g| try t.expectEqualStrings(w, g);
}

test "the whole set's log gives the set alone" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const r = try d.read(arena.allocator(), whole);
    try t.expectEqual(d.Kind.WHOLE, r.kind);
    try expectTargets(&.{"komira//release:mopm_darwin_libs"}, r.targets);
}

test "some libraries' log gives each library, in the selection's order" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const r = try d.read(arena.allocator(), some);
    try t.expectEqual(d.Kind.SOME, r.kind);
    try expectTargets(&SOME_TARGETS, r.targets);
}

test "the log of no library gives no target, and an empty targets file" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const r = try d.read(arena.allocator(), none);
    try t.expectEqual(d.Kind.NONE, r.kind);
    try t.expectEqual(@as(usize, 0), r.targets.len);
    try t.expectEqualStrings("", try d.render(arena.allocator(), r.targets));
}

test "a failed selection's log is refused: it holds no verdict" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectError(error.NoVerdict, d.read(arena.allocator(), broken));
    try t.expectError(error.NoVerdict, d.read(arena.allocator(), ""));
}

test "two verdicts are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectError(error.ManyVerdicts, d.read(arena.allocator(), whole ++ none));
}

test "a verdict other than WHOLE, SOME or NONE is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectError(error.UnknownVerdict, d.read(arena.allocator(), "[2026-11-23T16:13:46.534-06:00] darwin: BROKEN: no\n"));
    try t.expectError(error.UnknownVerdict, d.read(arena.allocator(), "darwin: some: lower case\nkomira//src/wkt:lib\n"));
}

test "a NONE with targets is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectError(error.TargetsWithNone, d.read(arena.allocator(), none ++ "komira//src/wkt:lib\n"));
}

test "a WHOLE or a SOME without targets is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectError(error.NoTargets, d.read(arena.allocator(), "[x] darwin: WHOLE: the whole set\nBXL SUCCEEDED\n"));
    try t.expectError(error.NoTargets, d.read(arena.allocator(), "darwin: SOME: 1 of the 66\n"));
}

test "a verdict line is `darwin: <word>: `, at the start or after buck2's time stamp" {
    try t.expectEqualStrings("SOME", d.verdictWord("darwin: SOME: 1 of 66").?);
    try t.expectEqualStrings("NONE", d.verdictWord("[2026-11-23T16:13:46.534-06:00] darwin: NONE: none").?);
    try t.expect(d.verdictWord("error: fail: darwin: BROKEN: x") == null);
    try t.expect(d.verdictWord("      fail(\"darwin: BROKEN: \" + verdict.reason)") == null);
    try t.expect(d.verdictWord("[no close darwin: SOME: x") == null);
    try t.expect(d.verdictWord("darwin: SOME") == null);
}

test "a target is a cell name, `//`, and a rest with no space" {
    try t.expect(d.isLabel("komira//src/wkt:lib"));
    try t.expect(d.isLabel("tests//a:b"));
    try t.expect(d.isLabel("my_cell//x"));
    try t.expect(!d.isLabel("//src/wkt:lib"));
    try t.expect(!d.isLabel("Komira//src/wkt:lib"));
    try t.expect(!d.isLabel("komira//"));
    try t.expect(!d.isLabel("komira//src/wkt:lib extra"));
    try t.expect(!d.isLabel("[2026-11-23T16:13:46.497-06:00] File changed: komira//src/encoding/BUCK"));
    try t.expect(!d.isLabel("BXL SUCCEEDED"));
}

test "the targets file holds each target on its own line" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectEqualStrings("komira//a:lib\nkomira//b:lib\n", try d.render(arena.allocator(), &.{ "komira//a:lib", "komira//b:lib" }));
}

test "the options are each given once, with a value" {
    const o = try d.parseArgs(&.{ "--log", "l", "--out", "o", "--github-output", "g" });
    try t.expectEqualStrings("l", o.log);
    try t.expectEqualStrings("o", o.out);
    try t.expectEqualStrings("g", o.github_output);
    try t.expectError(error.UnknownArgument, d.parseArgs(&.{ "--logs", "l" }));
    try t.expectError(error.MissingValue, d.parseArgs(&.{ "--out", "o", "--log" }));
    try t.expectError(error.RepeatedArgument, d.parseArgs(&.{ "--log", "l", "--log", "m" }));
    try t.expectError(error.MissingArgument, d.parseArgs(&.{ "--log", "l", "--out", "o" }));
    try t.expectError(error.MissingArgument, d.parseArgs(&.{}));
}

test "each refusal has its own message, and other errors none" {
    const all = [_]anyerror{ error.NoVerdict, error.ManyVerdicts, error.UnknownVerdict, error.TargetsWithNone, error.NoTargets };
    for (all, 0..) |e, i| {
        const m = d.describe(e).?;
        try t.expect(std.mem.startsWith(u8, m, "::error::"));
        for (all[0..i]) |o| try t.expect(!std.mem.eql(u8, m, d.describe(o).?));
    }
    try t.expect(d.describe(error.OutOfMemory) == null);
}
