//! komira_wheel check: a written wheel read back from its bytes, and refused
//! unless it is exactly what the rule asked for.
//!
//! What is held, in order:
//!   * the file is named `<dist>-<version>-<tag>.whl`, with the version the
//!     stamp gives; with `require_stamped`, the wheel is stamped (never
//!     `0.0.0`): an unstamped wheel is not publishable;
//!   * the zip reads back (zip.zig) and every member carries the stamp's date;
//!   * the members are exactly the files given, then METADATA, WHEEL, the
//!     licence files and RECORD, each file byte-equal to its input with its
//!     mode;
//!   * RECORD lists every other member exactly once, with the sha256 and size
//!     of its bytes, and itself with neither;
//!   * WHEEL's Tag is the tag, Root-Is-Purelib false, Wheel-Version 1.0;
//!   * METADATA's Requires-Dist lines are exactly the requirements given, and
//!     METADATA as a whole is the one the attributes give;
//!   * each licence member is byte-equal to its licence file;
//!   * the members pass native_policy's policy.zig again;
//!   * with a twin (the same wheel built again by a second action from inputs
//!     staged elsewhere), the two are the same bytes.

const std = @import("std");
const diag = @import("native_policy").diag;
const policy = @import("native_policy").policy;
const stamp_mod = @import("stamp.zig");
const tag_mod = @import("tag.zig");
const wheel = @import("wheel.zig");
const zip = @import("zip.zig");
const Alloc = std.mem.Allocator;
const Diag = diag.Diag;
const Refused = diag.Refused;
const refuse = diag.refuse;

fn find(members: []const zip.Read, name: []const u8) ?zip.Read {
    for (members) |m| if (std.mem.eql(u8, m.name, name)) return m;
    return null;
}

/// The values of every `<key>: ` header line of `text` before its body.
pub fn headerValues(alloc: Alloc, text: []const u8, key: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        if (l.len == 0) break;
        if (l.len > key.len + 2 and std.mem.startsWith(u8, l, key) and std.mem.eql(u8, l[key.len .. key.len + 2], ": "))
            try out.append(alloc, l[key.len + 2 ..]);
    }
    return out.toOwnedSlice(alloc);
}

/// RECORD against the members before it.
pub fn checkRecord(alloc: Alloc, d: *Diag, members: []const zip.Read, record_path: []const u8) Refused!void {
    if (members.len == 0 or !std.mem.eql(u8, members[members.len - 1].name, record_path))
        return refuse(d, alloc, "record: the last member is not {s}", .{record_path});
    const body = members[0 .. members.len - 1];
    const seen = try alloc.alloc(bool, body.len);
    @memset(seen, false);
    var self = false;
    var lines = std.mem.splitScalar(u8, members[members.len - 1].data, '\n');
    var n: usize = 0;
    while (lines.next()) |line| {
        n += 1;
        if (line.len == 0) {
            if (lines.peek() == null) break;
            return refuse(d, alloc, "record: line {d} is empty", .{n});
        }
        var cols = std.mem.splitScalar(u8, line, ',');
        const path = cols.next().?;
        const hash = cols.next() orelse return refuse(d, alloc, "record: line {d} has no hash column", .{n});
        const size = cols.next() orelse return refuse(d, alloc, "record: line {d} has no size column", .{n});
        if (cols.next() != null) return refuse(d, alloc, "record: line {d} has more than three columns", .{n});
        if (std.mem.eql(u8, path, record_path)) {
            if (self or hash.len != 0 or size.len != 0) return refuse(d, alloc, "record: RECORD lists itself twice, or with a hash or size", .{});
            self = true;
            continue;
        }
        var idx: ?usize = null;
        for (body, 0..) |m, i| if (std.mem.eql(u8, m.name, path)) {
            idx = i;
        };
        const i = idx orelse return refuse(d, alloc, "record: RECORD lists `{s}`, which the wheel does not hold", .{path});
        if (seen[i]) return refuse(d, alloc, "record: RECORD lists `{s}` twice", .{path});
        seen[i] = true;
        const want_hash = try wheel.recordHash(alloc, body[i].data);
        if (!std.mem.eql(u8, hash, want_hash)) return refuse(d, alloc, "record: RECORD gives `{s}` the hash {s}, but its bytes hash to {s}", .{ path, hash, want_hash });
        const want_size = try std.fmt.allocPrint(alloc, "{d}", .{body[i].data.len});
        if (!std.mem.eql(u8, size, want_size)) return refuse(d, alloc, "record: RECORD gives `{s}` the size {s}, but it holds {s} bytes", .{ path, size, want_size });
    }
    if (!self) return refuse(d, alloc, "record: RECORD does not list itself", .{});
    for (body, seen) |m, ok| if (!ok) return refuse(d, alloc, "record: `{s}` is in the wheel but not in RECORD", .{m.name});
}

