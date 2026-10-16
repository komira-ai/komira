//! tests_act's two diagnostics: what a remote worker provides to an action
//! (`re-probe`), and the loader's own record of what the compiler and a built
//! binary map (`loader-trace`). Both are written as reports; neither is part of
//! any build's verdict beyond the exit status `loader-trace` returns.

const std = @import("std");
const A = std.mem.Allocator;

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The environment variables, `NAME=value`, sorted.
pub fn environment(a: A) ![]u8 {
    var env = try std.process.getEnvMap(a);
    var lines = std.ArrayList([]const u8).init(a);
    var it = env.iterator();
    while (it.next()) |e| try lines.append(try std.fmt.allocPrint(a, "{s}={s}", .{ e.key_ptr.*, e.value_ptr.* }));
    std.mem.sort([]const u8, lines.items, {}, lessThan);
    var out = std.ArrayList(u8).init(a);
    for (lines.items) |l| try out.writer().print("{s}\n", .{l});
    return out.toOwnedSlice();
}

/// The lines of `text` that start with `ID=` or `VERSION_ID=`.
pub fn osRelease(a: A, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        if (std.mem.startsWith(u8, l, "ID=") or std.mem.startsWith(u8, l, "VERSION_ID=")) try out.writer().print("{s}\n", .{l});
    }
    return out.toOwnedSlice();
}

/// `line` without the first ` (0x<hex>)` (the load address `ld.so --list` prints).
pub fn stripAddress(a: A, line: []const u8) ![]u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, " (0x")) |at| {
        var e = at + 4;
        while (e < line.len and std.ascii.isHex(line[e]) and !std.ascii.isUpper(line[e])) e += 1;
        if (e < line.len and line[e] == ')') return std.mem.concat(a, u8, &.{ line[0..at], line[e + 1 ..] });
        from = at + 1;
    }
    return a.dupe(u8, line);
}

pub fn reProbe(a: A, args: []const []const u8) !void {
    if (args.len != 2) return error.Usage;
    const toolchain = args[0];
    var out = std.ArrayList(u8).init(a);
    const w = out.writer();
    try w.writeAll("== inherited environment\n");
    try w.writeAll(try environment(a));
    try w.writeAll("== host paths\n");
    for ([_][]const u8{ "/bin/sh", "/usr/bin/python3", "/usr/bin/zstd", "/usr/bin/unzip", "/usr/bin/xz", "/usr/bin/sed", "/usr/bin/cc" }) |p| {
        const present = if (std.fs.cwd().access(p, .{})) |_| true else |_| false;
        try w.print("{s} {s}\n", .{ if (present) "present" else "absent ", p });
    }
    try w.writeAll("== /etc/os-release\n");
    try w.writeAll(try osRelease(a, std.fs.cwd().readFileAlloc(a, "/etc/os-release", 1 << 20) catch ""));
    try w.writeAll("== dynamic loader view of bin/mojo\n");
    const mojo = try std.fs.path.join(a, &.{ toolchain, "bin/mojo" });
    const r = std.process.Child.run(.{ .allocator = a, .argv = &.{ "/lib64/ld-linux-x86-64.so.2", "--list", mojo }, .max_output_bytes = 1 << 20 }) catch |e| blk: {
        try w.print("loader failed: {s}\n", .{@errorName(e)});
        break :blk null;
    };
    if (r) |res| {
        const text = try std.mem.concat(a, u8, &.{ res.stdout, res.stderr });
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |l| {
            if (lines.peek() == null and l.len == 0) break;
            try w.print("{s}\n", .{try stripAddress(a, l)});
        }
    }
    try w.writeAll("== CLOSURE_MANIFEST\n");
    try w.writeAll(std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ toolchain, "CLOSURE_MANIFEST" }), 1 << 24) catch "");
    try w.print("== nproc {d}\n", .{std.Thread.getCpuCount() catch 1});
    const f = try std.fs.cwd().createFile(args[1], .{});
    defer f.close();
    try f.writeAll(out.items);
}

