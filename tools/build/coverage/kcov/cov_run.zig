// Why Zig: build tools are Zig (tools/build/README.md). This replaces
// cov_run.sh (a 400-line busybox shell script: strings, grep, sed, awk, cp,
// find), so that a coverage run runs no shell.
//! cov_run: runs one welded test's coverage binary under kcov in a build
//! action (`mojo_cov_run`, tools/build/mojo/coverage.bzl), through the release
//! gate's runner (its environment, with the differences below), and writes the
//! test's report in repository paths (README.md, "cov_run").
//!
//! usage: <run_dir>/cov_run <busybox> <gate> <compiler_dir> <label>
//!            <test_binary> <share> <src_dir> <xml_out> <marker_out>
//!            <src_repo> <test> <test_repo> <import> [--solib <file> [--solib-src <path>]...]
//!            [--gen <file>]... [--env NAME=VALUE]...
//!
//!   <run_dir>      the cov_run_dir: this program, kcov/ (bin/kcov, lib/),
//!                  cov_normalize and limit (the seconds the run may take: 450,
//!                  or a tests cell fixture's own)
//!   <test_binary>  the test built at -O0 with line tables ([coverage][bin][<test>])
//!   <share>        the test's declared data at their destinations, and its
//!                  source at <test>, its path in the package (what the line
//!                  tables name it by: `tests/test_x.mojo`)
//!   <src_dir>      the library's staged sources ([src]), a directory ending in
//!                  src/<import>: the package is compiled from its parent, so the
//!                  line tables name them `<import>/<file>`
//!   <src_repo>     the repository directory <src_dir> stages, with a trailing
//!                  `/` (empty for the repository's root)
//!   <test_repo>    the repository path of the test source
//!   <import>       the library's import name: the run stages the sources at
//!                  <import>/ (the directory the line tables name them by; with
//!                  --solib, at <src_dir>)
//!   --solib        the test is a shared library's driver (a mojo_shared_lib's
//!                  gate_srcs entry): <file> is the library's coverage build in
//!                  <share>, which the driver loads; kcov measures the libraries
//!                  the driver loads
//!   --solib-src    a source of that library, by its path in the package (which is
//!                  how the library's line tables name it), at that path in
//!                  <share>: measured, and mapped to the package's repository
//!                  directory; the report must hold the first. --solib with none
//!                  (every source generated) is refused
//!   --gen <file>   a generated source in <src_dir> (its path there): not measured
//!   <gate>         the gate (tools/build/run), which runs kcov as `gate mojo`
//!   --env          passed to the gate as given
//!
//! Steps (the numbers are the old script's, and README.md's):
//!   0. The binary must name the library's sources by <import>/, where the run
//!      stages them: kcov drops a file it cannot open without an error. It is
//!      refused when it names a [src] of the library (a string holding
//!      `buck-out/` and, inside an artifact, the path component src/<import>),
//!      and when it holds the library's code (a string with `<import>::`) but no
//!      whole string `<import>` or `<import>/...`.
//!   1. A root of COPIES (never links: kcov resolves every source name with
//!      realpath): bin/kcov and lib/, bin/<test>, share/ (the test's data, its
//!      source at <test> and the library's sources at <import>/) and lost/, a
//!      second copy of the sources where a name that does not resolve lands. Each
//!      generated source (--gen) is moved to gen/ and linked from both.
//!   2. `gate mojo` runs bin/kcov as the program of the test root, bounded by
//!      the limit (the gate kills the session and prints COVERAGE RUN FAILED).
//!      kcov exits with the test's status.
//!   3. kcov writes exactly one report (<out>/cov.xml).
//!   4. cov_normalize maps the paths to the repository's, requires the test's own
//!      source in the report (and the first --solib-src) and refuses the
//!      action's directories in the output. Its output is <xml_out>; then
//!      `PASS <label>` goes to <marker_out>.
//!
//! Exit status: the test's under kcov when it fails (the gate's); 1 when the
//! binary names the sources elsewhere, a kcov argument is too long, the run
//! passed its limit, or the report is missing or refused; 2 for a usage error,
//! which includes a `,` or `:` in a path given to kcov (its options split on them).

const std = @import("std");

pub const kcov_arg_max = 2047;

pub const Args = struct {
    busybox: []const u8,
    gate: []const u8,
    compiler: []const u8,
    label: []const u8,
    binary: []const u8,
    share: []const u8,
    src_rel: []const u8,
    xml: []const u8,
    marker: []const u8,
    src_repo: []const u8,
    test_: []const u8,
    test_repo: []const u8,
    import: []const u8,
    solib: ?[]const u8,
    solib_srcs: []const []const u8,
    gen: []const []const u8,
    /// What is left, for the gate: `--env NAME=VALUE`...
    rest: []const []const u8,
};

