//! pypi_smoke: the command line of the PyPI publish workflow (.github/workflows/pypi.yml): the TestPyPI half on
//! every merge that changes more than documentation (the user test of the wheel file, the upload to TestPyPI and the smoke of what it serves) and the
//! promotion of a file that passed it to PyPI.
//!
//!   pypi_smoke dist --wheel <file.whl> --out <dir> --record <file> --github-output <file>
//!   pypi_smoke state --index <testpypi|pypi> --dist <dir> --github-output <file>
//!   pypi_smoke present --index <testpypi|pypi> --name-file <path> --github-output <file>
//!   pypi_smoke verify --index <testpypi|pypi> --dist <dir> [--attempts <n>] [--delay <seconds>]
//!   pypi_smoke install --index <testpypi|pypi|dist> --dist <dir> --python <exe> --example <file> --expect <file>
//!                      --abi-table <file> --work <dir> [--attempts <n>] [--delay <seconds>]
//!   pypi_smoke matrix --pythons <file> --platform <name> --github-output <file>
//!   pypi_smoke storage --index <testpypi|pypi> --project <name> --limit-gib <1..1000> --over-percent <1..100>
//!                      --summary <file> --github-output <file>
//!   pypi_smoke promote --record <file> --out <dir> --github-output <file>
//!
//! `dist` names the wheel the build made as the index will (meta.zig), puts it alone in a directory and writes
//! `--record`, one line `<file name> <sha256> <size>` of the wheel (the record `promote` holds a download to);
//! `storage` sums the sizes of every file of every release of a project on an index (storage.zig), appends a
//! bullet to `--summary` and `over=<true|false>` and `bytes=<total>` to the output file, and prints an error
//! annotation when the project is over `--over-percent` of `--limit-gib` GiB (the command still exits 0: the
//! workflow's result job turns the run red from `over`); `promote` holds a record to TestPyPI and PyPI
//! (promote.zig), downloads the recorded file from TestPyPI into `--out` and appends `version`, `filename` and
//! `skipped` (the newer TestPyPI versions of the same tag that have no record, oldest first); `state`
//! says whether an index already holds that file (index.zig `lookup`); `present` says, from a file holding the
//! one-line name of a wheel (`<name>-<version>-<tag>.whl`) and before anything is built, whether the index's
//! release lists a file of exactly that name (index.zig `hasFile`) and appends `present=true` or
//! `present=false`; `verify` and `install` are the smoke
//! (index.zig `verify`, install.zig); `install --index dist` installs the wheel of the dist directory itself, with
//! no index and one attempt (a directory does not lag: `--attempts` and `--delay` are refused with it); `matrix`
//! reads the list of supported Pythons the build wrote for a platform (`//python:supported_pythons[<platform>]`,
//! matrix.zig) and appends `matrix=<the job matrix of the platform as JSON>`. Every step prints `pypi_smoke: ...`; a refusal prints
//! `pypi_smoke: FAILED: <why>` on stderr and `::error title=pypi::<why on one line>` on stdout for the GitHub
//! log; the exit status is 0 when the step held, 1 when it refused or failed, 2 for a usage error. Outputs for
//! later steps are appended to the file `--github-output` names. Everything is a flag; no environment is read.
const std = @import("std");
const common = @import("common.zig");
const meta = @import("meta.zig");
const index = @import("index.zig");
const install = @import("install.zig");
const matrix = @import("matrix.zig");
const promote = @import("promote.zig");
const storage = @import("storage.zig");
const rbf = @import("release_beta_fetch");

const Allocator = std.mem.Allocator;

/// What the commands reach outside the process through, so the cases give them in-memory ones.
pub const Deps = struct {
    fetcher: rbf.Fetcher,
    runner: install.Runner,
};

pub const usage =
    \\usage: pypi_smoke dist --wheel <file.whl> --out <dir> --record <file> --github-output <file>
    \\       pypi_smoke state --index <testpypi|pypi> --dist <dir> --github-output <file>
    \\       pypi_smoke present --index <testpypi|pypi> --name-file <path> --github-output <file>
    \\       pypi_smoke verify --index <testpypi|pypi> --dist <dir> [--attempts <n>] [--delay <seconds>]
    \\       pypi_smoke install --index <testpypi|pypi|dist> --dist <dir> --python <exe> --example <file> --expect <file>
    \\                          --abi-table <file> --work <dir> [--attempts <n>] [--delay <seconds>]
    \\       pypi_smoke matrix --pythons <file> --platform <name> --github-output <file>
    \\       pypi_smoke storage --index <testpypi|pypi> --project <name> --limit-gib <1..1000> --over-percent <1..100>
    \\                          --summary <file> --github-output <file>
    \\       pypi_smoke promote --record <file> --out <dir> --github-output <file>
    \\
