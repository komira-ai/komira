//! pypi_smoke: what `promote` holds before PyPI gets a file. The record (`dist --record`, kept by the run whose
//! TestPyPI smoke passed) is one line `<file name> <sha256> <size>`. TestPyPI must still list that file with
//! those bytes; PyPI must not already hold a newer version of the same wheel tag; the file is downloaded from
//! TestPyPI's file host and must be the recorded bytes and a wheel of that name. TestPyPI versions of the same tag newer than
//! the record have no record that their smoke passed: they are named, and not promoted.
//!
//! Versions are dot-separated decimal numbers compared part by part (`0.1.10` is newer than `0.1.9`; a shorter
//! prefix is older). A version of an index that is not of that form is not compared, and says so.
const std = @import("std");
const common = @import("common.zig");
const meta = @import("meta.zig");
const project = @import("project.zig");
const rbf = @import("release_beta_fetch");

const Allocator = common.Allocator;
const Error = common.Error;
const refuse = common.refuse;

pub const Record = struct {
    file_name: []const u8,
    sha256: []const u8,
    size: u64,
    parsed: meta.FileName,
};

fn isLowerHex(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

/// The record in `text`; `path` names the file in a refusal.
pub fn parseRecord(a: Allocator, why: *[]const u8, path: []const u8, text: []const u8) Error!Record {
    const line = if (std.mem.endsWith(u8, text, "\n")) text[0 .. text.len - 1] else text;
    if (std.mem.indexOfAny(u8, line, "\r\n") != null)
        return refuse(a, why, "--record {s} holds more than one line; exactly one line is wanted", .{path});
    var it = std.mem.splitScalar(u8, line, ' ');
    var parts: [3][]const u8 = undefined;
    var n: usize = 0;
    while (it.next()) |p| : (n += 1) {
        if (n < 3) parts[n] = p;
    }
    if (n != 3) return refuse(a, why, "--record {s} line '{s}' has {d} parts; '<file name> <sha256> <size>' separated by single spaces has 3", .{ path, line, n });
    var inner: []const u8 = "";
    const parsed = meta.parseFileName(a, &inner, parts[0]) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Refused => return refuse(a, why, "--record {s}: {s}", .{ path, inner }),
    };
    if (parts[1].len != 64 or !isLowerHex(parts[1]))
        return refuse(a, why, "--record {s}: the sha256 '{s}' is not 64 lowercase hex digits", .{ path, parts[1] });
    const digits_only = parts[2].len != 0 and std.mem.indexOfNone(u8, parts[2], "0123456789") == null;
    const size = if (digits_only) std.fmt.parseInt(u64, parts[2], 10) catch 0 else 0;
    if (size == 0) return refuse(a, why, "--record {s}: the size '{s}' is not a decimal number of bytes above 0", .{ path, parts[2] });
    if ((try versionParts(a, parsed.version)) == null)
        return refuse(a, why, "--record {s}: the version '{s}' is not dot-separated numbers", .{ path, parsed.version });
    return .{ .file_name = parts[0], .sha256 = parts[1], .size = size, .parsed = parsed };
}

/// The numbers of a dot-separated decimal version; null when it is not one.
fn versionParts(a: Allocator, v: []const u8) Error!?[]const u64 {
    var out = std.ArrayList(u64).empty;
    var it = std.mem.splitScalar(u8, v, '.');
    while (it.next()) |p| {
        if (p.len == 0 or std.mem.indexOfNone(u8, p, "0123456789") != null) return null;
        const n = std.fmt.parseInt(u64, p, 10) catch return null;
        try out.append(a, n);
    }
    return out.items;
}

/// Whether `x` is newer than `y` (both numeric parts).
fn newer(x: []const u64, y: []const u64) bool {
    return std.mem.order(u64, x, y) == .gt;
}

const Candidate = struct { version: []const u8, parts: []const u64 };

fn byAge(_: void, x: Candidate, y: Candidate) bool {
    return newer(y.parts, x.parts);
}

fn holdsFile(files: []const project.Listed, file_name: []const u8) ?project.Listed {
    for (files) |f| if (std.mem.eql(u8, f.filename, file_name)) return f;
    return null;
}

/// The versions of `releases` that list a file `<name>-<version>-<tag>.whl` and are numeric, as candidates
/// (a version that is not numeric is named in `log`).
fn sameTag(a: Allocator, comptime File: type, index_title: []const u8, releases: project.Releases(File), rec: Record, skip: ?[]const u8, log: *std.Io.Writer) !std.ArrayList(Candidate) {
    var out = std.ArrayList(Candidate).empty;
    for (releases.map.keys(), releases.map.values()) |version, files| {
        if (skip != null and std.mem.eql(u8, version, skip.?)) continue;
        const want = try std.fmt.allocPrint(a, "{s}-{s}-{s}.whl", .{ rec.parsed.name, version, rec.parsed.tag });
        var has = false;
        for (files) |f| if (std.mem.eql(u8, f.filename, want)) {
            has = true;
        };
        if (!has) continue;
        const parts = (try versionParts(a, version)) orelse {
            try log.print("pypi_smoke: {s} version {s} is not dot-separated numbers; not compared\n", .{ index_title, version });
            try log.flush();
            continue;
        };
        try out.append(a, .{ .version = version, .parts = parts });
    }
    return out;
}

pub const Result = struct {
    record: Record,
    /// The TestPyPI versions of the same tag newer than the record's, oldest first.
    skipped: []const []const u8,
    bytes: []const u8,
};

