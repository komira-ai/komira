// Why Zig: build tools are Zig (tools/build/README.md). third_party_act
// replaces the busybox scripts of `third_party_srcs` (defs.bzl) and of
// `botocore_model` (third_party/botocore), so those actions and tests run no shell.
//! third_party_act: the actions of the vendored-source rules.
//!
//!   third_party_act srcs-gen --archive <tgz> --out <file> --gen <program> --library <l>
//!       --gen-label <s> --drift-label <s> --committed-path <s>
//!       Decompresses the release archive into the scratch directory and runs
//!       <program> <l> <tar> <out> <gen-label> <drift-label> <committed-path>.
//!   third_party_act drift --generated <f> --committed <f> --regenerate <command>
//!       Exit 0 when the two files are the same bytes; else names the first
//!       differing lines (- committed, + generated) and the command that
//!       regenerates the committed copy, and exits 1.
//!   third_party_act botocore-model --src <f> --sha256 <hex> --out <f>
//!       Copies the model once its sha256 is the one models.bzl states.
//!
//! The messages and exit statuses are those of the scripts they replace.

const std = @import("std");
const U = @import("act_util");

const prog = "third_party_act";

fn usage(comptime fmt: []const u8, args: anytype) u8 {
    std.debug.print(prog ++ ": " ++ fmt ++ "\n", args);
    return 2;
}

// ---- drift ------------------------------------------------------------------

pub const Op = struct { sign: u8, line: []const u8 };

/// The lines of `text` as `diff` sees them: split at newlines, the empty piece
/// after a final newline not a line.
pub fn lines(a: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var list = std.ArrayList([]const u8).init(a);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try list.append(l);
    if (list.items.len > 0 and list.items[list.items.len - 1].len == 0) _ = list.pop();
    return list.toOwnedSlice();
}

/// The `-` and `+` lines of `diff -U0 have got`, in its order: within a run of
/// changes, the removed lines then the added ones. The common beginning and end
/// are trimmed and the middle is matched by longest common subsequence; a
/// middle too large for that is all removed and all added.
pub fn diffOps(a: std.mem.Allocator, have: []const []const u8, got: []const []const u8) ![]Op {
    var start: usize = 0;
    while (start < have.len and start < got.len and std.mem.eql(u8, have[start], got[start])) start += 1;
    var he = have.len;
    var ge = got.len;
    while (he > start and ge > start and std.mem.eql(u8, have[he - 1], got[ge - 1])) {
        he -= 1;
        ge -= 1;
    }
    const h = have[start..he];
    const g = got[start..ge];
    var ops = std.ArrayList(Op).init(a);
    if (h.len == 0 or g.len == 0 or h.len * g.len > 16 * 1024 * 1024) {
        for (h) |l| try ops.append(.{ .sign = '-', .line = l });
        for (g) |l| try ops.append(.{ .sign = '+', .line = l });
        return ops.toOwnedSlice();
    }
    // lcs[i][j]: the length of the longest common subsequence of h[i..] and g[j..].
    const w = g.len + 1;
    const lcs = try a.alloc(u32, (h.len + 1) * w);
    @memset(lcs, 0);
    var i: usize = h.len;
    while (i > 0) {
        i -= 1;
        var j: usize = g.len;
        while (j > 0) {
            j -= 1;
            lcs[i * w + j] = if (std.mem.eql(u8, h[i], g[j])) lcs[(i + 1) * w + j + 1] + 1 else @max(lcs[(i + 1) * w + j], lcs[i * w + j + 1]);
        }
    }
    var removed = std.ArrayList([]const u8).init(a);
    var added = std.ArrayList([]const u8).init(a);
    var x: usize = 0;
    var y: usize = 0;
    while (x < h.len or y < g.len) {
        if (x < h.len and y < g.len and std.mem.eql(u8, h[x], g[y])) {
            for (removed.items) |l| try ops.append(.{ .sign = '-', .line = l });
            for (added.items) |l| try ops.append(.{ .sign = '+', .line = l });
            removed.clearRetainingCapacity();
            added.clearRetainingCapacity();
            x += 1;
            y += 1;
        } else if (x < h.len and (y >= g.len or lcs[(x + 1) * w + y] >= lcs[x * w + y + 1])) {
            try removed.append(h[x]);
            x += 1;
        } else {
            try added.append(g[y]);
            y += 1;
        }
    }
    for (removed.items) |l| try ops.append(.{ .sign = '-', .line = l });
    for (added.items) |l| try ops.append(.{ .sign = '+', .line = l });
    return ops.toOwnedSlice();
}

