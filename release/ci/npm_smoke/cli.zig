//! npm_smoke: the command line of the npm release (//release:npm_packages and .github/workflows/npm.yml;
//! docs/ci.md, "npm.yml: publishing the npm packages").
//!
//!   npm_smoke set --main <name> --require-stamped <true|false> --out <file> --package <name>=<tarball> ...
//!   npm_smoke gate --file <path> --github-output <file>
//!   npm_smoke verify --set <file> --dir <dir> --github-output <file> [--built <file>]
//!   npm_smoke publish --set <file> --dir <dir> --node <exe> --npm <dir> --work <dir>
//!   npm_smoke smoke --set <file> --node <exe> --npm <dir> --work <dir> [--attempts <n>] [--delay <seconds>]
//!
//! `set` is the build action of //release:npm_packages: it writes npm_set.json (set.zig) for the tarballs
//! given, one `--package` per package (the flag is given once per package), the main package named by
//! `--main`; with `--require-stamped true` an unstamped set is refused.
//! `gate` reads the publish gate (gate.zig, release/npm_publish.txt) and appends `publish=true` or
//! `publish=false` to the output file.
//! `verify` holds a directory to the set it holds (set.zig `verifyDir`: exactly the set's tarballs and
//! npm_set.json, each with the set's SHA-256 and integrity), refuses an unstamped set, with `--built` refuses a
//! set other than the one at that path (the set the job built from the same stamp), and appends
//! `version=<the set's version>` to the output file.
//! `publish` does what `verify` does to the directory and then publishes it (publish.zig).
//! `smoke` installs the set's version from the registry and runs a query (smoke.zig); an unstamped set is
//! refused.
//!
//! Every step prints `npm_smoke: ...`; a refusal prints `npm_smoke: FAILED: <why>` on stderr and
//! `::error title=npm::<why>` (as a workflow command escapes it) on stdout; the exit status is 0 when the step
//! held, 1 when it refused or failed, 2 for a usage error, before anything is read or run. The paths `publish`
//! and `smoke` hand npm (`--dir`, `--node`, `--npm`, `--work`) are absolute, since npm runs in the work
//! directory. Everything is a flag; no environment is read.
const std = @import("std");
const common = @import("common.zig");
const gate = @import("gate.zig");
const npm = @import("npm.zig");
const publish = @import("publish.zig");
const set_mod = @import("set.zig");
const smoke = @import("smoke.zig");

const Allocator = std.mem.Allocator;

/// What the commands reach outside the process through, so the cases give them in-memory ones.
pub const Deps = struct {
    runner: npm.Runner,
    pause: smoke.Pause,
};

pub const usage =
    \\usage: npm_smoke set --main <name> --require-stamped <true|false> --out <file> --package <name>=<tarball> ...
    \\       npm_smoke gate --file <path> --github-output <file>
    \\       npm_smoke verify --set <file> --dir <dir> --github-output <file> [--built <file>]
    \\       npm_smoke publish --set <file> --dir <dir> --node <exe> --npm <dir> --work <dir>
    \\       npm_smoke smoke --set <file> --node <exe> --npm <dir> --work <dir> [--attempts <n>] [--delay <seconds>]
    \\
;

const Parsed = struct {
    values: []?[]const u8,
    /// The values of the one flag that may be given more than once, in order.
    repeated: []const []const u8,

    fn get(self: Parsed, k: usize) []const u8 {
        return self.values[k].?;
    }
};

fn usageError(err: *std.Io.Writer, comptime fmt: []const u8, args: anytype) !?Parsed {
    try err.print("npm_smoke: " ++ fmt ++ "\n", args);
    try err.writeAll(usage);
    try err.flush();
    return null;
}

