//! pypi_smoke: what an index says about a release, read from its JSON API
//! (`<json base><name>/<version>/json`, whose `urls` list the files of the release with their `size`,
//! `digests.sha256`, `url` and `yanked`).
//!
//! `lookup` is what `state` asks before an upload: is our wheel's file on the index, and with the same bytes.
//! One GET; before an upload there is nothing to wait for. `verify` is what the smoke asks after one: the
//! index lists our file with our sha256 and size, serves it from its file host, and the bytes it serves are the
//! built wheel's (sha256 and size) with the same METADATA `Name`, `Version`, `Requires-Python` and
//! `Requires-Dist`. An index lags an upload, so a refused attempt is repeated `attempts` times, `delay_ms`
//! apart; every difference of the last attempt is reported, not only the first.
const std = @import("std");
const common = @import("common.zig");
const meta = @import("meta.zig");
const rbf = @import("release_beta_fetch");

const Allocator = common.Allocator;
const Error = common.Error;
const refuse = common.refuse;

/// The most a release's JSON may be.
pub const max_json_bytes: usize = 16 << 20;

pub const State = enum { absent, same, differs };

/// What the index holds under our file name; `theirs` is its sha256 when it holds one.
pub const Found = struct { state: State, theirs: []const u8 = "" };

const Digests = struct { sha256: []const u8 };
const Url = struct {
    filename: []const u8,
    size: u64,
    digests: Digests,
    url: []const u8,
    yanked: bool = false,
};
const Release = struct { urls: []const Url };

/// The files of the release the wheel belongs to; null when the index has no such release (HTTP 404).
fn releaseFiles(a: Allocator, why: *[]const u8, fetcher: rbf.Fetcher, idx: common.Index, wheel: meta.Wheel) Error!?[]const Url {
    const url = try std.fmt.allocPrint(a, "{s}{s}/{s}/json", .{ idx.json_base, wheel.name, wheel.version });
    switch (fetcher.get(a, url, max_json_bytes)) {
        .body => |body| {
            const release = std.json.parseFromSliceLeaky(Release, a, body, .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return refuse(a, why, "GET {s}: the answer is not the JSON of a release ({s})", .{ url, @errorName(e) }),
            };
            return release.urls;
        },
        .status => |s| {
            if (s == 404) return null;
            return refuse(a, why, "GET {s}: HTTP {d}", .{ url, s });
        },
        .too_large => return refuse(a, why, "GET {s}: the answer is longer than {d} bytes", .{ url, max_json_bytes }),
        .bad_url => return refuse(a, why, "{s} is not a URL this tool fetches", .{url}),
        .transport => |e| return refuse(a, why, "GET {s}: {s}", .{ url, @errorName(e) }),
    }
}

fn entryOf(urls: []const Url, file_name: []const u8) ?Url {
    for (urls) |u| if (std.mem.eql(u8, u.filename, file_name)) return u;
    return null;
}

/// Whether the index holds our file, and with our bytes.
pub fn lookup(a: Allocator, why: *[]const u8, fetcher: rbf.Fetcher, idx: common.Index, wheel: meta.Wheel) Error!Found {
    const urls = (try releaseFiles(a, why, fetcher, idx, wheel)) orelse return .{ .state = .absent };
    const entry = entryOf(urls, wheel.file_name) orelse return .{ .state = .absent };
    const state: State = if (std.mem.eql(u8, entry.digests.sha256, &wheel.sha256)) .same else .differs;
    return .{ .state = state, .theirs = entry.digests.sha256 };
}

/// The one line of the GitHub log that says what `state` found and what the run does about it.
pub fn stateNotice(a: Allocator, found: Found, idx: common.Index, wheel: meta.Wheel) Error![]const u8 {
    return switch (found.state) {
        .absent => std.fmt.allocPrint(a, "{s} is not on {s}: it is uploaded", .{ wheel.file_name, idx.name }),
        .same => std.fmt.allocPrint(a, "{s} is already on {s} with the same sha256: no upload; the smoke runs", .{ wheel.file_name, idx.name }),
        .differs => std.fmt.allocPrint(a, "{s} is on {s} with sha256 {s}, not {s}: bytes differ at the same version: a commit that changed only documentation, which the stamp ignores; a code commit raises the version. No upload and no smoke.", .{ wheel.file_name, idx.name, found.theirs, &wheel.sha256 }),
    };
}

