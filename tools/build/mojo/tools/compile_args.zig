//! compile_args: the command line of mojo_compile (mojo_compile.zig), parsed
//! and checked without touching the file system.
//!
//!   mojo_compile --compiler=<dir> --cc-target=<triple> --zig=<dir>
//!                [--runpath=<$ORIGIN*>] [--source-root=<dir>] [--link-tail=<arg>]...
//!                [--watchdog-idle-secs=<n>] [--watchdog-sample-secs=<n>]
//!                [--ld-debug-output=<file>] -- <mojo arguments...>
//!
//! On macOS (`parseMacos`, mojo_compile_macos.zig) `--deployment-target=<v>`
//! and one or more `--macos-host=<id>` take the place of the three Linux
//! flags.
//!
//! Options come in any order; a repeated `--link-tail` accumulates in order,
//! any other repeated option keeps its last value. Every refusal is exit 2 of
//! the wrapper, with the message in `Diag.msg`.

const std = @import("std");

pub const Platform = enum { linux, macos };

pub const Options = struct {
    /// Absolute: `$PWD/<dir>` unless the flag gave an absolute path.
    compiler: []const u8,
    /// Absolute, as `compiler`. The directory holding the link driver `zig`.
    zig: []const u8,
    cc_target: []const u8,
    runpath: []const u8,
    /// Absolute, or null when not given.
    source_root: ?[]const u8,
    link_tail: []const []const u8,
    idle_secs: u32,
    sample_secs: u32,
    /// Absolute, or null: when given, the compiler runs with LD_DEBUG=libs
    /// and LD_DEBUG_OUTPUT=<this>, so the loader records what it maps
    /// (tests//functional/runtime_libs:loader_trace).
    ld_debug_output: ?[]const u8,
    /// The wrapper's working directory, absolute ($PWD as the shell spells
    /// it): what relative paths in `mojo_args` are relative to.
    pwd: []const u8,
    /// Everything after `--`, unchanged.
    mojo_args: []const []const u8,
    /// The value after the last `-o` in `mojo_args`.
    output: []const u8,
};

pub const Diag = struct {
    msg: []const u8 = "",
};

pub const Error = error{ Refused, OutOfMemory };

pub const default_runpath = "$ORIGIN/lib";
pub const default_idle_secs: u32 = 300;
pub const default_sample_secs: u32 = 30;

fn refuse(d: *Diag, alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Error {
    d.msg = std.fmt.allocPrint(alloc, fmt, args) catch return error.OutOfMemory;
    return error.Refused;
}

/// `p` when it is absolute, else `<pwd>/<p>`, spelled as the shell spelled
/// it (not canonicalised): the compiler matches -strip-file-prefix as a
/// string.
pub fn abspath(alloc: std.mem.Allocator, pwd: []const u8, p: []const u8) ![]const u8 {
    if (p.len > 0 and p[0] == '/') return p;
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ pwd, p });
}

/// A whole number of seconds: a non-empty run of digits that fits in u32.
fn parseSecs(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    for (s) |c| if (c < '0' or c > '9') return null;
    return std.fmt.parseInt(u32, s, 10) catch null;
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// The runpath must be `$ORIGIN` or start with `$ORIGIN/`.
pub fn runpathOk(r: []const u8) bool {
    return std.mem.eql(u8, r, "$ORIGIN") or std.mem.startsWith(u8, r, "$ORIGIN/");
}

/// The run path as the platform's loader spells it: `$ORIGIN` on Linux,
/// `@loader_path` on macOS.
pub fn platformRunpath(alloc: std.mem.Allocator, platform: Platform, r: []const u8) ![]const u8 {
    if (platform == .linux) return r;
    return std.fmt.allocPrint(alloc, "@loader_path{s}", .{r["$ORIGIN".len..]});
}

/// The value after the last `-o`, or null. `-o` as the last argument names
/// nothing and leaves an earlier value standing.
pub fn findOutput(args: []const []const u8) ?[]const u8 {
    var out: ?[]const u8 = null;
    var prev: []const u8 = "";
    for (args) |a| {
        if (std.mem.eql(u8, prev, "-o")) out = a;
        prev = a;
    }
    return out;
}

fn value(arg: []const u8, comptime flag: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, arg, flag)) return arg[flag.len..];
    return null;
}

