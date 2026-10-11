//! The cases of cov_zig (README.md#tests), `zig test` of this file (which
//! imports cov_zig.zig) run as a build action by `:cov_zig_unit`; the
//! executable `:cov_zig_exe` is not built unless every one passes.
//!
//! Each case runs the program as main does (`entry`: argv[0], the command
//! line, the working directory, $PWD and $BUCK_SCRATCH_PATH, stderr) from a
//! directory `shim` of its own: `shim/real/zig` is the stand-in
//! cov_zig_stub.zig (it records its arguments in `shim/real/argv` and copies
//! a given ELF file to the `-o` output) and `shim/debug_relocate` the real
//! one, their paths in the environment as COV_ZIG_STUB and DEBUG_RELOCATE
//! (the zig_test's `env_tools`; without them every case fails). When `entry`
//! says to exec a command line, the case runs that command line as main's
//! exec would. The fixtures put the
//! working directory where a C runtime unit's DW_AT_comp_dir would be. The
//! cases over the pinned zig run the shipped executable: cov_zig_exe_test.zig.

const std = @import("std");
const Z = @import("cov_zig.zig");
const elf = @import("cov_zig_elf.zig").elf;

const TGT = "x86_64-linux-gnu.2.34";
const Args = []const []const u8;

/// The path of a tool the test runs, from the environment variable `name`,
/// which the zig_test's `env_tools` sets. A run without it fails loudly; it
/// never passes unchecked.
fn tool(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    const v = std.process.getEnvVarOwned(a, name) catch {
        std.debug.print("the test target does not pass {s} (env_tools), so the tool cannot be run\n", .{name});
        return error.TestToolMissing;
    };
    return std.fs.cwd().realpathAlloc(a, v);
}

const Result = struct {
    status: u8,
    err: []const u8,
    /// The command line `entry` said to exec, null when it said to exit.
    exec: ?Args,
};

const Opts = struct {
    /// $PWD; null gives the working directory's own path, as a shell that
    /// changed into it by its physical path sets it.
    pwd: ?[]const u8 = null,
    scratch: ?[]const u8 = null,
    /// The stand-in's exit status.
    rc: ?[]const u8 = null,
};

