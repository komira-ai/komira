//! `assemble`: node_modules laid out from a lockfileVersion 3
//! package-lock.json and the pinned tarballs (modules.bzl, npm_modules).
//!
//! Per package: a tarball is pinned for it; the pinned lock's sri512 equals
//! the lockfile's integrity; the tarball's sha512 equals it; its package.json
//! states the locked name and version. Nothing runs: no install script.
const std = @import("std");
const platform = @import("platform.zig");
const sri = @import("sri.zig");
const unpack = @import("unpack.zig");

const NM = "node_modules/";

pub const Spec = struct {
    /// The text of package-lock.json.
    lockfile: []const u8,
    /// `name@version` -> the path of its .tgz.
    tarballs: std.StringHashMap([]const u8),
    /// `name@version` -> the sri512 of the pinned lock (kpin).
    sri512: std.StringHashMap([]const u8),
};

const WithBin = struct { path: []const u8, entry: std.json.Value };

fn str(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .string) x.string else null;
}

fn flag(v: std.json.Value, key: []const u8) bool {
    if (v != .object) return false;
    const x = v.object.get(key) orelse return false;
    return x == .bool and x.bool;
}

fn shorterFirst(_: void, x: []const u8, y: []const u8) bool {
    if (x.len != y.len) return x.len < y.len;
    return std.mem.lessThan(u8, x, y);
}

const Report = struct {
    installed: usize,
    installScriptsNotRun: []const []const u8,
    skipped: []const []const u8,
};

