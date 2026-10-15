//! package-lock.json, lockfileVersion 3: the tarballs it names. npm owns the
//! versions (kpin follows `npm install` / `npm update`); kpin takes each
//! package's resolved URL and its sha512 integrity.

const std = @import("std");
const valid = @import("valid.zig");
const Diag = @import("diag.zig").Diag;

pub const Pkg = struct {
    /// `name@version`
    key: []const u8,
    name: []const u8,
    version: []const u8,
    url: []const u8,
    sri512: []const u8,
};

fn lessPkg(_: void, x: Pkg, y: Pkg) bool {
    return std.mem.lessThan(u8, x.key, y.key);
}

/// The name a `packages` path installs under: what follows the last
/// `node_modules/`. (An alias's real name is in the entry's `name`.)
fn nameFromPath(path: []const u8) ?[]const u8 {
    const marker = "node_modules/";
    const at = std.mem.lastIndexOf(u8, path, marker) orelse return null;
    return path[at + marker.len ..];
}

fn field(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn flag(obj: std.json.ObjectMap, key: []const u8) bool {
    const v = obj.get(key) orelse return false;
    return switch (v) {
        .bool => |b| b,
        else => false,
    };
}

/// The packages of one lockfile, sorted by key, each once. `label` names the
/// file in messages. Refused (each into `diag`): another lockfileVersion, an
/// entry with no integrity or a sha1 one, a non-https URL.
pub fn read(a: std.mem.Allocator, label: []const u8, text: []const u8, diag: *Diag) error{Invalid}![]Pkg {
    const before = diag.count();
    const parsed = std.json.parseFromSlice(std.json.Value, a, text, .{}) catch {
        diag.add("{s}: not valid JSON", .{label});
        return error.Invalid;
    };
    const root = switch (parsed.value) {
        .object => |o| o,
        else => {
            diag.add("{s}: not a JSON object", .{label});
            return error.Invalid;
        },
    };
    const lv = root.get("lockfileVersion") orelse {
        diag.add("{s}: no lockfileVersion; kpin reads lockfileVersion 3", .{label});
        return error.Invalid;
    };
    if (lv != .integer or lv.integer != 3) {
        diag.add("{s}: lockfileVersion is not 3 (run npm >= 9 with --lockfile-version=3)", .{label});
        return error.Invalid;
    }
    const packages = switch (root.get("packages") orelse .null) {
        .object => |o| o,
        else => {
            diag.add("{s}: no `packages` object", .{label});
            return error.Invalid;
        },
    };

    var list = std.ArrayListUnmanaged(Pkg){};
    var it = packages.iterator();
    while (it.next()) |kv| {
        const path = kv.key_ptr.*;
        if (path.len == 0) continue; // the project itself
        const obj = switch (kv.value_ptr.*) {
            .object => |o| o,
            else => {
                diag.add("{s}: packages[{s}] is not an object", .{ label, path });
                continue;
            },
        };
        if (flag(obj, "link")) continue; // a workspace link: no tarball
        if (flag(obj, "inBundle")) continue; // inside its parent's tarball
        const resolved = field(obj, "resolved") orelse {
            diag.add("{s}: packages[{s}] has no `resolved` (a git or file dependency, or a bundled one); kpin cannot pin it", .{ label, path });
            continue;
        };
        const integrity = field(obj, "integrity") orelse {
            diag.add("{s}: packages[{s}] has no `integrity`", .{ label, path });
            continue;
        };
        const name = field(obj, "name") orelse nameFromPath(path) orelse {
            diag.add("{s}: packages[{s}] has no name and the path has no node_modules/", .{ label, path });
            continue;
        };
        const ver = field(obj, "version") orelse {
            diag.add("{s}: packages[{s}] has no version", .{ label, path });
            continue;
        };
        if (!std.mem.startsWith(u8, integrity, "sha512-")) {
            diag.add("{s}: packages[{s}] integrity is not sha512 (sha1 and sha256 integrities are refused)", .{ label, path });
            continue;
        }
        if (!valid.isSri512(integrity)) {
            diag.add("{s}: packages[{s}] integrity is not a sha512 of 64 bytes in base64", .{ label, path });
            continue;
        }
        if (!std.mem.startsWith(u8, resolved, "https://") or !valid.isUrl(resolved)) {
            diag.add("{s}: packages[{s}] resolved is not an https URL kpin accepts", .{ label, path });
            continue;
        }
        if (!valid.isPackageName(name) or !valid.isVersion(ver)) {
            diag.add("{s}: packages[{s}] has a name or version with unsupported characters", .{ label, path });
            continue;
        }
        list.append(a, .{
            .key = std.fmt.allocPrint(a, "{s}@{s}", .{ name, ver }) catch return error.Invalid,
            .name = name,
            .version = ver,
            .url = resolved,
            .sri512 = integrity,
        }) catch return error.Invalid;
    }
    if (diag.count() != before) return error.Invalid;
    return merge(a, &.{list.items}, diag);
}

/// The union of several lists: sorted by key, each key once. The same
/// name@version with two different integrities is an error (two lockfiles
/// disagree about which bytes that version is). Two URLs for one integrity
/// are not; the smaller is kept so the result does not depend on list order.
pub fn merge(a: std.mem.Allocator, lists: []const []const Pkg, diag: *Diag) error{Invalid}![]Pkg {
    const before = diag.count();
    var all = std.ArrayListUnmanaged(Pkg){};
    for (lists) |l| all.appendSlice(a, l) catch return error.Invalid;
    std.mem.sort(Pkg, all.items, {}, lessPkg);
    var out = std.ArrayListUnmanaged(Pkg){};
    for (all.items) |p| {
        if (out.items.len > 0 and std.mem.eql(u8, out.items[out.items.len - 1].key, p.key)) {
            const last = &out.items[out.items.len - 1];
            if (!std.mem.eql(u8, last.sri512, p.sri512)) {
                diag.add("{s} appears with two different integrities ({s} and {s})", .{ p.key, last.sri512, p.sri512 });
            } else if (std.mem.lessThan(u8, p.url, last.url)) {
                last.url = p.url;
            }
            continue;
        }
        out.append(a, p) catch return error.Invalid;
    }
    if (diag.count() != before) return error.Invalid;
    return out.toOwnedSlice(a) catch error.Invalid;
}