/// A directory of its own: `shim/` (cov_zig's directory) and the working
/// directory `<name>/`.
const Case = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    /// The physical path of the temporary directory, the shim and the
    /// working directory (`C` in the shell cases: what a compiler records).
    root: []const u8,
    shim: []const u8,
    dir: std.fs.Dir,
    cwd: []const u8,

    fn init(name: []const u8) !Case {
        var c = Case{ .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator), .tmp = std.testing.tmpDir(.{}), .root = "", .shim = "", .dir = undefined, .cwd = "" };
        errdefer c.tmp.cleanup();
        const a = c.alloc();
        c.root = try c.tmp.dir.realpathAlloc(a, ".");
        try c.tmp.dir.makePath("shim/real");
        try c.tmp.dir.symLink(try tool(a, "COV_ZIG_STUB"), "shim/real/zig", .{});
        try c.tmp.dir.symLink(try tool(a, "DEBUG_RELOCATE"), "shim/debug_relocate", .{});
        c.shim = try c.path("shim");
        try c.tmp.dir.makePath(name);
        c.dir = try c.tmp.dir.openDir(name, .{});
        c.cwd = try c.dir.realpathAlloc(a, ".");
        return c;
    }

    fn deinit(self: *Case) void {
        self.dir.close();
        self.tmp.cleanup();
        self.arena.deinit();
    }

    fn alloc(self: *Case) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// `rel` under the temporary directory, as an absolute path.
    fn path(self: *Case, rel: []const u8) ![]const u8 {
        return std.fs.path.join(self.alloc(), &.{ self.root, rel });
    }

    /// An ELF file with the section `section` (flags `flags`) holding
    /// `payload` and a NUL, then `tail`: what the stand-in writes as the
    /// link output.
    fn fixture(self: *Case, section: []const u8, flags: u64, payload: []const u8, tail: []const u8) !void {
        const p = try std.mem.concat(self.alloc(), u8, &.{ payload, "\x00" });
        const bytes = try std.mem.concat(self.alloc(), u8, &.{ try elf(self.alloc(), section, flags, p), tail });
        try self.raw(bytes);
    }

    /// `bytes` as the stand-in's link output.
    fn raw(self: *Case, bytes: []const u8) !void {
        try self.tmp.dir.writeFile("fx", bytes);
        try self.tmp.dir.writeFile("shim/real/stub_out", try self.path("fx"));
    }

    /// Runs the program with `args`, and the command line it says to exec.
    fn run(self: *Case, args: Args, o: Opts) !Result {
        const a = self.alloc();
        try self.tmp.dir.writeFile("shim/real/stub_rc", o.rc orelse "0");
        self.tmp.dir.deleteFile("shim/real/argv") catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
        var err = std.ArrayList(u8).init(a);
        const argv0 = try std.fs.path.join(a, &.{ self.shim, "zig" });
        const env = Z.Env{ .dir = self.dir, .cwd = self.cwd, .pwd = o.pwd orelse self.cwd, .scratch = o.scratch };
        switch (Z.entry(a, argv0, args, env, err.writer())) {
            .exit => |status| return .{ .status = status, .err = err.items, .exec = null },
            .exec => |line| {
                const r = try std.ChildProcess.run(.{ .allocator = a, .argv = line, .cwd_dir = self.dir });
                const status: u8 = switch (r.term) {
                    .Exited => |s| s,
                    else => return error.TestUnexpectedResult,
                };
                return .{ .status = status, .err = err.items, .exec = line };
            },
        }
    }

    /// The arguments the stand-in got, one per line; null when it did not run.
    fn argv(self: *Case) !?[]const u8 {
        return self.tmp.dir.readFileAlloc(self.alloc(), "shim/real/argv", 1 << 16) catch |e| switch (e) {
            error.FileNotFound => null,
            else => return e,
        };
    }

    fn file(self: *Case, name: []const u8) ![]const u8 {
        return self.dir.readFileAlloc(self.alloc(), name, 1 << 20);
    }
};

/// The placeholder debug_relocate writes over `dir`: '/' then '_'.
fn placeholder(a: std.mem.Allocator, dir: []const u8) ![]const u8 {
    const p = try a.alloc(u8, dir.len);
    @memset(p, '_');
    p[0] = '/';
    return p;
}

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn check(ok: bool, comptime what: []const u8, r: Result) !void {
    if (!ok) {
        std.debug.print("{s}; exit {d}; stderr:\n{s}\n", .{ what, r.status, r.err });
        return error.TestUnexpectedResult;
    }
}

fn lines(a: std.mem.Allocator, items: Args) ![]const u8 {
    var b = std.ArrayList(u8).init(a);
    for (items) |i| {
        try b.appendSlice(i);
        try b.append('\n');
    }
    return b.items;
}

// 1. A link: -Wl,--strip-debug dropped, the two flags appended after the
// compiler's own arguments, everything else in order; the output's working
// directory rewritten to the placeholder.
test "1. link: strip dropped, the two flags appended, the working directory relocated" {
    var c = try Case.init("link");
    defer c.deinit();
    const a = c.alloc();
    try c.fixture(".debug_line", 0, try std.mem.concat(a, u8, &.{ c.cwd, "/a.mojo" }), "");
    const r = try c.run(&.{ "cc", "-target", TGT, "-Wl,--strip-debug", "-Wl,--enable-new-dtags", "-Wl,-rpath,$ORIGIN/lib", "a.o", "-o", "out", "-lm" }, .{});
    try check(r.status == 0 and r.exec == null, "link: want exit 0", r);
    const want = try lines(a, &.{ "cc", "-target", TGT, "-Wl,--enable-new-dtags", "-Wl,-rpath,$ORIGIN/lib", "a.o", "-o", "out", "-lm", "-Wl,--build-id=none", "-Wl,--compress-debug-sections=none" });
    try std.testing.expectEqualStrings(want, (try c.argv()) orelse "");
    const out = try c.file("out");
    try check(has(out, try std.mem.concat(a, u8, &.{ try placeholder(a, c.cwd), "/a.mojo" })), "link: the output does not hold the placeholder", r);
    try check(!has(out, c.cwd), "link: the output still holds the working directory", r);
}

