//! An image's filesystem: its layers applied in order, as a container
//! runtime applies them (OCI image spec, "Applying changesets").
//!
//! A later entry replaces an earlier one at the same path; an entry that is
//! not a directory also removes what was below that path. Whiteouts apply to
//! the layers below theirs, never to entries of their own layer:
//! `<dir>/.wh.<name>` removes `<dir>/<name>` and everything under it, and
//! `<dir>/.wh..wh..opq` (an opaque directory) removes every child of `<dir>`.

const std = @import("std");
const C = @import("common.zig");
const tar = @import("tar.zig");
const Fail = C.Fail;
const Entry = tar.Entry;

pub const Type = enum {
    file,
    dir,
    symlink,
    other,

    fn letter(self: Type) u8 {
        return switch (self) {
            .file => '-',
            .dir => 'd',
            .symlink => 'l',
            .other => '?',
        };
    }
};

pub const Node = struct {
    ty: Type,
    mode: u32,
    size: u64,
    link: []const u8,
};

const OPAQUE = ".wh..wh..opq";
const WHITEOUT = ".wh.";
pub const MAX_LINKS: usize = 40;

/// `p` relative to /, without empty, `.` and `..` parts (`..` at / stays at /).
pub fn normalize(p: []const u8) []const u8 {
    var parts = C.list([]const u8);
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |c| {
        if (c.len == 0 or C.eql(c, ".")) continue;
        if (C.eql(c, "..")) {
            _ = parts.popOrNull();
            continue;
        }
        C.push([]const u8, &parts, c);
    }
    return C.join(parts.items, "/");
}

fn joinPath(dir: []const u8, name: []const u8) []const u8 {
    if (dir.len == 0) return C.dupe(name);
    return C.fmt("{s}/{s}", .{ dir, name });
}

const Split = struct { dir: []const u8, base: []const u8 };

fn split(p: []const u8) Split {
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| return .{ .dir = p[0..i], .base = p[i + 1 ..] };
    return .{ .dir = "", .base = p };
}

pub const Fs = struct {
    nodes: std.StringHashMap(Node),

    /// An empty filesystem.
    pub fn init() Fs {
        return .{ .nodes = std.StringHashMap(Node).init(C.a()) };
    }

    pub fn get(self: *const Fs, p: []const u8) ?Node {
        return self.nodes.get(p);
    }

    /// Every path strictly under `dir` ("" is /).
    fn removeChildren(self: *Fs, dir: []const u8) void {
        if (dir.len == 0) {
            self.nodes.clearRetainingCapacity();
            return;
        }
        const from = C.fmt("{s}/", .{dir});
        var under = C.list([]const u8);
        var it = self.nodes.keyIterator();
        while (it.next()) |k| {
            if (C.startsWith(k.*, from)) C.push([]const u8, &under, k.*);
        }
        for (under.items) |k| _ = self.nodes.remove(k);
    }

    /// `p` and everything under it.
    fn removeTree(self: *Fs, p: []const u8) void {
        _ = self.nodes.remove(p);
        self.removeChildren(p);
    }

    /// Applies one layer over this filesystem.
    pub fn apply(self: *Fs, entries: []const Entry) Fail!void {
        // Whiteouts first: they hide the layers below, whatever their order
        // in the layer.
        for (entries) |e| {
            const p = normalize(e.path);
            const sp = split(p);
            if (C.eql(sp.base, OPAQUE)) {
                self.removeChildren(sp.dir);
            } else if (C.startsWith(sp.base, WHITEOUT)) {
                const name = sp.base[WHITEOUT.len..];
                if (name.len == 0 or C.eql(name, ".") or C.eql(name, "..")) return C.fail("a whiteout `{s}` names no entry", .{e.path});
                self.removeTree(joinPath(sp.dir, name));
            }
        }
        for (entries) |e| {
            const p = normalize(e.path);
            if (C.startsWith(split(p).base, WHITEOUT)) continue;
            if (p.len == 0) {
                if (e.kind != .dir) return C.fail("the layer's root entry `{s}` is not a directory", .{e.path});
                continue;
            }
            const node: Node = switch (e.kind) {
                .hardlink => blk: {
                    const target = normalize(e.link);
                    const n = self.nodes.get(target) orelse return C.fail("hard link {s} -> {s}: no such entry", .{ p, e.link });
                    if (n.ty == .dir) return C.fail("hard link {s} -> {s}: a directory", .{ p, e.link });
                    break :blk n;
                },
                else => |k| .{
                    .ty = switch (k) {
                        .file => .file,
                        .dir => .dir,
                        .symlink => .symlink,
                        else => .other,
                    },
                    .mode = e.mode,
                    .size = e.size,
                    .link = e.link,
                },
            };
            if (node.ty != .dir) self.removeChildren(p);
            self.nodes.put(p, node) catch C.oom();
        }
    }

    /// The path `p` names once every symbolic link on the way is followed:
    /// a key of `nodes`, or a path that names nothing.
    pub fn resolve(self: *const Fs, p: []const u8) Fail![]const u8 {
        var todo = C.list([]const u8);
        pushReversed(&todo, p);
        var cur: []const u8 = "";
        var links: usize = 0;
        while (todo.popOrNull()) |c| {
            if (c.len == 0 or C.eql(c, ".")) continue;
            if (C.eql(c, "..")) {
                cur = split(cur).dir;
                continue;
            }
            const nxt = joinPath(cur, c);
            const found = self.nodes.get(nxt);
            if (found != null and found.?.ty == .symlink) {
                const n = found.?;
                links += 1;
                if (links > MAX_LINKS) return C.fail("{s}: more than {d} symbolic links", .{ p, MAX_LINKS });
                pushReversed(&todo, n.link);
                if (C.startsWith(n.link, "/")) cur = "";
            } else {
                cur = nxt;
            }
        }
        return cur;
    }
};

