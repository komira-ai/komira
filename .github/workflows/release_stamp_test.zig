//! The cases of the stamped builds that evaluate release/BUCK, //:release_stamp_cases: a `zig_test` run as a
//! build action. The subjects are the bytes of every workflow (KOMIRA_TEST_WORK/workflows/<name>.yml), every
//! local action (KOMIRA_TEST_WORK/actions/<name>.yml), release/release_set.bzl (release_set.bzl) and
//! release/BUCK (release.BUCK).
//!
//! release/BUCK calls the macro release_set (release_set.bzl), which fails the evaluation of the whole file,
//! and so the build of every target in it, when the build is stamped (`komira.package_stamp` set to anything
//! but `0`) and does not also set the release's revision, run id and attempt. A workflow step that builds a
//! target of release/BUCK stamped therefore passes the three values, the way release.yml's build of
//! //release:release_set does:
//!   -c komira.release_revision=${{ github.sha }} -c komira.release_run_id=gh-${{ github.run_id }}
//!   -c komira.release_attempt=${{ github.run_attempt }}
//! What the cases catch:
//!  - a command of a workflow or an action that sets komira.package_stamp and names a target of a package
//!    in EVALUATES (release itself, and the packages that hold a target depending on a target of release;
//!    any target of them counts, so the case is stricter than the failure for the targets that reach no
//!    target of release), or a recursive pattern over one, without each of the three flags, is
//!    refused with the file, the line, the target and the first missing flag;
//!  - a command is what YAML and the shell make one: a value folded (`>`) or written over several lines is one
//!    command, a shell line ending in a backslash runs on into the next, and each line of a literal block
//!    (`|`) is its own command; a comment, or the part of a value after ` #`, is no command and no flag;
//!  - the premise: release_set.bzl reads exactly the keys package_stamp, release_revision, release_run_id and
//!    release_attempt of `komira`, and release/BUCK loads release_set and calls it, so a fourth key or a moved
//!    call turns this case red until it is changed with them;
//!  - the real files: every workflow and action passes, and npm.yml holds three stamped builds of
//!    release/BUCK (two of //release:npm_packages, one of //release:npm_packages_macos_arm64) and
//!    release.yml one of //release:release_set, so the case reads the builds it
//!    is about.
//! Each defect is written into the real text, or into a new workflow, and must be refused with its exact
//! message.

const std = @import("std");
const t = std.testing;

/// The three flags release.yml's stamped build of //release:release_set passes, in the order the refusal
/// names the first one missing.
const RELEASE_FLAGS = [_][]const u8{
    "-c komira.release_revision=${{ github.sha }}",
    "-c komira.release_run_id=gh-${{ github.run_id }}",
    "-c komira.release_attempt=${{ github.run_attempt }}",
};

/// The flags as one run of text, the way the workflows write them.
const FLAGS_TEXT = RELEASE_FLAGS[0] ++ " " ++ RELEASE_FLAGS[1] ++ " " ++ RELEASE_FLAGS[2];

/// The packages (of the cell komira) a build of whose targets may load release/BUCK, every target of them
/// counted: release itself, and the packages that hold a target depending on one of release: the root package
/// (//:release_macos_cases reads //release:release_buck and //release:darwin_libs.bzl), tools/build/ci (its
/// cases read //release:mopm_plan_expectation and //release:release_packages_json) and ci (the aggregate
/// //ci:pr reaches every check).
const EVALUATES = [_][]const u8{ "release", "", "tools/build/ci", "ci" };

/// The keys of `komira` that release_set.bzl reads, in its order.
const KEYS = "package_stamp, release_revision, release_run_id, release_attempt";

const STAMP_KEY = "komira.package_stamp=";

fn indentOf(line: []const u8) usize {
    return line.len - std.mem.trimLeft(u8, line, " ").len;
}

fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t").len == 0;
}

fn isComment(line: []const u8) bool {
    const s = std.mem.trimLeft(u8, line, " ");
    return s.len > 0 and s[0] == '#';
}

