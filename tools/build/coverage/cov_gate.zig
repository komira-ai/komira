// Why Zig: build tools are Zig (tools/build/README.md). This replaces
// cov_gate.sh (a busybox shell script around `covcheck gate`), so that the
// coverage gate runs no shell.
//! cov_gate: the coverage gate of one mojo_library in a build action
//! (`mojo_cov_gate`, tools/build/mojo/coverage.bzl): `covcheck gate` over the
//! kcov reports of the library's tests and their branch records, in the
//! policy's mode (tools/build/coverage/policy.bzl). README.md, "The build gate".
//!
//! usage: <gate_dir>/cov_gate <busybox> <label> <package> <mode> <target_bp>
//!            <root> <tests> <held> <result_out> <summary_out> <marker_out>
//!            [--info-package <package>] [<report>...] [--branch-lcov <branch_info>...]
//!
//!   <gate_dir>   the cov_gate_dir: this program and covcheck/ (the covcheck
//!                binary and the runtime libraries it loads)
//!   <package>    the library's package, a repository directory (`(root)` for
//!                the top), as covcheck maps files to packages
//!   <mode>       census, neutral or enforce; <target_bp> 0 to 10000
//!   <root>       the library's sources at their repository paths: its
//!                non-generated [src] files and its test sources, and a BUCK
//!                file at <package>, so covcheck's nearest-BUCK rule finds the
//!                package; nothing else
//!   <tests>      a file naming the repository path of each test source the
//!                library welds, one per line: each is covcheck's
//!                --test-source, set aside wherever it is in the package
//!   <held>       covcheck's --held: the package's coverage_held, or a marker
//!                holding nothing (README.md, "The 99% threshold and holds")
//!   --info-package <package>  the library's package is test-only
//!                (COVERAGE_INFO_ONLY_DIRS, policy.bzl): covcheck reports its
//!                findings as information, so it has none and the gate never
//!                fails on a finding (covcheck exits 1 and 2 still fail it)
//!   <report>     a test's Cobertura report, in repository paths (cov_run)
//!   <branch_info> after the argument `--branch-lcov` (given at most once:
//!                every argument after it is a branch record file): a test's
//!                branch records, in repository paths
//!                (cov_branch_classify, tools/build/coverage/branch/README.md)
//!
//! The repository's files, as covcheck reads them (--repo-files, NUL-separated
//! like `git ls-files -z`), are every file under <root>: the gate measures each
//! source file of the library, recorded or not (a file no test compiled counts
//! all its executable lines uncovered, UnmeasuredFile), and the test sources
//! (<tests>, and anything under <package>/tests/) are set aside. With no report
//! (a library with no test) the package is NotMeasured.
//!
//! covcheck runs with the busybox applets as PATH, LC_ALL=C, and no
//! LD_LIBRARY_PATH or LD_PRELOAD.
//!
//! Exit status: 0 when covcheck wrote its outputs and found nothing fatal in
//! the mode (census and neutral fail on no finding but a Regression, a held
//! metric below the target): <result_out> (JSON) and <summary_out> (Markdown)
//! are covcheck's, and <marker_out> says PASS. 1 when covcheck exits 3 (a
//! finding in enforce mode, or a Regression in any mode: the summary is printed
//! under `COVERAGE GATE FAILED (<mode>): <package>`), when covcheck exits 1 (an
//! input it refuses) or 2 (bad usage), each with covcheck's message, in every
//! mode; 2 for a usage error of this program.

const std = @import("std");

pub const Mode = enum { census, neutral, enforce };

pub const Input = struct { flag: []const u8, path: []const u8 };

pub const UsageError = error{Usage};

/// A valid package: a repository directory, `(root)` for the top: not empty,
/// not absolute, no trailing slash, no empty component.
pub fn validPackage(p: []const u8) bool {
    if (p.len == 0 or p[0] == '/' or p[p.len - 1] == '/') return false;
    return std.mem.indexOf(u8, p, "//") == null;
}

