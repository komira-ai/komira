//! `kpin update` for Cargo: the size of each linked `.crate`, from kpin's own
//! download. `pinned_file` needs a size, and `cargo metadata` and Cargo.lock do
//! not carry one; taking it from a cargo cache would be trusting a file kpin
//! did not read. Each crate is fetched from the registry's static host,
//! hashed as it streams, and refused unless its sha256 is the one Cargo.lock
//! pins. Only the crates the build links are fetched (the same set `kpin
//! cargo` emits). Network: this is the only cargo step that opens a socket,
//! and it runs on a runner or a contributor's machine, never in a build.

const std = @import("std");
const cargo = @import("cargo.zig");
const fetch = @import("fetch.zig");
const Report = @import("diag.zig").Report;

pub const default_base = "https://static.crates.io/crates";

pub const Options = struct {
    /// `<base>/<name>/<name>-<version>.crate`
    base: []const u8 = default_base,
    /// Fetch what the sizes file already holds too, and alarm on any difference.
    verify: bool = false,
    max_blob: u64 = 1 << 30,
};

fn lessKey(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

/// The new sizes file (`<name>-<version>.crate <bytes>`, sorted, one line per
/// linked crate), or null when `rep` is not clean. A download whose sha256 is
/// not the one in Cargo.lock, or whose size differs from the file's, is an
/// alarm: the registry serves other bytes than were pinned.
pub fn run(a: std.mem.Allocator, f: fetch.Fetcher, in: cargo.Inputs, opts: Options, fetched: *usize, rep: *Report) !?[]u8 {
    const crates = cargo.linkedCrates(a, in, &rep.errors) catch return null;
    const prior = cargo.parseSizes(a, in.sizes_label, in.sizes, &rep.errors);
    var lines = std.ArrayListUnmanaged([]const u8){};
    for (crates) |c| {
        const key = try std.fmt.allocPrint(a, "{s}-{s}.crate", .{ c.name, c.version });
        const old = prior.get(key);
        var size: u64 = 0;
        if (old != null and !opts.verify) {
            size = old.?;
        } else {
            const url = try std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ opts.base, c.name, key });
            var d = fetch.Digest{ .max = opts.max_blob };
            f.get(url, d.sink()) catch |e| {
                rep.errors.add("{s}: fetching {s}: {s}", .{ key, url, @errorName(e) });
                continue;
            };
            const r = try d.finish(a);
            fetched.* += 1;
            if (!std.mem.eql(u8, r.sha256, c.checksum)) {
                rep.alarms.add("{s}: Cargo.lock pins sha256 {s}, {s} serves sha256 {s}", .{ key, c.checksum, url, r.sha256 });
                continue;
            }
            if (old) |o| if (o != r.size) {
                rep.alarms.add("{s}: the sizes file has {d} bytes, {s} serves {d}", .{ key, o, url, r.size });
                continue;
            };
            size = r.size;
        }
        try lines.append(a, try std.fmt.allocPrint(a, "{s} {d}\n", .{ key, size }));
    }
    if (!rep.clean()) return null;
    std.mem.sort([]const u8, lines.items, {}, lessKey);
    return try std.mem.concat(a, u8, lines.items);
}
