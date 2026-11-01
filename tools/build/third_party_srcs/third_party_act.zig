// Why Zig: build tools are Zig (tools/build/README.md). third_party_act
// replaces the busybox scripts of `third_party_srcs` (defs.bzl) and of
// `botocore_model` (third_party/botocore), so those actions and tests run no shell.
//! third_party_act: the actions of the vendored-source rules.
//!
//!   third_party_act srcs-gen --archive <tgz> --out <file> --gen <program> --library <l>
//!       --gen-label <s> --drift-label <s> --committed-path <s>
//!       Decompresses the release archive into the scratch directory and runs
//!       <program> <l> <tar> <out> <gen-label> <drift-label> <committed-path> <size of the
//!       archive in bytes>.
//!   third_party_act drift --generated <f> --committed <f> --regenerate <command>
//!       Exit 0 when the two files are the same bytes; else names the first
//!       differing lines (- committed, + generated) and the command that
//!       regenerates the committed copy, and exits 1.
//!   third_party_act files-check --archive <tgz> --files <file> --regenerate <command>
//!       [--require <list>]...
//!       Reads the committed files.bzl and the release archive, each on its own:
//!       exit 0 when every file a list (or a dict value) names is in the archive
//!       and in FILES, FILES is sorted and has no duplicate, every *INCLUDES
//!       directory holds a file of the archive, and every --require list is
//!       there and not empty; else names the first problems and exits 1.
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
    var list = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try list.append(a, l);
    if (list.items.len > 0 and list.items[list.items.len - 1].len == 0) _ = list.pop();
    return list.toOwnedSlice(a);
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
    var ops = std.ArrayList(Op).empty;
    if (h.len == 0 or g.len == 0 or h.len * g.len > 16 * 1024 * 1024) {
        for (h) |l| try ops.append(a, .{ .sign = '-', .line = l });
        for (g) |l| try ops.append(a, .{ .sign = '+', .line = l });
        return ops.toOwnedSlice(a);
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
    var removed = std.ArrayList([]const u8).empty;
    var added = std.ArrayList([]const u8).empty;
    var x: usize = 0;
    var y: usize = 0;
    while (x < h.len or y < g.len) {
        if (x < h.len and y < g.len and std.mem.eql(u8, h[x], g[y])) {
            for (removed.items) |l| try ops.append(a, .{ .sign = '-', .line = l });
            for (added.items) |l| try ops.append(a, .{ .sign = '+', .line = l });
            removed.clearRetainingCapacity();
            added.clearRetainingCapacity();
            x += 1;
            y += 1;
        } else if (x < h.len and (y >= g.len or lcs[(x + 1) * w + y] >= lcs[x * w + y + 1])) {
            try removed.append(a, h[x]);
            x += 1;
        } else {
            try added.append(a, g[y]);
            y += 1;
        }
    }
    for (removed.items) |l| try ops.append(a, .{ .sign = '-', .line = l });
    for (added.items) |l| try ops.append(a, .{ .sign = '+', .line = l });
    return ops.toOwnedSlice(a);
}

/// What the script showed of a diff: the changed lines whose text does not
/// begin with `-` or `+` (a line with no text is not shown), the first `max`.
pub fn shown(a: std.mem.Allocator, ops: []const Op, max: usize) ![][]u8 {
    var out = std.ArrayList([]u8).empty;
    for (ops) |op| {
        if (out.items.len == max) break;
        if (op.line.len == 0 or op.line[0] == '-' or op.line[0] == '+') continue;
        try out.append(a, try std.fmt.allocPrint(a, "{c}{s}", .{ op.sign, op.line }));
    }
    return out.toOwnedSlice(a);
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
    const out = std.fs.File.stdout().deprecatedWriter();
    if (std.mem.eql(u8, got, have)) {
        out.print("third_party_srcs: {s} matches the archive\n", .{have_path}) catch return 2;
        return 0;
    }
    out.print("third_party_srcs: {s} differs from what the archive gives (- committed, + generated):\n", .{have_path}) catch return 2;
    const ops = diffOps(a, lines(a, have) catch return 2, lines(a, got) catch return 2) catch return 2;
    const rows = shown(a, ops, 6) catch return 2;
    for (rows) |r| out.print("{s}\n", .{r}) catch return 2;
    out.print("regenerate: {s}\n", .{regen}) catch return 2;
    return 1;
}

// ---- srcs-gen ---------------------------------------------------------------

