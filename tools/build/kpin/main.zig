//! kpin: pins.toml and the native lockfiles in, pins.lock.bzl out. README.md.

const std = @import("std");
const cargo = @import("cargo.zig");
const cargo_lock = @import("cargo_lock.zig");
const cargo_trim = @import("cargo_trim.zig");
const cargo_update = @import("cargo_update.zig");
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
    \\  cargo    offline: Cargo.lock + `cargo metadata` + overrides -> a .bzl of crates.io crates
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
    \\cargo flags (--cargo-lock, --metadata, --overrides, --sizes, --rustc, --target, --cargo-out are required)
    \\  --cargo-lock FILE       Cargo.lock (version 3 or 4)
    \\  --metadata FILE         `cargo metadata --format-version 1 --locked --filter-platform <triple>`
    \\  --overrides FILE        what each build script decides, per crate and version
    \\  --sizes FILE            `<name>-<version>.crate <bytes>` per crate
    \\  --rustc VERSION         the pinned compiler; the overrides must be for it
    \\  --cargo-out FILE        the .bzl to write
    \\  --check                 do not write: exit 1 unless --cargo-out is what the inputs generate
    \\  --target TRIPLE         the platform the metadata was filtered for (--filter-platform)
    \\  --previous-lock FILE    the Cargo.lock of the merge base; a checksum that differs from it for
    \\                          the same crate version is an alarm
    \\  --stamp FILE            on success, write a passing validation result there
    \\  --trim FILE             instead of generating: write --metadata (raw, from `cargo metadata
    \\                          --filter-platform --target`) cut down to what kpin reads, with constant
    \\                          paths and the platform recorded, to FILE (the form that is committed)
    \\
    \\update, for Cargo (NETWORK): with --cargo-lock, --metadata, --sizes and --target, also writes
    \\the sizes file from a verified download of each linked .crate
    \\  --crates-base URL       default https://static.crates.io/crates
    \\  --no-pins               only the Cargo sizes: leave pins.toml and the lock alone
    \\
    \\exit: 0 ok, 1 failed, 2 usage, 3 alarm (never fixed by regenerating)
    \\
;

pub const Command = enum { lock, check, update, cargo };

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
    cargo_lock: ?[]const u8 = null,
    metadata: ?[]const u8 = null,
    overrides: ?[]const u8 = null,
    sizes: ?[]const u8 = null,
    rustc: ?[]const u8 = null,
    cargo_out: ?[]const u8 = null,
    check_out: bool = false,
    stamp: ?[]const u8 = null,
    trim: ?[]const u8 = null,
    target: ?[]const u8 = null,
    previous_lock: ?[]const u8 = null,
    crates_base: []const u8 = cargo_update.default_base,
    no_pins: bool = false,
};

pub const ArgError = error{ NoCommand, UnknownCommand, UnknownFlag, MissingValue, BadNumber, WrongCommand };

