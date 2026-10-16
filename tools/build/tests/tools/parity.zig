//! tests_act's `bundle-parity`: one program built two ways (an executable with its
//! run path, and a bundle) run through the same cases, with stdout, stderr and the
//! exit status compared.
//!
//! usage: tests_act bundle-parity <runnable dir> <binary> <bundle> <out>
//!
//! E/ is the executable: E/bin/<binary> with E/bin/lib/ (its run path), and the
//! bundle's share/ copied next to it. B/ is a copy of the bundle. Each case runs
//! `bin/<binary> ...` (or the symlink PROG to it) from the tree's root, with only
//! the environment the case sets, stdin from /dev/null, stdout and stderr to
//! files. Exit 1 when any case differs in stdout, stderr or exit status.

const std = @import("std");
const A = std.mem.Allocator;

pub const Cmp = enum { exact, signal };

pub const Case = struct {
    name: []const u8,
    env: []const [2][]const u8 = &.{},
    args: []const []const u8 = &.{},
    cmp: Cmp = .exact,
    /// The program, when not `bin/<binary>`.
    prog: ?[]const u8 = null,
};

pub const cases = [_]Case{
    .{ .name = "no-args" },
    .{ .name = "args", .args = &.{ "args", "two words", "", "ünï✓", "--flag=x" } },
    .{ .name = "env", .env = &.{.{ "KOMIRA_PROBE_ENV", "hello-env" }}, .args = &.{"env"} },
    .{ .name = "env-unset", .args = &.{"env"} },
    .{ .name = "exit3", .args = &.{"exit3"} },
    .{ .name = "raise", .args = &.{"raise"} },
    .{ .name = "buffered", .args = &.{"buffered"} },
    .{ .name = "data", .args = &.{"data"} },
    .{ .name = "unknown", .args = &.{"nosuchmode"} },
    .{ .name = "abort", .args = &.{"abort"}, .cmp = .signal },
    .{ .name = "segv", .args = &.{"segv"}, .cmp = .signal },
    .{ .name = "argv0-symlink", .args = &.{ "args", "one" }, .prog = "links/other-name" },
    .{ .name = "data-through-symlink", .args = &.{"data"}, .prog = "links/other-name" },
};

pub const Run = struct { rc: u32, out: []const u8, err: []const u8 };

/// `text` cut to `n` bytes with its newlines written `|` (`head -c n | tr '\n' '|'`).
pub fn flatten(a: A, text: []const u8, n: usize) ![]u8 {
    const cut = try a.dupe(u8, text[0..@min(n, text.len)]);
    for (cut) |*c| {
        if (c.* == '\n') c.* = '|';
    }
    return cut;
}

fn firstLine(s: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, s, '\n')) |i| s[0..i] else s;
}

/// What differs between the runs in E and B, as the report's words (empty: nothing).
pub fn differences(a: A, e: Run, b: Run, mode: Cmp) ![]u8 {
    var what = std.ArrayList(u8).init(a);
    if (!std.mem.eql(u8, e.out, b.out)) try what.appendSlice(" stdout");
    switch (mode) {
        // A fatal signal prints the runtime's stack dump: raw addresses (ASLR,
        // different on every run) and module names (probe vs libprobe.so), so
        // only its first line is compared. Status and stdout stay exact.
        .signal => if (!(std.mem.eql(u8, firstLine(e.err), firstLine(b.err)) and e.err.len > 0)) try what.appendSlice(" stderr-first-line"),
        .exact => if (!std.mem.eql(u8, e.err, b.err)) try what.appendSlice(" stderr"),
    }
    if (e.rc != b.rc) try what.writer().print(" exit({d} vs {d})", .{ e.rc, b.rc });
    return what.toOwnedSlice();
}

fn copyTree(a: A, src: std.fs.Dir, dest: std.fs.Dir) !void {
    var w = try src.walk(a);
    while (try w.next()) |e| {
        switch (e.kind) {
            .directory => try dest.makePath(e.path),
            .file => {
                if (std.fs.path.dirname(e.path)) |d| try dest.makePath(d);
                const st = try src.statFile(e.path);
                const mode: std.fs.File.Mode = if (st.mode & 0o111 != 0) 0o755 else 0o644;
                const data = try src.readFileAlloc(a, e.path, 1 << 30);
                const f = try dest.createFile(e.path, .{ .mode = mode });
                defer f.close();
                try f.writeAll(data);
                try f.chmod(mode);
            },
            .sym_link => {
                if (std.fs.path.dirname(e.path)) |d| try dest.makePath(d);
                var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
                try dest.symLink(try src.readLink(e.path, &buf), e.path, .{});
            },
            else => {},
        }
    }
}

