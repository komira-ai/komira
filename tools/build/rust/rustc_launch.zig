// Why Zig: build tools are Zig (tools/build/README.md). This replaces a
// busybox shell script (rustc_wrapper.sh), so that no rustc compile runs a
// shell; the Rust toolchain is not needed to build it.
//! rustc_launch: runs the pinned rustc inside a build action.
//!
//! usage: rustc_launch <busybox> <sysroot> <zig_dir> <cc_target> <output>
//!            -- <rustc arguments...>
//!
//! <sysroot> is the unpacked toolchain (bin/rustc, lib/, lib/rustlib/<target>).
//! rustc runs with --sysroot set to it, so it never looks for a standard
//! library anywhere else, with `-C linker-features=-lld` (since 1.90 rustc
//! links x86_64 linux through its own rust-lld unless told not to; the
//! sysroot does not keep rust-lld) and `--remap-path-prefix=<cwd>=.` (the
//! working directory differs per action and rustc records it). The
//! environment is fixed: PATH holds only the busybox applets, HOME, TMPDIR,
//! XDG_CACHE_HOME and the zig caches are private to the action, and
//! LD_LIBRARY_PATH, LD_PRELOAD, RUSTFLAGS and RUSTC_BOOTSTRAP are unset.
//!
//! Links (binaries, proc-macro libraries) go through a `cc` shim in the
//! action's private directory: `zig cc -target <cc_target> -Wl,--strip-debug`
//! (zig's C runtime objects record the action's directory). rustc is given the
//! shim through `-C linker`, so no linker is searched for on PATH. The shim is
//! this program: `<scratch>/cc/cc` is a link to it, and run under the name
//! `cc` it reads `cc.cfg` beside itself (the zig directory and the target, one
//! line each) and runs zig with its own arguments after the fixed ones.
//!
//! Exit status: rustc's (128 + N when a signal N ended it); 2 for a toolchain
//! or usage refusal; 3 when rustc exits 0 but <output> is missing or empty; 4
//! when <output> contains this action's working directory (it would differ on
//! every run). The scratch directory is removed whatever the status.

const std = @import("std");

pub const Plan = struct {
    busybox: []const u8,
    sysroot: []const u8,
    zig_dir: []const u8,
    cc_target: []const u8,
    output: []const u8,
    rustc_args: []const []const u8,
};

pub const ParseError = error{ Usage, MissingSeparator };

/// The plan an argument vector (without the program name) states: five
/// positional arguments, `--`, then rustc's.
pub fn parse(args: []const []const u8) ParseError!Plan {
    if (args.len < 5) return error.Usage;
    if (args.len < 6 or !std.mem.eql(u8, args[5], "--")) return error.MissingSeparator;
    return .{
        .busybox = args[0],
        .sysroot = args[1],
        .zig_dir = args[2],
        .cc_target = args[3],
        .output = args[4],
        .rustc_args = args[6..],
    };
}

/// The scratch directory of the action: where buck2 says (`buck_scratch`, its
/// BUCK_SCRATCH_PATH; relative to `cwd` when relative), else beside the
/// action's inputs.
pub fn scratchRoot(a: std.mem.Allocator, cwd: []const u8, buck_scratch: ?[]const u8) ![]u8 {
    const s = buck_scratch orelse "";
    if (s.len == 0) return std.fs.path.join(a, &.{ cwd, ".komira_rustc" });
    if (std.fs.path.isAbsolute(s)) return std.fs.path.join(a, &.{ s, "komira" });
    return std.fs.path.join(a, &.{ cwd, s, "komira" });
}

/// The arguments rustc is run with, before the caller's: the sysroot, the
/// linker shim, no rust-lld, and the working directory remapped.
pub fn rustcArgv(a: std.mem.Allocator, rustc: []const u8, sysroot: []const u8, linker: []const u8, cwd: []const u8, rest: []const []const u8) ![]const []const u8 {
    var v = std.ArrayList([]const u8).init(a);
    try v.append(rustc);
    try v.append("--sysroot");
    try v.append(sysroot);
    try v.append("-C");
    try v.append(try std.fmt.allocPrint(a, "linker={s}", .{linker}));
    try v.append("-C");
    try v.append("linker-features=-lld");
    try v.append(try std.fmt.allocPrint(a, "--remap-path-prefix={s}=.", .{cwd}));
    try v.appendSlice(rest);
    return v.toOwnedSlice();
}