fn getFile(a: Allocator, why: *[]const u8, fetcher: rbf.Fetcher, at: []const u8, size: u64) Error![]const u8 {
    switch (fetcher.get(a, at, size + 1)) {
        .body => |b| return b,
        .status => |s| return refuse(a, why, "GET {s}: HTTP {d}", .{ at, s }),
        .too_large => return refuse(a, why, "GET {s}: the file is larger than the recorded {d} bytes", .{ at, size }),
        .bad_url => return refuse(a, why, "{s} is not a URL this tool fetches", .{at}),
        .transport => |e| return refuse(a, why, "GET {s}: {s}", .{ at, @errorName(e) }),
    }
}

/// Every check of the header and the download; nothing is written. `out` is checked to be free at the end,
/// before the caller writes into it.
pub fn check(a: Allocator, why: *[]const u8, fetcher: rbf.Fetcher, record_path: []const u8, out: []const u8, log: *std.Io.Writer) !Result {
    const text = try meta.readFile(a, why, record_path, 4096);
    const rec = try parseRecord(a, why, record_path, text);
    const mine = (try versionParts(a, rec.parsed.version)).?;
    const name = rec.parsed.name;

    const test_releases = (try project.fetch(project.Listed, a, why, fetcher, common.testpypi, name)) orelse
        return refuse(a, why, "TestPyPI has no project {s}", .{name});
    const files = test_releases.map.get(rec.parsed.version) orelse
        return refuse(a, why, "TestPyPI lists no version {s} of {s}; {s} is not on it", .{ rec.parsed.version, name, rec.file_name });
    const entry = holdsFile(files, rec.file_name) orelse
        return refuse(a, why, "TestPyPI does not list {s} under version {s}", .{ rec.file_name, rec.parsed.version });
    var diffs = std.ArrayList([]const u8).empty;
    if (!std.mem.eql(u8, entry.digests.sha256, rec.sha256))
        try diffs.append(a, try std.fmt.allocPrint(a, "TestPyPI lists sha256 {s}, the record has {s}", .{ entry.digests.sha256, rec.sha256 }));
    if (entry.size != rec.size)
        try diffs.append(a, try std.fmt.allocPrint(a, "TestPyPI lists size {d}, the record has {d}", .{ entry.size, rec.size }));
    if (diffs.items.len != 0)
        return refuse(a, why, "{s} on TestPyPI is not the recorded file: {s}", .{ rec.file_name, try std.mem.join(a, "; ", diffs.items) });

    const others = try sameTag(a, project.Listed, "TestPyPI", test_releases, rec, rec.parsed.version, log);
    var skipped = std.ArrayList([]const u8).empty;
    std.mem.sort(Candidate, others.items, {}, byAge);
    for (others.items) |c| if (newer(c.parts, mine)) try skipped.append(a, c.version);

    if (try project.fetch(project.Named, a, why, fetcher, common.pypi, name)) |pypi_releases| {
        const there = try sameTag(a, project.Named, "PyPI", pypi_releases, rec, null, log);
        std.mem.sort(Candidate, there.items, {}, byAge);
        if (there.items.len != 0) {
            const top = there.items[there.items.len - 1];
            if (newer(top.parts, mine))
                return refuse(a, why, "PyPI's newest {s} with tag {s} is {s}, newer than {s}, the newest version whose TestPyPI smoke passed: nothing is promoted (a run of an older commit passed after a newer one)", .{ name, rec.parsed.tag, top.version, rec.parsed.version });
        }
    }

    if (!std.mem.startsWith(u8, entry.url, common.testpypi.files_prefix))
        return refuse(a, why, "TestPyPI serves {s} from {s}, not from {s}", .{ rec.file_name, entry.url, common.testpypi.files_prefix });
    const bytes = try getFile(a, why, fetcher, entry.url, rec.size);
    const hex = common.hexSha(bytes);
    if (bytes.len != rec.size or !std.mem.eql(u8, &hex, rec.sha256))
        return refuse(a, why, "GET {s}: the served bytes have sha256 {s} and size {d}; the record has sha256 {s} and size {d}", .{ entry.url, &hex, bytes.len, rec.sha256, rec.size });
    var inner: []const u8 = "";
    const wheel = meta.parseWheel(a, &inner, bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Refused => return refuse(a, why, "GET {s}: the served bytes: {s}", .{ entry.url, inner }),
    };
    if (!std.mem.eql(u8, wheel.file_name, rec.file_name))
        return refuse(a, why, "GET {s}: the served wheel is named {s} by its METADATA and WHEEL, not {s}", .{ entry.url, wheel.file_name, rec.file_name });
    try common.requireFreeDir(a, why, "--out", out);
    return .{ .record = rec, .skipped = skipped.items, .bytes = bytes };
}

/// Writes the downloaded file as `<out>/<file name>`.
pub fn write(a: Allocator, why: *[]const u8, res: Result, out: []const u8) Error!void {
    std.fs.cwd().makePath(out) catch |e| return refuse(a, why, "cannot make --out {s}: {s}", .{ out, @errorName(e) });
    const path = try std.fs.path.join(a, &.{ out, res.record.file_name });
    std.fs.cwd().writeFile(.{ .sub_path = path, .data = res.bytes }) catch |e|
        return refuse(a, why, "cannot write {s}: {s}", .{ path, @errorName(e) });
}
