// Why Zig: build tools are Zig (tools/build/README.md): the regeneration verb is
// repeated tooling, so it is a program, not a script.
//! regen: regenerate the committed generated sources of a library.
//!
//!   buck2 run komira//tools/build/gen:regen -- [--buck2 <path>] <target>...
//!
//! A <target> is a generated library (`komira//src/komira_aws_sqs:komira_aws_sqs`),
//! a package (`komira//src/komira_gcp_firestore:`, every generated library of it),
//! or `all` (every one in the cell `komira`; the cell `tests` and the libraries still
//! in the transition ledger have to be named, and a ledger library has to leave the
//! ledger first). For each library regen
//!
//!   1. asks buck2 for its `<name>_fresh` target (tools/build/gen/defs.bzl), which
//!      names the library's generation target and its committed directory;
//!   2. builds the generation targets, all of them in one build, through whatever
//!      the checkout is configured for (the farm); and
//!   3. makes each committed directory what the generator wrote: files that differ
//!      are written, files that are no longer generated are removed, files that are
//!      the same are not touched. Sorted, no timestamps, no mode but 0644: a second
//!      run changes nothing.
//!
//! The library's `<name>_fresh` check is the other half: it fails when the committed
//! directory is not what step 3 would leave, and prints this command.
//!
//! Exit status: 0; 1 when buck2 failed or a target names no generated library; 2
//! for a usage error or a failure of the tool's own.

const std = @import("std");
const U = @import("act_util");

const prog = "regen";

/// The kind of the rule `<name>_fresh` is (tools/build/gen/defs.bzl).
pub const fresh_kind = "gen_fresh";

/// What `sync` did to a directory.
pub const Summary = struct {
    wrote: usize = 0,
    removed: usize = 0,
    unchanged: usize = 0,
};

/// Makes `dst` hold exactly the files of `src` (regular files, subdirectories
/// included), byte for byte: a file whose bytes differ or that is missing is
/// written, a file `src` does not have is removed (and a directory it leaves
/// empty), a file already equal is not touched.
pub fn sync(a: std.mem.Allocator, src: std.fs.Dir, dst: std.fs.Dir) !Summary {
    var sum = Summary{};
    const want = try U.listFiles(a, src, true);
    const have = try U.listFiles(a, dst, false);
    var keep = std.StringHashMap(void).init(a);
    for (want) |n| try keep.put(n, {});
    for (have) |n| {
        if (keep.contains(n)) continue;
        try dst.deleteFile(n);
        sum.removed += 1;
    }
    for (want) |n| {
        const data = try U.readAll(a, src, n);
        const same = blk: {
            const old = dst.readFileAlloc(a, n, 1 << 30) catch break :blk false;
            break :blk std.mem.eql(u8, old, data);
        };
        if (same) {
            sum.unchanged += 1;
            continue;
        }
        try U.makeParent(dst, n);
        const f = try dst.createFile(n, .{ .mode = 0o644 });
        defer f.close();
        try f.writeAll(data);
        sum.wrote += 1;
    }
    try removeEmptyDirs(a, dst);
    return sum;
}

/// Removes every directory under `dir` that holds no file, deepest first.
fn removeEmptyDirs(a: std.mem.Allocator, dir: std.fs.Dir) !void {
    const names = try U.listNames(a, dir);
    for (names) |n| {
        const st = dir.statFile(n) catch continue;
        if (st.kind != .directory) continue;
        var sub = try dir.openDir(n, .{ .iterate = true });
        try removeEmptyDirs(a, sub);
        const left = try U.listNames(a, sub);
        sub.close();
        if (left.len == 0) try dir.deleteDir(n);
    }
}

/// One library to regenerate: where its generation target's output goes.
pub const Job = struct {
    /// The `<name>_fresh` label, for messages.
    fresh: []const u8,
    /// The generation target (`<name>_gen`).
    gen: []const u8,
    /// The committed directory, as a path from the root of the cell holding
    /// the package: the package, then `committed_dir`.
    dest: []const u8,
    /// The cell of the package.
    cell: []const u8,
};