;

const Parsed = struct {
    values: []?[]const u8,

    fn get(self: Parsed, k: usize) []const u8 {
        return self.values[k].?;
    }
};

/// The flags of one command: `names`, each given once; the first `required` must be there. Null after the usage
/// error was written to `err`.
fn parseFlags(a: Allocator, args: []const []const u8, names: []const []const u8, required: usize, err: *std.Io.Writer) !?Parsed {
    const values = try a.alloc(?[]const u8, names.len);
    @memset(values, null);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        var slot: ?*?[]const u8 = null;
        for (names, 0..) |n, k| {
            if (std.mem.eql(u8, flag, n)) slot = &values[k];
        }
        if (slot == null) {
            try err.print("pypi_smoke: unknown argument {s}\n{s}", .{ flag, usage });
            try err.flush();
            return null;
        }
        i += 1;
        if (i >= args.len or (slot.?.* != null)) {
            try err.print("pypi_smoke: {s} needs one value, given once\n", .{flag});
            try err.flush();
            return null;
        }
        slot.?.* = args[i];
    }
    var complete = true;
    for (values[0..required]) |v| {
        if (v == null) complete = false;
    }
    if (!complete) {
        try err.writeAll(usage);
        try err.flush();
        return null;
    }
    return .{ .values = values };
}

fn parseNumber(s: []const u8, max: u64) ?u64 {
    const v = std.fmt.parseInt(u64, s, 10) catch return null;
    return if (v <= max) v else null;
}

const Pace = struct { attempts: u32, delay_ms: u64 };

fn paceOf(err: *std.Io.Writer, attempts: ?[]const u8, delay: ?[]const u8) !?Pace {
    const n = parseNumber(attempts orelse "5", 20);
    if (n == null or n.? == 0) {
        try err.writeAll("pypi_smoke: --attempts is a number from 1 to 20\n");
        try err.flush();
        return null;
    }
    const d = parseNumber(delay orelse "30", 300) orelse {
        try err.writeAll("pypi_smoke: --delay is a number of seconds from 0 to 300\n");
        try err.flush();
        return null;
    };
    return .{ .attempts = @intCast(n.?), .delay_ms = d * 1000 };
}

fn indexOf(err: *std.Io.Writer, name: []const u8) !?common.Index {
    if (common.indexNamed(name)) |idx| return idx;
    try err.writeAll("pypi_smoke: --index is testpypi or pypi\n");
    try err.flush();
    return null;
}

/// `text` as one line of a GitHub workflow command: its lines joined by ` | `, and `%` and carriage returns
/// escaped as the command syntax wants.
fn oneLine(a: Allocator, text: []const u8) ![]const u8 {
    var parts = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t\r");
        if (t.len != 0) try parts.append(a, t);
    }
    const joined = try std.mem.join(a, " | ", parts.items);
    const escaped = try std.mem.replaceOwned(u8, a, joined, "%", "%25");
    return std.mem.replaceOwned(u8, a, escaped, "\r", "%0D");
}

/// A refusal or a failure: `pypi_smoke: FAILED: <why>` on `err`, the error annotation on `out`, exit status 1.
fn failed(a: Allocator, out: *std.Io.Writer, err: *std.Io.Writer, e: anyerror, why: []const u8) !u8 {
    const msg = if (e == error.Refused) why else @errorName(e);
    try out.flush();
    try err.print("pypi_smoke: FAILED: {s}\n", .{msg});
    try err.flush();
    try out.print("::error title=pypi::{s}\n", .{try oneLine(a, msg)});
    try out.flush();
    return 1;
}

fn failedText(a: Allocator, out: *std.Io.Writer, err: *std.Io.Writer, comptime fmt: []const u8, args: anytype) !u8 {
    const why = try std.fmt.allocPrint(a, fmt, args);
    return failed(a, out, err, error.Refused, why);
}