/// The column of the line's key: its indent, and the two of `- ` for the first key of a sequence item.
fn keyColumn(line: []const u8) usize {
    const s = line[indentOf(line)..];
    return indentOf(line) + @as(usize, if (std.mem.startsWith(u8, s, "- ")) 2 else 0);
}

/// The value of the line's `key: value`, or null when the line is no key with a value on it.
fn valueOf(line: []const u8) ?[]const u8 {
    var s = line[indentOf(line)..];
    if (std.mem.startsWith(u8, s, "- ")) s = s[2..];
    const at = std.mem.indexOf(u8, s, ": ") orelse return null;
    const key = s[0..at];
    if (key.len == 0 or std.mem.indexOfAny(u8, key, " '\"") != null) return null;
    const value = std.mem.trim(u8, s[at + 2 ..], " ");
    if (value.len == 0) return null;
    return value;
}

/// One command: the number of its first line and its text, with no comment.
const Command = struct { line: usize, text: []const u8 };

/// `text` cut at its first ` #`, the start of a YAML or shell comment.
fn uncommented(text: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, text, " #") orelse return text;
    return text[0..at];
}

/// The commands of a workflow or action text, comments left out (see the header).
fn commands(ar: std.mem.Allocator, text: []const u8) ![]const Command {
    var lines = std.ArrayList([]const u8).empty;
    var split = std.mem.splitScalar(u8, text, '\n');
    while (split.next()) |l| try lines.append(ar, std.mem.trimRight(u8, l, "\r"));
    const all = lines.items;
    var out = std.ArrayList(Command).empty;
    // The key column of the literal block the lines are in, if any.
    var literal: ?usize = null;
    var i: usize = 0;
    while (i < all.len) {
        const first = i;
        const line = all[i];
        i += 1;
        if (isBlank(line)) continue;
        if (literal) |col| {
            if (indentOf(line) > col) {
                if (isComment(line)) continue;
                // a shell line of the block, run on while it ends in a backslash
                var buf = std.ArrayList(u8).empty;
                try buf.appendSlice(ar, std.mem.trim(u8, uncommented(line), " "));
                while (i < all.len and std.mem.endsWith(u8, buf.items, "\\")) : (i += 1) {
                    buf.shrinkRetainingCapacity(buf.items.len - 1);
                    try buf.append(ar, ' ');
                    try buf.appendSlice(ar, std.mem.trim(u8, uncommented(all[i]), " "));
                }
                try out.append(ar, .{ .line = first + 1, .text = try buf.toOwnedSlice(ar) });
                continue;
            }
            literal = null;
        }
        if (isComment(line)) continue;
        const col = keyColumn(line);
        const value = valueOf(line) orelse {
            try out.append(ar, .{ .line = first + 1, .text = uncommented(line) });
            continue;
        };
        if (std.mem.startsWith(u8, value, "|")) {
            literal = col;
            continue;
        }
        // a plain, quoted or folded value: every deeper line is more of it
        var buf = std.ArrayList(u8).empty;
        try buf.appendSlice(ar, uncommented(line));
        while (i < all.len and (isBlank(all[i]) or indentOf(all[i]) > col)) : (i += 1) {
            if (isBlank(all[i]) or isComment(all[i])) continue;
            try buf.append(ar, ' ');
            try buf.appendSlice(ar, std.mem.trim(u8, uncommented(all[i]), " "));
        }
        try out.append(ar, .{ .line = first + 1, .text = try buf.toOwnedSlice(ar) });
    }
    return out.toOwnedSlice(ar);
}

/// Whether the command sets komira.package_stamp to a value other than `0` (release_set's reading).
fn stamped(text: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, STAMP_KEY)) |at| {
        const start = at + STAMP_KEY.len;
        var end = start;
        while (end < text.len and std.mem.indexOfScalar(u8, " \t'\"", text[end]) == null) end += 1;
        if (!std.mem.eql(u8, text[start..end], "0")) return true;
        from = end;
    }
    return false;
}

