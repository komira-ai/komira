//! pypi_smoke: a wheel as the driver knows it. It reads a wheel this repository's writer wrote (wheel_zip's
//! reader refuses any other zip, which is right: an index serves the uploaded bytes unchanged) and takes from it
//! what a file name, an upload and a comparison need: the distribution's name and version from METADATA, the
//! tag from WHEEL, the requirements, and the file name those give.
//!
//! A wheel has exactly one top-level `<name>-<version>.dist-info/` directory, which holds METADATA and WHEEL;
//! METADATA has exactly one `Name` and one `Version` and WHEEL exactly one `Tag`. The file name is
//! `<name, each run of - _ . made one _, lowercase>-<version>-<tag>.whl`.
const std = @import("std");
const common = @import("common.zig");

const Allocator = common.Allocator;
const Error = common.Error;
const refuse = common.refuse;
const zip = common.zip;
const Diag = common.Diag;

/// The most a wheel may be, as a file and as a download.
pub const max_wheel_bytes: usize = 1 << 30;

pub const Wheel = struct {
    bytes: []const u8,
    sha256: [64]u8,
    /// METADATA's `Name`, as written.
    name: []const u8,
    version: []const u8,
    tag: []const u8,
    requires_python: ?[]const u8,
    /// Every `Requires-Dist` value, in METADATA's order.
    requires_dist: []const []const u8,
    file_name: []const u8,
};

/// `name` with each run of `-`, `_` and `.` replaced by one `_`, and lowercased.
pub fn normalizeName(a: Allocator, name: []const u8) Error![]u8 {
    var out = std.ArrayList(u8).empty;
    var in_run = false;
    for (name) |c| {
        if (c == '-' or c == '_' or c == '.') {
            if (!in_run) try out.append(a, '_');
            in_run = true;
        } else {
            try out.append(a, std.ascii.toLower(c));
            in_run = false;
        }
    }
    return out.toOwnedSlice(a);
}

const Header = struct { key: []const u8, value: []const u8 };

/// The `Key: value` lines of `text` before its first blank line.
fn headersOf(a: Allocator, text: []const u8) Error![]const Header {
    var list = std.ArrayList(Header).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, "\r");
        if (line.len == 0) break;
        const colon = std.mem.indexOf(u8, line, ": ") orelse continue;
        try list.append(a, .{ .key = line[0..colon], .value = line[colon + 2 ..] });
    }
    return list.toOwnedSlice(a);
}

fn valuesOf(a: Allocator, headers: []const Header, key: []const u8) Error![]const []const u8 {
    var list = std.ArrayList([]const u8).empty;
    for (headers) |h| if (std.mem.eql(u8, h.key, key)) try list.append(a, h.value);
    return list.toOwnedSlice(a);
}

fn exactlyOne(a: Allocator, why: *[]const u8, headers: []const Header, file: []const u8, key: []const u8) Error![]const u8 {
    const vs = try valuesOf(a, headers, key);
    if (vs.len != 1) return refuse(a, why, "{s} has {d} {s} line(s); exactly one is wanted", .{ file, vs.len, key });
    return vs[0];
}

/// A value that goes into a file name and into a GitHub output line: no space, separator or control byte.
fn checkToken(a: Allocator, why: *[]const u8, what: []const u8, value: []const u8, extra: []const u8) Error!void {
    var ok = value.len != 0;
    for (value) |c| {
        if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, extra, c) != null)) ok = false;
    }
    if (!ok) return refuse(a, why, "{s} '{s}' is empty or has a character a wheel file name cannot hold", .{ what, value });
}

/// The three parts of a wheel's file name.
pub const FileName = struct { name: []const u8, version: []const u8, tag: []const u8 };

