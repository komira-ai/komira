//! `kpin cargo`: Cargo.lock, `cargo metadata` and an overrides table in, a
//! `.bzl` of `crates_io_library` targets out.
//!
//! Cargo owns the resolution: it runs, with a network, outside the build, and
//! writes Cargo.lock (the sha256 of every `.crate`) and the `cargo metadata`
//! JSON (the packages, the resolved dependency graph and, per package, the
//! features Cargo enabled). kpin reads those and the overrides, and never
//! resolves anything. The output is deterministic, so `--check` can compare
//! it with the committed file byte for byte.
//!
//! What no tool can know is what a crate's build script decides for the
//! pinned compiler. A crate with a build script and no entry in the overrides
//! is an error that names it; an entry for a crate that is not linked, or has
//! no build script (or whose class does not fit what it carries), is an error
//! too. README.md, "Cargo".

const std = @import("std");
const valid = @import("valid.zig");
const lockfile = @import("cargo_lock.zig");
const Diag = @import("diag.zig").Diag;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

/// The only registry kpin pins crates from.
pub const crates_io = "registry+https://github.com/rust-lang/crates.io-index";

pub const Inputs = struct {
    /// Names of the inputs, for messages.
    lock_label: []const u8 = "Cargo.lock",
    metadata_label: []const u8 = "metadata.json",
    overrides_label: []const u8 = "overrides.json",
    sizes_label: []const u8 = "sizes.txt",
    lock: []const u8,
    metadata: []const u8,
    overrides: []const u8,
    /// One line per crate: `<name>-<version>.crate <bytes>`.
    sizes: []const u8,
    /// The pinned compiler the overrides must have been derived for.
    rustc: []const u8,
};

// ---- the overrides -----------------------------------------------------------

const Sub = struct { file: []const u8, from: []const u8, to: []const u8, count: ?i64 = null };
const Add = struct { file: []const u8, content: []const u8 };
const KV = struct { key: []const u8, value: []const u8 };

const Override = struct {
    class: u8 = 0,
    why: []const u8 = "",
    cfgs: []const []const u8 = &.{},
    env: []const KV = &.{},
    has_patch: bool = false,
    copy: []const []const u8 = &.{},
    subs: []const Sub = &.{},
    adds: []const Add = &.{},
    natives: []const []const u8 = &.{},
    used: bool = false,
};

const no_values: []const Value = &.{};