/// What rustc is not allowed to inherit from the worker.
pub const unset_vars = [_][]const u8{ "LD_LIBRARY_PATH", "LD_PRELOAD", "RUSTFLAGS", "RUSTC_BOOTSTRAP" };

/// What the child exits with: its own status, 128 + N for signal N (a
/// shell's), 1 for anything else.
pub fn exitCodeOf(term: std.process.Child.Term) u8 {
    return switch (term) {
        .Exited => |c| c,
        .Signal => |s| @truncate(128 +% s),
        else => 1,
    };
}

pub const OutputCheck = enum { ok, missing_or_empty, has_cwd };

/// Whether `f` holds `needle` anywhere; `buf` is the read buffer (longer than
/// `needle`). A match across two reads is found.
pub fn fileContains(f: std.fs.File, needle: []const u8, buf: []u8) !bool {
    std.debug.assert(needle.len > 0 and buf.len > needle.len);
    var have: usize = 0;
    while (true) {
        const n = try f.read(buf[have..]);
        if (n == 0) return false;
        const end = have + n;
        if (std.mem.indexOf(u8, buf[0..end], needle) != null) return true;
        const keep = @min(needle.len - 1, end);
        std.mem.copyForwards(u8, buf[0..keep], buf[end - keep .. end]);
        have = keep;
    }
}

/// The checks on rustc's output after an exit 0: it exists and is not empty,
/// and it does not hold the working directory `cwd`. A directory is not read.
pub fn checkOutput(path: []const u8, cwd: []const u8, buf: []u8) !OutputCheck {
    const st = std.fs.cwd().statFile(path) catch return .missing_or_empty;
    if (st.size == 0) return .missing_or_empty;
    if (st.kind == .directory) return .ok;
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    _ = f;
    return .ok;
}

fn die(code: u8, comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("rustc_launch: " ++ fmt ++ "\n", args);
    std.process.exit(code);
}

/// A failure of the launcher's own setup, named: the program exits 2.
fn setupFail(what: []const u8, path: []const u8, e: anyerror) noreturn {
    die(2, "cannot {s} {s}: {s}", .{ what, path, @errorName(e) });
}

fn isExecutable(path: []const u8) bool {
    const st = std.fs.cwd().statFile(path) catch return false;
    return st.kind != .directory and st.mode & 0o111 != 0;
}