pub fn parseArgs(a: std.mem.Allocator, argv: []const []const u8) ArgError!Config {
    if (argv.len == 0) return error.NoCommand;
    const cmd = std.meta.stringToEnum(Command, argv[0]) orelse return error.UnknownCommand;
    var cfg = Config{ .command = cmd };
    var npms = std.ArrayListUnmanaged([]const u8){};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--verify")) {
            if (cmd != .update) return error.WrongCommand;
            cfg.verify = true;
        } else if (std.mem.eql(u8, arg, "--allow-http-loopback")) {
            if (cmd != .update) return error.WrongCommand;
            cfg.allow_http_loopback = true;
        } else if (std.mem.eql(u8, arg, "--check")) {
            if (cmd != .cargo) return error.WrongCommand;
            cfg.check_out = true;
        } else if (std.mem.eql(u8, arg, "--no-pins")) {
            if (cmd != .update) return error.WrongCommand;
            cfg.no_pins = true;
        } else if (std.mem.eql(u8, arg, "--cargo-lock") or std.mem.eql(u8, arg, "--metadata") or std.mem.eql(u8, arg, "--sizes") or
            std.mem.eql(u8, arg, "--target") or std.mem.eql(u8, arg, "--crates-base") or
            std.mem.eql(u8, arg, "--overrides") or std.mem.eql(u8, arg, "--rustc") or std.mem.eql(u8, arg, "--cargo-out") or
            std.mem.eql(u8, arg, "--stamp") or std.mem.eql(u8, arg, "--trim") or std.mem.eql(u8, arg, "--previous-lock"))
        {
            // Shared by `cargo` and `update` (the sizes); the rest are `cargo`'s.
            const shared = std.mem.eql(u8, arg, "--cargo-lock") or std.mem.eql(u8, arg, "--metadata") or std.mem.eql(u8, arg, "--sizes") or
                std.mem.eql(u8, arg, "--target") or std.mem.eql(u8, arg, "--crates-base");
            if (cmd != .cargo and !(shared and cmd == .update)) return error.WrongCommand;
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            const v = argv[i];
            if (std.mem.eql(u8, arg, "--cargo-lock")) cfg.cargo_lock = v else if (std.mem.eql(u8, arg, "--metadata")) cfg.metadata = v else if (std.mem.eql(u8, arg, "--overrides")) cfg.overrides = v else if (std.mem.eql(u8, arg, "--sizes")) cfg.sizes = v else if (std.mem.eql(u8, arg, "--rustc")) cfg.rustc = v else if (std.mem.eql(u8, arg, "--cargo-out")) cfg.cargo_out = v else if (std.mem.eql(u8, arg, "--stamp")) cfg.stamp = v else if (std.mem.eql(u8, arg, "--target")) cfg.target = v else if (std.mem.eql(u8, arg, "--crates-base")) cfg.crates_base = v else if (std.mem.eql(u8, arg, "--previous-lock")) cfg.previous_lock = v else cfg.trim = v;
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
    try std.fs.cwd().writeFile(tmp, data);
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
    var lists = std.ArrayListUnmanaged([]const npm.Pkg){};
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

fn emit(rep: *const Report, err: std.io.AnyWriter) u8 {
    for (rep.errors.msgs.items) |m| err.print("error: {s}\n", .{m}) catch {};
    for (rep.alarms.msgs.items) |m| err.print("ALARM: {s}\n", .{m}) catch {};
    if (rep.alarms.count() > 0) {
        err.writeAll("ALARM: a hash changed for a version that is already locked. Regenerating would hide it; read the project's announcement, and if the change is legitimate a human accepts it in review.\n") catch {};
        return EXIT_ALARM;
    }
    return if (rep.errors.count() > 0) EXIT_FAIL else EXIT_OK;
}

pub fn run(a: std.mem.Allocator, argv: []const []const u8, out: std.io.AnyWriter, err: std.io.AnyWriter, http: *fetch.HttpFetcher) u8 {
    const cfg = parseArgs(a, argv) catch |e| {
        err.print("kpin: {s}\n\n{s}", .{ @errorName(e), usage }) catch {};
        return EXIT_USAGE;
    };
    var rep = Report.init(a);
    switch (cfg.command) {
        .lock => cmdLock(a, cfg, out, &rep),
        .check => cmdCheck(a, cfg, out, &rep),
        .update => cmdUpdate(a, cfg, out, &rep, http),
        .cargo => cmdCargo(a, cfg, out, &rep),
    }
    return emit(&rep, err);
}

fn cmdLock(a: std.mem.Allocator, cfg: Config, out: std.io.AnyWriter, rep: *Report) void {
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

fn cmdCheck(a: std.mem.Allocator, cfg: Config, out: std.io.AnyWriter, rep: *Report) void {
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

fn cmdUpdate(a: std.mem.Allocator, cfg: Config, out: std.io.AnyWriter, rep: *Report, http: *fetch.HttpFetcher) void {
    http.allow_http_loopback = cfg.allow_http_loopback;
    if (cfg.sizes != null or cfg.cargo_lock != null or cfg.metadata != null or cfg.target != null) {
        updateCargoSizes(a, cfg, out, rep, http);
        if (!rep.clean() or cfg.no_pins) return;
    } else if (cfg.no_pins) {
        return rep.errors.add("--no-pins is for the Cargo sizes: give --cargo-lock, --metadata, --sizes and --target", .{});
    }
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

/// A checksum that differs from the base's for the same crate version.
fn cargoLockAlarms(a: std.mem.Allocator, base_text: []const u8, cur_text: []const u8, rep: *Report) void {
    const base = cargo_lock.parse(a, "the base Cargo.lock", base_text, &rep.errors) catch return;
    const cur = cargo_lock.parse(a, "Cargo.lock", cur_text, &rep.errors) catch return;
    for (cur) |c| {
        for (base) |b| {
            if (std.mem.eql(u8, b.name, c.name) and std.mem.eql(u8, b.version, c.version) and std.mem.eql(u8, b.source, c.source) and b.checksum.len > 0 and !std.mem.eql(u8, b.checksum, c.checksum)) {
                rep.alarms.add("{s} {s}: Cargo.lock has checksum {s}, the base has {s}", .{ c.name, c.version, c.checksum, b.checksum });
            }
        }
    }
}

fn updateCargoSizes(a: std.mem.Allocator, cfg: Config, out: std.io.AnyWriter, rep: *Report, http: *fetch.HttpFetcher) void {
    const lp = cfg.cargo_lock orelse return rep.errors.add("kpin update: the Cargo sizes need --cargo-lock", .{});
    const mp = cfg.metadata orelse return rep.errors.add("kpin update: the Cargo sizes need --metadata", .{});
    const sp = cfg.sizes orelse return rep.errors.add("kpin update: the Cargo sizes need --sizes", .{});
    const target = cfg.target orelse return rep.errors.add("kpin update: the Cargo sizes need --target", .{});
    const lock = readFile(a, lp) catch |e| return rep.errors.add("cannot read {s}: {s}", .{ lp, @errorName(e) });
    const meta = readFile(a, mp) catch |e| return rep.errors.add("cannot read {s}: {s}", .{ mp, @errorName(e) });
    // A sizes file that does not exist yet is the first run.
    const have: []const u8 = readFile(a, sp) catch |e| blk: {
        if (e != error.FileNotFound) return rep.errors.add("cannot read {s}: {s}", .{ sp, @errorName(e) });
        break :blk "";
    };
    var fetched: usize = 0;
    const text = cargo_update.run(a, http.fetcher(), .{
        .lock_label = lp,
        .metadata_label = mp,
        .sizes_label = sp,
        .lock = lock,
        .metadata = meta,
        .sizes = have,
        .target = target,
    }, .{ .base = cfg.crates_base, .verify = cfg.verify, .max_blob = cfg.max_bytes }, &fetched, rep) catch |e| return rep.errors.add("update failed: {s}", .{@errorName(e)});
    const t = text orelse return;
    if (!std.mem.eql(u8, t, have)) writeFile(a, sp, t) catch |e| return rep.errors.add("cannot write {s}: {s}", .{ sp, @errorName(e) });
    out.print("kpin: fetched {d} crates; {s} {s}\n", .{ fetched, sp, if (std.mem.eql(u8, t, have)) "is unchanged" else "is rewritten" }) catch {};
}

/// The 1-based line of the first difference between two texts.
fn firstDifference(x: []const u8, y: []const u8) usize {
    var line: usize = 1;
    var i: usize = 0;
    while (i < x.len and i < y.len) : (i += 1) {
        if (x[i] != y[i]) return line;
        if (x[i] == '\n') line += 1;
    }
    return line;
}

fn cmdCargo(a: std.mem.Allocator, cfg: Config, out: std.io.AnyWriter, rep: *Report) void {
    if (cfg.trim) |dest| {
        const src = cfg.metadata orelse return rep.errors.add("kpin cargo --trim needs --metadata", .{});
        const raw = readFile(a, src) catch |e| return rep.errors.add("cannot read {s}: {s}", .{ src, @errorName(e) });
        const target = cfg.target orelse return rep.errors.add("kpin cargo --trim needs --target: the platform the metadata was filtered for", .{});
        const text = cargo_trim.trim(a, src, raw, target, &rep.errors) catch return;
        writeFile(a, dest, text) catch |e| return rep.errors.add("cannot write {s}: {s}", .{ dest, @errorName(e) });
        out.print("kpin: {s} written\n", .{dest}) catch {};
        return;
    }
    const names = .{ "--cargo-lock", "--metadata", "--overrides", "--sizes", "--rustc", "--target", "--cargo-out" };
    const vals = .{ cfg.cargo_lock, cfg.metadata, cfg.overrides, cfg.sizes, cfg.rustc, cfg.target, cfg.cargo_out };
    var missing = false;
    inline for (names, vals) |n, v| {
        if (v == null) {
            rep.errors.add("kpin cargo needs {s}", .{n});
            missing = true;
        }
    }
    if (missing) return;
    const lock = readFile(a, cfg.cargo_lock.?) catch |e| return rep.errors.add("cannot read {s}: {s}", .{ cfg.cargo_lock.?, @errorName(e) });
    const meta = readFile(a, cfg.metadata.?) catch |e| return rep.errors.add("cannot read {s}: {s}", .{ cfg.metadata.?, @errorName(e) });
    const ovs = readFile(a, cfg.overrides.?) catch |e| return rep.errors.add("cannot read {s}: {s}", .{ cfg.overrides.?, @errorName(e) });
    const sizes = readFile(a, cfg.sizes.?) catch |e| return rep.errors.add("cannot read {s}: {s}", .{ cfg.sizes.?, @errorName(e) });
    const text = cargo.generate(a, .{
        .lock_label = cfg.cargo_lock.?,
        .metadata_label = cfg.metadata.?,
        .overrides_label = cfg.overrides.?,
        .sizes_label = cfg.sizes.?,
        .lock = lock,
        .metadata = meta,
        .overrides = ovs,
        .sizes = sizes,
        .rustc = cfg.rustc.?,
        .target = cfg.target.?,
    }, &rep.errors) catch return;
    if (cfg.previous_lock) |pl| {
        const base = readFile(a, pl) catch |e| return rep.errors.add("cannot read {s}: {s}", .{ pl, @errorName(e) });
        cargoLockAlarms(a, base, lock, rep);
        if (rep.alarms.count() > 0) return;
    }
    const dest = cfg.cargo_out.?;
    if (cfg.check_out) {
        const have = readFile(a, dest) catch |e| return rep.errors.add("cannot read {s}: {s}", .{ dest, @errorName(e) });
        if (!std.mem.eql(u8, have, text)) {
            return rep.errors.add("{s} is not what the inputs generate (first difference at line {d}): regenerate it with `kpin cargo` (without --check) and commit the result; never edit it by hand", .{ dest, firstDifference(have, text) });
        }
        out.print("kpin: {s} is up to date\n", .{dest}) catch {};
    } else {
        const same = if (readFile(a, dest)) |have| std.mem.eql(u8, have, text) else |_| false;
        if (!same) writeFile(a, dest, text) catch |e| return rep.errors.add("cannot write {s}: {s}", .{ dest, @errorName(e) });
        out.print("kpin: {s} {s}\n", .{ dest, if (same) "is up to date" else "written" }) catch {};
    }
    if (cfg.stamp) |s| writeFile(a, s, "{\"version\": 1, \"data\": {\"status\": \"success\", \"message\": \"kpin cargo: the generated file is what the inputs produce\"}}\n") catch |e| rep.errors.add("cannot write {s}: {s}", .{ s, @errorName(e) });
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    var http = fetch.HttpFetcher{ .allocator = a };
    const argv = try a.alloc([]const u8, args.len - 1);
    for (args[1..], 0..) |s, i| argv[i] = s;
    const out = std.io.getStdOut().writer();
    const err = std.io.getStdErr().writer();
    const code = run(a, argv, out.any(), err.any(), &http);
    std.process.exit(code);
}