fn str(v: Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn objOf(v: Value) ?ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

fn arrOf(v: Value) ?[]const Value {
    return switch (v) {
        .array => |x| x.items,
        else => null,
    };
}

fn strField(o: ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return str(v);
}

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

/// `key`'s array of strings; an error into `diag` (naming `where`) if it is
/// anything else.
fn strList(a: std.mem.Allocator, o: ObjectMap, key: []const u8, where: []const u8, diag: *Diag) []const []const u8 {
    const v = o.get(key) orelse return &.{};
    const items = arrOf(v) orelse {
        diag.add("{s}: `{s}` is not a list", .{ where, key });
        return &.{};
    };
    var out = std.ArrayListUnmanaged([]const u8){};
    for (items) |x| {
        const s = str(x) orelse {
            diag.add("{s}: `{s}` holds a non-string", .{ where, key });
            continue;
        };
        out.append(a, s) catch return &.{};
    }
    return out.items;
}

fn knownKeys(o: ObjectMap, comptime known: []const []const u8, where: []const u8, diag: *Diag) void {
    var it = o.iterator();
    outer: while (it.next()) |kv| {
        inline for (known) |k| {
            if (std.mem.eql(u8, kv.key_ptr.*, k)) continue :outer;
        }
        diag.add("{s}: unknown key `{s}` (a typo is not ignored)", .{ where, kv.key_ptr.* });
    }
}

const ParsedOverrides = struct {
    rustc: []const u8,
    map: std.StringHashMapUnmanaged(Override),
};

fn parseOverrides(a: std.mem.Allocator, label: []const u8, text: []const u8, diag: *Diag) error{Invalid}!ParsedOverrides {
    const before = diag.count();
    const parsed = std.json.parseFromSlice(Value, a, text, .{}) catch {
        diag.add("{s}: not valid JSON", .{label});
        return error.Invalid;
    };
    const root = objOf(parsed.value) orelse {
        diag.add("{s}: not a JSON object", .{label});
        return error.Invalid;
    };
    knownKeys(root, &.{ "rustc", "crates" }, label, diag);
    const rustc = strField(root, "rustc") orelse {
        diag.add("{s}: no `rustc`: the compiler version the cfgs and generated files were derived for", .{label});
        return error.Invalid;
    };
    var map = std.StringHashMapUnmanaged(Override){};
    const crates = objOf(root.get("crates") orelse .null) orelse {
        diag.add("{s}: no `crates` object", .{label});
        return error.Invalid;
    };
    var it = crates.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        const where = std.fmt.allocPrint(a, "{s}: \"{s}\"", .{ label, key }) catch return error.Invalid;
        const o = objOf(kv.value_ptr.*) orelse {
            diag.add("{s} is not an object", .{where});
            continue;
        };
        knownKeys(o, &.{ "class", "why", "cfgs", "env", "patch", "native_deps" }, where, diag);
        var ov = Override{};
        const cls = strField(o, "class") orelse "";
        if (cls.len != 1 or std.mem.indexOfScalar(u8, "abcm", cls[0]) == null) {
            diag.add("{s}: `class` is a, b, c or m", .{where});
        } else ov.class = cls[0];
        ov.why = strField(o, "why") orelse "";
        if (ov.why.len == 0) diag.add("{s}: no `why`: say what the build script decides, or why the crate needs the entry", .{where});
        ov.cfgs = strList(a, o, "cfgs", where, diag);
        ov.natives = strList(a, o, "native_deps", where, diag);
        if (o.get("env")) |ev| {
            if (objOf(ev)) |eo| {
                var list = std.ArrayListUnmanaged(KV){};
                var ei = eo.iterator();
                while (ei.next()) |e| {
                    const v = str(e.value_ptr.*) orelse {
                        diag.add("{s}: env `{s}` is not a string", .{ where, e.key_ptr.* });
                        continue;
                    };
                    list.append(a, .{ .key = e.key_ptr.*, .value = v }) catch return error.Invalid;
                }
                std.mem.sort(KV, list.items, {}, struct {
                    fn less(_: void, x: KV, y: KV) bool {
                        return std.mem.lessThan(u8, x.key, y.key);
                    }
                }.less);
                ov.env = list.items;
            } else diag.add("{s}: `env` is not an object", .{where});
        }
        if (o.get("patch")) |pv| {
            ov.has_patch = true;
            if (objOf(pv)) |po| {
                knownKeys(po, &.{ "copy", "sub", "add" }, where, diag);
                ov.copy = strList(a, po, "copy", where, diag);
                if (po.get("sub")) |sv| {
                    var subs = std.ArrayListUnmanaged(Sub){};
                    for (arrOf(sv) orelse no_values) |x| {
                        const so = objOf(x) orelse {
                            diag.add("{s}: a patch.sub entry is not an object", .{where});
                            continue;
                        };
                        knownKeys(so, &.{ "file", "from", "to", "count" }, where, diag);
                        const f = strField(so, "file");
                        const from = strField(so, "from");
                        const to = strField(so, "to");
                        if (f == null or from == null or to == null) {
                            diag.add("{s}: every patch.sub entry needs string `file`, `from` and `to`", .{where});
                            continue;
                        }
                        var count: ?i64 = null;
                        if (so.get("count")) |cv| switch (cv) {
                            .integer => |n| count = n,
                            else => diag.add("{s}: patch.sub `count` is not an integer", .{where}),
                        };
                        subs.append(a, .{ .file = f.?, .from = from.?, .to = to.?, .count = count }) catch return error.Invalid;
                    }
                    ov.subs = subs.items;
                }
                if (po.get("add")) |av| {
                    var adds = std.ArrayListUnmanaged(Add){};
                    for (arrOf(av) orelse no_values) |x| {
                        const ao = objOf(x) orelse {
                            diag.add("{s}: a patch.add entry is not an object", .{where});
                            continue;
                        };
                        knownKeys(ao, &.{ "file", "content" }, where, diag);
                        const f = strField(ao, "file");
                        const c = strField(ao, "content");
                        if (f == null or c == null) {
                            diag.add("{s}: every patch.add entry needs string `file` and `content`", .{where});
                            continue;
                        }
                        adds.append(a, .{ .file = f.?, .content = c.? }) catch return error.Invalid;
                    }
                    ov.adds = adds.items;
                }
                for (ov.copy) |p| if (!valid.isRelPath(p)) diag.add("{s}: patch.copy `{s}` is not a relative path inside the crate", .{ where, p });
                for (ov.subs) |s| if (!valid.isRelPath(s.file)) diag.add("{s}: patch.sub file `{s}` is not a relative path inside the crate", .{ where, s.file });
                for (ov.adds) |s| if (!valid.isRelPath(s.file)) diag.add("{s}: patch.add file `{s}` is not a relative path inside the crate", .{ where, s.file });
            } else diag.add("{s}: `patch` is not an object", .{where});
        }
        for (ov.natives) |n| if (!validLabel(n)) diag.add("{s}: native_deps `{s}` is not a target label", .{ where, n });
        for (ov.cfgs) |c| if (c.len == 0 or std.mem.indexOfAny(u8, c, " \t\n") != null) diag.add("{s}: cfg `{s}` is empty or holds white space", .{ where, c });
        // A class says what the entry carries; one that carries more is mislabelled.
        switch (ov.class) {
            'a' => if (ov.has_patch or ov.natives.len > 0) diag.add("{s}: class a only emits cfgs and env; this entry patches or links native code (class b or c)", .{where}),
            'b' => if (!ov.has_patch) diag.add("{s}: class b generates files: it needs a `patch`", .{where}),
            'c' => if (ov.natives.len == 0) diag.add("{s}: class c replaces native code with a komira target: it needs `native_deps`", .{where}),
            else => {},
        }
        map.put(a, key, ov) catch return error.Invalid;
    }
    if (diag.count() != before) return error.Invalid;
    return .{ .rustc = rustc, .map = map };
}