pub const UsageError = error{Usage};

fn relativeFile(p: []const u8) bool {
    return p.len > 0 and p[0] != '/' and p[p.len - 1] != '/';
}

fn hasAny(s: []const u8, set: []const u8) bool {
    return std.mem.indexOfAny(u8, s, set) != null;
}

/// The arguments after the program name. On `error.Usage`, `diag` says what is wrong.
pub fn parse(a: std.mem.Allocator, argv: []const []const u8, diag: *[]const u8) (UsageError || std.mem.Allocator.Error)!Args {
    if (argv.len < 13) {
        diag.* = "usage error";
        return error.Usage;
    }
    var r = Args{
        .busybox = argv[0], .gate = argv[1], .compiler = argv[2], .label = argv[3], .binary = argv[4], .share = argv[5],
        .src_rel = argv[6], .xml = argv[7], .marker = argv[8], .src_repo = argv[9], .test_ = argv[10], .test_repo = argv[11],
        .import = argv[12], .solib = null, .solib_srcs = &.{}, .gen = &.{}, .rest = &.{},
    };
    if (!relativeFile(r.src_rel)) {
        diag.* = try std.fmt.allocPrint(a, "<src_dir> {s} must be a relative path from the action's directory", .{r.src_rel});
        return error.Usage;
    }
    if (!relativeFile(r.test_)) {
        diag.* = try std.fmt.allocPrint(a, "<test> {s} must be a relative file path", .{r.test_});
        return error.Usage;
    }
    if (!relativeFile(r.test_repo)) {
        diag.* = try std.fmt.allocPrint(a, "<test_repo> {s} must be a relative file path", .{r.test_repo});
        return error.Usage;
    }
    // <src_repo>: empty, or relative with a trailing /.
    if (r.src_repo.len > 0 and (r.src_repo[0] == '/' or r.src_repo[r.src_repo.len - 1] != '/')) {
        diag.* = try std.fmt.allocPrint(a, "<src_repo> {s} must be empty or relative with a trailing /", .{r.src_repo});
        return error.Usage;
    }
    if (r.import.len == 0) {
        diag.* = try std.fmt.allocPrint(a, "<import> {s} is not an import name", .{r.import});
        return error.Usage;
    }
    for (r.import) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) {
            diag.* = try std.fmt.allocPrint(a, "<import> {s} is not an import name", .{r.import});
            return error.Usage;
        }
    }
    const want = try std.fmt.allocPrint(a, "src/{s}", .{r.import});
    const ok = std.mem.endsWith(u8, r.src_rel, try std.fmt.allocPrint(a, "/{s}", .{want}));
    if (!ok) {
        diag.* = try std.fmt.allocPrint(a, "<src_dir> {s} does not end in src/{s}", .{ r.src_rel, r.import });
        return error.Usage;
    }

    var i: usize = 13;
    if (i < argv.len and std.mem.eql(u8, argv[i], "--solib")) {
        if (i + 1 >= argv.len) {
            diag.* = "--solib needs a file";
            return error.Usage;
        }
        if (!relativeFile(argv[i + 1])) {
            diag.* = try std.fmt.allocPrint(a, "--solib {s} must be a relative file path", .{argv[i + 1]});
            return error.Usage;
        }
        r.solib = argv[i + 1];
        i += 2;
        var srcs = std.ArrayList([]const u8).empty;
        while (i < argv.len and std.mem.eql(u8, argv[i], "--solib-src")) {
            if (i + 1 >= argv.len) {
                diag.* = "--solib-src needs a path";
                return error.Usage;
            }
            const p = argv[i + 1];
            if (!relativeFile(p) or std.mem.startsWith(u8, p, "buck-out/") or hasAny(p, ",: ")) {
                diag.* = try std.fmt.allocPrint(a, "--solib-src {s} must be a relative file path outside buck-out/ without a space, , or :", .{p});
                return error.Usage;
            }
            try srcs.append(a, p);
            i += 2;
        }
        r.solib_srcs = try srcs.toOwnedSlice(a);
    }
    // The package's repository directory, for --solib: <test_repo> is it then <test>.
    if (r.solib != null and pkgRepo(r.test_repo, r.test_) == null) {
        diag.* = try std.fmt.allocPrint(a, "with --solib, <test_repo> {s} must be a directory then <test> {s}", .{ r.test_repo, r.test_ });
        return error.Usage;
    }
    var gens = std.ArrayList([]const u8).empty;
    while (i < argv.len and std.mem.eql(u8, argv[i], "--gen")) {
        if (i + 1 >= argv.len) {
            diag.* = "--gen needs a file";
            return error.Usage;
        }
        const p = argv[i + 1];
        if (p.len == 0 or p[0] == '/' or hasAny(p, ",: ")) {
            diag.* = try std.fmt.allocPrint(a, "--gen {s} must be a relative path without a space, , or :", .{p});
            return error.Usage;
        }
        try gens.append(a, p);
        i += 2;
    }
    r.gen = try gens.toOwnedSlice(a);
    r.rest = argv[i..];
    return r;
}

