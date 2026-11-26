//! komira_wheel: a wheel (PEP 427; core metadata 2.4) made from the rule's
//! attributes and files, byte for byte reproducible.
//!
//! The wheel holds, in this order: the files, sorted bytewise by path; then
//! `<dist>-<version>.dist-info/` METADATA, WHEEL, `licenses/<name>` for each
//! licence file (sorted; PEP 639), and RECORD last. Every member is dated with
//! the stamp's commit time (zip.zig). Before anything is written, the files
//! are held to native_policy's policy.zig.

const std = @import("std");
const diag = @import("native_policy").diag;
const policy = @import("native_policy").policy;
const tag_mod = @import("tag.zig");
const zip = @import("zip.zig");
const Alloc = std.mem.Allocator;
const Diag = diag.Diag;
const Refused = diag.Refused;
const refuse = diag.refuse;

pub const File = struct {
    path: []const u8,
    data: []const u8,
    mode: u32 = 0o644,
};

pub const Url = struct { label: []const u8, url: []const u8 };

pub const Input = struct {
    name: []const u8,
    version: []const u8,
    summary: []const u8,
    /// The README (Markdown): METADATA's body.
    readme: []const u8,
    requires_python: []const u8,
    requires_dist: []const []const u8 = &.{},
    classifiers: []const []const u8 = &.{},
    project_urls: []const Url = &.{},
    license_expression: []const u8,
    /// The licence files, by file name.
    licenses: []const File,
    /// Every other member, at its path in the wheel.
    files: []const File,
    tag: []const u8,
    max_glibcxx: ?[]const u8 = null,
    max_cxxabi: ?[]const u8 = null,
    external_needed: []const []const u8 = &.{},
};

pub const generator = "komira_wheel";

/// A distribution name in its normalised form (PEP 503): lowercase letters
/// and digits, single `-` between them. Another spelling is refused rather
/// than rewritten, so the rule states the name the wheel has.
pub fn normalName(s: []const u8) bool {
    if (s.len == 0 or s[0] == '-' or s[s.len - 1] == '-') return false;
    for (s, 0..) |c, i| {
        if (c == '-') {
            if (s[i - 1] == '-') return false;
            continue;
        }
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c))) return false;
    }
    return true;
}

/// A release version: dot-separated numbers without leading zeros. No local
/// version (`+...`), no pre- or post-release: what the stamp gives.
pub fn releaseVersion(s: []const u8) bool {
    var parts = std.mem.splitScalar(u8, s, '.');
    var n: usize = 0;
    while (parts.next()) |p| : (n += 1) {
        if (p.len == 0 or (p.len > 1 and p[0] == '0')) return false;
        for (p) |c| if (!std.ascii.isDigit(c)) return false;
    }
    return n >= 2;
}

pub fn distStem(alloc: Alloc, name: []const u8) ![]const u8 {
    const out = try alloc.dupe(u8, name);
    std.mem.replaceScalar(u8, out, '-', '_');
    return out;
}

pub fn distInfo(alloc: Alloc, name: []const u8, ver: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}-{s}.dist-info", .{ try distStem(alloc, name), ver });
}

pub fn fileName(alloc: Alloc, name: []const u8, ver: []const u8, tag: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}-{s}-{s}.whl", .{ try distStem(alloc, name), ver, tag });
}

/// A METADATA header value: one line, not empty.
fn oneLine(alloc: Alloc, d: *Diag, what: []const u8, s: []const u8) Refused!void {
    if (s.len == 0) return refuse(d, alloc, "metadata: {s} is empty", .{what});
    if (std.mem.indexOfAny(u8, s, "\r\n") != null) return refuse(d, alloc, "metadata: {s} `{s}` holds a line break", .{ what, s });
}