// 2. The output named joined (-oout) is relocated too.
test "2. joined -o: -oout is a link output, relocated" {
    var c = try Case.init("joined");
    defer c.deinit();
    try c.fixture(".debug_info", 0, c.cwd, "");
    const r = try c.run(&.{ "c++", "a.o", "-oout" }, .{});
    try check(r.status == 0 and r.exec == null, "joined -o: want exit 0", r);
    try check(!has(try c.file("out"), c.cwd), "joined -o: the output still holds the working directory", r);
}

// 3. A compile (-c) is not a link: the arguments reach real/zig unchanged,
// -Wl,--strip-debug included, and the output is not relocated.
test "3. compile: -c reaches real/zig unchanged, not relocated" {
    var c = try Case.init("compile");
    defer c.deinit();
    const a = c.alloc();
    try c.fixture(".debug_line", 0, c.cwd, "");
    const args = [_][]const u8{ "cc", "-c", "a.c", "-Wl,--strip-debug", "-o", "a.o" };
    const r = try c.run(&args, .{});
    try check(r.status == 0, "compile: want exit 0", r);
    try check(r.exec != null, "compile: entry did not exec real/zig", r);
    const line = r.exec.?;
    try std.testing.expectEqualStrings(try std.fs.path.join(a, &.{ c.shim, "real", "zig" }), line[0]);
    try std.testing.expectEqualStrings(try lines(a, &args), (try c.argv()) orelse "");
    try check(has(try c.file("a.o"), c.cwd), "compile: the output was relocated", r);
}

// 4. Another subcommand passes through unchanged.
test "4. other subcommand: passes through unchanged" {
    var c = try Case.init("other");
    defer c.deinit();
    const args = [_][]const u8{ "ar", "rcs", "lib.a", "-Wl,--strip-debug" };
    const r = try c.run(&args, .{});
    try check(r.status == 0 and r.exec != null, "other subcommand: want exit 0 through exec", r);
    try std.testing.expectEqualStrings(try lines(c.alloc(), &args), (try c.argv()) orelse "");
}

// 5. A failed link exits with real/zig's status and relocates nothing.
test "5. failed link: real/zig's status, nothing relocated" {
    var c = try Case.init("failed");
    defer c.deinit();
    try c.fixture(".debug_line", 0, c.cwd, "");
    const r = try c.run(&.{ "cc", "a.o", "-o", "out" }, .{ .rc = "7" });
    try check(r.status == 7 and r.exec == null, "failed link: want exit 7", r);
    try check(has(try c.file("out"), c.cwd), "failed link: the output was relocated", r);
}

// 6. Debug sections that do not name the working directory: exit 1. The
// DWARF names a directory nobody relocated, so the bytes would differ by
// machine.
test "6. debug info elsewhere: exit 1" {
    var c = try Case.init("elsewhere");
    defer c.deinit();
    try c.fixture(".debug_line", 0, "/some/other/compile/dir", "");
    const r = try c.run(&.{ "cc", "a.o", "-o", "out" }, .{});
    try check(r.status == 1 and has(r.err, "has debug sections but holds the working directory"), "debug info elsewhere: want exit 1 saying so", r);
}

// 7. No debug section and no working directory: 0 rewrites are fine.
test "7. no debug section: exit 0" {
    var c = try Case.init("nodebug");
    defer c.deinit();
    try c.fixture(".text", 0, "nothing", "");
    const r = try c.run(&.{ "cc", "a.o", "-o", "out" }, .{});
    try check(r.status == 0, "no debug section: want exit 0", r);
}