fn validLabel(s: []const u8) bool {
    if (s.len < 1 or s.len > 256) return false;
    for (s) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or switch (c) {
            '-', '_', '.', '/', ':', '+', '@', '[', ']' => true,
            else => false,
        };
        if (!ok) return false;
    }
    return true;
}

// ---- the packages ------------------------------------------------------------

const Edge = struct { alias: []const u8, id: []const u8 };

const Pkg = struct {
    id: []const u8,
    name: []const u8,
    version: []const u8,
    edition: []const u8 = "2021",
    source: []const u8 = "",
    manifest_dir: []const u8 = "",
    targets: []const Value = &.{},
    node: ?ObjectMap = null,
    workspace: bool = false,
    reached: bool = false,
    // Filled for the packages that are emitted.
    lib_name: []const u8 = "",
    root: []const u8 = "src/lib.rs",
    proc_macro: bool = false,
    has_build: bool = false,
    features: []const []const u8 = &.{},
    checksum: []const u8 = "",
    size: u64 = 0,
    target: []const u8 = "",
    dup: bool = false,
    edges: []const Edge = &.{},
};

fn lessPkg(_: void, x: *Pkg, y: *Pkg) bool {
    const o = std.mem.order(u8, x.name, y.name);
    if (o != .eq) return o == .lt;
    return std.mem.order(u8, x.version, y.version) == .lt;
}

fn parseSizes(a: std.mem.Allocator, label: []const u8, text: []const u8, diag: *Diag) std.StringHashMapUnmanaged(u64) {
    var m = std.StringHashMapUnmanaged(u64){};
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        n += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var f = std.mem.tokenizeAny(u8, line, " \t");
        const name = f.next().?;
        const size_text = f.next() orelse {
            diag.add("{s}:{d}: expected `<name>-<version>.crate <bytes>`", .{ label, n });
            continue;
        };
        const size = std.fmt.parseInt(u64, size_text, 10) catch {
            diag.add("{s}:{d}: `{s}` is not a size in bytes", .{ label, n, size_text });
            continue;
        };
        m.put(a, name, size) catch {};
    }
    return m;
}