/// Whether the package `pkg` is in EVALUATES.
fn evaluates(pkg: []const u8) bool {
    for (EVALUATES) |p| if (std.mem.eql(u8, p, pkg)) return true;
    return false;
}

/// Whether the target or pattern `token` (of the cell komira) is in a package of EVALUATES, or is a
/// recursive pattern over one.
fn reachesRelease(token: []const u8) bool {
    const s = if (std.mem.startsWith(u8, token, "@")) token[1..] else token;
    const at = std.mem.indexOf(u8, s, "//") orelse return false;
    const cell = s[0..at];
    if (cell.len != 0 and !std.mem.eql(u8, cell, "komira")) return false;
    const rest = s[at + 2 ..];
    if (std.mem.eql(u8, rest, "...")) return true;
    if (std.mem.endsWith(u8, rest, "/...")) {
        const base = rest[0 .. rest.len - "/...".len];
        for (EVALUATES) |p| {
            if (std.mem.eql(u8, p, base)) return true;
            if (std.mem.startsWith(u8, p, base) and p.len > base.len and p[base.len] == '/') return true;
        }
        return false;
    }
    const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return false;
    return evaluates(rest[0..colon]);
}

/// The first target of the command that loads release/BUCK, or null.
fn releaseTarget(text: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, text, " \t'\"");
    while (it.next()) |token| if (reachesRelease(token)) return token;
    return null;
}

/// The stamped commands of `text` that load release/BUCK.
fn stampedReleaseBuilds(ar: std.mem.Allocator, text: []const u8) ![]const Command {
    var out = std.ArrayList(Command).empty;
    for (try commands(ar, text)) |c| {
        if (stamped(c.text) and releaseTarget(c.text) != null) try out.append(ar, c);
    }
    return out.toOwnedSlice(ar);
}

/// Null if every stamped command of the workflow or action `name` (its text `text`) that loads release/BUCK
/// passes the three flags, else the refusal of the first that does not.
fn check(ar: std.mem.Allocator, name: []const u8, text: []const u8) !?[]const u8 {
    for (try stampedReleaseBuilds(ar, text)) |c| {
        for (RELEASE_FLAGS) |flag| {
            if (std.mem.indexOf(u8, c.text, flag) == null) {
                return try std.fmt.allocPrint(ar, "{s}:{d}: a stamped build of {s} evaluates release/BUCK, whose release_set fails without `{s}`: pass the release's revision, run id and attempt as release.yml does", .{ name, c.line, releaseTarget(c.text).?, flag });
            }
        }
    }
    return null;
}

/// Null if release_set.bzl reads exactly KEYS of `komira`, else the refusal.
fn checkMacro(ar: std.mem.Allocator, text: []const u8) !?[]const u8 {
    const needle = "read_config(\"komira\", \"";
    var keys = std.ArrayList(u8).empty;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, needle)) |at| {
        const start = at + needle.len;
        const end = std.mem.indexOfScalarPos(u8, text, start, '"') orelse text.len;
        if (keys.items.len != 0) try keys.appendSlice(ar, ", ");
        try keys.appendSlice(ar, text[start..end]);
        from = end;
    }
    if (std.mem.eql(u8, keys.items, KEYS)) return null;
    return try std.fmt.allocPrint(ar, "release_set.bzl reads the keys `{s}` of komira, not `{s}`: hold the stamped builds of the workflows to the keys it reads", .{ keys.items, KEYS });
}

/// Null if release/BUCK loads release_set and calls it, else the refusal.
fn checkBuck(ar: std.mem.Allocator, text: []const u8) !?[]const u8 {
    const loads = std.mem.indexOf(u8, text, "load(\":release_set.bzl\", \"release_set\")") != null;
    const calls = std.mem.indexOf(u8, text, "\nrelease_set(\n") != null;
    if (loads and calls) return null;
    return try std.fmt.allocPrint(ar, "release.BUCK no longer loads and calls release_set: change these cases with it", .{});
}

fn work(ar: std.mem.Allocator) ![]const u8 {
    return std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK");
}

