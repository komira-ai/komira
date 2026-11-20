//! komira_wheel: a wheel (PEP 427, core metadata 2.4) made from a package's
//! files, its native libraries, its licence files and its pyproject's
//! `[project]`, byte for byte reproducible.
//!
//! The wheel holds, in this order:
//!   <import>/...                 the package's files, sorted bytewise by path;
//!   <import>/_lib/...            the native directory (libkomira, and lib/ of
//!                                its native owners), sorted, without the
//!                                runtime libraries named to leave out;
//!   <dist>-<version>.dist-info/METADATA, WHEEL, licenses/<name>... (sorted),
//!   and RECORD last.
//! Every function returns the refusal in a Diag (wheel_project.zig); only the
//! command exits.

const std = @import("std");
const project = @import("wheel_project.zig");
const zip = @import("wheel_zip.zig");
const Alloc = std.mem.Allocator;
const Diag = project.Diag;
const Project = project.Project;
const Refused = project.Refused;
const refuse = project.refuse;

pub const File = struct {
    path: []const u8,
    data: []const u8,
    mode: u32 = 0o644,
};

pub const Input = struct {
    project: Project,
    /// The README's file name (it must be the pyproject's `readme`) and bytes.
    readme_name: []const u8,
    readme: []const u8,
    version: []const u8,
    tag: []const u8,
    /// Requirements the build adds after the pyproject's `dependencies`: the
    /// Mojo runtime's package, pinned to the compiler the library was built with.
    runtime_requires: []const []const u8,
    import_name: []const u8,
    /// The package's files, at their paths in the wheel (`<import>/...`).
    package_files: []const File,
    /// The native directory's files, at their paths in that directory.
    native_files: []const File,
    /// The library the package loads, at the top of the native directory.
    native_lib: []const u8,
    /// Runtime libraries the native directory holds under lib/ that the wheel
    /// must not carry (the Mojo runtime comes from its own package).
    native_drop: []const []const u8,
    /// The licence files, by their name in `license-files`.
    licenses: []const File,
};

pub const Built = struct {
    file_name: []const u8,
    wheel: []u8,
    metadata: []u8,
};

pub const generator = "komira_wheel";
pub const native_dir = "_lib";

fn isDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// `<base>.post<stamp>` (packaging/conda/README.md, "Wheels: versioning"): the
/// compiler version, then the release's build number as a PEP 440
/// post-release. An unstamped build is `.post0`, which the release check
/// refuses.
pub fn version(alloc: Alloc, d: *Diag, base: []const u8, stamp: []const u8) Refused![]const u8 {
    var parts = std.mem.splitScalar(u8, base, '.');
    while (parts.next()) |p| {
        if (!isDigits(p) or (p.len > 1 and p[0] == '0'))
            return refuse(d, alloc, "the base version `{s}` is not dot-separated numbers without leading zeros", .{base});
    }
    if (!isDigits(stamp) or (stamp.len > 1 and stamp[0] == '0'))
        return refuse(d, alloc, "the stamp `{s}` is not a number without leading zeros", .{stamp});
    return std.fmt.allocPrint(alloc, "{s}.post{s}", .{ base, stamp });
}

/// A tag the package can carry: `py3-none-<platform>`. The package loads its
/// library with ctypes and uses no CPython ABI, so the interpreter part is
/// `py3` and the ABI part `none`; the platform part is the build's.
pub fn checkTag(alloc: Alloc, d: *Diag, tag: []const u8) Refused!void {
    const head = "py3-none-";
    if (!std.mem.startsWith(u8, tag, head) or tag.len == head.len)
        return refuse(d, alloc, "the tag `{s}` is not `py3-none-<platform>` (the package loads its library with ctypes and uses no CPython ABI)", .{tag});
    for (tag[head.len..]) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_'))
            return refuse(d, alloc, "the platform tag `{s}` holds `{c}`", .{ tag[head.len..], c });
    }
}

/// The distribution's name as a wheel's file name spells it: `-` becomes `_`.
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

/// The core metadata (version 2.4, for PEP 639's License-Expression and
/// License-File), with the README as its body.
pub fn renderMetadata(alloc: Alloc, p: Project, ver: []const u8, runtime_requires: []const []const u8, readme: []const u8) Alloc.Error![]u8 {
    return metadataText(alloc, p, ver, runtime_requires, readme) catch |err| switch (err) {
        // An allocating writer fails only when its allocation does.
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
    };
}

