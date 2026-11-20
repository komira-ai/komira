//! komira_wheel: what the command reads from its flags and the file system:
//! `<name>=<file>` flags, the files of a directory, the output directory a
//! check reads, and the flag values it holds against the pyproject. Each
//! refusal is returned in a Diag (wheel_project.zig), so komira_wheel.zig only
//! forwards to these and exits on a refusal.

const std = @import("std");
const project = @import("wheel_project.zig");
const wheel = @import("wheel.zig");
const Alloc = std.mem.Allocator;
const Diag = project.Diag;
const Refused = project.Refused;
const refuse = project.refuse;

const max_file = 8 * 1024 * 1024 * 1024 - 1;

/// `<name>=<file>`, split at the first `=`; both parts non-empty.
pub fn named(alloc: Alloc, d: *Diag, arg: []const u8, flag: []const u8) Refused![2][]const u8 {
    const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return refuse(d, alloc, "{s} `{s}` is not <name>=<file>", .{ flag, arg });
    if (eq == 0 or eq + 1 == arg.len) return refuse(d, alloc, "{s} `{s}` is not <name>=<file>", .{ flag, arg });
    return .{ arg[0..eq], arg[eq + 1 ..] };
}

/// Every regular file under `root`, at its path relative to it, in the order
/// the file system gives (the builder sorts). A file of `native` is mode 0755
/// (a shared library); any other keeps 0755 only if it has an exec bit. A
/// symbolic link or a special file is refused.
pub fn walk(alloc: Alloc, d: *Diag, root: []const u8, native: bool) Refused![]wheel.File {
    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch |err|
        return refuse(d, alloc, "cannot open {s}: {s}", .{ root, @errorName(err) });
    defer dir.close();
    var w = try dir.walk(alloc);
    defer w.deinit();
    var list = std.ArrayList(wheel.File).empty;
    while (w.next() catch |err| return refuse(d, alloc, "cannot read {s}: {s}", .{ root, @errorName(err) })) |entry| {
        switch (entry.kind) {
            .directory => {},
            .file => {
                const path = try alloc.dupe(u8, entry.path);
                const st = dir.statFile(path) catch |err| return refuse(d, alloc, "cannot stat {s}/{s}: {s}", .{ root, path, @errorName(err) });
                const data = dir.readFileAlloc(alloc, path, max_file) catch |err| return refuse(d, alloc, "cannot read {s}/{s}: {s}", .{ root, path, @errorName(err) });
                try list.append(alloc, .{
                    .path = path,
                    .data = data,
                    .mode = if (native or (st.mode & 0o111) != 0) 0o755 else 0o644,
                });
            },
            else => return refuse(d, alloc, "{s}/{s}: not a regular file or directory ({s})", .{ root, entry.path, @tagName(entry.kind) }),
        }
    }
    return list.toOwnedSlice(alloc);
}

/// An output directory as `check` reads it: its file names and its one wheel.
pub const Listing = struct {
    names: []const []const u8,
    wheel_name: []const u8,
};

pub fn listDir(alloc: Alloc, d: *Diag, path: []const u8) Refused!Listing {
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err|
        return refuse(d, alloc, "cannot open {s}: {s}", .{ path, @errorName(err) });
    defer dir.close();
    var names = std.ArrayList([]const u8).empty;
    var wheel_name: ?[]const u8 = null;
    var it = dir.iterate();
    while (it.next() catch |err| return refuse(d, alloc, "cannot read {s}: {s}", .{ path, @errorName(err) })) |entry| {
        if (entry.kind != .file) return refuse(d, alloc, "{s}/{s}: not a regular file", .{ path, entry.name });
        const n = try alloc.dupe(u8, entry.name);
        try names.append(alloc, n);
        if (!std.mem.endsWith(u8, n, ".whl")) continue;
        if (wheel_name != null) return refuse(d, alloc, "{s} holds two wheels", .{path});
        wheel_name = n;
    }
    return .{ .names = try names.toOwnedSlice(alloc), .wheel_name = wheel_name orelse return refuse(d, alloc, "{s} holds no wheel", .{path}) };
}

/// `--require-stamped`: `true` or `false`, nothing else.
pub fn flagBool(alloc: Alloc, d: *Diag, flag: []const u8, v: []const u8) Refused!bool {
    if (std.mem.eql(u8, v, "true")) return true;
    if (std.mem.eql(u8, v, "false")) return false;
    return refuse(d, alloc, "{s} is `{s}`, not true or false", .{ flag, v });
}

/// The distribution the rule names (to name the wheel's file) must be the
/// pyproject's.
pub fn checkDistribution(alloc: Alloc, d: *Diag, name: []const u8, p: project.Project) Refused!void {
    if (!std.mem.eql(u8, name, p.name)) return refuse(d, alloc, "--name is `{s}`, but the pyproject's name is `{s}`", .{ name, p.name });
}

/// Each requirement the build adds is one non-empty METADATA line.
pub fn checkRequirements(alloc: Alloc, d: *Diag, reqs: []const []const u8) Refused!void {
    for (reqs) |r| if (r.len == 0 or std.mem.indexOfAny(u8, r, "\r\n") != null)
        return refuse(d, alloc, "--runtime-requires `{s}` is empty or holds a line break", .{r});
}
