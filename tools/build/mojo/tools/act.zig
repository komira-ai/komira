// Why Zig: build tools are Zig (tools/build/README.md). act replaces
// run_check.sh and the busybox `cp` and `cat` applets in the Mojo and Rust
// rules, so those actions run no shell.
//! act: the small actions the Mojo and Rust rules run.
//!
//!   act copy <src> <dst>
//!       Copies the file <src> to <dst>, keeping its mode: publishes a package
//!       or an executable once the markers that are hidden inputs of the
//!       action exist (the gate's join).
//!   act cat <out> <in>...
//!       Writes the concatenation of the files <in> to <out> (the README
//!       join's marker).
//!   act run-check <busybox> <binary> <out> [<expected>]
//!       Runs <binary> (the binary inside its runnable directory, next to
//!       lib/) with the busybox applets as PATH, a TMPDIR and HOME of its own,
//!       no library path (LD_LIBRARY_PATH, LD_PRELOAD and the DYLD_ variables
//!       are cleared, so a binary that cannot find its runtime libraries
//!       through its own run path fails here, as under `buck2 run`), stdin
//!       empty, and writes its standard output to <out>. Exit 1 when the
//!       binary exits non-zero (the last 100 lines of its stderr are shown) or,
//!       with <expected>, when its stdout is not that file byte for byte.
//!
//! Exit status: 0; 1 for a failed check; 2 for a usage error or a failure of
//! the tool's own.

