//! pins.toml: the things that have no native lockfile (toolchains, release
//! binaries). The schema is README.md's "pins.toml"; this file checks it.

const std = @import("std");
const toml = @import("toml.zig");
const valid = @import("valid.zig");
const Diag = @import("diag.zig").Diag;

pub const Platform = struct {
    id: []const u8,
    /// What `{platform}` becomes in the url template.
    token: []const u8,
    /// A hash the human supplies (a bootstrap); `kpin update` otherwise
    /// computes it. Both are set or neither.
    sha256: ?[]const u8 = null,
    size: ?u64 = null,
};

pub const Pin = struct {
    name: []const u8,
    version: []const u8,
    /// Has `{version}` and `{platform}` in it.
    url: []const u8,
    /// A JSON document whose `latest_field` is the newest version.
    latest_url: ?[]const u8 = null,
    latest_field: ?[]const u8 = null,
    /// Stripped from the front of what `latest_field` holds (`v` for a tag).
    version_prefix: []const u8 = "",
    platforms: []Platform,
};

const pin_keys = [_][]const u8{ "version", "url", "latest_url", "latest_field", "version_prefix" };
const platform_keys = [_][]const u8{ "token", "sha256", "size" };

fn known(keys: []const []const u8, k: []const u8) bool {
    for (keys) |x| if (std.mem.eql(u8, x, k)) return true;
    return false;
}

fn str(t: *const toml.Table, key: []const u8, diag: *Diag) ?[]const u8 {
    const e = t.get(key) orelse return null;
    switch (e.value) {
        .string => |s| return s,
        .int => {
            diag.add("line {d}: `{s}` in [{s}] must be a string", .{ e.line, key, t.path });
            return null;
        },
    }
}

/// `{version}` and `{platform}` replaced; any other brace is an error.
pub fn expand(a: std.mem.Allocator, template: []const u8, version: []const u8, token: []const u8) error{ BadTemplate, OutOfMemory }![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    var i: usize = 0;
    while (i < template.len) {
        const c = template[i];
        if (c == '{') {
            if (std.mem.startsWith(u8, template[i..], "{version}")) {
                try out.appendSlice(a, version);
                i += "{version}".len;
            } else if (std.mem.startsWith(u8, template[i..], "{platform}")) {
                try out.appendSlice(a, token);
                i += "{platform}".len;
            } else return error.BadTemplate;
        } else if (c == '}') {
            return error.BadTemplate;
        } else {
            try out.append(a, c);
            i += 1;
        }
    }
    const url = try out.toOwnedSlice(a);
    if (!valid.isUrl(url)) return error.BadTemplate;
    return url;
}

fn lessPlatform(_: void, x: Platform, y: Platform) bool {
    return std.mem.lessThan(u8, x.id, y.id);
}

fn lessPin(_: void, x: Pin, y: Pin) bool {
    return std.mem.lessThan(u8, x.name, y.name);
}