/// Decompresses the gzip file `src` to `dst`.
pub fn gunzip(dir: std.fs.Dir, src: []const u8, dst: []const u8) !void {
    const in = try dir.openFile(src, .{});
    defer in.close();
    const out = try dir.createFile(dst, .{});
    defer out.close();
    // Whole file inflated with no window buffer: the standard library's windowed
    // decoder mishandles a fixed-Huffman match at the end of its window.
    const a = std.heap.page_allocator;
    const gz = try in.readToEndAlloc(a, 1 << 31);
    defer a.free(gz);
    var gz_in: std.Io.Reader = .fixed(gz);
    var dec = std.compress.flate.Decompress.init(&gz_in, .gzip, &.{});
    var buf: [65536]u8 = undefined;
    var fw = out.writer(&buf);
    _ = dec.reader.streamRemaining(&fw.interface) catch |e| return switch (e) {
        error.ReadFailed => dec.err orelse e,
        error.WriteFailed => fw.err orelse e,
    };
    try fw.interface.flush();
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
    const size = (std.fs.cwd().statFile(archive) catch |e| return usage("cannot stat {s}: {s}", .{ archive, @errorName(e) })).size;
    const size_text = std.fmt.allocPrint(a, "{d}", .{size}) catch return 2;
    var child = std.process.Child.init(&.{ gen_abs, library, tar, out, gen_label, drift_label, committed, size_text }, a);
    const term = child.spawnAndWait() catch |e| return usage("cannot run {s}: {s}", .{ gen, @errorName(e) });
    return U.exitCodeOf(term);
}

// ---- files-check ------------------------------------------------------------

pub const Table = struct { name: []const u8, values: []const []const u8 };

/// The strings in double quotes on `line`, in order (the generated file escapes none).
fn quotedStrings(a: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, line, i, '"')) |open| {
        const close = std.mem.indexOfScalarPos(u8, line, open + 1, '"') orelse break;
        try out.append(a, line[open + 1 .. close]);
        i = close + 1;
    }
    return out.toOwnedSlice(a);
}

/// The lists and dicts of a generated .bzl file: a line `NAME = [` or `NAME = {`
/// opens one, a line `]` or `}` closes it. A list entry is `    "x",` and gives
/// x; a dict entry is `    "key": "x",` and gives x (the key is a name, not a
/// file). Every other line is not read.
pub fn parseTables(a: std.mem.Allocator, text: []const u8) ![]const Table {
    var tables = std.ArrayList(Table).empty;
    var values = std.ArrayList([]const u8).empty;
    var name: ?[]const u8 = null;
    var dict = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (name) |n| {
            if (std.mem.eql(u8, line, "]") or std.mem.eql(u8, line, "}")) {
                try tables.append(a, .{ .name = n, .values = try values.toOwnedSlice(a) });
                values = .empty;
                name = null;
                continue;
            }
            const qs = try quotedStrings(a, line);
            const want: usize = if (dict) 2 else 1;
            if (qs.len >= want) try values.append(a, qs[want - 1]);
            continue;
        }
        const open_list = std.mem.endsWith(u8, line, " = [");
        if (open_list or std.mem.endsWith(u8, line, " = {")) {
            name = line[0 .. line.len - 4];
            dict = !open_list;
        }
    }
    if (name != null) return error.UnclosedTable;
    return tables.toOwnedSlice(a);
}

