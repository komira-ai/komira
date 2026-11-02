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
//!  2. CLAUDE.md imports AGENTS.md: it has a line that is exactly `@AGENTS.md` outside a fenced
//!     code block and outside a code span, since an import in either is not read as one. Lines,
//!     line endings and fences are read by the repository's Markdown reader
//!     (tools/build/markdown/markdown.zig, CommonMark fences: backticks or tildes, closed only by
//!     a run of the same character at least as long). A code span may run over several lines of
//!     one paragraph, so spans are read per paragraph here.
//!
//! The four files are read from a directory the caller passes (the real ones from the action's
//! KOMIRA_TEST_WORK, the fixtures from a scratch directory of the test's own), each up to
//! MAX_BYTES; a file that cannot be read is refused, naming it and the error.

const std = @import("std");
const md = @import("markdown");
const t = std.testing;

const AGENTS = "AGENTS.md";
const COPY = "tools/build/agents_md/shared_core.md";
const HASH = "tools/build/agents_md/shared_core.sha256";
const CLAUDE = "CLAUDE.md";

const BEGIN = "<!-- shared-core:begin -->";
const END = "<!-- shared-core:end -->";
const IMPORT = "@AGENTS.md";

/// The most bytes read from one input file.
const MAX_BYTES = 1 << 22;

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
        if (std.mem.eql(u8, lineAt(core, n), lineAt(copy, n))) {
            return try std.fmt.allocPrint(ar, "the shared core of {s} differs from {s} at the end of line {d} of the core: one ends the line with a newline and the other ends there", .{ AGENTS, COPY, n });
        }
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

/// Whether a line of `para` (the lines of one paragraph) is exactly the import and is not inside
/// a code span. A run of N backticks opens a span that the next run of exactly N backticks in the
/// paragraph closes, across lines; a run with no such partner is literal text (CommonMark).
fn importOutsideSpans(ar: std.mem.Allocator, para: []const []const u8) !bool {
    var text = std.ArrayList(u8){};
    const starts = try ar.alloc(usize, para.len);
    for (para, 0..) |line, k| {
        starts[k] = text.items.len;
        try text.appendSlice(ar, line);
        try text.append(ar, '\n');
    }
    const s = text.items;
    var covered = try ar.alloc(bool, s.len);
    @memset(covered, false);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '`') {
            i += 1;
            continue;
        }
        const open = i;
        while (i < s.len and s[i] == '`') i += 1;
        const n = i - open;
        var j = i;
        const close: ?usize = while (j < s.len) {
            if (s[j] != '`') {
                j += 1;
                continue;
            }
            const run = j;
            while (j < s.len and s[j] == '`') j += 1;
            if (j - run == n) break run;
        } else null;
        if (close) |c| {
            @memset(covered[open .. c + n], true);
            i = c + n;
        }
    }
    for (para, starts) |line, at| {
        if (std.mem.eql(u8, line, IMPORT) and !covered[at]) return true;
    }
    return false;
}

/// Null when CLAUDE.md imports AGENTS.md (a line exactly `@AGENTS.md` outside a fenced code
/// block and outside a code span); else the refusal.
fn checkImport(ar: std.mem.Allocator, claude: []const u8) !?[]const u8 {
    const lines = try md.splitLines(ar, claude);
    const code = try md.codeMask(ar, lines);
    var i: usize = 0;
    while (i < lines.len) {
        if (code[i] or md.strip(lines[i]).len == 0) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < lines.len and !code[j] and md.strip(lines[j]).len != 0) j += 1;
        if (try importOutsideSpans(ar, lines[i..j])) return null;
        i = j;
    }
    return try std.fmt.allocPrint(ar, "{s} has no line `{s}` outside a code block or code span, so it does not import {s}", .{ CLAUDE, IMPORT, AGENTS });
}

const Loaded = union(enum) {
    bytes: []const u8,
    refused: []const u8,
};