pub fn parse(alloc: std.mem.Allocator, platform: Platform, pwd: []const u8, args: []const []const u8, d: *Diag) Error!Options {
    var compiler: ?[]const u8 = null;
    var zig: ?[]const u8 = null;
    var cc_target: ?[]const u8 = null;
    var runpath: []const u8 = default_runpath;
    var source_root: ?[]const u8 = null;
    var tail = std.ArrayList([]const u8).init(alloc);
    var idle_raw: []const u8 = "300";
    var sample_raw: []const u8 = "30";
    var ld_debug: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) break;
        if (value(a, "--compiler=")) |v| {
            compiler = try abspath(alloc, pwd, v);
        } else if (value(a, "--zig=")) |v| {
            zig = try abspath(alloc, pwd, v);
        } else if (value(a, "--cc-target=")) |v| {
            cc_target = v;
        } else if (value(a, "--runpath=")) |v| {
            if (!runpathOk(v)) return refuse(d, alloc, "REFUSING: --runpath={s} is not $ORIGIN-relative", .{v});
            runpath = v;
        } else if (value(a, "--source-root=")) |v| {
            source_root = try abspath(alloc, pwd, v);
        } else if (value(a, "--link-tail=")) |v| {
            if (std.mem.indexOfScalar(u8, v, '\n') != null) return refuse(d, alloc, "REFUSING: --link-tail value holds a newline", .{});
            try tail.append(v);
        } else if (value(a, "--watchdog-idle-secs=")) |v| {
            idle_raw = v;
        } else if (value(a, "--watchdog-sample-secs=")) |v| {
            sample_raw = v;
        } else if (value(a, "--ld-debug-output=")) |v| {
            ld_debug = try abspath(alloc, pwd, v);
        } else if (std.mem.startsWith(u8, a, "--deployment-target=") or std.mem.startsWith(u8, a, "--macos-host=")) {
            return refuse(d, alloc, "REFUSING: {s} is a macOS option; this mojo_compile is built for Linux", .{a});
        } else {
            return refuse(d, alloc, "expected -- before compiler arguments (got '{s}')", .{a});
        }
    }
    if (!allDigits(idle_raw) or !allDigits(sample_raw)) {
        return refuse(d, alloc, "REFUSING: watchdog seconds must be whole numbers (idle '{s}', sample '{s}')", .{ idle_raw, sample_raw });
    }
    const idle = parseSecs(idle_raw) orelse return refuse(d, alloc, "REFUSING: watchdog seconds must be at most {d} (idle '{s}', sample '{s}')", .{ std.math.maxInt(u32), idle_raw, sample_raw });
    const sample = parseSecs(sample_raw) orelse return refuse(d, alloc, "REFUSING: watchdog seconds must be at most {d} (idle '{s}', sample '{s}')", .{ std.math.maxInt(u32), idle_raw, sample_raw });
    if (sample < 1) return refuse(d, alloc, "REFUSING: --watchdog-sample-secs must be at least 1", .{});
    if (i >= args.len) return refuse(d, alloc, "expected -- before compiler arguments", .{});
    if (compiler == null or zig == null or cc_target == null) {
        return refuse(d, alloc, "usage: mojo_compile --compiler=<dir> --cc-target=<triple> --zig=<dir> [options] -- <mojo arguments...>", .{});
    }
    const mojo_args = args[i + 1 ..];
    const output = findOutput(mojo_args) orelse "";
    if (output.len == 0) return refuse(d, alloc, "no -o <output> in compiler arguments", .{});
    _ = platform;
    return .{
        .compiler = compiler.?,
        .zig = zig.?,
        .cc_target = cc_target.?,
        .runpath = runpath,
        .source_root = source_root,
        .link_tail = try tail.toOwnedSlice(),
        .idle_secs = idle,
        .sample_secs = sample,
        .ld_debug_output = ld_debug,
        .pwd = pwd,
        .mojo_args = mojo_args,
        .output = output,
    };
}

/// Where the compiler runs, when not in the wrapper's own working directory:
/// for `precompile` with a source root, the root's parent; else null.
///
/// A package compile records each source file by the path it names it with,
/// and `-strip-file-prefix` does not reach `precompile`. Run from the parent
/// of the staged package and given the package by its basename, the compiler
/// records `<name>/<file>.mojo`: the same `.mojoc` bytes under every working
/// directory, buck-out isolation directory and staging path
/// (tests//functional/mojoc_path:same_bytes).
pub fn runDir(o: Options) ?[]const u8 {
    const root = o.source_root orelse return null;
    if (o.mojo_args.len == 0 or !std.mem.eql(u8, o.mojo_args[0], "precompile")) return null;
    return std.fs.path.dirname(root);
}

/// The compiler's arguments:
///   * `build` with a source root: `-strip-file-prefix=<root>/` right after
///     the subcommand;
///   * `precompile` with a source root (runDir is not null, the compiler
///     runs there): the value after `-o` and every relative `-I` directory
///     (`-I<dir>` or `-I <dir>`) made absolute against `pwd`, and the
///     argument naming the source root replaced by the root's basename;
///   * otherwise `mojo_args` unchanged.
pub fn compilerArgs(alloc: std.mem.Allocator, o: Options) ![]const []const u8 {
    const root = o.source_root orelse return o.mojo_args;
    if (runDir(o) != null) {
        var out = std.ArrayList([]const u8).init(alloc);
        var prev: []const u8 = "";
        for (o.mojo_args) |a| {
            if (std.mem.eql(u8, prev, "-o") or std.mem.eql(u8, prev, "-I")) {
                try out.append(try abspath(alloc, o.pwd, a));
            } else if (std.mem.startsWith(u8, a, "-I") and a.len > 2) {
                try out.append(try std.fmt.allocPrint(alloc, "-I{s}", .{try abspath(alloc, o.pwd, a[2..])}));
            } else if (std.mem.eql(u8, try abspath(alloc, o.pwd, a), root)) {
                try out.append(std.fs.path.basename(root));
            } else {
                try out.append(a);
            }
            prev = a;
        }
        return out.toOwnedSlice();
    }
    if (o.mojo_args.len == 0 or !std.mem.eql(u8, o.mojo_args[0], "build")) return o.mojo_args;
    var out = std.ArrayList([]const u8).init(alloc);
    try out.append(o.mojo_args[0]);
    try out.append(try std.fmt.allocPrint(alloc, "-strip-file-prefix={s}/", .{root}));
    try out.appendSlice(o.mojo_args[1..]);
    return out.toOwnedSlice();
}