/// `target` is a non-empty string of digits.
pub fn validTarget(t: []const u8) bool {
    if (t.len == 0) return false;
    for (t) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// The optional `--info-package`, the mode and the reports and branch records
/// of the arguments after the eleven positional ones. `diag` says what is wrong.
pub fn parseTail(a: std.mem.Allocator, package: []const u8, tail: []const []const u8, diag: *[]const u8) (UsageError || std.mem.Allocator.Error)!struct { info: ?[]const u8, inputs: []Input } {
    var rest = tail;
    var info: ?[]const u8 = null;
    if (rest.len > 0 and std.mem.eql(u8, rest[0], "--info-package")) {
        if (rest.len < 2 or !std.mem.eql(u8, rest[1], package)) {
            diag.* = try std.fmt.allocPrint(a, "--info-package must name the package {s}", .{package});
            return error.Usage;
        }
        info = rest[1];
        rest = rest[2..];
    }
    var inputs = std.ArrayList(Input).init(a);
    var flag: []const u8 = "--cobertura";
    for (rest) |arg| {
        if (std.mem.eql(u8, arg, "--branch-lcov") and std.mem.eql(u8, flag, "--cobertura")) {
            flag = "--branch-lcov";
            continue;
        }
        try inputs.append(.{ .flag = flag, .path = arg });
    }
    return .{ .info = info, .inputs = try inputs.toOwnedSlice() };
}

/// The files under `dir` (regular files, at their paths from `dir`), sorted
/// bytewise.
pub fn repoFiles(a: std.mem.Allocator, dir: std.fs.Dir) ![][]const u8 {
    var out = std.ArrayList([]const u8).init(a);
    var w = try dir.walk(a);
    defer w.deinit();
    while (try w.next()) |e| {
        if (e.kind == .file) try out.append(try a.dupe(u8, e.path));
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return out.toOwnedSlice();
}

/// `names` NUL-terminated and concatenated (`find ... | sort | tr '\n' '\0'`).
pub fn nulSeparated(a: std.mem.Allocator, names: []const []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    for (names) |n| {
        try out.appendSlice(n);
        try out.append(0);
    }
    return out.toOwnedSlice();
}

/// The lines of the tests file that end in a newline (a last line without one is
/// not read, as `while read` does).
pub fn testSources(a: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).init(a);
    var rest = text;
    while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
        try out.append(rest[0..nl]);
        rest = rest[nl + 1 ..];
    }
    return out.toOwnedSlice();
}

/// A report or record path as covcheck takes it: `=<path>` when the path holds
/// `=` (covcheck reads `PKGDIR=FILE` otherwise).
pub fn inputArg(a: std.mem.Allocator, abs_path: []const u8) ![]u8 {
    return if (std.mem.indexOfScalar(u8, abs_path, '=') != null) std.fmt.allocPrint(a, "={s}", .{abs_path}) else a.dupe(u8, abs_path);
}

