// Why Zig: build tools are Zig (tools/build/README.md). This replaces
// proto_check.sh and the case script of proto_check.bzl (busybox shell), so that
// the check runs no shell.
//! proto_check: refuses a googleapis proto tree unless it is exactly the import
//! closure of its roots.
//!
//! usage: proto_check check <protoc dir> <tree> <out set> <out tree> <root>...
//!        proto_check case <expect> <verdict> <protoc dir> <tree> <root>...
//!
//! <protoc dir> is the protoc distribution (bin/protoc, include/), <tree> the
//! files staged at their import paths (extracted from the pinned googleapis
//! archive, whose sha256 the download itself checks), and the roots import
//! paths in the tree. `check` refuses (exit 1, `proto_check: <reason>` on
//! stderr), naming the file, unless
//!   - the tree holds nothing under google/protobuf/ (protoc's own);
//!   - protoc parses the roots with nothing on its path but the tree and
//!     protoc's include/, so a file the closure needs and the tree lacks fails
//!     here; and
//!   - every file of the tree is in the descriptor set protoc writes for the
//!     roots (--include_imports), so the tree holds the closure and nothing
//!     else.
//! Only then does it write <out set> (that descriptor set) and <out tree> (a
//! copy of the tree), so nothing reads a tree that is not exactly the closure.
//!
//! `case` runs the same check into a scratch directory and asserts its verdict:
//! accepted (the set is not empty and the written tree equals the staged one)
//! when <expect> is empty, otherwise refused with a message holding <expect>
//! and with nothing written; it writes `accepted`, or `refused` and the
//! message, to <verdict>.

const std = @import("std");
const A = std.mem.Allocator;

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The relative paths of the files and links of `dir`, sorted.
pub fn listFiles(a: A, dir: std.fs.Dir) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    var w = try dir.walk(a);
    while (try w.next()) |e| {
        if (e.kind == .directory) continue;
        try out.append(a, try a.dupe(u8, e.path));
    }
    std.mem.sort([]const u8, out.items, {}, lessThan);
    return out.toOwnedSlice(a);
}

fn readVarint(d: []const u8, at: *usize) !u64 {
    var v: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        if (at.* >= d.len or shift > 63) return error.BadDescriptorSet;
        const b = d[at.*];
        at.* += 1;
        v |= @as(u64, b & 0x7f) << shift;
        if (b & 0x80 == 0) return v;
        shift += 7;
    }
}

/// Skips the field of wire type `wt` at `at`; returns its length-delimited
/// payload when it is one.
fn field(d: []const u8, at: *usize, wt: u64) !?[]const u8 {
    switch (wt) {
        0 => {
            _ = try readVarint(d, at);
            return null;
        },
        1 => at.* += 8,
        5 => at.* += 4,
        2 => {
            const n = try readVarint(d, at);
            if (n > d.len - at.*) return error.BadDescriptorSet;
            const p = d[at.* .. at.* + n];
            at.* += n;
            return p;
        },
        else => return error.BadDescriptorSet,
    }
    if (at.* > d.len) return error.BadDescriptorSet;
    return null;
}

/// The `name` (field 1) of every `file` (field 1) of a FileDescriptorSet.
pub fn setNames(a: A, set: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    var at: usize = 0;
    while (at < set.len) {
        const key = try readVarint(set, &at);
        const payload = try field(set, &at, key & 7);
        if (key >> 3 != 1 or payload == null) continue;
        const f = payload.?;
        var p: usize = 0;
        while (p < f.len) {
            const k = try readVarint(f, &p);
            const inner = try field(f, &p, k & 7);
            if (k >> 3 == 1 and inner != null) {
                try out.append(a, inner.?);
                break;
            }
        }
    }
    return out.toOwnedSlice(a);
}

/// The first reason the tree is not exactly the closure, or null. `tree` and
/// `closure` are sorted.
pub fn mismatch(a: A, tree: []const []const u8, closure: []const []const u8) !?[]u8 {
    for (closure) |c| {
        if (!has(tree, c)) return try std.fmt.allocPrint(a, "{s} is in the import closure but not in the tree", .{c});
    }
    return null;
}

fn has(sorted: []const []const u8, x: []const u8) bool {
    return std.sort.binarySearch([]const u8, sorted, x, struct {
        fn f(k: []const u8, item: []const u8) std.math.Order {
            return std.mem.order(u8, k, item);
        }
    }.f) != null;
}

