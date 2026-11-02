//! The cases of //:agents_md_cases, a `zig_test` run as a build action.
//!
//! Two rules keep the repository's engineering rules in one place, and are held here on the real
//! files and on fixtures with the rule broken:
//!  1. The shared core of AGENTS.md (the lines between `<!-- shared-core:begin -->` and
//!     `<!-- shared-core:end -->`) is byte for byte its canonical copy,
//!     tools/build/agents_md/shared_core.md, and the SHA-256 of that copy is the one recorded in
//!     tools/build/agents_md/shared_core.sha256. The copy and the hash are the same in every
//!     repository that carries the core, so an edit to the core here alone fails, and so does an
//!     edit to the core and the copy without the hash.
//!  2. CLAUDE.md imports AGENTS.md: it has a line that is exactly `@AGENTS.md`, outside a fenced
//!     code block (an import inside a fence is not read as one).

const std = @import("std");
const t = std.testing;

const AGENTS = "AGENTS.md";
const COPY = "tools/build/agents_md/shared_core.md";
const HASH = "tools/build/agents_md/shared_core.sha256";
const CLAUDE = "CLAUDE.md";

const BEGIN = "<!-- shared-core:begin -->";
const END = "<!-- shared-core:end -->";
const IMPORT = "@AGENTS.md";

/// The offsets of every line of `text` that is exactly `line` (no other bytes, `\n`-ended or last).
fn lineStarts(ar: std.mem.Allocator, text: []const u8, line: []const u8) ![]const usize {
    var out = std.ArrayList(usize){};
    var start: usize = 0;
    while (start <= text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, start, '\n');
        const stop = nl orelse text.len;
        if (std.mem.eql(u8, text[start..stop], line)) try out.append(ar, start);
        if (nl == null) break;
        start = stop + 1;
    }
    return out.toOwnedSlice(ar);
}

const Core = union(enum) {
    /// The bytes after the begin line's `\n` up to the start of the end line.
    core: []const u8,
    refused: []const u8,
};

/// The shared core of an AGENTS.md, or why it has none.
fn sharedCore(ar: std.mem.Allocator, agents: []const u8) !Core {
    const begins = try lineStarts(ar, agents, BEGIN);
    const ends = try lineStarts(ar, agents, END);
    if (begins.len != 1) return .{ .refused = try std.fmt.allocPrint(ar, "{s} has {d} lines `{s}`, wanted exactly one", .{ AGENTS, begins.len, BEGIN }) };
    if (ends.len != 1) return .{ .refused = try std.fmt.allocPrint(ar, "{s} has {d} lines `{s}`, wanted exactly one", .{ AGENTS, ends.len, END }) };
    const from = begins[0] + BEGIN.len + 1;
    if (ends[0] < from) return .{ .refused = try std.fmt.allocPrint(ar, "{s}: `{s}` comes before `{s}`", .{ AGENTS, END, BEGIN }) };
    const core = agents[from..ends[0]];
    if (std.mem.trim(u8, core, " \t\r\n").len == 0) return .{ .refused = try std.fmt.allocPrint(ar, "{s}: the shared core is empty, so the check would be vacuous", .{AGENTS}) };
    return .{ .core = core };
}

/// The 1-based number of the first line where `a` and `b` differ, given that they differ.
fn firstDifferentLine(a: []const u8, b: []const u8) usize {
    var line: usize = 1;
    var i: usize = 0;
    while (i < a.len and i < b.len and a[i] == b[i]) : (i += 1) {
        if (a[i] == '\n') line += 1;
    }
    return line;
}

/// The line of `text` numbered `n` (1-based), without its `\n`; empty past the end.
fn lineAt(text: []const u8, n: usize) []const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    var i: usize = 1;
    while (it.next()) |l| : (i += 1) {
        if (i == n) return l;
    }
    return "";
}