pub const Report = struct { sha256: [64]u8, size: usize };

/// One attempt of `verify`.
fn verifyOnce(a: Allocator, why: *[]const u8, fetcher: rbf.Fetcher, idx: common.Index, built: meta.Wheel) !void {
    const urls = (try releaseFiles(a, why, fetcher, idx, built)) orelse
        return refuse(a, why, "{s} is not on {s} yet", .{ built.file_name, idx.name });
    const entry = entryOf(urls, built.file_name) orelse
        return refuse(a, why, "{s} is not on {s} yet", .{ built.file_name, idx.name });
    var diffs = std.ArrayList([]const u8).empty;
    if (!std.mem.eql(u8, entry.digests.sha256, &built.sha256))
        try diffs.append(a, try std.fmt.allocPrint(a, "{s}: the index lists sha256 {s}, the built wheel has {s}", .{ built.file_name, entry.digests.sha256, &built.sha256 }));
    if (entry.size != built.bytes.len)
        try diffs.append(a, try std.fmt.allocPrint(a, "{s}: the index lists size {d}, the built wheel has {d}", .{ built.file_name, entry.size, built.bytes.len }));
    if (!std.mem.startsWith(u8, entry.url, idx.files_prefix)) {
        try diffs.append(a, try std.fmt.allocPrint(a, "{s}: the index serves it from {s}, not from {s}", .{ built.file_name, entry.url, idx.files_prefix }));
    } else switch (fetcher.get(a, entry.url, built.bytes.len + 1)) {
        .body => |served| try compareServed(a, built, served, &diffs),
        .status => |s| try diffs.append(a, try std.fmt.allocPrint(a, "GET {s}: HTTP {d}", .{ entry.url, s })),
        .too_large => try diffs.append(a, try std.fmt.allocPrint(a, "GET {s}: the file is larger than the built wheel's {d} bytes", .{ entry.url, built.bytes.len })),
        .bad_url => try diffs.append(a, try std.fmt.allocPrint(a, "{s} is not a URL this tool fetches", .{entry.url})),
        .transport => |e| try diffs.append(a, try std.fmt.allocPrint(a, "GET {s}: {s}", .{ entry.url, @errorName(e) })),
    }
    if (diffs.items.len == 0) return;
    var all = std.Io.Writer.Allocating.init(a);
    try all.writer.print("{d} difference(s) between what {s} serves and the wheel that was built:", .{ diffs.items.len, idx.name });
    for (diffs.items) |line| try all.writer.print("\n  {s}", .{line});
    why.* = all.written();
    return error.Refused;
}

/// The bytes the file host served against the built wheel: sha256 and size, then METADATA.
fn compareServed(a: Allocator, built: meta.Wheel, served: []const u8, diffs: *std.ArrayList([]const u8)) Error!void {
    const hex = common.hexSha(served);
    if (served.len != built.bytes.len or !std.mem.eql(u8, &hex, &built.sha256))
        try diffs.append(a, try std.fmt.allocPrint(a, "{s}: the served bytes have sha256 {s} and size {d}; the built wheel has sha256 {s} and size {d}", .{ built.file_name, &hex, served.len, &built.sha256, built.bytes.len }));
    var inner: []const u8 = "";
    const wheel = meta.parseWheel(a, &inner, served) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Refused => {
            try diffs.append(a, try std.fmt.allocPrint(a, "{s}: the served bytes: {s}", .{ built.file_name, inner }));
            return;
        },
    };
    try meta.metadataDifferences(a, wheel, built, diffs);
}

/// `verify` (header): up to `attempts` attempts, `delay_ms` apart; the refusal of the last one. `log` gets a line
/// for each attempt that failed and is repeated.
pub fn verify(a: Allocator, why: *[]const u8, fetcher: rbf.Fetcher, idx: common.Index, built: meta.Wheel, attempts: u32, delay_ms: u64, log: *std.Io.Writer) !Report {
    var n: u32 = 0;
    while (true) {
        n += 1;
        verifyOnce(a, why, fetcher, idx, built) catch |e| {
            if (e != error.Refused or n >= attempts) return e;
            try log.print("attempt {d} of {d} failed, trying again: {s}\n", .{ n, attempts, why.* });
            try log.flush();
            std.Thread.sleep(delay_ms * std.time.ns_per_ms);
            continue;
        };
        return .{ .sha256 = built.sha256, .size = built.bytes.len };
    }
}
