//! tests_act's checks over `aws-client-gen`: `aws-gen` generates a module,
//! `aws-refuse` runs the generator on inputs it must refuse, and `aws-cmp`
//! compares a generated module (and, when the generator split it, its parts)
//! with its golden.

const std = @import("std");
const diff = @import("unified_diff");
const proto_checks = @import("proto_checks.zig");
const A = std.mem.Allocator;

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(1);
}

fn writeFile(path: []const u8, data: []const u8) !void {
    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(data);
}

fn exitCode(term: std.process.Child.Term) u32 {
    return switch (term) {
        .Exited => |c| c,
        .Signal => |s| 128 + s,
        else => 255,
    };
}

/// aws-gen <generator> <out dir> <module> <probe 0|1> -- <generator args>...
/// Writes <out dir>/<module>.mojo, and <out dir>/_layout_probe.mojo when <probe> is 1.
pub fn gen(a: A, args: []const []const u8) !void {
    if (args.len < 5 or !std.mem.eql(u8, args[4], "--")) return error.Usage;
    const out = args[1];
    const module = args[2];
    try std.fs.cwd().makePath(out);
    var argv = std.ArrayList([]const u8).empty;
    try argv.appendSlice(a, &.{ args[0], "--module", module, "--out", try std.fmt.allocPrint(a, "{s}/{s}.mojo", .{ out, module }) });
    if (std.mem.eql(u8, args[3], "1")) try argv.appendSlice(a, &.{ "--probe-out", try std.fmt.allocPrint(a, "{s}/_layout_probe.mojo", .{out}) });
    try argv.appendSlice(a, args[5..]);
    var child = std.process.Child.init(argv.items, a);
    const code = exitCode(try child.spawnAndWait());
    if (code != 0) std.process.exit(@intCast(code));
}

/// aws-refuse <generator> <stamp> <message> <probe 0|1> -- <generator args>...
/// The generator must exit non-zero, print <message> on stderr and write no file.
pub fn refuse(a: A, args: []const []const u8) !void {
    if (args.len < 5 or !std.mem.eql(u8, args[4], "--")) return error.Usage;
    const scratch_base = std.process.getEnvVarOwned(a, "BUCK_SCRATCH_PATH") catch try a.dupe(u8, ".komira_aws_codegen");
    const t = try std.fs.path.join(a, &.{ scratch_base, "aws_codegen" });
    const out = try std.fs.path.join(a, &.{ t, "out" });
    try std.fs.cwd().deleteTree(t);
    try std.fs.cwd().makePath(out);
    defer std.fs.cwd().deleteTree(t) catch {};
    var argv = std.ArrayList([]const u8).empty;
    try argv.appendSlice(a, &.{ args[0], "--module", "refused", "--out", try std.fs.path.join(a, &.{ out, "refused.mojo" }) });
    if (std.mem.eql(u8, args[3], "1")) try argv.appendSlice(a, &.{ "--probe-out", try std.fs.path.join(a, &.{ out, "_layout_probe.mojo" }) });
    try argv.appendSlice(a, args[5..]);
    // The probe flag precedes the user's arguments, as the script's `set --` put it.
    const r = try std.process.Child.run(.{ .allocator = a, .argv = argv.items, .max_output_bytes = 1 << 26 });
    const rc = exitCode(r.term);
    if (rc == 0) fail("aws_codegen: expected a refusal, and the generator exited 0", .{});
    if (std.mem.indexOf(u8, r.stderr, args[2]) == null) {
        std.debug.print("aws_codegen: the refusal does not say: {s}\nit said:\n{s}\n", .{ args[2], r.stderr[0..@min(r.stderr.len, 2000)] });
        std.process.exit(1);
    }
    var d = try std.fs.cwd().openDir(out, .{ .iterate = true });
    defer d.close();
    var names = std.ArrayList(u8).empty;
    var it = d.iterate();
    while (try it.next()) |e| {
        if (names.items.len > 0) try names.append(a, ' ');
        try names.appendSlice(a, e.name);
    }
    if (names.items.len > 0) fail("aws_codegen: the generator refused but wrote: {s}", .{names.items});
    try writeFile(args[1], try std.fmt.allocPrint(a, "refused (exit {d}): {s}\n", .{ rc, args[2] }));
}

/// `text` as one line: each line with its leading spaces dropped, followed by \x1e.
pub fn flat(a: A, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        if (lines.peek() == null and l.len == 0) break;
        try out.appendSlice(a, std.mem.trimLeft(u8, l, " "));
        try out.append(a, 0x1e);
    }
    return out.toOwnedSlice(a);
}

/// Whether the generated `module` holds `want` as whole lines, leading spaces
/// removed, a needle matching from the start of a line to the end of a line.
/// The first line of `want` keeps its own leading spaces (as the shell's `printf`
/// put the opening \x1e before it), so a needle that starts with spaces never matches.
pub fn holds(a: A, module: []const u8, want: []const u8) !bool {
    const hay = try std.mem.concat(a, u8, &.{ "\x1e", try flat(a, module) });
    var lines = std.mem.splitScalar(u8, want, '\n');
    var needle = std.ArrayList(u8).empty;
    try needle.append(a, 0x1e);
    var first = true;
    while (lines.next()) |l| {
        if (lines.peek() == null and l.len == 0 and !first) break;
        try needle.appendSlice(a, if (first) l else std.mem.trimLeft(u8, l, " "));
        try needle.append(a, 0x1e);
        first = false;
    }
    return std.mem.indexOf(u8, hay, needle.items) != null;
}

