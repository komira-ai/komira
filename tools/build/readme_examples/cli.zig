//! The commands of the README examples tool (main.zig): their flags, the
//! files they read and write, what they print and their exit status.
//!
//!     tool generate --readme <README.md> --display <name> --package <import name>
//!                   --links allow|refuse --out-dir <dir> --examples <file>
//!                   [--includes allow|refuse]
//!         Writes, into --out-dir (made if absent), each example's program
//!         `readme_<package>_<line>.mojo` and the runner `readme_<package>.mojo`
//!         that runs them all (program.zig), and to --examples the README line
//!         of each example's opening fence, one per line, in README order.
//!         With no example, --examples is empty and the runner prints that it
//!         ran nothing. --links refuse: refuse a relative link (a README that
//!         ships in its package). An included fence is an example in module
//!         mode (examples.zig); --includes refuse (the README of a library
//!         still on the inline model) refuses include markers. Every flag
//!         but --includes (allow when absent) is required.
//!     tool check --readme <README.md> --display <name> [--example <path>=<file>]... --out <file>
//!         The freshness check of a source-first README (include.zig):
//!         each --example is a file the library lists, <path> as an include
//!         names it (`examples/<name>.mojo`, relative to the README) and
//!         <file> where it is read. Passing, writes one line to --out: how
//!         many examples it shows, or `NO EXAMPLE` when it lists and shows
//!         none (exit 0); refused, prints each refusal on its own line and
//!         writes nothing (exit 1).
//!     tool fill --readme <README.md> --display <name> [--example <path>=<file>]... --out <file>
//!         Writes to --out the patch that makes the README what `fill`
//!         writes (each include's fence body rewritten from its file, nothing
//!         else), as `git apply` takes it from the repository root (`a/` and
//!         `b/` before <display>); empty when the README is fresh. Refused
//!         (exit 1) only when an include cannot be filled: its file is not
//!         listed, its fence is missing, not ```mojo, indented or not closed,
//!         or the file may not be shown.
//!     tool migrate --readme <README.md> --display <name> --out-dir <dir>
//!         Writes <dir>/README.md and <dir>/examples/example_<n>.mojo: the
//!         README made source-first (migrate.zig). Refused (exit 1), writes
//!         nothing.
//!     tool migrate --verify --readme <README.md> --display <name> --migrated <dir> --out <file>
//!         The proof of a migration of <README.md> into <dir> (its README.md
//!         and every file of its examples/), migrate.zig's `verify`. Passing,
//!         writes one line to --out (exit 0); refused, prints each refusal
//!         (exit 1).
//!     tool expect-failure --text <text> --out <file> -- <command>...
//!         Runs <command> (its first word found on PATH unless it holds a
//!         `/`), and passes only when it exits non-zero with <text> in its
//!         stdout or stderr (expect_failure.zig): writes
//!         `FAILED AS EXPECTED: <text>` to --out (exit 0). Otherwise prints
//!         why and the end of its output (exit 1).
//!     tool map --package <import name> --display <name> --report <file>
//!         Prints the report with each `readme_<package>_<line>.mojo:<n>` (an
//!         example's program) rewritten to `<display>:<n>`.
//!     tool link --readme <README.md> --display <name> --out <file>
//!         Writes to --out the arguments of the README's link block
//!         (link.zig), one `run\t<word>` or `build\t<word>` line each; an
//!         empty file when the README holds no block.
//!     tool link-check --readme <README.md> --display <name> --expect <file> --out <file>
//!         When the block's arguments, in `link`'s form, are the bytes of
//!         --expect, writes them to --out (exit 0); otherwise prints both and
//!         writes nothing (exit 1). The build
//!         runs it on each packaged README against the arguments the packer
//!         wrote (tools/build/package/conda.bzl).
//!     tool release-check --out <file> [--expect-refusal <text>]
//!                        (--member <conda name> <display> <README> | --no-readme <conda name> <display>)...
//!         The README gate of a release set (tools/build/package/release_set.bzl):
//!         refuses each member that ships no README (`--no-readme`), and each
//!         whose README holds no example as `generate --links refuse` reads
//!         it (a ```mojo or ```mojo module fence; examples.zig), or is refused
//!         by that read. Each refusal is one line naming the member. Passing, writes to --out `<conda name> <examples>` per
//!         member. With --expect-refusal (the build's own tests of this
//!         check), exit 0 and write the refusal to --out only when the
//!         members are refused and the refusal contains <text>; otherwise
//!         exit 1. --out is required, and at least one member.
//!     tool tasks-check --catalogue <catalogue.json> --catalogue-display <name>
//!                      --root <dir> --display <dir> --out <file>
//!         The check of the common-task pages (tasks.zig): the catalogue,
//!         and each subdirectory of --root as a task directory (files at the
//!         top of --root are not read). Refusals name the catalogue
//!         --catalogue-display and the task files under --display. Passing,
//!         writes to --out `<directory> <status>` per task directory, in
//!         name order (exit 0); refused, prints each refusal on its own line
//!         and writes nothing (exit 1). The build runs it on
//!         docs/tasks/catalogue.json and python/docs/tasks
//!         (python/docs/tasks/BUCK, `:pages`).
//!
//! A flag is `--name value` or `--name=value` (`--verify` takes no value).
//! Everything goes to stdout.
//! Exit status: 0; 1 when the README is refused (each reason on its own line,
//! naming `<display>:<line>`); 2 on bad usage or a file it cannot read or
//! write.

