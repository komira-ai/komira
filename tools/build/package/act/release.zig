//! The release-set checks of conda_release_set_check (tools/build/package/
//! release_set.bzl), in place of its busybox scripts: the stamp check (the
//! release set file against the packages built with the test stamp), the
//! release order check (no member requires a member listed after it), and the
//! test that runs the order check over fixtures.
//!
//! A refusal is one line on stderr, `conda_release_set_check: <reason>`, and
//! exit status 1; the order test's own refusals say `release_order_test:`.

const std = @import("std");
const U = @import("act_util");

pub const prog = "conda_release_set_check";

fn no(out: *U.Out, comptime fmt: []const u8, args: anytype) error{ Refused, OutOfMemory } {
    try out.appendSlice(prog ++ ": ");
    try out.writer().print(fmt, args);
    try out.append('\n');
    return error.Refused;
}

pub const Member = struct { name: []const u8, path: []const u8 };

/// `text` with, on each line, the first `"members":[...]` and the commas after
/// it removed: the top level of a metadata.json, the metapackage's `members`
/// rows (which carry `build` and `version` too) gone. (`sed
/// 's/"members":\[[^]]*\],*//'`.)
pub fn withoutMembers(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var b = std.ArrayList(u8).init(a);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try b.append('\n');
        first = false;
        const key = "\"members\":[";
        if (std.mem.indexOf(u8, line, key)) |at| {
            if (std.mem.indexOfScalarPos(u8, line, at + key.len, ']')) |close| {
                var end = close + 1;
                while (end < line.len and line[end] == ',') end += 1;
                try b.appendSlice(line[0..at]);
                try b.appendSlice(line[end..]);
                continue;
            }
        }
        try b.appendSlice(line);
    }
    return b.toOwnedSlice();
}

/// Whether `file` holds the compact-JSON pair `kv` as a whole value: followed
/// by `,` or `}`.
pub fn has(a: std.mem.Allocator, kv: []const u8, file: []const u8) !bool {
    const comma = try std.fmt.allocPrint(a, "{s},", .{kv});
    const brace = try std.fmt.allocPrint(a, "{s}}}", .{kv});
    return U.contains(file, comma) or U.contains(file, brace);
}

pub const Stamp = struct {
    version: []const u8,
    build_number: []const u8,
    commit: []const u8,
    timestamp_ms: []const u8,
    build: []const u8,
    meta: []const u8,
    meta_dir: []const u8,
    set: []const u8,
    license: []const u8,
    summary: []const u8,
    home: []const u8,
    members: []const Member,
};

fn stamped(a: std.mem.Allocator, out: *U.Out, s: Stamp, what: []const u8, name: []const u8, dir_path: []const u8) !void {
    const f = try std.fmt.allocPrint(a, "{s}-{s}-{s}.conda", .{ name, s.version, s.build });
    const fp = try std.fs.path.join(a, &.{ dir_path, f });
    const present = blk: {
        const st = std.fs.cwd().statFile(fp) catch break :blk false;
        break :blk st.kind == .file;
    };
    if (!present) {
        var names: []const u8 = "";
        if (std.fs.cwd().openDir(dir_path, .{ .iterate = true })) |d_| {
            var d = d_;
            defer d.close();
            names = try U.spaced(a, try U.listNames(a, d));
        } else |_| {}
        return no(out, "{s} {s}: [{s}] holds no {s} (version {s}, build {s}: the test stamp)", .{ what, name, names, f, s.version, s.build });
    }
    const manifest = std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ dir_path, "manifest.json" }), 1 << 26) catch "";
    const file_kv = try std.fmt.allocPrint(a, "\"file\":\"{s}\"", .{f});
    if (!try has(a, file_kv, manifest)) return no(out, "{s} {s}: manifest.json does not name {s}: {s}", .{ what, name, f, U.trimNewlines(manifest) });
    const version_kv = try std.fmt.allocPrint(a, "\"version\":\"{s}\"", .{s.version});
    if (!try has(a, version_kv, manifest)) return no(out, "{s} {s}: manifest.json is not version {s}: {s}", .{ what, name, s.version, U.trimNewlines(manifest) });
    const metadata = std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ dir_path, "metadata.json" }), 1 << 26) catch "";
    const top = try withoutMembers(a, metadata);
    const kvs = [_][]const u8{
        try std.fmt.allocPrint(a, "\"build\":\"{s}\"", .{s.build}),
        try std.fmt.allocPrint(a, "\"build_number\":{s}", .{s.build_number}),
        try std.fmt.allocPrint(a, "\"source_commit\":\"{s}\"", .{s.commit}),
        "\"stamped\":true",
        try std.fmt.allocPrint(a, "\"timestamp_ms\":{s}", .{s.timestamp_ms}),
    };
    for (kvs) |kv| {
        if (!try has(a, kv, top)) return no(out, "{s} {s}: metadata.json does not carry {s} of the test stamp at its top level: {s}", .{ what, name, kv, U.trimNewlines(metadata) });
    }
}