/// The regular files of the tar `bytes`, each below the archive's top
/// directory (which is dropped), in archive order.
pub fn archiveFiles(a: std.mem.Allocator, bytes: []const u8) ![]const []const u8 {
    var reader: std.Io.Reader = .fixed(bytes);
    var name_buf: [4096]u8 = undefined;
    var link_buf: [4096]u8 = undefined;
    var it = std.tar.Iterator.init(&reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    var out = std.ArrayList([]const u8).empty;
    while (try it.next()) |f| {
        if (f.kind != .file) continue;
        const slash = std.mem.indexOfScalar(u8, f.name, '/') orelse continue;
        try out.append(a, try a.dupe(u8, f.name[slash + 1 ..]));
    }
    return out.toOwnedSlice(a);
}

fn holdsFile(archive: []const []const u8, dir: []const u8) bool {
    if (std.mem.eql(u8, dir, ".")) return archive.len > 0;
    for (archive) |f| {
        if (f.len > dir.len and f[dir.len] == '/' and std.mem.startsWith(u8, f, dir)) return true;
    }
    return false;
}

/// What is wrong with the files.bzl `text` against the files of the archive
/// (see the header of this file); empty when nothing is.
pub fn filesProblems(a: std.mem.Allocator, text: []const u8, archive: []const []const u8, require: []const []const u8) ![]const []const u8 {
    var have = std.StringHashMap(void).init(a);
    for (archive) |n| try have.put(n, {});
    const tables = try parseTables(a, text);
    var out = std.ArrayList([]const u8).empty;
    var in_files = std.StringHashMap(void).init(a);
    var has_files = false;
    for (tables) |t| {
        if (!std.mem.eql(u8, t.name, "FILES")) continue;
        has_files = true;
        for (t.values, 0..) |v, i| {
            try in_files.put(v, {});
            if (i > 0 and !std.mem.lessThan(u8, t.values[i - 1], v)) {
                try out.append(a, try std.fmt.allocPrint(a, "FILES: {s} follows {s}; the list is sorted with no duplicate", .{ v, t.values[i - 1] }));
            }
        }
    }
    if (!has_files) try out.append(a, "there is no FILES list");
    for (tables) |t| {
        const dirs = std.mem.endsWith(u8, t.name, "INCLUDES");
        for (t.values) |v| {
            if (dirs) {
                if (!holdsFile(archive, v)) try out.append(a, try std.fmt.allocPrint(a, "{s}: {s} holds no file of the archive", .{ t.name, v }));
            } else if (!have.contains(v)) {
                try out.append(a, try std.fmt.allocPrint(a, "{s}: {s} is not in the archive", .{ t.name, v }));
            } else if (has_files and !in_files.contains(v)) {
                try out.append(a, try std.fmt.allocPrint(a, "{s}: {s} is not in FILES", .{ t.name, v }));
            }
        }
    }
    for (require) |r| {
        var found = false;
        for (tables) |t| {
            if (!std.mem.eql(u8, t.name, r)) continue;
            found = true;
            if (t.values.len == 0) try out.append(a, try std.fmt.allocPrint(a, "{s} is required and is empty", .{r}));
        }
        if (!found) try out.append(a, try std.fmt.allocPrint(a, "{s} is required and is not in the file", .{r}));
    }
    return out.toOwnedSlice(a);
}

fn cmdFilesCheck(a: std.mem.Allocator, args: []const []const u8) u8 {
    const spec = [_]U.Spec{ .{ .name = "archive" }, .{ .name = "files" }, .{ .name = "regenerate" }, .{ .name = "require" } };
    var bad: []const u8 = "";
    const f = U.parseFlags(a, args, &spec, &bad) catch |e| return usage("files-check: {s}: {s}", .{ @errorName(e), bad });
    const archive = f.need("archive") catch return usage("files-check needs --archive", .{});
    const files = f.need("files") catch return usage("files-check needs --files", .{});
    const regenerate = f.need("regenerate") catch return usage("files-check needs --regenerate", .{});
    var require = std.ArrayList([]const u8).empty;
    for (f.all(a, "require") catch return 2) |it| require.append(a, it.vals[0]) catch return 2;

    const cwd = std.fs.cwd().realpathAlloc(a, ".") catch return 2;
    const scratch = U.scratchRoot(a, cwd, std.posix.getenv("BUCK_SCRATCH_PATH")) catch return 2;
    std.fs.cwd().makePath(scratch) catch |e| return usage("cannot create {s}: {s}", .{ scratch, @errorName(e) });
    defer std.fs.cwd().deleteTree(scratch) catch {};
    const tar = std.fs.path.join(a, &.{ scratch, "archive.tar" }) catch return 2;
    gunzip(std.fs.cwd(), archive, tar) catch |e| {
        std.debug.print("gzip: {s}: {s}\n", .{ archive, @errorName(e) });
        return 1;
    };
    const tar_bytes = std.fs.cwd().readFileAlloc(a, tar, 1 << 31) catch |e| return usage("cannot read {s}: {s}", .{ tar, @errorName(e) });
    const names = archiveFiles(a, tar_bytes) catch |e| return usage("cannot read {s}: {s}", .{ archive, @errorName(e) });
    const text = std.fs.cwd().readFileAlloc(a, files, 1 << 28) catch |e| return usage("cannot read {s}: {s}", .{ files, @errorName(e) });
    const problems = filesProblems(a, text, names, require.items) catch |e| return usage("cannot read {s}: {s}", .{ files, @errorName(e) });
    if (problems.len == 0) {
        std.debug.print("third_party_srcs: {s} names only files of the archive ({d} files)\n", .{ files, names.len });
        return 0;
    }
    std.debug.print("third_party_srcs: {s} disagrees with the archive ({d} problems; first {d}):\n", .{ files, problems.len, @min(problems.len, 10) });
    for (problems[0..@min(problems.len, 10)]) |p| std.debug.print("  {s}\n", .{p});
    std.debug.print("regenerate: {s}\n", .{regenerate});
    return 1;
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
    if (argv.len < 2) std.process.exit(usage("usage: third_party_act (srcs-gen|drift|files-check|botocore-model) ...", .{}));
    const plain = a.alloc([]const u8, argv.len - 2) catch std.process.exit(2);
    for (argv[2..], 0..) |s, i| plain[i] = s;
    const sub = argv[1];
    const rc: u8 = if (std.mem.eql(u8, sub, "srcs-gen"))
        cmdSrcsGen(a, plain)
    else if (std.mem.eql(u8, sub, "drift"))
        cmdDrift(a, plain)
    else if (std.mem.eql(u8, sub, "files-check"))
        cmdFilesCheck(a, plain)
    else if (std.mem.eql(u8, sub, "botocore-model"))
        cmdBotocore(a, plain)
    else
        usage("unknown subcommand {s}", .{sub});
    if (rc != 0) std.process.exit(rc);
}