fn readData(ar: std.mem.Allocator, rel: []const u8) ![]const u8 {
    return std.fs.cwd().readFileAlloc(ar, try std.fs.path.join(ar, &.{ try work(ar), rel }), 1 << 22);
}

/// The file names of the directory `sub` of the test's data, sorted.
fn listDir(ar: std.mem.Allocator, sub: []const u8) ![]const []const u8 {
    const path = try std.fs.path.join(ar, &.{ try work(ar), sub });
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();
    var out = std.ArrayList([]const u8).empty;
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (e.kind == .directory) continue;
        try out.append(ar, try ar.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return out.items;
}

/// `text` with its one `old` replaced by `new`; fails when `old` is not in it exactly once.
fn edit(ar: std.mem.Allocator, text: []const u8, old: []const u8, new: []const u8) ![]const u8 {
    const at = std.mem.indexOf(u8, text, old) orelse {
        std.debug.print("not in the text: {s}\n", .{old});
        return error.NotFound;
    };
    if (std.mem.indexOfPos(u8, text, at + old.len, old) != null) {
        std.debug.print("more than once in the text: {s}\n", .{old});
        return error.NotUnique;
    }
    return try std.mem.concat(ar, u8, &.{ text[0..at], new, text[at + old.len ..] });
}

/// The number of the line of `text` that holds `needle`.
fn lineOf(text: []const u8, needle: []const u8) !usize {
    const at = std.mem.indexOf(u8, text, needle) orelse return error.NotFound;
    return std.mem.count(u8, text[0..at], "\n") + 1;
}

/// The refusal of the stamped build of `target` at `name`:`line` that lacks `flag`.
fn refusal(ar: std.mem.Allocator, name: []const u8, line: usize, target: []const u8, flag: []const u8) ![]const u8 {
    return std.fmt.allocPrint(ar, "{s}:{d}: a stamped build of {s} evaluates release/BUCK, whose release_set fails without `{s}`: pass the release's revision, run id and attempt as release.yml does", .{ name, line, target, flag });
}

fn expectExact(got_or_null: ?[]const u8, want: []const u8) !void {
    const got = got_or_null orelse {
        std.debug.print("accepted a text that must be refused with: {s}\n", .{want});
        return error.Accepted;
    };
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("refused with \"{s}\", wanted \"{s}\"\n", .{ got, want });
        return error.WrongRefusal;
    }
}

fn expectRefused(ar: std.mem.Allocator, name: []const u8, text: []const u8, want: []const u8) !void {
    try expectExact(try check(ar, name, text), want);
}

fn expectAccepted(ar: std.mem.Allocator, name: []const u8, text: []const u8) !void {
    if (try check(ar, name, text)) |got| {
        std.debug.print("refused a text that holds the flags: {s}\n", .{got});
        return error.Refused;
    }
}

/// A workflow of one job whose one step runs `run` (a line, or the lines of a literal block).
fn workflowRunning(ar: std.mem.Allocator, run: []const u8) ![]const u8 {
    return std.fmt.allocPrint(ar, "name: new\non:\n  push:\n    branches: [main]\npermissions: {{}}\njobs:\n  build:\n    runs-on: ubuntu-24.04\n    steps:\n      - name: build\n{s}\n", .{run});
}

/// A workflow of one job whose one step runs the buck2-farm action with `with` under `with:`.
fn workflowFarm(ar: std.mem.Allocator, with: []const u8) ![]const u8 {
    return std.fmt.allocPrint(ar, "name: new\non:\n  push:\n    branches: [main]\npermissions: {{}}\njobs:\n  build:\n    runs-on: ubuntu-24.04\n    steps:\n      - name: build\n        uses: ./.github/actions/buck2-farm\n        with:\n{s}\n          assert-remote: ${{{{ steps.assert.outputs.path }}}}\n", .{with});
}

const STAMP = "-c komira.package_stamp=${{ steps.stamp.outputs.build_number }}";

