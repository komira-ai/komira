//! komira_wheel same: two finished wheels of one package for two platforms
//! (the macOS wheel and the Linux wheel of the same build), read from their
//! bytes, and refused unless they are the same package apart from each
//! platform's native libraries:
//!
//!   members    no member name is in a wheel twice (a second copy could
//!              differ unseen);
//!   dist-info  both have one `.dist-info` directory, of the same name (the
//!              same distribution at the same version);
//!   members    every member but RECORD and WHEEL is in both, with the same
//!              bytes and the same mode, except the members named as one
//!              wheel's own (`--only-in-wheel`, `--only-in-like`): each of
//!              those is in that wheel, not in the other, and is a native
//!              library (Mach-O or ELF), so no Python file can differ;
//!   WHEEL      the same lines but `Tag:`, whose Python and ABI tags
//!              (`py3-none`) are the same: the platform tag alone differs;
//!   RECORD     not compared: it lists the members' hashes, and the members
//!              are compared themselves.
//!
//! The marker counts the members alike and lists each wheel's own, by its tag, so
//! a reader sees exactly what differs.

const std = @import("std");
const check_mod = @import("check.zig");
const cli = @import("cli.zig");
const diag = @import("native_policy").diag;
const elf = @import("native_policy").elf;
const macho = @import("native_policy").macho;
const zip = @import("zip.zig");
const Alloc = std.mem.Allocator;
const Diag = diag.Diag;
const Refused = diag.Refused;
const refuse = diag.refuse;

/// One wheel as `same` reads it: its members, the name of its `.dist-info`
/// directory and its WHEEL tag.
const Side = struct {
    members: []const zip.Read,
    info: []const u8,
    tag: []const u8,
};

fn find(members: []const zip.Read, name: []const u8) ?zip.Read {
    for (members) |m| if (std.mem.eql(u8, m.name, name)) return m;
    return null;
}

