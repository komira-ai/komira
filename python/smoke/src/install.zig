//! pypi_smoke: what a user does with the published wheel, in an empty environment of the Python they have.
//!
//! In `<work>/venv`, made by `<python> -m venv`, with pip's isolated mode and no cache:
//!  1. from TestPyPI: the wheel's `Requires-Dist` requirements from the real index
//!     (`--only-binary=:all:`), so that nothing but komira comes from TestPyPI, then
//!     `komira==<version>` from TestPyPI with `--no-deps`; from PyPI: `komira==<version>` plainly. The komira
//!     install is repeated like `verify` (an index lags an upload); the requirements are not.
//!  2. `pip check` must exit 0, and `pip show komira` must report the version that was published.
//!  3. The example and its data files are copied (by base name) into `<work>/run` and the example is run there
//!     by `<work>/venv/bin/python -I`. It must exit 0 and print exactly the text of the expected file, in which
//!     `<version>` is the published version and `<abi_version>` is the engine's C ABI version, taken from the
//!     first line of the ABI table (`version<TAB><major>.<minor>` is major * 1000 + minor).
//! A step that fails is named with its command, its exit status and the last lines of its stderr; a program
//! that prints another text is shown beside the expected one, in full.
//!
//! Commands run through a `Runner`, so the cases run a pip in memory; the real one is a child process with the
//! environment of this one.
const std = @import("std");
const common = @import("common.zig");
const meta = @import("meta.zig");

const Allocator = common.Allocator;
const Error = common.Error;
const refuse = common.refuse;

/// The most of a command's stdout and stderr a run keeps (pip prints a line per file).
pub const max_output_bytes: usize = 16 * 1024 * 1024;

/// How a command ended.
pub const Ran = struct {
    /// The exit status; null when the command did not exit (a signal, or stopped).
    code: ?u8,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
};

/// Runs `argv` in `cwd`. An error is a command that could not be started or read.
pub const Runner = struct {
    ctx: *anyopaque,
    runFn: *const fn (ctx: *anyopaque, a: Allocator, argv: []const []const u8, cwd: []const u8) anyerror!Ran,

    pub fn run(self: Runner, a: Allocator, argv: []const []const u8, cwd: []const u8) anyerror!Ran {
        return self.runFn(self.ctx, a, argv, cwd);
    }
};

/// The runner of the command line: a child process with the environment of this one, no stdin, and stdout and
/// stderr kept up to `max_output` bytes each (more is an error of the run).
pub const Process = struct {
    max_output: usize = max_output_bytes,

    pub fn runner(self: *Process) Runner {
        return .{ .ctx = self, .runFn = runChild };
    }

    fn runChild(ctx: *anyopaque, a: Allocator, argv: []const []const u8, cwd: []const u8) anyerror!Ran {
        const self: *Process = @ptrCast(@alignCast(ctx));
        const r = try std.process.Child.run(.{ .allocator = a, .argv = argv, .cwd = cwd, .max_output_bytes = self.max_output });
        const code: ?u8 = switch (r.term) {
            .Exited => |c| c,
            else => null,
        };
        return .{ .code = code, .stdout = r.stdout, .stderr = r.stderr };
    }
};

pub const Options = struct {
    index: common.Index,
    python: []const u8,
    example: []const u8,
    expect: []const u8,
    data: []const []const u8,
    abi_table: []const u8,
    work: []const u8,
    attempts: u32,
    delay_ms: u64,
};

/// How many lines of a failed command's stderr a refusal shows.
const stderr_lines: usize = 12;

/// The C ABI version `table_text` (the ABI table at `path`) names on its first line: `version<TAB><major>.<minor>`
/// is major * 1000 + minor.
pub fn abiVersion(a: Allocator, why: *[]const u8, path: []const u8, table_text: []const u8) Error!u32 {
    const first = std.mem.trimRight(u8, table_text[0 .. std.mem.indexOfScalar(u8, table_text, '\n') orelse table_text.len], "\r");
    var tab = std.mem.splitScalar(u8, first, '\t');
    const key = tab.next() orelse "";
    const value = tab.next() orelse "";
    if (tab.next() == null and std.mem.eql(u8, key, "version")) {
        var dot = std.mem.splitScalar(u8, value, '.');
        const major = std.fmt.parseInt(u32, dot.next() orelse "", 10) catch null;
        const minor = std.fmt.parseInt(u32, dot.next() orelse "", 10) catch null;
        if (dot.next() == null and major != null and minor != null and minor.? <= 999 and major.? <= 1000)
            return major.? * 1000 + minor.?;
    }
    return refuse(a, why, "the first line of {s} is '{s}', not `version<TAB><major>.<minor>`", .{ path, first });
}

/// The expected text with `<version>` and `<abi_version>` replaced.
pub fn expectedText(a: Allocator, text: []const u8, version: []const u8, abi: u32) Error![]u8 {
    const with_version = try std.mem.replaceOwned(u8, a, text, "<version>", version);
    const abi_text = try std.fmt.allocPrint(a, "{d}", .{abi});
    return std.mem.replaceOwned(u8, a, with_version, "<abi_version>", abi_text);
}

fn join(a: Allocator, base: []const []const u8, more: []const []const u8) Error![]const []const u8 {
    return std.mem.concat(a, []const u8, &.{ base, more });
}