fn metadataText(alloc: Alloc, p: Project, ver: []const u8, runtime_requires: []const []const u8, readme: []const u8) ![]u8 {
    var w = std.Io.Writer.Allocating.init(alloc);
    const o = &w.writer;
    try o.print("Metadata-Version: 2.4\nName: {s}\nVersion: {s}\nSummary: {s}\n", .{ p.name, ver, p.description });
    if (p.authors.len != 0) try o.print("Author: {s}\n", .{try std.mem.join(alloc, ", ", p.authors)});
    try o.print("License-Expression: {s}\n", .{p.license});
    for (p.license_files) |f| try o.print("License-File: {s}\n", .{f});
    if (p.keywords.len != 0) try o.print("Keywords: {s}\n", .{try std.mem.join(alloc, ",", p.keywords)});
    for (p.classifiers) |c| try o.print("Classifier: {s}\n", .{c});
    for (p.urls) |u| try o.print("Project-URL: {s}, {s}\n", .{ u.label, u.url });
    try o.print("Requires-Python: {s}\n", .{p.requires_python});
    for (p.dependencies) |r| try o.print("Requires-Dist: {s}\n", .{r});
    for (runtime_requires) |r| try o.print("Requires-Dist: {s}\n", .{r});
    for (p.extras) |e| {
        try o.print("Provides-Extra: {s}\n", .{e.name});
        for (e.requires) |r| try o.print("Requires-Dist: {s}; extra == \"{s}\"\n", .{ r, e.name });
    }
    try o.print("Description-Content-Type: text/markdown\n\n", .{});
    try o.writeAll(readme);
    return w.toOwnedSlice();
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

/// A member path the wheel can carry: relative, `/`-separated, no empty, `.`
/// or `..` part, and nothing RECORD's CSV would have to quote.
pub fn checkPath(alloc: Alloc, d: *Diag, path: []const u8) Refused!void {
    if (path.len == 0 or path[0] == '/') return refuse(d, alloc, "`{s}` is not a relative path", .{path});
    if (std.mem.indexOfAny(u8, path, ",\"\r\n\\") != null) return refuse(d, alloc, "`{s}` holds a comma, a quote, a backslash or a line break", .{path});
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |p| {
        if (p.len == 0 or std.mem.eql(u8, p, ".") or std.mem.eql(u8, p, ".."))
            return refuse(d, alloc, "`{s}` has an empty, `.` or `..` part", .{path});
    }
}

fn lessMember(_: void, a: zip.Member, b: zip.Member) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn has(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn packageMembers(alloc: Alloc, d: *Diag, in: Input, out: *std.ArrayList(zip.Member)) Refused!void {
    const prefix = try std.fmt.allocPrint(alloc, "{s}/", .{in.import_name});
    const lib_prefix = try std.fmt.allocPrint(alloc, "{s}/{s}/", .{ in.import_name, native_dir });
    var init = false;
    var typed = false;
    for (in.package_files) |f| {
        try checkPath(alloc, d, f.path);
        if (!std.mem.startsWith(u8, f.path, prefix))
            return refuse(d, alloc, "the package file `{s}` is not under `{s}`: the wheel carries the import package and nothing beside it", .{ f.path, prefix });
        if (std.mem.startsWith(u8, f.path, lib_prefix))
            return refuse(d, alloc, "the package file `{s}` is under `{s}`, where the wheel puts the native directory", .{ f.path, lib_prefix });
        if (std.mem.endsWith(u8, f.path, ".pyc") or std.mem.indexOf(u8, f.path, "__pycache__") != null or std.mem.indexOf(u8, f.path, ".dist-info") != null)
            return refuse(d, alloc, "the package file `{s}` is bytecode or metadata the wheel rule writes itself", .{f.path});
        init = init or std.mem.eql(u8, f.path[prefix.len..], "__init__.py");
        typed = typed or std.mem.eql(u8, f.path[prefix.len..], "py.typed");
        try out.append(alloc, .{ .name = f.path, .data = f.data, .mode = f.mode });
    }
    if (!init) return refuse(d, alloc, "the package has no `{s}__init__.py`", .{prefix});
    if (!typed) return refuse(d, alloc, "the package has no `{s}py.typed`: it ships typed (PEP 561)", .{prefix});

    var lib = false;
    const dropped = try alloc.alloc(bool, in.native_drop.len);
    @memset(dropped, false);
    native: for (in.native_files) |f| {
        try checkPath(alloc, d, f.path);
        for (in.native_drop, 0..) |name, i| {
            if (std.mem.startsWith(u8, f.path, "lib/") and std.mem.eql(u8, f.path["lib/".len..], name)) {
                dropped[i] = true;
                continue :native;
            }
        }
        lib = lib or std.mem.eql(u8, f.path, in.native_lib);
        try out.append(alloc, .{ .name = try std.fmt.allocPrint(alloc, "{s}{s}", .{ lib_prefix, f.path }), .data = f.data, .mode = f.mode });
    }
    if (!lib) return refuse(d, alloc, "the native directory has no `{s}` at its top", .{in.native_lib});
    for (in.native_drop, dropped) |name, ok| {
        if (!ok) return refuse(d, alloc, "the native directory has no `lib/{s}` to leave out: the list of runtime libraries and the directory disagree", .{name});
    }
}

/// The wheel of `in`, its file name and its METADATA.
pub fn build(alloc: Alloc, d: *Diag, in: Input) Refused!Built {
    const p = in.project;
    try checkTag(alloc, d, in.tag);
    if (!project.normalName(in.import_name) or std.mem.indexOfScalar(u8, in.import_name, '-') != null)
        return refuse(d, alloc, "the import name `{s}` is not a Python package name in lowercase", .{in.import_name});
    if (!std.mem.eql(u8, in.readme_name, p.readme))
        return refuse(d, alloc, "the README given is `{s}`, but the pyproject's `readme` is `{s}`", .{ in.readme_name, p.readme });
    if (!std.mem.endsWith(u8, p.readme, ".md"))
        return refuse(d, alloc, "the readme `{s}` is not Markdown (`.md`), the one content type the wheel rule writes", .{p.readme});
    for (in.licenses) |l| {
        if (std.mem.indexOfScalar(u8, l.path, '/') != null) return refuse(d, alloc, "the licence file `{s}` is not a bare file name", .{l.path});
        try checkPath(alloc, d, l.path);
        if (!has(p.license_files, l.path)) return refuse(d, alloc, "the licence file `{s}` is not in the pyproject's `license-files`", .{l.path});
    }
    for (p.license_files) |name| {
        var found: usize = 0;
        for (in.licenses) |l| found += @intFromBool(std.mem.eql(u8, l.path, name));
        if (found != 1) return refuse(d, alloc, "the pyproject's `license-files` names `{s}`, which is given {d} times (once is required): a wheel without its licence text is refused", .{ name, found });
    }

    var body = std.ArrayList(zip.Member).empty;
    try packageMembers(alloc, d, in, &body);
    std.mem.sort(zip.Member, body.items, {}, lessMember);
    for (body.items[1..], 1..) |m, i| {
        if (std.mem.eql(u8, m.name, body.items[i - 1].name)) return refuse(d, alloc, "`{s}` is given twice", .{m.name});
    }

    const info = try distInfo(alloc, p.name, in.version);
    const metadata = try renderMetadata(alloc, p, in.version, in.runtime_requires, in.readme);
    try body.append(alloc, .{ .name = try std.fmt.allocPrint(alloc, "{s}/METADATA", .{info}), .data = metadata });
    try body.append(alloc, .{ .name = try std.fmt.allocPrint(alloc, "{s}/WHEEL", .{info}), .data = try renderWheel(alloc, in.tag) });
    const lics = try alloc.dupe(File, in.licenses);
    std.mem.sort(File, lics, {}, struct {
        fn less(_: void, a: File, b: File) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.less);
    for (lics) |l| try body.append(alloc, .{ .name = try std.fmt.allocPrint(alloc, "{s}/licenses/{s}", .{ info, l.path }), .data = l.data });
    const record_path = try std.fmt.allocPrint(alloc, "{s}/RECORD", .{info});
    try body.append(alloc, .{ .name = record_path, .data = try renderRecord(alloc, body.items, record_path) });

    return .{
        .file_name = try fileName(alloc, p.name, in.version, in.tag),
        .wheel = try zip.write(alloc, d, body.items),
        .metadata = metadata,
    };
}

/// The release's artifact manifest for a PYTHON artifact: the keys of a CONDA
/// manifest (packaging/conda/README.md) without `subdir`, in this order,
/// compact, one trailing newline. `metadata` names the wheel's METADATA, the
/// file beside the manifest.
pub fn manifest(alloc: Alloc, name: []const u8, ver: []const u8, platform: []const u8, file: []const u8, sha256_hex: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "{{\"format\":\"kci.artifact_manifest\",\"schema_version\":1,\"artifact_type\":\"PYTHON\",\"name\":\"{s}\",\"version\":\"{s}\",\"platform\":\"{s}\",\"file\":\"{s}\",\"sha256\":\"{s}\",\"metadata\":\"METADATA\"}}\n",
        .{ name, ver, platform, file, sha256_hex },
    );
}
