//! The shipped cov_normalize executable as a process (README.md#tests):
//! `zig test` of this file, run as a build action by `:cov_normalize_exe_test`,
//! a validation of `:cov_normalize`. The cases in cov_normalize_test.zig call
//! the program's `entry` in-process; these run the executable the public
//! target hands out (module `exes`, the `zig_test`'s `exes`) as a child
//! process, with an empty environment, and check what `main` adds: the
//! command line taken from argv[1..], the messages written to stderr and
//! none to stdout, and `entry`'s status as the process's exit status.

const std = @import("std");
const exes = @import("exes");

const fixture = @embedFile("fixtures/kcov_full_paths.xml");
const golden = @embedFile("fixtures/kcov_full_paths.golden.xml");

const FX = "kcov_full_paths.xml";
const OUT = "out.xml";

const D = "/worker/build/0123456789abcdef/root";
const P = "/__________________________________";
const ART = "buck-out/v2/art/komira/src/komira_retry/__komira_retry__/fedcba9876543210/src/komira_retry/";
const PKG = "src/komira_retry/";

// The command line of cov_normalize_test.zig's golden case.
const MAPS = [_][]const u8{
    "--map", D ++ "/srcroot/" ++ ART ++ "=" ++ PKG,
    "--map", D ++ "/srcroot/=" ++ PKG,
    "--map", P ++ "/" ++ ART ++ "=" ++ PKG,
    "--exclude", D ++ "/srcroot/buck-out/v2/gen/",
};
const MUST = [_][]const u8{ "--must-contain", PKG ++ "tests/test_refusals.mojo", "--must-contain", PKG ++ "policy.mojo" };
const IO = [_][]const u8{ "--in", FX, "--out", OUT };

const Run = struct {
    code: u8,
    stdout: []const u8,
    stderr: []const u8,
    out: ?[]const u8,
};

/// Runs the executable with `args` in a directory of its own holding the
/// fixture, and reads back its exit status, stdout, stderr and output file.
fn run(a: std.mem.Allocator, tmp: *std.testing.TmpDir, args: []const []const u8) !Run {
    {
        var f = try tmp.dir.createFile(FX, .{});
        defer f.close();
        try f.writeAll(fixture);
    }
    const exe = try std.fs.cwd().realpathAlloc(a, exes.cov_normalize);
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
            std.debug.print("cov_normalize did not exit: {any}; stderr:\n{s}\n", .{ r.term, r.stderr });
            return error.TestUnexpectedResult;
        },
    };
    const out = tmp.dir.readFileAlloc(a, OUT, 1 << 20) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
    return .{ .code = code, .stdout = r.stdout, .stderr = r.stderr, .out = out };
}

fn expect(name: []const u8, r: Run, code: u8, msg: []const u8) !void {
    if (r.code != code or std.mem.indexOf(u8, r.stderr, msg) == null or r.stdout.len != 0) {
        std.debug.print("{s}: exit {d}, want {d} with '{s}' on stderr and nothing on stdout; stdout:\n{s}\nstderr:\n{s}\n", .{ name, r.code, code, msg, r.stdout, r.stderr });
        return error.TestUnexpectedResult;
    }
}

test "success: exit 0, the golden output, the count line on stderr" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try run(arena.allocator(), &tmp, &(IO ++ MAPS ++ MUST ++ [_][]const u8{ "--forbid", D }));
    try expect("success", r, 0, "cov_normalize: 7 class(es) read, 1 excluded, 5 written\n");
    try std.testing.expectEqualStrings(golden, r.out orelse return error.TestUnexpectedResult);
}

test "refusal: exit 1, the refusal on stderr, no output" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // MAPS without its second map: the three test files are unmapped.
    const maps = [_][]const u8{ MAPS[0], MAPS[1], MAPS[4], MAPS[5], MAPS[6], MAPS[7] };
    const r = try run(arena.allocator(), &tmp, &(IO ++ maps ++ [_][]const u8{ "--must-contain", PKG ++ "policy.mojo" }));
    try expect("refusal", r, 1, "unmapped file name '" ++ D ++ "/srcroot/tests/test_refusals.mojo': no --map or --exclude prefix covers it\n");
    try expect("refusal", r, 1, "cov_normalize: 3 unmapped file name(s) in " ++ FX ++ "; nothing written\n");
    if (r.out != null) {
        std.debug.print("refusal: an output was written\n", .{});
        return error.TestUnexpectedResult;
    }
}

test "bad usage: exit 2, the usage line on stderr, no output" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try run(arena.allocator(), &tmp, &(IO ++ MAPS ++ MUST ++ [_][]const u8{ "--in", FX }));
    try expect("bad usage", r, 2, "cov_normalize: --in given twice\nusage: cov_normalize --in <report.xml> --out <file>");
    if (r.out != null) {
        std.debug.print("bad usage: an output was written\n", .{});
        return error.TestUnexpectedResult;
    }
}
