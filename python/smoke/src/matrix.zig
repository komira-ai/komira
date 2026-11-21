//! pypi_smoke: the jobs of the user test of the wheel (`matrix`), from the one list of the Pythons and platforms
//! the package is tested on after every merge, python/supported_pythons.tsv.
//!
//! The list has one row per pair, `<platform><TAB><python>`; a line that starts with `#` and an empty line are
//! skipped. The platform is one whose wheel a workflow builds and installs on every merge (`platforms` below
//! says which, and the hosted runner its job runs on); the Python is a CPython version as actions/setup-python
//! spells it, `3.<minor>`. A row that is not two fields, a platform not in `platforms`, a Python that is not
//! `3.<minor>` and a row given twice are refused, each naming its line. `matrix` keeps the rows of one platform,
//! in file order, and writes them as the `include` list of a GitHub job matrix; a platform with no row is refused,
//! because a job matrix with no entry is no job at all.
const std = @import("std");
const common = @import("common.zig");

const Allocator = common.Allocator;
const Error = common.Error;
const refuse = common.refuse;

/// A platform whose wheel is built and installed on every merge, and the GitHub-hosted runner of its job.
pub const Platform = struct {
    name: []const u8,
    runner: []const u8,
};

/// The platforms a row may name. release.yml builds the Linux x86_64 wheel on every merge; a platform joins this
/// table in the change that builds its wheel on every merge too.
pub const platforms = [_]Platform{
    .{ .name = "linux-x86_64", .runner = "ubuntu-24.04" },
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

/// One row of the list.
pub const Row = struct {
    platform: Platform,
    python: []const u8,
    /// The row's line in the file, from 1.
    line: usize,
};

/// Whether `v` is `3.<minor>`: a minor of one to three digits without a leading zero.
fn isPython(v: []const u8) bool {
    if (!std.mem.startsWith(u8, v, "3.")) return false;
    const minor = v[2..];
    if (minor.len == 0 or minor.len > 3 or (minor.len > 1 and minor[0] == '0')) return false;
    for (minor) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// The rows of the list `text` (the file at `path`), in file order.
pub fn parse(a: Allocator, why: *[]const u8, path: []const u8, text: []const u8) Error![]Row {
    var rows = std.ArrayList(Row).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (it.next()) |line| {
        n += 1;
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const platform = fields.next().?;
        const python = fields.next() orelse
            return refuse(a, why, "line {d} of {s} is '{s}', not `<platform><TAB><python>`", .{ n, path, line });
        if (fields.next() != null)
            return refuse(a, why, "line {d} of {s} is '{s}', not `<platform><TAB><python>`", .{ n, path, line });
        const p = platformNamed(platform) orelse
            return refuse(a, why, "line {d} of {s} names the platform '{s}', whose wheel no workflow builds and installs on every merge (the platforms: {s})", .{ n, path, platform, try platformNames(a) });
        if (!isPython(python))
            return refuse(a, why, "line {d} of {s} names the Python '{s}', not `3.<minor>`", .{ n, path, python });
        for (rows.items) |r| {
            if (std.mem.eql(u8, r.platform.name, p.name) and std.mem.eql(u8, r.python, python))
                return refuse(a, why, "line {d} of {s} repeats line {d} ({s}, Python {s})", .{ n, path, r.line, p.name, python });
        }
        try rows.append(a, .{ .platform = p, .python = python, .line = n });
    }
    return rows.toOwnedSlice(a);
}

/// The rows of `platform`, in file order; none is a refusal.
pub fn forPlatform(a: Allocator, why: *[]const u8, path: []const u8, rows: []const Row, platform: Platform) Error![]const Row {
    var out = std.ArrayList(Row).empty;
    for (rows) |r| {
        if (std.mem.eql(u8, r.platform.name, platform.name)) try out.append(a, r);
    }
    if (out.items.len == 0)
        return refuse(a, why, "{s} has no row for the platform {s}: its user test would have no job", .{ path, platform.name });
    return out.toOwnedSlice(a);
}

/// The job matrix of `rows` as one line of JSON: `{"include":[{"platform":...,"python":...,"runner":...},...]}`.
/// Every value is a platform name, a runner of `platforms` or a checked `3.<minor>`, so none needs escaping.
pub fn json(a: Allocator, rows: []const Row) Error![]const u8 {
    var w = std.Io.Writer.Allocating.init(a);
    w.writer.writeAll("{\"include\":[") catch return error.OutOfMemory;
    for (rows, 0..) |r, i| {
        w.writer.print("{s}{{\"platform\":\"{s}\",\"python\":\"{s}\",\"runner\":\"{s}\"}}", .{ if (i == 0) "" else ",", r.platform.name, r.python, r.platform.runner }) catch return error.OutOfMemory;
    }
    w.writer.writeAll("]}") catch return error.OutOfMemory;
    return w.written();
}
