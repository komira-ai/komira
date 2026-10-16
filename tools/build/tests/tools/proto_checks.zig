//! tests_act's checks of protoc-gen-mojo: `proto-gen` runs protoc with the plugin
//! over a corpus and records the outcome; `proto-check` judges it (golden files, or
//! an expected failure, and absent and present strings); `rest-extract` cuts the
//! REST URL helpers block out of a generated file.

const std = @import("std");
const diff = @import("unified_diff");
const A = std.mem.Allocator;

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(1);
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("tests_act: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

/// proto-gen <protoc dir> <plugin> <corpus> <out dir> <options> <n roots> <root>... <import path>...
/// Always exits 0: the outcome is recorded in <out>/files, <out>/stderr and <out>/rc.
pub fn protoGen(a: A, args: []const []const u8) !void {
    if (args.len < 6) return error.Usage;
    const protoc = args[0];
    const plugin = if (std.fs.path.isAbsolute(args[1])) args[1] else try std.fs.path.join(a, &.{ try std.fs.cwd().realpathAlloc(a, "."), args[1] });
    const corpus = args[2];
    const out = args[3];
    const options = args[4];
    const n = try std.fmt.parseInt(usize, args[5], 10);
    if (args.len < 6 + n) return error.Usage;
    const roots = args[6 .. 6 + n];
    const generate = args[6 + n ..];
    const cwd = std.fs.cwd();
    const files = try std.fs.path.join(a, &.{ out, "files" });
    try cwd.makePath(files);
    const scratch_base = std.process.getEnvVarOwned(a, "BUCK_SCRATCH_PATH") catch try a.dupe(u8, ".komira_action");
    const t = try std.fs.path.join(a, &.{ scratch_base, "komira" });
    try cwd.deleteTree(t);
    try cwd.makePath(try std.fs.path.join(a, &.{ t, "tmp" }));
    defer cwd.deleteTree(t) catch {};
    var env = try std.process.getEnvMap(a);
    try env.put("TMPDIR", try cwd.realpathAlloc(a, try std.fs.path.join(a, &.{ t, "tmp" })));
    try env.put("HOME", try cwd.realpathAlloc(a, t));
    // protoc searches the corpus first, then the roots in order, then its own
    // well-known types.
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(a, try std.fs.path.join(a, &.{ protoc, "bin/protoc" }));
    try argv.append(a, try std.fmt.allocPrint(a, "--proto_path={s}", .{corpus}));
    try argv.appendSlice(a, generate);
    for (roots) |r| try argv.append(a, try std.fmt.allocPrint(a, "--proto_path={s}", .{r}));
    try argv.append(a, try std.fmt.allocPrint(a, "--proto_path={s}/include", .{protoc}));
    try argv.append(a, try std.fmt.allocPrint(a, "--plugin=protoc-gen-mojo={s}", .{plugin}));
    try argv.append(a, try std.fmt.allocPrint(a, "--mojo_out={s}", .{files}));
    try argv.append(a, try std.fmt.allocPrint(a, "--mojo_opt={s}", .{options}));
    const r = try std.process.Child.run(.{ .allocator = a, .argv = argv.items, .env_map = &env, .max_output_bytes = 1 << 26 });
    const rc: u32 = switch (r.term) {
        .Exited => |c| c,
        .Signal => |s| 128 + s,
        else => 255,
    };
    try writeFile(try std.fs.path.join(a, &.{ out, "stderr" }), r.stderr);
    try writeFile(try std.fs.path.join(a, &.{ out, "rc" }), try std.fmt.allocPrint(a, "{d}\n", .{rc}));
}

fn writeFile(path: []const u8, data: []const u8) !void {
    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(data);
}

fn listTop(a: A, dir: std.fs.Dir) ![][]const u8 {
    var names = std.ArrayList([]const u8).empty;
    var it = dir.iterate();
    while (try it.next()) |e| try names.append(a, try a.dupe(u8, e.name));
    std.mem.sort([]const u8, names.items, {}, lessThan);
    return names.toOwnedSlice(a);
}

/// The relative paths of the regular files under `dir`, sorted.
fn listFiles(a: A, dir: std.fs.Dir) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    var w = try dir.walk(a);
    while (try w.next()) |e| {
        if (e.kind != .directory) try out.append(a, try a.dupe(u8, e.path));
    }
    std.mem.sort([]const u8, out.items, {}, lessThan);
    return out.toOwnedSlice(a);
}

fn grepHits(a: A, dir: std.fs.Dir, needle: []const u8) ![][]const u8 {
    var hits = std.ArrayList([]const u8).empty;
    for (try listFiles(a, dir)) |f| {
        const data = try dir.readFileAlloc(a, f, 1 << 28);
        if (std.mem.indexOf(u8, data, needle) != null) try hits.append(a, f);
    }
    return hits.toOwnedSlice(a);
}

