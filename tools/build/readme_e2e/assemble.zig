//! `readme_e2e assemble`: the staged set of a release, from the packages the
//! build made.
//!
//! The release flow is stage, then README e2e, then publish. `mopm stage` writes
//! the staged set; this writes the same directory from `.conda` files the
//! build already holds (`mojo_conda`, buildrules), so the e2e has a set to
//! install from before the release reaches for mopm's own:
//!
//!     <out>/plan.json                    members in dependency order
//!     <out>/<subdir>/<file>.conda        each package, as mopm pack wrote it
//!     <out>/<name>/README.md             each package's README
//!
//! plan.json is that of mopm's spec/staged-set.md: every member is an `upload`
//! with its files' sha256 and size, `manifest_sha256` (the sha256 of the
//! `<name>.mopm.json` inside the package, which is what `mopm pack` prints) and
//! the README's path. A package whose name, version or file name disagree with
//! the metadata inside it, or that needs a package the set does not hold, is
//! refused: the e2e installs offline, so the set must hold the whole closure.

const std = @import("std");
const Allocator = std.mem.Allocator;
const conda = @import("conda.zig");
const plan_mod = @import("plan.zig");

pub const Member = struct {
    name: []const u8,
    version: []const u8,
    /// The `.conda` file, in a directory named for its subdir.
    conda: []const u8,
    readme: []const u8,
};

pub const Options = struct {
    out: []const u8,
    mojo: []const u8,
    members: []const Member,
};

const subdirs = [_][]const u8{ "noarch", "linux-64", "linux-aarch64", "osx-arm64" };
const max_readme: usize = 64 * 1024;

const Built = struct {
    member: Member,
    subdir: []const u8,
    filename: []const u8,
    bytes: []const u8,
    metadata: []const u8,
    deps: []const []const u8,
    readme: []const u8,
};