/// Starlark string literal. Registry-derived strings passed `valid.zig` and
/// need no escape; the overrides (reviewed by a human) may hold anything.
fn q(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        '\r' => try w.writeAll("\\r"),
        0...8, 11, 12, 14...31, 127 => try w.print("\\x{x:0>2}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn strListLine(w: anytype, name: []const u8, items: []const []const u8) !void {
    if (items.len == 0) return;
    try w.print("        {s} = [", .{name});
    if (items.len <= 3) {
        for (items, 0..) |s, i| {
            if (i > 0) try w.writeAll(", ");
            try q(w, s);
        }
        try w.writeAll("],\n");
    } else {
        try w.writeAll("\n");
        for (items) |s| {
            try w.writeAll("            ");
            try q(w, s);
            try w.writeAll(",\n");
        }
        try w.writeAll("        ],\n");
    }
}

/// The generated `.bzl`, or `error.Invalid` with every problem in `diag`.
pub fn generate(a: std.mem.Allocator, in: Inputs, diag: *Diag) error{Invalid}![]u8 {
    const before = diag.count();

    const lock = lockfile.parse(a, in.lock_label, in.lock, diag) catch return error.Invalid;
    const sizes = parseSizes(a, in.sizes_label, in.sizes, diag);
    const ovs = parseOverrides(a, in.overrides_label, in.overrides, diag) catch return error.Invalid;
    if (!std.mem.eql(u8, ovs.rustc, in.rustc)) {
        diag.add("{s}: derived for rustc {s}, but the pinned compiler is {s}: re-derive each entry for the new compiler (cfgs and generated files are per version), then set `rustc`", .{ in.overrides_label, ovs.rustc, in.rustc });
    }

    const parsed = std.json.parseFromSlice(Value, a, in.metadata, .{}) catch {
        diag.add("{s}: not valid JSON", .{in.metadata_label});
        return error.Invalid;
    };
    const root = objOf(parsed.value) orelse {
        diag.add("{s}: not a JSON object", .{in.metadata_label});
        return error.Invalid;
    };
    const pkg_values = arrOf(root.get("packages") orelse .null) orelse {
        diag.add("{s}: no `packages` list", .{in.metadata_label});
        return error.Invalid;
    };
    const resolve = objOf(root.get("resolve") orelse .null) orelse {
        diag.add("{s}: no `resolve` (it was made with --no-deps): kpin needs the resolved graph", .{in.metadata_label});
        return error.Invalid;
    };

    // Packages by id.
    var by_id = std.StringHashMapUnmanaged(*Pkg){};
    for (pkg_values) |pv| {
        const o = objOf(pv) orelse continue;
        const id = strField(o, "id") orelse {
            diag.add("{s}: a package with no id", .{in.metadata_label});
            continue;
        };
        const name = strField(o, "name") orelse "";
        const version = strField(o, "version") orelse "";
        const p = a.create(Pkg) catch return error.Invalid;
        p.* = .{ .id = id, .name = name, .version = version };
        if (o.get("source")) |sv| p.source = str(sv) orelse "";
        if (strField(o, "edition")) |e| p.edition = e;
        const mp = strField(o, "manifest_path") orelse "";
        p.manifest_dir = std.fs.path.dirname(mp) orelse "";
        if (o.get("targets")) |tv| p.targets = arrOf(tv) orelse &.{};
        by_id.put(a, id, p) catch return error.Invalid;
    }
    // Nodes of the resolved graph.
    for (arrOf(resolve.get("nodes") orelse .null) orelse no_values) |nv| {
        const no = objOf(nv) orelse continue;
        const id = strField(no, "id") orelse continue;
        if (by_id.get(id)) |p| p.node = no;
    }
    var queue = std.ArrayListUnmanaged(*Pkg){};
    for (arrOf(resolve.get("workspace_members") orelse root.get("workspace_members") orelse .null) orelse no_values) |wv| {
        const id = str(wv) orelse continue;
        if (by_id.get(id)) |p| {
            p.workspace = true;
            p.reached = true;
            queue.append(a, p) catch return error.Invalid;
        }
    }
    if (queue.items.len == 0) {
        diag.add("{s}: no workspace members", .{in.metadata_label});
        return error.Invalid;
    }

    // The crates linked into a binary: normal edges only, from the members.
    // Build- and dev-dependencies are not (no build script runs here).
    var linked = std.ArrayListUnmanaged(*Pkg){};
    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const p = queue.items[qi];
        const node = p.node orelse {
            diag.add("{s}: {s} {s} has no node in the resolved graph", .{ in.metadata_label, p.name, p.version });
            continue;
        };
        var edges = std.ArrayListUnmanaged(Edge){};
        for (arrOf(node.get("deps") orelse .null) orelse no_values) |dv| {
            const d = objOf(dv) orelse continue;
            var normal = false;
            for (arrOf(d.get("dep_kinds") orelse .null) orelse no_values) |kv| {
                const ko = objOf(kv) orelse continue;
                if ((ko.get("kind") orelse .null) == .null) normal = true;
            }
            if (!normal) continue;
            const id = strField(d, "pkg") orelse continue;
            const alias = strField(d, "name") orelse "";
            const t = by_id.get(id) orelse {
                diag.add("{s}: {s} {s} depends on an id that is not a package: {s}", .{ in.metadata_label, p.name, p.version, id });
                continue;
            };
            edges.append(a, .{ .alias = alias, .id = id }) catch return error.Invalid;
            if (t.workspace) continue;
            if (!t.reached) {
                t.reached = true;
                queue.append(a, t) catch return error.Invalid;
                linked.append(a, t) catch return error.Invalid;
            }
        }
        p.edges = edges.items;
    }

    var overrides_used: usize = 0;
    for (linked.items) |p| {
        const where = std.fmt.allocPrint(a, "{s} {s}", .{ p.name, p.version }) catch return error.Invalid;
        if (!valid.isCrateName(p.name) or !valid.isVersion(p.version) or !valid.isEdition(p.edition)) {
            diag.add("{s}: a name, version or edition with unsupported characters", .{where});
            continue;
        }
        if (p.source.len == 0) {
            diag.add("{s} is a path dependency, not a registry crate: kpin pins registry crates only", .{where});
            continue;
        }
        if (!std.mem.eql(u8, p.source, crates_io)) {
            diag.add("{s} comes from `{s}`: kpin pins crates.io crates only (a git or another registry is not pinned by a sha256)", .{ where, p.source });
            continue;
        }
        // The checksum Cargo.lock holds for exactly this package.
        for (lock) |e| {
            if (std.mem.eql(u8, e.name, p.name) and std.mem.eql(u8, e.version, p.version) and std.mem.eql(u8, e.source, p.source)) p.checksum = e.checksum;
        }
        if (p.checksum.len == 0) {
            diag.add("{s} has no checksum in {s}", .{ where, in.lock_label });
        } else if (!valid.isSha256(p.checksum)) {
            diag.add("{s}: the checksum in {s} is not a lower-case sha256 hex string: `{s}`", .{ where, in.lock_label, p.checksum });
        }
        const crate_file = std.fmt.allocPrint(a, "{s}-{s}.crate", .{ p.name, p.version }) catch return error.Invalid;
        if (sizes.get(crate_file)) |sz| p.size = sz else diag.add("{s}: no size for {s} in {s}", .{ where, crate_file, in.sizes_label });

        // Targets: the library, and whether a build script exists.
        for (p.targets) |tv| {
            const to = objOf(tv) orelse continue;
            for (arrOf(to.get("kind") orelse .null) orelse no_values) |kv| {
                const kind = str(kv) orelse continue;
                if (std.mem.eql(u8, kind, "custom-build")) p.has_build = true;
                if (std.mem.eql(u8, kind, "lib") or std.mem.eql(u8, kind, "rlib") or std.mem.eql(u8, kind, "proc-macro")) {
                    p.lib_name = strField(to, "name") orelse "";
                    p.proc_macro = std.mem.eql(u8, kind, "proc-macro");
                    const sp = strField(to, "src_path") orelse "";
                    const prefix = std.fmt.allocPrint(a, "{s}/", .{p.manifest_dir}) catch return error.Invalid;
                    if (std.mem.startsWith(u8, sp, prefix)) {
                        p.root = sp[prefix.len..];
                    } else diag.add("{s}: the library's src_path is not under its manifest directory", .{where});
                }
            }
        }
        if (p.lib_name.len == 0) {
            diag.add("{s} is linked but has no library target", .{where});
            continue;
        }
        if (!valid.isCrateName(p.lib_name) or !valid.isRelPath(p.root)) diag.add("{s}: a library name or root with unsupported characters", .{where});

        // Features Cargo resolved.
        var feats = std.ArrayListUnmanaged([]const u8){};
        const node = p.node orelse continue;
        for (arrOf(node.get("features") orelse .null) orelse no_values) |fv| {
            const f = str(fv) orelse continue;
            if (!valid.isFeatureName(f)) {
                diag.add("{s}: feature `{s}` has unsupported characters", .{ where, f });
                continue;
            }
            feats.append(a, f) catch return error.Invalid;
        }
        std.mem.sort([]const u8, feats.items, {}, lessStr);
        p.features = feats.items;

        // Build scripts: never skipped silently.
        const ov = ovs.map.getPtr(where);
        if (ov) |o| {
            o.used = true;
            overrides_used += 1;
        }
        if (p.has_build and ov == null) {
            diag.add("{s} has a build script and no entry in {s}: say what the script decides for rustc {s} (cfgs, env, generated files or a native target), as class a, b or c", .{ where, in.overrides_label, in.rustc });
        } else if (!p.has_build and ov != null and ov.?.class != 'm') {
            diag.add("{s} has no build script, and its entry in {s} is class {c}: classes a, b and c are for a build script's outcome (class m is a crate with no script whose source needs an env or an edit)", .{ where, in.overrides_label, ov.?.class });
        } else if (p.has_build and ov != null and ov.?.class == 'm') {
            diag.add("{s} has a build script: its entry in {s} is class a, b or c, not m", .{ where, in.overrides_label });
        }
    }
    // An entry nothing uses is stale: a crate left the graph or moved on.
    {
        var names = std.ArrayListUnmanaged([]const u8){};
        var it = ovs.map.iterator();
        while (it.next()) |kv| if (!kv.value_ptr.used) names.append(a, kv.key_ptr.*) catch return error.Invalid;
        std.mem.sort([]const u8, names.items, {}, lessStr);
        for (names.items) |n| diag.add("{s}: \"{s}\" matches no linked crate (a crate that moved to another version, or is no longer linked): remove or update the entry", .{ in.overrides_label, n });
    }
    if (diag.count() != before) return error.Invalid;

    std.mem.sort(*Pkg, linked.items, {}, lessPkg);
    // Target names: the crate name, with the version when two versions are linked.
    for (linked.items) |p| {
        for (linked.items) |o| {
            if (o != p and std.mem.eql(u8, o.name, p.name)) p.dup = true;
        }
        p.target = if (p.dup) std.fmt.allocPrint(a, "{s}-{s}", .{ p.name, p.version }) catch return error.Invalid else p.name;
    }

    var out = std.ArrayListUnmanaged(u8){};
    const w = out.writer(a);
    w.print(
        \\# Generated by `kpin cargo` (tools/build/kpin/README.md, "Cargo") from Cargo.lock, `cargo metadata`
        \\# and the overrides, for rustc {s}. Do not edit it: change the Cargo manifests or the overrides and regenerate.
        \\
        \\load("@komira//tools/build/rust:defs.bzl", "cargo_pkg_env", "crates_io_library")
        \\
        \\def crates():
        \\
    , .{in.rustc}) catch return error.Invalid;
    for (linked.items) |p| render(a, w, p, by_id, ovs.map.get(std.fmt.allocPrint(a, "{s} {s}", .{ p.name, p.version }) catch return error.Invalid)) catch return error.Invalid;
    // One blank line between crates, none at the end.
    while (out.items.len > 1 and out.items[out.items.len - 1] == '\n' and out.items[out.items.len - 2] == '\n') _ = out.pop();
    return out.toOwnedSlice(a) catch error.Invalid;
}