/// The differences between the trees `golden` and `got` as `diff -r -u` shows
/// them, or null when they are the same.
pub fn treeDiff(a: A, golden: std.fs.Dir, golden_name: []const u8, got: std.fs.Dir, got_name: []const u8) !?[]u8 {
    var names = std.StringHashMap(void).init(a);
    for (try listFiles(a, golden)) |f| try names.put(f, {});
    for (try listFiles(a, got)) |f| try names.put(f, {});
    var sorted = std.ArrayList([]const u8).empty;
    var it = names.keyIterator();
    while (it.next()) |k| try sorted.append(a, k.*);
    std.mem.sort([]const u8, sorted.items, {}, lessThan);
    var out = std.ArrayList(u8).empty;
    for (sorted.items) |f| {
        const x = golden.readFileAlloc(a, f, 1 << 28) catch null;
        const y = got.readFileAlloc(a, f, 1 << 28) catch null;
        if (x == null) {
            try out.writer(a).print("Only in {s}: {s}\n", .{ got_name, f });
        } else if (y == null) {
            try out.writer(a).print("Only in {s}: {s}\n", .{ golden_name, f });
        } else if (!std.mem.eql(u8, x.?, y.?)) {
            const l1 = try std.fmt.allocPrint(a, "{s}/{s}", .{ golden_name, f });
            const l2 = try std.fmt.allocPrint(a, "{s}/{s}", .{ got_name, f });
            try out.writer(a).print("diff -r -u {s} {s}\n", .{ l1, l2 });
            if (try diff.unifiedDiff(a, l1, l2, x.?, y.?)) |d| try out.appendSlice(a, d);
        }
    }
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(a);
}

/// proto-check <gen> <golden dir or ""> <expected error or ""> <mark> <n absent> <absent>... <present>...
pub fn protoCheck(a: A, args: []const []const u8) !void {
    if (args.len < 5) return error.Usage;
    const gen = args[0];
    const golden = args[1];
    const expect = args[2];
    const mark = args[3];
    const n = try std.fmt.parseInt(usize, args[4], 10);
    if (args.len < 5 + n) return error.Usage;
    const cwd = std.fs.cwd();
    const rc_text = std.mem.trimRight(u8, try cwd.readFileAlloc(a, try std.fs.path.join(a, &.{ gen, "rc" }), 1 << 10), "\n");
    const stderr_text = try cwd.readFileAlloc(a, try std.fs.path.join(a, &.{ gen, "stderr" }), 1 << 26);
    const files_path = try std.fs.path.join(a, &.{ gen, "files" });
    var files = try cwd.openDir(files_path, .{ .iterate = true });
    defer files.close();
    if (expect.len > 0) {
        if (std.mem.eql(u8, rc_text, "0")) fail("protoc-gen-mojo was expected to fail with: {s}; it succeeded", .{expect});
        if (std.mem.indexOf(u8, stderr_text, expect) == null) {
            std.debug.print("protoc-gen-mojo failed, but not with: {s}\n{s}", .{ expect, stderr_text });
            std.process.exit(1);
        }
        const top = try listTop(a, files);
        if (top.len > 0) {
            std.debug.print("protoc-gen-mojo failed but wrote files:\n", .{});
            for (top) |t| std.debug.print("{s}\n", .{t});
            std.process.exit(1);
        }
    } else {
        if (!std.mem.eql(u8, rc_text, "0")) {
            std.debug.print("protoc-gen-mojo failed (exit {s}):\n{s}", .{ rc_text, stderr_text });
            std.process.exit(1);
        }
        var g = try cwd.openDir(golden, .{ .iterate = true });
        defer g.close();
        if (try treeDiff(a, g, golden, files, files_path)) |d| {
            std.debug.print("{s}", .{d});
            fail("the generated files differ from the golden files (above)", .{});
        }
    }
    for (args[5 .. 5 + n]) |s| {
        const hits = try grepHits(a, files, s);
        if (hits.len > 0) {
            for (hits) |h| std.debug.print("{s}/{s}\n", .{ files_path, h });
            fail("the generated files above hold `{s}`, which must be absent", .{s});
        }
    }
    for (args[5 + n ..]) |s| {
        if ((try grepHits(a, files, s)).len == 0) fail("no generated file holds `{s}`", .{s});
    }
    try writeFile(mark, "ok\n");
}

pub const rest_begin = "# ---- REST URL helpers (one copy per REST file) ----";
pub const rest_end = "# ---- end of REST URL helpers ----";

/// The lines of `src` from the begin marker to the end marker, both included.
pub fn restBlock(a: A, src: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var on = false;
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |l| {
        if (lines.peek() == null and l.len == 0) break;
        if (std.mem.eql(u8, l, rest_begin)) on = true;
        if (on) try out.writer(a).print("{s}\n", .{l});
        if (std.mem.eql(u8, l, rest_end)) on = false;
    }
    return out.toOwnedSlice(a);
}

fn countLines(src: []const u8, line: []const u8) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |l| {
        if (std.mem.eql(u8, l, line)) n += 1;
    }
    return n;
}

/// rest-extract <generated file> <out>
pub fn restExtract(a: A, args: []const []const u8) !void {
    if (args.len != 2) return error.Usage;
    const src = try std.fs.cwd().readFileAlloc(a, args[0], 1 << 28);
    for ([_][]const u8{ rest_begin, rest_end }) |m| {
        const n = countLines(src, m);
        if (n != 1) fail("proto_codegen: {s} holds the marker '{s}' {d} times, not once", .{ args[0], m, n });
    }
    try writeFile(args[1], try restBlock(a, src));
}
