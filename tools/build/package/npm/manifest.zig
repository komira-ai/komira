//! komira_npm: the package.json a tarball carries, stamped from the one
//! checked in beside the package's sources, and held to what the rule says
//! the package is.
//!
//! The source manifest is the development one: `"version": "0.0.0"`,
//! `"private": true`, and every optional dependency at `0.0.0`. Stamping it
//! changes only those values: the version and every optional dependency become
//! the stamp's version, and a stamped package drops `private` (an unstamped
//! one keeps it, so npm refuses to publish it). Of the source's optional
//! dependencies the package keeps exactly the rule's (`Want.optional`, each
//! one the source lists), in the source's order, and drops the key when it
//! keeps none: the source lists every platform package, and a main package
//! names only those published with it. Every other key keeps its value and
//! its place; the text is written as `JSON.stringify(v, null, 2)` writes it,
//! with a final newline.
//!
//! Held, in the source and again in the package.json read back:
//!   * `name` is the rule's name, and `license` the rule's licence;
//!   * `repository.url` is https://github.com/komira-ai/komira, which npm's
//!     trusted publishing requires the package to state;
//!   * `os`, `cpu` and `libc` are exactly the platform's (one value each), or
//!     absent for a package with no platform;
//!   * the optional dependencies are exactly the rule's (read back);
//!   * `files` is a list of paths and globs (`*` within a part, `**` for any
//!     parts; no negation), so the tarball's members can be held to it;
//!   * no install script (`preinstall`, `install`, `postinstall`): npm
//!     install is the only step;
//!   * numbers are integers (no package.json key needs another).

const std = @import("std");
const diag = @import("native_policy").diag;
const json = std.json;
const Alloc = std.mem.Allocator;
const Diag = diag.Diag;
const Refused = diag.Refused;
const refuse = diag.refuse;

pub const repository_url = "https://github.com/komira-ai/komira";

pub const unstamped_version = "0.0.0";

/// The `os`, `cpu` and `libc` npm selects a platform package by; all null
/// for a package that holds no native file.
pub const Platform = struct {
    os: ?[]const u8 = null,
    cpu: ?[]const u8 = null,
    libc: ?[]const u8 = null,
};

/// What the rule says the package is.
pub const Want = struct {
    name: []const u8,
    version: []const u8,
    stamped: bool,
    license: []const u8,
    platform: Platform = .{},
    /// The optional dependencies the package names: each one the source
    /// manifest lists, none twice; the others are dropped.
    optional: []const []const u8 = &.{},
};

/// The stamped manifest's text, and its `files` list.
pub const Stamped = struct {
    bytes: []const u8,
    files: []const []const u8,
};

const install_scripts = [_][]const u8{ "preinstall", "install", "postinstall" };

pub fn parse(alloc: Alloc, d: *Diag, what: []const u8, bytes: []const u8) Refused!json.ObjectMap {
    const v = json.parseFromSliceLeaky(json.Value, alloc, bytes, .{}) catch |err|
        return refuse(d, alloc, "manifest: {s} is not JSON ({s})", .{ what, @errorName(err) });
    if (v != .object) return refuse(d, alloc, "manifest: {s} is not a JSON object", .{what});
    return v.object;
}