/// The bytes of `name` in `dir`, or why it cannot be read (missing, a directory, unreadable, or
/// over MAX_BYTES).
fn load(ar: std.mem.Allocator, dir: std.fs.Dir, name: []const u8) !Loaded {
    const bytes = dir.readFileAlloc(ar, name, MAX_BYTES) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return .{ .refused = try std.fmt.allocPrint(ar, "{s} cannot be read: {s}", .{ name, @errorName(e) }) },
    };
    return .{ .bytes = bytes };
}

/// Null when the four files in `dir` (AGENTS.md, CLAUDE.md, shared_core.md, shared_core.sha256)
/// pass both checks; else the first refusal.
fn checkDir(ar: std.mem.Allocator, dir: std.fs.Dir) !?[]const u8 {
    var got: [4][]const u8 = undefined;
    for ([_][]const u8{ AGENTS, CLAUDE, "shared_core.md", "shared_core.sha256" }, 0..) |name, k| {
        got[k] = switch (try load(ar, dir, name)) {
            .bytes => |b| b,
            .refused => |why| return why,
        };
    }
    if (try checkCore(ar, got[0], got[2], got[3])) |why| return why;
    return checkImport(ar, got[1]);
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

test "the real AGENTS.md, CLAUDE.md, canonical copy and hash pass both checks" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const work = try std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK");
    var dir = try std.fs.cwd().openDir(work, .{});
    defer dir.close();
    if (try checkDir(ar, dir)) |why| {
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
    const goods = [_][]const u8{
        "@AGENTS.md\n",
        "@AGENTS.md",
        "@AGENTS.md\r\n", // a CRLF line ending is a line ending
        "# Notes\n\n@AGENTS.md\n\nRepository notes.\n",
        "```sh\n./buck2 build\n```\n@AGENTS.md\n",
        // After a closed tilde block that quotes a backtick fence.
        "~~~\n```\nx\n~~~\n@AGENTS.md\n",
        // A run of backticks with a backtick in its info string opens no fence.
        "``` a`b\n@AGENTS.md\n",
        // A code span closed on the same line, before the import's paragraph line.
        "Use `x` here\n@AGENTS.md\n",
        // A backtick run with no partner of its length is literal text.
        "a `` b\n@AGENTS.md\n",
        // A span that does not reach the import: it closes before it.
        "`one\ntwo`\n@AGENTS.md\n",
        // An unclosed run in another paragraph does not reach across a blank line.
        "`open\n\n@AGENTS.md\n",
    };
    for (goods) |good| {
        if (try checkImport(ar, good)) |why| {
            std.debug.print("refused \"{s}\": {s}\n", .{ good, why });
            return error.Refused;
        }
    }
}

test "a CLAUDE.md without the import line, or with it only in prose, a code block, a code span or another spelling, is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const want = "CLAUDE.md has no line `@AGENTS.md` outside a code block or code span, so it does not import AGENTS.md";
    const bads = [_][]const u8{
        "",
        "# Notes\n",
        "Read @AGENTS.md first.\n",
        " @AGENTS.md\n",
        "\t@AGENTS.md\n",
        "@AGENTS.md \n",
        "@agents.md\n",
        "@./AGENTS.md\n",
        "@AGENTS.md.bak\n",
        "```\n@AGENTS.md\n```\n",
        "  ```md\n@AGENTS.md\n  ```\n",
        "\t```\n@AGENTS.md\n\t```\n", // a tab-indented fence
        "~~~md\n@AGENTS.md\n~~~\n", // a tilde fence
        "~~~\n@AGENTS.md\n", // an unclosed tilde fence runs to the end
        "```\n@AGENTS.md\n", // an unclosed backtick fence runs to the end
        "````\n```\n@AGENTS.md\n````\n", // a shorter run does not close a longer fence
        "```\n``` md\n@AGENTS.md\n```\n", // a run with an info string does not close a fence
        "~~~\n```\n@AGENTS.md\n```\n~~~\n", // a backtick block quoted in a tilde block
        "```\n~~~\n@AGENTS.md\n```\n", // a tilde line does not close a backtick fence
        "`\n@AGENTS.md\n`\n", // a code span over three lines
        "Run ``x\n@AGENTS.md\ny`` here.\n", // a double-backtick span
    };
    for (bads) |bad| {
        expectRefused(try checkImport(ar, bad), want) catch |e| {
            std.debug.print("for \"{s}\"\n", .{bad});
            return e;
        };
    }
}