/// Runs one command; the answer when it exited 0, else a refusal naming the step.
fn step(a: Allocator, why: *[]const u8, runner: Runner, name: []const u8, argv: []const []const u8, cwd: []const u8, log: *std.Io.Writer) !Ran {
    const shown = try std.mem.join(a, " ", argv);
    try log.print("pypi_smoke: {s}: {s}\n", .{ name, shown });
    try log.flush();
    const ran = runner.run(a, argv, cwd) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return refuse(a, why, "{s}: `{s}` could not run: {s}", .{ name, shown, @errorName(e) });
    };
    const tail = try common.lastLines(a, ran.stderr, stderr_lines);
    const code = ran.code orelse
        return refuse(a, why, "{s}: `{s}` did not exit (killed by a signal); last lines of stderr:\n{s}", .{ name, shown, tail });
    if (code != 0) return refuse(a, why, "{s}: `{s}` exited with {d}; last lines of stderr:\n{s}", .{ name, shown, code, tail });
    return ran;
}

/// Copies the example and its data files into `run_dir`, each under its base name.
fn stageRun(a: Allocator, why: *[]const u8, opts: Options, run_dir: []const u8) Error!void {
    std.fs.cwd().makePath(run_dir) catch |e| return refuse(a, why, "cannot make {s}: {s}", .{ run_dir, @errorName(e) });
    var seen = std.ArrayList([]const u8).empty;
    const sources = try join(a, &.{opts.example}, opts.data);
    for (sources) |src| {
        const base = std.fs.path.basename(src);
        for (seen.items) |s| {
            if (std.mem.eql(u8, s, base)) return refuse(a, why, "two files to copy are named {s}", .{base});
        }
        try seen.append(a, base);
        const dest = try std.fs.path.join(a, &.{ run_dir, base });
        std.fs.cwd().copyFile(src, std.fs.cwd(), dest, .{}) catch |e|
            return refuse(a, why, "cannot copy {s} to {s}: {s}", .{ src, dest, @errorName(e) });
    }
}

/// The version `pip show` printed.
fn shownVersion(text: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "Version: ")) return line["Version: ".len..];
    }
    return null;
}

/// `install` (header). `wheel` is the dist wheel: it names the package and its version and its requirements.
pub fn run(a: Allocator, why: *[]const u8, runner: Runner, opts: Options, wheel: meta.Wheel, log: *std.Io.Writer) !void {
    try common.requireFreeDir(a, why, "--work", opts.work);
    const abi_text = try meta.readFile(a, why, opts.abi_table, 1 << 20);
    const abi = try abiVersion(a, why, opts.abi_table, abi_text);
    const expected = try expectedText(a, try meta.readFile(a, why, opts.expect, 1 << 20), wheel.version, abi);
    const run_dir = try std.fs.path.join(a, &.{ opts.work, "run" });
    try stageRun(a, why, opts, run_dir);

    const venv = try std.fs.path.join(a, &.{ opts.work, "venv" });
    const venv_python = try std.fs.path.join(a, &.{ venv, "bin", "python" });
    _ = try step(a, why, runner, "create the virtual environment", &.{ opts.python, "-m", "venv", venv }, opts.work, log);
    const pip = [_][]const u8{ venv_python, "-m", "pip", "--isolated", "--disable-pip-version-check" };
    const install_flags = [_][]const u8{ "install", "--no-cache-dir", "--only-binary=:all:" };
    const install = try join(a, &pip, &install_flags);

    const pin = try std.fmt.allocPrint(a, "{s}=={s}", .{ wheel.name, wheel.version });
    var komira_args: []const []const u8 = undefined;
    if (std.mem.eql(u8, opts.index.simple, common.dependency_index)) {
        komira_args = try join(a, install, &.{ "--index-url", opts.index.simple, pin });
    } else {
        if (wheel.requires_dist.len != 0) {
            const deps = try join(a, install, &.{ "--index-url", common.dependency_index });
            _ = try step(a, why, runner, "install the requirements from PyPI", try join(a, deps, wheel.requires_dist), opts.work, log);
        }
        komira_args = try join(a, install, &.{ "--no-deps", "--index-url", opts.index.simple, pin });
    }
    var n: u32 = 0;
    while (true) {
        n += 1;
        _ = step(a, why, runner, "install komira", komira_args, opts.work, log) catch |e| {
            if (e != error.Refused or n >= opts.attempts) return e;
            try log.print("attempt {d} of {d} failed, trying again: {s}\n", .{ n, opts.attempts, why.* });
            try log.flush();
            std.Thread.sleep(opts.delay_ms * std.time.ns_per_ms);
            continue;
        };
        break;
    }

    _ = try step(a, why, runner, "check the installed requirements", try join(a, &pip, &.{"check"}), opts.work, log);
    const shown = try step(a, why, runner, "show the installed komira", try join(a, &pip, &.{ "show", wheel.name }), opts.work, log);
    const installed = shownVersion(shown.stdout) orelse "(none)";
    if (!std.mem.eql(u8, installed, wheel.version))
        return refuse(a, why, "pip show {s} reports version {s}, not {s}", .{ wheel.name, installed, wheel.version });

    const example = std.fs.path.basename(opts.example);
    const ran = try step(a, why, runner, "run the example", &.{ venv_python, "-I", example }, run_dir, log);
    if (!std.mem.eql(u8, ran.stdout, expected))
        return refuse(a, why, "{s} printed other text than {s} says\nexpected:\n{s}\noutput:\n{s}\nstderr:\n{s}", .{ example, opts.expect, expected, ran.stdout, ran.stderr });
}