/// What the query patterns for `arg` are: `all` is every `gen_fresh` of the cell
/// `komira`; a package pattern (`cell//path:`) is itself; a library label is its
/// `_fresh` target.
pub fn patternOf(a: std.mem.Allocator, arg: []const u8) ![]const u8 {
    if (std.mem.eql(u8, arg, "all")) return "komira//...";
    if (std.mem.endsWith(u8, arg, ":") or std.mem.endsWith(u8, arg, "...")) return arg;
    if (std.mem.indexOf(u8, arg, "//") == null or std.mem.indexOfScalar(u8, arg, ':') == null) return error.NotALabel;
    return std.fmt.allocPrint(a, "{s}_fresh", .{arg});
}

/// The cell of a label (`komira` of `komira//src/x:x`).
fn cellOf(label: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, label, "//") orelse return "";
    return label[0..at];
}

/// The package path of a label (`src/x` of `komira//src/x:x`).
fn packageOf(label: []const u8) []const u8 {
    const at = (std.mem.indexOf(u8, label, "//") orelse return "") + 2;
    const colon = std.mem.indexOfScalarPos(u8, label, at, ':') orelse label.len;
    return label[at..colon];
}

/// The jobs in the JSON of `buck2 uquery --json -a committed_dir -a gen`: an
/// object of label to attributes. Sorted by label.
pub fn parseJobs(a: std.mem.Allocator, json: []const u8) ![]Job {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    if (parsed != .object) return error.BadQueryResult;
    var jobs = std.ArrayList(Job).empty;
    var it = parsed.object.iterator();
    while (it.next()) |e| {
        const label = e.key_ptr.*;
        if (e.value_ptr.* != .object) return error.BadQueryResult;
        const attrs = e.value_ptr.object;
        const dir = attrs.get("committed_dir") orelse return error.BadQueryResult;
        const gen = attrs.get("gen") orelse return error.BadQueryResult;
        if (dir != .string or gen != .string) return error.BadQueryResult;
        const pkg = packageOf(label);
        const dest = if (pkg.len == 0) dir.string else try std.fmt.allocPrint(a, "{s}/{s}", .{ pkg, dir.string });
        try jobs.append(a, .{ .fresh = label, .gen = gen.string, .dest = dest, .cell = cellOf(label) });
    }
    std.mem.sort(Job, jobs.items, {}, struct {
        fn less(_: void, x: Job, y: Job) bool {
            return std.mem.lessThan(u8, x.fresh, y.fresh);
        }
    }.less);
    return jobs.items;
}

/// The `label path` lines of `buck2 build --show-full-output`: the path of `label`.
pub fn outputOf(text: []const u8, label: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        if (std.mem.startsWith(u8, l, label) and l.len > label.len and l[label.len] == ' ') {
            return std.mem.trim(u8, l[label.len + 1 ..], " \r");
        }
    }
    return null;
}

fn usage(comptime fmt: []const u8, args: anytype) u8 {
    std.debug.print(prog ++ ": " ++ fmt ++ "\n", args);
    return 2;
}

/// The checkout's `buck2`: the file of that name beside the nearest `.buckconfig`
/// above the current directory, else `buck2` from the path.
fn findBuck2(a: std.mem.Allocator) ![]const u8 {
    var dir: []const u8 = try std.fs.cwd().realpathAlloc(a, ".");
    while (true) {
        const cfg = try std.fs.path.join(a, &.{ dir, ".buckconfig" });
        if (std.fs.cwd().access(cfg, .{})) |_| {
            const cand = try std.fs.path.join(a, &.{ dir, "buck2" });
            if (std.fs.cwd().access(cand, .{})) |_| return cand else |_| {}
        } else |_| {}
        dir = std.fs.path.dirname(dir) orelse return "buck2";
    }
}

/// Runs buck2 with `argv` (its stderr, the build's progress, passes through) and
/// returns its standard output; null when it failed.
fn buck(a: std.mem.Allocator, buck2: []const u8, argv: []const []const u8) !?[]u8 {
    var full = std.ArrayList([]const u8).empty;
    try full.append(a, buck2);
    try full.appendSlice(a, argv);
    var child = std.process.Child.init(full.items, a);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    var out = std.ArrayList(u8).empty;
    const f = child.stdout.?;
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = try f.read(&buf);
        if (n == 0) break;
        try out.appendSlice(a, buf[0..n]);
    }
    const term = try child.wait();
    if (U.exitCodeOf(term) != 0) return null;
    return out.items;
}