/// What the script showed of a diff: the changed lines whose text does not
/// begin with `-` or `+` (a line with no text is not shown), the first `max`.
pub fn shown(a: std.mem.Allocator, ops: []const Op, max: usize) ![][]u8 {
    var out = std.ArrayList([]u8).init(a);
    for (ops) |op| {
        if (out.items.len == max) break;
        if (op.line.len == 0 or op.line[0] == '-' or op.line[0] == '+') continue;
        try out.append(try std.fmt.allocPrint(a, "{c}{s}", .{ op.sign, op.line }));
    }
    return out.toOwnedSlice();
}

fn cmdDrift(a: std.mem.Allocator, args: []const []const u8) u8 {
    const spec = [_]U.Spec{ .{ .name = "generated" }, .{ .name = "committed" }, .{ .name = "regenerate" } };
    var bad: []const u8 = "";
    const f = U.parseFlags(a, args, &spec, &bad) catch |e| return usage("drift: {s}: {s}", .{ @errorName(e), bad });
    const got_path = f.need("generated") catch return usage("drift needs --generated", .{});
    const have_path = f.need("committed") catch return usage("drift needs --committed", .{});
    const regen = f.need("regenerate") catch return usage("drift needs --regenerate", .{});
    const got = std.fs.cwd().readFileAlloc(a, got_path, 1 << 28) catch |e| return usage("cannot read {s}: {s}", .{ got_path, @errorName(e) });
    const have = std.fs.cwd().readFileAlloc(a, have_path, 1 << 28) catch |e| return usage("cannot read {s}: {s}", .{ have_path, @errorName(e) });
    const out = std.io.getStdOut().writer();
    if (std.mem.eql(u8, got, have)) {
        out.print("third_party_srcs: {s} matches the archive\n", .{have_path}) catch return 2;
        return 0;
    }
    out.print("third_party_srcs: {s} differs from what the archive gives (- committed, + generated):\n", .{have_path}) catch return 2;
    const ops = diffOps(a, lines(a, have) catch return 2, lines(a, got) catch return 2) catch return 2;
    const rows = shown(a, ops, 6) catch return 2;
    for (rows) |r| out.print("{s}\n", .{r}) catch return 2;
    out.print("regenerate: {s}\n", .{regen}) catch return 2;
    return 0;
}

// ---- srcs-gen ---------------------------------------------------------------

/// Decompresses the gzip file `src` to `dst`.
pub fn gunzip(dir: std.fs.Dir, src: []const u8, dst: []const u8) !void {
    const in = try dir.openFile(src, .{});
    defer in.close();
    const out = try dir.createFile(dst, .{});
    defer out.close();
    var br = std.io.bufferedReader(in.reader());
    var dec = std.compress.gzip.decompressor(br.reader());
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = try dec.reader().read(&buf);
        if (n == 0) break;
        try out.writeAll(buf[0..n]);
    }
}

