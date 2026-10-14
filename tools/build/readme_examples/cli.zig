//! The commands of the README examples tool (main.zig): their flags, the
//! files they read and write, what they print and their exit status.
//!
//!     tool generate --readme <README.md> --display <name> --package <import name>
//!                   --links allow|refuse --out-dir <dir> --examples <file>
//!         Writes, into --out-dir (made if absent), each example's program
//!         `readme_<package>_<line>.mojo` and the runner `readme_<package>.mojo`
//!         that runs them all (program.zig), and to --examples the README line
//!         of each example's opening fence, one per line, in README order.
//!         With no example, --examples is empty and the runner prints that it
//!         ran nothing. --links refuse: refuse a relative link (a README that
//!         ships in its package). Every flag is required.
//!     tool map --package <import name> --display <name> --report <file>
//!         Prints the report with each `readme_<package>_<line>.mojo:<n>` (an
//!         example's program) rewritten to `<display>:<n>`.
//!     tool link --readme <README.md> --display <name> --out <file>
//!         Writes to --out the arguments of the README's link block
//!         (link.zig), one `run\t<word>` or `build\t<word>` line each; an
//!         empty file when the README holds no block. kci's install
//!         validation reads them (src/kci_validate, readme_link.mojo).
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
//!         by that read. kci's install validation (src/kci_validate,
//!         readme_installed.mojo) refuses both after a release is published;
//!         each refusal is one line naming the member and quoting kci's
//!         words. Passing, writes to --out `<conda name> <examples>` per
//!         member. With --expect-refusal (the build's own tests of this
//!         check), exit 0 and write the refusal to --out only when the
//!         members are refused and the refusal contains <text>; otherwise
//!         exit 1. --out is required, and at least one member.
//!
//! A flag is `--name value` or `--name=value`. Everything goes to stdout.
//! Exit status: 0; 1 when the README is refused (each reason on its own line,
//! naming `<display>:<line>`); 2 on bad usage or a file it cannot read or
//! write.

const std = @import("std");
const examples = @import("examples.zig");
const program = @import("program.zig");
const link = @import("link.zig");
const Allocator = std.mem.Allocator;

/// What the process does: its exit status and the bytes it prints (main.zig
/// writes them to stdout and exits, nothing more).
pub const Outcome = struct { code: u8, stdout: []const u8 };

const USAGE = "usage: tool generate --readme F --display NAME --package NAME --links allow|refuse --out-dir D --examples F\n" ++
    "       tool map --package NAME --display NAME --report F\n" ++
    "       tool link --readme F --display NAME --out F\n" ++
    "       tool link-check --readme F --display NAME --expect F --out F\n" ++
    "       tool release-check --out F [--expect-refusal TEXT] (--member NAME DISPLAY F | --no-readme NAME DISPLAY)...\n";

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

/// The value of each flag in `names` (from argv[2]), every one required and
/// non-empty, none twice; or the usage outcome that refuses them.
fn flags(alloc: Allocator, argv: []const []const u8, comptime names: []const []const u8) union(enum) { values: [names.len][]const u8, refused: Outcome } {
    var values: [names.len][]const u8 = .{""} ** names.len;
    var seen: [names.len]bool = .{false} ** names.len;
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
        const found: ?usize = inline for (names, 0..) |n, k| {
            if (std.mem.startsWith(u8, name, "--") and std.mem.eql(u8, name[2..], n)) break k;
        } else null;
        const k = found orelse return .{ .refused = usage(alloc, fmt(alloc, "unknown flag {s}", .{name})) };
        if (seen[k]) return .{ .refused = usage(alloc, fmt(alloc, "{s} given twice", .{name})) };
        seen[k] = true;
        values[k] = value;
    }
    inline for (names, 0..) |n, k| {
        if (!seen[k] or values[k].len == 0) return .{ .refused = usage(alloc, "--" ++ n ++ " is required") };
    }
    return .{ .values = values };
}

fn writeFile(dir: std.fs.Dir, path: []const u8, data: []const u8) !void {
    const f = try dir.createFile(path, .{});
    defer f.close();
    try f.writeAll(data);
}