/// The `<which> init <file>` lines of the `ld.*` records in `dir`, sorted and
/// unique: one per object the loader mapped and initialized, never one it
/// only tried. `strip` (an absolute directory with a trailing slash) is
/// written `<toolchain>/` where it occurs.
pub fn inits(a: A, dir: std.fs.Dir, which: []const u8, strip: []const u8) ![][]const u8 {
    var set = std.StringHashMap(void).init(a);
    var d = dir.openDir(which, .{ .iterate = true }) catch return &.{};
    defer d.close();
    var names = std.ArrayList([]const u8).init(a);
    var it = d.iterate();
    while (try it.next()) |e| {
        if (e.kind == .file and std.mem.startsWith(u8, e.name, "ld.")) try names.append(try a.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    for (names.items) |n| {
        const text = try d.readFileAlloc(a, n, 1 << 28);
        var lines = std.mem.splitScalar(u8, text, '\n');
        const key = "calling init: ";
        while (lines.next()) |l| {
            const at = std.mem.lastIndexOf(u8, l, key) orelse continue;
            var rest = l[at + key.len ..];
            var line: []const u8 = try std.fmt.allocPrint(a, "{s} init {s}", .{ which, rest });
            if (std.mem.indexOf(u8, rest, strip)) |s| {
                rest = try std.mem.concat(a, u8, &.{ rest[0..s], "<toolchain>/", rest[s + strip.len ..] });
                line = try std.fmt.allocPrint(a, "{s} init {s}", .{ which, rest });
            }
            try set.put(line, {});
        }
    }
    var out = std.ArrayList([]const u8).init(a);
    var ki = set.keyIterator();
    while (ki.next()) |k| try out.append(k.*);
    std.mem.sort([]const u8, out.items, {}, lessThan);
    return out.toOwnedSlice();
}

fn exitCode(term: std.process.Child.Term) u32 {
    return switch (term) {
        .Exited => |c| c,
        .Signal => |s| 128 + s,
        else => 255,
    };
}

/// loader-trace <wrapper> <launcher> <toolchain> <zig> <cc target> <cpu> <source> <exe> <report>
pub fn loaderTrace(a: A, args: []const []const u8) !u8 {
    if (args.len != 9) return error.Usage;
    const cwd = std.fs.cwd();
    const d = ".komira_ldtrace";
    try cwd.deleteTree(d);
    try cwd.makePath(d ++ "/compile");
    try cwd.makePath(d ++ "/run");
    const abs = try cwd.realpathAlloc(a, d);
    defer cwd.deleteTree(d) catch {};
    const toolchain = args[2];
    var env = try std.process.getEnvMap(a);
    const wrapper_args = [_][]const u8{
        args[0],                                                                  try std.fmt.allocPrint(a, "--compiler={s}", .{toolchain}),
        try std.fmt.allocPrint(a, "--zig={s}", .{args[3]}),                       try std.fmt.allocPrint(a, "--cc-target={s}", .{args[4]}),
        try std.fmt.allocPrint(a, "--ld-debug-output={s}/compile/ld", .{abs}), "--",
        "build",                                                                  "--target-cpu",
        args[5],                                                                  args[6],
        "-o",                                                                     args[7],
    };
    var child = std.process.Child.init(&wrapper_args, a);
    child.env_map = &env;
    var crc = exitCode(try child.spawnAndWait());
    var rrc: ?u32 = null;
    if (crc == 0) {
        var renv = try std.process.getEnvMap(a);
        try renv.put("LD_DEBUG", "libs");
        try renv.put("LD_DEBUG_OUTPUT", try std.fmt.allocPrint(a, "{s}/run/ld", .{abs}));
        var run = std.process.Child.init(&.{ args[1], "launch", toolchain, args[7] }, a);
        run.env_map = &renv;
        run.stdout_behavior = .Ignore;
        rrc = exitCode(try run.spawnAndWait());
    }
    var report = std.ArrayList(u8).init(a);
    const w = report.writer();
    try w.print("compile rc={d}\n", .{crc});
    if (rrc) |r| try w.print("run rc={d}\n", .{r}) else try w.writeAll("run rc=-\n");
    var root = try cwd.openDir(d, .{ .iterate = true });
    defer root.close();
    const here = try cwd.realpathAlloc(a, ".");
    const strip = try std.fmt.allocPrint(a, "{s}/{s}/", .{ here, toolchain });
    for ([_][]const u8{ "compile", "run" }) |which| {
        for (try inits(a, root, which, strip)) |l| try w.print("{s}\n", .{l});
    }
    const f = try cwd.createFile(args[8], .{});
    defer f.close();
    try f.writeAll(report.items);
    crc = if (crc == 0 and rrc != null and rrc.? == 0) 0 else 1;
    return @intCast(crc);
}