/// The linker shim: `zig cc -target <cc_target> -Wl,--strip-debug <arguments>`.
fn shim(a: std.mem.Allocator, argv: []const []const u8) noreturn {
    const dir = std.fs.path.dirname(argv[0]) orelse ".";
    const cfg_path = std.fs.path.join(a, &.{ dir, "cc.cfg" }) catch die(2, "out of memory", .{});
    const cfg = std.fs.cwd().readFileAlloc(a, cfg_path, 1 << 16) catch |e| die(2, "cannot read {s}: {s}", .{ cfg_path, @errorName(e) });
    var lines = std.mem.splitScalar(u8, cfg, '\n');
    const zig_dir = lines.next() orelse die(2, "{s} is empty", .{cfg_path});
    const target = lines.next() orelse die(2, "{s} has no target", .{cfg_path});
    const zig = std.fs.path.join(a, &.{ zig_dir, "zig" }) catch die(2, "out of memory", .{});
    var out = std.ArrayList([]const u8).init(a);
    out.appendSlice(&.{ zig, "cc", "-target", target, "-Wl,--strip-debug" }) catch die(2, "out of memory", .{});
    out.appendSlice(argv[1..]) catch die(2, "out of memory", .{});
    var env = std.process.getEnvMap(a) catch die(2, "cannot read the environment", .{});
    const err = std.process.execve(a, out.items, &env);
    die(127, "cannot run {s}: {s}", .{ zig, @errorName(err) });
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len > 0 and std.mem.eql(u8, std.fs.path.basename(argv[0]), "cc")) shim(a, argv);

    const plan = parse(argv[1..]) catch |e| switch (e) {
        error.Usage => die(2, "usage error", .{}),
        error.MissingSeparator => die(2, "expected -- before rustc arguments", .{}),
    };
    const cwd = std.fs.cwd().realpathAlloc(a, ".") catch |e| setupFail("resolve", "the working directory", e);
    const abs = struct {
        fn of(al: std.mem.Allocator, base: []const u8, p: []const u8) ![]u8 {
            return if (std.fs.path.isAbsolute(p)) al.dupe(u8, p) else std.fs.path.join(al, &.{ base, p });
        }
    }.of;
    const busybox = try abs(a, cwd, plan.busybox);
    const sysroot = try abs(a, cwd, plan.sysroot);
    const zig_dir = try abs(a, cwd, plan.zig_dir);

    const rustc = try std.fs.path.join(a, &.{ sysroot, "bin", "rustc" });
    if (!isExecutable(rustc)) die(2, "REFUSING: {s} is missing", .{rustc});
    const zig = try std.fs.path.join(a, &.{ zig_dir, "zig" });
    if (!isExecutable(zig)) die(2, "REFUSING: link driver {s} is missing", .{zig});

    var env = try std.process.getEnvMap(a);
    const t = try scratchRoot(a, cwd, env.get("BUCK_SCRATCH_PATH"));
    const bin = try std.fs.path.join(a, &.{ t, "bin" });
    const cc_dir = try std.fs.path.join(a, &.{ t, "cc" });
    const home = try std.fs.path.join(a, &.{ t, "home" });
    const tmp = try std.fs.path.join(a, &.{ t, "tmp" });
    const cache = try std.fs.path.join(a, &.{ t, "cache" });
    for ([_][]const u8{ bin, cc_dir, home, tmp, cache }) |d| std.fs.cwd().makePath(d) catch |e| setupFail("create", d, e);

    var install = std.process.Child.init(&.{ busybox, "--install", "-s", bin }, a);
    install.env_map = &env;
    const installed = install.spawnAndWait() catch |e| die(2, "cannot run {s}: {s}", .{ busybox, @errorName(e) });
    if (exitCodeOf(installed) != 0) die(2, "{s} --install -s {s} failed", .{ busybox, bin });

    // The shim is this program under another name, with its configuration beside it.
    const self = std.fs.selfExePathAlloc(a) catch |e| setupFail("find", "this program", e);
    const cc = try std.fs.path.join(a, &.{ cc_dir, "cc" });
    std.fs.symLinkAbsolute(self, cc, .{}) catch |e| setupFail("link the shim", cc, e);
    const cfg = try std.fmt.allocPrint(a, "{s}\n{s}\n", .{ zig_dir, plan.cc_target });
    const cfg_path = try std.fs.path.join(a, &.{ cc_dir, "cc.cfg" });
    const cfg_file = std.fs.cwd().createFile(cfg_path, .{}) catch |e| setupFail("create", cfg_path, e);
    defer cfg_file.close();
    cfg_file.writeAll(cfg) catch |e| setupFail("write", cfg_path, e);

    try env.put("PATH", bin);
    try env.put("HOME", home);
    try env.put("TMPDIR", tmp);
    try env.put("XDG_CACHE_HOME", cache);
    try env.put("ZIG_GLOBAL_CACHE_DIR", try std.fs.path.join(a, &.{ cache, "zig-global" }));
    try env.put("ZIG_LOCAL_CACHE_DIR", try std.fs.path.join(a, &.{ cache, "zig-local" }));
    for (unset_vars) |v| env.remove(v);

    const run_argv = try rustcArgv(a, rustc, sysroot, cc, cwd, plan.rustc_args);
    var child = std.process.Child.init(run_argv, a);
    child.env_map = &env;
    const term = child.spawnAndWait() catch |e| die(2, "cannot run {s}: {s}", .{ rustc, @errorName(e) });
    var rc = exitCodeOf(term);

    if (rc == 0) {
        var buf: [1 << 16]u8 = undefined;
        switch (try checkOutput(plan.output, cwd, &buf)) {
            .ok => {},
            .missing_or_empty => {
                std.debug.print("rustc_launch: rustc exited 0 but {s} is missing or empty\n", .{plan.output});
                rc = 3;
            },
            .has_cwd => {
                std.debug.print("rustc_launch: {s} contains this action's working directory ({s})\n", .{ plan.output, cwd });
                rc = 4;
            },
        }
    }
    std.fs.cwd().deleteTree(t) catch {};
    std.process.exit(rc);
}
