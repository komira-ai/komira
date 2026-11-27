//! komira_wheel: the version and commit time a build's stamp gives.
//!
//! The stamp is the one the release set uses: `-c komira.package_stamp=<N>`
//! (N the first-parent commit count), `-c komira.package_commit=<sha>` and
//! `-c komira.package_timestamp_ms=<ms>`. All three give the version `0.1.<N>`,
//! a PEP 440 final release, and the commit time every member is dated with.
//! None (the defaults: `0`, empty, `0`) gives `0.0.0` dated 1980-01-01, an
//! unstamped development wheel that the release check refuses. Any other mix
//! is refused, naming what is missing: a half-stamped wheel is never written.

const std = @import("std");
const diag = @import("native_policy").diag;
const Alloc = std.mem.Allocator;
const Diag = diag.Diag;
const Refused = diag.Refused;
const refuse = diag.refuse;

pub const Stamp = struct {
    version: []const u8,
    stamped: bool,
    commit: []const u8,
    timestamp_ms: i64,
};

pub const unstamped_version = "0.0.0";

fn digits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn hex40(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) return false;
    return true;
}

pub fn of(alloc: Alloc, d: *Diag, n: []const u8, commit: []const u8, timestamp_ms: []const u8) Refused!Stamp {
    const has_n = !std.mem.eql(u8, n, "0") and n.len != 0;
    const has_commit = commit.len != 0;
    const has_time = !std.mem.eql(u8, timestamp_ms, "0") and timestamp_ms.len != 0;
    if (!has_n and !has_commit and !has_time)
        return .{ .version = unstamped_version, .stamped = false, .commit = "", .timestamp_ms = 0 };
    if (!(has_n and has_commit and has_time)) {
        var missing = std.ArrayList([]const u8).empty;
        if (!has_n) try missing.append(alloc, "komira.package_stamp");
        if (!has_commit) try missing.append(alloc, "komira.package_commit");
        if (!has_time) try missing.append(alloc, "komira.package_timestamp_ms");
        return refuse(d, alloc, "a stamp needs all of -c komira.package_stamp, -c komira.package_commit and -c komira.package_timestamp_ms, or none; missing: {s}", .{try std.mem.join(alloc, ", ", missing.items)});
    }
    if (!digits(n) or n[0] == '0') return refuse(d, alloc, "the stamp `{s}` is not a positive number without leading zeros", .{n});
    if (!hex40(commit)) return refuse(d, alloc, "the stamp's commit `{s}` is not 40 lowercase hex digits", .{commit});
    if (!digits(timestamp_ms)) return refuse(d, alloc, "the stamp's commit time `{s}` is not a number of milliseconds", .{timestamp_ms});
    const ms = std.fmt.parseInt(i64, timestamp_ms, 10) catch return refuse(d, alloc, "the stamp's commit time `{s}` is out of range", .{timestamp_ms});
    return .{ .version = try std.fmt.allocPrint(alloc, "0.1.{s}", .{n}), .stamped = true, .commit = commit, .timestamp_ms = ms };
}