// ---- macOS -------------------------------------------------------------------

/// The macOS command line (mojo_compile_macos.zig):
///
///   mojo_compile --compiler=<dir> --deployment-target=<v> --macos-host=<id>...
///                [--runpath=<$ORIGIN*>] [--source-root=<dir>] [--link-tail=<arg>]...
///                [--watchdog-idle-secs=<n>] [--watchdog-sample-secs=<n>] -- <mojo arguments...>
pub const MacosOptions = struct {
    /// Absolute, as `Options.compiler`.
    compiler: []const u8,
    /// MACOSX_DEPLOYMENT_TARGET of every link.
    deployment_target: []const u8,
    /// The host identities the compile may run on (`[komira_re]
    /// darwin_macos_hosts`), in the order given; never empty.
    macos_hosts: []const []const u8,
    /// As dyld spells it: `@loader_path` for `$ORIGIN`.
    runpath: []const u8,
    source_root: ?[]const u8,
    link_tail: []const []const u8,
    idle_secs: u32,
    sample_secs: u32,
    /// As `Options.pwd`.
    pwd: []const u8,
    mojo_args: []const []const u8,
    output: []const u8,

    /// The fields `compilerArgs` and `runDir` read, as an `Options`.
    pub fn common(self: MacosOptions) Options {
        return .{
            .compiler = self.compiler,
            .zig = "",
            .cc_target = self.deployment_target,
            .runpath = self.runpath,
            .source_root = self.source_root,
            .link_tail = self.link_tail,
            .idle_secs = self.idle_secs,
            .sample_secs = self.sample_secs,
            .ld_debug_output = null,
            .pwd = self.pwd,
            .mojo_args = self.mojo_args,
            .output = self.output,
        };
    }
};

/// The options as `parse` reads them, with the macOS flags in place of the
/// Linux ones (a Linux flag is refused), and two macOS refusals: no
/// `--macos-host` (a compile that may run on no host), and `shared-lib`
/// among the compiler's arguments without `-install_name` (bundles are Linux
/// only; a C-ABI library names itself for dyld).
pub fn parseMacos(alloc: std.mem.Allocator, pwd: []const u8, args: []const []const u8, d: *Diag) Error!MacosOptions {
    var compiler: ?[]const u8 = null;
    var deployment: ?[]const u8 = null;
    var hosts = std.ArrayList([]const u8).init(alloc);
    var runpath: []const u8 = default_runpath;
    var source_root: ?[]const u8 = null;
    var tail = std.ArrayList([]const u8).init(alloc);
    var idle_raw: []const u8 = "300";
    var sample_raw: []const u8 = "30";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) break;
        if (value(a, "--compiler=")) |v| {
            compiler = try abspath(alloc, pwd, v);
        } else if (value(a, "--deployment-target=")) |v| {
            deployment = v;
        } else if (value(a, "--macos-host=")) |v| {
            if (v.len == 0) return refuse(d, alloc, "REFUSING: an empty --macos-host", .{});
            try hosts.append(v);
        } else if (value(a, "--runpath=")) |v| {
            if (!runpathOk(v)) return refuse(d, alloc, "REFUSING: --runpath={s} is not $ORIGIN-relative", .{v});
            runpath = v;
        } else if (value(a, "--source-root=")) |v| {
            source_root = try abspath(alloc, pwd, v);
        } else if (value(a, "--link-tail=")) |v| {
            if (std.mem.indexOfScalar(u8, v, '\n') != null) return refuse(d, alloc, "REFUSING: --link-tail value holds a newline", .{});
            try tail.append(v);
        } else if (value(a, "--watchdog-idle-secs=")) |v| {
            idle_raw = v;
        } else if (value(a, "--watchdog-sample-secs=")) |v| {
            sample_raw = v;
        } else if (std.mem.startsWith(u8, a, "--zig=") or std.mem.startsWith(u8, a, "--cc-target=") or std.mem.startsWith(u8, a, "--ld-debug-output=")) {
            return refuse(d, alloc, "REFUSING: {s} is a Linux option; this mojo_compile is built for macOS", .{a});
        } else {
            return refuse(d, alloc, "expected -- before compiler arguments (got '{s}')", .{a});
        }
    }
    if (!allDigits(idle_raw) or !allDigits(sample_raw)) {
        return refuse(d, alloc, "REFUSING: watchdog seconds must be whole numbers (idle '{s}', sample '{s}')", .{ idle_raw, sample_raw });
    }
    const idle = parseSecs(idle_raw) orelse return refuse(d, alloc, "REFUSING: watchdog seconds must be at most {d} (idle '{s}', sample '{s}')", .{ std.math.maxInt(u32), idle_raw, sample_raw });
    const sample = parseSecs(sample_raw) orelse return refuse(d, alloc, "REFUSING: watchdog seconds must be at most {d} (idle '{s}', sample '{s}')", .{ std.math.maxInt(u32), idle_raw, sample_raw });
    if (sample < 1) return refuse(d, alloc, "REFUSING: --watchdog-sample-secs must be at least 1", .{});
    if (i >= args.len) return refuse(d, alloc, "expected -- before compiler arguments", .{});
    if (compiler == null or deployment == null or deployment.?.len == 0) {
        return refuse(d, alloc, "usage: mojo_compile --compiler=<dir> --deployment-target=<v> --macos-host=<id>... [options] -- <mojo arguments...>", .{});
    }
    if (hosts.items.len == 0) {
        return refuse(d, alloc, "REFUSING: no --macos-host: the compile names no macOS host it may run on ([komira_re] darwin_macos_hosts)", .{});
    }
    const mojo_args = args[i + 1 ..];
    var shared = false;
    var named = false;
    for (mojo_args) |a| {
        if (std.mem.eql(u8, a, "shared-lib")) shared = true;
        if (std.mem.eql(u8, a, "-install_name")) named = true;
    }
    if (shared and !named) {
        return refuse(d, alloc, "REFUSING: --emit shared-lib on macOS without -Xlinker -install_name; bundles are linux only (a C-ABI library, mojo_shared_lib, builds as a .dylib)", .{});
    }
    const output = findOutput(mojo_args) orelse "";
    if (output.len == 0) return refuse(d, alloc, "no -o <output> in compiler arguments", .{});
    return .{
        .compiler = compiler.?,
        .deployment_target = deployment.?,
        .macos_hosts = try hosts.toOwnedSlice(),
        .runpath = try platformRunpath(alloc, .macos, runpath),
        .source_root = source_root,
        .link_tail = try tail.toOwnedSlice(),
        .idle_secs = idle,
        .sample_secs = sample,
        .pwd = pwd,
        .mojo_args = mojo_args,
        .output = output,
    };
}