const std = @import("std");
const examples = @import("examples.zig");
const program = @import("program.zig");
const link = @import("link.zig");
const tasks = @import("tasks.zig");
const include = @import("include.zig");
const migrate_mod = @import("migrate.zig");
const expect_failure = @import("expect_failure.zig");
const unified_diff = @import("unified_diff");
const Allocator = std.mem.Allocator;

/// What the process does: its exit status and the bytes it prints (main.zig
/// writes them to stdout and exits, nothing more).
pub const Outcome = struct { code: u8, stdout: []const u8 };

const USAGE = "usage: tool generate --readme F --display NAME --package NAME --links allow|refuse --out-dir D --examples F [--includes allow|refuse]\n" ++
    "       tool check --readme F --display NAME [--example PATH=F]... --out F\n" ++
    "       tool fill --readme F --display NAME [--example PATH=F]... --out F\n" ++
    "       tool migrate [--verify] --readme F --display NAME (--out-dir D | --migrated D --out F)\n" ++
    "       tool expect-failure --text TEXT --out F -- COMMAND...\n" ++
    "       tool map --package NAME --display NAME --report F\n" ++
    "       tool link --readme F --display NAME --out F\n" ++
    "       tool link-check --readme F --display NAME --expect F --out F\n" ++
    "       tool release-check --out F [--expect-refusal TEXT] (--member NAME DISPLAY F | --no-readme NAME DISPLAY)...\n" ++
    "       tool tasks-check --catalogue F --catalogue-display NAME --root D --display D --out F\n";

fn usage(alloc: Allocator, why: []const u8) Outcome {
    const text = std.mem.concat(alloc, u8, &.{ "readme-examples: ", why, "\n", USAGE }) catch oom();
    return .{ .code = 2, .stdout = text };
}

fn oom() noreturn {
    @panic("out of memory");
}

fn fmt(alloc: Allocator, comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(alloc, f, args) catch oom();
}

fn Flags(comptime n: usize) type {
    return union(enum) { values: [n][]const u8, refused: Outcome };
}

/// The value of each flag in `names` (from argv[2]), every one required and
/// non-empty, none twice; or the usage outcome that refuses them.
fn flags(alloc: Allocator, argv: []const []const u8, comptime names: []const []const u8) Flags(names.len) {
    return flagsOpt(alloc, argv, names, &.{});
}

/// `flags` with the flags of `optional` after those of `names`: each may be
/// left out (its value is then ""), and is non-empty when given.
fn flagsOpt(alloc: Allocator, argv: []const []const u8, comptime names: []const []const u8, comptime optional: []const []const u8) Flags(names.len + optional.len) {
    const n_all = names.len + optional.len;
    var values: [n_all][]const u8 = .{""} ** n_all;
    var seen: [n_all]bool = .{false} ** n_all;
    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        var name = a;
        var value: []const u8 = "";
        if (std.mem.indexOfScalar(u8, a, '=')) |eq| {
            name = a[0..eq];
            value = a[eq + 1 ..];
        } else if (i + 1 < argv.len) {
            value = argv[i + 1];
            i += 1;
        } else {
            return .{ .refused = usage(alloc, fmt(alloc, "{s} needs a value", .{a})) };
        }
        const found: ?usize = blk: {
            inline for (names, 0..) |n, k| {
                if (std.mem.startsWith(u8, name, "--") and std.mem.eql(u8, name[2..], n)) break :blk k;
            }
            inline for (optional, 0..) |n, k| {
                if (std.mem.startsWith(u8, name, "--") and std.mem.eql(u8, name[2..], n)) break :blk names.len + k;
            }
            break :blk null;
        };
        const k = found orelse return .{ .refused = usage(alloc, fmt(alloc, "unknown flag {s}", .{name})) };
        if (seen[k]) return .{ .refused = usage(alloc, fmt(alloc, "{s} given twice", .{name})) };
        seen[k] = true;
        values[k] = value;
    }
    inline for (names, 0..) |n, k| {
        if (!seen[k] or values[k].len == 0) return .{ .refused = usage(alloc, "--" ++ n ++ " is required") };
    }
    inline for (optional, 0..) |n, k| {
        if (seen[names.len + k] and values[names.len + k].len == 0) return .{ .refused = usage(alloc, "--" ++ n ++ " needs a value") };
    }
    return .{ .values = values };
}

