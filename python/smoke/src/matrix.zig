//! pypi_smoke: the jobs of a workflow that installs the wheel once per supported Python (`matrix`), from the one
//! list of the supported Pythons, python/pythons.bzl, as the build writes it for one platform: the JSON list of the
//! sub-target `//python:supported_pythons[<platform>]`, the exact versions actions/setup-python installs there,
//! oldest first (`["3.11.17","3.12.15","3.13.16","3.14.8"]`).
//!
//! A list that is not a JSON list of strings, a version that is not `3.<minor>.<micro>`, a minor named twice or
//! out of order, and an empty list (a job matrix with no entry is no job at all) are refused. `json` writes the
//! versions as the `include` list of a GitHub job matrix, each with the platform and the hosted runner of its jobs
//! (`platforms` below).
const std = @import("std");
const common = @import("common.zig");

const Allocator = common.Allocator;
const Error = common.Error;
const refuse = common.refuse;

/// A platform whose wheel a workflow installs on a hosted runner, and that runner.
pub const Platform = struct {
    name: []const u8,
    runner: []const u8,
};

/// The platforms a matrix may be written for: the Linux x86_64 wheel's jobs (pypi.yml's user test and Linux
/// smoke jobs) and the macOS arm64 wheel's (the macOS smoke jobs of pypi.yml).
pub const platforms = [_]Platform{
    .{ .name = "linux-x86_64", .runner = "ubuntu-24.04" },
    .{ .name = "macos-arm64", .runner = "macos-15" },
};

pub fn platformNamed(name: []const u8) ?Platform {
    for (platforms) |p| if (std.mem.eql(u8, p.name, name)) return p;
    return null;
}

/// The names of `platforms`, joined by `, `, for a refusal.
pub fn platformNames(a: Allocator) Error![]const u8 {
    var names: [platforms.len][]const u8 = undefined;
    for (platforms, 0..) |p, i| names[i] = p.name;
    return std.mem.join(a, ", ", &names);
}

/// A number of one to three digits without a leading zero.
fn number(s: []const u8) ?u32 {
    if (s.len == 0 or s.len > 3 or (s.len > 1 and s[0] == '0')) return null;
    for (s) |c| if (c < '0' or c > '9') return null;
    return std.fmt.parseInt(u32, s, 10) catch null;
}

/// The minor of `v` if `v` is `3.<minor>.<micro>`, else null.
fn minorOf(v: []const u8) ?u32 {
    var it = std.mem.splitScalar(u8, v, '.');
    const major = it.next().?;
    if (!std.mem.eql(u8, major, "3")) return null;
    const minor = number(it.next() orelse return null) orelse return null;
    _ = number(it.next() orelse return null) orelse return null;
    if (it.next() != null) return null;
    return minor;
}

/// The versions of the list `text` (the file at `path`), in file order.
pub fn parse(a: Allocator, why: *[]const u8, path: []const u8, text: []const u8) Error![]const []const u8 {
    const parsed = std.json.parseFromSlice([]const []const u8, a, text, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return refuse(a, why, "{s} is not a JSON list of strings", .{path}),
    };
    const vs = parsed.value;
    if (vs.len == 0) return refuse(a, why, "{s} names no Python: its jobs would be none", .{path});
    var prev: ?u32 = null;
    for (vs, 0..) |v, i| {
        const minor = minorOf(v) orelse
            return refuse(a, why, "entry {d} of {s} is '{s}', not `3.<minor>.<micro>`", .{ i + 1, path, v });
        if (prev) |p| if (minor <= p)
            return refuse(a, why, "entry {d} of {s} is '{s}', after '{s}': each minor once, oldest first", .{ i + 1, path, v, vs[i - 1] });
        prev = minor;
    }
    return vs;
}

/// The job matrix of `versions` on `platform` as one line of JSON:
/// `{"include":[{"platform":...,"python":...,"runner":...},...]}`. Every value is a platform name, a runner of
/// `platforms` or a checked `3.<minor>.<micro>`, so none needs escaping.
pub fn json(a: Allocator, platform: Platform, versions: []const []const u8) Error![]const u8 {
    var w = std.Io.Writer.Allocating.init(a);
    w.writer.writeAll("{\"include\":[") catch return error.OutOfMemory;
    for (versions, 0..) |v, i| {
        w.writer.print("{s}{{\"platform\":\"{s}\",\"python\":\"{s}\",\"runner\":\"{s}\"}}", .{ if (i == 0) "" else ",", platform.name, v, platform.runner }) catch return error.OutOfMemory;
    }
    w.writer.writeAll("]}") catch return error.OutOfMemory;
    return w.written();
}