/// The package's repository directory ("" or ending in `/`) when `test_repo` is
/// `test` or `<dir>/test`; null otherwise.
pub fn pkgRepo(test_repo: []const u8, test_: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, test_repo, test_)) return "";
    if (test_repo.len > test_.len and std.mem.endsWith(u8, test_repo, test_) and test_repo[test_repo.len - test_.len - 1] == '/')
        return test_repo[0 .. test_repo.len - test_.len];
    return null;
}

/// The directory part of a path with its trailing `/`, or "".
pub fn dirPart(p: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| p[0 .. i + 1] else "";
}

/// The seconds in the limit file: digits, not empty, not starting with 0.
pub fn parseLimit(text: []const u8) ?[]const u8 {
    const t = std.mem.trimRight(u8, text, "\n");
    if (t.len == 0 or t[0] == '0') return null;
    for (t) |c| {
        if (c < '0' or c > '9') return null;
    }
    return t;
}

// ---- step 0: the names a binary holds -------------------------------------------------

fn printable(c: u8) bool {
    return (c >= 0x20 and c < 0x7f) or c == '\t';
}

/// The runs of printable bytes of `data` (`strings -n 1`).
pub fn strings(a: std.mem.Allocator, data: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (i < data.len) {
        if (!printable(data[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < data.len and printable(data[i])) i += 1;
        try out.append(a, data[start..i]);
    }
    return out.toOwnedSlice(a);
}

fn nameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "_./+@=-", c) != null;
}

/// `grep -o -E '[A-Za-z0-9_./+@=-]*buck-out/[A-Za-z0-9_./+@=-]*'` over `lines`: each
/// maximal run of those characters that holds `buck-out/`.
pub fn buckNames(a: std.mem.Allocator, lines: []const []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (lines) |l| {
        var i: usize = 0;
        while (i < l.len) {
            if (!nameChar(l[i])) {
                i += 1;
                continue;
            }
            const start = i;
            while (i < l.len and nameChar(l[i])) i += 1;
            if (std.mem.indexOf(u8, l[start..i], "buck-out/") != null) try out.append(a, l[start..i]);
        }
    }
    return out.toOwnedSlice(a);
}

/// The [src] directories of the library the binary names: of `names`, those with
/// `/__<target>__/` and later `/src/<import>` followed by `/` or the end, each cut
/// after the last such `/src/<import>`; sorted, unique.
pub fn elsewhere(a: std.mem.Allocator, names: []const []const u8, import: []const u8) ![]const []const u8 {
    const needle = try std.fmt.allocPrint(a, "/src/{s}", .{import});
    var out = std.ArrayList([]const u8).empty;
    for (names) |n| {
        // /__[^/]+__/ somewhere, then /src/<import> after it.
        var from: usize = 0;
        var art_end: ?usize = null;
        while (std.mem.indexOfPos(u8, n, from, "/__")) |at| {
            const rest = n[at + 3 ..];
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse break;
            const comp = rest[0..slash];
            if (comp.len >= 3 and std.mem.endsWith(u8, comp, "__")) {
                art_end = at + 3 + slash;
                break;
            }
            from = at + 1;
        }
        const after = art_end orelse continue;
        // The last `/src/<import>` at or after the artifact directory, followed by `/` or the end.
        var cut: ?usize = null;
        var pos: usize = after + 1;
        while (std.mem.indexOfPos(u8, n, pos, needle)) |at| {
            const end = at + needle.len;
            if (end == n.len or n[end] == '/') cut = end;
            pos = at + 1;
        }
        if (cut) |c| try out.append(a, n[0..c]);
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    var uniq = std.ArrayList([]const u8).empty;
    for (out.items) |s| {
        if (uniq.items.len == 0 or !std.mem.eql(u8, uniq.items[uniq.items.len - 1], s)) try uniq.append(a, s);
    }
    return uniq.toOwnedSlice(a);
}

fn wordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Whether some string holds `<import>::` not as the end of a longer word (the start
/// of the name of a function or type of the library).
pub fn holdsCode(lines: []const []const u8, import: []const u8) bool {
    for (lines) |l| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, l, from, import)) |at| {
            from = at + 1;
            const after = at + import.len;
            if (!(after + 1 < l.len and l[after] == ':' and l[after + 1] == ':')) continue;
            if (at > 0 and wordChar(l[at - 1])) continue;
            return true;
        }
    }
    return false;
}