fn stringOf(obj: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// `key` of `obj` is exactly the one-string list `[want]`, or absent when
/// `want` is null.
fn checkPlatformField(alloc: Alloc, d: *Diag, obj: json.ObjectMap, key: []const u8, want: ?[]const u8) Refused!void {
    const got = obj.get(key);
    const w = want orelse {
        if (got != null) return refuse(d, alloc, "platform: the manifest names `{s}`, and a package with no platform names none", .{key});
        return;
    };
    const ok = if (got) |g| g == .array and g.array.items.len == 1 and g.array.items[0] == .string and std.mem.eql(u8, g.array.items[0].string, w) else false;
    if (!ok) return refuse(d, alloc, "platform: the manifest's `{s}` is not [\"{s}\"], the platform's", .{ key, w });
}

/// The `files` list of `obj`, each entry checked.
fn filesOf(alloc: Alloc, d: *Diag, obj: json.ObjectMap) Refused![]const []const u8 {
    const v = obj.get("files") orelse return refuse(d, alloc, "files: the manifest has no `files` list, so it does not say what npm packs", .{});
    if (v != .array) return refuse(d, alloc, "files: the manifest's `files` is not a list", .{});
    var out = std.ArrayList([]const u8).empty;
    for (v.array.items) |e| {
        if (e != .string) return refuse(d, alloc, "files: an entry of `files` is not a string", .{});
        const s = e.string;
        if (s.len == 0 or s[0] == '/' or s[0] == '!' or std.mem.startsWith(u8, s, "./") or s[s.len - 1] == '/' or std.mem.indexOfScalar(u8, s, '\\') != null)
            return refuse(d, alloc, "files: the entry `{s}` is not a relative path or glob (no leading `/`, `./` or `!`, no trailing `/`, no `\\`)", .{s});
        var parts = std.mem.splitScalar(u8, s, '/');
        while (parts.next()) |p| {
            if (p.len == 0 or std.mem.eql(u8, p, ".") or std.mem.eql(u8, p, ".."))
                return refuse(d, alloc, "files: the entry `{s}` has an empty, `.` or `..` part", .{s});
        }
        try out.append(alloc, s);
    }
    return out.toOwnedSlice(alloc);
}

/// The fields every manifest is held to, source and written alike.
fn checkFields(alloc: Alloc, d: *Diag, obj: json.ObjectMap, want: Want) Refused![]const []const u8 {
    const name = stringOf(obj, "name") orelse return refuse(d, alloc, "manifest: the manifest has no `name` string", .{});
    if (!std.mem.eql(u8, name, want.name)) return refuse(d, alloc, "manifest: the manifest names the package {s}, not {s}", .{ name, want.name });
    const license = stringOf(obj, "license") orelse return refuse(d, alloc, "manifest: the manifest has no `license` string", .{});
    if (!std.mem.eql(u8, license, want.license)) return refuse(d, alloc, "manifest: the manifest's licence is `{s}`, not the rule's `{s}`", .{ license, want.license });
    const repo = obj.get("repository") orelse return refuse(d, alloc, "repository: the manifest has no `repository`, and trusted publishing needs its url to be {s}", .{repository_url});
    const url = if (repo == .object) stringOf(repo.object, "url") else null;
    const u = url orelse return refuse(d, alloc, "repository: the manifest's `repository` is not an object with a `url` string, and trusted publishing needs its url to be {s}", .{repository_url});
    if (!std.mem.eql(u8, u, repository_url)) return refuse(d, alloc, "repository: the manifest's repository.url is `{s}`, not {s}, which trusted publishing requires", .{ u, repository_url });
    try checkPlatformField(alloc, d, obj, "os", want.platform.os);
    try checkPlatformField(alloc, d, obj, "cpu", want.platform.cpu);
    try checkPlatformField(alloc, d, obj, "libc", want.platform.libc);
    if (obj.get("scripts")) |s| {
        if (s == .object) {
            for (install_scripts) |k| {
                if (s.object.get(k) != null)
                    return refuse(d, alloc, "scripts: the manifest has a `{s}` script, and npm install is the only step: a package runs nothing at install", .{k});
            }
        }
    }
    try checkNumbers(alloc, d, .{ .object = obj });
    return filesOf(alloc, d, obj);
}

fn checkNumbers(alloc: Alloc, d: *Diag, v: json.Value) Refused!void {
    switch (v) {
        .float, .number_string => return refuse(d, alloc, "manifest: the manifest holds a number that is not an integer", .{}),
        .array => |a| {
            for (a.items) |x| try checkNumbers(alloc, d, x);
        },
        .object => |o| {
            for (o.values()) |x| try checkNumbers(alloc, d, x);
        },
        else => {},
    }
}

/// The optional dependencies of `obj` (an empty object when it has none).
fn optionalOf(alloc: Alloc, d: *Diag, obj: json.ObjectMap) Refused!?*json.ObjectMap {
    const p = obj.getPtr("optionalDependencies") orelse return null;
    if (p.* != .object) return refuse(d, alloc, "manifest: the manifest's `optionalDependencies` is not an object", .{});
    return &p.object;
}

fn listed(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// Keeps of `obj`'s optional dependencies exactly `keep`, in their order in
/// `obj`; refused when `keep` names one twice or one `obj` does not list. With
/// none kept, the key goes.
fn keepOptional(alloc: Alloc, d: *Diag, obj: *json.ObjectMap, keep: []const []const u8) Refused!void {
    for (keep, 0..) |k, i| {
        if (listed(keep[0..i], k)) return refuse(d, alloc, "optional: the rule names the optional dependency {s} twice", .{k});
    }
    const opt = try optionalOf(alloc, d, obj.*);
    for (keep) |k| {
        const has = if (opt) |o| o.contains(k) else false;
        if (!has) return refuse(d, alloc, "optional: the rule names the optional dependency {s}, which the source manifest does not list", .{k});
    }
    const o = opt orelse return;
    var drop = std.ArrayList([]const u8).empty;
    for (o.keys()) |k| {
        if (!listed(keep, k)) try drop.append(alloc, k);
    }
    for (drop.items) |k| _ = o.orderedRemove(k);
    if (keep.len == 0) _ = obj.orderedRemove("optionalDependencies");
}

/// The source manifest `source`, stamped for `want`.
pub fn stamp(alloc: Alloc, d: *Diag, source: []const u8, want: Want) Refused!Stamped {
    var obj = try parse(alloc, d, "the source manifest", source);
    const files = try checkFields(alloc, d, obj, want);
    const ver = stringOf(obj, "version") orelse return refuse(d, alloc, "manifest: the source manifest has no `version` string", .{});
    if (!std.mem.eql(u8, ver, unstamped_version)) return refuse(d, alloc, "manifest: the source manifest's version is {s}; the rule stamps the version, so the source says {s}", .{ ver, unstamped_version });
    const private = obj.get("private");
    if (private == null or private.? != .bool or !private.?.bool) return refuse(d, alloc, "manifest: the source manifest is not `\"private\": true`; the rule drops it from a stamped package, so no unstamped one is published", .{});
    if (try optionalOf(alloc, d, obj)) |opt| {
        for (opt.keys(), opt.values()) |k, *v| {
            if (v.* != .string or !std.mem.eql(u8, v.string, unstamped_version))
                return refuse(d, alloc, "manifest: the source manifest's optional dependency {s} is not at {s}; the rule stamps it with the package's version", .{ k, unstamped_version });
            v.* = .{ .string = want.version };
        }
    }
    try keepOptional(alloc, d, &obj, want.optional);
    try obj.put("version", .{ .string = want.version });
    if (want.stamped) _ = obj.orderedRemove("private");
    return .{ .bytes = try render(alloc, .{ .object = obj }), .files = files };
}

/// The package.json read back from a tarball, held to `want`: the fields
/// above, the stamp's version on the package and on every optional
/// dependency, exactly the rule's optional dependencies, and `private` true
/// exactly when unstamped. Its `files` list.
pub fn checkWritten(alloc: Alloc, d: *Diag, bytes: []const u8, want: Want) Refused![]const []const u8 {
    const obj = try parse(alloc, d, "the package's package.json", bytes);
    const files = try checkFields(alloc, d, obj, want);
    const ver = stringOf(obj, "version") orelse return refuse(d, alloc, "version: the package.json has no `version` string", .{});
    if (!std.mem.eql(u8, ver, want.version)) return refuse(d, alloc, "version: the package.json's version is {s}, not the stamp's {s}", .{ ver, want.version });
    const opt = try optionalOf(alloc, d, obj);
    if (opt) |o| {
        for (o.keys(), o.values()) |k, v| {
            if (!listed(want.optional, k))
                return refuse(d, alloc, "optional: the package.json names the optional dependency {s}, which the rule does not", .{k});
            if (v != .string or !std.mem.eql(u8, v.string, want.version))
                return refuse(d, alloc, "version: the package.json's optional dependency {s} is not at the package's version {s}", .{ k, want.version });
        }
    }
    for (want.optional) |k| {
        const has = if (opt) |o| o.contains(k) else false;
        if (!has) return refuse(d, alloc, "optional: the package.json does not name the optional dependency {s}, which the rule does", .{k});
    }
    const private = obj.get("private");
    const is_private = private != null and private.? == .bool and private.?.bool;
    if (want.stamped and private != null) return refuse(d, alloc, "version: the stamped package.json keeps `private`, so npm would not publish it", .{});
    if (!want.stamped and !is_private) return refuse(d, alloc, "version: the unstamped package.json is not `\"private\": true`, so npm would publish a development package", .{});
    return files;
}

fn lower(c: u8) u8 {
    return std.ascii.toLower(c);
}

/// Whether the file name `f` is `stem` or `stem.<anything>`, in any case.
fn named(f: []const u8, stem: []const u8) bool {
    if (f.len < stem.len) return false;
    for (f[0..stem.len], stem) |a, b| {
        if (lower(a) != b) return false;
    }
    return f.len == stem.len or f[stem.len] == '.';
}

/// Whether npm packs `path` whatever `files` says: package.json, and a
/// README or licence file at the top.
pub fn alwaysPacked(path: []const u8) bool {
    if (std.mem.eql(u8, path, "package.json")) return true;
    if (std.mem.indexOfScalar(u8, path, '/') != null) return false;
    return named(path, "readme") or named(path, "license") or named(path, "licence");
}

/// Whether the path part `s` matches the glob part `p` (`*` any run of
/// characters, `?` one).
fn partMatch(p: []const u8, s: []const u8) bool {
    if (p.len == 0) return s.len == 0;
    if (p[0] == '*') {
        var i: usize = 0;
        while (i <= s.len) : (i += 1) {
            if (partMatch(p[1..], s[i..])) return true;
        }
        return false;
    }
    if (s.len == 0) return false;
    return (p[0] == '?' or p[0] == s[0]) and partMatch(p[1..], s[1..]);
}

fn partsMatch(p: []const []const u8, s: []const []const u8) bool {
    if (p.len == 0) return s.len == 0;
    if (std.mem.eql(u8, p[0], "**")) {
        var i: usize = 0;
        while (i <= s.len) : (i += 1) {
            if (partsMatch(p[1..], s[i..])) return true;
        }
        return false;
    }
    if (s.len == 0) return false;
    return partMatch(p[0], s[0]) and partsMatch(p[1..], s[1..]);
}

fn split(alloc: Alloc, s: []const u8) Alloc.Error![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, s, '/');
    while (it.next()) |p| try out.append(alloc, p);
    return out.toOwnedSlice(alloc);
}

/// Whether the entry `entry` of `files` packs `path`: the path itself or a
/// file under it, matched part by part, as npm packs a directory it names.
pub fn entryPacks(alloc: Alloc, entry: []const u8, path: []const u8) Alloc.Error!bool {
    const e = try split(alloc, entry);
    const p = try split(alloc, path);
    var i: usize = 1;
    while (i <= p.len) : (i += 1) {
        if (partsMatch(e, p[0..i])) return true;
    }
    return false;
}

/// Whether npm packs `path` for a manifest whose `files` list is `files`.
pub fn packs(alloc: Alloc, files: []const []const u8, path: []const u8) Alloc.Error!bool {
    if (alwaysPacked(path)) return true;
    for (files) |f| {
        if (try entryPacks(alloc, f, path)) return true;
    }
    return false;
}

fn indent(alloc: Alloc, out: *std.ArrayList(u8), n: usize) Alloc.Error!void {
    try out.appendNTimes(alloc, ' ', n);
}

fn putString(alloc: Alloc, out: *std.ArrayList(u8), s: []const u8) Alloc.Error!void {
    try out.append(alloc, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(alloc, "\\\""),
        '\\' => try out.appendSlice(alloc, "\\\\"),
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\r' => try out.appendSlice(alloc, "\\r"),
        '\t' => try out.appendSlice(alloc, "\\t"),
        0x08 => try out.appendSlice(alloc, "\\b"),
        0x0c => try out.appendSlice(alloc, "\\f"),
        0...0x07, 0x0b, 0x0e...0x1f => try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "\\u{x:0>4}", .{c})),
        else => try out.append(alloc, c),
    };
    try out.append(alloc, '"');
}