fn has(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn topDir(path: []const u8) []const u8 {
    return path[0 .. std.mem.indexOfScalar(u8, path, '/') orelse path.len];
}

/// `members`' one `.dist-info` directory and the one Tag of its WHEEL;
/// `label` names the wheel in a refusal.
fn side(alloc: Alloc, d: *Diag, label: []const u8, members: []const zip.Read) Refused!Side {
    for (members, 0..) |m, i| {
        for (members[0..i]) |o| if (std.mem.eql(u8, o.name, m.name))
            return refuse(d, alloc, "members: {s} holds {s} twice", .{ label, m.name });
    }
    var info: ?[]const u8 = null;
    for (members) |m| {
        const top = topDir(m.name);
        if (top.len == m.name.len or !std.mem.endsWith(u8, top, ".dist-info")) continue;
        if (info) |seen| {
            if (!std.mem.eql(u8, seen, top)) return refuse(d, alloc, "dist-info: {s} has two .dist-info directories, {s} and {s}", .{ label, seen, top });
        } else info = top;
    }
    const dir = info orelse return refuse(d, alloc, "dist-info: {s} has no .dist-info directory", .{label});
    const wheel_file = find(members, try std.fmt.allocPrint(alloc, "{s}/WHEEL", .{dir})) orelse
        return refuse(d, alloc, "WHEEL: {s} has no {s}/WHEEL", .{ label, dir });
    const tags = try check_mod.headerValues(alloc, wheel_file.data, "Tag");
    if (tags.len != 1) return refuse(d, alloc, "WHEEL: {s} has {d} Tag lines, not one", .{ label, tags.len });
    if (std.mem.count(u8, tags[0], "-") != 2) return refuse(d, alloc, "WHEEL: {s} has the Tag `{s}`, which is not <python>-<abi>-<platform>", .{ label, tags[0] });
    return .{ .members = members, .info = dir, .tag = tags[0] };
}

/// `tag` (three parts, `side` checked) without its platform part: `py3-none`
/// of `py3-none-macosx_11_0_arm64`.
fn pythonAbi(tag: []const u8) []const u8 {
    return tag[0..std.mem.lastIndexOfScalar(u8, tag, '-').?];
}

/// `tag`'s platform part: `macosx_11_0_arm64` of `py3-none-macosx_11_0_arm64`.
fn platformOf(tag: []const u8) []const u8 {
    return tag[std.mem.lastIndexOfScalar(u8, tag, '-').? + 1 ..];
}

/// WHEEL's lines but the Tag line.
fn untagged(alloc: Alloc, text: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        if (std.mem.startsWith(u8, l, "Tag: ")) continue;
        try out.appendSlice(alloc, l);
        try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}

fn native(data: []const u8) bool {
    return macho.isMachO(data) or elf.isElf(data);
}

/// Refuses the wheels `a` (members of `--wheel`) and `b` (of `--like`) unless
/// they are the same package as described above, with `only_a` and `only_b`
/// exactly each one's own members; returns the marker.
pub fn check(alloc: Alloc, d: *Diag, a_members: []const zip.Read, b_members: []const zip.Read, only_a: []const []const u8, only_b: []const []const u8) Refused![]const u8 {
    const a = try side(alloc, d, "the wheel", a_members);
    const b = try side(alloc, d, "its like", b_members);
    const la = platformOf(a.tag);
    const lb = platformOf(b.tag);
    if (!std.mem.eql(u8, a.info, b.info)) return refuse(d, alloc, "dist-info: {s} is {s} and {s} is {s}: not the same distribution at the same version", .{ la, a.info, lb, b.info });
    if (!std.mem.eql(u8, pythonAbi(a.tag), pythonAbi(b.tag)))
        return refuse(d, alloc, "WHEEL: the Python and ABI tags differ: {s} for {s}, {s} for {s}", .{ pythonAbi(a.tag), la, pythonAbi(b.tag), lb });

    const wheel_path = try std.fmt.allocPrint(alloc, "{s}/WHEEL", .{a.info});
    const record_path = try std.fmt.allocPrint(alloc, "{s}/RECORD", .{a.info});
    if (!std.mem.eql(u8, try untagged(alloc, find(a.members, wheel_path).?.data), try untagged(alloc, find(b.members, wheel_path).?.data)))
        return refuse(d, alloc, "WHEEL: {s} differs beyond its Tag line", .{wheel_path});

    for ([_]struct { own: []const []const u8, in: Side, label: []const u8, other: Side, other_label: []const u8 }{
        .{ .own = only_a, .in = a, .label = la, .other = b, .other_label = lb },
        .{ .own = only_b, .in = b, .label = lb, .other = a, .other_label = la },
    }) |s| {
        for (s.own) |name| {
            const m = find(s.in.members, name) orelse return refuse(d, alloc, "members: {s} is named as {s}'s own, and {s} has no such member", .{ name, s.label, s.label });
            if (find(s.other.members, name) != null) return refuse(d, alloc, "members: {s} is named as {s}'s own, and {s} has it too", .{ name, s.label, s.other_label });
            if (!native(m.data)) return refuse(d, alloc, "members: {s} is named as {s}'s own, and it is not a native library (Mach-O or ELF): only native files may differ", .{ name, s.label });
        }
        for (s.in.members) |m| {
            if (std.mem.eql(u8, m.name, wheel_path) or std.mem.eql(u8, m.name, record_path) or has(s.own, m.name)) continue;
            const o = find(s.other.members, m.name) orelse return refuse(d, alloc, "members: {s} is in {s} and not in {s}", .{ m.name, s.label, s.other_label });
            if (!std.mem.eql(u8, m.data, o.data)) return refuse(d, alloc, "members: {s} differs between {s} and {s}", .{ m.name, s.label, s.other_label });
            if (m.mode != o.mode) return refuse(d, alloc, "members: {s} is mode {o} in {s} and {o} in {s}", .{ m.name, m.mode, s.label, o.mode, s.other_label });
        }
    }

    var out = std.ArrayList(u8).empty;
    const w = out.writer(alloc);
    var alike: usize = 0;
    for (a.members) |m| {
        if (!std.mem.eql(u8, m.name, wheel_path) and !std.mem.eql(u8, m.name, record_path) and !has(only_a, m.name)) alike += 1;
    }
    try w.print("{d} members alike ({s} and {s}); WHEEL differs only in its Tag, {s} and {s}\n", .{ alike, la, lb, a.tag, b.tag });
    for (only_a) |n| try w.print("only in {s}: {s}\n", .{ la, n });
    for (only_b) |n| try w.print("only in {s}: {s}\n", .{ lb, n });
    return out.toOwnedSlice(alloc);
}

pub const flags = [_][]const u8{ "--wheel", "--like", "--only-in-wheel", "--only-in-like", "--out" };

/// What `komira_wheel same` writes: the marker, and the path it goes to.
pub const Result = struct { out: []const u8, marker: []const u8 };

/// `komira_wheel same <argv>`: both wheels read with `files.read(alloc, d,
/// path)` and compared.
pub fn command(alloc: Alloc, d: *Diag, argv: []const []const u8, files: anytype) Refused!Result {
    const args = try cli.parseOnly(alloc, d, argv, &flags);
    const a = try zip.read(alloc, d, try files.read(alloc, d, try args.one(alloc, d, "--wheel")));
    const b = try zip.read(alloc, d, try files.read(alloc, d, try args.one(alloc, d, "--like")));
    const marker = try check(alloc, d, a, b, try args.all(alloc, "--only-in-wheel"), try args.all(alloc, "--only-in-like"));
    return .{ .out = try args.one(alloc, d, "--out"), .marker = marker };
}