fn cmdSrcsGen(a: std.mem.Allocator, args: []const []const u8) u8 {
    const spec = [_]U.Spec{
        .{ .name = "archive" }, .{ .name = "out" },         .{ .name = "gen" },            .{ .name = "library" },
        .{ .name = "gen-label" }, .{ .name = "drift-label" }, .{ .name = "committed-path" },
    };
    var bad: []const u8 = "";
    const f = U.parseFlags(a, args, &spec, &bad) catch |e| return usage("srcs-gen: {s}: {s}", .{ @errorName(e), bad });
    const archive = f.need("archive") catch return usage("srcs-gen needs --archive", .{});
    const out = f.need("out") catch return usage("srcs-gen needs --out", .{});
    const gen = f.need("gen") catch return usage("srcs-gen needs --gen", .{});
    const library = f.need("library") catch return usage("srcs-gen needs --library", .{});
    const gen_label = f.need("gen-label") catch return usage("srcs-gen needs --gen-label", .{});
    const drift_label = f.need("drift-label") catch return usage("srcs-gen needs --drift-label", .{});
    const committed = f.need("committed-path") catch return usage("srcs-gen needs --committed-path", .{});

    // Scratch: where buck2 says, else beside the action's inputs (a local action
    // shares the checkout root with the others, so scratch is per action).
    const cwd = std.fs.cwd().realpathAlloc(a, ".") catch return 2;
    const scratch = U.scratchRoot(a, cwd, std.posix.getenv("BUCK_SCRATCH_PATH")) catch return 2;
    std.fs.cwd().makePath(scratch) catch |e| return usage("cannot create {s}: {s}", .{ scratch, @errorName(e) });
    defer std.fs.cwd().deleteTree(scratch) catch {};
    const tar = std.fs.path.join(a, &.{ scratch, "archive.tar" }) catch return 2;
    gunzip(std.fs.cwd(), archive, tar) catch |e| {
        std.debug.print("gzip: {s}: {s}\n", .{ archive, @errorName(e) });
        return 1;
    };
    const gen_abs = U.abs(a, cwd, gen) catch return 2;
    var child = std.process.Child.init(&.{ gen_abs, library, tar, out, gen_label, drift_label, committed }, a);
    const term = child.spawnAndWait() catch |e| return usage("cannot run {s}: {s}", .{ gen, @errorName(e) });
    return U.exitCodeOf(term);
}

// ---- botocore-model -----------------------------------------------------------

/// Why the model `data` (read from `src`) is not the one models.bzl pins, or null.
pub fn modelRefusal(a: std.mem.Allocator, src: []const u8, data: []const u8, want: []const u8) !?[]u8 {
    const got = U.sha256Hex(data);
    if (std.mem.eql(u8, &got, want)) return null;
    return try std.fmt.allocPrint(a, "botocore_model: {s} has sha256 {s}; models.bzl says {s}\n", .{ src, &got, want });
}

fn cmdBotocore(a: std.mem.Allocator, args: []const []const u8) u8 {
    const spec = [_]U.Spec{ .{ .name = "src" }, .{ .name = "sha256" }, .{ .name = "out" } };
    var bad: []const u8 = "";
    const f = U.parseFlags(a, args, &spec, &bad) catch |e| return usage("botocore-model: {s}: {s}", .{ @errorName(e), bad });
    const src = f.need("src") catch return usage("botocore-model needs --src", .{});
    const want = f.need("sha256") catch return usage("botocore-model needs --sha256", .{});
    const out = f.need("out") catch return usage("botocore-model needs --out", .{});
    const data = std.fs.cwd().readFileAlloc(a, src, 1 << 28) catch |e| return usage("cannot read {s}: {s}", .{ src, @errorName(e) });
    if (modelRefusal(a, src, data, want) catch return 2) |text| {
        std.debug.print("{s}", .{text});
        return 1;
    }
    if (std.fs.path.dirname(out)) |d| std.fs.cwd().makePath(d) catch {};
    std.fs.cwd().copyFile(src, std.fs.cwd(), out, .{}) catch |e| return usage("cannot copy {s} to {s}: {s}", .{ src, out, @errorName(e) });
    return 0;
}

pub fn main() void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = std.process.argsAlloc(a) catch std.process.exit(2);
    if (argv.len < 2) std.process.exit(usage("usage: third_party_act (srcs-gen|drift|botocore-model) ...", .{}));
    const plain = a.alloc([]const u8, argv.len - 2) catch std.process.exit(2);
    for (argv[2..], 0..) |s, i| plain[i] = s;
    const sub = argv[1];
    const rc: u8 = if (std.mem.eql(u8, sub, "srcs-gen"))
        cmdSrcsGen(a, plain)
    else if (std.mem.eql(u8, sub, "drift"))
        cmdDrift(a, plain)
    else if (std.mem.eql(u8, sub, "botocore-model"))
        cmdBotocore(a, plain)
    else
        usage("unknown subcommand {s}", .{sub});
    if (rc != 0) std.process.exit(rc);
}
