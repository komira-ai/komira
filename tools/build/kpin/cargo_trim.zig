//! `kpin cargo --trim`: `cargo metadata` output cut down to what kpin reads,
//! with the machine's paths made constant. The raw output names the registry
//! cache of whoever ran it (a home directory, an index hash) and carries
//! every description, readme and test target of every crate: not something to
//! commit. The trimmed file is what is committed, and `kpin cargo` reads it
//! (or the raw output) with the same result.

const std = @import("std");
const Diag = @import("diag.zig").Diag;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

fn obj(a: std.mem.Allocator) ObjectMap {
    return ObjectMap.init(a);
}

fn get(o: ObjectMap, key: []const u8) Value {
    return o.get(key) orelse .null;
}

fn getStr(o: ObjectMap, key: []const u8) ?[]const u8 {
    return switch (get(o, key)) {
        .string => |s| s,
        else => null,
    };
}

/// The renamed id of a path package, else the id itself.
fn mapId(ids: std.StringHashMapUnmanaged([]const u8), v: Value) Value {
    return switch (v) {
        .string => |s| .{ .string = ids.get(s) orelse s },
        else => v,
    };
}

fn isLibKind(k: []const u8) bool {
    return std.mem.eql(u8, k, "lib") or std.mem.eql(u8, k, "rlib") or std.mem.eql(u8, k, "proc-macro") or std.mem.eql(u8, k, "custom-build");
}

/// The name a dependency has as a crate: Cargo turns `-` into `_`.
fn sameCrateName(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const nx: u8 = if (x == '-') '_' else x;
        const ny: u8 = if (y == '-') '_' else y;
        if (nx != ny) return false;
    }
    return true;
}

/// Whether one of the features Cargo enabled for `pkg` switches the optional
/// dependency `key` (its name in the manifest, or its rename) on: a `dep:key`
/// entry, or a strong `key/feature` entry. A weak `key?/feature` entry only
/// configures the dependency when something else enabled it.
fn featureEnablesDep(pkg: ObjectMap, node_features: []const Value, key: []const u8) bool {
    const map = switch (get(pkg, "features")) {
        .object => |o| o,
        else => return true, // no feature table to read: keep the edge
    };
    for (node_features) |fv| {
        const f = switch (fv) {
            .string => |s| s,
            else => continue,
        };
        const defs = switch (map.get(f) orelse continue) {
            .array => |x| x.items,
            else => continue,
        };
        for (defs) |dv| {
            const d = switch (dv) {
                .string => |s| s,
                else => continue,
            };
            if (std.mem.startsWith(u8, d, "dep:") and std.mem.eql(u8, d[4..], key)) return true;
            if (std.mem.startsWith(u8, d, key) and d.len > key.len and d[key.len] == '/') return true;
        }
    }
    return false;
}

/// Whether the NORMAL edge from `pkg` (whose enabled features are `node_features`)
/// named `edge_name` to the package `dep_pkg` is one Cargo activated.
///
/// `cargo metadata` lists, among a node's dependencies, an optional dependency
/// that is only named by a weak feature (`alloc = ["ring?/alloc"]`) although no
/// feature switched it on: it is not compiled, `cargo tree` does not show it,
/// and kpin, which follows every normal edge, would build it (and its build
/// script). The manifest's own declarations decide: an edge is kept when some
/// normal declaration of that dependency is not optional, or an enabled feature
/// switches it on. When the metadata carries no declarations or features for
/// the package (a hand-made fixture), or no declaration matches, the edge is
/// kept.
fn normalEdgeActive(pkg: ObjectMap, node_features: []const Value, edge_name: []const u8, dep_pkg: []const u8) bool {
    const decls = switch (get(pkg, "dependencies")) {
        .array => |x| x.items,
        else => return true,
    };
    var matched = false;
    for (decls) |dv| {
        const d = switch (dv) {
            .object => |o| o,
            else => continue,
        };
        if (get(d, "kind") != .null) continue; // build and dev declarations are not this edge
        const name = getStr(d, "name") orelse continue;
        if (!std.mem.eql(u8, name, dep_pkg)) continue;
        const key = getStr(d, "rename") orelse name;
        if (!sameCrateName(key, edge_name)) continue;
        matched = true;
        const optional = switch (get(d, "optional")) {
            .bool => |b| b,
            else => false,
        };
        if (!optional) return true;
        if (featureEnablesDep(pkg, node_features, key)) return true;
    }
    return !matched;
}

