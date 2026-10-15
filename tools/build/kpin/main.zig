//! kpin: pins.toml and the native lockfiles in, pins.lock.bzl out. README.md.

const std = @import("std");
const fetch = @import("fetch.zig");
const lockfmt = @import("lockfmt.zig");
const npm = @import("npm.zig");
const pins = @import("pins.zig");
const resolve = @import("resolve.zig");
const update = @import("update.zig");
const Diag = @import("diag.zig").Diag;
const Report = @import("diag.zig").Report;

pub const EXIT_OK: u8 = 0;
/// Stale lock, bad input, a fetch that failed.
pub const EXIT_FAIL: u8 = 1;
pub const EXIT_USAGE: u8 = 2;
/// A hash changed for a version that is already locked.
pub const EXIT_ALARM: u8 = 3;

pub const default_pins = "tools/build/pins/pins.toml";
pub const default_lock = "tools/build/pins/pins.lock.bzl";

pub const usage =
    \\usage: kpin <command> [flags]
    \\
    \\commands
    \\  lock     offline: write the lock from pins.toml, the package-lock.json files
    \\           and the lock already on disk
    \\  check    offline: exit 1 if the lock is stale, 3 if a hash changed for a version
    \\  update   NETWORK: move versions, fetch what the lock lacks, write inputs and lock
    \\
    \\flags
    \\  --pins FILE        pins.toml (default tools/build/pins/pins.toml)
    \\  --lock FILE        the lock (default tools/build/pins/pins.lock.bzl)
    \\  --npm FILE         a package-lock.json (lockfileVersion 3); repeatable
    \\  --previous FILE    check: the lock of the merge base; a hash that differs from it
    \\                     for the same version is an alarm
    \\  --verify           update: fetch what the lock holds too; any difference is an alarm
    \\  --only NAME        update: one pin only (npm packages are left alone)
    \\  --max-bytes N      update: refuse a download larger than N (default 1073741824)
    \\  --allow-http-loopback   update: allow http:// to 127.0.0.1 (tests)
    \\
    \\exit: 0 ok, 1 failed, 2 usage, 3 alarm (never fixed by regenerating)
    \\
;

pub const Command = enum { lock, check, update };

pub const Config = struct {
    command: Command,
    pins_path: []const u8 = default_pins,
    pins_given: bool = false,
    lock_path: []const u8 = default_lock,
    npm_paths: []const []const u8 = &.{},
    previous: ?[]const u8 = null,
    verify: bool = false,
    only: ?[]const u8 = null,
    max_bytes: u64 = 1 << 30,
    allow_http_loopback: bool = false,
};

pub const ArgError = error{ NoCommand, UnknownCommand, UnknownFlag, MissingValue, BadNumber, WrongCommand };

pub fn parseArgs(a: std.mem.Allocator, argv: []const []const u8) ArgError!Config {
    if (argv.len == 0) return error.NoCommand;
    const cmd = std.meta.stringToEnum(Command, argv[0]) orelse return error.UnknownCommand;
    var cfg = Config{ .command = cmd };
    var npms = std.ArrayList([]const u8).empty;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--verify")) {
            if (cmd != .update) return error.WrongCommand;
            cfg.verify = true;
        } else if (std.mem.eql(u8, arg, "--allow-http-loopback")) {
            if (cmd != .update) return error.WrongCommand;
            cfg.allow_http_loopback = true;
        } else if (std.mem.eql(u8, arg, "--pins") or std.mem.eql(u8, arg, "--lock") or std.mem.eql(u8, arg, "--npm") or
            std.mem.eql(u8, arg, "--previous") or std.mem.eql(u8, arg, "--only") or std.mem.eql(u8, arg, "--max-bytes"))
        {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            const v = argv[i];
            if (std.mem.eql(u8, arg, "--pins")) {
                cfg.pins_path = v;
                cfg.pins_given = true;
            } else if (std.mem.eql(u8, arg, "--lock")) {
                cfg.lock_path = v;
            } else if (std.mem.eql(u8, arg, "--npm")) {
                npms.append(a, v) catch return error.MissingValue;
            } else if (std.mem.eql(u8, arg, "--previous")) {
                if (cmd != .check) return error.WrongCommand;
                cfg.previous = v;
            } else if (std.mem.eql(u8, arg, "--only")) {
                if (cmd != .update) return error.WrongCommand;
                cfg.only = v;
            } else {
                if (cmd != .update) return error.WrongCommand;
                cfg.max_bytes = std.fmt.parseInt(u64, v, 10) catch return error.BadNumber;
            }
        } else return error.UnknownFlag;
    }
    cfg.npm_paths = npms.items;
    return cfg;
}