fn cmdDist(a: Allocator, args: []const []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    const names = [_][]const u8{ "--wheel", "--out", "--record", "--github-output" };
    const p = (try parseFlags(a, args, &names, 4, err)) orelse return 2;
    var why: []const u8 = "";
    const wheel = meta.loadWheelFile(a, &why, p.get(0)) catch |e| return failed(a, out, err, e, why);
    meta.writeDist(a, &why, wheel, p.get(1)) catch |e| return failed(a, out, err, e, why);
    const record = try std.fmt.allocPrint(a, "{s} {s} {d}\n", .{ wheel.file_name, &wheel.sha256, wheel.bytes.len });
    std.fs.cwd().writeFile(.{ .sub_path = p.get(2), .data = record }) catch |e|
        return failedText(a, out, err, "cannot write --record {s}: {s}", .{ p.get(2), @errorName(e) });
    const lines = try std.fmt.allocPrint(a, "version={s}\nfilename={s}\nsha256={s}\n", .{ wheel.version, wheel.file_name, &wheel.sha256 });
    common.appendFile(p.get(3), lines) catch |e|
        return failedText(a, out, err, "cannot write --github-output {s}: {s}", .{ p.get(3), @errorName(e) });
    try out.print("pypi_smoke: {s} ({d} bytes, sha256 {s}) is version {s} of {s}; written to {s}\n", .{ wheel.file_name, wheel.bytes.len, &wheel.sha256, wheel.version, wheel.name, p.get(1) });
    try out.flush();
    return 0;
}

fn cmdState(a: Allocator, args: []const []const u8, deps: Deps, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    const names = [_][]const u8{ "--index", "--dist", "--github-output" };
    const p = (try parseFlags(a, args, &names, 3, err)) orelse return 2;
    const idx = (try indexOf(err, p.get(0))) orelse return 2;
    var why: []const u8 = "";
    const wheel = meta.loadDist(a, &why, p.get(1)) catch |e| return failed(a, out, err, e, why);
    const found = index.lookup(a, &why, deps.fetcher, idx, wheel) catch |e| return failed(a, out, err, e, why);
    common.appendFile(p.get(2), try std.fmt.allocPrint(a, "state={s}\n", .{@tagName(found.state)})) catch |e|
        return failedText(a, out, err, "cannot write --github-output {s}: {s}", .{ p.get(2), @errorName(e) });
    const text = try index.stateNotice(a, found, idx, wheel);
    if (found.state == .absent) {
        try out.print("pypi_smoke: {s}\n", .{text});
    } else {
        try out.print("::notice title=pypi::{s}\n", .{text});
    }
    try out.flush();
    return 0;
}

fn cmdPresent(a: Allocator, args: []const []const u8, deps: Deps, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    const names = [_][]const u8{ "--index", "--name-file", "--github-output" };
    const p = (try parseFlags(a, args, &names, 3, err)) orelse return 2;
    const idx = (try indexOf(err, p.get(0))) orelse return 2;
    const text = std.fs.cwd().readFileAlloc(a, p.get(1), 4096) catch |e|
        return failedText(a, out, err, "cannot read --name-file {s}: {s}", .{ p.get(1), @errorName(e) });
    var why: []const u8 = "";
    const file = meta.parseFileName(a, &why, text) catch |e| return failed(a, out, err, e, why);
    const file_name = std.mem.trimRight(u8, text, "\n");
    const there = index.hasFile(a, &why, deps.fetcher, idx, file, file_name) catch |e| return failed(a, out, err, e, why);
    common.appendFile(p.get(2), if (there) "present=true\n" else "present=false\n") catch |e|
        return failedText(a, out, err, "cannot write --github-output {s}: {s}", .{ p.get(2), @errorName(e) });
    try out.print("::notice title=pypi::{s} is {s}{s}{s}\n", .{ file_name, if (there) "on " else "not on ", idx.name, if (there) " already" else "" });
    try out.flush();
    return 0;
}

fn cmdVerify(a: Allocator, args: []const []const u8, deps: Deps, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    const names = [_][]const u8{ "--index", "--dist", "--attempts", "--delay" };
    const p = (try parseFlags(a, args, &names, 2, err)) orelse return 2;
    const idx = (try indexOf(err, p.get(0))) orelse return 2;
    const pace = (try paceOf(err, p.values[2], p.values[3])) orelse return 2;
    var why: []const u8 = "";
    const wheel = meta.loadDist(a, &why, p.get(1)) catch |e| return failed(a, out, err, e, why);
    const rep = index.verify(a, &why, deps.fetcher, idx, wheel, pace.attempts, pace.delay_ms, out) catch |e| return failed(a, out, err, e, why);
    try out.print("pypi_smoke: {s} serves {s} as built (sha256 {s}, {d} bytes, METADATA Name, Version, Requires-Python and Requires-Dist equal)\n", .{ idx.name, wheel.file_name, &rep.sha256, rep.size });
    try out.flush();
    return 0;
}