/// Null when AGENTS.md's shared core is the canonical copy and the copy hashes to the recorded
/// SHA-256; else the refusal.
fn checkCore(ar: std.mem.Allocator, agents: []const u8, copy: []const u8, hash: []const u8) !?[]const u8 {
    const core = switch (try sharedCore(ar, agents)) {
        .core => |c| c,
        .refused => |why| return why,
    };
    if (!std.mem.eql(u8, core, copy)) {
        const n = firstDifferentLine(core, copy);
        return try std.fmt.allocPrint(ar, "the shared core of {s} differs from {s} at line {d} of the core: \"{s}\" in {s}, \"{s}\" in {s}", .{ AGENTS, COPY, n, lineAt(core, n), AGENTS, lineAt(copy, n), COPY });
    }
    const want = std.mem.trimRight(u8, hash, "\n");
    if (want.len != 64 or std.mem.indexOfNone(u8, want, "0123456789abcdef") != null or hash.len != 65) {
        return try std.fmt.allocPrint(ar, "{s} is not one line of 64 lowercase hex digits", .{HASH});
    }
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(copy, &digest, .{});
    const got = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &got, want)) {
        return try std.fmt.allocPrint(ar, "the SHA-256 of {s} is {s}, but {s} records {s}", .{ COPY, &got, HASH, want });
    }
    return null;
}

/// Null when CLAUDE.md imports AGENTS.md (a line exactly `@AGENTS.md` outside a fenced code
/// block); else the refusal.
fn checkImport(ar: std.mem.Allocator, claude: []const u8) !?[]const u8 {
    var fenced = false;
    var it = std.mem.splitScalar(u8, claude, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trimLeft(u8, line, " "), "```")) {
            fenced = !fenced;
            continue;
        }
        if (!fenced and std.mem.eql(u8, line, IMPORT)) return null;
    }
    return try std.fmt.allocPrint(ar, "{s} has no line `{s}` outside a code block, so it does not import {s}", .{ CLAUDE, IMPORT, AGENTS });
}

fn read(ar: std.mem.Allocator, name: []const u8) ![]const u8 {
    const work = try std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK");
    return std.fs.cwd().readFileAlloc(ar, try std.fs.path.join(ar, &.{ work, name }), 1 << 22);
}

fn expectRefused(got_opt: ?[]const u8, want: []const u8) !void {
    const got = got_opt orelse {
        std.debug.print("accepted; wanted a refusal with: {s}\n", .{want});
        return error.Accepted;
    };
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("refused with \"{s}\", wanted \"{s}\"\n", .{ got, want });
        return error.WrongRefusal;
    }
}

const FIXTURE_CORE =
    \\## Shared core
    \\
    \\- **T1 BLOCK.** A rule.
    \\- **T2 SHOULD.** Another rule.
    \\
;

const FIXTURE_AGENTS = "# Rules\n\nIntro.\n\n" ++ BEGIN ++ "\n" ++ FIXTURE_CORE ++ END ++ "\n\n## Repository rules\n\n- **B21 BLOCK.** Ours.\n";

/// The fixture core's SHA-256, as shared_core.sha256 holds it.
fn fixtureHash(ar: std.mem.Allocator, copy: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(copy, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(ar, "{s}\n", .{&hex});
}

fn replaced(ar: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8) ![]const u8 {
    const out = try std.mem.replaceOwned(u8, ar, text, from, to);
    try t.expect(!std.mem.eql(u8, out, text));
    return out;
}

test "the real AGENTS.md shared core is the canonical copy, and the copy hashes to the recorded SHA-256" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    if (try checkCore(ar, try read(ar, AGENTS), try read(ar, "shared_core.md"), try read(ar, "shared_core.sha256"))) |why| {
        std.debug.print("{s}\n", .{why});
        return error.Refused;
    }
}

test "the real CLAUDE.md imports AGENTS.md" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    if (try checkImport(ar, try read(ar, CLAUDE))) |why| {
        std.debug.print("{s}\n", .{why});
        return error.Refused;
    }
}

test "a fixture whose core, copy and hash agree is accepted, with any text outside the core" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const hash = try fixtureHash(ar, FIXTURE_CORE);
    try t.expect((try checkCore(ar, FIXTURE_AGENTS, FIXTURE_CORE, hash)) == null);
    const outside = try replaced(ar, FIXTURE_AGENTS, "- **B21 BLOCK.** Ours.\n", "- **B21 BLOCK.** Ours, reworded.\n- **B23 SHOULD.** New.\n");
    try t.expect((try checkCore(ar, outside, FIXTURE_CORE, hash)) == null);
    const intro = try replaced(ar, FIXTURE_AGENTS, "Intro.\n", "Another intro.\n");
    try t.expect((try checkCore(ar, intro, FIXTURE_CORE, hash)) == null);
}