fn generate(alloc: Allocator, dir: std.fs.Dir, argv: []const []const u8) Outcome {
    const v = switch (flags(alloc, argv, &.{ "readme", "display", "package", "links", "out-dir", "examples" })) {
        .values => |v| v,
        .refused => |o| return o,
    };
    const links = v[3];
    if (!std.mem.eql(u8, links, "allow") and !std.mem.eql(u8, links, "refuse")) {
        return usage(alloc, fmt(alloc, "--links is allow or refuse, not {s}", .{links}));
    }
    const text = dir.readFileAlloc(alloc, v[0], std.math.maxInt(usize)) catch |e| {
        return .{ .code = 2, .stdout = fmt(alloc, "readme-examples: cannot read {s}: {s}\n", .{ v[0], @errorName(e) }) };
    };
    const exs = switch (examples.extract(alloc, text, v[1], std.mem.eql(u8, links, "refuse")) catch oom()) {
        .examples => |e| e,
        .refused => |why| return .{ .code = 1, .stdout = fmt(alloc, "{s}\n", .{why}) },
    };
    var why: []const u8 = "";
    const programs = program.generatePrograms(alloc, exs, v[2], v[1], &why) catch |e| switch (e) {
        error.Refused => return .{ .code = 1, .stdout = fmt(alloc, "{s}\n", .{why}) },
        error.OutOfMemory => oom(),
    };
    var lines = std.ArrayList(u8).init(alloc);
    for (exs) |ex| lines.writer().print("{d}\n", .{ex.line}) catch oom();
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

/// Why kci's install validation refuses release member `m` (one line per
/// reason, each naming the member), or null when it holds an example; adds
/// `<name> <examples>` to `passed` then.
fn releaseRefusal(alloc: Allocator, dir: std.fs.Dir, m: Member, passed: *std.ArrayList(u8)) union(enum) { why: ?[]const u8, failed: Outcome } {
    const path = m.readme orelse return .{ .why = fmt(alloc, "release member {s}: no README is packaged, so kci's install validation would refuse it after publish:" ++
        " \"{s} ships no share/doc/{s}/README.md: a release needs a README; add {s}\"", .{ m.name, m.name, m.name, m.display }) };
    const text = switch (readReadme(alloc, dir, path)) {
        .text => |x| x,
        .failed => |o| return .{ .failed = o },
    };
    switch (examples.extract(alloc, text, m.display, true) catch oom()) {
        .refused => |why| {
            var out = std.ArrayList(u8).init(alloc);
            var it = std.mem.splitScalar(u8, why, '\n');
            var first = true;
            while (it.next()) |line| {
                if (!first) out.append('\n') catch oom();
                first = false;
                out.writer().print("release member {s}: kci's install validation would refuse its README after publish: {s}", .{ m.name, line }) catch oom();
            }
            return .{ .why = out.items };
        },
        .examples => |exs| {
            if (exs.len == 0) return .{ .why = fmt(alloc, "release member {s}: {s} holds no ```mojo or ```mojo module example, so kci's install validation would refuse it after publish:" ++
                " \"{s} holds no ```mojo example, so the validation would run nothing; add one\"", .{ m.name, m.display, m.display }) };
            passed.writer().print("{s} {d}\n", .{ m.name, exs.len }) catch oom();
            return .{ .why = null };
        },
    }
}

fn releaseCheck(alloc: Allocator, dir: std.fs.Dir, argv: []const []const u8) Outcome {
    var out: ?[]const u8 = null;
    var expect: ?[]const u8 = null;
    var members = std.ArrayList(Member).init(alloc);
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
        members.append(.{ .name = argv[i + 1], .display = argv[i + 2], .readme = if (n == 3) argv[i + 3] else null }) catch oom();
        i += 1 + n;
    }
    const out_path = out orelse return usage(alloc, "--out is required");
    if (members.items.len == 0) return usage(alloc, "no --member or --no-readme");
    var refusals = std.ArrayList(u8).init(alloc);
    var passed = std.ArrayList(u8).init(alloc);
    for (members.items) |m| {
        switch (releaseRefusal(alloc, dir, m, &passed)) {
            .failed => |o| return o,
            .why => |w| if (w) |why| refusals.writer().print("{s}\n", .{why}) catch oom(),
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

/// What the tool does with `argv`, paths read relative to `dir`.
pub fn run(alloc: Allocator, dir: std.fs.Dir, argv: []const []const u8) Outcome {
    if (argv.len < 2) return usage(alloc, "no subcommand");
    if (std.mem.eql(u8, argv[1], "generate")) return generate(alloc, dir, argv);
    if (std.mem.eql(u8, argv[1], "map")) return map(alloc, dir, argv);
    if (std.mem.eql(u8, argv[1], "link")) return linkCmd(alloc, dir, argv);
    if (std.mem.eql(u8, argv[1], "link-check")) return linkCheck(alloc, dir, argv);
    if (std.mem.eql(u8, argv[1], "release-check")) return releaseCheck(alloc, dir, argv);
    return usage(alloc, fmt(alloc, "unknown subcommand {s}", .{argv[1]}));
}