test "every workflow and action passes the release's values on each stamped build that evaluates release/BUCK" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    for ([_][]const u8{ "workflows", "actions" }) |sub| {
        const names = try listDir(ar, sub);
        try t.expect(names.len > 0);
        for (names) |name| {
            if (try check(ar, name, try readData(ar, try std.fs.path.join(ar, &.{ sub, name })))) |got| {
                std.debug.print("{s}\n", .{got});
                return error.Refused;
            }
        }
    }
    // the case reads the builds it is about
    try t.expectEqual(@as(usize, 3), (try stampedReleaseBuilds(ar, try readData(ar, "workflows/npm.yml"))).len);
    try t.expectEqual(@as(usize, 1), (try stampedReleaseBuilds(ar, try readData(ar, "workflows/release.yml"))).len);
    try t.expectEqual(@as(usize, 0), (try stampedReleaseBuilds(ar, try readData(ar, "workflows/pypi.yml"))).len);
    try t.expect((try checkMacro(ar, try readData(ar, "release_set.bzl"))) == null);
    try t.expect((try checkBuck(ar, try readData(ar, "release.BUCK"))) == null);
}

test "npm.yml's stamped builds of //release:npm_packages and //release:npm_packages_macos_arm64 without the release's values are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try readData(ar, "workflows/npm.yml");
    // the build job's step and the test job's step, as each was before the values: both are refused
    const build = " " ++ FLAGS_TEXT ++ " //release:npm_packages --out";
    const old_build = try edit(ar, text, build, " //release:npm_packages --out");
    try expectRefused(ar, "npm.yml", old_build, try refusal(ar, "npm.yml", try lineOf(text, build), "//release:npm_packages", RELEASE_FLAGS[0]));
    const record = " " ++ FLAGS_TEXT ++ " //release:npm_packages[npm_set.json]";
    const old_record = try edit(ar, text, record, " //release:npm_packages[npm_set.json]");
    try expectRefused(ar, "npm.yml", old_record, try refusal(ar, "npm.yml", try lineOf(text, record), "//release:npm_packages[npm_set.json]", RELEASE_FLAGS[0]));
    // the macOS job's set, without them
    const macos = " " ++ FLAGS_TEXT ++ " //release:npm_packages_macos_arm64 --out";
    const old_macos = try edit(ar, text, macos, " //release:npm_packages_macos_arm64 --out");
    try expectRefused(ar, "npm.yml", old_macos, try refusal(ar, "npm.yml", try lineOf(text, macos), "//release:npm_packages_macos_arm64", RELEASE_FLAGS[0]));
    // the real text passes; its stamped install test is of //node, which loads no release/BUCK
    try expectAccepted(ar, "npm.yml", text);
}

test "release.yml's build of the release set is refused without any one of the three values, or with another value" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const text = try readData(ar, "workflows/release.yml");
    const line = try lineOf(text, FLAGS_TEXT);
    inline for (RELEASE_FLAGS) |flag| {
        try expectRefused(ar, "release.yml", try edit(ar, text, " " ++ flag, ""), try refusal(ar, "release.yml", line, "//release:release_set", flag));
    }
    // the revision of HEAD, a run id without its prefix, a fixed attempt
    try expectRefused(ar, "release.yml", try edit(ar, text, RELEASE_FLAGS[0], "-c komira.release_revision=HEAD"), try refusal(ar, "release.yml", line, "//release:release_set", RELEASE_FLAGS[0]));
    try expectRefused(ar, "release.yml", try edit(ar, text, RELEASE_FLAGS[1], "-c komira.release_run_id=${{ github.run_id }}"), try refusal(ar, "release.yml", line, "//release:release_set", RELEASE_FLAGS[1]));
    try expectRefused(ar, "release.yml", try edit(ar, text, RELEASE_FLAGS[2], "-c komira.release_attempt=1"), try refusal(ar, "release.yml", line, "//release:release_set", RELEASE_FLAGS[2]));
}