fn run(a: std.mem.Allocator, buck2: []const u8, args: []const []const u8) u8 {
    var patterns = std.ArrayList([]const u8).empty;
    for (args) |arg| {
        const p = patternOf(a, arg) catch return usage("`{s}` is not a target label (`cell//package:name`), a package (`cell//package:`) or `all`", .{arg});
        patterns.append(a, p) catch return 2;
    }
    var all_jobs = std.ArrayList(Job).empty;
    for (patterns.items, args) |p, arg| {
        const query = std.fmt.allocPrint(a, "kind('^{s}$', {s})", .{ fresh_kind, p }) catch return 2;
        const out = (buck(a, buck2, &.{ "uquery", "--json", "-a", "committed_dir", "-a", "gen", query }) catch return usage("cannot run {s}", .{buck2})) orelse return 1;
        const jobs = parseJobs(a, out) catch |e| return usage("cannot read the result of the query {s}: {s}", .{ query, @errorName(e) });
        if (jobs.len == 0) {
            std.debug.print(prog ++ ": {s} names no generated library with committed sources: either it is not a generated library, or it is still in the transition ledger (tools/build/gen/transition.bzl), whose entries are built from the generator on every build and have no committed directory; take it out of the ledger, then run this again\n", .{arg});
            return 1;
        }
        all_jobs.appendSlice(a, jobs) catch return 2;
    }

    // One build for every generation target.
    var build = std.ArrayList([]const u8).empty;
    build.appendSlice(a, &.{ "build", "--show-full-output" }) catch return 2;
    for (all_jobs.items) |j| build.append(a, j.gen) catch return 2;
    const built = (buck(a, buck2, build.items) catch return usage("cannot run {s}", .{buck2})) orelse return 1;

    for (all_jobs.items) |j| {
        const gen_path = outputOf(built, j.gen) orelse return usage("buck2 printed no output path for {s}", .{j.gen});
        const root_out = (buck(a, buck2, &.{ "audit", "cell", "--paths-only", j.cell }) catch return usage("cannot run {s}", .{buck2})) orelse return 1;
        const root = std.mem.trim(u8, root_out, " \r\n");
        const dest = std.fs.path.join(a, &.{ root, j.dest }) catch return 2;
        var src = std.fs.openDirAbsolute(gen_path, .{ .iterate = true }) catch |e| return usage("cannot open the output of {s} ({s}): {s}", .{ j.gen, gen_path, @errorName(e) });
        defer src.close();
        std.fs.cwd().makePath(dest) catch |e| return usage("cannot create {s}: {s}", .{ dest, @errorName(e) });
        var dst = std.fs.openDirAbsolute(dest, .{ .iterate = true }) catch |e| return usage("cannot open {s}: {s}", .{ dest, @errorName(e) });
        defer dst.close();
        const sum = sync(a, src, dst) catch |e| return usage("cannot update {s}: {s}", .{ dest, @errorName(e) });
        std.debug.print("{s}: {s}/: wrote {d}, removed {d}, unchanged {d}\n", .{ j.fresh, j.dest, sum.wrote, sum.removed, sum.unchanged });
    }
    return 0;
}

pub fn main() void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = std.process.argsAlloc(a) catch std.process.exit(2);
    var buck2: ?[]const u8 = null;
    var targets = std.ArrayList([]const u8).empty;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--buck2")) {
            i += 1;
            if (i >= argv.len) std.process.exit(usage("--buck2 needs a path", .{}));
            buck2 = argv[i];
        } else if (std.mem.startsWith(u8, argv[i], "--")) {
            std.process.exit(usage("unknown flag {s}", .{argv[i]}));
        } else {
            targets.append(a, argv[i]) catch std.process.exit(2);
        }
    }
    if (targets.items.len == 0) std.process.exit(usage("usage: regen [--buck2 <path>] <target|package:|all>...", .{}));
    const b = buck2 orelse findBuck2(a) catch std.process.exit(2);
    const rc = run(a, b, targets.items);
    if (rc != 0) std.process.exit(rc);
}