test "a word changed in the core of AGENTS.md is refused, naming the line and both texts" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const hash = try fixtureHash(ar, FIXTURE_CORE);
    const agents = try replaced(ar, FIXTURE_AGENTS, "Another rule.", "Another reworded rule.");
    try expectRefused(
        try checkCore(ar, agents, FIXTURE_CORE, hash),
        "the shared core of AGENTS.md differs from tools/build/agents_md/shared_core.md at line 4 of the core: \"- **T2 SHOULD.** Another reworded rule.\" in AGENTS.md, \"- **T2 SHOULD.** Another rule.\" in tools/build/agents_md/shared_core.md",
    );
}

test "a rule added to, or dropped from, the core of AGENTS.md alone is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const hash = try fixtureHash(ar, FIXTURE_CORE);
    const added = try replaced(ar, FIXTURE_AGENTS, "Another rule.\n", "Another rule.\n- **T3 BLOCK.** More.\n");
    try expectRefused(
        try checkCore(ar, added, FIXTURE_CORE, hash),
        "the shared core of AGENTS.md differs from tools/build/agents_md/shared_core.md at line 5 of the core: \"- **T3 BLOCK.** More.\" in AGENTS.md, \"\" in tools/build/agents_md/shared_core.md",
    );
    const dropped = try replaced(ar, FIXTURE_AGENTS, "- **T2 SHOULD.** Another rule.\n", "");
    try expectRefused(
        try checkCore(ar, dropped, FIXTURE_CORE, hash),
        "the shared core of AGENTS.md differs from tools/build/agents_md/shared_core.md at line 4 of the core: \"\" in AGENTS.md, \"- **T2 SHOULD.** Another rule.\" in tools/build/agents_md/shared_core.md",
    );
}

test "a core that differs only in whitespace or line endings is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const hash = try fixtureHash(ar, FIXTURE_CORE);
    const trailing = try replaced(ar, FIXTURE_AGENTS, "A rule.\n", "A rule. \n");
    try expectRefused(
        try checkCore(ar, trailing, FIXTURE_CORE, hash),
        "the shared core of AGENTS.md differs from tools/build/agents_md/shared_core.md at line 3 of the core: \"- **T1 BLOCK.** A rule. \" in AGENTS.md, \"- **T1 BLOCK.** A rule.\" in tools/build/agents_md/shared_core.md",
    );
    const crlf = try replaced(ar, FIXTURE_AGENTS, "A rule.\n", "A rule.\r\n");
    try expectRefused(
        try checkCore(ar, crlf, FIXTURE_CORE, hash),
        "the shared core of AGENTS.md differs from tools/build/agents_md/shared_core.md at line 3 of the core: \"- **T1 BLOCK.** A rule.\r\" in AGENTS.md, \"- **T1 BLOCK.** A rule.\" in tools/build/agents_md/shared_core.md",
    );
}

test "the core and the copy changed together without the hash is refused, naming both hashes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const hash = try fixtureHash(ar, FIXTURE_CORE);
    const copy = try replaced(ar, FIXTURE_CORE, "A rule.", "A changed rule.");
    const agents = try replaced(ar, FIXTURE_AGENTS, "A rule.", "A changed rule.");
    const want = try std.fmt.allocPrint(ar, "the SHA-256 of tools/build/agents_md/shared_core.md is {s}, but tools/build/agents_md/shared_core.sha256 records {s}", .{ std.mem.trimRight(u8, try fixtureHash(ar, copy), "\n"), std.mem.trimRight(u8, hash, "\n") });
    try expectRefused(try checkCore(ar, agents, copy, hash), want);
    // With the hash moved too, the change is accepted: that is how the core changes.
    try t.expect((try checkCore(ar, agents, copy, try fixtureHash(ar, copy))) == null);
}

test "a hash file that is not one line of 64 lowercase hex digits is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const hash = try fixtureHash(ar, FIXTURE_CORE);
    const want = "tools/build/agents_md/shared_core.sha256 is not one line of 64 lowercase hex digits";
    const bads = [_][]const u8{
        "",
        "\n",
        std.mem.trimRight(u8, hash, "\n"), // no newline
        try std.fmt.allocPrint(ar, "{s}\n", .{hash}), // a second, empty line
        try std.fmt.allocPrint(ar, "{s}  shared_core.md\n", .{std.mem.trimRight(u8, hash, "\n")}), // sha256sum's form
        try std.ascii.allocUpperString(ar, hash), // upper case
        hash[1..], // 63 digits
        try std.fmt.allocPrint(ar, "g{s}", .{hash[1..]}), // not hex
    };
    for (bads) |bad| try expectRefused(try checkCore(ar, FIXTURE_AGENTS, FIXTURE_CORE, bad), want);
}