fn cmdInstall(a: Allocator, args: []const []const u8, deps: Deps, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    const names = [_][]const u8{ "--index", "--dist", "--python", "--example", "--expect", "--abi-table", "--work", "--attempts", "--delay" };
    const p = (try parseFlags(a, args, &names, 7, err)) orelse return 2;
    const from_dist = std.mem.eql(u8, p.get(0), "dist");
    if (!from_dist and common.indexNamed(p.get(0)) == null) {
        try err.writeAll("pypi_smoke: --index is testpypi, pypi or dist\n");
        try err.flush();
        return 2;
    }
    if (from_dist and (p.values[7] != null or p.values[8] != null)) {
        try err.writeAll("pypi_smoke: --attempts and --delay are for an index; --index dist installs once\n");
        try err.flush();
        return 2;
    }
    const pace = if (from_dist) Pace{ .attempts = 1, .delay_ms = 0 } else (try paceOf(err, p.values[7], p.values[8])) orelse return 2;
    var why: []const u8 = "";
    const wheel = meta.loadDist(a, &why, p.get(1)) catch |e| return failed(a, out, err, e, why);
    // pip runs in the work directory, so it is given the dist directory's absolute path
    const source: install.Source = if (from_dist) .{
        .dist = std.fs.cwd().realpathAlloc(a, p.get(1)) catch |e|
            return failedText(a, out, err, "cannot resolve --dist {s}: {s}", .{ p.get(1), @errorName(e) }),
    } else .{ .index = common.indexNamed(p.get(0)).? };
    const opts = install.Options{
        .source = source,
        .python = p.get(2),
        .example = p.get(3),
        .expect = p.get(4),
        .abi_table = p.get(5),
        .work = p.get(6),
        .attempts = pace.attempts,
        .delay_ms = pace.delay_ms,
    };
    install.run(a, &why, deps.runner, opts, wheel, out) catch |e| return failed(a, out, err, e, why);
    const from = switch (source) {
        .index => |idx| idx.name,
        .dist => |dir| try std.fmt.allocPrint(a, "the dist directory {s}", .{dir}),
    };
    try out.print("pypi_smoke: pip installed {s}=={s} from {s} into an empty environment and {s} printed what {s} says\n", .{ wheel.name, wheel.version, from, opts.example, opts.expect });
    try out.flush();
    return 0;
}

fn cmdMatrix(a: Allocator, args: []const []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    const names = [_][]const u8{ "--pythons", "--platform", "--github-output" };
    const p = (try parseFlags(a, args, &names, 3, err)) orelse return 2;
    const platform = matrix.platformNamed(p.get(1)) orelse {
        try err.print("pypi_smoke: --platform is one of {s}\n", .{try matrix.platformNames(a)});
        try err.flush();
        return 2;
    };
    var why: []const u8 = "";
    const text = meta.readFile(a, &why, p.get(0), 1 << 20) catch |e| return failed(a, out, err, e, why);
    const versions = matrix.parse(a, &why, p.get(0), text) catch |e| return failed(a, out, err, e, why);
    const line = try std.fmt.allocPrint(a, "matrix={s}\n", .{try matrix.json(a, platform, versions)});
    common.appendFile(p.get(2), line) catch |e|
        return failedText(a, out, err, "cannot write --github-output {s}: {s}", .{ p.get(2), @errorName(e) });
    try out.print("pypi_smoke: the jobs of the {s} wheel run on {s} with Python {s}\n", .{ platform.name, platform.runner, try std.mem.join(a, ", ", versions) });
    try out.flush();
    return 0;
}