fn readFile(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(a, path, 256 << 20);
}

/// Writes through a sibling file and a rename: a crash never leaves half a lock.
fn writeFile(a: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const tmp = try std.fmt.allocPrint(a, "{s}.kpin-tmp", .{path});
    try std.fs.cwd().writeFile(.{ .sub_path = tmp, .data = data });
    try std.fs.cwd().rename(tmp, path);
}

fn readLock(a: std.mem.Allocator, path: []const u8, missing_ok: bool, rep: *Report) ?struct { lock: lockfmt.Lock, text: []const u8 } {
    const text = readFile(a, path) catch |e| {
        if (e == error.FileNotFound and missing_ok) return .{ .lock = .{}, .text = "" };
        rep.errors.add("cannot read the lock {s}: {s}", .{ path, @errorName(e) });
        return null;
    };
    const lock = lockfmt.parse(a, text, &rep.errors) catch return null;
    return .{ .lock = lock, .text = text };
}

fn readNpm(a: std.mem.Allocator, cfg: Config, rep: *Report) ?[]npm.Pkg {
    var lists = std.ArrayList([]const npm.Pkg).empty;
    for (cfg.npm_paths) |path| {
        const text = readFile(a, path) catch |e| {
            rep.errors.add("cannot read {s}: {s}", .{ path, @errorName(e) });
            return null;
        };
        const l = npm.read(a, path, text, &rep.errors) catch return null;
        lists.append(a, l) catch return null;
    }
    return npm.merge(a, lists.items, &rep.errors) catch null;
}

fn readPinsText(a: std.mem.Allocator, cfg: Config, rep: *Report) ?[]const u8 {
    return readFile(a, cfg.pins_path) catch |e| {
        rep.errors.add("cannot read {s}: {s}{s}", .{ cfg.pins_path, @errorName(e), if (cfg.pins_given) "" else " (the default; name another with --pins)" });
        return null;
    };
}

fn emit(rep: *const Report, err: *std.Io.Writer) u8 {
    for (rep.errors.msgs.items) |m| err.print("error: {s}\n", .{m}) catch {};
    for (rep.alarms.msgs.items) |m| err.print("ALARM: {s}\n", .{m}) catch {};
    if (rep.alarms.count() > 0) {
        err.writeAll("ALARM: a hash changed for a version that is already locked. Regenerating would hide it; read the project's announcement, and if the change is legitimate a human accepts it in review.\n") catch {};
        return EXIT_ALARM;
    }
    return if (rep.errors.count() > 0) EXIT_FAIL else EXIT_OK;
}

pub fn run(a: std.mem.Allocator, argv: []const []const u8, out: *std.Io.Writer, err: *std.Io.Writer, http: *fetch.HttpFetcher) u8 {
    const cfg = parseArgs(a, argv) catch |e| {
        err.print("kpin: {s}\n\n{s}", .{ @errorName(e), usage }) catch {};
        return EXIT_USAGE;
    };
    var rep = Report.init(a);
    switch (cfg.command) {
        .lock => cmdLock(a, cfg, out, &rep),
        .check => cmdCheck(a, cfg, out, &rep),
        .update => cmdUpdate(a, cfg, out, &rep, http),
    }
    return emit(&rep, err);
}