fn writeFile(dir: std.fs.Dir, path: []const u8, data: []const u8) !void {
    const f = try dir.createFile(path, .{});
    defer f.close();
    try f.writeAll(data);
}

fn generate(alloc: Allocator, dir: std.fs.Dir, argv: []const []const u8) Outcome {
    const v = switch (flagsOpt(alloc, argv, &.{ "readme", "display", "package", "links", "out-dir", "examples" }, &.{"includes"})) {
        .values => |v| v,
        .refused => |o| return o,
    };
    const links = v[3];
    if (!std.mem.eql(u8, links, "allow") and !std.mem.eql(u8, links, "refuse")) {
        return usage(alloc, fmt(alloc, "--links is allow or refuse, not {s}", .{links}));
    }
    const includes = if (v[6].len == 0) "allow" else v[6];
    if (!std.mem.eql(u8, includes, "allow") and !std.mem.eql(u8, includes, "refuse")) {
        return usage(alloc, fmt(alloc, "--includes is allow or refuse, not {s}", .{includes}));
    }
    const text = dir.readFileAlloc(alloc, v[0], std.math.maxInt(usize)) catch |e| {
        return .{ .code = 2, .stdout = fmt(alloc, "readme-examples: cannot read {s}: {s}\n", .{ v[0], @errorName(e) }) };
    };
    const opts = examples.Options{ .refuse_relative_links = std.mem.eql(u8, links, "refuse"), .refuse_includes = std.mem.eql(u8, includes, "refuse") };
    const exs = switch (examples.extractWith(alloc, text, v[1], opts) catch oom()) {
        .examples => |e| e,
        .refused => |why| return .{ .code = 1, .stdout = fmt(alloc, "{s}\n", .{why}) },
    };
    var why: []const u8 = "";
    const programs = program.generatePrograms(alloc, exs, v[2], v[1], &why) catch |e| switch (e) {
        error.Refused => return .{ .code = 1, .stdout = fmt(alloc, "{s}\n", .{why}) },
        error.OutOfMemory => oom(),
    };
    var lines = std.ArrayList(u8).empty;
    for (exs) |ex| lines.writer(alloc).print("{d}\n", .{ex.line}) catch oom();
    writeAll(alloc, dir, v[4], programs, v[5], lines.items) catch |e| {
        return .{ .code = 2, .stdout = fmt(alloc, "readme-examples: cannot write: {s}\n", .{@errorName(e)}) };
    };
    return .{ .code = 0, .stdout = "" };
}

fn writeAll(alloc: Allocator, dir: std.fs.Dir, out_dir: []const u8, programs: []const program.Program, examples_path: []const u8, lines: []const u8) !void {
    try dir.makePath(out_dir);
    for (programs) |p| try writeFile(dir, fmt(alloc, "{s}/{s}", .{ out_dir, p.name }), p.text);
    try writeFile(dir, examples_path, lines);
}

fn map(alloc: Allocator, dir: std.fs.Dir, argv: []const []const u8) Outcome {
    const v = switch (flags(alloc, argv, &.{ "package", "display", "report" })) {
        .values => |v| v,
        .refused => |o| return o,
    };
    const report = dir.readFileAlloc(alloc, v[2], std.math.maxInt(usize)) catch |e| {
        return .{ .code = 2, .stdout = fmt(alloc, "readme-examples: cannot read {s}: {s}\n", .{ v[2], @errorName(e) }) };
    };
    return .{ .code = 0, .stdout = program.mapReport(alloc, report, v[0], v[1]) catch oom() };
}

fn readReadme(alloc: Allocator, dir: std.fs.Dir, path: []const u8) union(enum) { text: []const u8, failed: Outcome } {
    const text = dir.readFileAlloc(alloc, path, std.math.maxInt(usize)) catch |e| {
        return .{ .failed = .{ .code = 2, .stdout = fmt(alloc, "readme-examples: cannot read {s}: {s}\n", .{ path, @errorName(e) }) } };
    };
    return .{ .text = text };
}

