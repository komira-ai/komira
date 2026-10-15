//! `run`: a program of node_modules run by the pinned node over a copy of a
//! source tree (modules.bzl, node_tree_test).
//!
//! The copy is made in the action's scratch directory, `node_modules` linked
//! into the package directory, and node run there with an environment of its
//! own: the host's is never inherited.
const std = @import("std");
const unpack = @import("unpack.zig");

pub const Spec = struct {
    /// The staged source tree (a directory), the laid-out node_modules, the
    /// pinned node's root (bin/node) and the directory whose lib/ holds the
    /// C++ runtime node links: all absolute.
    tree: []const u8,
    modules: []const u8,
    node: []const u8,
    libs: []const u8,
    /// The package's directory below the tree, and the program (a path in
    /// it) with its arguments.
    package: []const u8,
    program: []const u8,
    args: []const []const u8,
    /// Variables of the target, added to the fixed ones.
    env: []const [2][]const u8,
    /// A directory of the package to export, or null for a pass marker.
    out_dir: ?[]const u8,
    scratch: []const u8,
};

/// The scratch directory of an action: buck2 names a private one in
/// BUCK_SCRATCH_PATH (relative to the working directory, or absolute); where
/// there is none, a directory of the working directory.
pub fn scratchDir(a: std.mem.Allocator, cwd: []const u8, buck_scratch: ?[]const u8) ![]u8 {
    const s = buck_scratch orelse "";
    if (s.len == 0) return std.fs.path.join(a, &.{ cwd, ".komira_action" });
    return std.fs.path.resolve(a, &.{ cwd, s, "komira" });
}

/// The environment node runs in, and nothing else.
pub fn buildEnv(a: std.mem.Allocator, spec: Spec) !std.process.EnvMap {
    var env = std.process.EnvMap.init(a);
    const home = try std.fs.path.join(a, &.{ spec.scratch, "home" });
    const tmp = try std.fs.path.join(a, &.{ spec.scratch, "tmp" });
    try env.put("LC_ALL", "C");
    try env.put("TZ", "UTC0");
    try env.put("HOME", home);
    try env.put("TMPDIR", tmp);
    try env.put("PATH", try std.fs.path.join(a, &.{ spec.node, "bin" }));
    try env.put("LD_LIBRARY_PATH", try std.fs.path.join(a, &.{ spec.libs, "lib" }));
    for (spec.env) |kv| try env.put(kv[0], kv[1]);
    return env;
}

/// Copies the tree below `src` to `dst`: files 0644, or 0755 if the source is
/// executable (a source's mode may be read-only; the copy is to be written).
pub fn copyTree(a: std.mem.Allocator, src: std.fs.Dir, dst: std.fs.Dir) !void {
    var walker = try src.walk(a);
    defer walker.deinit();
    while (try walker.next()) |e| {
        switch (e.kind) {
            .directory => try dst.makePath(e.path),
            .file => {
                if (std.fs.path.dirname(e.path)) |d| try dst.makePath(d);
                const st = try src.statFile(e.path);
                try src.copyFile(e.path, dst, e.path, .{});
                const f = try dst.openFile(e.path, .{});
                defer f.close();
                try f.chmod(unpack.modeOf(@intCast(st.mode)));
            },
            else => return error.UnsupportedFileKind,
        }
    }
}

fn say(w: anytype, comptime fmt: []const u8, args: anytype) error{Failed} {
    w.print("node_modules: " ++ fmt ++ "\n", args) catch {};
    return error.Failed;
}

/// Runs the program; the result is `out` (a directory or a pass marker).
/// Every refusal is written to `w` and is error.Failed.
pub fn run(a: std.mem.Allocator, spec: Spec, out_path: []const u8, w: anytype) !void {
    const cwd = std.fs.cwd();
    cwd.deleteTree(spec.scratch) catch {};
    defer cwd.deleteTree(spec.scratch) catch {};
    const work_path = try std.fs.path.join(a, &.{ spec.scratch, "work" });
    try cwd.makePath(work_path);
    {
        var src = try cwd.openDir(spec.tree, .{ .iterate = true });
        defer src.close();
        var dst = try cwd.openDir(work_path, .{});
        defer dst.close();
        try copyTree(a, src, dst);
    }
    const pkg_path = try std.fs.path.join(a, &.{ work_path, spec.package });
    try cwd.makePath(pkg_path);
    var pkg = try cwd.openDir(pkg_path, .{});
    defer pkg.close();
    try pkg.symLink(spec.modules, "node_modules", .{ .is_directory = true });
    pkg.access(spec.program, .{}) catch {
        return say(w, "{s} is not in {s}/ (a package missing from node_modules, or a bin it does not declare)", .{ spec.program, spec.package });
    };
    const home = try std.fs.path.join(a, &.{ spec.scratch, "home" });
    const tmp = try std.fs.path.join(a, &.{ spec.scratch, "tmp" });
    try cwd.makePath(home);
    try cwd.makePath(tmp);

    var argv = std.ArrayList([]const u8).init(a);
    try argv.append(try std.fs.path.join(a, &.{ spec.node, "bin", "node" }));
    try argv.append(try std.fs.path.join(a, &.{ pkg_path, spec.program }));
    try argv.appendSlice(spec.args);
    var env = try buildEnv(a, spec);
    var child = std.process.Child.init(argv.items, a);
    child.cwd = pkg_path;
    child.env_map = &env;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = child.spawnAndWait() catch |err| return say(w, "{s}: cannot run node: {s}", .{ spec.program, @errorName(err) });
    switch (term) {
        .Exited => |code| if (code != 0) return say(w, "{s} exited {d}", .{ spec.program, code }),
        .Signal => |sig| return say(w, "{s} was killed by signal {d}", .{ spec.program, sig }),
        else => return say(w, "{s} did not exit normally", .{spec.program}),
    }

    if (spec.out_dir) |od| {
        var from = pkg.openDir(od, .{ .iterate = true }) catch return say(w, "{s} passed but wrote no {s}/", .{ spec.program, od });
        defer from.close();
        try cwd.makePath(out_path);
        var to = try cwd.openDir(out_path, .{});
        defer to.close();
        try copyTree(a, from, to);
    } else {
        const f = try cwd.createFile(out_path, .{});
        f.close();
    }
}