const std = @import("std");

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("act: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

/// What the program exits with when a child ended as `term`: the child's own
/// status, 128 + N for signal N (a shell's), 1 for anything else.
pub fn exitCodeOf(term: std.process.Child.Term) u8 {
    return switch (term) {
        .Exited => |c| c,
        .Signal => |s| @truncate(128 +% s),
        else => 1,
    };
}

/// The last `n` lines of `text` (as `tail -n`): a final line without a
/// newline counts, and the text's own final newline ends its last line.
pub fn lastLines(text: []const u8, n: usize) []const u8 {
    if (n == 0 or text.len == 0) return text[text.len..];
    var end = text.len;
    if (text[end - 1] == '\n') end -= 1;
    var start = end;
    var seen: usize = 0;
    while (start > 0) {
        if (text[start - 1] == '\n') {
            seen += 1;
            if (seen == n) break;
        }
        start -= 1;
    }
    return text[start..];
}

/// The environment run-check gives the binary: `base` without the library
/// path variables, with `path`, `tmp` and `home` set.
pub fn cleanEnv(a: std.mem.Allocator, base: std.process.EnvMap, path: []const u8, tmp: []const u8, home: []const u8) !std.process.EnvMap {
    var env = std.process.EnvMap.init(a);
    var it = base.iterator();
    while (it.next()) |e| try env.put(e.key_ptr.*, e.value_ptr.*);
    for (cleared) |v| env.remove(v);
    try env.put("PATH", path);
    try env.put("TMPDIR", tmp);
    try env.put("HOME", home);
    return env;
}

pub const cleared = [_][]const u8{ "LD_LIBRARY_PATH", "LD_PRELOAD", "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES" };

fn abs(a: std.mem.Allocator, cwd: []const u8, p: []const u8) ![]u8 {
    return if (std.fs.path.isAbsolute(p)) a.dupe(u8, p) else std.fs.path.join(a, &.{ cwd, p });
}

fn copy(args: []const []const u8) void {
    if (args.len != 2) die("usage: act copy <src> <dst>", .{});
    const st = std.fs.cwd().statFile(args[0]) catch |e| die("cannot read {s}: {s}", .{ args[0], @errorName(e) });
    if (st.kind == .directory) die("{s} is a directory", .{args[0]});
    std.fs.cwd().copyFile(args[0], std.fs.cwd(), args[1], .{}) catch |e| die("cannot copy {s} to {s}: {s}", .{ args[0], args[1], @errorName(e) });
}

fn cat(a: std.mem.Allocator, args: []const []const u8) void {
    if (args.len < 1) die("usage: act cat <out> <in>...", .{});
    const out = std.fs.cwd().createFile(args[0], .{}) catch |e| die("cannot create {s}: {s}", .{ args[0], @errorName(e) });
    defer out.close();
    for (args[1..]) |p| {
        const data = std.fs.cwd().readFileAlloc(a, p, 1 << 28) catch |e| die("cannot read {s}: {s}", .{ p, @errorName(e) });
        out.writeAll(data) catch |e| die("cannot write {s}: {s}", .{ args[0], @errorName(e) });
    }
}

fn runCheck(a: std.mem.Allocator, args: []const []const u8) u8 {
    if (args.len < 3 or args.len > 4) die("usage: act run-check <busybox> <binary> <out> [<expected>]", .{});
    const cwd = std.fs.cwd().realpathAlloc(a, ".") catch |e| die("cannot resolve the working directory: {s}", .{@errorName(e)});
    const bb = abs(a, cwd, args[0]) catch die("out of memory", .{});
    const bin = abs(a, cwd, args[1]) catch die("out of memory", .{});
    const out_path = args[2];

    var rnd: [4]u8 = undefined;
    std.crypto.random.bytes(&rnd);
    const hex = std.fmt.bytesToHex(rnd, .lower);
    const t = std.fmt.allocPrint(a, "{s}/.komira_run.{s}", .{ cwd, &hex }) catch die("out of memory", .{});
    const bin_dir = std.fs.path.join(a, &.{ t, "bin" }) catch die("out of memory", .{});
    const tmp = std.fs.path.join(a, &.{ t, "tmp" }) catch die("out of memory", .{});
    const home = std.fs.path.join(a, &.{ t, "home" }) catch die("out of memory", .{});
    for ([_][]const u8{ bin_dir, tmp, home }) |d| std.fs.cwd().makePath(d) catch |e| die("cannot create {s}: {s}", .{ d, @errorName(e) });
    defer std.fs.cwd().deleteTree(t) catch {};

    const base = std.process.getEnvMap(a) catch die("cannot read the environment", .{});
    var install = std.process.Child.init(&.{ bb, "--install", "-s", bin_dir }, a);
    install.env_map = &base;
    const installed = install.spawnAndWait() catch |e| die("cannot run {s}: {s}", .{ bb, @errorName(e) });
    if (exitCodeOf(installed) != 0) die("{s} --install -s {s} failed", .{ bb, bin_dir });

    const env = cleanEnv(a, base, bin_dir, tmp, home) catch die("out of memory", .{});
    var child = std.process.Child.init(&.{bin}, a);
    child.env_map = &env;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.spawn() catch |e| {
        std.debug.print("run_check: {s} cannot start: {s}\n", .{ args[1], @errorName(e) });
        return 1;
    };
    var out_buf = std.ArrayList(u8).init(a);
    var err_buf = std.ArrayList(u8).init(a);
    child.collectOutput(&out_buf, &err_buf, 1 << 28) catch |e| die("cannot read the output of {s}: {s}", .{ bin, @errorName(e) });
    // (A binary that cannot be executed is reported by wait, not by spawn.)
    const term = child.wait() catch |e| {
        std.debug.print("run_check: {s} cannot start: {s}\n", .{ args[1], @errorName(e) });
        return 1;
    };
    const rc = exitCodeOf(term);

    const out = std.fs.cwd().createFile(out_path, .{}) catch |e| die("cannot create {s}: {s}", .{ out_path, @errorName(e) });
    defer out.close();
    out.writeAll(out_buf.items) catch |e| die("cannot write {s}: {s}", .{ out_path, @errorName(e) });

    if (rc != 0) {
        std.debug.print("run_check: {s} exited {d}\n{s}", .{ args[1], rc, lastLines(err_buf.items, 100) });
        if (err_buf.items.len > 0 and err_buf.items[err_buf.items.len - 1] != '\n') std.debug.print("\n", .{});
        return 1;
    }
    if (args.len == 4) {
        const want = std.fs.cwd().readFileAlloc(a, args[3], 1 << 28) catch |e| die("cannot read {s}: {s}", .{ args[3], @errorName(e) });
        if (!std.mem.eql(u8, want, out_buf.items)) {
            std.debug.print("run_check: stdout of {s} differs from {s}\n--- expected\n{s}--- actual\n{s}", .{ args[1], args[3], want, out_buf.items });
            return 1;
        }
    }
    return 0;
}

pub fn main() void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = std.process.argsAlloc(a) catch die("out of memory", .{});
    if (argv.len < 2) die("usage: act (copy|cat|run-check) ...", .{});
    const sub = argv[1];
    if (std.mem.eql(u8, sub, "copy")) {
        copy(argv[2..]);
    } else if (std.mem.eql(u8, sub, "cat")) {
        cat(a, argv[2..]);
    } else if (std.mem.eql(u8, sub, "run-check")) {
        const rc = runCheck(a, argv[2..]);
        if (rc != 0) std.process.exit(rc);
    } else die("unknown subcommand {s}", .{sub});
}