/// The trimmed metadata, as JSON text, recording that it was made for
/// `--filter-platform target`. Every package keeps its name, version,
/// id, source and edition, and the library and build-script targets; its
/// paths become `/m/<name>-<version>/...`. The resolved graph keeps each
/// node's id, features and dependencies (name, package, kinds).
pub fn trim(a: std.mem.Allocator, label: []const u8, text: []const u8, target: []const u8, diag: *Diag) error{Invalid}![]u8 {
    const before = diag.count();
    const parsed = std.json.parseFromSlice(Value, a, text, .{}) catch {
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
    var out = obj(a);
    // What the metadata was filtered for: `cargo metadata` does not say, so the
    // person or job that ran it does, once, here; `kpin cargo` checks it.
    out.put("filter_platform", .{ .string = target }) catch return error.Invalid;
    var packages = std.json.Array.init(a);
    const pkgs = switch (get(root, "packages")) {
        .array => |x| x.items,
        else => {
            diag.add("{s}: no `packages` list", .{label});
            return error.Invalid;
        },
    };
    // A path package's id names its directory (`path+file:///home/..`):
    // renamed, consistently, everywhere an id is used.
    var ids = std.StringHashMapUnmanaged([]const u8){};
    for (pkgs) |pv| {
        const p = switch (pv) {
            .object => |o| o,
            else => continue,
        };
        const id = getStr(p, "id") orelse continue;
        if (get(p, "source") != .null) continue;
        const name = getStr(p, "name") orelse "";
        const version = getStr(p, "version") orelse "";
        ids.put(a, id, std.fmt.allocPrint(a, "path+file:///m/{s}-{s}#{s}@{s}", .{ name, version, name, version }) catch return error.Invalid) catch return error.Invalid;
    }
    for (pkgs) |pv| {
        const p = switch (pv) {
            .object => |o| o,
            else => continue,
        };
        const name = getStr(p, "name") orelse "";
        const version = getStr(p, "version") orelse "";
        const manifest = getStr(p, "manifest_path") orelse "";
        const dir = std.fs.path.dirname(manifest) orelse "";
        const base = std.fmt.allocPrint(a, "/m/{s}-{s}", .{ name, version }) catch return error.Invalid;
        var q = obj(a);
        for ([_][]const u8{ "name", "version", "source", "edition" }) |k| q.put(k, get(p, k)) catch return error.Invalid;
        q.put("id", mapId(ids, get(p, "id"))) catch return error.Invalid;
        q.put("manifest_path", .{ .string = std.fmt.allocPrint(a, "{s}/Cargo.toml", .{base}) catch return error.Invalid }) catch return error.Invalid;
        var targets = std.json.Array.init(a);
        const tv = switch (get(p, "targets")) {
            .array => |x| x.items,
            else => &[_]Value{},
        };
        for (tv) |tgt| {
            const to = switch (tgt) {
                .object => |o| o,
                else => continue,
            };
            const kinds = switch (get(to, "kind")) {
                .array => |x| x.items,
                else => continue,
            };
            var keep = false;
            for (kinds) |kv| switch (kv) {
                .string => |s| if (isLibKind(s)) {
                    keep = true;
                },
                else => {},
            };
            if (!keep) continue;
            const sp = getStr(to, "src_path") orelse "";
            const prefix = std.fmt.allocPrint(a, "{s}/", .{dir}) catch return error.Invalid;
            if (!std.mem.startsWith(u8, sp, prefix)) {
                diag.add("{s}: {s} {s}: a target's src_path is not under its manifest directory", .{ label, name, version });
                continue;
            }
            var t = obj(a);
            t.put("name", get(to, "name")) catch return error.Invalid;
            t.put("kind", get(to, "kind")) catch return error.Invalid;
            t.put("src_path", .{ .string = std.fmt.allocPrint(a, "{s}/{s}", .{ base, sp[prefix.len..] }) catch return error.Invalid }) catch return error.Invalid;
            targets.append(.{ .object = t }) catch return error.Invalid;
        }
        q.put("targets", .{ .array = targets }) catch return error.Invalid;
        packages.append(.{ .object = q }) catch return error.Invalid;
    }
    out.put("packages", .{ .array = packages }) catch return error.Invalid;
    var members = std.json.Array.init(a);
    for (switch (get(root, "workspace_members")) {
        .array => |x| x.items,
        else => &[_]Value{},
    }) |m| members.append(mapId(ids, m)) catch return error.Invalid;
    out.put("workspace_members", .{ .array = members }) catch return error.Invalid;

    const resolve = switch (get(root, "resolve")) {
        .object => |o| o,
        else => {
            diag.add("{s}: no `resolve` (it was made with --no-deps): kpin needs the resolved graph", .{label});
            return error.Invalid;
        },
    };
    // The raw packages by id, to read each manifest's declarations and features.
    var raw_pkgs = std.StringHashMapUnmanaged(ObjectMap){};
    for (pkgs) |pv| {
        const p = switch (pv) {
            .object => |o| o,
            else => continue,
        };
        const id = getStr(p, "id") orelse continue;
        raw_pkgs.put(a, id, p) catch return error.Invalid;
    }
    var nodes = std.json.Array.init(a);
    const nv = switch (get(resolve, "nodes")) {
        .array => |x| x.items,
        else => &[_]Value{},
    };
    for (nv) |n| {
        const no = switch (n) {
            .object => |o| o,
            else => continue,
        };
        var q = obj(a);
        q.put("id", mapId(ids, get(no, "id"))) catch return error.Invalid;
        q.put("features", get(no, "features")) catch return error.Invalid;
        var deps = std.json.Array.init(a);
        for (switch (get(no, "deps")) {
            .array => |x| x.items,
            else => &[_]Value{},
        }) |dv| {
            const d = switch (dv) {
                .object => |o| o,
                else => continue,
            };
            // Only the edges Cargo activated: see normalEdgeActive.
            var kinds = std.json.Array.init(a);
            for (switch (get(d, "dep_kinds")) {
                .array => |x| x.items,
                else => &[_]Value{},
            }) |kv| {
                const ko = switch (kv) {
                    .object => |o| o,
                    else => {
                        kinds.append(kv) catch return error.Invalid;
                        continue;
                    },
                };
                if (get(ko, "kind") == .null) {
                    const from = getStr(no, "id") orelse "";
                    const dep_id = getStr(d, "pkg") orelse "";
                    if (raw_pkgs.get(from)) |from_pkg| if (raw_pkgs.get(dep_id)) |dep_pkg| {
                        const node_features = switch (get(no, "features")) {
                            .array => |x| x.items,
                            else => &[_]Value{},
                        };
                        if (!normalEdgeActive(from_pkg, node_features, getStr(d, "name") orelse "", getStr(dep_pkg, "name") orelse "")) continue;
                    };
                }
                kinds.append(kv) catch return error.Invalid;
            }
            if (kinds.items.len == 0) continue;
            var dq = obj(a);
            dq.put("name", get(d, "name")) catch return error.Invalid;
            dq.put("pkg", mapId(ids, get(d, "pkg"))) catch return error.Invalid;
            dq.put("dep_kinds", .{ .array = kinds }) catch return error.Invalid;
            deps.append(.{ .object = dq }) catch return error.Invalid;
        }
        q.put("deps", .{ .array = deps }) catch return error.Invalid;
        nodes.append(.{ .object = q }) catch return error.Invalid;
    }
    var r = obj(a);
    r.put("nodes", .{ .array = nodes }) catch return error.Invalid;
    out.put("resolve", .{ .object = r }) catch return error.Invalid;
    if (diag.count() != before) return error.Invalid;
    const text_out = std.json.Stringify.valueAlloc(a, Value{ .object = out }, .{ .whitespace = .indent_1 }) catch return error.Invalid;
    return std.mem.concat(a, u8, &.{ text_out, "\n" }) catch error.Invalid;
}