/// The attributes METADATA is made of, each checked.
pub fn checkMetadata(alloc: Alloc, d: *Diag, in: Input) Refused!void {
    if (!normalName(in.name)) return refuse(d, alloc, "metadata: the name `{s}` is not a normalised name (lowercase letters, digits, single `-`)", .{in.name});
    if (!releaseVersion(in.version)) return refuse(d, alloc, "metadata: the version `{s}` is not a release version (dot-separated numbers; no local, pre- or post-release part)", .{in.version});
    try oneLine(alloc, d, "the summary", in.summary);
    try oneLine(alloc, d, "requires_python", in.requires_python);
    try oneLine(alloc, d, "license_expression", in.license_expression);
    for (in.requires_dist) |r| try oneLine(alloc, d, "a requirement", r);
    for (in.classifiers) |c| {
        try oneLine(alloc, d, "a classifier", c);
        if (std.mem.startsWith(u8, c, "License ::"))
            return refuse(d, alloc, "metadata: the classifier `{s}` beside license_expression: PEP 639 forbids License :: classifiers with a License-Expression", .{c});
    }
    for (in.project_urls) |u| {
        try oneLine(alloc, d, "a project URL label", u.label);
        try oneLine(alloc, d, "a project URL", u.url);
        if (std.mem.indexOfScalar(u8, u.label, ',') != null) return refuse(d, alloc, "metadata: the project URL label `{s}` holds `,`, which ends the label in METADATA", .{u.label});
        if (u.label.len > 32) return refuse(d, alloc, "metadata: the project URL label `{s}` is over 32 characters, which the core metadata spec allows", .{u.label});
    }
    if (in.licenses.len == 0) return refuse(d, alloc, "metadata: no licence file: a wheel carries its licence text (PEP 639)", .{});
    for (in.licenses, 0..) |l, i| {
        if (std.mem.indexOfScalar(u8, l.path, '/') != null) return refuse(d, alloc, "metadata: the licence file `{s}` is not a bare file name", .{l.path});
        try checkPath(alloc, d, l.path);
        for (in.licenses[0..i]) |prev| if (std.mem.eql(u8, prev.path, l.path)) return refuse(d, alloc, "metadata: the licence file `{s}` is given twice", .{l.path});
    }
}

fn lessFile(_: void, a: File, b: File) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

/// The licence files in the order METADATA and the wheel list them.
pub fn sortedLicenses(alloc: Alloc, licenses: []const File) ![]File {
    const out = try alloc.dupe(File, licenses);
    std.mem.sort(File, out, {}, lessFile);
    return out;
}

/// The core metadata, with the README as its body.
pub fn renderMetadata(alloc: Alloc, in: Input) Alloc.Error![]u8 {
    var out = std.ArrayList(u8).empty;
    const line = struct {
        fn f(a: Alloc, o: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) Alloc.Error!void {
            try o.appendSlice(a, try std.fmt.allocPrint(a, fmt ++ "\n", args));
        }
    }.f;
    try line(alloc, &out, "Metadata-Version: 2.4", .{});
    try line(alloc, &out, "Name: {s}", .{in.name});
    try line(alloc, &out, "Version: {s}", .{in.version});
    try line(alloc, &out, "Summary: {s}", .{in.summary});
    try line(alloc, &out, "Requires-Python: {s}", .{in.requires_python});
    try line(alloc, &out, "License-Expression: {s}", .{in.license_expression});
    for (try sortedLicenses(alloc, in.licenses)) |l| try line(alloc, &out, "License-File: {s}", .{l.path});
    for (in.classifiers) |c| try line(alloc, &out, "Classifier: {s}", .{c});
    for (in.project_urls) |u| try line(alloc, &out, "Project-URL: {s}, {s}", .{ u.label, u.url });
    for (in.requires_dist) |r| try line(alloc, &out, "Requires-Dist: {s}", .{r});
    try line(alloc, &out, "Description-Content-Type: text/markdown", .{});
    try out.append(alloc, '\n');
    try out.appendSlice(alloc, in.readme);
    return out.toOwnedSlice(alloc);
}

pub fn renderWheel(alloc: Alloc, tag: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "Wheel-Version: 1.0\nGenerator: {s}\nRoot-Is-Purelib: false\nTag: {s}\n", .{ generator, tag });
}

/// `sha256=<urlsafe base64, no padding>` of `data`, as RECORD spells a hash.
pub fn recordHash(alloc: Alloc, data: []const u8) ![]const u8 {
    var dig: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &dig, .{});
    const enc = std.base64.url_safe_no_pad.Encoder;
    const buf = try alloc.alloc(u8, enc.calcSize(dig.len));
    _ = enc.encode(buf, &dig);
    return std.fmt.allocPrint(alloc, "sha256={s}", .{buf});
}

