//! `kpin update`: the one command that touches the network. In order:
//!
//!  1. pins with a `latest_url`: read the newest version from that document
//!     and, if it is newer than pins.toml's, move pins.toml to it;
//!  2. fetch every tarball or file the lock does not hold yet (all of them
//!     with `verify`), computing sha256 and size; npm tarballs are also checked
//!     against package-lock.json's sha512;
//!  3. a fetched hash that differs from the lock's for the same version is an
//!     alarm, and nothing is written;
//!  4. otherwise the new lock is the offline `compute` over a seed of the
//!     fetched and carried hashes.
//!
//! It works on text and returns text; main.zig reads and writes the files.

const std = @import("std");
const fetch = @import("fetch.zig");
const lockfmt = @import("lockfmt.zig");
const npm = @import("npm.zig");
const pins = @import("pins.zig");
const resolve = @import("resolve.zig");
const valid = @import("valid.zig");
const Diag = @import("diag.zig").Diag;
const Report = @import("diag.zig").Report;

pub const Options = struct {
    /// Fetch what the lock already holds too, and alarm on any difference.
    verify: bool = false,
    /// Only this pin (npm packages are left alone).
    only: ?[]const u8 = null,
    max_blob: u64 = 1 << 30,
    max_meta: usize = 16 << 20,
};

pub const Outcome = struct {
    /// pins.toml with the bumped versions; null when no version moved.
    pins_text: ?[]const u8 = null,
    /// The new lock; null when `rep` is not clean.
    lock_text: ?[]const u8 = null,
    fetched: usize = 0,
    /// One line per version moved and per note worth printing.
    notes: Diag,
};

/// Dotted numbers only (`1.2.3`); anything with a letter is not compared.
pub fn numericParts(s: []const u8, out: *[8]u64) ?usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |part| {
        if (n == out.len or part.len == 0) return null;
        out[n] = std.fmt.parseInt(u64, part, 10) catch return null;
        n += 1;
    }
    return n;
}

/// Is `cand` a greater version than `cur`? False if either is not dotted numbers.
pub fn isNewer(cur: []const u8, cand: []const u8) bool {
    var x: [8]u64 = undefined;
    var y: [8]u64 = undefined;
    const nx = numericParts(cur, &x) orelse return false;
    const ny = numericParts(cand, &y) orelse return false;
    var i: usize = 0;
    while (i < @max(nx, ny)) : (i += 1) {
        const a: u64 = if (i < nx) x[i] else 0;
        const b: u64 = if (i < ny) y[i] else 0;
        if (b != a) return b > a;
    }
    return false;
}

/// The string at the dotted `path` of a JSON document.
pub fn jsonString(a: std.mem.Allocator, body: []const u8, path: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, a, body, .{}) catch return null;
    var cur = parsed.value;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |seg| {
        switch (cur) {
            .object => |o| cur = o.get(seg) orelse return null,
            else => return null,
        }
    }
    return switch (cur) {
        .string => |s| s,
        else => null,
    };
}

fn digestOf(a: std.mem.Allocator, f: fetch.Fetcher, url: []const u8, max: u64) !fetch.Digest.Result {
    var d = fetch.Digest{ .max = max };
    try f.get(url, d.sink());
    return d.finish(a);
}