test "a minimal AGENTS.md, begin line first and end line last with no newline, is accepted" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const core = "- **T1 BLOCK.** A rule.\n";
    try t.expect((try checkCore(ar, BEGIN ++ "\n" ++ core ++ END, core, try fixtureHash(ar, core))) == null);
}

test "a begin line at the end of the file, or a core of tabs and carriage returns, is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const hash = try fixtureHash(ar, FIXTURE_CORE);
    try expectRefused(try checkCore(ar, "# Rules\n" ++ BEGIN, FIXTURE_CORE, hash), "AGENTS.md has 0 lines `<!-- shared-core:end -->`, wanted exactly one");
    try expectRefused(try checkCore(ar, END ++ "\n" ++ BEGIN, FIXTURE_CORE, hash), "AGENTS.md: `<!-- shared-core:end -->` comes before `<!-- shared-core:begin -->`");
    const blank = "\t\r\n\t\n\r\n";
    try expectRefused(try checkCore(ar, BEGIN ++ "\n" ++ blank ++ END ++ "\n", blank, try fixtureHash(ar, blank)), "AGENTS.md: the shared core is empty, so the check would be vacuous");
}

test "a canonical copy changed, emptied or truncated on its own is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const hash = try fixtureHash(ar, FIXTURE_CORE);
    const changed = try replaced(ar, FIXTURE_CORE, "A rule.", "A changed rule.");
    try expectRefused(
        try checkCore(ar, FIXTURE_AGENTS, changed, hash),
        "the shared core of AGENTS.md differs from tools/build/agents_md/shared_core.md at line 3 of the core: \"- **T1 BLOCK.** A rule.\" in AGENTS.md, \"- **T1 BLOCK.** A changed rule.\" in tools/build/agents_md/shared_core.md",
    );
    try expectRefused(
        try checkCore(ar, FIXTURE_AGENTS, "", hash),
        "the shared core of AGENTS.md differs from tools/build/agents_md/shared_core.md at line 1 of the core: \"## Shared core\" in AGENTS.md, \"\" in tools/build/agents_md/shared_core.md",
    );
    try expectRefused(
        try checkCore(ar, FIXTURE_AGENTS, FIXTURE_CORE[0..20], hash),
        "the shared core of AGENTS.md differs from tools/build/agents_md/shared_core.md at line 3 of the core: \"- **T1 BLOCK.** A rule.\" in AGENTS.md, \"- **\" in tools/build/agents_md/shared_core.md",
    );
    const no_newline = FIXTURE_CORE[0 .. FIXTURE_CORE.len - 1];
    try expectRefused(
        try checkCore(ar, FIXTURE_AGENTS, no_newline, try fixtureHash(ar, no_newline)),
        "the shared core of AGENTS.md differs from tools/build/agents_md/shared_core.md at the end of line 4 of the core: one ends the line with a newline and the other ends there",
    );
}

test "a well-formed hash that is not the copy's, and hashes malformed by CRLF, an inner newline or one digit too many, are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const hash = try fixtureHash(ar, FIXTURE_CORE);
    const digits = hash[0..64];
    const other = try fixtureHash(ar, "another text\n");
    const want = try std.fmt.allocPrint(ar, "the SHA-256 of tools/build/agents_md/shared_core.md is {s}, but tools/build/agents_md/shared_core.sha256 records {s}", .{ digits, other[0..64] });
    try expectRefused(try checkCore(ar, FIXTURE_AGENTS, FIXTURE_CORE, other), want);
    const malformed = "tools/build/agents_md/shared_core.sha256 is not one line of 64 lowercase hex digits";
    const bads = [_][]const u8{
        try std.fmt.allocPrint(ar, "{s}\r\n", .{digits}),
        try std.fmt.allocPrint(ar, "{s}\n{s}\n", .{ digits[0..32], digits[32..] }),
        try std.fmt.allocPrint(ar, "{s}0\n", .{digits}), // 65 digits
        try std.fmt.allocPrint(ar, "{s}\n", .{digits[0..63]}), // 63 digits
    };
    for (bads) |bad| try expectRefused(try checkCore(ar, FIXTURE_AGENTS, FIXTURE_CORE, bad), malformed);
}

