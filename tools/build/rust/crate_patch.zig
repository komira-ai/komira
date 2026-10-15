//! crate_patch: copies a crate's sources and edits them, in a build action,
//! where Cargo would have run the crate's build script.
//!
//!   crate_patch <spec.json> <crate dir> <out dir>
//!
//! The spec (the `patch` attribute of the Rust rules, as JSON):
//!   {"copy": ["src", ...],                        entries of the crate directory to copy (all if empty)
//!    "sub":  [{"file", "from", "to", "count"}],   exact text substitutions in a copied file
//!    "add":  [{"file", "content"}]}               generated files
//!
//! A substitution that matches a number of times other than `count` (default
//! 1) is an error: a patch that stops matching after a crate upgrade must
//! fail the build, not silently do nothing. A substitution or an `add` that
//! names a path outside the copied tree, and an `add` of a file the crate
//! already has, are errors too. Output is deterministic: the same inputs give
//! the same bytes.

const std = @import("std");

pub const Sub = struct { file: []const u8, from: []const u8, to: []const u8, count: usize = 1 };
pub const Add = struct { file: []const u8, content: []const u8 };
pub const Spec = struct {
    copy: []const []const u8 = &.{},
    sub: []const Sub = &.{},
    add: []const Add = &.{},
};

pub const PatchError = error{
    EmptyPattern,
    WrongMatchCount,
    SubTargetMissing,
    AddCollides,
    BadPath,
    NotFileOrDir,
};

/// Why `patchTree` failed, for the message (the error value says only which).
pub const Diag = struct {
    buf: [512]u8 = undefined,
    msg: []const u8 = "",

    fn set(d: *Diag, comptime fmt: []const u8, args: anytype) void {
        d.msg = std.fmt.bufPrint(&d.buf, fmt, args) catch "(message too long)";
    }
};

/// `text` with every `from` replaced by `to`; `n` is how many there were.
pub fn replaceAll(a: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8, n: *usize) ![]u8 {
    n.* = 0;
    if (from.len == 0) return error.EmptyPattern;
    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, from)) |at| {
        try out.appendSlice(text[i..at]);
        try out.appendSlice(to);
        i = at + from.len;
        n.* += 1;
    }
    try out.appendSlice(text[i..]);
    return out.toOwnedSlice();
}

/// A relative path with no `..`, no leading `/` and no empty or `.` part.
fn safeRel(p: []const u8) bool {
    if (p.len == 0 or p[0] == '/') return false;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn copyFile(a: std.mem.Allocator, src: std.fs.Dir, dst: std.fs.Dir, name: []const u8, rel: []const u8, spec: Spec, diag: *Diag) !void {
    var data = try src.readFileAlloc(a, name, 1 << 28);
    for (spec.sub) |s| {
        if (!std.mem.eql(u8, s.file, rel)) continue;
        var n: usize = 0;
        data = try replaceAll(a, data, s.from, s.to, &n);
        if (n != s.count) {
            diag.set("{s}: `{s}` matched {d} times, expected {d}", .{ rel, s.from, n, s.count });
            return error.WrongMatchCount;
        }
    }
    try dst.writeFile(name, data);
}

fn copyTree(a: std.mem.Allocator, src: std.fs.Dir, dst: std.fs.Dir, spec: Spec, prefix: []const u8, diag: *Diag) !void {
    var names = std.ArrayList(std.fs.Dir.Entry).init(a);
    var it = src.iterate();
    while (try it.next()) |e| try names.append(.{ .name = try a.dupe(u8, e.name), .kind = e.kind });
    // Directory order is the file system's; sort so the work is deterministic.
    std.mem.sort(std.fs.Dir.Entry, names.items, {}, struct {
        fn less(_: void, x: std.fs.Dir.Entry, y: std.fs.Dir.Entry) bool {
            return std.mem.order(u8, x.name, y.name) == .lt;
        }
    }.less);
    for (names.items) |e| {
        const rel = if (prefix.len == 0) e.name else try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, e.name });
        switch (e.kind) {
            .directory => {
                try dst.makePath(e.name);
                var s = try src.openDir(e.name, .{ .iterate = true });
                defer s.close();
                var d = try dst.openDir(e.name, .{});
                defer d.close();
                try copyTree(a, s, d, spec, rel, diag);
            },
            .file => try copyFile(a, src, dst, e.name, rel, spec, diag),
            else => {
                diag.set("{s}: not a file or directory", .{rel});
                return error.NotFileOrDir;
            },
        }
    }
}