/// The first `<import>::` followed by letters, digits, `_` and `:` that any string
/// holds, or null.
pub fn firstCodeName(lines: []const []const u8, import: []const u8) ?[]const u8 {
    for (lines) |l| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, l, from, import)) |at| {
            from = at + 1;
            const after = at + import.len;
            if (!(after + 1 < l.len and l[after] == ':' and l[after + 1] == ':')) continue;
            var end = after + 2;
            while (end < l.len and (wordChar(l[end]) or l[end] == ':')) end += 1;
            return l[at..end];
        }
    }
    return null;
}

/// Whether some string is exactly `stage` or `stage/...`.
pub fn namesStage(lines: []const []const u8, stage: []const u8) bool {
    for (lines) |l| {
        if (std.mem.eql(u8, l, stage)) return true;
        if (l.len > stage.len and std.mem.startsWith(u8, l, stage) and l[stage.len] == '/') return true;
    }
    return false;
}

// ---- the gate's stderr ------------------------------------------------------------------

/// The gate's stderr with its banner's header pair removed: a line `GATED TEST
/// FAILED: <label> (exit <rc>)` followed by `The library's package is not produced
/// until this test passes.` goes (the release gate's test did not fail: this is the
/// coverage run); a header with another line after it is kept.
pub fn filterGateErr(a: std.mem.Allocator, text: []const u8, label: []const u8, rc: u8) ![]u8 {
    const header = try std.fmt.allocPrint(a, "GATED TEST FAILED: {s} (exit {d})", .{ label, rc });
    const trailer = "The library's package is not produced until this test passes.";
    var out = std.ArrayList(u8).empty;
    var held = false;
    var done = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        if (lines.peek() == null and l.len == 0) break;
        if (!done and !held and std.mem.eql(u8, l, header)) {
            held = true;
            continue;
        }
        if (held and std.mem.eql(u8, l, trailer)) {
            held = false;
            done = true;
            continue;
        }
        if (held) {
            try out.appendSlice(a, header);
            try out.append(a, '\n');
            held = false;
        }
        try out.appendSlice(a, l);
        try out.append(a, '\n');
    }
    return out.toOwnedSlice(a);
}

fn hasLineStarting(text: []const u8, prefixes: []const []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        for (prefixes) |p| {
            if (std.mem.startsWith(u8, l, p)) return true;
        }
    }
    return false;
}

/// Whether kcov's own lines say it could not trace the test (ptrace or personality
/// refused by the executor).
pub fn traceRefused(err: []const u8) bool {
    var lines = std.mem.splitScalar(u8, err, '\n');
    while (lines.next()) |l| {
        if (std.mem.startsWith(u8, l, "Can't set me as ptraced: ") or std.mem.startsWith(u8, l, "Can't set personality: ") or std.mem.startsWith(u8, l, "Can't get personality: ")) return true;
        const p = "Can't attach to ";
        if (std.mem.startsWith(u8, l, p) and l.len > p.len and l[p.len] >= '0' and l[p.len] <= '9') return true;
    }
    return false;
}

/// Why a coverage run's gate exited `rc`, from its stderr.
pub fn failureWhy(a: std.mem.Allocator, err: []const u8, rc: u8) ![]u8 {
    if (traceRefused(err)) return a.dupe(u8, "kcov could not trace the test: this executor refuses ptrace or personality(ADDR_NO_RANDOMIZE) (a seccomp profile), and coverage cannot be measured on it.");
    if (hasLineStarting(err, &.{ "kcov: error: ", "Usage: kcov " })) return a.dupe(u8, "kcov itself failed (its message is above), not the test.");
    return std.fmt.allocPrint(a, "The test failed under kcov (exit {d}). A coverage run builds the test at -O0 and runs it traced; a test that passes in the release gate and fails here fails this action, and is a bug to fix.", .{rc});
}

// ---- copies ------------------------------------------------------------------------------

/// Copies the tree `src` into `dst`, following links (`cp -RL`).
pub fn copyTreeDeref(src: std.fs.Dir, dst: std.fs.Dir) !void {
    var it = src.iterate();
    while (try it.next()) |e| {
        const st = src.statFile(e.name) catch |err| switch (err) {
            error.FileNotFound => continue, // a dangling link
            else => return err,
        };
        switch (st.kind) {
            .directory => {
                dst.makeDir(e.name) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
                var s = try src.openDir(e.name, .{ .iterate = true });
                defer s.close();
                var d = try dst.openDir(e.name, .{ .iterate = true });
                defer d.close();
                try copyTreeDeref(s, d);
            },
            .file => try src.copyFile(e.name, dst, e.name, .{}),
            else => {},
        }
    }
}