fn runCase(a: A, tree: []const u8, program: []const u8, c: Case) !Run {
    var env = std.process.EnvMap.init(a);
    for (c.env) |kv| try env.put(kv[0], kv[1]);
    var argv = std.ArrayList([]const u8).init(a);
    try argv.append(program);
    try argv.appendSlice(c.args);
    var child = std.process.Child.init(argv.items, a);
    child.cwd = tree;
    child.env_map = &env;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    var out = std.ArrayList(u8).init(a);
    var err = std.ArrayList(u8).init(a);
    try child.collectOutput(&out, &err, 1 << 26);
    const term = try child.wait();
    const rc: u32 = switch (term) {
        .Exited => |x| x,
        .Signal => |s| 128 + s,
        else => 255,
    };
    return .{ .rc = rc, .out = out.items, .err = err.items };
}

pub fn parity(a: A, args: []const []const u8) !u8 {
    if (args.len != 4) return error.Usage;
    const cwd = std.fs.cwd();
    const t0 = ".komira_parity";
    try cwd.deleteTree(t0);
    try cwd.makePath(t0 ++ "/E/bin");
    try cwd.makePath(t0 ++ "/B");
    defer cwd.deleteTree(t0) catch {};
    const t = try cwd.realpathAlloc(a, t0);
    const bin = args[1];
    {
        var src = try cwd.openDir(args[0], .{ .iterate = true });
        defer src.close();
        var dest = try cwd.openDir(t0 ++ "/E/bin", .{});
        defer dest.close();
        try copyTree(a, src, dest);
    }
    {
        var src = try cwd.openDir(try std.fs.path.join(a, &.{ args[2], "share" }), .{ .iterate = true });
        defer src.close();
        try cwd.makePath(t0 ++ "/E/share");
        var dest = try cwd.openDir(t0 ++ "/E/share", .{});
        defer dest.close();
        try copyTree(a, src, dest);
    }
    {
        var src = try cwd.openDir(args[2], .{ .iterate = true });
        defer src.close();
        var dest = try cwd.openDir(t0 ++ "/B", .{});
        defer dest.close();
        try copyTree(a, src, dest);
    }
    // argv[0] other than bin/<name>: a symlink with another name in another directory.
    for ([_][]const u8{ "E", "B" }) |tree| {
        const links = try std.fmt.allocPrint(a, "{s}/{s}/links", .{ t, tree });
        try cwd.makePath(links);
        const target = try std.fmt.allocPrint(a, "../bin/{s}", .{bin});
        try std.fs.cwd().symLink(target, try std.fmt.allocPrint(a, "{s}/other-name", .{links}), .{});
    }
    var report = std.ArrayList(u8).init(a);
    const w = report.writer();
    var bad: usize = 0;
    for (cases) |c| {
        const program = c.prog orelse try std.fmt.allocPrint(a, "bin/{s}", .{bin});
        const e = try runCase(a, try std.fs.path.join(a, &.{ t, "E" }), program, c);
        const b = try runCase(a, try std.fs.path.join(a, &.{ t, "B" }), program, c);
        const what = try differences(a, e, b, c.cmp);
        if (what.len > 0) {
            bad += 1;
            try w.print("DIFF {s}:{s}\n", .{ c.name, what });
            for ([_]struct { n: []const u8, r: Run }{ .{ .n = "E", .r = e }, .{ .n = "B", .r = b } }) |x|
                try w.print("  {s} rc={d} out={s} err={s}\n", .{ x.n, x.r.rc, try flatten(a, x.r.out, 300), try flatten(a, x.r.err, 300) });
        } else {
            try w.print("SAME {s}: rc={d} stdout {d}B stderr {d}B {s}\n", .{ c.name, e.rc, e.out.len, e.err.len, try flatten(a, e.err, 120) });
        }
    }
    try w.print("{d} cases, {d} differ\n", .{ cases.len, bad });
    const f = try cwd.createFile(args[3], .{});
    defer f.close();
    try f.writeAll(report.items);
    std.debug.print("{s}", .{report.items});
    return if (bad == 0) 0 else 1;
}