/// Copies `in` (the whole tree, or the `copy` entries) to `out`, applying
/// the substitutions, then writes the `add` files.
pub fn patchTree(a: std.mem.Allocator, in: std.fs.Dir, out: std.fs.Dir, spec: Spec, diag: *Diag) !void {
    if (spec.copy.len == 0) {
        try copyTree(a, in, out, spec, "", diag);
    } else {
        for (spec.copy) |name| {
            if (!safeRel(name)) {
                diag.set("copy: `{s}` is not a relative path inside the crate", .{name});
                return error.BadPath;
            }
            const st = try in.statFile(name);
            if (st.kind == .directory) {
                try out.makePath(name);
                var s = try in.openDir(name, .{ .iterate = true });
                defer s.close();
                var d = try out.openDir(name, .{});
                defer d.close();
                try copyTree(a, s, d, spec, name, diag);
            } else {
                if (std.fs.path.dirname(name)) |dn| try out.makePath(dn);
                try copyFile(a, in, out, name, name, spec, diag);
            }
        }
    }
    // Every substitution must have named a file that was copied.
    for (spec.sub) |s| {
        out.access(s.file, .{}) catch {
            diag.set("sub: {s} is not in the output (copy it, or fix the path)", .{s.file});
            return error.SubTargetMissing;
        };
    }
    for (spec.add) |f| {
        if (!safeRel(f.file)) {
            diag.set("add: `{s}` is not a relative path inside the crate", .{f.file});
            return error.BadPath;
        }
        if (out.access(f.file, .{})) |_| {
            diag.set("add: {s} already exists in the crate", .{f.file});
            return error.AddCollides;
        } else |_| {}
        if (std.fs.path.dirname(f.file)) |d| try out.makePath(d);
        try out.writeFile(f.file, f.content);
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    if (args.len != 4) {
        std.debug.print("usage: crate_patch <spec.json> <crate dir> <out dir>\n", .{});
        std.process.exit(2);
    }
    const spec_text = try std.fs.cwd().readFileAlloc(a, args[1], 1 << 24);
    const spec = (std.json.parseFromSlice(Spec, a, spec_text, .{}) catch |e| {
        std.debug.print("crate_patch: {s}: not a patch spec: {s}\n", .{ args[1], @errorName(e) });
        std.process.exit(2);
    }).value;

    var in = try std.fs.cwd().openDir(args[2], .{ .iterate = true });
    defer in.close();
    try std.fs.cwd().makePath(args[3]);
    var out = try std.fs.cwd().openDir(args[3], .{});
    defer out.close();

    var diag = Diag{};
    patchTree(a, in, out, spec, &diag) catch |e| {
        std.debug.print("crate_patch: {s}\n", .{if (diag.msg.len > 0) diag.msg else @errorName(e)});
        std.process.exit(1);
    };
}

// ---- tests -------------------------------------------------------------------

test "replaceAll counts and replaces" {
    const a = std.testing.allocator;
    var n: usize = 0;
    const r = try replaceAll(a, "aXbXc", "X", "--", &n);
    defer a.free(r);
    try std.testing.expectEqualStrings("a--b--c", r);
    try std.testing.expectEqual(@as(usize, 2), n);
}

test "replaceAll with no match reports zero" {
    const a = std.testing.allocator;
    var n: usize = 7;
    const r = try replaceAll(a, "abc", "Z", "y", &n);
    defer a.free(r);
    try std.testing.expectEqualStrings("abc", r);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "replaceAll refuses an empty pattern" {
    var n: usize = 0;
    try std.testing.expectError(error.EmptyPattern, replaceAll(std.testing.allocator, "abc", "", "y", &n));
}

test "safeRel refuses escapes" {
    try std.testing.expect(safeRel("src/lib.rs"));
    try std.testing.expect(!safeRel("../x"));
    try std.testing.expect(!safeRel("/etc/passwd"));
    try std.testing.expect(!safeRel("a//b"));
    try std.testing.expect(!safeRel("a/./b"));
    try std.testing.expect(!safeRel(""));
}

fn fixture(tmp: *std.testing.TmpDir) !void {
    try tmp.dir.makePath("in/src/sub");
    try tmp.dir.makePath("in/other");
    try tmp.dir.writeFile("in/src/lib.rs", "include!(concat!(env!(\"OUT_DIR\"), \"/g.rs\"));\n");
    try tmp.dir.writeFile("in/src/sub/m.rs", "A A\n");
    try tmp.dir.writeFile("in/other/skip.rs", "not copied");
    try tmp.dir.writeFile("in/Cargo.toml", "[package]\n");
    try tmp.dir.makePath("out");
}

fn run(tmp: *std.testing.TmpDir, spec: Spec, diag: *Diag) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var in = try tmp.dir.openDir("in", .{ .iterate = true });
    defer in.close();
    var out = try tmp.dir.openDir("out", .{});
    defer out.close();
    try patchTree(arena.allocator(), in, out, spec, diag);
}

test "patchTree copies, substitutes and adds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(&tmp);
    var diag = Diag{};
    try run(&tmp, .{
        .copy = &.{ "src", "Cargo.toml" },
        .sub = &.{
            .{ .file = "src/lib.rs", .from = "concat!(env!(\"OUT_DIR\"), \"/g.rs\")", .to = "\"g.rs\"" },
            .{ .file = "src/sub/m.rs", .from = "A", .to = "B", .count = 2 },
        },
        .add = &.{.{ .file = "src/g.rs", .content = "pub const G: u8 = 1;\n" }},
    }, &diag);
    const a = std.testing.allocator;
    const lib = try tmp.dir.readFileAlloc(a, "out/src/lib.rs", 1 << 16);
    defer a.free(lib);
    try std.testing.expectEqualStrings("include!(\"g.rs\");\n", lib);
    const m = try tmp.dir.readFileAlloc(a, "out/src/sub/m.rs", 1 << 16);
    defer a.free(m);
    try std.testing.expectEqualStrings("B B\n", m);
    const g = try tmp.dir.readFileAlloc(a, "out/src/g.rs", 1 << 16);
    defer a.free(g);
    try std.testing.expectEqualStrings("pub const G: u8 = 1;\n", g);
    // `copy` named src and Cargo.toml only.
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("out/other/skip.rs", .{}));
    try tmp.dir.access("out/Cargo.toml", .{});
}