fn cmdLock(a: std.mem.Allocator, cfg: Config, out: *std.Io.Writer, rep: *Report) void {
    const pins_text = readPinsText(a, cfg, rep) orelse return;
    const list = pins.load(a, pins_text, &rep.errors) catch return;
    const npm_pkgs = readNpm(a, cfg, rep) orelse return;
    const prev = readLock(a, cfg.lock_path, true, rep) orelse return;
    const lock = resolve.compute(a, .{ .pins = list, .npm = npm_pkgs }, prev.lock, rep) catch return;
    if (!rep.clean()) return;
    const text = lockfmt.render(a, lock) catch |e| {
        rep.errors.add("cannot render the lock: {s}", .{@errorName(e)});
        return;
    };
    if (std.mem.eql(u8, text, prev.text)) {
        out.print("kpin: {s} is up to date\n", .{cfg.lock_path}) catch {};
        return;
    }
    writeFile(a, cfg.lock_path, text) catch |e| {
        rep.errors.add("cannot write {s}: {s}", .{ cfg.lock_path, @errorName(e) });
        return;
    };
    out.print("kpin: wrote {s} ({d} pins, {d} npm packages)\n", .{ cfg.lock_path, lock.pins.len, lock.npm.len }) catch {};
}

fn cmdCheck(a: std.mem.Allocator, cfg: Config, out: *std.Io.Writer, rep: *Report) void {
    const pins_text = readPinsText(a, cfg, rep) orelse return;
    const list = pins.load(a, pins_text, &rep.errors) catch return;
    const npm_pkgs = readNpm(a, cfg, rep) orelse return;
    const cur = readLock(a, cfg.lock_path, false, rep) orelse return;
    const lock = resolve.compute(a, .{ .pins = list, .npm = npm_pkgs }, cur.lock, rep) catch return;
    if (cfg.previous) |path| {
        const base = readLock(a, path, false, rep) orelse return;
        resolve.compareToPrevious(base.lock, cur.lock, rep);
    }
    if (!rep.clean()) return;
    const text = lockfmt.render(a, lock) catch |e| {
        rep.errors.add("cannot render the lock: {s}", .{@errorName(e)});
        return;
    };
    if (!std.mem.eql(u8, text, cur.text)) {
        rep.errors.add("{s} is stale: it is not what the inputs produce. Run `./buck2 run komira//tools/build/kpin -- lock` (or `update`) and commit the result", .{cfg.lock_path});
        return;
    }
    out.print("kpin: {s} is up to date ({d} pins, {d} npm packages)\n", .{ cfg.lock_path, lock.pins.len, lock.npm.len }) catch {};
}

fn cmdUpdate(a: std.mem.Allocator, cfg: Config, out: *std.Io.Writer, rep: *Report, http: *fetch.HttpFetcher) void {
    http.allow_http_loopback = cfg.allow_http_loopback;
    const pins_text = readPinsText(a, cfg, rep) orelse return;
    const npm_pkgs = readNpm(a, cfg, rep) orelse return;
    const prev = readLock(a, cfg.lock_path, true, rep) orelse return;
    const o = update.run(a, http.fetcher(), pins_text, npm_pkgs, prev.lock, .{
        .verify = cfg.verify,
        .only = cfg.only,
        .max_blob = cfg.max_bytes,
    }, rep) catch |e| {
        rep.errors.add("update failed: {s}", .{@errorName(e)});
        return;
    };
    for (o.notes.msgs.items) |n| out.print("kpin: {s}\n", .{n}) catch {};
    if (!rep.clean()) return;
    if (o.pins_text) |t| writeFile(a, cfg.pins_path, t) catch |e| {
        rep.errors.add("cannot write {s}: {s}", .{ cfg.pins_path, @errorName(e) });
        return;
    };
    const lock_text = o.lock_text.?;
    if (!std.mem.eql(u8, lock_text, prev.text)) writeFile(a, cfg.lock_path, lock_text) catch |e| {
        rep.errors.add("cannot write {s}: {s}", .{ cfg.lock_path, @errorName(e) });
        return;
    };
    out.print("kpin: fetched {d}; {s}\n", .{ o.fetched, if (std.mem.eql(u8, lock_text, prev.text)) "the lock is unchanged" else "the lock is rewritten" }) catch {};
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    var http = fetch.HttpFetcher{ .allocator = a };
    const argv = try a.alloc([]const u8, args.len - 1);
    for (args[1..], 0..) |s, i| argv[i] = s;
    // Buffered writers (zig 0.15's writers have no unbuffered default),
    // flushed before the process exits.
    var out_buf: [4096]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var out = std.fs.File.stdout().writer(&out_buf);
    var err = std.fs.File.stderr().writer(&err_buf);
    const code = run(a, argv, &out.interface, &err.interface, &http);
    out.interface.flush() catch {};
    err.interface.flush() catch {};
    std.process.exit(code);
}