// ---- tests -------------------------------------------------------------------

const testing = std.testing;

const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    diag: Diag,
    result: Error!Options,

    fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }
};

fn tryParse(args: []const []const u8) Parsed {
    var p = Parsed{ .arena = std.heap.ArenaAllocator.init(testing.allocator), .diag = .{}, .result = undefined };
    p.result = parse(p.arena.allocator(), .linux, "/wd", args, &p.diag);
    return p;
}

const base = [_][]const u8{ "--compiler=tc", "--cc-target=x86_64-linux-gnu.2.34", "--zig=/z" };

fn withBase(comptime extra: []const []const u8, comptime tail: []const []const u8) []const []const u8 {
    return &(base ++ extra[0..extra.len].* ++ [_][]const u8{"--"} ++ tail[0..tail.len].*);
}

// Catches: a required flag read from the wrong option, or a relative
// directory not made absolute against $PWD. Mutant: drop the abspath.
test "options: each flag, relative dirs made absolute against PWD" {
    var p = tryParse(withBase(&.{ "--runpath=$ORIGIN/x", "--source-root=src", "--ld-debug-output=ld/trace" }, &.{ "build", "a.mojo", "-o", "out" }));
    defer p.deinit();
    const o = try p.result;
    try testing.expectEqualStrings("/wd/tc", o.compiler);
    try testing.expectEqualStrings("/z", o.zig);
    try testing.expectEqualStrings("x86_64-linux-gnu.2.34", o.cc_target);
    try testing.expectEqualStrings("$ORIGIN/x", o.runpath);
    try testing.expectEqualStrings("/wd/src", o.source_root.?);
    try testing.expectEqualStrings("/wd/ld/trace", o.ld_debug_output.?);
    try testing.expectEqual(@as(u32, 300), o.idle_secs);
    try testing.expectEqual(@as(u32, 30), o.sample_secs);
    try testing.expectEqualStrings("out", o.output);
    try testing.expectEqual(@as(usize, 4), o.mojo_args.len);
}

// Catches: options accepted only in one order. Mutant: require --compiler first.
test "options: any order" {
    var p = tryParse(&.{ "--watchdog-idle-secs=7", "--zig=z", "--link-tail=-lm", "--cc-target=t", "--compiler=/c", "--", "precompile", "-o", "o" });
    defer p.deinit();
    const o = try p.result;
    try testing.expectEqualStrings("/c", o.compiler);
    try testing.expectEqualStrings("/wd/z", o.zig);
    try testing.expectEqual(@as(u32, 7), o.idle_secs);
}