fn head60(a: A, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (lines.next()) |l| {
        if (lines.peek() == null and l.len == 0) break;
        if (n == 60) break;
        try out.writer(a).print("{s}\n", .{l});
        n += 1;
    }
    return out.toOwnedSlice(a);
}

/// The generated module as `must_contain` reads it: the module file (the facade,
/// when the generator split it) and then each part, by name.
fn moduleText(a: A, module_path: []const u8, parts_path: []const u8) ![]u8 {
    const cwd = std.fs.cwd();
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(a, try cwd.readFileAlloc(a, module_path, 1 << 28));
    var parts = cwd.openDir(parts_path, .{ .iterate = true }) catch return out.toOwnedSlice(a);
    defer parts.close();
    var names = std.ArrayList([]const u8).empty;
    var it = parts.iterate();
    while (try it.next()) |e| try names.append(a, try a.dupe(u8, e.name));
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    for (names.items) |n| try out.appendSlice(a, try parts.readFileAlloc(a, n, 1 << 28));
    return out.toOwnedSlice(a);
}

/// aws-cmp <stamp> <gen dir> <module> <golden> <golden probe|-> <golden parts dir|-> [<must contain>...]
///
/// The module, and the probe, are byte for byte their goldens. When the generator
/// split the module (a facade and the files of <gen dir>/_parts), <golden parts
/// dir> holds the parts' goldens, file for file; with `-` the module must not
/// have been split. No generated file reaches the line limit. The must-contain
/// strings are read in the module and its parts together.
pub fn cmp(a: A, args: []const []const u8) !void {
    if (args.len < 6) return error.Usage;
    const cwd = std.fs.cwd();
    var bad = false;
    const module_path = try std.fmt.allocPrint(a, "{s}/{s}.mojo", .{ args[1], args[2] });
    const probe_path = try std.fmt.allocPrint(a, "{s}/_layout_probe.mojo", .{args[1]});
    const parts_path = try std.fmt.allocPrint(a, "{s}/_parts", .{args[1]});
    const pairs = [_][2][]const u8{.{ module_path, args[3] }};
    for (pairs) |p| try check(a, p[0], p[1], &bad);
    if (!std.mem.eql(u8, args[4], "-")) {
        try check(a, probe_path, args[4], &bad);
    } else if (cwd.access(probe_path, .{})) |_| {
        std.debug.print("aws_codegen: a probe was generated and no golden names it\n", .{});
        bad = true;
    } else |_| {}
    const parts_made = if (cwd.access(parts_path, .{})) |_| true else |_| false;
    if (!std.mem.eql(u8, args[5], "-")) {
        if (!parts_made) {
            std.debug.print("aws_codegen: the module was not split, and {s} holds the goldens of its parts\n", .{args[5]});
            bad = true;
        } else {
            var g = try cwd.openDir(args[5], .{ .iterate = true });
            defer g.close();
            var got = try cwd.openDir(parts_path, .{ .iterate = true });
            defer got.close();
            if (try proto_checks.treeDiff(a, g, args[5], got, parts_path)) |d| {
                std.debug.print("aws_codegen: the parts differ from their goldens:\n{s}", .{try head60(a, d)});
                bad = true;
            }
        }
    } else if (parts_made) {
        std.debug.print("aws_codegen: the module was split into parts and no golden names them\n", .{});
        bad = true;
    }
    var gen_dir = try cwd.openDir(args[1], .{ .iterate = true });
    defer gen_dir.close();
    if (try proto_checks.tooLong(a, gen_dir)) |f| {
        std.debug.print("aws_codegen: the generated file {s} reaches {d} lines, the limit of a source file; the generator must split it\n", .{ f, proto_checks.max_lines });
        bad = true;
    }
    const module = try moduleText(a, module_path, parts_path);
    for (args[6..]) |want| {
        if (!try holds(a, module, want)) {
            std.debug.print("aws_codegen: {s}.mojo does not contain:\n{s}\n", .{ args[2], want });
            bad = true;
        }
    }
    if (bad) std.process.exit(1);
    try writeFile(args[0], try std.fmt.allocPrint(a, "equal to the golden, and {d} must_contain held: {s}.mojo\n", .{ args[6..].len, args[2] }));
}

fn check(a: A, generated: []const u8, golden: []const u8, bad: *bool) !void {
    const g = try std.fs.cwd().readFileAlloc(a, generated, 1 << 28);
    const w = try std.fs.cwd().readFileAlloc(a, golden, 1 << 28);
    if (std.mem.eql(u8, g, w)) return;
    std.debug.print("aws_codegen: {s} differs from the golden {s}:\n", .{ generated, golden });
    if (try diff.unifiedDiff(a, golden, generated, w, g)) |d| std.debug.print("{s}", .{try head60(a, d)});
    bad.* = true;
}