/// The release set file against what the target was given, then every member
/// and the metapackage against the test stamp. Returns the marker text.
pub fn stampCheck(a: std.mem.Allocator, out: *U.Out, s: Stamp) ![]u8 {
    const text = std.fs.cwd().readFileAlloc(a, s.set, 1 << 24) catch |e| return no(out, "cannot read {s}: {s}", .{ s.set, @errorName(e) });
    var want = std.ArrayList(u8).init(a);
    var got_meta: []const u8 = "";
    var got_lic: []const u8 = "";
    var got_sum: []const u8 = "";
    var got_home: []const u8 = "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        // `${line%% *}` and `${line#* }`: up to the first space, and after it
        // (the whole line when there is none).
        const sp = std.mem.indexOfScalar(u8, line, ' ');
        const k = if (sp) |i| line[0..i] else line;
        const v = if (sp) |i| line[i + 1 ..] else line;
        if (std.mem.eql(u8, k, "metapackage")) {
            got_meta = v;
        } else if (std.mem.eql(u8, k, "member")) {
            try want.append(' ');
            try want.appendSlice(v);
        } else if (std.mem.eql(u8, k, "license")) {
            got_lic = v;
        } else if (std.mem.eql(u8, k, "summary")) {
            got_sum = v;
        } else if (std.mem.eql(u8, k, "home")) {
            got_home = v;
        } else return no(out, "{s}: unknown key '{s}'", .{ s.set, k });
    }
    if (!std.mem.eql(u8, got_meta, s.meta)) return no(out, "{s} names the metapackage '{s}', this target makes '{s}'", .{ s.set, got_meta, s.meta });
    if (!std.mem.eql(u8, got_lic, s.license)) return no(out, "{s}'s license is '{s}', conda-meta is given '{s}'", .{ s.set, got_lic, s.license });
    if (!std.mem.eql(u8, got_sum, s.summary)) return no(out, "{s}'s summary is '{s}', conda-meta is given '{s}'", .{ s.set, got_sum, s.summary });
    if (!std.mem.eql(u8, got_home, s.home)) return no(out, "{s}'s home is '{s}', conda-meta is given '{s}'", .{ s.set, got_home, s.home });

    var names = std.ArrayList(u8).init(a);
    for (s.members) |m| {
        try stamped(a, out, s, "member", m.name, m.path);
        try names.append(' ');
        try names.appendSlice(m.name);
    }
    if (!std.mem.eql(u8, names.items, want.items)) return no(out, "libs are [{s} ], {s}'s members are [{s} ]: the two lists of the release set differ", .{ names.items, s.set, want.items });
    try stamped(a, out, s, "metapackage", s.meta, s.meta_dir);
    const meta_json = try std.fs.path.join(a, &.{ s.meta_dir, "metadata.json" });
    const meta_text = std.fs.cwd().readFileAlloc(a, meta_json, 1 << 26) catch "";
    for (s.members) |m| {
        const req = try std.fmt.allocPrint(a, "\"{s} =={s} {s}\"", .{ m.name, s.version, s.build });
        if (!U.contains(meta_text, req)) return no(out, "metapackage {s} does not require member {s} at {s} {s}: {s}", .{ s.meta, m.name, s.version, s.build, U.trimNewlines(meta_text) });
    }
    return std.fmt.allocPrint(a, "stamped {s} {s}:{s}\n", .{ s.version, s.build, names.items });
}

/// Release order: no member requires a member listed after it. A requirement
/// is `"<name> ==<V> <B>"` in a member's metadata.json `depends` (komira_pack).
/// `members` carry the name and the path of that metadata.json. Returns the
/// marker text.
pub fn orderCheck(a: std.mem.Allocator, out: *U.Out, set: []const u8, version: []const u8, build: []const u8, members: []const Member) ![]u8 {
    for (members, 0..) |m, i| {
        const meta = std.fs.cwd().readFileAlloc(a, m.path, 1 << 26) catch |e| return no(out, "cannot read {s}: {s}", .{ m.path, @errorName(e) });
        for (members[i + 1 ..]) |r| {
            const req = try std.fmt.allocPrint(a, "\"{s} =={s} {s}\"", .{ r.name, version, build });
            if (U.contains(meta, req)) {
                return no(out, "member {s} requires {s}, which {s} lists after it: list each member after the members it requires (here, in release/artifacts.textproto and in libs)", .{ m.name, r.name, set });
            }
        }
    }
    var names = std.ArrayList(u8).init(a);
    for (members) |m| {
        try names.append(' ');
        try names.appendSlice(m.name);
    }
    return std.fmt.allocPrint(a, "in order:{s}\n", .{names.items});
}

/// What the order test decides about a run of the order check: null when it
/// is as wanted, else the reason (without the program prefix). `want` is the
/// text a refusal must contain; empty: the check must pass with no stderr.
pub fn judgeOrderRun(a: std.mem.Allocator, code: u8, stderr: []const u8, want: []const u8) !?[]u8 {
    if (code == 0) {
        if (want.len != 0) return try std.fmt.allocPrint(a, "the order check passed, expected a refusal containing '{s}'", .{want});
        if (stderr.len != 0) return try std.fmt.allocPrint(a, "the order check passed with stderr: {s}", .{U.trimNewlines(stderr)});
        return null;
    }
    if (want.len == 0) return try std.fmt.allocPrint(a, "the order check refused, expected it to pass: {s}", .{U.trimNewlines(stderr)});
    var newlines: usize = 0;
    for (stderr) |c| {
        if (c == '\n') newlines += 1;
    }
    if (newlines != 1) return try std.fmt.allocPrint(a, "the order check refused with more than one line of stderr: {s}", .{U.trimNewlines(stderr)});
    if (!U.contains(stderr, want)) return try std.fmt.allocPrint(a, "the order check refused without '{s}': {s}", .{ want, U.trimNewlines(stderr) });
    return null;
}