// Catches: repeated --link-tail keeping one value, or reordering them.
// Mutant planted: keep the first --link-tail only.
test "options: repeated --link-tail accumulates in order" {
    var p = tryParse(withBase(&.{ "--link-tail=libb.a", "--link-tail=-lc++", "--link-tail=liba.a" }, &.{ "build", "-o", "o" }));
    defer p.deinit();
    const o = try p.result;
    try testing.expectEqual(@as(usize, 3), o.link_tail.len);
    try testing.expectEqualStrings("libb.a", o.link_tail[0]);
    try testing.expectEqualStrings("-lc++", o.link_tail[1]);
    try testing.expectEqualStrings("liba.a", o.link_tail[2]);
}

// Catches: a repeated option keeping its first value.
test "options: any other repeated option keeps its last value" {
    var p = tryParse(withBase(&.{ "--runpath=$ORIGIN/a", "--runpath=$ORIGIN/b", "--watchdog-sample-secs=5", "--watchdog-sample-secs=6", "--compiler=/c2" }, &.{ "build", "-o", "o" }));
    defer p.deinit();
    const o = try p.result;
    try testing.expectEqualStrings("$ORIGIN/b", o.runpath);
    try testing.expectEqual(@as(u32, 6), o.sample_secs);
    try testing.expectEqualStrings("/c2", o.compiler);
}

fn expectRefused(args: []const []const u8, want: []const u8) !void {
    var p = tryParse(args);
    defer p.deinit();
    if (p.result) |_| {
        std.debug.print("accepted, want a refusal naming '{s}'\n", .{want});
        return error.TestUnexpectedResult;
    } else |e| {
        try testing.expectEqual(error.Refused, e);
        if (std.mem.indexOf(u8, p.diag.msg, want) == null) {
            std.debug.print("refusal '{s}' does not name '{s}'\n", .{ p.diag.msg, want });
            return error.TestUnexpectedResult;
        }
    }
}

// Catches: compiler arguments taken without the `--` separator, or an
// unknown option passed on. Mutant: treat an unknown option as the start of
// the compiler arguments.
test "options: missing -- and unknown options are refused" {
    try expectRefused(&(base ++ [_][]const u8{ "build", "-o", "o" }), "expected -- before compiler arguments");
    try expectRefused(&(base ++ [_][]const u8{"--bogus=1"}), "expected -- before compiler arguments");
    try expectRefused(&base, "expected -- before compiler arguments");
}

// The four positionals the shell took are named flags now: each missing one
// is the shell's "fewer than five arguments" usage error.
test "options: a missing required flag or no arguments is a usage error" {
    try expectRefused(&.{}, "expected -- before compiler arguments");
    try expectRefused(&.{ "--compiler=c", "--zig=z", "--", "build", "-o", "o" }, "usage");
    try expectRefused(&.{ "--compiler=c", "--cc-target=t", "--", "build", "-o", "o" }, "usage");
    try expectRefused(&.{ "--zig=z", "--cc-target=t", "--", "build", "-o", "o" }, "usage");
}

test "options: macOS flags are refused on Linux" {
    try expectRefused(withBase(&.{"--macos-host=14.5-abc"}, &.{ "build", "-o", "o" }), "macOS option");
    try expectRefused(withBase(&.{"--deployment-target=11.0"}, &.{ "build", "-o", "o" }), "macOS option");
}

// Catches: a run path that names a directory outside the binary's own.
// Mutant planted: accept `$ORIGINx` (a prefix test without the slash).
test "runpath: $ORIGIN and $ORIGIN/x pass; /abs and $ORIGINx are refused" {
    try testing.expect(runpathOk("$ORIGIN"));
    try testing.expect(runpathOk("$ORIGIN/x"));
    try testing.expect(!runpathOk("/abs"));
    try testing.expect(!runpathOk("$ORIGINx"));
    try testing.expect(!runpathOk(""));
    try expectRefused(withBase(&.{"--runpath=$ORIGINx"}, &.{ "build", "-o", "o" }), "is not $ORIGIN-relative");
    try expectRefused(withBase(&.{"--runpath=/abs/lib"}, &.{ "build", "-o", "o" }), "is not $ORIGIN-relative");
    var p = tryParse(withBase(&.{}, &.{ "build", "-o", "o" }));
    defer p.deinit();
    try testing.expectEqualStrings("$ORIGIN/lib", (try p.result).runpath);
}

test "runpath: macOS spells $ORIGIN as @loader_path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("@loader_path/lib", try platformRunpath(arena.allocator(), .macos, "$ORIGIN/lib"));
    try testing.expectEqualStrings("@loader_path", try platformRunpath(arena.allocator(), .macos, "$ORIGIN"));
    try testing.expectEqualStrings("$ORIGIN/lib", try platformRunpath(arena.allocator(), .linux, "$ORIGIN/lib"));
}