test "an AGENTS.md with no begin or end line, or two of either, is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const hash = try fixtureHash(ar, FIXTURE_CORE);
    try expectRefused(try checkCore(ar, try replaced(ar, FIXTURE_AGENTS, BEGIN ++ "\n", ""), FIXTURE_CORE, hash), "AGENTS.md has 0 lines `<!-- shared-core:begin -->`, wanted exactly one");
    try expectRefused(try checkCore(ar, try replaced(ar, FIXTURE_AGENTS, END ++ "\n", ""), FIXTURE_CORE, hash), "AGENTS.md has 0 lines `<!-- shared-core:end -->`, wanted exactly one");
    try expectRefused(try checkCore(ar, FIXTURE_AGENTS ++ BEGIN ++ "\n", FIXTURE_CORE, hash), "AGENTS.md has 2 lines `<!-- shared-core:begin -->`, wanted exactly one");
    try expectRefused(try checkCore(ar, FIXTURE_AGENTS ++ END, FIXTURE_CORE, hash), "AGENTS.md has 2 lines `<!-- shared-core:end -->`, wanted exactly one");
    try expectRefused(try checkCore(ar, "", FIXTURE_CORE, hash), "AGENTS.md has 0 lines `<!-- shared-core:begin -->`, wanted exactly one");
}

test "a marker that is not a whole line does not count as one" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const hash = try fixtureHash(ar, FIXTURE_CORE);
    // Indented, or quoted in prose: the core has no begin line.
    try expectRefused(try checkCore(ar, try replaced(ar, FIXTURE_AGENTS, BEGIN ++ "\n", "  " ++ BEGIN ++ "\n"), FIXTURE_CORE, hash), "AGENTS.md has 0 lines `<!-- shared-core:begin -->`, wanted exactly one");
    try expectRefused(try checkCore(ar, try replaced(ar, FIXTURE_AGENTS, END ++ "\n", "see " ++ END ++ "\n"), FIXTURE_CORE, hash), "AGENTS.md has 0 lines `<!-- shared-core:end -->`, wanted exactly one");
    // A marker mentioned in prose beside the real ones is not a second marker.
    const prose = try replaced(ar, FIXTURE_AGENTS, "Intro.\n", "Intro: the core is after `" ++ BEGIN ++ "`.\n");
    try t.expect((try checkCore(ar, prose, FIXTURE_CORE, hash)) == null);
}

test "an end line before the begin line, or an empty core, is refused, not passed vacuously" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try expectRefused(try checkCore(ar, END ++ "\n" ++ FIXTURE_CORE ++ BEGIN ++ "\n", FIXTURE_CORE, try fixtureHash(ar, FIXTURE_CORE)), "AGENTS.md: `<!-- shared-core:end -->` comes before `<!-- shared-core:begin -->`");
    const empty = "\n \n";
    try expectRefused(try checkCore(ar, BEGIN ++ "\n" ++ empty ++ END ++ "\n", empty, try fixtureHash(ar, empty)), "AGENTS.md: the shared core is empty, so the check would be vacuous");
    try expectRefused(try checkCore(ar, BEGIN ++ "\n" ++ END ++ "\n", "", try fixtureHash(ar, "")), "AGENTS.md: the shared core is empty, so the check would be vacuous");
}

test "a CLAUDE.md that is the import, or holds it among other lines, imports AGENTS.md" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try t.expect((try checkImport(ar, "@AGENTS.md\n")) == null);
    try t.expect((try checkImport(ar, "@AGENTS.md")) == null);
    try t.expect((try checkImport(ar, "# Notes\n\n@AGENTS.md\n\nRepository notes.\n")) == null);
    try t.expect((try checkImport(ar, "```sh\n./buck2 build\n```\n@AGENTS.md\n")) == null);
}

test "a CLAUDE.md without the import line, or with it only in prose, a code block or another spelling, is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const want = "CLAUDE.md has no line `@AGENTS.md` outside a code block, so it does not import AGENTS.md";
    const bads = [_][]const u8{
        "",
        "# Notes\n",
        "Read @AGENTS.md first.\n",
        " @AGENTS.md\n",
        "@AGENTS.md \n",
        "@AGENTS.md\r\n",
        "@agents.md\n",
        "@./AGENTS.md\n",
        "@AGENTS.md.bak\n",
        "```\n@AGENTS.md\n```\n",
        "  ```md\n@AGENTS.md\n  ```\n",
    };
    for (bads) |bad| try expectRefused(try checkImport(ar, bad), want);
}