/// The pins in `text`, by name. Problems go to `diag`; any makes the result
/// `error.Invalid`.
pub fn load(a: std.mem.Allocator, text: []const u8, diag: *Diag) error{Invalid}![]Pin {
    const before = diag.count();
    const tables = toml.parse(a, text, diag) catch return error.Invalid;
    var pins = std.ArrayListUnmanaged(Pin){};
    var plats = std.ArrayListUnmanaged(std.ArrayListUnmanaged(Platform)){};

    // Pass 1: the pin tables, `[name]`.
    for (tables) |*t| {
        if (std.mem.indexOfScalar(u8, t.path, '.') != null) continue;
        if (!valid.isPinName(t.path)) {
            diag.add("line {d}: pin name `{s}` must be lower-case letters, digits, - and _", .{ t.line, t.path });
            continue;
        }
        for (t.entries.items) |e| if (!known(&pin_keys, e.key)) {
            diag.add("line {d}: unknown key `{s}` in [{s}] (known: version, url, latest_url, latest_field, version_prefix)", .{ e.line, e.key, t.path });
        };
        const version = str(t, "version", diag) orelse {
            diag.add("line {d}: [{s}] needs a version", .{ t.line, t.path });
            continue;
        };
        const url = str(t, "url", diag) orelse {
            diag.add("line {d}: [{s}] needs a url template", .{ t.line, t.path });
            continue;
        };
        if (!valid.isVersion(version)) {
            diag.add("line {d}: version `{s}` of {s} has unsupported characters", .{ t.line, version, t.path });
            continue;
        }
        const latest_url = str(t, "latest_url", diag);
        const latest_field = str(t, "latest_field", diag);
        if ((latest_url == null) != (latest_field == null)) {
            diag.add("line {d}: [{s}] sets only one of latest_url and latest_field", .{ t.line, t.path });
            continue;
        }
        if (latest_url) |u| if (!valid.isUrl(u)) {
            diag.add("line {d}: latest_url of {s} is not a URL kpin accepts", .{ t.line, t.path });
            continue;
        };
        if (latest_field) |f| if (!valid.isJsonPath(f)) {
            diag.add("line {d}: latest_field of {s} is not a dotted path", .{ t.line, t.path });
            continue;
        };
        const prefix = str(t, "version_prefix", diag) orelse "";
        if (prefix.len > 0 and !valid.isVersion(prefix)) {
            diag.add("line {d}: version_prefix of {s} has unsupported characters", .{ t.line, t.path });
            continue;
        }
        pins.append(a, .{
            .name = t.path,
            .version = version,
            .url = url,
            .latest_url = latest_url,
            .latest_field = latest_field,
            .version_prefix = prefix,
            .platforms = &.{},
        }) catch return error.Invalid;
        plats.append(a, .{}) catch return error.Invalid;
    }

    // Pass 2: `[name.platform.id]`.
    for (tables) |*t| {
        if (std.mem.indexOfScalar(u8, t.path, '.') == null) continue;
        var segs = std.mem.splitScalar(u8, t.path, '.');
        const name = segs.next().?;
        const mid = segs.next() orelse "";
        const id = segs.next() orelse "";
        if (segs.next() != null or !std.mem.eql(u8, mid, "platform") or id.len == 0) {
            diag.add("line {d}: [{s}] is not a pin table or a [name.platform.id] table", .{ t.line, t.path });
            continue;
        }
        var idx: ?usize = null;
        for (pins.items, 0..) |p, i| if (std.mem.eql(u8, p.name, name)) {
            idx = i;
        };
        const pi = idx orelse {
            diag.add("line {d}: [{s}] names a pin ({s}) that has no [{s}] table", .{ t.line, t.path, name, name });
            continue;
        };
        if (!valid.isPinName(id)) {
            diag.add("line {d}: platform id `{s}` must be lower-case letters, digits, - and _", .{ t.line, id });
            continue;
        }
        for (t.entries.items) |e| if (!known(&platform_keys, e.key)) {
            diag.add("line {d}: unknown key `{s}` in [{s}] (known: token, sha256, size)", .{ e.line, e.key, t.path });
        };
        var token: []const u8 = id;
        if (str(t, "token", diag)) |tk| {
            if (!valid.isToken(tk)) {
                diag.add("line {d}: token `{s}` has unsupported characters", .{ t.line, tk });
                continue;
            }
            token = tk;
        }
        const sha = str(t, "sha256", diag);
        var size: ?u64 = null;
        if (t.get("size")) |e| switch (e.value) {
            .int => |n| size = n,
            .string => diag.add("line {d}: `size` in [{s}] must be an integer", .{ e.line, t.path }),
        };
        if ((sha == null) != (size == null)) {
            diag.add("line {d}: [{s}] sets only one of sha256 and size; set both or neither", .{ t.line, t.path });
            continue;
        }
        if (sha) |s| if (!valid.isSha256(s)) {
            diag.add("line {d}: sha256 in [{s}] is not 64 lower-case hex digits", .{ t.line, t.path });
            continue;
        };
        plats.items[pi].append(a, .{ .id = id, .token = token, .sha256 = sha, .size = size }) catch return error.Invalid;
    }

    for (pins.items, 0..) |*p, i| {
        std.mem.sort(Platform, plats.items[i].items, {}, lessPlatform);
        p.platforms = plats.items[i].items;
        if (p.platforms.len == 0) {
            diag.add("[{s}] has no [{s}.platform.<id>] table (use one named `any` for a single file)", .{ p.name, p.name });
            continue;
        }
        for (p.platforms) |pf| {
            _ = expand(a, p.url, p.version, pf.token) catch {
                diag.add("[{s}] url template does not expand to a URL for platform {s} (only {{version}} and {{platform}} are placeholders; http(s) with a plain character set)", .{ p.name, pf.id });
                break;
            };
        }
    }
    std.mem.sort(Pin, pins.items, {}, lessPin);
    if (diag.count() != before) return error.Invalid;
    return pins.toOwnedSlice(a) catch error.Invalid;
}

/// `text` with the `version` line of `[name]` set to `new`. Everything else,
/// comments included, is kept byte for byte.
pub fn setVersion(a: std.mem.Allocator, text: []const u8, name: []const u8, new: []const u8) error{ NotFound, OutOfMemory }![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    var in_section = false;
    var done = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |raw| {
        if (!first) try out.append(a, '\n');
        first = false;
        const t = toml.stripComment(raw);
        if (t.len > 0 and t[0] == '[') {
            in_section = t.len == name.len + 2 and std.mem.eql(u8, t[1 .. t.len - 1], name);
        } else if (in_section and !done and std.mem.startsWith(u8, t, "version")) {
            const rest = std.mem.trimLeft(u8, t["version".len..], " \t");
            if (rest.len > 0 and rest[0] == '=') {
                const q1 = std.mem.indexOfScalar(u8, raw, '"');
                const q2 = if (q1) |q| std.mem.indexOfScalarPos(u8, raw, q + 1, '"') else null;
                if (q1 != null and q2 != null) {
                    try out.appendSlice(a, raw[0 .. q1.? + 1]);
                    try out.appendSlice(a, new);
                    try out.appendSlice(a, raw[q2.?..]);
                    done = true;
                    continue;
                }
            }
        }
        try out.appendSlice(a, raw);
    }
    if (!done) return error.NotFound;
    return out.toOwnedSlice(a);
}