/// The content of a name file: one line, `<name>-<version>-<python>-<abi>-<platform>.whl` (the tag is the last
/// three parts) and a line feed (which may be missing). A name with a build tag (six parts) or fewer than
/// five parts is not a name this tool's wheels have, and is refused; so is any part that fails the check a
/// wheel's own Name, Version and Tag pass.
pub fn parseFileName(a: Allocator, why: *[]const u8, text: []const u8) Error!FileName {
    const line = if (std.mem.endsWith(u8, text, "\n")) text[0 .. text.len - 1] else text;
    if (std.mem.indexOfAny(u8, line, "\r\n") != null)
        return refuse(a, why, "the name file holds more than one line; exactly one file name is wanted", .{});
    const suffix = ".whl";
    if (!std.mem.endsWith(u8, line, suffix))
        return refuse(a, why, "the name file's line '{s}' is not a wheel file name: it does not end in {s}", .{ line, suffix });
    const stem = line[0 .. line.len - suffix.len];
    const want_parts = 5;
    var parts: [want_parts][]const u8 = undefined;
    var it = std.mem.splitScalar(u8, stem, '-');
    var n: usize = 0;
    while (it.next()) |part| : (n += 1) {
        if (n < want_parts) parts[n] = part;
    }
    if (n != want_parts)
        return refuse(a, why, "the name file's line '{s}' has {d} '-' separated parts before {s}; <name>-<version>-<python>-<abi>-<platform> has {d}", .{ line, n, suffix, @as(usize, want_parts) });
    try checkToken(a, why, "Name", parts[0], "._");
    try checkToken(a, why, "Version", parts[1], ".+!_");
    for (parts[2..]) |tag_part| try checkToken(a, why, "Tag", tag_part, "._");
    const tag_at = parts[0].len + 1 + parts[1].len + 1;
    return .{ .name = parts[0], .version = parts[1], .tag = stem[tag_at..] };
}

fn find(members: []const zip.Read, name: []const u8) ?[]const u8 {
    for (members) |m| if (std.mem.eql(u8, m.name, name)) return m.data;
    return null;
}

/// The wheel in `bytes`; the reason it is not one this tool can name is left in `why`.
pub fn parseWheel(a: Allocator, why: *[]const u8, bytes: []const u8) Error!Wheel {
    var d = Diag{};
    const members = zip.read(a, &d, bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Refused => return refuse(a, why, "not a wheel this tool reads: {s}", .{d.msg}),
    };
    var infos = std.ArrayList([]const u8).empty;
    for (members) |m| {
        const slash = std.mem.indexOfScalar(u8, m.name, '/') orelse continue;
        const top = m.name[0..slash];
        if (!std.mem.endsWith(u8, top, ".dist-info")) continue;
        var seen = false;
        for (infos.items) |i| {
            if (std.mem.eql(u8, i, top)) seen = true;
        }
        if (!seen) try infos.append(a, top);
    }
    if (infos.items.len == 0) return refuse(a, why, "the wheel has no top-level .dist-info directory", .{});
    if (infos.items.len > 1) return refuse(a, why, "the wheel has {d} top-level .dist-info directories ({s}); exactly one is wanted", .{ infos.items.len, try std.mem.join(a, ", ", infos.items) });
    const info = infos.items[0];
    const metadata_text = find(members, try std.fmt.allocPrint(a, "{s}/METADATA", .{info})) orelse
        return refuse(a, why, "{s} holds no METADATA", .{info});
    const wheel_text = find(members, try std.fmt.allocPrint(a, "{s}/WHEEL", .{info})) orelse
        return refuse(a, why, "{s} holds no WHEEL", .{info});
    const metadata = try headersOf(a, metadata_text);
    const name = try exactlyOne(a, why, metadata, "METADATA", "Name");
    const version = try exactlyOne(a, why, metadata, "METADATA", "Version");
    const tag = try exactlyOne(a, why, try headersOf(a, wheel_text), "WHEEL", "Tag");
    try checkToken(a, why, "Name", name, "._-");
    try checkToken(a, why, "Version", version, ".+!_");
    try checkToken(a, why, "Tag", tag, "._-");
    const normal = try normalizeName(a, name);
    const want_info = try std.fmt.allocPrint(a, "{s}-{s}.dist-info", .{ normal, version });
    if (!std.mem.eql(u8, info, want_info)) return refuse(a, why, "the .dist-info directory is {s}; METADATA's Name and Version make it {s}", .{ info, want_info });
    const python = try valuesOf(a, metadata, "Requires-Python");
    if (python.len > 1) return refuse(a, why, "METADATA has {d} Requires-Python lines; at most one is allowed", .{python.len});
    return .{
        .bytes = bytes,
        .sha256 = common.hexSha(bytes),
        .name = name,
        .version = version,
        .tag = tag,
        .requires_python = if (python.len == 1) python[0] else null,
        .requires_dist = try valuesOf(a, metadata, "Requires-Dist"),
        .file_name = try std.fmt.allocPrint(a, "{s}-{s}-{s}.whl", .{ normal, version, tag }),
    };
}

