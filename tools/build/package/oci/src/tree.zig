//! `komira_oci tree`: bundles and files laid at paths in one directory, the
//! tree `oci_image` lays at / in an image.
//!
//! The places are refused unless every path is plain (no empty, `.` or `..`
//! part; letters, digits and `_.+-`), a bundle's ends in /, and no path is
//! inside another, so no copy overwrites another's file (a file at
//! `app/bin/x` beside a bundle at `app/` would replace the bundle's
//! program). `lay` takes only a `Plan`, which `plan` makes after those
//! refusals. Modes are 0755 for directories and for files with any exec
//! bit, else 0644; a bundle holds regular files and directories only.

const std = @import("std");
const C = @import("common.zig");
const Fail = C.Fail;

pub const Place = struct {
    /// The path in the tree; a bundle's ends in /.
    path: []const u8,
    src: []const u8,
    bundle: bool,
};

/// Places `plan` accepted.
pub const Plan = struct { places: []const Place };

/// What `plan` answers: the plan, or every reason the places are refused.
pub const Planned = union(enum) { plan: Plan, refused: [][]const u8 };

fn plain(p: []const u8) bool {
    if (p.len == 0) return false;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |c| {
        if (c.len == 0 or C.eql(c, ".") or C.eql(c, "..")) return false;
        for (c) |b| {
            if (!(std.ascii.isAlphanumeric(b) or b == '_' or b == '.' or b == '+' or b == '-')) return false;
        }
    }
    return true;
}

fn strLess(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

/// The places, or every reason they are refused.
pub fn plan(places: []const Place) Planned {
    var out = C.list([]const u8);
    if (places.len == 0) C.push([]const u8, &out, "an empty tree");
    for (places) |p| {
        if (p.bundle and !(C.endsWith(p.path, "/") and plain(p.path[0 .. p.path.len - 1]))) {
            C.push([]const u8, &out, C.fmt("bundle path `{s}` must be a plain relative path ending in /", .{p.path}));
        }
        if (!p.bundle and !plain(p.path)) {
            C.push([]const u8, &out, C.fmt("file path `{s}` must be a plain relative path", .{p.path}));
        }
    }
    const paths = C.a().alloc([]const u8, places.len) catch C.oom();
    for (places, 0..) |p, i| paths[i] = p.path;
    std.mem.sort([]const u8, paths, {}, strLess);
    for (paths, 0..) |p, i| {
        if (i > 0 and C.eql(paths[i - 1], p)) C.push([]const u8, &out, C.fmt("`{s}` given twice", .{p}));
        const dir = if (C.endsWith(p, "/")) p else C.fmt("{s}/", .{p});
        for (paths) |q| {
            if (!C.eql(q, p) and C.startsWith(q, dir)) C.push([]const u8, &out, C.fmt("`{s}` is inside `{s}`", .{ q, p }));
        }
    }
    if (out.items.len == 0) return .{ .plan = .{ .places = places } };
    return .{ .refused = out.items };
}

fn modeFor(src: C.Stat) u32 {
    return if (src.mode & 0o111 != 0) 0o755 else 0o644;
}

fn chmod(p: []const u8, mode: u32) Fail!void {
    C.chmod(p, mode) catch |e| return C.fail("cannot chmod {s}: {s}", .{ p, C.ioErr(e) });
}

fn mkdir(p: []const u8) Fail!void {
    std.fs.cwd().makeDir(p) catch |e| return C.fail("cannot create {s}: {s}", .{ p, C.ioErr(e) });
    try chmod(p, 0o755);
}

/// `dir` under `out`, each missing part made with mode 0755.
pub fn mkdirs(out: []const u8, dir: []const u8) Fail!void {
    var at: []const u8 = out;
    var it = std.mem.splitScalar(u8, dir, '/');
    while (it.next()) |c| {
        if (c.len == 0) continue;
        at = C.pathJoin(at, c);
        if (C.lstat(at)) |m| {
            if (!m.isDir()) return C.fail("{s}: not a directory", .{at});
        } else |_| try mkdir(at);
    }
}

pub fn copyFile(src: []const u8, dest: []const u8) Fail!void {
    const m = C.stat(src) catch |e| return C.fail("cannot read {s}: {s}", .{ src, C.ioErr(e) });
    if (!m.isFile()) return C.fail("{s}: not a regular file", .{src});
    if (C.lstat(dest)) |_| {
        return C.fail("{s}: already in the tree", .{dest});
    } else |_| {}
    copyBytes(src, dest) catch |e| return C.fail("cannot copy {s} to {s}: {s}", .{ src, dest, C.ioErr(e) });
    try chmod(dest, modeFor(m));
}

fn copyBytes(src: []const u8, dest: []const u8) !void {
    try C.writeFile(dest, try C.readFile(src));
}

fn nameLess(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

/// Whether it copied any file.
fn copyDir(src: []const u8, dest: []const u8) Fail!bool {
    try mkdir(dest);
    var names = C.list([]const u8);
    {
        var d = std.fs.cwd().openDir(src, .{ .iterate = true }) catch |e| return C.fail("cannot read {s}: {s}", .{ src, C.ioErr(e) });
        defer d.close();
        var it = d.iterate();
        while (it.next() catch |e| return C.fail("cannot read {s}: {s}", .{ src, C.ioErr(e) })) |ent| {
            C.push([]const u8, &names, C.dupe(ent.name));
        }
    }
    std.mem.sort([]const u8, names.items, {}, nameLess);
    var any = false;
    for (names.items) |n| {
        const s = C.pathJoin(src, n);
        const d = C.pathJoin(dest, n);
        const m = C.lstat(s) catch |e| return C.fail("cannot read {s}: {s}", .{ s, C.ioErr(e) });
        if (m.isDir()) {
            if (try copyDir(s, d)) any = true;
        } else if (m.isFile()) {
            try copyFile(s, d);
            any = true;
        } else {
            return C.fail("{s}: not a regular file or directory", .{s});
        }
    }
    return any;
}

/// Lays the plan's places under `out`, a directory not yet there.
pub fn lay(out: []const u8, p: Plan) Fail!void {
    try mkdir(out);
    for (p.places) |pl| {
        const rel = std.mem.trimRight(u8, pl.path, "/");
        const parent = if (std.mem.lastIndexOfScalar(u8, rel, '/')) |i| rel[0..i] else "";
        try mkdirs(out, parent);
        const dest = C.pathJoin(out, rel);
        if (pl.bundle) {
            if (!try copyDir(pl.src, dest)) return C.fail("bundle {s} holds no files", .{pl.src});
        } else {
            try copyFile(pl.src, dest);
        }
    }
}