// Catches: a malformed knob read as some number, a zero sample (a division
// by zero), or a value past u32 wrapping. Mutant planted: accept sample 0.
test "watchdog knobs: 0 turns it off; 5m, empty, sample 0 and 4294967296 are refused" {
    {
        var p = tryParse(withBase(&.{ "--watchdog-idle-secs=0", "--watchdog-sample-secs=1" }, &.{ "build", "-o", "o" }));
        defer p.deinit();
        const o = try p.result;
        try testing.expectEqual(@as(u32, 0), o.idle_secs);
        try testing.expectEqual(@as(u32, 1), o.sample_secs);
    }
    try expectRefused(withBase(&.{"--watchdog-idle-secs=5m"}, &.{ "build", "-o", "o" }), "whole numbers");
    try expectRefused(withBase(&.{"--watchdog-idle-secs="}, &.{ "build", "-o", "o" }), "whole numbers");
    try expectRefused(withBase(&.{"--watchdog-sample-secs="}, &.{ "build", "-o", "o" }), "whole numbers");
    try expectRefused(withBase(&.{"--watchdog-sample-secs=-1"}, &.{ "build", "-o", "o" }), "whole numbers");
    try expectRefused(withBase(&.{"--watchdog-sample-secs=0"}, &.{ "build", "-o", "o" }), "--watchdog-sample-secs must be at least 1");
    try expectRefused(withBase(&.{"--watchdog-idle-secs=4294967296"}, &.{ "build", "-o", "o" }), "at most 4294967295");
    try expectRefused(withBase(&.{"--watchdog-sample-secs=4294967296"}, &.{ "build", "-o", "o" }), "at most 4294967295");
    var p = tryParse(withBase(&.{"--watchdog-idle-secs=4294967295"}, &.{ "build", "-o", "o" }));
    defer p.deinit();
    try testing.expectEqual(@as(u32, 4294967295), (try p.result).idle_secs);
}

// Catches: the wrong argument checked after the compiler exits. Mutant
// planted: the first -o wins.
test "-o: none, one, two (last wins), -o last" {
    try testing.expect(findOutput(&.{ "build", "a.mojo" }) == null);
    try testing.expectEqualStrings("x", findOutput(&.{ "build", "-o", "x" }).?);
    try testing.expectEqualStrings("y", findOutput(&.{ "-o", "x", "build", "-o", "y" }).?);
    try testing.expectEqualStrings("x", findOutput(&.{ "-o", "x", "-o" }).?);
    try testing.expect(findOutput(&.{ "build", "-o" }) == null);
    try expectRefused(withBase(&.{}, &.{ "build", "a.mojo" }), "no -o <output>");
    try expectRefused(withBase(&.{}, &.{ "build", "-o" }), "no -o <output>");
    try expectRefused(withBase(&.{}, &.{ "build", "-o", "" }), "no -o <output>");
}

// Catches: a source prefix stripped where the compiler rejects the flag
// (`precompile`, `doc`) or put in the wrong place. Mutant planted: insert
// for every subcommand.
test "strip prefix: build inserts after the subcommand; precompile and doc do not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = Diag{};
    const b = try parse(a, .linux, "/wd", withBase(&.{"--source-root=stage/src"}, &.{ "build", "x.mojo", "-o", "o" }), &d);
    const got = try compilerArgs(a, b);
    try testing.expectEqual(@as(usize, 5), got.len);
    try testing.expectEqualStrings("build", got[0]);
    try testing.expectEqualStrings("-strip-file-prefix=/wd/stage/src/", got[1]);
    try testing.expectEqualStrings("x.mojo", got[2]);
    try testing.expect(runDir(b) == null);
    for ([_][]const u8{ "precompile", "doc" }) |sub| {
        const o = try parse(a, .linux, "/wd", &(base ++ [_][]const u8{ "--source-root=s", "--", sub, "x", "-o", "o" }), &d);
        const g = try compilerArgs(a, o);
        try testing.expectEqual(@as(usize, 4), g.len);
        try testing.expectEqualStrings(sub, g[0]);
        try testing.expectEqualStrings("x", g[1]);
        for (g) |arg| try testing.expect(!std.mem.startsWith(u8, arg, "-strip-file-prefix"));
    }
    const none = try parse(a, .linux, "/wd", withBase(&.{}, &.{ "build", "x", "-o", "o" }), &d);
    try testing.expectEqual(@as(usize, 4), (try compilerArgs(a, none)).len);
}