fn render(a: std.mem.Allocator, w: anytype, p: *Pkg, by_id: std.StringHashMapUnmanaged(*Pkg), ov: ?Override) !void {
    if (ov) |o| {
        try w.print("    # {s} ({c}): {s}\n", .{ if (o.class == 'm') "no build script, edited by hand" else "build script", o.class, o.why });
    }
    try w.writeAll("    crates_io_library(\n");
    try w.print("        name = \"{s}\",\n        version = \"{s}\",\n        sha256 = \"{s}\",\n        size = {d},\n", .{ p.target, p.version, p.checksum, p.size });
    if (!std.mem.eql(u8, p.target, p.name)) try w.print("        crate = \"{s}\",\n", .{p.name});
    const def_name = try a.dupe(u8, p.name);
    std.mem.replaceScalar(u8, def_name, '-', '_');
    if (!std.mem.eql(u8, def_name, p.lib_name)) try w.print("        crate_name = \"{s}\",\n", .{p.lib_name});
    if (!std.mem.eql(u8, p.root, "src/lib.rs")) try w.print("        crate_root = \"{s}\",\n", .{p.root});
    if (!std.mem.eql(u8, p.edition, "2021")) try w.print("        edition = \"{s}\",\n", .{p.edition});
    try strListLine(w, "features", p.features);
    if (ov) |o| {
        try strListLine(w, "cfgs", o.cfgs);
    }
    // Cargo's variables for env!(), and the crate's own.
    try w.print("        env = cargo_pkg_env(\"{s}\", \"{s}\", \"{s}\")", .{ p.name, p.version, p.lib_name });
    if (ov) |o| if (o.env.len > 0) {
        try w.writeAll(" | {\n");
        for (o.env) |kv| {
            try w.writeAll("            ");
            try q(w, kv.key);
            try w.writeAll(": ");
            try q(w, kv.value);
            try w.writeAll(",\n");
        }
        try w.writeAll("        }");
    };
    try w.writeAll(",\n");
    if (p.proc_macro) try w.writeAll("        proc_macro = True,\n        proc_macro_extern = True,\n");

    // Dependencies: the edges that are linked; the name a crate gives one
    // that is not the dependency's library name is a rename.
    var deps = std.ArrayListUnmanaged([]const u8){};
    var renamed = std.ArrayListUnmanaged([2][]const u8){};
    for (p.edges) |e| {
        const d = by_id.get(e.id).?;
        if (d.workspace) continue;
        const label = try std.fmt.allocPrint(a, ":{s}", .{d.target});
        if (std.mem.eql(u8, e.alias, d.lib_name)) {
            try deps.append(a, label);
        } else {
            try renamed.append(a, .{ e.alias, label });
        }
    }
    std.mem.sort([]const u8, deps.items, {}, lessStr);
    var uniq = std.ArrayListUnmanaged([]const u8){};
    for (deps.items) |d| {
        if (uniq.items.len == 0 or !std.mem.eql(u8, uniq.items[uniq.items.len - 1], d)) try uniq.append(a, d);
    }
    try strListLine(w, "deps", uniq.items);
    if (renamed.items.len > 0) {
        std.mem.sort([2][]const u8, renamed.items, {}, struct {
            fn less(_: void, x: [2][]const u8, y: [2][]const u8) bool {
                const c = std.mem.order(u8, x[0], y[0]);
                if (c != .eq) return c == .lt;
                return std.mem.order(u8, x[1], y[1]) == .lt;
            }
        }.less);
        try w.writeAll("        renamed_deps = {\n");
        var last: [2][]const u8 = .{ "", "" };
        for (renamed.items) |r| {
            if (std.mem.eql(u8, r[0], last[0]) and std.mem.eql(u8, r[1], last[1])) continue;
            last = r;
            try w.writeAll("            ");
            try q(w, r[0]);
            try w.writeAll(": ");
            try q(w, r[1]);
            try w.writeAll(",\n");
        }
        try w.writeAll("        },\n");
    }
    if (ov) |o| {
        try strListLine(w, "native_deps", o.natives);
        if (o.has_patch) {
            try w.writeAll("        patch = {\n");
            if (o.copy.len > 0) {
                try w.writeAll("            \"copy\": [");
                for (o.copy, 0..) |x, i| {
                    if (i > 0) try w.writeAll(", ");
                    try q(w, x);
                }
                try w.writeAll("],\n");
            }
            if (o.subs.len > 0) {
                try w.writeAll("            \"sub\": [\n");
                for (o.subs) |s| {
                    try w.writeAll("                {\"file\": ");
                    try q(w, s.file);
                    try w.writeAll(", \"from\": ");
                    try q(w, s.from);
                    try w.writeAll(", \"to\": ");
                    try q(w, s.to);
                    if (s.count) |c| try w.print(", \"count\": {d}", .{c});
                    try w.writeAll("},\n");
                }
                try w.writeAll("            ],\n");
            }
            if (o.adds.len > 0) {
                try w.writeAll("            \"add\": [\n");
                for (o.adds) |s| {
                    try w.writeAll("                {\"file\": ");
                    try q(w, s.file);
                    try w.writeAll(", \"content\": ");
                    try q(w, s.content);
                    try w.writeAll("},\n");
                }
                try w.writeAll("            ],\n");
            }
            try w.writeAll("        },\n");
        }
    }
    try w.writeAll("    )\n\n");
}