/// The README's link block as `run\t<word>`/`build\t<word>` lines (empty
/// without a block), or the refusal outcome.
fn linkArgs(alloc: Allocator, dir: std.fs.Dir, readme: []const u8, display: []const u8) union(enum) { args: []const u8, failed: Outcome } {
    const text = switch (readReadme(alloc, dir, readme)) {
        .text => |x| x,
        .failed => |o| return .{ .failed = o },
    };
    return switch (link.parse(alloc, text, display) catch oom()) {
        .none => .{ .args = "" },
        .commands => |c| .{ .args = link.argsText(alloc, c) catch oom() },
        .refused => |why| .{ .failed = .{ .code = 1, .stdout = fmt(alloc, "{s}\n", .{why}) } },
    };
}

fn linkCmd(alloc: Allocator, dir: std.fs.Dir, argv: []const []const u8) Outcome {
    const v = switch (flags(alloc, argv, &.{ "readme", "display", "out" })) {
        .values => |v| v,
        .refused => |o| return o,
    };
    const args = switch (linkArgs(alloc, dir, v[0], v[1])) {
        .args => |x| x,
        .failed => |o| return o,
    };
    writeFile(dir, v[2], args) catch |e| {
        return .{ .code = 2, .stdout = fmt(alloc, "readme-examples: cannot write {s}: {s}\n", .{ v[2], @errorName(e) }) };
    };
    return .{ .code = 0, .stdout = "" };
}

fn linkCheck(alloc: Allocator, dir: std.fs.Dir, argv: []const []const u8) Outcome {
    const v = switch (flags(alloc, argv, &.{ "readme", "display", "expect", "out" })) {
        .values => |v| v,
        .refused => |o| return o,
    };
    const args = switch (linkArgs(alloc, dir, v[0], v[1])) {
        .args => |x| x,
        .failed => |o| return o,
    };
    const want = switch (readReadme(alloc, dir, v[2])) {
        .text => |x| x,
        .failed => |o| return o,
    };
    if (std.mem.eql(u8, args, want)) {
        writeFile(dir, v[3], args) catch |e| {
            return .{ .code = 2, .stdout = fmt(alloc, "readme-examples: cannot write {s}: {s}\n", .{ v[3], @errorName(e) }) };
        };
        return .{ .code = 0, .stdout = "" };
    }
    return .{ .code = 1, .stdout = fmt(alloc, "{s}: its link block parses to\n{s}which is not what was written:\n{s}", .{ v[1], args, want }) };
}

const Member = struct { name: []const u8, display: []const u8, readme: ?[]const u8 };

/// Why the release refuses release member `m` (one line per
/// reason, each naming the member), or null when it holds an example; adds
/// `<name> <examples>` to `passed` then.
fn releaseRefusal(alloc: Allocator, dir: std.fs.Dir, m: Member, passed: *std.ArrayList(u8)) union(enum) { why: ?[]const u8, failed: Outcome } {
    const path = m.readme orelse return .{ .why = fmt(alloc, "release member {s}: no README is packaged, so the release would refuse it:" ++
        " \"{s} ships no share/doc/{s}/README.md: a release needs a README; add {s}\"", .{ m.name, m.name, m.name, m.display }) };
    const text = switch (readReadme(alloc, dir, path)) {
        .text => |x| x,
        .failed => |o| return .{ .failed = o },
    };
    switch (examples.extract(alloc, text, m.display, true) catch oom()) {
        .refused => |why| {
            var out = std.ArrayList(u8).empty;
            var it = std.mem.splitScalar(u8, why, '\n');
            var first = true;
            while (it.next()) |line| {
                if (!first) out.append(alloc, '\n') catch oom();
                first = false;
                out.writer(alloc).print("release member {s}: the release would refuse its README: {s}", .{ m.name, line }) catch oom();
            }
            return .{ .why = out.items };
        },
        .examples => |exs| {
            if (exs.len == 0) return .{ .why = fmt(alloc, "release member {s}: {s} holds no ```mojo or ```mojo module example, so the release would refuse it:" ++
                " \"{s} holds no ```mojo example, so the validation would run nothing; add one\"", .{ m.name, m.display, m.display }) };
            passed.writer(alloc).print("{s} {d}\n", .{ m.name, exs.len }) catch oom();
            return .{ .why = null };
        },
    }
}