fn cmdStorage(a: Allocator, args: []const []const u8, deps: Deps, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    const names = [_][]const u8{ "--index", "--project", "--limit-gib", "--over-percent", "--summary", "--github-output" };
    const p = (try parseFlags(a, args, &names, 6, err)) orelse return 2;
    const idx = (try indexOf(err, p.get(0))) orelse return 2;
    const project_ok = p.get(1).len != 0 and for (p.get(1)) |c| {
        if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "._-", c) == null) break false;
    } else true;
    if (!project_ok) {
        try err.writeAll("pypi_smoke: --project is a project name: letters, digits, '.', '_' and '-'\n");
        try err.flush();
        return 2;
    }
    const limit = parseNumber(p.get(2), 1000);
    if (limit == null or limit.? == 0) {
        try err.writeAll("pypi_smoke: --limit-gib is a number from 1 to 1000\n");
        try err.flush();
        return 2;
    }
    const over = parseNumber(p.get(3), 100);
    if (over == null or over.? == 0) {
        try err.writeAll("pypi_smoke: --over-percent is a number from 1 to 100\n");
        try err.flush();
        return 2;
    }
    var why: []const u8 = "";
    const rep = storage.measure(a, &why, deps.fetcher, .{ .idx = idx, .project = p.get(1), .limit_gib = limit.?, .over_percent = over.? }) catch |e| return failed(a, out, err, e, why);
    common.appendFile(p.get(4), rep.bullet) catch |e|
        return failedText(a, out, err, "cannot write --summary {s}: {s}", .{ p.get(4), @errorName(e) });
    const lines = try std.fmt.allocPrint(a, "over={s}\nbytes={d}\n", .{ if (rep.over) "true" else "false", rep.totals.bytes });
    common.appendFile(p.get(5), lines) catch |e|
        return failedText(a, out, err, "cannot write --github-output {s}: {s}", .{ p.get(5), @errorName(e) });
    try out.writeAll(rep.log);
    try out.flush();
    return 0;
}

fn cmdPromote(a: Allocator, args: []const []const u8, deps: Deps, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    const names = [_][]const u8{ "--record", "--out", "--github-output" };
    const p = (try parseFlags(a, args, &names, 3, err)) orelse return 2;
    var why: []const u8 = "";
    const res = promote.check(a, &why, deps.fetcher, p.get(0), p.get(1), out) catch |e| return failed(a, out, err, e, why);
    const rec = res.record;
    const lines = try std.fmt.allocPrint(a, "version={s}\nfilename={s}\nskipped={s}\n", .{ rec.parsed.version, rec.file_name, try std.mem.join(a, ", ", res.skipped) });
    // the output file is tried first, so a file that cannot be written leaves --out empty
    common.appendFile(p.get(2), lines) catch |e|
        return failedText(a, out, err, "cannot write --github-output {s}: {s}", .{ p.get(2), @errorName(e) });
    promote.write(a, &why, res, p.get(1)) catch |e| return failed(a, out, err, e, why);
    for (res.skipped) |v| try out.print("::notice title=pypi::{s} {s} is on TestPyPI with no record that its TestPyPI smoke passed (the smoke failed, or its run has not ended): not promoted\n", .{ rec.parsed.name, v });
    try out.print("pypi_smoke: promoting {s} {s}: {s} (sha256 {s}, {d} bytes) downloaded from TestPyPI, as recorded\n", .{ rec.parsed.name, rec.parsed.version, rec.file_name, rec.sha256, rec.size });
    try out.flush();
    return 0;
}

/// The command line after the program's name. Returns the exit status.
pub fn run(a: Allocator, args: []const []const u8, deps: Deps, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    if (args.len >= 1) {
        const rest = args[1..];
        if (std.mem.eql(u8, args[0], "dist")) return cmdDist(a, rest, out, err);
        if (std.mem.eql(u8, args[0], "state")) return cmdState(a, rest, deps, out, err);
        if (std.mem.eql(u8, args[0], "present")) return cmdPresent(a, rest, deps, out, err);
        if (std.mem.eql(u8, args[0], "verify")) return cmdVerify(a, rest, deps, out, err);
        if (std.mem.eql(u8, args[0], "install")) return cmdInstall(a, rest, deps, out, err);
        if (std.mem.eql(u8, args[0], "matrix")) return cmdMatrix(a, rest, out, err);
        if (std.mem.eql(u8, args[0], "storage")) return cmdStorage(a, rest, deps, out, err);
        if (std.mem.eql(u8, args[0], "promote")) return cmdPromote(a, rest, deps, out, err);
    }
    try err.writeAll(usage);
    try err.flush();
    return 2;
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ebuf: [1024]u8 = undefined;
    var err = std.fs.File.stderr().writer(&ebuf);
    var obuf: [1024]u8 = undefined;
    var out = std.fs.File.stdout().writer(&obuf);
    const argv = try std.process.argsAlloc(a);
    const rest = try a.alloc([]const u8, if (argv.len > 0) argv.len - 1 else 0);
    for (rest, argv[1..]) |*r, arg| r.* = arg;
    var http = rbf.Http{};
    var process = install.Process{};
    return run(a, rest, .{ .fetcher = http.fetcher(), .runner = process.runner() }, &out.interface, &err.interface);
}