pub fn readFile(a: Allocator, why: *[]const u8, path: []const u8, max: usize) Error![]u8 {
    return std.fs.cwd().readFileAlloc(a, path, max) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return refuse(a, why, "cannot read {s}: {s}", .{ path, @errorName(e) }),
    };
}

/// The wheel at `path` (any file name).
pub fn loadWheelFile(a: Allocator, why: *[]const u8, path: []const u8) Error!Wheel {
    const bytes = try readFile(a, why, path, max_wheel_bytes);
    return parseWheel(a, why, bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Refused => return refuse(a, why, "{s}: {s}", .{ path, why.* }),
    };
}

/// The wheel of a dist directory: `dir` holds one `.whl` and nothing else, and the file is named as its METADATA
/// and WHEEL say.
pub fn loadDist(a: Allocator, why: *[]const u8, dir: []const u8) Error!Wheel {
    var d = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch |e|
        return refuse(a, why, "cannot open --dist {s}: {s}", .{ dir, @errorName(e) });
    defer d.close();
    var names = std.ArrayList([]const u8).empty;
    var it = d.iterate();
    while (it.next() catch |e| return refuse(a, why, "cannot list --dist {s}: {s}", .{ dir, @errorName(e) })) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".whl"))
            return refuse(a, why, "--dist {s} holds {s}; one .whl file and nothing else is wanted", .{ dir, entry.name });
        try names.append(a, try a.dupe(u8, entry.name));
    }
    if (names.items.len != 1) return refuse(a, why, "--dist {s} holds {d} files; exactly one .whl is wanted", .{ dir, names.items.len });
    const path = try std.fs.path.join(a, &.{ dir, names.items[0] });
    const wheel = try loadWheelFile(a, why, path);
    if (!std.mem.eql(u8, wheel.file_name, names.items[0]))
        return refuse(a, why, "the file {s} is named {s} by its METADATA and WHEEL", .{ names.items[0], wheel.file_name });
    return wheel;
}

/// Writes the wheel's bytes as `<out>/<its file name>`; `out` does not exist or is empty.
pub fn writeDist(a: Allocator, why: *[]const u8, wheel: Wheel, out: []const u8) Error!void {
    try common.requireFreeDir(a, why, "--out", out);
    std.fs.cwd().makePath(out) catch |e| return refuse(a, why, "cannot make --out {s}: {s}", .{ out, @errorName(e) });
    const path = try std.fs.path.join(a, &.{ out, wheel.file_name });
    std.fs.cwd().writeFile(.{ .sub_path = path, .data = wheel.bytes }) catch |e|
        return refuse(a, why, "cannot write {s}: {s}", .{ path, @errorName(e) });
}

fn listText(a: Allocator, items: []const []const u8) Error![]const u8 {
    return std.fmt.allocPrint(a, "[{s}]", .{try std.mem.join(a, ", ", items)});
}

fn sameList(x: []const []const u8, y: []const []const u8) bool {
    if (x.len != y.len) return false;
    for (x, y) |p, q| if (!std.mem.eql(u8, p, q)) return false;
    return true;
}

/// One line for each of METADATA's `Name`, `Version`, `Requires-Python` and `Requires-Dist` (the full, ordered
/// list) that differs between the wheel an index serves and the wheel that was built.
pub fn metadataDifferences(a: Allocator, served: Wheel, built: Wheel, list: *std.ArrayList([]const u8)) Error!void {
    if (!std.mem.eql(u8, served.name, built.name))
        try list.append(a, try std.fmt.allocPrint(a, "METADATA Name: served '{s}', built '{s}'", .{ served.name, built.name }));
    if (!std.mem.eql(u8, served.version, built.version))
        try list.append(a, try std.fmt.allocPrint(a, "METADATA Version: served '{s}', built '{s}'", .{ served.version, built.version }));
    const sp = served.requires_python orelse "(none)";
    const bp = built.requires_python orelse "(none)";
    if (!std.mem.eql(u8, sp, bp))
        try list.append(a, try std.fmt.allocPrint(a, "METADATA Requires-Python: served '{s}', built '{s}'", .{ sp, bp }));
    if (!sameList(served.requires_dist, built.requires_dist))
        try list.append(a, try std.fmt.allocPrint(a, "METADATA Requires-Dist: served {s}, built {s}", .{ try listText(a, served.requires_dist), try listText(a, built.requires_dist) }));
}