fn releaseCheck(alloc: Allocator, dir: std.fs.Dir, argv: []const []const u8) Outcome {
    var out: ?[]const u8 = null;
    var expect: ?[]const u8 = null;
    var members = std.ArrayList(Member).empty;
    var i: usize = 2;
    while (i < argv.len) {
        const a = argv[i];
        const is_out = std.mem.eql(u8, a, "--out");
        if (is_out or std.mem.eql(u8, a, "--expect-refusal")) {
            if (i + 1 >= argv.len or argv[i + 1].len == 0) return usage(alloc, fmt(alloc, "{s} needs a value", .{a}));
            const slot = if (is_out) &out else &expect;
            if (slot.* != null) return usage(alloc, fmt(alloc, "{s} given twice", .{a}));
            slot.* = argv[i + 1];
            i += 2;
            continue;
        }
        const n: usize = if (std.mem.eql(u8, a, "--member")) 3 else if (std.mem.eql(u8, a, "--no-readme")) 2 else {
            return usage(alloc, fmt(alloc, "unknown argument {s}", .{a}));
        };
        if (i + n >= argv.len) return usage(alloc, fmt(alloc, "{s} needs {d} values", .{ a, n }));
        for (argv[i + 1 .. i + 1 + n]) |v| {
            if (v.len == 0) return usage(alloc, fmt(alloc, "{s} has an empty value", .{a}));
        }
        members.append(alloc, .{ .name = argv[i + 1], .display = argv[i + 2], .readme = if (n == 3) argv[i + 3] else null }) catch oom();
        i += 1 + n;
    }
    const out_path = out orelse return usage(alloc, "--out is required");
    if (members.items.len == 0) return usage(alloc, "no --member or --no-readme");
    var refusals = std.ArrayList(u8).empty;
    var passed = std.ArrayList(u8).empty;
    for (members.items) |m| {
        switch (releaseRefusal(alloc, dir, m, &passed)) {
            .failed => |o| return o,
            .why => |w| if (w) |why| refusals.writer(alloc).print("{s}\n", .{why}) catch oom(),
        }
    }
    var written = passed.items;
    if (expect) |want| {
        if (refusals.items.len == 0) return .{ .code = 1, .stdout = fmt(alloc, "release-check: expected a refusal containing '{s}'; every member passed\n", .{want}) };
        if (std.mem.indexOf(u8, refusals.items, want) == null) {
            return .{ .code = 1, .stdout = fmt(alloc, "release-check: expected a refusal containing '{s}', refused with:\n{s}", .{ want, refusals.items }) };
        }
        written = refusals.items;
    } else if (refusals.items.len > 0) {
        return .{ .code = 1, .stdout = refusals.items };
    }
    writeFile(dir, out_path, written) catch |e| {
        return .{ .code = 2, .stdout = fmt(alloc, "readme-examples: cannot write {s}: {s}\n", .{ out_path, @errorName(e) }) };
    };
    return .{ .code = 0, .stdout = "" };
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn fileLess(_: void, a: tasks.File, b: tasks.File) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// The task directories under `root`, in name order, each with its files
/// in name order (a subdirectory with no bytes).
fn readTasks(alloc: Allocator, dir: std.fs.Dir, root: []const u8) ![]const tasks.Task {
    var top = try dir.openDir(root, .{ .iterate = true });
    defer top.close();
    var names = std.ArrayList([]const u8).empty;
    var it = top.iterate();
    while (try it.next()) |e| {
        if (e.kind == .directory) try names.append(alloc, try alloc.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    var out = std.ArrayList(tasks.Task).empty;
    for (names.items) |name| {
        var sub = try top.openDir(name, .{ .iterate = true });
        defer sub.close();
        var files = std.ArrayList(tasks.File).empty;
        var fit = sub.iterate();
        while (try fit.next()) |e| {
            const data: ?[]const u8 = if (e.kind == .directory) null else try sub.readFileAlloc(alloc, e.name, std.math.maxInt(usize));
            try files.append(alloc, .{ .name = try alloc.dupe(u8, e.name), .data = data });
        }
        std.mem.sort(tasks.File, files.items, {}, fileLess);
        try out.append(alloc, .{ .name = name, .files = files.items });
    }
    return out.items;
}

fn tasksCheck(alloc: Allocator, dir: std.fs.Dir, argv: []const []const u8) Outcome {
    const v = switch (flags(alloc, argv, &.{ "catalogue", "catalogue-display", "root", "display", "out" })) {
        .values => |v| v,
        .refused => |o| return o,
    };
    const catalogue = dir.readFileAlloc(alloc, v[0], std.math.maxInt(usize)) catch |e| {
        return .{ .code = 2, .stdout = fmt(alloc, "readme-examples: cannot read {s}: {s}\n", .{ v[0], @errorName(e) }) };
    };
    const found = readTasks(alloc, dir, v[2]) catch |e| {
        return .{ .code = 2, .stdout = fmt(alloc, "readme-examples: cannot read the task directories of {s}: {s}\n", .{ v[2], @errorName(e) }) };
    };
    const result = tasks.check(alloc, v[3], v[1], catalogue, found) catch oom();
    if (result.refusals.len > 0) {
        const text = std.mem.join(alloc, "\n", result.refusals) catch oom();
        return .{ .code = 1, .stdout = fmt(alloc, "{s}\n", .{text}) };
    }
    writeFile(dir, v[4], result.report) catch |e| {
        return .{ .code = 2, .stdout = fmt(alloc, "readme-examples: cannot write {s}: {s}\n", .{ v[4], @errorName(e) }) };
    };
    return .{ .code = 0, .stdout = "" };
}

/// The flags of `check` and `fill`: the README, its name, the output, and
/// each listed example (`--example <path>=<file>`, read here).
const Shown = struct {
    text: []const u8,
    display: []const u8,
    out: []const u8,
    listed: []const include.Listed,
};

fn readShown(alloc: Allocator, dir: std.fs.Dir, argv: []const []const u8) union(enum) { shown: Shown, failed: Outcome } {
    var readme: ?[]const u8 = null;
    var display: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var listed = std.ArrayList(include.Listed).empty;
    var i: usize = 2;
    while (i < argv.len) {
        const a = argv[i];
        var name = a;
        var value: []const u8 = "";
        if (std.mem.startsWith(u8, a, "--") and std.mem.indexOfScalar(u8, a, '=') != null) {
            const eq = std.mem.indexOfScalar(u8, a, '=').?;
            name = a[0..eq];
            value = a[eq + 1 ..];
            i += 1;
        } else {
            if (i + 1 >= argv.len) return .{ .failed = usage(alloc, fmt(alloc, "{s} needs a value", .{a})) };
            value = argv[i + 1];
            i += 2;
        }
        if (value.len == 0) return .{ .failed = usage(alloc, fmt(alloc, "{s} has an empty value", .{name})) };
        if (std.mem.eql(u8, name, "--example")) {
            const eq = std.mem.indexOfScalar(u8, value, '=') orelse return .{ .failed = usage(alloc, fmt(alloc, "--example {s} is not PATH=FILE", .{value})) };
            const path = value[0..eq];
            const file = value[eq + 1 ..];
            if (path.len == 0 or file.len == 0) return .{ .failed = usage(alloc, fmt(alloc, "--example {s} is not PATH=FILE", .{value})) };
            for (listed.items) |l| {
                if (std.mem.eql(u8, l.path, path)) return .{ .failed = usage(alloc, fmt(alloc, "--example {s} given twice", .{path})) };
            }
            const data = dir.readFileAlloc(alloc, file, std.math.maxInt(usize)) catch |e| {
                return .{ .failed = .{ .code = 2, .stdout = fmt(alloc, "readme-examples: cannot read {s}: {s}\n", .{ file, @errorName(e) }) } };
            };
            listed.append(alloc, .{ .path = path, .data = data }) catch oom();
            continue;
        }
        const slot = if (std.mem.eql(u8, name, "--readme")) &readme else if (std.mem.eql(u8, name, "--display")) &display else if (std.mem.eql(u8, name, "--out")) &out else {
            return .{ .failed = usage(alloc, fmt(alloc, "unknown flag {s}", .{name})) };
        };
        if (slot.* != null) return .{ .failed = usage(alloc, fmt(alloc, "{s} given twice", .{name})) };
        slot.* = value;
    }
    const readme_path = readme orelse return .{ .failed = usage(alloc, "--readme is required") };
    const display_name = display orelse return .{ .failed = usage(alloc, "--display is required") };
    const out_path = out orelse return .{ .failed = usage(alloc, "--out is required") };
    const text = switch (readReadme(alloc, dir, readme_path)) {
        .text => |x| x,
        .failed => |o| return .{ .failed = o },
    };
    return .{ .shown = .{ .text = text, .display = display_name, .out = out_path, .listed = listed.items } };
}

fn refusedLines(alloc: Allocator, refusals: []const []const u8) Outcome {
    const text = std.mem.join(alloc, "\n", refusals) catch oom();
    return .{ .code = 1, .stdout = fmt(alloc, "{s}\n", .{text}) };
}

fn checkCmd(alloc: Allocator, dir: std.fs.Dir, argv: []const []const u8) Outcome {
    const s = switch (readShown(alloc, dir, argv)) {
        .shown => |x| x,
        .failed => |o| return o,
    };
    const r = include.check(alloc, s.text, s.display, s.listed) catch oom();
    if (r.refusals.len > 0) return refusedLines(alloc, r.refusals);
    const line = if (r.shown == 0)
        fmt(alloc, "NO EXAMPLE {s}: it lists no readme_examples and shows none, so nothing was compiled or run\n", .{s.display})
    else
        fmt(alloc, "{s}: {d} example(s), each fence its file byte for byte\n", .{ s.display, r.shown });
    writeFile(dir, s.out, line) catch |e| {
        return .{ .code = 2, .stdout = fmt(alloc, "readme-examples: cannot write {s}: {s}\n", .{ s.out, @errorName(e) }) };
    };
    return .{ .code = 0, .stdout = "" };
}

fn fillCmd(alloc: Allocator, dir: std.fs.Dir, argv: []const []const u8) Outcome {
    const s = switch (readShown(alloc, dir, argv)) {
        .shown => |x| x,
        .failed => |o| return o,
    };
    const r = include.check(alloc, s.text, s.display, s.listed) catch oom();
    if (!r.fillable) return refusedLines(alloc, r.refusals);
    const a_name = fmt(alloc, "a/{s}", .{s.display});
    const b_name = fmt(alloc, "b/{s}", .{s.display});
    const patch = (unified_diff.unifiedDiff(alloc, a_name, b_name, s.text, r.filled) catch oom()) orelse "";
    writeFile(dir, s.out, patch) catch |e| {
        return .{ .code = 2, .stdout = fmt(alloc, "readme-examples: cannot write {s}: {s}\n", .{ s.out, @errorName(e) }) };
    };
    return .{ .code = 0, .stdout = "" };
}

fn listedLess(_: void, a: include.Listed, b: include.Listed) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

/// The files of `<root>/examples`, as `examples/<name>`, in name order; none
/// when there is no such directory.
fn readExamples(alloc: Allocator, dir: std.fs.Dir, root: []const u8) ![]const include.Listed {
    var sub = dir.openDir(fmt(alloc, "{s}/examples", .{root}), .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    defer sub.close();
    var out = std.ArrayList(include.Listed).empty;
    var it = sub.iterate();
    while (try it.next()) |e| {
        if (e.kind == .directory) continue;
        const data = try sub.readFileAlloc(alloc, e.name, std.math.maxInt(usize));
        try out.append(alloc, .{ .path = fmt(alloc, "{s}{s}", .{ include.DIR, e.name }), .data = data });
    }
    std.mem.sort(include.Listed, out.items, {}, listedLess);
    return out.items;
}

fn migrateCmd(alloc: Allocator, dir: std.fs.Dir, argv: []const []const u8) Outcome {
    // `--verify` takes no value: take it out before the flags are read.
    var verify = false;
    var rest = std.ArrayList([]const u8).empty;
    for (argv, 0..) |a, i| {
        if (i >= 2 and std.mem.eql(u8, a, "--verify")) {
            if (verify) return usage(alloc, "--verify given twice");
            verify = true;
            continue;
        }
        rest.append(alloc, a) catch oom();
    }
    if (!verify) {
        const v = switch (flags(alloc, rest.items, &.{ "readme", "display", "out-dir" })) {
            .values => |v| v,
            .refused => |o| return o,
        };
        const text = switch (readReadme(alloc, dir, v[0])) {
            .text => |x| x,
            .failed => |o| return o,
        };
        const m = switch (migrate_mod.migrate(alloc, text, v[1]) catch oom()) {
            .migrated => |m| m,
            .refused => |why| return .{ .code = 1, .stdout = fmt(alloc, "{s}\n", .{why}) },
        };
        writeMigrated(alloc, dir, v[2], m) catch |e| {
            return .{ .code = 2, .stdout = fmt(alloc, "readme-examples: cannot write {s}: {s}\n", .{ v[2], @errorName(e) }) };
        };
        return .{ .code = 0, .stdout = "" };
    }
    const v = switch (flags(alloc, rest.items, &.{ "readme", "display", "migrated", "out" })) {
        .values => |v| v,
        .refused => |o| return o,
    };
    const old = switch (readReadme(alloc, dir, v[0])) {
        .text => |x| x,
        .failed => |o| return o,
    };
    const new = switch (readReadme(alloc, dir, fmt(alloc, "{s}/README.md", .{v[2]}))) {
        .text => |x| x,
        .failed => |o| return o,
    };
    const files = readExamples(alloc, dir, v[2]) catch |e| {
        return .{ .code = 2, .stdout = fmt(alloc, "readme-examples: cannot read {s}/examples: {s}\n", .{ v[2], @errorName(e) }) };
    };
    const refusals = migrate_mod.verify(alloc, old, v[1], new, files) catch oom();
    if (refusals.len > 0) return refusedLines(alloc, refusals);
    const line = fmt(alloc, "migrate --verify {s}: {d} example(s), each file the program the gate ran for its fence; the README differs only inside them\n", .{ v[1], files.len });
    writeFile(dir, v[3], line) catch |e| {
        return .{ .code = 2, .stdout = fmt(alloc, "readme-examples: cannot write {s}: {s}\n", .{ v[3], @errorName(e) }) };
    };
    return .{ .code = 0, .stdout = "" };
}

fn writeMigrated(alloc: Allocator, dir: std.fs.Dir, out_dir: []const u8, m: migrate_mod.Migrated) !void {
    try dir.makePath(fmt(alloc, "{s}/examples", .{out_dir}));
    try writeFile(dir, fmt(alloc, "{s}/README.md", .{out_dir}), m.readme);
    for (m.files) |f| try writeFile(dir, fmt(alloc, "{s}/{s}", .{ out_dir, f.path }), f.data);
}

fn expectFailureCmd(alloc: Allocator, dir: std.fs.Dir, argv: []const []const u8) Outcome {
    var sep: ?usize = null;
    for (argv[2..], 2..) |a, i| {
        if (std.mem.eql(u8, a, "--")) {
            sep = i;
            break;
        }
    }
    const at = sep orelse return usage(alloc, "expect-failure needs `--` and the command after its flags");
    const v = switch (flags(alloc, argv[0..at], &.{ "text", "out" })) {
        .values => |v| v,
        .refused => |o| return o,
    };
    const cmd = argv[at + 1 ..];
    if (cmd.len == 0) return usage(alloc, "expect-failure: no command after `--`");
    const r = std.process.Child.run(.{
        .allocator = alloc,
        .argv = cmd,
        .cwd_dir = dir,
        .max_output_bytes = 1 << 26,
    }) catch |e| {
        return .{ .code = 2, .stdout = fmt(alloc, "readme-examples: cannot run {s}: {s}\n", .{ cmd[0], @errorName(e) }) };
    };
    const end = expect_failure.endOf(r.term);
    const output = std.mem.concat(alloc, u8, &.{ r.stdout, r.stderr }) catch oom();
    if (expect_failure.judge(alloc, end, output, v[0]) catch oom()) |why| {
        return .{ .code = 1, .stdout = fmt(alloc, "expect-failure: {s}\n", .{why}) };
    }
    writeFile(dir, v[1], fmt(alloc, "FAILED AS EXPECTED: {s}\n", .{v[0]})) catch |e| {
        return .{ .code = 2, .stdout = fmt(alloc, "readme-examples: cannot write {s}: {s}\n", .{ v[1], @errorName(e) }) };
    };
    return .{ .code = 0, .stdout = "" };
}

/// What the tool does with `argv`, paths read relative to `dir`.
pub fn run(alloc: Allocator, dir: std.fs.Dir, argv: []const []const u8) Outcome {
    if (argv.len < 2) return usage(alloc, "no subcommand");
    if (std.mem.eql(u8, argv[1], "generate")) return generate(alloc, dir, argv);
    if (std.mem.eql(u8, argv[1], "map")) return map(alloc, dir, argv);
    if (std.mem.eql(u8, argv[1], "link")) return linkCmd(alloc, dir, argv);
    if (std.mem.eql(u8, argv[1], "link-check")) return linkCheck(alloc, dir, argv);
    if (std.mem.eql(u8, argv[1], "release-check")) return releaseCheck(alloc, dir, argv);
    if (std.mem.eql(u8, argv[1], "tasks-check")) return tasksCheck(alloc, dir, argv);
    if (std.mem.eql(u8, argv[1], "check")) return checkCmd(alloc, dir, argv);
    if (std.mem.eql(u8, argv[1], "fill")) return fillCmd(alloc, dir, argv);
    if (std.mem.eql(u8, argv[1], "migrate")) return migrateCmd(alloc, dir, argv);
    if (std.mem.eql(u8, argv[1], "expect-failure")) return expectFailureCmd(alloc, dir, argv);
    return usage(alloc, fmt(alloc, "unknown subcommand {s}", .{argv[1]}));
}