// 8. debug_relocate's refusal fails the link: the working directory
// followed by another byte (a longer name).
test "8. relocation refused: exit 1, debug_relocate's message passed on" {
    var c = try Case.init("refused");
    defer c.deinit();
    try c.fixture(".debug_line", 0, try std.mem.concat(c.alloc(), u8, &.{ c.cwd, "x" }), "");
    const r = try c.run(&.{ "cc", "a.o", "-o", "out" }, .{});
    try check(r.status == 1, "relocation refused: want exit 1", r);
    try check(has(r.err, "debug_relocate refused out (exit 1)"), "relocation refused: the message does not name debug_relocate's refusal", r);
    try check(has(r.err, "is followed by byte 0x78"), "relocation refused: debug_relocate's own message is not passed on", r);
}

// 9. A compressed debug section fails the link (debug_relocate refuses it).
test "9. compressed section: exit 1 naming SHF_COMPRESSED" {
    var c = try Case.init("compressed");
    defer c.deinit();
    try c.fixture(".debug_line", 2048, c.cwd, "");
    const r = try c.run(&.{ "cc", "a.o", "-o", "out" }, .{});
    try check(r.status == 1 and has(r.err, "SHF_COMPRESSED"), "compressed section: want exit 1 naming SHF_COMPRESSED", r);
}

// 10. An output that is not ELF64: exit 1.
test "10. not ELF: exit 1" {
    var c = try Case.init("notelf");
    defer c.deinit();
    try c.raw(try std.mem.concat(c.alloc(), u8, &.{ "not an ELF file ", c.cwd }));
    const r = try c.run(&.{ "cc", "a.o", "-o", "out" }, .{});
    try check(r.status == 1 and has(r.err, "is not an ELF64 little-endian file"), "not ELF: want exit 1 saying so", r);
}

// 11. The working directory reached through a symbolic link: $PWD (the
// logical path, which a compiler may record instead) is relocated too, and
// so is an absolute $BUCK_SCRATCH_PATH outside the working directory.
test "11. logical: $PWD and an absolute $BUCK_SCRATCH_PATH relocated too" {
    var c = try Case.init("logical");
    defer c.deinit();
    const a = c.alloc();
    try c.tmp.dir.makePath("scratch_elsewhere");
    try c.tmp.dir.symLink(c.cwd, "via_link", .{});
    const l = try c.path("via_link");
    const s = try c.path("scratch_elsewhere");
    try std.testing.expect(!std.mem.eql(u8, l, c.cwd));
    const tail = try std.mem.concat(a, u8, &.{ l, "/b.mojo\x00", s, "/zig/crt.c\x00" });
    try c.fixture(".debug_line", 0, c.cwd, tail);
    const r = try c.run(&.{ "cc", "a.o", "-o", "out" }, .{ .pwd = l, .scratch = s });
    try check(r.status == 0, "logical: want exit 0", r);
    const out = try c.file("out");
    for ([_][]const u8{ c.cwd, l, s }) |d| {
        if (has(out, d)) std.debug.print("logical: the output still holds {s}\n", .{d});
        try std.testing.expect(!has(out, d));
    }
}

// 12. Only the logical spelling: the output names $PWD (the working
// directory through a symbolic link, which LLVM records when it names the
// same directory) and never the physical path. That directory was
// relocated, so the link passes: the zero-count check counts both spellings.
test "12. logical only: the output names only $PWD, relocated, exit 0" {
    var c = try Case.init("logical_only");
    defer c.deinit();
    try c.tmp.dir.symLink(c.cwd, "via_link2", .{});
    const l = try c.path("via_link2");
    try std.testing.expect(!std.mem.eql(u8, l, c.cwd));
    try c.fixture(".debug_line", 0, l, "");
    const r = try c.run(&.{ "cc", "a.o", "-o", "out" }, .{ .pwd = l });
    try check(r.status == 0, "logical only: want exit 0", r);
    const out = try c.file("out");
    try check(!has(out, l), "logical only: the output still holds $PWD", r);
    try check(has(out, try placeholder(c.alloc(), l)), "logical only: the output does not hold the placeholder of $PWD", r);
}