/// Lays the tree out in `out` (an open directory; `out_path` is its path).
/// Every problem is written to `w` as a `node_modules:` line; any problem
/// makes the result error.Failed (the tree is then not to be used).
pub fn assemble(a: std.mem.Allocator, spec: Spec, out: std.fs.Dir, out_path: []const u8, w: anytype) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, a, spec.lockfile, .{}) catch {
        try w.print("node_modules: the lockfile is not JSON\n", .{});
        return error.Failed;
    };
    const root = parsed.value;
    const lv = if (root == .object) root.object.get("lockfileVersion") else null;
    const pk = if (root == .object) root.object.get("packages") else null;
    if (lv == null or lv.? != .integer or lv.?.integer != 3 or pk == null or pk.? != .object) {
        try w.print("node_modules: the lockfile is not a lockfileVersion 3 package-lock.json\n", .{});
        return error.Failed;
    }
    const packages = pk.?.object;

    var problems = std.ArrayList([]const u8).init(a);
    var installed: usize = 0;
    var skipped = std.ArrayList([]const u8).init(a);
    var scripts = std.ArrayList([]const u8).init(a);
    var with_bin = std.ArrayList(WithBin).init(a);

    var paths = std.ArrayList([]const u8).init(a);
    for (packages.keys()) |k| {
        if (k.len > 0) try paths.append(k);
    }
    std.mem.sort([]const u8, paths.items, {}, shorterFirst);

    for (paths.items) |p| {
        const e = packages.get(p).?;
        if (e != .object) continue;
        if (!std.mem.startsWith(u8, p, NM)) continue; // a workspace member: no tarball
        if (flag(e, "link")) continue;
        const at = std.mem.lastIndexOf(u8, p, NM).?;
        const name = str(e, "name") orelse p[at + NM.len ..];
        const version = str(e, "version") orelse {
            try problems.append(try std.fmt.allocPrint(a, "{s} ({s}) has no version", .{ name, p }));
            continue;
        };
        const key = try std.fmt.allocPrint(a, "{s}@{s}", .{ name, version });
        const rel = p[NM.len..];
        if (flag(e, "hasInstallScript")) try scripts.append(try std.fmt.allocPrint(a, "{s} {s}", .{ p, key }));

        const fields = [_]struct { name: []const u8, current: []const u8 }{
            .{ .name = "os", .current = platform.os },
            .{ .name = "cpu", .current = platform.cpu },
            .{ .name = "libc", .current = platform.libc },
        };
        var refused: ?[]const u8 = null;
        var refused_current: []const u8 = "";
        for (fields) |f| {
            const list = if (e == .object) e.object.get(f.name) else null;
            if (!platform.ok(list, f.current)) {
                refused = f.name;
                refused_current = f.current;
                break;
            }
        }
        if (refused) |field| {
            const list = try std.json.stringifyAlloc(a, e.object.get(field).?, .{});
            if (flag(e, "optional")) {
                try skipped.append(try std.fmt.allocPrint(a, "{s} {s}: optional, {s} {s} excludes {s}", .{ p, key, field, list, refused_current }));
            } else {
                try problems.append(try std.fmt.allocPrint(a, "{s} ({s}) needs {s} {s} and is not optional", .{ key, p, field, list }));
            }
            continue;
        }

        if (flag(e, "inBundle")) {
            // Inside its parent's tarball: it must be there.
            const pj = try std.fmt.allocPrint(a, "{s}/package.json", .{rel});
            out.access(pj, .{}) catch {
                try problems.append(try std.fmt.allocPrint(a, "{s} ({s}) is bundled but its parent's tarball holds no {s}/package.json", .{ key, p, p }));
                continue;
            };
            if (e.object.get("bin") != null) try with_bin.append(.{ .path = p, .entry = e });
            continue;
        }

        const tarball = spec.tarballs.get(key) orelse {
            try problems.append(try std.fmt.allocPrint(a, "{s} ({s}) has no pinned tarball: pins.lock.bzl is stale (kpin update)", .{ key, p }));
            continue;
        };
        const want = str(e, "integrity") orelse "";
        if (!std.mem.startsWith(u8, want, sri.prefix)) {
            try problems.append(try std.fmt.allocPrint(a, "{s} ({s}) has no sha512 integrity in the lockfile", .{ key, p }));
            continue;
        }
        const pinned = spec.sri512.get(key) orelse "undefined";
        if (!std.mem.eql(u8, pinned, want)) {
            try problems.append(try std.fmt.allocPrint(a, "{s}: the lockfile says {s}, the pinned lock says {s} (kpin check)", .{ key, want, pinned }));
            continue;
        }
        const bytes = std.fs.cwd().readFileAlloc(a, tarball, 1 << 30) catch |err| {
            try problems.append(try std.fmt.allocPrint(a, "{s}: cannot read {s}: {s}", .{ key, tarball, @errorName(err) }));
            continue;
        };
        const got = try sri.of(a, bytes);
        if (!std.mem.eql(u8, got, want)) {
            try problems.append(try std.fmt.allocPrint(a, "{s}: the tarball is {s}, the lockfile says {s}", .{ key, got, want }));
            continue;
        }
        try out.makePath(rel);
        var dest = try out.openDir(rel, .{});
        defer dest.close();
        const stats = unpack.unpackTgz(dest, bytes) catch |err| {
            try problems.append(try std.fmt.allocPrint(a, "{s}: {s}", .{ key, @errorName(err) }));
            continue;
        };
        const pj_text = dest.readFileAlloc(a, "package.json", 64 << 20) catch {
            try problems.append(try std.fmt.allocPrint(a, "{s}: the tarball holds no package.json", .{key}));
            continue;
        };
        const pj = std.json.parseFromSlice(std.json.Value, a, pj_text, .{}) catch {
            try problems.append(try std.fmt.allocPrint(a, "{s}: package.json is not JSON", .{key}));
            continue;
        };
        const pj_name = str(pj.value, "name") orelse "undefined";
        const pj_version = str(pj.value, "version") orelse "undefined";
        if (!std.mem.eql(u8, pj_name, name) or !std.mem.eql(u8, pj_version, version)) {
            try problems.append(try std.fmt.allocPrint(a, "{s}: its package.json says {s}@{s}", .{ key, pj_name, pj_version }));
            continue;
        }
        installed += 1;
        if (stats.links > 0) {
            try skipped.append(try std.fmt.allocPrint(a, "{s} {s}: {d} link entr{s} in the tarball, not extracted (npm drops them)", .{ p, key, stats.links, if (stats.links == 1) "y" else "ies" }));
        }
        if (e.object.get("bin") != null) try with_bin.append(.{ .path = p, .entry = e });
    }

    // .bin: for every package with executables, a relative symlink in the
    // node_modules directory that holds it, the executable made executable.
    // The shallowest package wins a name two want.
    var links = std.StringHashMap(void).init(a);
    for (with_bin.items) |wb| {
        const p = wb.path;
        const at = std.mem.lastIndexOf(u8, p, NM).?;
        const parent_rel = if (at + NM.len - 1 > NM.len - 1) p[NM.len .. at + NM.len - 1] else "";
        const pkg_rel = p[NM.len..];
        const name = str(wb.entry, "name") orelse p[at + NM.len ..];
        const bin = wb.entry.object.get("bin").?;
        var table = std.StringArrayHashMap([]const u8).init(a);
        switch (bin) {
            .string => |s| {
                const base = if (std.mem.lastIndexOfScalar(u8, name, '/')) |i| name[i + 1 ..] else name;
                try table.put(base, s);
            },
            .object => |o| {
                var it = o.iterator();
                while (it.next()) |kv| {
                    if (kv.value_ptr.* == .string) try table.put(kv.key_ptr.*, kv.value_ptr.string);
                }
            },
            else => {},
        }
        var it = table.iterator();
        while (it.next()) |kv| {
            const cmd = kv.key_ptr.*;
            var file: []const u8 = kv.value_ptr.*;
            while (std.mem.startsWith(u8, file, "./")) file = file[2..];
            var bad = file.len == 0 or file[0] == '/' or cmd.len == 0 or std.mem.indexOfScalar(u8, cmd, '/') != null;
            var segs = std.mem.splitScalar(u8, file, '/');
            while (segs.next()) |s| {
                if (std.mem.eql(u8, s, "..")) bad = true;
            }
            if (bad) {
                try problems.append(try std.fmt.allocPrint(a, "{s}: bin {s} leaves the package", .{ name, cmd }));
                continue;
            }
            const target_rel = try std.fs.path.join(a, &.{ pkg_rel, file });
            out.access(target_rel, .{}) catch {
                try skipped.append(try std.fmt.allocPrint(a, "{s}: bin {s} -> {s} is not in the tarball, no link", .{ p, cmd, file }));
                continue;
            };
            const bin_dir_rel = try std.fs.path.join(a, &.{ parent_rel, ".bin" });
            const link_rel = try std.fs.path.join(a, &.{ bin_dir_rel, cmd });
            if (links.contains(link_rel)) continue;
            try links.put(link_rel, {});
            try out.makePath(bin_dir_rel);
            const target_file = try out.openFile(target_rel, .{});
            try target_file.chmod(0o755);
            target_file.close();
            const abs_dir = try std.fs.path.join(a, &.{ out_path, bin_dir_rel });
            const abs_target = try std.fs.path.join(a, &.{ out_path, target_rel });
            const rel_target = try std.fs.path.relative(a, abs_dir, abs_target);
            try out.symLink(rel_target, link_rel, .{});
        }
    }

    if (problems.items.len > 0) {
        const shown = @min(problems.items.len, 40);
        for (problems.items[0..shown]) |m| try w.print("node_modules: {s}\n", .{m});
        if (problems.items.len > shown) try w.print("node_modules: ... and {d} more\n", .{problems.items.len - shown});
        return error.Failed;
    }

    const report = Report{ .installed = installed, .installScriptsNotRun = scripts.items, .skipped = skipped.items };
    var f = try out.createFile(".komira-node-modules.json", .{});
    defer f.close();
    try std.json.stringify(report, .{ .whitespace = .indent_2 }, f.writer());
    try f.writer().writeByte('\n');
    try w.print("node_modules: {d} packages, {d} bin links, {d} skipped, {d} install scripts not run\n", .{ installed, links.count(), skipped.items.len, scripts.items.len });
}