/// The flags of one command: `names`, each given once (except `repeat`, which may be given any number of times
/// and at least once when it is not null); the first `required` must be there. Null after the usage error was
/// written to `err`.
fn parseFlags(a: Allocator, args: []const []const u8, names: []const []const u8, required: usize, repeat: ?[]const u8, err: *std.Io.Writer) !?Parsed {
    const values = try a.alloc(?[]const u8, names.len);
    @memset(values, null);
    var repeated = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        const repeats = if (repeat) |r| std.mem.eql(u8, flag, r) else false;
        var slot: ?*?[]const u8 = null;
        for (names, 0..) |n, k| {
            if (std.mem.eql(u8, flag, n)) slot = &values[k];
        }
        if (!repeats and slot == null) return usageError(err, "unknown argument {s}", .{flag});
        if (i + 1 >= args.len) return usageError(err, "{s} needs a value", .{flag});
        i += 1;
        if (repeats) {
            try repeated.append(a, args[i]);
            continue;
        }
        if (slot.?.* != null) return usageError(err, "{s} is given twice", .{flag});
        slot.?.* = args[i];
    }
    for (values[0..required], 0..) |v, k| {
        if (v == null) return usageError(err, "{s} is missing", .{names[k]});
    }
    if (repeat) |r| {
        if (repeated.items.len == 0) return usageError(err, "{s} is missing", .{r});
    }
    return .{ .values = values, .repeated = repeated.items };
}

/// Each of `flags` (indexes into `names`) that was given is an absolute path: npm runs in the work directory,
/// so a relative path would name another file there. Null when they are; else 2 after the usage error.
fn requireAbsolute(p: Parsed, names: []const []const u8, flags: []const usize, err: *std.Io.Writer) !?u8 {
    for (flags) |k| {
        const v = p.values[k] orelse continue;
        if (!std.fs.path.isAbsolute(v)) {
            _ = try usageError(err, "{s} is an absolute path, not {s}", .{ names[k], v });
            return 2;
        }
    }
    return null;
}

fn parseNumber(s: []const u8, max: u64) ?u64 {
    const v = std.fmt.parseInt(u64, s, 10) catch return null;
    return if (v <= max) v else null;
}

/// `why` as a workflow command's message: `%`, CR and LF escaped, so it is one line.
fn annotation(a: Allocator, why: []const u8) ![]const u8 {
    var w = std.Io.Writer.Allocating.init(a);
    for (why) |c| switch (c) {
        '%' => try w.writer.writeAll("%25"),
        '\r' => try w.writer.writeAll("%0D"),
        '\n' => try w.writer.writeAll("%0A"),
        else => try w.writer.writeByte(c),
    };
    return w.written();
}

fn failed(a: Allocator, out: *std.Io.Writer, err: *std.Io.Writer, why: []const u8) !u8 {
    try err.print("npm_smoke: FAILED: {s}\n", .{why});
    try err.flush();
    try out.print("::error title=npm::{s}\n", .{try annotation(a, why)});
    try out.flush();
    return 1;
}

fn appendOutput(a: Allocator, out: *std.Io.Writer, err: *std.Io.Writer, path: []const u8, text: []const u8) !?u8 {
    common.appendFile(path, text) catch |e|
        return try failed(a, out, err, try std.fmt.allocPrint(a, "cannot write --github-output {s}: {s}", .{ path, @errorName(e) }));
    return null;
}

fn cmdSet(a: Allocator, args: []const []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    const p = (try parseFlags(a, args, &.{ "--main", "--require-stamped", "--out" }, 3, "--package", err)) orelse return 2;
    const stamped = p.get(1);
    if (!std.mem.eql(u8, stamped, "true") and !std.mem.eql(u8, stamped, "false")) {
        _ = try usageError(err, "--require-stamped is true or false, not {s}", .{stamped});
        return 2;
    }
    var why: []const u8 = "";
    var inputs = std.ArrayList(set_mod.Input).empty;
    for (p.repeated) |spec| {
        const eq = std.mem.indexOfScalar(u8, spec, '=') orelse {
            _ = try usageError(err, "--package is <name>=<tarball>, not {s}", .{spec});
            return 2;
        };
        try inputs.append(a, .{ .name = spec[0..eq], .path = spec[eq + 1 ..], .bytes = "" });
    }
    for (inputs.items) |*in| {
        in.bytes = common.readFile(a, &why, "the tarball", in.path) catch |e| switch (e) {
            error.Refused => return failed(a, out, err, why),
            else => return e,
        };
    }
    const set = set_mod.build(a, &why, p.get(0), inputs.items, std.mem.eql(u8, stamped, "true")) catch |e| switch (e) {
        error.Refused => return failed(a, out, err, why),
        else => return e,
    };
    common.writeFile(a, &why, p.get(2), try set_mod.render(a, set)) catch |e| switch (e) {
        error.Refused => return failed(a, out, err, why),
        else => return e,
    };
    try out.print("npm_smoke: the set of {d} packages at {s}, {s} last\n", .{ set.packages.len, set.version, set.main });
    try out.flush();
    return 0;
}