/// The wheel named `name` with bytes `bytes`, against the input it was built
/// from (`in.version` is the stamp's) and the stamp.
pub fn check(alloc: Alloc, d: *Diag, in: wheel.Input, st: stamp_mod.Stamp, name: []const u8, bytes: []const u8, require_stamped: bool, twin: ?[]const u8) Refused!void {
    if (require_stamped and !st.stamped)
        return refuse(d, alloc, "stamp: the wheel is unstamped (version {s}): a development wheel, never a release", .{st.version});
    if (!std.mem.eql(u8, in.version, st.version)) return refuse(d, alloc, "stamp: the version {s} is not the stamp's {s}", .{ in.version, st.version });
    const t = try tag_mod.parse(alloc, d, in.tag);
    const want_name = try wheel.fileName(alloc, in.name, in.version, in.tag);
    if (!std.mem.eql(u8, name, want_name)) return refuse(d, alloc, "name: the wheel is named {s}, not {s}", .{ name, want_name });

    const members = try zip.read(alloc, d, bytes);
    const date = try zip.stampOf(alloc, d, st.timestamp_ms);
    for (members) |m| {
        if (m.stamp.date != date.date or m.stamp.time != date.time)
            return refuse(d, alloc, "date: {s} is dated {x}/{x}, not the stamp's {x}/{x}", .{ m.name, m.stamp.date, m.stamp.time, date.date, date.time });
    }

    // The members, in order: the files sorted, then the dist-info.
    const info = try wheel.distInfo(alloc, in.name, in.version);
    var want = std.ArrayList(wheel.File).empty;
    const files = try alloc.dupe(wheel.File, in.files);
    std.mem.sort(wheel.File, files, {}, struct {
        fn less(_: void, a: wheel.File, b: wheel.File) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.less);
    try want.appendSlice(alloc, files);
    try want.append(alloc, .{ .path = try std.fmt.allocPrint(alloc, "{s}/METADATA", .{info}), .data = "" });
    try want.append(alloc, .{ .path = try std.fmt.allocPrint(alloc, "{s}/WHEEL", .{info}), .data = "" });
    const lics = try wheel.sortedLicenses(alloc, in.licenses);
    for (lics) |l| try want.append(alloc, .{ .path = try std.fmt.allocPrint(alloc, "{s}/licenses/{s}", .{ info, l.path }), .data = l.data });
    const record_path = try std.fmt.allocPrint(alloc, "{s}/RECORD", .{info});
    try want.append(alloc, .{ .path = record_path, .data = "" });
    for (members, 0..) |m, i| {
        if (i >= want.items.len) return refuse(d, alloc, "members: the wheel carries {s}, which the rule did not give", .{m.name});
        const w = want.items[i];
        if (!std.mem.eql(u8, m.name, w.path)) return refuse(d, alloc, "members: member {d} is {s}, not {s}", .{ i, m.name, w.path });
        if (i < files.len) {
            if (!std.mem.eql(u8, m.data, w.data)) return refuse(d, alloc, "members: {s} is not the file given", .{m.name});
            if (m.mode != w.mode) return refuse(d, alloc, "mode: {s} has mode {o}, not {o}", .{ m.name, m.mode, w.mode });
        } else if (m.mode != 0o644) return refuse(d, alloc, "mode: {s} has mode {o}, not 644", .{ m.name, m.mode });
    }
    if (members.len < want.items.len) return refuse(d, alloc, "members: the wheel has no {s}", .{want.items[members.len].path});

    try checkRecord(alloc, d, members, record_path);

    const wheel_file = find(members, try std.fmt.allocPrint(alloc, "{s}/WHEEL", .{info})).?;
    const tags = try headerValues(alloc, wheel_file.data, "Tag");
    if (tags.len != 1 or !std.mem.eql(u8, tags[0], in.tag)) return refuse(d, alloc, "tag: WHEEL gives the tags {s}, not {s}", .{ try std.mem.join(alloc, " ", tags), in.tag });
    if (!std.mem.eql(u8, wheel_file.data, try wheel.renderWheel(alloc, in.tag))) return refuse(d, alloc, "tag: WHEEL is not Wheel-Version 1.0, Root-Is-Purelib false:\n{s}", .{wheel_file.data});

    const meta = find(members, try std.fmt.allocPrint(alloc, "{s}/METADATA", .{info})).?;
    const reqs = try headerValues(alloc, meta.data, "Requires-Dist");
    var same = reqs.len == in.requires_dist.len;
    for (reqs, 0..) |r, i| same = same and i < in.requires_dist.len and std.mem.eql(u8, r, in.requires_dist[i]);
    if (!same) return refuse(d, alloc, "requires: METADATA's Requires-Dist is [{s}], not [{s}]", .{ try std.mem.join(alloc, "; ", reqs), try std.mem.join(alloc, "; ", in.requires_dist) });
    if (!std.mem.eql(u8, meta.data, try wheel.renderMetadata(alloc, in))) return refuse(d, alloc, "metadata: METADATA is not the one the rule's attributes give", .{});

    for (lics) |l| {
        const m = find(members, try std.fmt.allocPrint(alloc, "{s}/licenses/{s}", .{ info, l.path })).?;
        if (!std.mem.eql(u8, m.data, l.data)) return refuse(d, alloc, "licence: {s} differs from the licence file given", .{m.name});
    }

    var checked = std.ArrayList(policy.Member).empty;
    for (members) |m| try checked.append(alloc, .{ .name = m.name, .data = m.data });
    try policy.check(alloc, d, wheel.policyOf(t, in), checked.items);

    if (twin) |tw| {
        if (!std.mem.eql(u8, tw, bytes)) return refuse(d, alloc, "twin: the wheel built twice from the same inputs, staged at two paths, is not the same bytes ({d} and {d} bytes): the build is not reproducible", .{ bytes.len, tw.len });
    }
}