pub fn run(
    a: std.mem.Allocator,
    f: fetch.Fetcher,
    pins_text: []const u8,
    npm_pkgs: []const npm.Pkg,
    prev: lockfmt.Lock,
    opts: Options,
    rep: *Report,
) !Outcome {
    var out = Outcome{ .notes = Diag.init(a) };
    const list = pins.load(a, pins_text, &rep.errors) catch return out;

    if (opts.only) |name| {
        var found = false;
        for (list) |p| if (std.mem.eql(u8, p.name, name)) {
            found = true;
        };
        if (!found) {
            rep.errors.add("--only {s}: no such pin in pins.toml", .{name});
            return out;
        }
    }

    // 1. newer versions
    var text: []const u8 = pins_text;
    for (list) |*p| {
        if (opts.only) |name| if (!std.mem.eql(u8, p.name, name)) continue;
        const url = p.latest_url orelse continue;
        var c = fetch.Collect{ .a = a, .max = opts.max_meta };
        f.get(url, c.sink()) catch |e| {
            rep.errors.add("{s}: fetching {s}: {s}", .{ p.name, url, @errorName(e) });
            continue;
        };
        const raw = jsonString(a, c.buf.items, p.latest_field.?) orelse {
            rep.errors.add("{s}: {s} has no string at `{s}`", .{ p.name, url, p.latest_field.? });
            continue;
        };
        const stripped = if (p.version_prefix.len > 0 and std.mem.startsWith(u8, raw, p.version_prefix)) raw[p.version_prefix.len..] else raw;
        if (!valid.isVersion(stripped)) {
            rep.errors.add("{s}: the newest version `{s}` has unsupported characters", .{ p.name, raw });
            continue;
        }
        if (!isNewer(p.version, stripped)) continue;
        text = pins.setVersion(a, text, p.name, stripped) catch |e| {
            rep.errors.add("{s}: cannot set the version in pins.toml: {s}", .{ p.name, @errorName(e) });
            continue;
        };
        out.notes.add("{s}: {s} -> {s}", .{ p.name, p.version, stripped });
        p.version = stripped;
    }

    // 2. the hashes
    var seed_pins = std.ArrayListUnmanaged(lockfmt.LockPin){};
    for (list) |p| {
        const old = prev.findPin(p.name);
        const same = old != null and std.mem.eql(u8, old.?.version, p.version);
        const selected = opts.only == null or std.mem.eql(u8, opts.only.?, p.name);
        var files = std.ArrayListUnmanaged(lockfmt.File){};
        for (p.platforms) |pf| {
            const prior: ?lockfmt.File = if (same) lockfmt.findFile(old.?, pf.id) else null;
            const need = selected and (prior == null or opts.verify);
            if (!need) {
                if (prior) |pr| try files.append(a, pr);
                continue;
            }
            const url = pins.expand(a, p.url, p.version, pf.token) catch {
                rep.errors.add("{s}: url template does not expand for {s}", .{ p.name, pf.id });
                continue;
            };
            const d = digestOf(a, f, url, opts.max_blob) catch |e| {
                rep.errors.add("{s} {s} ({s}): fetching {s}: {s}", .{ p.name, p.version, pf.id, url, @errorName(e) });
                continue;
            };
            out.fetched += 1;
            if (prior) |pr| if (!std.mem.eql(u8, pr.sha256, d.sha256) or pr.size != d.size) {
                rep.alarms.add("{s} {s} ({s}): the lock has sha256 {s} size {d}, {s} now serves sha256 {s} size {d}", .{ p.name, p.version, pf.id, pr.sha256, pr.size, url, d.sha256, d.size });
                continue;
            };
            if (pf.sha256) |claimed| if (!std.mem.eql(u8, claimed, d.sha256) or pf.size.? != d.size) {
                rep.errors.add("{s} {s} ({s}): pins.toml says sha256 {s} size {d}, the bytes are sha256 {s} size {d}", .{ p.name, p.version, pf.id, claimed, pf.size.?, d.sha256, d.size });
                continue;
            };
            try files.append(a, .{ .platform = pf.id, .url = url, .sha256 = d.sha256, .size = d.size });
        }
        try seed_pins.append(a, .{ .name = p.name, .version = p.version, .files = try files.toOwnedSlice(a) });
    }

    var seed_npm = std.ArrayListUnmanaged(lockfmt.Npm){};
    for (npm_pkgs) |pkg| {
        const prior = prev.findNpm(pkg.key);
        const need = opts.only == null and (prior == null or opts.verify);
        if (!need) {
            if (prior) |pr| try seed_npm.append(a, pr);
            continue;
        }
        const d = digestOf(a, f, pkg.url, opts.max_blob) catch |e| {
            rep.errors.add("{s}: fetching {s}: {s}", .{ pkg.key, pkg.url, @errorName(e) });
            continue;
        };
        out.fetched += 1;
        if (!std.mem.eql(u8, d.sri512, pkg.sri512)) {
            // Not the lock's alarm: the registry disagrees with the lockfile it
            // is supposed to match. Still nothing is written.
            rep.errors.add("{s}: the tarball's sha512 is {s}, package-lock.json says {s}", .{ pkg.key, d.sri512, pkg.sri512 });
            continue;
        }
        if (prior) |pr| if (!std.mem.eql(u8, pr.sha256, d.sha256) or pr.size != d.size) {
            rep.alarms.add("{s}: the lock has sha256 {s} size {d}, {s} now serves sha256 {s} size {d}", .{ pkg.key, pr.sha256, pr.size, pkg.url, d.sha256, d.size });
            continue;
        };
        try seed_npm.append(a, .{ .key = pkg.key, .name = pkg.name, .version = pkg.version, .url = pkg.url, .sri512 = pkg.sri512, .sha256 = d.sha256, .size = d.size });
    }
    if (!rep.clean()) return out;

    // 3. the lock
    const seed = lockfmt.Lock{ .pins = seed_pins.items, .npm = seed_npm.items };
    const lock = try resolve.compute(a, .{ .pins = list, .npm = npm_pkgs }, seed, rep);
    if (!rep.clean()) return out;
    out.lock_text = lockfmt.render(a, lock) catch |e| {
        rep.errors.add("cannot render the lock: {s}", .{@errorName(e)});
        return out;
    };
    if (!std.mem.eql(u8, text, pins_text)) out.pins_text = text;
    return out;
}