fn cmdGate(a: Allocator, args: []const []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    const p = (try parseFlags(a, args, &.{ "--file", "--github-output" }, 2, null, err)) orelse return 2;
    var why: []const u8 = "";
    const g = blk: {
        const text = common.readFile(a, &why, "the publish gate", p.get(0)) catch |e| switch (e) {
            error.Refused => return failed(a, out, err, why),
            else => return e,
        };
        break :blk gate.parse(a, &why, p.get(0), text) catch |e| switch (e) {
            error.Refused => return failed(a, out, err, why),
            else => return e,
        };
    };
    const on = g == .on;
    if (try appendOutput(a, out, err, p.get(1), if (on) "publish=true\n" else "publish=false\n")) |code| return code;
    try out.print("npm_smoke: {s} says publish: {s}\n", .{ p.get(0), if (on) "on: the publish job runs" else "off: the publish job and the smoke are skipped" });
    try out.flush();
    return 0;
}

/// The set at `path`, stamped, with the directory `dir` holding exactly it; null after the refusal was written.
fn loadVerified(a: Allocator, out: *std.Io.Writer, err: *std.Io.Writer, path: []const u8, dir: []const u8) !?set_mod.Set {
    var why: []const u8 = "";
    const set = set_mod.load(a, &why, path) catch |e| switch (e) {
        error.Refused => {
            _ = try failed(a, out, err, why);
            return null;
        },
        else => return e,
    };
    if (!set.stamped()) {
        _ = try failed(a, out, err, try std.fmt.allocPrint(a, "{s} is unstamped ({s}): only a release set is verified, published or smoked", .{ path, set.version }));
        return null;
    }
    if (dir.len == 0) return set;
    set_mod.verifyDir(a, &why, set, dir) catch |e| switch (e) {
        error.Refused => {
            _ = try failed(a, out, err, why);
            return null;
        },
        else => return e,
    };
    return set;
}

/// The first way `built` differs from `got`, or null when they are one set.
fn difference(a: Allocator, got: set_mod.Set, built: set_mod.Set) !?[]const u8 {
    if (!std.mem.eql(u8, got.version, built.version)) return try std.fmt.allocPrint(a, "the version is {s}, and {s} was built", .{ got.version, built.version });
    if (got.packages.len != built.packages.len) return try std.fmt.allocPrint(a, "it holds {d} packages, and {d} were built", .{ got.packages.len, built.packages.len });
    for (got.packages, built.packages) |g, b| {
        if (!std.mem.eql(u8, g.name, b.name)) return try std.fmt.allocPrint(a, "it holds {s} where {s} was built", .{ g.name, b.name });
        if (!std.mem.eql(u8, g.sha256, b.sha256)) return try std.fmt.allocPrint(a, "{s} has the sha256 {s}, and {s} was built", .{ g.name, g.sha256, b.sha256 });
    }
    return null;
}