/// The parts of `p` between `/`s, pushed last first, so they pop in order.
fn pushReversed(todo: *C.List([]const u8), p: []const u8) void {
    var parts = C.list([]const u8);
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |c| C.push([]const u8, &parts, c);
    var i = parts.items.len;
    while (i > 0) {
        i -= 1;
        C.push([]const u8, todo, parts.items[i]);
    }
}

pub const Want = enum {
    /// A regular file with mode 0755.
    exec,
    /// A regular file of one byte or more.
    file,
};

pub const Wanted = struct { want: Want, path: []const u8 };

/// The answer for each wanted path: `ok ...` lines, and failures.
pub const Findings = struct { ok: [][]const u8, bad: [][]const u8 };

pub fn checkPaths(fs: *const Fs, wants: []const Wanted) Findings {
    var ok = C.list([]const u8);
    var bad = C.list([]const u8);
    for (wants) |w| {
        const kind = if (w.want == .exec) "exec" else "file";
        const p = w.path;
        const r = fs.resolve(p) catch {
            C.push([]const u8, &bad, C.fmt("{s} {s}: {s}", .{ kind, p, C.msg }));
            continue;
        };
        if (fs.nodes.get(r)) |n| {
            if (n.ty != .file) {
                C.push([]const u8, &bad, C.fmt("{s} {s}: {s} is of type {c}, not a regular file", .{ kind, p, r, n.ty.letter() }));
            } else if (w.want == .exec and n.mode != 0o755) {
                C.push([]const u8, &bad, C.fmt("exec {s}: {s} has mode {o}, want 755", .{ p, r, n.mode }));
            } else if (w.want == .file and n.size < 1) {
                C.push([]const u8, &bad, C.fmt("file {s}: {s} is empty", .{ p, r }));
            } else {
                C.push([]const u8, &ok, C.fmt("ok {s} {s} -> {s}", .{ kind, p, r }));
            }
        } else {
            C.push([]const u8, &bad, C.fmt("{s} {s}: not in the image", .{ kind, p }));
        }
    }
    return .{ .ok = ok.items, .bad = bad.items };
}

/// The entries of `layer` (applied over `below`) that change the type of
/// an entry of `below`: a directory over a symlink (`bin/` over
/// `bin -> usr/bin`) hides everything the link reaches.
pub fn typeChanges(below: *const Fs, layer: []const Entry) [][]const u8 {
    var out = C.list([]const u8);
    for (layer) |e| {
        const p = normalize(e.path);
        if (C.startsWith(split(p).base, WHITEOUT)) continue;
        const ty: Type = switch (e.kind) {
            .file, .hardlink => .file,
            .dir => .dir,
            .symlink => .symlink,
            .other => .other,
        };
        if (below.nodes.get(p)) |n| {
            if (n.ty != ty) C.push([]const u8, &out, C.fmt("the last layer turns {s} from type {c} into type {c}", .{ p, n.ty.letter(), ty.letter() }));
        }
    }
    return out.items;
}
