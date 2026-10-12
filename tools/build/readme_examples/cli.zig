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
//!
//! A flag is `--name value` or `--name=value`. Everything goes to stdout.
//! Exit status: 0; 1 when the README is refused (each reason on its own line,
//! naming `<display>:<line>`); 2 on bad usage or a file it cannot read or
//! write.

const std = @import("std");
const examples = @import("examples.zig");
const program = @import("program.zig");
const Allocator = std.mem.Allocator;

/// What the process does: its exit status and the bytes it prints (main.zig
/// writes them to stdout and exits, nothing more).
pub const Outcome = struct { code: u8, stdout: []const u8 };

const USAGE = "usage: tool generate --readme F --display NAME --package NAME --links allow|refuse --out-dir D --examples F\n" ++
    "       tool map --package NAME --display NAME --report F\n";

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

/// What the tool does with `argv`, paths read relative to `dir`.
pub fn run(alloc: Allocator, dir: std.fs.Dir, argv: []const []const u8) Outcome {
    if (argv.len < 2) return usage(alloc, "no subcommand");
    if (std.mem.eql(u8, argv[1], "generate")) return generate(alloc, dir, argv);
    if (std.mem.eql(u8, argv[1], "map")) return map(alloc, dir, argv);
    return usage(alloc, fmt(alloc, "unknown subcommand {s}", .{argv[1]}));
}