// 13. Only the absolute $BUCK_SCRATCH_PATH, outside the working directory:
// the output names it and neither spelling of the working directory. It is
// relocated (debug_relocate counts it), but the zero-count check counts the
// working directory's spellings alone, so the link fails: a count of every
// directory given would pass it, and the runtime's DWARF could then name a
// directory nobody relocated.
test "13. scratch only: relocated, and the link fails, exit 1" {
    var c = try Case.init("scratch_only");
    defer c.deinit();
    const a = c.alloc();
    try c.tmp.dir.makePath("sbx_scratch");
    const s = try c.path("sbx_scratch");
    try std.testing.expect(!std.mem.startsWith(u8, s, try std.mem.concat(a, u8, &.{ c.cwd, "/" })));
    try c.fixture(".debug_line", 0, try std.mem.concat(a, u8, &.{ s, "/zig/crt.c" }), "");
    const r = try c.run(&.{ "cc", "a.o", "-o", "out" }, .{ .scratch = s });
    try check(r.status == 1 and has(r.err, "has debug sections but holds the working directory"), "scratch only: want exit 1 saying so", r);
    try check(!has(try c.file("out"), s), "scratch only: the output still holds the scratch directory (not relocated)", r);
}

// A relative $PWD or $BUCK_SCRATCH_PATH is not a directory of the action:
// neither is given to debug_relocate (which would refuse it, so the link
// would fail), and the relative strings in the output stay as they are.
test "relative: a relative $PWD and $BUCK_SCRATCH_PATH are not relocated, exit 0" {
    var c = try Case.init("relative");
    defer c.deinit();
    const a = c.alloc();
    const l = "relative/logical/dir";
    const s = "relative/scratch/dir";
    try c.fixture(".debug_line", 0, c.cwd, try std.mem.concat(a, u8, &.{ l, "/b.mojo\x00", s, "/zig/crt.c\x00" }));
    const r = try c.run(&.{ "cc", "a.o", "-o", "out" }, .{ .pwd = l, .scratch = s });
    try check(r.status == 0, "relative: want exit 0", r);
    const out = try c.file("out");
    try check(!has(out, c.cwd), "relative: the output still holds the working directory", r);
    try check(has(out, l) and has(out, s), "relative: a relative $PWD or $BUCK_SCRATCH_PATH was rewritten", r);
}

// 14. A link at a release optimization level is refused before real/zig
// runs: zig 0.12 then gives lld -O2 or -O3 (link/Elf.zig), which merges
// string tails, and a string that is the tail of a relocated directory would
// be rewritten with it. -O0 and -Og are Debug for zig, and a bare -O goes to
// clang without changing the mode: those links pass, and so does a compile.
test "14. release level: refused before real/zig runs; Debug levels and a compile pass" {
    for ([_][]const u8{ "-O1", "-O2", "-O3", "-O4", "-Ofast", "-Os", "-Oz" }) |o| {
        var c = try Case.init("opt");
        defer c.deinit();
        try c.fixture(".debug_line", 0, c.cwd, "");
        const r = try c.run(&.{ "cc", "a.o", o, "-o", "out" }, .{});
        if (r.status != 1 or !has(r.err, try std.mem.concat(c.alloc(), u8, &.{ "optimization level ", o })) or (try c.argv()) != null) {
            std.debug.print("link with {s}: exit {d}, want 1 naming it with real/zig not run; stderr:\n{s}\n", .{ o, r.status, r.err });
            return error.TestUnexpectedResult;
        }
    }
    for ([_][]const u8{ "-O0", "-Og", "-O" }) |o| {
        var c = try Case.init("opt");
        defer c.deinit();
        try c.fixture(".debug_line", 0, c.cwd, "");
        const r = try c.run(&.{ "cc", "a.o", o, "-o", "out" }, .{});
        if (r.status != 0) {
            std.debug.print("link with {s}: exit {d}, want 0; stderr:\n{s}\n", .{ o, r.status, r.err });
            return error.TestUnexpectedResult;
        }
    }
    var k = try Case.init("optcompile");
    defer k.deinit();
    try k.fixture(".debug_line", 0, k.cwd, "");
    const r = try k.run(&.{ "cc", "-c", "a.c", "-O2", "-o", "a.o" }, .{});
    try check(r.status == 0 and r.exec != null, "compile with -O2: want exit 0 through exec (only a link is refused)", r);
}