fn cmdVerify(a: Allocator, args: []const []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    const p = (try parseFlags(a, args, &.{ "--set", "--dir", "--github-output", "--built" }, 3, null, err)) orelse return 2;
    const set = (try loadVerified(a, out, err, p.get(0), p.get(1))) orelse return 1;
    if (p.values[3]) |built_path| {
        var why: []const u8 = "";
        const built = set_mod.load(a, &why, built_path) catch |e| switch (e) {
            error.Refused => return failed(a, out, err, why),
            else => return e,
        };
        if (try difference(a, set, built)) |d| return failed(a, out, err, try std.fmt.allocPrint(a, "the set {s} is not the set built from the same stamp ({s}): {s}", .{ p.get(0), built_path, d }));
    }
    if (try appendOutput(a, out, err, p.get(2), try std.fmt.allocPrint(a, "version={s}\n", .{set.version}))) |code| return code;
    try out.print("npm_smoke: {s} holds the {d} tarballs of {s} at {s}, each with its sha256 and integrity\n", .{ p.get(1), set.packages.len, p.get(0), set.version });
    try out.flush();
    return 0;
}

fn cmdPublish(a: Allocator, args: []const []const u8, deps: Deps, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    const names = [_][]const u8{ "--set", "--dir", "--node", "--npm", "--work" };
    const p = (try parseFlags(a, args, &names, 5, null, err)) orelse return 2;
    if (try requireAbsolute(p, &names, &.{ 1, 2, 3, 4 }, err)) |code| return code;
    const set = (try loadVerified(a, out, err, p.get(0), p.get(1))) orelse return 1;
    var why: []const u8 = "";
    const tools = npm.Tools{ .node = p.get(2), .npm = p.get(3), .work = p.get(4) };
    publish.run(a, &why, deps.runner, tools, set, p.get(1), out) catch |e| switch (e) {
        error.Refused => return failed(a, out, err, why),
        else => return e,
    };
    return 0;
}

fn cmdSmoke(a: Allocator, args: []const []const u8, deps: Deps, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    const names = [_][]const u8{ "--set", "--node", "--npm", "--work", "--attempts", "--delay" };
    const p = (try parseFlags(a, args, &names, 4, null, err)) orelse return 2;
    if (try requireAbsolute(p, &names, &.{ 1, 2, 3 }, err)) |code| return code;
    const attempts = parseNumber(p.values[4] orelse "5", 20) orelse 0;
    if (attempts == 0) {
        _ = try usageError(err, "--attempts is a number from 1 to 20", .{});
        return 2;
    }
    const delay = parseNumber(p.values[5] orelse "30", 300) orelse {
        _ = try usageError(err, "--delay is a number of seconds from 0 to 300", .{});
        return 2;
    };
    const set = (try loadVerified(a, out, err, p.get(0), "")) orelse return 1;
    var why: []const u8 = "";
    const opts = smoke.Options{
        .tools = .{ .node = p.get(1), .npm = p.get(2), .work = p.get(3) },
        .attempts = @intCast(attempts),
        .delay_ms = delay * 1000,
        .pause = deps.pause,
    };
    smoke.run(a, &why, deps.runner, opts, set, out) catch |e| switch (e) {
        error.Refused => return failed(a, out, err, why),
        else => return e,
    };
    return 0;
}

/// The command line after the program's name. Returns the exit status.
pub fn run(a: Allocator, args: []const []const u8, deps: Deps, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    if (args.len >= 1) {
        const rest = args[1..];
        if (std.mem.eql(u8, args[0], "set")) return cmdSet(a, rest, out, err);
        if (std.mem.eql(u8, args[0], "gate")) return cmdGate(a, rest, out, err);
        if (std.mem.eql(u8, args[0], "verify")) return cmdVerify(a, rest, out, err);
        if (std.mem.eql(u8, args[0], "publish")) return cmdPublish(a, rest, deps, out, err);
        if (std.mem.eql(u8, args[0], "smoke")) return cmdSmoke(a, rest, deps, out, err);
    }
    try err.writeAll(usage);
    try err.flush();
    return 2;
}

/// The pause between two install attempts of the smoke: the real one.
const Sleeper = struct {
    fn pause(_: *anyopaque, ms: u64) void {
        std.Thread.sleep(ms * std.time.ns_per_ms);
    }
};

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
    var process = npm.Process{};
    var none: u8 = 0;
    return run(a, rest, .{ .runner = process.runner(), .pause = .{ .ctx = &none, .pauseFn = Sleeper.pause } }, &out.interface, &err.interface);
}