fn refuse(a: Allocator, log: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !bool {
    const line = try std.fmt.allocPrint(a, "readme_e2e assemble: " ++ fmt ++ "\n", args);
    try log.appendSlice(a, line);
    return false;
}

/// Writes the set. False, with the reason in `log`, when a member is refused.
pub fn assemble(a: Allocator, opts: Options, log: *std.ArrayList(u8)) !bool {
    if (opts.members.len == 0) return refuse(a, log, "no member", .{});
    var built: std.ArrayList(Built) = .empty;
    const cwd = std.fs.cwd();
    for (opts.members) |m| {
        for (built.items) |b| {
            if (std.mem.eql(u8, b.member.name, m.name)) return refuse(a, log, "{s} is a member twice", .{m.name});
        }
        const bytes = cwd.readFileAlloc(a, m.conda, 1 << 29) catch |e|
            return refuse(a, log, "{s}: cannot read {s}: {s}", .{ m.name, m.conda, @errorName(e) });
        const subdir = std.fs.path.basename(std.fs.path.dirname(m.conda) orelse "");
        var known = false;
        for (subdirs) |s| known = known or std.mem.eql(u8, s, subdir);
        if (!known) return refuse(a, log, "{s}: {s} is not in a directory named for a subdir (noarch, linux-64, linux-aarch64, osx-arm64)", .{ m.name, m.conda });
        const filename = std.fs.path.basename(m.conda);
        const want = try plan_mod.packageFile(a, m.name, m.version, try std.fmt.allocPrint(a, "mojo{s}_0", .{opts.mojo}));
        if (!std.mem.eql(u8, filename, want)) return refuse(a, log, "{s}: the file is {s}, and a package {s} {s} for Mojo {s} is {s}", .{ m.name, filename, m.name, m.version, opts.mojo, want });
        var why: []const u8 = "";
        const files = conda.read(a, bytes, &why) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Corrupt => return refuse(a, log, "{s}: {s}: {s}", .{ m.name, m.conda, why }),
        };
        const meta_name = try std.fmt.allocPrint(a, "lib/mojo/{s}.mopm.json", .{m.name});
        const metadata = conda.find(files, meta_name) orelse return refuse(a, log, "{s}: {s} holds no {s}", .{ m.name, m.conda, meta_name });
        const meta = plan_mod.parseMetadata(a, metadata, &why) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Invalid => return refuse(a, log, "{s}: {s}", .{ m.name, why }),
        };
        if (!std.mem.eql(u8, meta.name, m.name)) return refuse(a, log, "{s}: the metadata inside {s} names the package {s}", .{ m.name, m.conda, meta.name });
        if (meta.version) |v| {
            if (!std.mem.eql(u8, v, m.version)) return refuse(a, log, "{s}: the metadata inside {s} says version {s}, not {s}", .{ m.name, m.conda, v, m.version });
        }
        var deps: std.ArrayList([]const u8) = .empty;
        for (meta.deps) |d| try deps.append(a, d.name);
        const readme = cwd.readFileAlloc(a, m.readme, max_readme + 1) catch |e|
            return refuse(a, log, "{s}: cannot read the README {s}: {s}", .{ m.name, m.readme, @errorName(e) });
        if (readme.len > max_readme) return refuse(a, log, "{s}: the README is over {d} bytes", .{ m.name, max_readme });
        if (!std.unicode.utf8ValidateSlice(readme)) return refuse(a, log, "{s}: the README is not UTF-8", .{m.name});
        try built.append(a, .{ .member = m, .subdir = subdir, .filename = filename, .bytes = bytes, .metadata = metadata, .deps = deps.items, .readme = readme });
    }

    // Dependency order: the member with the smallest name among those whose
    // dependencies are all placed, until none is left.
    var ordered: std.ArrayList(usize) = .empty;
    var placed = try a.alloc(bool, built.items.len);
    @memset(placed, false);
    for (built.items) |b| {
        for (b.deps) |d| {
            var held = false;
            for (built.items) |o| held = held or std.mem.eql(u8, o.member.name, d);
            if (!held) return refuse(a, log, "{s} needs {s}, which is not in the set; the e2e installs offline, so the set holds the whole closure", .{ b.member.name, d });
        }
    }
    while (ordered.items.len < built.items.len) {
        var pick: ?usize = null;
        for (built.items, 0..) |b, i| {
            if (placed[i]) continue;
            var ready = true;
            for (b.deps) |d| {
                for (built.items, 0..) |o, j| {
                    if (std.mem.eql(u8, o.member.name, d) and !placed[j]) ready = false;
                }
            }
            if (!ready) continue;
            if (pick == null or std.mem.lessThan(u8, b.member.name, built.items[pick.?].member.name)) pick = i;
        }
        const i = pick orelse return refuse(a, log, "the members' dependencies form a cycle", .{});
        placed[i] = true;
        try ordered.append(a, i);
    }

    var members: std.ArrayList(plan_mod.Member) = .empty;
    try cwd.makePath(opts.out);
    var out = try cwd.openDir(opts.out, .{});
    defer out.close();
    for (ordered.items) |i| {
        const b = built.items[i];
        const rel = try std.fs.path.join(a, &.{ b.subdir, b.filename });
        if (std.fs.path.dirname(rel)) |d| try out.makePath(d);
        try out.writeFile(.{ .sub_path = rel, .data = b.bytes, .flags = .{ .exclusive = true } });
        const readme_rel = try std.fmt.allocPrint(a, "{s}/README.md", .{b.member.name});
        try out.makePath(b.member.name);
        try out.writeFile(.{ .sub_path = readme_rel, .data = b.readme, .flags = .{ .exclusive = true } });
        const files = try a.alloc(plan_mod.PlanFile, 1);
        files[0] = .{ .subdir = b.subdir, .filename = b.filename, .sha256 = try a.dupe(u8, &plan_mod.sha256Hex(b.bytes)), .size = b.bytes.len };
        try members.append(a, .{
            .name = b.member.name,
            .version = b.member.version,
            .action = "upload",
            .manifest_sha256 = try a.dupe(u8, &plan_mod.sha256Hex(b.metadata)),
            .files = files,
            .readme = readme_rel,
        });
    }
    // The plan is written last: a set with a plan is a complete one.
    const text = try plan_mod.renderPlan(a, .{ .version = 1, .members = members.items });
    try out.writeFile(.{ .sub_path = "plan.json", .data = text });
    const line = try std.fmt.allocPrint(a, "readme_e2e assemble: {d} member(s) staged in {s}\n", .{ members.items.len, opts.out });
    try log.appendSlice(a, line);
    return true;
}