/// The name in `label` that precedes the first space, after its last colon: the
/// library the banner says is not produced.
pub fn libraryName(label: []const u8) []const u8 {
    const first = label[0 .. std.mem.indexOfScalar(u8, label, ' ') orelse label.len];
    return if (std.mem.lastIndexOfScalar(u8, first, ':')) |c| first[c + 1 ..] else first;
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("cov_gate: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn abs(a: std.mem.Allocator, cwd: []const u8, p: []const u8) []u8 {
    return (if (std.fs.path.isAbsolute(p)) a.dupe(u8, p) else std.fs.path.join(a, &.{ cwd, p })) catch die("out of memory", .{});
}

pub fn exitCodeOf(term: std.process.Child.Term) u8 {
    return switch (term) {
        .Exited => |c| c,
        .Signal => |s| @truncate(128 +% s),
        else => 1,
    };
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len < 12) die("usage error", .{});
    const cwd = try std.fs.cwd().realpathAlloc(a, ".");
    const here = std.fs.path.dirname(try std.fs.selfExePathAlloc(a)) orelse ".";
    const bb = abs(a, cwd, argv[1]);
    const label = argv[2];
    const package = argv[3];
    const mode_s = argv[4];
    const target = argv[5];
    const root = abs(a, cwd, argv[6]);
    const tests_path = abs(a, cwd, argv[7]);
    const held = abs(a, cwd, argv[8]);
    const result = abs(a, cwd, argv[9]);
    const summary = abs(a, cwd, argv[10]);
    const marker = abs(a, cwd, argv[11]);
    var diag: []const u8 = "";
    const tail = parseTail(a, package, argv[12..], &diag) catch die("{s}", .{diag});
    _ = std.meta.stringToEnum(Mode, mode_s) orelse die("mode '{s}' is not census, neutral or enforce", .{mode_s});
    if (!validTarget(target)) die("target '{s}' is not a number of basis points", .{target});
    if (!validPackage(package)) die("package '{s}' is not a repository directory", .{package});

    const env_scratch = std.process.getEnvVarOwned(a, "BUCK_SCRATCH_PATH") catch "";
    const k = if (env_scratch.len == 0)
        try std.fs.path.join(a, &.{ cwd, ".cov_gate" })
    else if (std.fs.path.isAbsolute(env_scratch))
        try std.fs.path.join(a, &.{ env_scratch, "cov_gate" })
    else
        try std.fs.path.join(a, &.{ cwd, env_scratch, "cov_gate" });
    const bin = try std.fs.path.join(a, &.{ k, "bin" });
    try std.fs.cwd().makePath(bin);
    var env = try std.process.getEnvMap(a);
    var install = std.process.Child.init(&.{ bb, "--install", "-s", bin }, a);
    install.env_map = &env;
    const installed = install.spawnAndWait() catch |e| die("cannot run {s}: {s}", .{ bb, @errorName(e) });
    if (exitCodeOf(installed) != 0) die("{s} --install -s {s} failed", .{ bb, bin });
    try env.put("PATH", bin);
    try env.put("LC_ALL", "C");
    env.remove("LD_LIBRARY_PATH");
    env.remove("LD_PRELOAD");

    const buck = if (std.mem.eql(u8, package, "(root)")) try std.fs.path.join(a, &.{ root, "BUCK" }) else try std.fs.path.join(a, &.{ root, package, "BUCK" });
    const bs = std.fs.cwd().statFile(buck) catch null;
    if (bs == null or bs.?.kind != .file) die("{s}: the staged sources have no BUCK file at {s}", .{ label, package });

    var root_dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
    defer root_dir.close();
    const repo_path = try std.fs.path.join(a, &.{ k, "repo_files" });
    {
        const f = try std.fs.cwd().createFile(repo_path, .{});
        defer f.close();
        try f.writeAll(try nulSeparated(a, try repoFiles(a, root_dir)));
    }

    var args = std.ArrayList([]const u8).init(a);
    try args.append(try std.fs.path.join(a, &.{ here, "covcheck", "covcheck" }));
    try args.appendSlice(&.{ "gate", "--package", package, "--repo-files", repo_path, "--source-root", root });
    try args.appendSlice(&.{ "--held", try std.fmt.allocPrint(a, "={s}", .{held}), "--mode", mode_s, "--target-bp", target });
    try args.appendSlice(&.{ "--result-out", result, "--summary-out", summary });
    for (tail.inputs) |in| {
        try args.append(in.flag);
        try args.append(try inputArg(a, abs(a, cwd, in.path)));
    }
    const tests_text = std.fs.cwd().readFileAlloc(a, tests_path, 1 << 24) catch |e| die("cannot read {s}: {s}", .{ tests_path, @errorName(e) });
    for ((try testSources(a, tests_text))[0..0]) |t| {
        try args.append("--test-source");
        try args.append(t);
    }
    if (tail.info) |i| {
        try args.append("--info-package");
        try args.append(i);
    }

    var child = std.process.Child.init(args.items, a);
    child.env_map = &env;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    var out_buf = std.ArrayList(u8).init(a);
    var err_buf = std.ArrayList(u8).init(a);
    try child.collectOutput(&out_buf, &err_buf, 1 << 28);
    const rc = exitCodeOf(try child.wait());
    // (stdout then stderr: the script sent both to one file; covcheck writes
    // its message to one of them.)
    var both = std.ArrayList(u8).init(a);
    try both.appendSlice(out_buf.items);
    try both.appendSlice(err_buf.items);

    switch (rc) {
        0 => {
            const f = try std.fs.cwd().createFile(marker, .{});
            defer f.close();
            try f.writer().print("PASS {s} ({s})\n", .{ label, mode_s });
        },
        3 => {
            const bar = "==================================================================";
            std.debug.print("{s}\nCOVERAGE GATE FAILED ({s}): {s} ({s}): covcheck gate exited 3\n", .{ bar, mode_s, package, label });
            std.debug.print("The conda package ({s}_conda) is not produced until its coverage meets the policy;\n", .{libraryName(label)});
            std.debug.print("the library and its dependents still build.\n{s}\n", .{bar});
            std.debug.print("{s}", .{std.fs.cwd().readFileAlloc(a, summary, 1 << 24) catch ""});
            std.debug.print("{s}", .{both.items});
            std.process.exit(1);
        },
        else => {
            const bar = "==================================================================";
            std.debug.print("{s}", .{both.items});
            std.debug.print("{s}\nCOVERAGE GATE ERROR: {s} ({s}): covcheck exited {d} (its message is above)\n{s}\n", .{ bar, package, label, rc, bar });
            std.process.exit(1);
        },
    }
    std.fs.cwd().deleteTree(k) catch {};
}
