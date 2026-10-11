//! The shipped debug_relocate executable as a process (README.md#tests):
//! `zig test` of this file, run as a build action by
//! `:debug_relocate_exe_test`, a validation of `:debug_relocate`. The cases in
//! debug_relocate_test.zig call the program's `entry` in-process; these run
//! the executable the public target hands out (module `exes`, the
//! `zig_test`'s `exes`) as a child process, with an empty environment, and
//! check what `main` adds: the command line taken from argv[1..], the counts
//! written to stdout and the messages to stderr, and `entry`'s status as the
//! process's exit status.

const std = @import("std");
const exes = @import("exes");

const D = "/worker/build/0123456789abcdef/root";
const P = "/__________________________________";

const Run = struct {
    code: u8,
    stdout: []const u8,
    stderr: []const u8,
    file: []const u8,
};

/// Runs the executable with `args` in a directory of its own holding `f`
/// (the bytes `bytes`), and reads back its exit status, stdout, stderr and f.
fn run(a: std.mem.Allocator, tmp: *std.testing.TmpDir, bytes: []const u8, args: []const []const u8) !Run {
    {
        var f = try tmp.dir.createFile("f", .{});
        defer f.close();
        try f.writeAll(bytes);
    }
    const exe = try std.fs.cwd().realpathAlloc(a, exes.debug_relocate);
    var argv = std.ArrayList([]const u8).init(a);
    try argv.append(exe);
    try argv.appendSlice(args);
    var env = std.process.EnvMap.init(a);
    const r = try std.ChildProcess.run(.{
        .allocator = a,
        .argv = argv.items,
        .cwd_dir = tmp.dir,
        .env_map = &env,
        .max_output_bytes = 1 << 20,
    });
    const code: u8 = switch (r.term) {
        .Exited => |c| c,
        else => {
            std.debug.print("debug_relocate did not exit: {any}; stderr:\n{s}\n", .{ r.term, r.stderr });
            return error.TestUnexpectedResult;
        },
    };
    const file = try tmp.dir.readFileAlloc(a, "f", 1 << 20);
    return .{ .code = code, .stdout = r.stdout, .stderr = r.stderr, .file = file };
}

/// Exit `code`, `out` the whole of stdout, `msg` on stderr (empty: nothing),
/// and f holding `want`.
fn expect(name: []const u8, r: Run, code: u8, out: []const u8, msg: []const u8, want: []const u8) !void {
    const err_ok = if (msg.len == 0) r.stderr.len == 0 else std.mem.indexOf(u8, r.stderr, msg) != null;
    if (r.code != code or !std.mem.eql(u8, r.stdout, out) or !err_ok) {
        std.debug.print("{s}: exit {d}, want {d} with stdout '{s}' and '{s}' on stderr; stdout:\n{s}\nstderr:\n{s}\n", .{ name, r.code, code, out, msg, r.stdout, r.stderr });
        return error.TestUnexpectedResult;
    }
    if (!std.mem.eql(u8, r.file, want)) {
        std.debug.print("{s}: the file holds the wrong bytes\n", .{name});
        return error.TestUnexpectedResult;
    }
}

test "success: exit 0, the count on stdout, nothing on stderr, the file rewritten" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try run(arena.allocator(), &tmp, "A" ++ D ++ "/x\x00", &.{ "f", D });
    try expect("success", r, 0, "1 " ++ D ++ "\n", "", "A" ++ P ++ "/x\x00");
}

test "refusal: exit 1, the refusal on stderr, nothing on stdout, the file untouched" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = D ++ "/ok\x00" ++ D ++ "x\x00";
    const r = try run(arena.allocator(), &tmp, f, &.{ "f", D });
    try expect("refusal", r, 1, "", "debug_relocate: f: " ++ D ++ " at offset 39 is followed by byte 0x78, not '/' or NUL, so the file is left unchanged\n", f);
}

test "bad usage: exit 2, the usage line on stderr, nothing on stdout, the file untouched" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = D ++ "\x00";
    const r = try run(arena.allocator(), &tmp, f, &.{ "f", "/a/b/cd" });
    try expect("bad usage", r, 2, "", "debug_relocate: directory '/a/b/cd' is 7 bytes long, under 8\nusage: debug_relocate <file> <dir>...\n", f);
}