test "a new workflow's stamped build of any target or pattern that loads release/BUCK is refused, and of one that does not is not" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const refused = [_][]const u8{
        "//release:npm_packages",
        "komira//release:mopm_artifacts",
        "@komira//release:release_set",
        "//release/...",
        "//...",
        "komira//...",
        "//:release_macos_cases",
        "//tools/build/ci:release_plan_expect_cases",
        "//tools/build/...",
        "//ci:pr",
    };
    for (refused) |target| {
        const cmd = try std.fmt.allocPrint(ar, "        run: ./buck2 build {s} {s}", .{ STAMP, target });
        try expectRefused(ar, "new.yml", try workflowRunning(ar, cmd), try refusal(ar, "new.yml", 11, target, RELEASE_FLAGS[0]));
        // with the three values it passes
        const ok = try std.fmt.allocPrint(ar, "        run: ./buck2 build {s} {s} {s}", .{ STAMP, FLAGS_TEXT, target });
        try expectAccepted(ar, "new.yml", try workflowRunning(ar, ok));
    }
    const accepted = [_][]const u8{
        // packages that load no release/BUCK, and another cell's package named release
        "//release/ci:release_json",
        "//release/readme_e2e:packages.bzl",
        "//node:install_test",
        "//python:komira_wheel[release]",
        "//tools/build/ci/tests:x",
        "tests//release:x",
        "//releases:x",
    };
    for (accepted) |target| {
        const cmd = try std.fmt.allocPrint(ar, "        run: ./buck2 build {s} {s}", .{ STAMP, target });
        try expectAccepted(ar, "new.yml", try workflowRunning(ar, cmd));
    }
    // a build that is not stamped, or stamped 0 (release_set's unstamped), needs no value
    try expectAccepted(ar, "new.yml", try workflowRunning(ar, "        run: ./buck2 build //release:release_set"));
    try expectAccepted(ar, "new.yml", try workflowRunning(ar, "        run: ./buck2 build -c komira.package_stamp=0 //release:release_set"));
    try expectAccepted(ar, "new.yml", try workflowRunning(ar, "        run: ./buck2 build -c komira.package_commit=abc //release:release_set"));
    // a stamp of the empty string is a stamp to release_set
    try expectRefused(ar, "new.yml", try workflowRunning(ar, "        run: ./buck2 build -c komira.package_stamp= //release:release_set"), try refusal(ar, "new.yml", 11, "//release:release_set", RELEASE_FLAGS[0]));
    // a stamp spelled with --config, and a stamp of 0 then another one
    try expectRefused(ar, "new.yml", try workflowRunning(ar, "        run: ./buck2 build --config komira.package_stamp=7 //release:release_set"), try refusal(ar, "new.yml", 11, "//release:release_set", RELEASE_FLAGS[0]));
    try expectRefused(ar, "new.yml", try workflowRunning(ar, "        run: ./buck2 build -c komira.package_stamp=0 -c komira.package_stamp=7 //release:release_set"), try refusal(ar, "new.yml", 11, "//release:release_set", RELEASE_FLAGS[0]));
    // a quoted run line, through the buck2-farm action
    try expectRefused(ar, "new.yml", try workflowRunning(ar, "        run: './buck2 build " ++ STAMP ++ " //release:npm_packages'"), try refusal(ar, "new.yml", 11, "//release:npm_packages", RELEASE_FLAGS[0]));
    try expectRefused(ar, "new.yml", try workflowFarm(ar, "          args: build " ++ STAMP ++ " //release:npm_packages --out x"), try refusal(ar, "new.yml", 13, "//release:npm_packages", RELEASE_FLAGS[0]));
}