/// The failure message of the check, or null when the tree is the closure and
/// the descriptor set was written.
fn check(a: A, protoc: []const u8, tree_path: []const u8, out_set: []const u8, out_tree: []const u8, roots: []const []const u8) !?[]u8 {
    if (roots.len == 0) return try a.dupe(u8, "the target names no root");
    var tree = try std.fs.cwd().openDir(tree_path, .{ .iterate = true });
    defer tree.close();
    const files = try listFiles(a, tree);
    if (files.len == 0) return try a.dupe(u8, "the tree holds no file");
    for (files) |f| {
        if (std.mem.startsWith(u8, f, "google/protobuf/"))
            return try std.fmt.allocPrint(a, "{s} is in the tree, but google/protobuf/ is protoc's own (its include/)", .{f});
    }
    const scratch_base = std.process.getEnvVarOwned(a, "BUCK_SCRATCH_PATH") catch try a.dupe(u8, ".proto_check");
    const scratch = try std.fs.path.join(a, &.{ scratch_base, "proto_check" });
    try std.fs.cwd().deleteTree(scratch);
    try std.fs.cwd().makePath(scratch);
    defer std.fs.cwd().deleteTree(scratch) catch {};
    const set_path = try std.fs.path.join(a, &.{ scratch, "set.pb" });
    var argv = std.ArrayList([]const u8).empty;
    try argv.appendSlice(a, &.{
        try std.fs.path.join(a, &.{ protoc, "bin/protoc" }),
        "-I",
        tree_path,
        "-I",
        try std.fs.path.join(a, &.{ protoc, "include" }),
        "--include_imports",
        try std.fmt.allocPrint(a, "--descriptor_set_out={s}", .{set_path}),
    });
    try argv.appendSlice(a, roots);
    const r = try std.process.Child.run(.{ .allocator = a, .argv = argv.items, .max_output_bytes = 1 << 24 });
    const ok = switch (r.term) {
        .Exited => |c| c == 0,
        else => false,
    };
    if (!ok) return try std.fmt.allocPrint(a, "protoc cannot parse the roots from the tree: {s}", .{std.mem.trimRight(u8, r.stderr, "\n")});
    const set = try std.fs.cwd().readFileAlloc(a, set_path, 1 << 28);
    var closure = std.ArrayList([]const u8).empty;
    for (setNames(a, set) catch return try a.dupe(u8, "protoc cannot decode the descriptor set")) |n| {
        if (!std.mem.startsWith(u8, n, "google/protobuf/")) try closure.append(a, n);
    }
    std.mem.sort([]const u8, closure.items, {}, lessThan);
    if (closure.items.len == 0) return try a.dupe(u8, "the descriptor set names no file");
    for (files) |f| {
        if (!has(closure.items, f)) return try std.fmt.allocPrint(a, "{s} is in the tree but not in the import closure of the roots", .{f});
    }
    if (try mismatch(a, files, closure.items)) |m| return m;
    try writeAll(out_set, set);
    try copyTree(a, tree, files, out_tree);
    return null;
}

fn writeAll(path: []const u8, data: []const u8) !void {
    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(data);
}

fn copyTree(a: A, src: std.fs.Dir, files: []const []const u8, dest: []const u8) !void {
    try std.fs.cwd().makePath(dest);
    for (files) |f| {
        const to = try std.fs.path.join(a, &.{ dest, f });
        if (std.fs.path.dirname(to)) |d| try std.fs.cwd().makePath(d);
        const data = try src.readFileAlloc(a, f, 1 << 28);
        try writeAll(to, data);
    }
}

fn sameTree(a: A, x: []const u8, y: []const u8) !bool {
    var dx = try std.fs.cwd().openDir(x, .{ .iterate = true });
    defer dx.close();
    var dy = try std.fs.cwd().openDir(y, .{ .iterate = true });
    defer dy.close();
    const fx = try listFiles(a, dx);
    const fy = try listFiles(a, dy);
    if (fx.len != fy.len) return false;
    for (fx, fy) |p, q| {
        if (!std.mem.eql(u8, p, q)) return false;
        const bx = try dx.readFileAlloc(a, p, 1 << 28);
        const by = try dy.readFileAlloc(a, q, 1 << 28);
        if (!std.mem.eql(u8, bx, by)) return false;
    }
    return true;
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("proto_check: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len >= 7 and std.mem.eql(u8, argv[1], "check")) {
        if (try check(a, argv[2], argv[3], argv[4], argv[5], argv[6..])) |msg| die("{s}", .{msg});
        return;
    }
    if (argv.len >= 6 and std.mem.eql(u8, argv[1], "case")) {
        const expect = argv[2];
        const verdict = argv[3];
        const base = std.process.getEnvVarOwned(a, "BUCK_SCRATCH_PATH") catch try a.dupe(u8, ".proto_check_case");
        const t = try std.fs.path.join(a, &.{ base, "proto_check_case" });
        try std.fs.cwd().deleteTree(t);
        try std.fs.cwd().makePath(t);
        defer std.fs.cwd().deleteTree(t) catch {};
        const set = try std.fs.path.join(a, &.{ t, "set.pb" });
        const out_tree = try std.fs.path.join(a, &.{ t, "tree" });
        const msg = try check(a, argv[4], argv[5], set, out_tree, argv[6..]);
        if (expect.len == 0) {
            if (msg) |m| die("proto_check_case: the check refused a tree it must accept:\nproto_check: {s}", .{m});
            const st = std.fs.cwd().statFile(set) catch die("proto_check_case: the check wrote no descriptor set", .{});
            if (st.size == 0) die("proto_check_case: the check wrote no descriptor set", .{});
            if (!try sameTree(a, argv[5], out_tree)) die("proto_check_case: the checked tree differs from the staged one", .{});
            try writeAll(verdict, "accepted\n");
        } else {
            const m = msg orelse die("proto_check_case: the check accepted a tree it must refuse with: {s}", .{expect});
            const full = try std.fmt.allocPrint(a, "proto_check: {s}\n", .{m});
            if (std.mem.indexOf(u8, full, expect) == null) die("proto_check_case: the check refused, but not with: {s}\n{s}", .{ expect, full });
            if (std.fs.cwd().access(set, .{})) |_| {
                die("proto_check_case: the check refused but wrote an output", .{});
            } else |_| {}
            if (std.fs.cwd().access(out_tree, .{})) |_| {
                die("proto_check_case: the check refused but wrote an output", .{});
            } else |_| {}
            try writeAll(verdict, try std.fmt.allocPrint(a, "refused\n{s}", .{full}));
        }
        return;
    }
    die("usage: proto_check check <protoc dir> <tree> <out set> <out tree> <root>... | case <expect> <verdict> <protoc dir> <tree> <root>...", .{});
}
