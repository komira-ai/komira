//! The offline core: inputs (pins.toml, package-lock.json) plus the lock as
//! it stands give the new lock, or say why not.
//!
//! The lock is keyed by (name, version, file) -- a platform of a pin, a
//! `name@version` of an npm package. A key's sha256 and size are never
//! computed here (that needs the bytes, so only `update` does); they come from
//! the lock already on disk, or from a hash the human wrote in pins.toml. Where
//! neither has them, the answer is "run kpin update", not a guess.
//!
//! The alarm: a key the lock already has, under the same version, whose hash
//! the inputs now contradict. Regenerating would "fix" it, which is exactly what
//! must not happen quietly.

const std = @import("std");
const lockfmt = @import("lockfmt.zig");
const npm = @import("npm.zig");
const pins = @import("pins.zig");
const Report = @import("diag.zig").Report;

pub const Inputs = struct {
    pins: []const pins.Pin = &.{},
    npm: []const npm.Pkg = &.{},
};

/// The lock the inputs call for. `prev` is the lock on disk (empty if none).
/// Nothing is returned for an input with a problem; the problems are in `rep`
/// and the lock is only as complete as they allow.
pub fn compute(a: std.mem.Allocator, in: Inputs, prev: lockfmt.Lock, rep: *Report) error{OutOfMemory}!lockfmt.Lock {
    var out_pins = std.ArrayListUnmanaged(lockfmt.LockPin){};
    for (in.pins) |p| {
        const old = prev.findPin(p.name);
        const same_version = old != null and std.mem.eql(u8, old.?.version, p.version);
        var files = std.ArrayListUnmanaged(lockfmt.File){};
        for (p.platforms) |pf| {
            const url = pins.expand(a, p.url, p.version, pf.token) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.BadTemplate => {
                    rep.errors.add("{s}: url template does not expand for {s}", .{ p.name, pf.id });
                    continue;
                },
            };
            const prior: ?lockfmt.File = if (same_version) lockfmt.findFile(old.?, pf.id) else null;
            if (prior) |pr| {
                if (pf.sha256) |claimed| {
                    if (!std.mem.eql(u8, claimed, pr.sha256) or pf.size.? != pr.size) {
                        rep.alarms.add("{s} {s} ({s}): pins.toml says sha256 {s} size {d}, the lock has {s} size {d}", .{ p.name, p.version, pf.id, claimed, pf.size.?, pr.sha256, pr.size });
                        continue;
                    }
                }
                try files.append(a, .{ .platform = pf.id, .url = url, .sha256 = pr.sha256, .size = pr.size });
            } else if (pf.sha256) |claimed| {
                try files.append(a, .{ .platform = pf.id, .url = url, .sha256 = claimed, .size = pf.size.? });
            } else {
                rep.errors.add("{s} {s} ({s}) has no sha256 yet: run `kpin update`", .{ p.name, p.version, pf.id });
            }
        }
        try out_pins.append(a, .{ .name = p.name, .version = p.version, .files = try files.toOwnedSlice(a) });
    }

    var out_npm = std.ArrayListUnmanaged(lockfmt.Npm){};
    for (in.npm) |pkg| {
        if (prev.findNpm(pkg.key)) |old| {
            if (!std.mem.eql(u8, old.sri512, pkg.sri512)) {
                rep.alarms.add("{s}: package-lock.json says integrity {s}, the lock has {s}: same version, different bytes", .{ pkg.key, pkg.sri512, old.sri512 });
                continue;
            }
            try out_npm.append(a, .{ .key = pkg.key, .name = pkg.name, .version = pkg.version, .url = pkg.url, .sri512 = pkg.sri512, .sha256 = old.sha256, .size = old.size });
        } else {
            rep.errors.add("{s} has no sha256 yet: run `kpin update`", .{pkg.key});
        }
    }
    return .{ .pins = try out_pins.toOwnedSlice(a), .npm = try out_npm.toOwnedSlice(a) };
}

/// Every key both locks have under the same version must hold the same bytes.
/// `check --previous` runs this with the lock of the merge base, so a hash
/// edited in the lock itself (which `compute` would carry along) is caught.
pub fn compareToPrevious(prev: lockfmt.Lock, cur: lockfmt.Lock, rep: *Report) void {
    for (prev.pins) |op| {
        const np = cur.findPin(op.name) orelse continue;
        if (!std.mem.eql(u8, np.version, op.version)) continue;
        for (op.files) |of| {
            const nf = lockfmt.findFile(np, of.platform) orelse continue;
            if (!std.mem.eql(u8, nf.sha256, of.sha256) or nf.size != of.size) {
                rep.alarms.add("{s} {s} ({s}): was sha256 {s} size {d}, is now {s} size {d}", .{ op.name, op.version, of.platform, of.sha256, of.size, nf.sha256, nf.size });
            }
        }
    }
    for (prev.npm) |on| {
        const nn = cur.findNpm(on.key) orelse continue;
        if (!std.mem.eql(u8, nn.sha256, on.sha256) or nn.size != on.size or !std.mem.eql(u8, nn.sri512, on.sri512)) {
            rep.alarms.add("{s}: was sha256 {s} (integrity {s}), is now sha256 {s} (integrity {s})", .{ on.key, on.sha256, on.sri512, nn.sha256, nn.sri512 });
        }
    }
}
