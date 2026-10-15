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
            var dq = obj(a);
            dq.put("name", get(d, "name")) catch return error.Invalid;
            dq.put("pkg", mapId(ids, get(d, "pkg"))) catch return error.Invalid;
            dq.put("dep_kinds", get(d, "dep_kinds")) catch return error.Invalid;
            deps.append(.{ .object = dq }) catch return error.Invalid;
        }
        q.put("deps", .{ .array = deps }) catch return error.Invalid;
        nodes.append(.{ .object = q }) catch return error.Invalid;
    }
    var r = obj(a);
    r.put("nodes", .{ .array = nodes }) catch return error.Invalid;
    out.put("resolve", .{ .object = r }) catch return error.Invalid;
    if (diag.count() != before) return error.Invalid;
    const text_out = std.json.stringifyAlloc(a, Value{ .object = out }, .{ .whitespace = .indent_1 }) catch return error.Invalid;
    return std.mem.concat(a, u8, &.{ text_out, "\n" }) catch error.Invalid;
}
