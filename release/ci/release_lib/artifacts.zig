//! release/artifacts.textproto, read for what the release set must be: the
//! artifact names in order, and the arguments of the metapackage.
//!
//! The file is a textproto the build never parses (the release set is a
//! Buck2 target, //release:release_set); this reader holds the set to it. It
//! reads the file's own layout, one field per line:
//!
//!   artifacts {
//!     name: "<name>"
//!     ... args: "<value>" ...
//!   }
//!
//! `build_systems { ... }` blocks are skipped. A value holding a backslash
//! is refused: none of the file's values has one, and an escape would be
//! read wrongly.
const std = @import("std");

pub const Artifact = struct {
    name: []const u8,
    args: []const []const u8,
};

pub const ParseError = error{ BadLine, NoName, NestedBlock };

/// The value of a `key: "value"` line, or null if the line is another key.
fn quoted(line: []const u8, key: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, line, key)) return null;
    var rest = std.mem.trimLeft(u8, line[key.len..], " \t");
    if (rest.len == 0 or rest[0] != ':') return null;
    rest = std.mem.trim(u8, rest[1..], " \t");
    if (rest.len < 2 or rest[0] != '"' or rest[rest.len - 1] != '"') return error.BadLine;
    const v = rest[1 .. rest.len - 1];
    if (std.mem.indexOfAny(u8, v, "\"\\") != null) return error.BadLine;
    return v;
}

/// Every artifact of the file, in order.
pub fn parse(a: std.mem.Allocator, text: []const u8) ![]Artifact {
    var out = std.ArrayList(Artifact).empty;
    var in_artifact = false;
    var in_other = false;
    var name: ?[]const u8 = null;
    var args = std.ArrayList([]const u8).empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.eql(u8, line, "artifacts {")) {
            if (in_artifact or in_other) return error.NestedBlock;
            in_artifact = true;
            name = null;
            args = std.ArrayList([]const u8).empty;
            continue;
        }
        if (std.mem.endsWith(u8, line, "{")) {
            if (in_artifact or in_other) return error.NestedBlock;
            in_other = true;
            continue;
        }
        if (std.mem.eql(u8, line, "}")) {
            if (in_artifact) {
                try out.append(a, .{ .name = name orelse return error.NoName, .args = args.items });
            }
            in_artifact = false;
            in_other = false;
            continue;
        }
        if (!in_artifact) continue;
        if (try quoted(line, "name")) |v| {
            name = v;
        } else if (try quoted(line, "args")) |v| {
            try args.append(a, v);
        }
    }
    return out.items;
}

/// What the release set is, as the Buck2 target states it.
pub const Expect = struct {
    /// The library packages, in order (the artifact names).
    members: []const []const u8,
    metapackage: []const u8,
    license: []const u8,
    summary: []const u8,
    home: []const u8,
    /// `<path in the package>=<file>`.
    extra_file: []const u8,
    /// The text before the revision in the metapackage's label.
    label_prefix: []const u8,
};

/// The arguments the metapackage artifact must carry: the packer's
/// `conda-meta` over every library's manifest, in order, and the fixed
/// package metadata.
pub fn metapackageArgs(a: std.mem.Allocator, e: Expect) ![]const []const u8 {
    var v = std.ArrayList([]const u8).empty;
    try v.appendSlice(a, &.{ "conda-meta", "--name", e.metapackage });
    for (e.members) |m| {
        try v.append(a, "--member-manifest");
        try v.append(a, try std.fmt.allocPrint(a, "{{release_dir}}/{s}/manifest.json", .{m}));
    }
    try v.appendSlice(a, &.{ "--license", e.license, "--summary", e.summary, "--home", e.home });
    try v.appendSlice(a, &.{ "--extra-file", e.extra_file });
    try v.appendSlice(a, &.{ "--label", try std.fmt.allocPrint(a, "{s}{{revision_id}}", .{e.label_prefix}) });
    try v.appendSlice(a, &.{ "--out-dir", "{out_dir}" });
    return v.items;
}

/// Why the set `e` is not the file's, or null when it is: the artifact names
/// (and so the packages) are the file's, in its order, and the metapackage
/// is built with the arguments the file gives.
pub fn disagreement(a: std.mem.Allocator, text: []const u8, e: Expect) !?[]const u8 {
    const arts = try parse(a, text);
    const want_n = e.members.len + 1;
    const common = @min(arts.len, want_n);
    var i: usize = 0;
    while (i < common) : (i += 1) {
        const want = if (i < e.members.len) e.members[i] else e.metapackage;
        if (!std.mem.eql(u8, arts[i].name, want)) {
            return try std.fmt.allocPrint(a, "artifact {d} of the artifacts file is '{s}', and the release set's is '{s}' (the file's order is the release order, the metapackage last)", .{ i + 1, arts[i].name, want });
        }
    }
    if (arts.len > want_n) {
        return try std.fmt.allocPrint(a, "the artifacts file declares '{s}', which the release set does not build", .{arts[want_n].name});
    }
    if (arts.len < want_n) {
        const want = if (arts.len < e.members.len) e.members[arts.len] else e.metapackage;
        return try std.fmt.allocPrint(a, "the release set builds '{s}', which the artifacts file does not declare", .{want});
    }
    const have = arts[arts.len - 1].args;
    const want = try metapackageArgs(a, e);
    const n = @min(have.len, want.len);
    var k: usize = 0;
    while (k < n) : (k += 1) {
        if (!std.mem.eql(u8, have[k], want[k])) {
            return try std.fmt.allocPrint(a, "argument {d} of the metapackage '{s}' in the artifacts file is '{s}', and the release set gives '{s}'", .{ k + 1, e.metapackage, have[k], want[k] });
        }
    }
    if (have.len != want.len) {
        return try std.fmt.allocPrint(a, "the metapackage '{s}' has {d} arguments in the artifacts file and {d} in the release set", .{ e.metapackage, have.len, want.len });
    }
    return null;
}
