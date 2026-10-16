//! tests_act's checks over `aws-client-gen`: `aws-gen` generates a module,
//! `aws-refuse` runs the generator on inputs it must refuse, and `aws-cmp`
//! compares a generated module with its golden.

const std = @import("std");
const diff = @import("unified_diff");
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
    var argv = std.ArrayList([]const u8).init(a);
    try argv.appendSlice(&.{ args[0], "--module", module, "--out", try std.fmt.allocPrint(a, "{s}/{s}.mojo", .{ out, module }) });
    if (std.mem.eql(u8, args[3], "1")) try argv.appendSlice(&.{ "--probe-out", try std.fmt.allocPrint(a, "{s}/_layout_probe.mojo", .{out}) });
    try argv.appendSlice(args[5..]);
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
    var argv = std.ArrayList([]const u8).init(a);
    try argv.appendSlice(&.{ args[0], "--module", "refused", "--out", try std.fs.path.join(a, &.{ out, "refused.mojo" }) });
    if (std.mem.eql(u8, args[3], "1")) try argv.appendSlice(&.{ "--probe-out", try std.fs.path.join(a, &.{ out, "_layout_probe.mojo" }) });
    try argv.appendSlice(args[5..]);
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
    var names = std.ArrayList(u8).init(a);
    var it = d.iterate();
    while (try it.next()) |e| {
        if (names.items.len > 0) try names.append(' ');
        try names.appendSlice(e.name);
    }
    if (names.items.len > 0) fail("aws_codegen: the generator refused but wrote: {s}", .{names.items});
    try writeFile(args[1], try std.fmt.allocPrint(a, "refused (exit {d}): {s}\n", .{ rc, args[2] }));
}

/// `text` as one line: each line with its leading spaces dropped, followed by \x1e.
pub fn flat(a: A, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        if (lines.peek() == null and l.len == 0) break;
        try out.appendSlice(std.mem.trimLeft(u8, l, " "));
        try out.append(0x1e);
    }
    return out.toOwnedSlice();
}

/// Whether the generated `module` holds `want` as whole lines, leading spaces
/// removed, a needle matching from the start of a line to the end of a line.
/// The first line of `want` keeps its own leading spaces (as the shell's `printf`
/// put the opening \x1e before it), so a needle that starts with spaces never matches.
pub fn holds(a: A, module: []const u8, want: []const u8) !bool {
    const hay = try std.mem.concat(a, u8, &.{ "\x1e", try flat(a, module) });
    var lines = std.mem.splitScalar(u8, want, '\n');
    var needle = std.ArrayList(u8).init(a);
    try needle.append(0x1e);
    var first = true;
    while (lines.next()) |l| {
        if (lines.peek() == null and l.len == 0 and !first) break;
        try needle.appendSlice(if (first) l else std.mem.trimLeft(u8, l, " "));
        try needle.append(0x1e);
        first = false;
    }
    return std.mem.indexOf(u8, hay, needle.items) != null;
}

fn head60(a: A, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (lines.next()) |l| {
        if (lines.peek() == null and l.len == 0) break;
        if (n == 60) break;
        try out.writer().print("{s}\n", .{l});
        n += 1;
    }
    return out.toOwnedSlice();
}

/// aws-cmp <stamp> <gen dir> <module> <golden> <golden probe|-> [<must contain>...]
pub fn cmp(a: A, args: []const []const u8) !void {
    if (args.len < 5) return error.Usage;
    const cwd = std.fs.cwd();
    var bad = false;
    const module_path = try std.fmt.allocPrint(a, "{s}/{s}.mojo", .{ args[1], args[2] });
    const probe_path = try std.fmt.allocPrint(a, "{s}/_layout_probe.mojo", .{args[1]});
    const pairs = [_][2][]const u8{.{ module_path, args[3] }};
    for (pairs) |p| try check(a, p[0], p[1], &bad);
    if (!std.mem.eql(u8, args[4], "-")) {
        try check(a, probe_path, args[4], &bad);
    } else if (cwd.access(probe_path, .{})) |_| {
        std.debug.print("aws_codegen: a probe was generated and no golden names it\n", .{});
        bad = true;
    } else |_| {}
    const module = try cwd.readFileAlloc(a, module_path, 1 << 28);
    for (args[5..]) |want| {
        if (!try holds(a, module, want)) {
            std.debug.print("aws_codegen: {s}.mojo does not contain:\n{s}\n", .{ args[2], want });
            bad = true;
        }
    }
    if (bad) std.process.exit(1);
    try writeFile(args[0], try std.fmt.allocPrint(a, "equal to the golden, and {d} must_contain held: {s}.mojo\n", .{ args[5..].len, args[2] }));
}

fn check(a: A, generated: []const u8, golden: []const u8, bad: *bool) !void {
    const g = try std.fs.cwd().readFileAlloc(a, generated, 1 << 28);
    const w = try std.fs.cwd().readFileAlloc(a, golden, 1 << 28);
    if (std.mem.eql(u8, g, w)) return;
    std.debug.print("aws_codegen: {s} differs from the golden {s}:\n", .{ generated, golden });
    if (try diff.unifiedDiff(a, golden, generated, w, g)) |d| std.debug.print("{s}", .{try head60(a, d)});
    bad.* = true;
}