test "a command written over several lines is one command, each line of a literal block its own, and a comment is none" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    // a folded value, and a plain value over two lines: the target on the second line
    try expectRefused(ar, "new.yml", try workflowFarm(ar, "          args: >-\n            build " ++ STAMP ++ "\n            //release:npm_packages"), try refusal(ar, "new.yml", 13, "//release:npm_packages", RELEASE_FLAGS[0]));
    try expectRefused(ar, "new.yml", try workflowFarm(ar, "          args: build " ++ STAMP ++ "\n            //release:npm_packages"), try refusal(ar, "new.yml", 13, "//release:npm_packages", RELEASE_FLAGS[0]));
    // the values on the folded value's second line pass
    try expectAccepted(ar, "new.yml", try workflowFarm(ar, "          args: >-\n            build " ++ STAMP ++ "\n            " ++ FLAGS_TEXT ++ " //release:npm_packages"));
    // a shell line run on with a backslash, in a literal block
    const block = "        run: |\n          echo start\n          ./buck2 build " ++ STAMP ++ " \\\n            //release:npm_packages";
    try expectRefused(ar, "new.yml", try workflowRunning(ar, block), try refusal(ar, "new.yml", 13, "//release:npm_packages", RELEASE_FLAGS[0]));
    const block_ok = "        run: |\n          ./buck2 build " ++ STAMP ++ " \\\n            " ++ FLAGS_TEXT ++ " \\\n            //release:npm_packages";
    try expectAccepted(ar, "new.yml", try workflowRunning(ar, block_ok));
    // two commands of a literal block: the values of one are not the other's
    const two = "        run: |\n          ./buck2 build " ++ STAMP ++ " " ++ FLAGS_TEXT ++ " //release:release_set\n          ./buck2 build " ++ STAMP ++ " //release:npm_packages";
    try expectRefused(ar, "new.yml", try workflowRunning(ar, two), try refusal(ar, "new.yml", 13, "//release:npm_packages", RELEASE_FLAGS[0]));
    // after a literal block, the next key is read again
    const after = "        run: |\n          echo start\n      - name: next\n        run: ./buck2 build " ++ STAMP ++ " //release:npm_packages";
    try expectRefused(ar, "new.yml", try workflowRunning(ar, after), try refusal(ar, "new.yml", 14, "//release:npm_packages", RELEASE_FLAGS[0]));
    // the values in a trailing comment are not passed; a commented-out build is no build
    try expectRefused(ar, "new.yml", try workflowRunning(ar, "        run: ./buck2 build " ++ STAMP ++ " //release:npm_packages # " ++ FLAGS_TEXT), try refusal(ar, "new.yml", 11, "//release:npm_packages", RELEASE_FLAGS[0]));
    try expectAccepted(ar, "new.yml", try workflowRunning(ar, "        # run: ./buck2 build " ++ STAMP ++ " //release:npm_packages\n        run: true"));
    try expectAccepted(ar, "new.yml", try workflowRunning(ar, "        run: |\n          # ./buck2 build " ++ STAMP ++ " //release:npm_packages\n          true"));
}

test "the premise: release_set.bzl reads exactly the four keys and release/BUCK calls release_set" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const macro = try readData(ar, "release_set.bzl");
    const attempt = "    attempt = read_config(\"komira\", \"release_attempt\", \"\")\n";
    // a fourth value release_set needs, and one it no longer reads
    const more = try edit(ar, macro, attempt, attempt ++ "    channel = read_config(\"komira\", \"release_channel\", \"\")\n");
    try expectExact(try checkMacro(ar, more), "release_set.bzl reads the keys `" ++ KEYS ++ ", release_channel` of komira, not `" ++ KEYS ++ "`: hold the stamped builds of the workflows to the keys it reads");
    const fewer = try edit(ar, macro, attempt, "    attempt = \"1\"\n");
    try expectExact(try checkMacro(ar, fewer), "release_set.bzl reads the keys `package_stamp, release_revision, release_run_id` of komira, not `" ++ KEYS ++ "`: hold the stamped builds of the workflows to the keys it reads");
    const buck = try readData(ar, "release.BUCK");
    const want = "release.BUCK no longer loads and calls release_set: change these cases with it";
    try expectExact(try checkBuck(ar, try edit(ar, buck, "\nrelease_set(\n", "\n_moved_release_set(\n")), want);
    try expectExact(try checkBuck(ar, try edit(ar, buck, "load(\":release_set.bzl\", \"release_set\")", "load(\"//release/set:release_set.bzl\", \"release_set\")")), want);
}