test "patchTree with no copy list copies everything" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(&tmp);
    var diag = Diag{};
    try run(&tmp, .{}, &diag);
    try tmp.dir.access("out/other/skip.rs", .{});
    try tmp.dir.access("out/src/sub/m.rs", .{});
}

test "a substitution that matches the wrong number of times fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(&tmp);
    var diag = Diag{};
    // "A A" holds two As; the default count is 1.
    try std.testing.expectError(error.WrongMatchCount, run(&tmp, .{
        .sub = &.{.{ .file = "src/sub/m.rs", .from = "A", .to = "B" }},
    }, &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.msg, "matched 2 times, expected 1") != null);
}

test "a substitution that no longer matches fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(&tmp);
    var diag = Diag{};
    try std.testing.expectError(error.WrongMatchCount, run(&tmp, .{
        .sub = &.{.{ .file = "src/lib.rs", .from = "gone after an upgrade", .to = "x" }},
    }, &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.msg, "matched 0 times") != null);
}

test "a substitution naming a file that was not copied fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(&tmp);
    var diag = Diag{};
    try std.testing.expectError(error.SubTargetMissing, run(&tmp, .{
        .copy = &.{"src"},
        .sub = &.{.{ .file = "other/skip.rs", .from = "not", .to = "x" }},
    }, &diag));
}

test "add refuses an existing file and an escaping path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixture(&tmp);
    var diag = Diag{};
    try std.testing.expectError(error.AddCollides, run(&tmp, .{
        .add = &.{.{ .file = "src/lib.rs", .content = "x" }},
    }, &diag));
    try std.testing.expectError(error.BadPath, run(&tmp, .{
        .add = &.{.{ .file = "../escape.rs", .content = "x" }},
    }, &diag));
    try std.testing.expectError(error.BadPath, run(&tmp, .{
        .copy = &.{"../in"},
    }, &diag));
}

test "the spec parses from the JSON the rules write" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const spec = (try std.json.parseFromSlice(Spec, arena.allocator(),
        \\{"copy": ["src"], "sub": [{"file": "src/lib.rs", "from": "a", "to": "b"}, {"file": "f", "from": "x", "to": "y", "count": 3}],
        \\ "add": [{"file": "src/g.rs", "content": "c"}]}
    , .{})).value;
    try std.testing.expectEqual(@as(usize, 1), spec.copy.len);
    try std.testing.expectEqual(@as(usize, 1), spec.sub[0].count);
    try std.testing.expectEqual(@as(usize, 3), spec.sub[1].count);
    try std.testing.expectEqualStrings("c", spec.add[0].content);
}