// Catches: a precompile run in the action directory (the .mojoc records the
// staged buck-out path), its output or a dependency directory left relative
// to a directory the compiler no longer runs in, or the package named by its
// staged path. Mutants planted, one per build: drop the -o abspath; drop the
// basename rewrite (both red here; the second also red in
// tests//functional/mojoc_path:same_bytes).
test "precompile with a source root: runs in the root's parent, package by basename, -o and -I absolute" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = Diag{};
    const o = try parse(a, .linux, "/wd", withBase(&.{"--source-root=stage/src/pkg"}, &.{ "precompile", "-Iinc/d", "-I/abs/e", "-I", "inc/f", "stage/src/pkg", "-o", "out/pkg.mojoc" }), &d);
    try testing.expectEqualStrings("/wd/stage/src", runDir(o).?);
    const g = try compilerArgs(a, o);
    const want = [_][]const u8{ "precompile", "-I/wd/inc/d", "-I/abs/e", "-I", "/wd/inc/f", "pkg", "-o", "/wd/out/pkg.mojoc" };
    try testing.expectEqual(want.len, g.len);
    for (want, g) |w, x| try testing.expectEqualStrings(w, x);
    // The root given absolute and the positional relative name one directory.
    const p = try parse(a, .linux, "/wd", withBase(&.{"--source-root=/wd/s/q"}, &.{ "precompile", "s/q", "-o", "/o/q.mojoc" }), &d);
    try testing.expectEqualStrings("/wd/s", runDir(p).?);
    const h = try compilerArgs(a, p);
    try testing.expectEqualStrings("q", h[1]);
    try testing.expectEqualStrings("/o/q.mojoc", h[3]);
}

// Catches: the compiler moved for a compile that names no source root, or
// for `build` and `doc` (their paths stay relative to the action directory).
// Mutant planted: runDir ignores the subcommand.
test "runDir: null without a source root, and for build and doc" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = Diag{};
    const bare = try parse(a, .linux, "/wd", withBase(&.{}, &.{ "precompile", "-Ii", "s", "-o", "o" }), &d);
    try testing.expect(runDir(bare) == null);
    const g = try compilerArgs(a, bare);
    try testing.expectEqualStrings("-Ii", g[1]);
    try testing.expectEqualStrings("o", g[4]);
    for ([_][]const u8{ "build", "doc" }) |sub| {
        const o = try parse(a, .linux, "/wd", &(base ++ [_][]const u8{ "--source-root=s/p", "--", sub, "-Ii", "s/p", "-o", "o" }), &d);
        try testing.expect(runDir(o) == null);
        const h = try compilerArgs(a, o);
        try testing.expectEqualStrings("o", h[h.len - 1]);
        try testing.expectEqualStrings("s/p", h[h.len - 3]);
    }
}

test "abspath: absolute kept, relative joined to PWD as spelled" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("/x/y", try abspath(arena.allocator(), "/wd", "/x/y"));
    try testing.expectEqualStrings("/wd/./x/../y", try abspath(arena.allocator(), "/wd", "./x/../y"));
}

// ---- macOS options -------------------------------------------------------------

const mac_base = [_][]const u8{ "--compiler=tc", "--deployment-target=11.0", "--macos-host=26.5-0123456789abcdef" };

fn macWithBase(comptime extra: []const []const u8, comptime tail: []const []const u8) []const []const u8 {
    return &(mac_base ++ extra[0..extra.len].* ++ [_][]const u8{"--"} ++ tail[0..tail.len].*);
}

const MacParsed = struct {
    arena: std.heap.ArenaAllocator,
    diag: Diag,
    result: Error!MacosOptions,

    fn deinit(self: *MacParsed) void {
        self.arena.deinit();
    }
};

fn tryParseMacos(args: []const []const u8) MacParsed {
    var p = MacParsed{ .arena = std.heap.ArenaAllocator.init(testing.allocator), .diag = .{}, .result = undefined };
    p.result = parseMacos(p.arena.allocator(), "/wd", args, &p.diag);
    return p;
}

fn expectRefusedMacos(args: []const []const u8, want: []const u8) !void {
    var p = tryParseMacos(args);
    defer p.deinit();
    if (p.result) |_| {
        std.debug.print("accepted, want a refusal naming '{s}'\n", .{want});
        return error.TestUnexpectedResult;
    } else |e| {
        try testing.expectEqual(error.Refused, e);
        if (std.mem.indexOf(u8, p.diag.msg, want) == null) {
            std.debug.print("refusal '{s}' does not name '{s}'\n", .{ p.diag.msg, want });
            return error.TestUnexpectedResult;
        }
    }
}

// Catches: a macOS flag read from the wrong option, hosts not accumulated in
// order, a relative compiler directory left relative, or the run path given
// to dyld in its Linux spelling. Mutant planted: keep the last --macos-host only.
test "macOS options: each flag; hosts accumulate in order; the run path in dyld's spelling" {
    var p = tryParseMacos(macWithBase(&.{ "--macos-host=15.0-fedcba9876543210", "--runpath=$ORIGIN/../lib", "--source-root=src", "--link-tail=liba.a", "--link-tail=-lc++" }, &.{ "build", "a.mojo", "-o", "out" }));
    defer p.deinit();
    const o = try p.result;
    try testing.expectEqualStrings("/wd/tc", o.compiler);
    try testing.expectEqualStrings("11.0", o.deployment_target);
    try testing.expectEqual(@as(usize, 2), o.macos_hosts.len);
    try testing.expectEqualStrings("26.5-0123456789abcdef", o.macos_hosts[0]);
    try testing.expectEqualStrings("15.0-fedcba9876543210", o.macos_hosts[1]);
    try testing.expectEqualStrings("@loader_path/../lib", o.runpath);
    try testing.expectEqualStrings("/wd/src", o.source_root.?);
    try testing.expectEqualStrings("liba.a", o.link_tail[0]);
    try testing.expectEqualStrings("-lc++", o.link_tail[1]);
    try testing.expectEqual(@as(u32, 300), o.idle_secs);
    try testing.expectEqual(@as(u32, 30), o.sample_secs);
    try testing.expectEqualStrings("out", o.output);
    // The default run path, in dyld's spelling.
    var q = tryParseMacos(macWithBase(&.{}, &.{ "build", "-o", "o" }));
    defer q.deinit();
    try testing.expectEqualStrings("@loader_path/lib", (try q.result).runpath);
    // -strip-file-prefix goes in as on Linux.
    const args = try compilerArgs(p.arena.allocator(), o.common());
    try testing.expectEqualStrings("-strip-file-prefix=/wd/src/", args[1]);
}