/// RECORD: one `path,hash,size` row per member, then its own row with no hash
/// or size. No path needs CSV quoting (checkPath refuses one that would).
pub fn renderRecord(alloc: Alloc, members: []const zip.Member, record_path: []const u8) Alloc.Error![]u8 {
    var out = std.ArrayList(u8).empty;
    for (members) |m| try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s},{s},{d}\n", .{ m.name, try recordHash(alloc, m.data), m.data.len }));
    try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{s},,\n", .{record_path}));
    return out.toOwnedSlice(alloc);
}

/// A member path the wheel can carry: relative, `/`-separated, printable
/// ASCII (the zip names no encoding), no empty, `.` or `..` part, and nothing
/// RECORD's CSV would have to quote.
pub fn checkPath(alloc: Alloc, d: *Diag, path: []const u8) Refused!void {
    if (path.len == 0 or path[0] == '/') return refuse(d, alloc, "path: `{s}` is not a relative path", .{path});
    if (std.mem.indexOfAny(u8, path, ",\"\\") != null) return refuse(d, alloc, "path: `{s}` holds a comma, a quote or a backslash", .{path});
    for (path) |c| if (c >= 0x7f or c < 0x20) return refuse(d, alloc, "path: `{s}` holds a byte outside printable ASCII", .{path});
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |p| {
        if (p.len == 0 or std.mem.eql(u8, p, ".") or std.mem.eql(u8, p, ".."))
            return refuse(d, alloc, "path: `{s}` has an empty, `.` or `..` part", .{path});
        if (std.mem.endsWith(u8, p, ".dist-info") or std.mem.endsWith(u8, p, ".data"))
            return refuse(d, alloc, "path: `{s}` is under a .dist-info or .data directory, which the wheel rule writes itself", .{path});
    }
}

/// The policy of `in`, for its files (native_policy's policy.zig).
pub fn policyOf(t: tag_mod.Tag, in: Input) policy.Policy {
    return .{ .glibc = t.glibc, .macos = t.macos, .arch = t.arch, .max_glibcxx = in.max_glibcxx, .max_cxxabi = in.max_cxxabi, .external_needed = in.external_needed };
}

/// The wheel of `in`, dated `stamp`.
pub fn build(alloc: Alloc, d: *Diag, in: Input, stamp: zip.Stamp) Refused![]u8 {
    const t = try tag_mod.parse(alloc, d, in.tag);
    try checkMetadata(alloc, d, in);
    const files = try alloc.dupe(File, in.files);
    std.mem.sort(File, files, {}, lessFile);
    var body = std.ArrayList(zip.Member).empty;
    var checked = std.ArrayList(policy.Member).empty;
    for (files, 0..) |f, i| {
        try checkPath(alloc, d, f.path);
        if (i > 0 and std.mem.eql(u8, f.path, files[i - 1].path)) return refuse(d, alloc, "path: `{s}` is given twice", .{f.path});
        try body.append(alloc, .{ .name = f.path, .data = f.data, .mode = f.mode });
        try checked.append(alloc, .{ .name = f.path, .data = f.data });
    }
    if (files.len == 0) return refuse(d, alloc, "path: the wheel has no files", .{});
    try policy.check(alloc, d, policyOf(t, in), checked.items);

    const info = try distInfo(alloc, in.name, in.version);
    try body.append(alloc, .{ .name = try std.fmt.allocPrint(alloc, "{s}/METADATA", .{info}), .data = try renderMetadata(alloc, in) });
    try body.append(alloc, .{ .name = try std.fmt.allocPrint(alloc, "{s}/WHEEL", .{info}), .data = try renderWheel(alloc, in.tag) });
    for (try sortedLicenses(alloc, in.licenses)) |l| try body.append(alloc, .{ .name = try std.fmt.allocPrint(alloc, "{s}/licenses/{s}", .{ info, l.path }), .data = l.data });
    const record_path = try std.fmt.allocPrint(alloc, "{s}/RECORD", .{info});
    try body.append(alloc, .{ .name = record_path, .data = try renderRecord(alloc, body.items, record_path) });
    return zip.write(alloc, d, body.items, stamp);
}