/// A scratch directory of the test's own holding the four files of a passing fixture.
fn fixtureDir(ar: std.mem.Allocator) !t.TmpDir {
    var tmp = t.tmpDir(.{});
    try tmp.dir.writeFile(.{ .sub_path = AGENTS, .data = FIXTURE_AGENTS });
    try tmp.dir.writeFile(.{ .sub_path = CLAUDE, .data = "@AGENTS.md\n" });
    try tmp.dir.writeFile(.{ .sub_path = "shared_core.md", .data = FIXTURE_CORE });
    try tmp.dir.writeFile(.{ .sub_path = "shared_core.sha256", .data = try fixtureHash(ar, FIXTURE_CORE) });
    return tmp;
}

test "a fixture directory holding the four files passes; each file missing is refused, naming it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    {
        var tmp = try fixtureDir(ar);
        defer tmp.cleanup();
        try t.expect((try checkDir(ar, tmp.dir)) == null);
    }
    for ([_][]const u8{ AGENTS, CLAUDE, "shared_core.md", "shared_core.sha256" }) |name| {
        var tmp = try fixtureDir(ar);
        defer tmp.cleanup();
        try tmp.dir.deleteFile(name);
        try expectRefused(try checkDir(ar, tmp.dir), try std.fmt.allocPrint(ar, "{s} cannot be read: FileNotFound", .{name}));
    }
}

test "a directory in place of an input file is refused, naming it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    var tmp = try fixtureDir(ar);
    defer tmp.cleanup();
    try tmp.dir.deleteFile(CLAUDE);
    try tmp.dir.makeDir(CLAUDE);
    try expectRefused(try checkDir(ar, tmp.dir), "CLAUDE.md cannot be read: IsDir");
}

test "an input file of exactly MAX_BYTES is read, and one byte more is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    var tmp = try fixtureDir(ar);
    defer tmp.cleanup();
    // CLAUDE.md padded with blank lines after its import: read whole, it still imports.
    const at_limit = try ar.alloc(u8, MAX_BYTES);
    @memset(at_limit, '\n');
    @memcpy(at_limit[0..IMPORT.len], IMPORT);
    try tmp.dir.writeFile(.{ .sub_path = CLAUDE, .data = at_limit });
    try t.expect((try checkDir(ar, tmp.dir)) == null);
    const over = try ar.alloc(u8, MAX_BYTES + 1);
    @memset(over, '\n');
    @memcpy(over[0..IMPORT.len], IMPORT);
    try tmp.dir.writeFile(.{ .sub_path = CLAUDE, .data = over });
    try expectRefused(try checkDir(ar, tmp.dir), "CLAUDE.md cannot be read: FileTooBig");
}

test "an input file without read permission is refused, naming it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    var tmp = try fixtureDir(ar);
    defer tmp.cleanup();
    var f = try tmp.dir.openFile(AGENTS, .{});
    try f.chmod(0);
    f.close();
    // A process with CAP_DAC_OVERRIDE (root) reads the file anyway; then this case cannot be
    // shown, and it says so instead of passing.
    if (tmp.dir.readFileAlloc(ar, AGENTS, MAX_BYTES)) |_| {
        std.debug.print("skipped: this process reads a file with mode 000 (it runs as root), so an unreadable file cannot be made here\n", .{});
        return error.SkipZigTest;
    } else |_| {}
    try expectRefused(try checkDir(ar, tmp.dir), "AGENTS.md cannot be read: AccessDenied");
}