// Catches: a macOS precompile left in the action directory (its .mojoc
// records the staged buck-out path), or its -o and -I made absolute against
// something other than the action directory (MacosOptions.common dropping
// pwd). Mutant planted: common() sets .pwd = "" (red: -o and -I lose /wd).
test "macOS options: precompile with a source root runs in the root's parent, as on Linux" {
    var p = tryParseMacos(macWithBase(&.{"--source-root=stage/src/pkg"}, &.{ "precompile", "-Iinc/d", "stage/src/pkg", "-o", "out/pkg.mojoc" }));
    defer p.deinit();
    const o = (try p.result).common();
    try testing.expectEqualStrings("/wd/stage/src", runDir(o).?);
    const g = try compilerArgs(p.arena.allocator(), o);
    const want = [_][]const u8{ "precompile", "-I/wd/inc/d", "pkg", "-o", "/wd/out/pkg.mojoc" };
    try testing.expectEqual(want.len, g.len);
    for (want, g) |w, x| try testing.expectEqualStrings(w, x);
}

// Catches: a compile that may run on any host (an action key that names no
// host toolchain). Mutant planted: accept an empty host list.
test "macOS options: no --macos-host, or an empty one, is refused" {
    try expectRefusedMacos(&.{ "--compiler=tc", "--deployment-target=11.0", "--", "build", "-o", "o" }, "no --macos-host");
    try expectRefusedMacos(macWithBase(&.{"--macos-host="}, &.{ "build", "-o", "o" }), "an empty --macos-host");
}

// Catches: one source run under the other platform's contract.
test "macOS options: Linux flags are refused; a missing required flag is a usage error" {
    try expectRefusedMacos(macWithBase(&.{"--zig=/z"}, &.{ "build", "-o", "o" }), "Linux option");
    try expectRefusedMacos(macWithBase(&.{"--cc-target=x86_64-linux-gnu"}, &.{ "build", "-o", "o" }), "Linux option");
    try expectRefusedMacos(macWithBase(&.{"--ld-debug-output=t"}, &.{ "build", "-o", "o" }), "Linux option");
    try expectRefusedMacos(&.{ "--compiler=tc", "--macos-host=h-1", "--", "build", "-o", "o" }, "usage");
    try expectRefusedMacos(&.{ "--deployment-target=11.0", "--macos-host=h-1", "--", "build", "-o", "o" }, "usage");
    try expectRefusedMacos(&.{ "--compiler=tc", "--deployment-target=", "--macos-host=h-1", "--", "build", "-o", "o" }, "usage");
    try expectRefusedMacos(&(mac_base ++ [_][]const u8{ "build", "-o", "o" }), "expected -- before compiler arguments");
    try expectRefusedMacos(macWithBase(&.{"--runpath=/abs"}, &.{ "build", "-o", "o" }), "is not $ORIGIN-relative");
    try expectRefusedMacos(macWithBase(&.{"--watchdog-sample-secs=0"}, &.{ "build", "-o", "o" }), "at least 1");
    try expectRefusedMacos(macWithBase(&.{"--watchdog-idle-secs=5m"}, &.{ "build", "-o", "o" }), "whole numbers");
    try expectRefusedMacos(macWithBase(&.{}, &.{ "build", "a.mojo" }), "no -o <output>");
}

// Catches: a bundle (a Linux-only shape) built on macOS, or a C-ABI library
// that names itself for dyld refused. Mutant planted: drop the
// -install_name test (every shared-lib refused).
test "macOS options: shared-lib without -install_name is refused; with it, accepted" {
    try expectRefusedMacos(macWithBase(&.{}, &.{ "build", "--emit", "shared-lib", "x.mojo", "-o", "o" }), "bundles are linux only");
    try expectRefusedMacos(macWithBase(&.{}, &.{ "build", "--emit", "shared-lib", "-Xlinker", "-soname", "-Xlinker", "x.so", "x.mojo", "-o", "o" }), "bundles are linux only");
    var p = tryParseMacos(macWithBase(&.{}, &.{ "build", "--emit", "shared-lib", "-Xlinker", "-install_name", "-Xlinker", "@rpath/x.dylib", "x.mojo", "-o", "o" }));
    defer p.deinit();
    _ = try p.result;
}