// ---- running ---------------------------------------------------------------------------------

pub fn exitCodeOf(term: std.process.Child.Term) u8 {
    return switch (term) {
        .Exited => |c| c,
        .Signal => |s| @truncate(128 +% s),
        else => 1,
    };
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("cov_run: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

/// The failure banner and exit 1.
fn red(label: []const u8, comptime fmt: []const u8, args: anytype) noreturn {
    const msg = std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch "out of memory";
    std.debug.print("==================================================================\nCOVERAGE RUN FAILED: {s}\n{s}\n==================================================================\n", .{ label, msg });
    std.process.exit(1);
}

fn abs(a: std.mem.Allocator, cwd: []const u8, p: []const u8) []u8 {
    return (if (std.fs.path.isAbsolute(p)) a.dupe(u8, p) else std.fs.path.join(a, &.{ cwd, p })) catch die("out of memory", .{});
}

fn mkdirs(path: []const u8) void {
    std.fs.cwd().makePath(path) catch |e| die("cannot create {s}: {s}", .{ path, @errorName(e) });
}

fn copyFileTo(src: []const u8, dst: []const u8) void {
    if (std.fs.path.dirname(dst)) |d| mkdirs(d);
    std.fs.cwd().copyFile(src, std.fs.cwd(), dst, .{}) catch |e| die("cannot copy {s} to {s}: {s}", .{ src, dst, @errorName(e) });
}

fn copyTreeTo(src: []const u8, dst: []const u8) void {
    mkdirs(dst);
    var s = std.fs.cwd().openDir(src, .{ .iterate = true }) catch |e| die("cannot open {s}: {s}", .{ src, @errorName(e) });
    defer s.close();
    var d = std.fs.cwd().openDir(dst, .{ .iterate = true }) catch |e| die("cannot open {s}: {s}", .{ dst, @errorName(e) });
    defer d.close();
    copyTreeDeref(s, d) catch |e| die("cannot copy {s} to {s}: {s}", .{ src, dst, @errorName(e) });
}

fn isFile(path: []const u8) bool {
    const st = std.fs.cwd().statFile(path) catch return false;
    return st.kind == .file;
}

fn isDir(path: []const u8) bool {
    const st = std.fs.cwd().statFile(path) catch return false;
    return st.kind == .directory;
}

fn isSymlink(path: []const u8) bool {
    var buf: [4096]u8 = undefined;
    _ = std.fs.cwd().readLink(path, &buf) catch return false;
    return true;
}

fn realpath(a: std.mem.Allocator, p: []const u8) []u8 {
    return std.fs.cwd().realpathAlloc(a, p) catch |e| die("cannot resolve {s}: {s}", .{ p, @errorName(e) });
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    var diag: []const u8 = "";
    const args = parse(a, argv[1..], &diag) catch die("{s}", .{diag});
    const cwd = try std.fs.cwd().realpathAlloc(a, ".");
    const here = std.fs.path.dirname(try std.fs.selfExePathAlloc(a)) orelse ".";
    const bb = abs(a, cwd, args.busybox);
    const gate = abs(a, cwd, args.gate);
    const bin = abs(a, cwd, args.binary);
    const share = abs(a, cwd, args.share);
    const xml = abs(a, cwd, args.xml);
    const marker = abs(a, cwd, args.marker);
    const src = abs(a, cwd, args.src_rel);
    const label = args.label;

    const limit_path = try std.fs.path.join(a, &.{ here, "limit" });
    const limit_text = std.fs.cwd().readFileAlloc(a, limit_path, 4096) catch |e| die("cannot read {s}: {s}", .{ limit_path, @errorName(e) });
    const limit = parseLimit(limit_text) orelse die("{s} holds '{s}', not a number of seconds", .{ limit_path, std.mem.trimRight(u8, limit_text, "\n") });
    const test_dir = dirPart(args.test_);
    const test_repo_dir = dirPart(args.test_repo);
    const pkg_repo: []const u8 = if (args.solib != null) pkgRepo(args.test_repo, args.test_).? else "";
    // Where the run stages the library's sources: a shared library's driver names none of
    // <src_dir>, so it is staged at its own path then, out of their way.
    const stage: []const u8 = if (args.solib != null) args.src_rel else args.import;

    const env_scratch = std.process.getEnvVarOwned(a, "BUCK_SCRATCH_PATH") catch "";
    const k = if (env_scratch.len == 0)
        try std.fs.path.join(a, &.{ cwd, ".cov_run" })
    else if (std.fs.path.isAbsolute(env_scratch))
        try std.fs.path.join(a, &.{ env_scratch, "cov_run" })
    else
        try std.fs.path.join(a, &.{ cwd, env_scratch, "cov_run" });
    const k_bin = try std.fs.path.join(a, &.{ k, "bin" });
    mkdirs(k_bin);
    var env = try std.process.getEnvMap(a);
    {
        var install = std.process.Child.init(&.{ bb, "--install", "-s", k_bin }, a);
        install.env_map = &env;
        const installed = install.spawnAndWait() catch |e| die("cannot run {s}: {s}", .{ bb, @errorName(e) });
        if (exitCodeOf(installed) != 0) die("{s} --install -s {s} failed", .{ bb, k_bin });
    }
    try env.put("PATH", k_bin);

    if (args.solib != null and args.solib_srcs.len == 0)
        red(label, "cov_run: --solib with no --solib-src: every source of the shared library {s} is generated, so none is measured and whether kcov measured the library cannot be checked; its drivers have no coverage run.", .{args.solib.?});

    // 0. Where the binary names the library's sources.
    const data = std.fs.cwd().readFileAlloc(a, bin, 1 << 31) catch |e| die("cannot read {s}: {s}", .{ bin, @errorName(e) });
    const lines = try strings(a, data);
    const names = try buckNames(a, lines);
    const wrong = try elsewhere(a, names, args.import);
    if (wrong.len > 0) {
        var joined = std.ArrayList(u8).empty;
        for (wrong) |w| {
            try joined.appendSlice(a, w);
            try joined.append(a, ' ');
        }
        red(label, "the test binary names the library's sources by {s}but this run stages them at {s}/: kcov would drop them without an error (README.md, \"cov_run\").", .{ joined.items, stage });
    }
    if (holdsCode(lines, args.import) and !namesStage(lines, stage)) {
        const code = firstCodeName(lines, args.import) orelse args.import;
        red(label, "the test binary holds code of the library ({s}) but names none of its sources by {s}/, where this run stages them: kcov would drop them without an error (README.md, \"cov_run\").", .{ code, stage });
    }

    // 1. The root and lost/, all copies.
    const r0 = try std.fs.path.join(a, &.{ k, "root" });
    const l0 = try std.fs.path.join(a, &.{ k, "lost" });
    for ([_][]const u8{ "bin", "lib", "share" }) |sub| mkdirs(try std.fs.path.join(a, &.{ r0, sub }));
    const name = std.fs.path.basename(bin);
    copyFileTo(try std.fs.path.join(a, &.{ here, "kcov", "bin", "kcov" }), try std.fs.path.join(a, &.{ r0, "bin", "kcov" }));
    copyTreeTo(try std.fs.path.join(a, &.{ here, "kcov", "lib" }), try std.fs.path.join(a, &.{ r0, "lib" }));
    copyFileTo(bin, try std.fs.path.join(a, &.{ r0, "bin", name }));
    copyTreeTo(share, try std.fs.path.join(a, &.{ r0, "share" }));
    const share_test = try std.fs.path.join(a, &.{ r0, "share", args.test_ });
    if (!isFile(share_test)) red(label, "the test's source {s} is not in its share directory", .{args.test_});
    if (args.solib) |so| {
        if (!isFile(try std.fs.path.join(a, &.{ r0, "share", so }))) red(label, "the shared library {s} (--solib) is not in the test's share directory", .{so});
    }
    for (args.solib_srcs) |p| {
        if (!isFile(try std.fs.path.join(a, &.{ r0, "share", p }))) red(label, "the shared library's source {s} (--solib-src) is not in the test's share directory", .{p});
    }
    const staged_share = try std.fs.path.join(a, &.{ r0, "share", stage });
    if (std.fs.cwd().statFile(staged_share)) |_| red(label, "the share directory already holds {s} (a data file under it?)", .{stage}) else |_| {}
    copyTreeTo(src, staged_share);
    copyTreeTo(src, try std.fs.path.join(a, &.{ l0, stage }));
    mkdirs(try std.fs.path.join(a, &.{ l0, test_dir }));
    copyFileTo(try std.fs.path.join(a, &.{ share, args.test_ }), try std.fs.path.join(a, &.{ l0, args.test_ }));
    for (args.solib_srcs) |p| copyFileTo(try std.fs.path.join(a, &.{ share, p }), try std.fs.path.join(a, &.{ l0, p }));
    const r = realpath(a, r0);
    const l = realpath(a, l0);
    const s = try std.fs.path.join(a, &.{ r, "share" });
    for ([_][]const u8{ s, l, stage, args.test_ }) |p| {
        if (hasAny(p, ",:")) die("{s} holds a , or :, which kcov's options split on", .{p});
    }
    const out = try std.fs.path.join(a, &.{ k, "kout" });

    // The generated sources: each is a link to a copy under gen/, outside both trees.
    const g = try std.fs.path.join(a, &.{ k, "gen" });
    for (args.gen) |gp| {
        const in_share = try std.fs.path.join(a, &.{ s, stage, gp });
        // A generated source is a file, or a directory of them (the parts of a
        // split generated module): either is moved whole and linked back.
        const is_dir = isDir(in_share);
        if (!(isFile(in_share) or is_dir) or isSymlink(in_share)) red(label, "the generated source {s} is not a file or a directory in {s}/", .{ gp, stage });
        const moved = try std.fs.path.join(a, &.{ g, gp });
        if (std.fs.path.dirname(moved)) |d| mkdirs(d);
        std.fs.cwd().rename(in_share, moved) catch |e| die("cannot move {s}: {s}", .{ in_share, @errorName(e) });
        std.fs.cwd().symLink(moved, in_share, .{ .is_directory = is_dir }) catch |e| die("cannot link {s}: {s}", .{ in_share, @errorName(e) });
        const in_lost = try std.fs.path.join(a, &.{ l, stage, gp });
        if (is_dir) std.fs.cwd().deleteTree(in_lost) catch {} else std.fs.cwd().deleteFile(in_lost) catch {};
        std.fs.cwd().symLink(moved, in_lost, .{ .is_directory = is_dir }) catch |e| die("cannot link {s}: {s}", .{ in_lost, @errorName(e) });
    }

    // 2. kcov under the gate's runner.
    var inc = std.ArrayList(u8).empty;
    try inc.writer(a).print("{s}/{s},{s}/{s},{s}/{s},{s}/{s}", .{ s, stage, s, args.test_, l, stage, l, args.test_ });
    for (args.solib_srcs) |p| try inc.writer(a).print(",{s}/{s},{s}/{s}", .{ s, p, l, p });
    var gate_args = std.ArrayList([]const u8).empty;
    try gate_args.appendSlice(a, &.{
        gate, "mojo", "--busybox", bb, "--runtime-lib", try std.fs.path.join(a, &.{ args.compiler, "lib" }), "--label", label,
        "--test", try std.fs.path.join(a, &.{ r, "bin", "kcov" }), "--marker", try std.fs.path.join(a, &.{ k, "gate.passed" }),
        "--limit-s", limit, "--limit-report", "coverage",
    });
    try gate_args.appendSlice(a, args.rest);
    var kcov_args = std.ArrayList([]const u8).empty;
    try kcov_args.append(a, "--cobertura-only");
    if (args.solib == null) try kcov_args.append(a, "--skip-solibs");
    try kcov_args.appendSlice(a, &.{
        "--configure=cobertura-full-paths=1",
        try std.fmt.allocPrint(a, "--include-path={s}", .{inc.items}),
        try std.fmt.allocPrint(a, "--replace-src-path=^(?!/):{s}/", .{l}),
        out,
        try std.fs.path.join(a, &.{ r, "bin", name }),
    });
    // Each of kcov's arguments is shorter than its 2048 bytes: it reads each argument before
    // the program as a path and fails "Too long string!".
    for (kcov_args.items) |ka| {
        if (ka.len > kcov_arg_max)
            red(label, "cov_run: a kcov argument of {d} bytes ({s}...) is longer than kcov takes ({d}): kcov reads each argument before the program as a path and fails \"Too long string!\" (README.md, \"cov_run\").", .{ ka.len, ka[0..@min(ka.len, 80)], kcov_arg_max });
    }
    for (kcov_args.items) |ka| {
        try gate_args.append(a, "--arg");
        try gate_args.append(a, ka);
    }
    var gate_child = std.process.Child.init(gate_args.items, a);
    gate_child.env_map = &env;
    gate_child.stdin_behavior = .Inherit;
    gate_child.stdout_behavior = .Inherit;
    gate_child.stderr_behavior = .Pipe;
    try gate_child.spawn();
    var gerr = std.ArrayList(u8).empty;
    {
        var buf: [65536]u8 = undefined;
        while (true) {
            const n = try gate_child.stderr.?.read(&buf);
            if (n == 0) break;
            try gerr.appendSlice(a, buf[0..n]);
        }
    }
    const rc = exitCodeOf(try gate_child.wait());
    try env.put("LC_ALL", "C");
    const gate_err = gerr.items;
    const limit_line = try std.fmt.allocPrint(a, "COVERAGE RUN FAILED: {s}", .{label});
    if (rc == 1 and hasLine(gate_err, limit_line)) {
        std.debug.print("{s}", .{gate_err});
        std.process.exit(1);
    }
    if (rc != 0) {
        std.debug.print("{s}", .{try filterGateErr(a, gate_err, label, rc)});
        const why = try failureWhy(a, gate_err, rc);
        std.debug.print("==================================================================\nCOVERAGE RUN FAILED: {s}\n{s}\n==================================================================\n", .{ label, why });
        std.process.exit(rc);
    }

    // 3. Exactly one report.
    var out_dir = std.fs.cwd().openDir(out, .{ .iterate = true }) catch red(label, "kcov wrote no output directory ({s})", .{out});
    defer out_dir.close();
    var found = std.ArrayList([]const u8).empty;
    {
        var w = try out_dir.walk(a);
        defer w.deinit();
        while (try w.next()) |e| {
            if (e.kind == .file and std.mem.endsWith(u8, e.basename, ".xml")) try found.append(a, try std.fs.path.join(a, &.{ out, e.path }));
        }
    }
    if (found.items.len != 1) {
        var joined = std.ArrayList(u8).empty;
        for (found.items) |f| {
            try joined.appendSlice(a, f);
            try joined.append(a, ' ');
        }
        red(label, "kcov wrote {d} XML report(s), expected exactly one: {s}", .{ found.items.len, joined.items });
    }

    // 4. Repository paths.
    var norm = std.ArrayList([]const u8).empty;
    try norm.append(a, try std.fs.path.join(a, &.{ here, "cov_normalize" }));
    try norm.appendSlice(a, &.{ "--in", found.items[0], "--out", xml });
    try norm.appendSlice(a, &.{ "--map", try std.fmt.allocPrint(a, "{s}/{s}/={s}", .{ s, stage, args.src_repo }) });
    try norm.appendSlice(a, &.{ "--map", try std.fmt.allocPrint(a, "{s}/{s}={s}", .{ s, test_dir, test_repo_dir }) });
    // The shell's $PWD: the environment's when it names this directory, else the physical one.
    const pwd = blk: {
        const e = std.process.getEnvVarOwned(a, "PWD") catch break :blk cwd;
        if (!std.fs.path.isAbsolute(e)) break :blk cwd;
        const re = std.fs.cwd().realpathAlloc(a, e) catch break :blk cwd;
        break :blk if (std.mem.eql(u8, re, cwd)) e else cwd;
    };
    try norm.appendSlice(a, &.{ "--must-contain", args.test_repo, "--forbid", pwd, "--forbid", r, "--forbid", l });
    if (args.solib != null) {
        if (test_dir.len > 0) try norm.appendSlice(a, &.{ "--map", try std.fmt.allocPrint(a, "{s}/={s}", .{ s, pkg_repo }) });
        try norm.appendSlice(a, &.{ "--must-contain", try std.fmt.allocPrint(a, "{s}{s}", .{ pkg_repo, args.solib_srcs[0] }) });
    }
    const p_real = realpath(a, pwd);
    if (!std.mem.eql(u8, p_real, pwd)) try norm.appendSlice(a, &.{ "--forbid", p_real });
    var nchild = std.process.Child.init(norm.items, a);
    nchild.env_map = &env;
    nchild.stdout_behavior = .Pipe;
    nchild.stderr_behavior = .Pipe;
    try nchild.spawn();
    var nout = std.ArrayList(u8).empty;
    var nerr = std.ArrayList(u8).empty;
    try nchild.collectOutput(a, &nout, &nerr, 1 << 26);
    const nrc = exitCodeOf(try nchild.wait());
    if (nrc != 0) {
        // (The script sent both streams to one file and showed it.)
        std.debug.print("{s}{s}", .{ nout.items, nerr.items });
        const lost_quote = try std.fmt.allocPrint(a, "'{s}/", .{l});
        if (std.mem.indexOf(u8, nout.items, lost_quote) != null or std.mem.indexOf(u8, nerr.items, lost_quote) != null)
            red(label, "cov_normalize refused kcov's report (above): kcov could not resolve these sources from its working directory {s}, so they were not staged where the line tables name them ({s}/ and {s}); their names fell through to {s}/.", .{ s, stage, args.test_, l });
        red(label, "cov_normalize refused kcov's report (above).", .{});
    }
    const mf = std.fs.cwd().createFile(marker, .{}) catch |e| die("cannot create {s}: {s}", .{ marker, @errorName(e) });
    defer mf.close();
    try mf.deprecatedWriter().print("PASS {s}\n", .{label});
    std.fs.cwd().deleteTree(k) catch {};
}

fn hasLine(text: []const u8, line: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        if (std.mem.eql(u8, l, line)) return true;
    }
    return false;
}
