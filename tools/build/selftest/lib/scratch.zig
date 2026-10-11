//! Scratch trees: a snapshot of the checkout's tracked files (and its
//! `.buckconfig.local`, the farm configuration on a developer's machine)
//! under the scenario's work directory, where a scenario plants a defect without
//! touching the checkout.
//!
//! The trees lie inside the checkout, under buck-out/selftest_tmp (lib.zig).
//! Without a `.buckroot`, buck2 would take the checkout's root as the
//! project root of a tree there and reach the checkout's daemon and files. So every tree
//! gets a `.buckroot`, and `create` refuses a tree for which
//! `buck2 root --kind project` does not print the tree itself.
//! The runner stops the tree's daemon at the end; the scenario then deletes
//! the tree (`--keep-scratch` keeps it).
const std = @import("std");
const Runner = @import("runner.zig").Runner;

pub const Tree = struct {
    root: []const u8,
    files: usize,
};

/// The paths `git ls-files -z` printed.
pub fn splitZ(a: std.mem.Allocator, out: []const u8) ![][]const u8 {
    var res = std.ArrayList([]const u8).init(a);
    var it = std.mem.splitScalar(u8, out, 0);
    while (it.next()) |p| if (p.len > 0) try res.append(p);
    return res.toOwnedSlice();
}

fn copyOne(src_root: std.fs.Dir, dst_root: std.fs.Dir, rel: []const u8) !bool {
    var link_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const st = src_root.statFile(rel) catch |e| switch (e) {
        error.FileNotFound => return false, // tracked, deleted in the working tree
        else => return e,
    };
    if (std.fs.path.dirname(rel)) |d| try dst_root.makePath(d);
    if (src_root.readLink(rel, &link_buf)) |target| {
        try dst_root.symLink(target, rel, .{});
        return true;
    } else |_| {}
    if (st.kind == .directory) return false; // a submodule
    try src_root.copyFile(rel, dst_root, rel, .{});
    return true;
}

/// Snapshots `r.root` into `<tmp>/<name>`.
pub fn create(a: std.mem.Allocator, r: *Runner, tmp: []const u8, name: []const u8, why: *[]const u8) !Tree {
    const root = try std.fs.path.join(a, &.{ tmp, name });
    std.fs.deleteTreeAbsolute(root) catch {};
    std.fs.makeDirAbsolute(root) catch |e| {
        why.* = try std.fmt.allocPrint(a, "cannot create {s}: {s}", .{ root, @errorName(e) });
        return error.Scratch;
    };
    const ls = std.ChildProcess.run(.{
        .allocator = a,
        .argv = &.{ "git", "-C", r.root, "ls-files", "-z", "--cached" },
        .max_output_bytes = 1 << 26,
    }) catch |e| {
        why.* = try std.fmt.allocPrint(a, "cannot run git ls-files in {s}: {s}", .{ r.root, @errorName(e) });
        return error.Scratch;
    };
    if (ls.term != .Exited or ls.term.Exited != 0) {
        why.* = try std.fmt.allocPrint(a, "git ls-files failed in {s}: {s}", .{ r.root, ls.stderr });
        return error.Scratch;
    }
    var src = try std.fs.openDirAbsolute(r.root, .{});
    defer src.close();
    var dst = try std.fs.openDirAbsolute(root, .{});
    defer dst.close();
    var n: usize = 0;
    for (try splitZ(a, ls.stdout)) |rel| {
        const copied = copyOne(src, dst, rel) catch |e| {
            why.* = try std.fmt.allocPrint(a, "cannot copy {s} into {s}: {s}", .{ rel, root, @errorName(e) });
            return error.Scratch;
        };
        if (copied) n += 1;
    }
    _ = copyOne(src, dst, ".buckconfig.local") catch false;
    dst.writeFile(".buckroot", "") catch |e| {
        why.* = try std.fmt.allocPrint(a, "cannot write {s}/.buckroot: {s}", .{ root, @errorName(e) });
        return error.Scratch;
    };
    const tree = Tree{ .root = root, .files = n };

    // The tree must be its own project root. `buck2 root` starts no daemon,
    // and the tree's daemon is tracked (stopped at the end) only once the
    // root is the tree's: otherwise `buck2 kill` there would stop the
    // checkout's own daemon, the one running this test.
    const res = try r.run(&.{ "root", "--kind", "project" }, .{ .configured = false, .cwd = root, .track = false });
    const got = std.mem.trim(u8, res.stdout, " \r\n");
    const real = try std.fs.realpathAlloc(a, root);
    if (!res.ok() or !std.mem.eql(u8, got, real)) {
        why.* = try std.fmt.allocPrint(a, "the scratch tree {s} is not its own project root: buck2 root --kind project printed `{s}` (see {s})", .{ real, got, res.log });
        return error.Scratch;
    }
    return tree;
}

/// Writes `bytes` at `rel` in the tree.
pub fn plant(tree: Tree, rel: []const u8, bytes: []const u8) !void {
    var d = try std.fs.openDirAbsolute(tree.root, .{});
    defer d.close();
    if (std.fs.path.dirname(rel)) |p| try d.makePath(p);
    try d.writeFile(rel, bytes);
}

/// Copies `from` to `to` inside the tree.
pub fn copy(tree: Tree, from: []const u8, to: []const u8) !void {
    var d = try std.fs.openDirAbsolute(tree.root, .{});
    defer d.close();
    if (std.fs.path.dirname(to)) |p| try d.makePath(p);
    try d.copyFile(from, d, to, .{});
}

pub fn destroy(tree: Tree) void {
    std.fs.deleteTreeAbsolute(tree.root) catch {};
}