fn put(alloc: Alloc, out: *std.ArrayList(u8), v: json.Value, depth: usize) Alloc.Error!void {
    switch (v) {
        .null => try out.appendSlice(alloc, "null"),
        .bool => |b| try out.appendSlice(alloc, if (b) "true" else "false"),
        .integer => |i| try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{d}", .{i})),
        // checkNumbers refused every other number before anything is rendered.
        .float, .number_string => unreachable,
        .string => |s| try putString(alloc, out, s),
        .array => |a| {
            if (a.items.len == 0) return out.appendSlice(alloc, "[]");
            try out.appendSlice(alloc, "[\n");
            for (a.items, 0..) |x, i| {
                try indent(alloc, out, 2 * (depth + 1));
                try put(alloc, out, x, depth + 1);
                try out.appendSlice(alloc, if (i + 1 < a.items.len) ",\n" else "\n");
            }
            try indent(alloc, out, 2 * depth);
            try out.append(alloc, ']');
        },
        .object => |o| {
            if (o.count() == 0) return out.appendSlice(alloc, "{}");
            try out.appendSlice(alloc, "{\n");
            for (o.keys(), o.values(), 0..) |k, x, i| {
                try indent(alloc, out, 2 * (depth + 1));
                try putString(alloc, out, k);
                try out.appendSlice(alloc, ": ");
                try put(alloc, out, x, depth + 1);
                try out.appendSlice(alloc, if (i + 1 < o.count()) ",\n" else "\n");
            }
            try indent(alloc, out, 2 * depth);
            try out.append(alloc, '}');
        },
    }
}

/// `v` as `JSON.stringify(v, null, 2)` writes it, and a newline. Only a
/// value checkNumbers passed.
pub fn render(alloc: Alloc, v: json.Value) Alloc.Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    try put(alloc, &out, v, 0);
    try out.append(alloc, '\n');
    return out.toOwnedSlice(alloc);
}
