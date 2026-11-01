//! tests_act's checks of coverage builds (tests 41, 43, 46, 47): the binaries
//! (`cov-debug-check`), the per-test reports (`cov-report-check`), a branch
//! coverage profile (`cov-branch-check`), the branch coverage link (`cov-link-line`)
//! and `cov-plant`, a copy of a source with one planted defect.

const std = @import("std");
const diff = @import("unified_diff");
const minised = @import("minised.zig");
const A = std.mem.Allocator;

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn red(comptime who: []const u8, comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(who ++ " RED: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn usage(comptime msg: []const u8) noreturn {
    std.debug.print("tests_act: " ++ msg ++ "\n", .{});
    std.process.exit(2);
}

fn readFile(a: A, path: []const u8) []u8 {
    return std.fs.cwd().readFileAlloc(a, path, 1 << 30) catch |e| {
        std.debug.print("tests_act: cannot read {s}: {s}\n", .{ path, @errorName(e) });
        std.process.exit(2);
    };
}

fn writeFile(path: []const u8, data: []const u8) void {
    if (std.fs.path.dirname(path)) |d| std.fs.cwd().makePath(d) catch {};
    const f = std.fs.cwd().createFile(path, .{}) catch |e| {
        std.debug.print("tests_act: cannot create {s}: {s}\n", .{ path, @errorName(e) });
        std.process.exit(2);
    };
    defer f.close();
    f.writeAll(data) catch |e| {
        std.debug.print("tests_act: cannot write {s}: {s}\n", .{ path, @errorName(e) });
        std.process.exit(2);
    };
}

fn absolute(a: A, p: []const u8) []u8 {
    if (std.fs.path.isAbsolute(p)) return a.dupe(u8, p) catch @panic("oom");
    const cwd = std.fs.cwd().realpathAlloc(a, ".") catch @panic("oom");
    return std.fs.path.join(a, &.{ cwd, p }) catch @panic("oom");
}

fn exitCode(term: std.process.Child.Term) u32 {
    return switch (term) {
        .Exited => |c| c,
        .Signal => |s| 128 + s,
        else => 255,
    };
}

fn scratch(a: A, name: []const u8) []u8 {
    const base = std.process.getEnvVarOwned(a, "BUCK_SCRATCH_PATH") catch return absolute(a, std.fmt.allocPrint(a, ".{s}", .{name}) catch @panic("oom"));
    return absolute(a, std.fs.path.join(a, &.{ base, name }) catch @panic("oom"));
}

// ---- strings --------------------------------------------------------------

/// The runs of at least `min` printable bytes (tab and 0x20..0x7e) of `data`, as
/// `strings -n` lists them.
pub fn strings(a: A, data: []const u8, min: usize) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    var start: ?usize = null;
    var i: usize = 0;
    while (i <= data.len) : (i += 1) {
        const printable = i < data.len and (data[i] == '\t' or (data[i] >= 0x20 and data[i] < 0x7f));
        if (printable) {
            if (start == null) start = i;
        } else if (start) |s| {
            if (i - s >= min) try out.append(a, data[s..i]);
            start = null;
        }
    }
    return out.toOwnedSlice(a);
}

pub fn hasString(list: []const []const u8, want: []const u8) bool {
    for (list) |s| {
        if (std.mem.eql(u8, s, want)) return true;
    }
    return false;
}

/// Whether `data` holds `/` followed by at least eight underscores, and, if
/// `closed`, then `/` after the underscores.
pub fn hasPlaceholder(data: []const u8, closed: bool) bool {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, data, i, '/')) |s| {
        var e = s + 1;
        while (e < data.len and data[e] == '_') e += 1;
        if (e - s - 1 >= 8) {
            if (!closed) return true;
            // `/_{8,}/`: the underscores may be given back one at a time, but a
            // run followed by anything else but `/` is no match.
            if (e < data.len and data[e] == '/') return true;
        }
        i = s + 1;
    }
    return false;
}

/// The first `/_{8,}/` and the printable bytes after it, for the message.
fn placeholderPath(data: []const u8) []const u8 {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, data, i, '/')) |s| {
        var e = s + 1;
        while (e < data.len and data[e] == '_') e += 1;
        if (e - s - 1 >= 8 and e < data.len and data[e] == '/') {
            var f = e + 1;
            while (f < data.len and data[f] >= 0x20 and data[f] < 0x7f) f += 1;
            return data[s..f];
        }
        i = s + 1;
    }
    return "";
}

fn isPlaceholderOnly(s: []const u8) bool {
    if (s.len < 9 or s[0] != '/') return false;
    for (s[1..]) |c| {
        if (c != '_') return false;
    }
    return true;
}

fn plainDir(d: []const u8) bool {
    for (d) |c| {
        if (std.mem.indexOfScalar(u8, ".*+?()[]{}|^$\\", c) != null) return false;
    }
    return true;
}

// ---- cov-debug-check ------------------------------------------------------

/// cov-debug-check <out> <debug_relocate> hermetic|same [--name=<s>]... [--dir=<s>]... <binary>...
pub fn debugCheck(a: A, args: []const []const u8) !void {
    if (args.len < 3) usage("cov-debug-check <out> <debug_relocate> hermetic|same ...");
    const out_path = args[0];
    const reloc = absolute(a, args[1]);
    const mode = args[2];
    var names = std.ArrayList([]const u8).empty;
    var dirs = std.ArrayList([]const u8).empty;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.startsWith(u8, args[i], "--name=")) {
            try names.append(a, args[i]["--name=".len..]);
        } else if (std.mem.startsWith(u8, args[i], "--dir=")) {
            try dirs.append(a, args[i]["--dir=".len..]);
        } else break;
    }
    const bins = args[i..];
    if (bins.len < 1) usage("check.sh: no binary");
    var report = std.ArrayList(u8).empty;
    const w = report.writer(a);
    if (std.mem.eql(u8, mode, "hermetic")) {
        if (names.items.len == 0) usage("check.sh: hermetic needs a --name");
        for (dirs.items) |d| if (!plainDir(d)) usage("cov-debug-check: --dir takes a literal string, not a pattern");
        const t = scratch(a, "cov_check");
        try std.fs.cwd().makePath(t);
        defer std.fs.cwd().deleteTree(t) catch {};
        for (bins) |b| {
            const n = std.fs.path.basename(b);
            const st = std.fs.cwd().statFile(b) catch null;
            if (st == null or st.?.size == 0) red("cov_debug_check", "{s}: missing or empty", .{n});
            const data = readFile(a, b);
            if (std.mem.indexOf(u8, data, ".debug_line") == null) red("cov_debug_check", "{s}: no .debug_line section; the line tables did not reach the binary", .{n});
            const strs = try strings(a, data, 4);
            for (names.items) |s| {
                if (!hasString(strs, s)) red("cov_debug_check", "{s}: no string '{s}'; the compile kept no line tables", .{ n, s });
            }
            for (dirs.items) |d| {
                if (!hasString(strs, d)) red("cov_debug_check", "{s}: no relative directory matching '{s}'; the line tables do not name the sources relative to the working directory", .{ n, d });
            }
            if (!hasPlaceholder(data, false)) red("cov_debug_check", "{s}: no placeholder '/___...'; the C runtime's compilation directory was not relocated", .{n});
            if (hasPlaceholder(data, true)) red("cov_debug_check", "{s}: holds an absolute path under the working directory ({s}); the line tables must name sources relative to it", .{ n, placeholderPath(data) });
            for (strs) |s| {
                if (s.len > 0 and s[0] == '/' and !isPlaceholderOnly(s) and !std.mem.eql(u8, s, "/lib64/ld-linux-x86-64.so.2"))
                    red("cov_debug_check", "{s}: holds an absolute path ({s}); a coverage binary may name only the placeholder and the ELF interpreter", .{ n, s });
            }
            const copy = try std.fs.path.join(a, &.{ t, "copy" });
            writeFile(copy, data);
            const f = try std.fs.cwd().openFile(copy, .{});
            f.chmod(0o755) catch {};
            f.close();
            const r = try std.process.Child.run(.{ .allocator = a, .argv = &.{ reloc, copy, "/nonexistent/directory/name" }, .max_output_bytes = 1 << 24 });
            if (exitCode(r.term) != 0) red("cov_debug_check", "{s}: debug_relocate refused it: {s}", .{ n, std.mem.trimRight(u8, try std.mem.concat(a, u8, &.{ r.stdout, r.stderr }), "\n") });
            var nm = std.ArrayList(u8).empty;
            for (names.items) |s| try nm.writer(a).print(" {s}", .{s});
            var dr = std.ArrayList(u8).empty;
            for (dirs.items) |s| try dr.writer(a).print(" {s}", .{s});
            try w.print("ok {s}: .debug_line, line tables naming{s}, relative directories{s}, placeholder, no absolute path, no compressed section\n", .{ n, nm.items, dr.items });
        }
    } else if (std.mem.eql(u8, mode, "same")) {
        var first: ?[32]u8 = null;
        const cwd = try std.fs.cwd().realpathAlloc(a, ".");
        for (bins) |b| {
            var h: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(readFile(a, b), &h, .{});
            const abs = absolute(a, b);
            const shown = if (std.mem.startsWith(u8, abs, cwd) and abs.len > cwd.len and abs[cwd.len] == '/') abs[cwd.len + 1 ..] else abs;
            try w.print("{x} {s}\n", .{ &h, shown });
            if (first == null) first = h;
            if (!std.mem.eql(u8, &first.?, &h)) {
                const flat = try a.dupe(u8, report.items);
                for (flat) |*c| {
                    if (c.* == '\n') c.* = ';';
                }
                red("cov_debug_check", "{s} differ", .{flat});
            }
        }
        if (bins.len < 2) red("cov_debug_check", "same: needs two binaries", .{});
    } else usage("check.sh: unknown mode");
    writeFile(out_path, report.items);
}

// ---- cov-report-check -----------------------------------------------------

/// cov-report-check <out> golden (--golden <golden> <report>)...
///                  <out> census --covcheck <covcheck...> --package <dir> (--file <repo path> <source>)... (--expect <s>)... (--cobertura <report>)...
///                  <out> result (--expect <s>)... --json <result.json>
pub fn reportCheck(a: A, args: []const []const u8) !void {
    if (args.len < 2) usage("cov-report-check <out> golden|census|result ...");
    const out_path = args[0];
    const mode = args[1];
    var rest = args[2..];
    var report = std.ArrayList(u8).empty;
    const w = report.writer(a);
    if (std.mem.eql(u8, mode, "golden")) {
        if (rest.len < 3) red("cov_report_check", "golden: no report", .{});
        while (rest.len > 0) {
            if (rest.len < 3 or !std.mem.eql(u8, rest[0], "--golden")) usage("report.sh: usage");
            const g = readFile(a, rest[1]);
            const r = readFile(a, rest[2]);
            if (!std.mem.eql(u8, g, r)) {
                const d = (try diff.unifiedDiff(a, rest[1], rest[2], g, r)) orelse "";
                red("cov_report_check", "{s} is not {s} byte for byte; diff golden report:\n{s}", .{ std.fs.path.basename(rest[2]), std.fs.path.basename(rest[1]), d });
            }
            try w.print("ok {s} = {s} ({d} bytes)\n", .{ std.fs.path.basename(rest[2]), std.fs.path.basename(rest[1]), r.len });
            rest = rest[3..];
        }
    } else if (std.mem.eql(u8, mode, "census")) {
        try census(a, rest, w);
    } else if (std.mem.eql(u8, mode, "result")) {
        var expects = std.ArrayList([]const u8).empty;
        while (rest.len >= 2 and std.mem.eql(u8, rest[0], "--expect")) {
            try expects.append(a, rest[1]);
            rest = rest[2..];
        }
        if (!(rest.len == 2 and std.mem.eql(u8, rest[0], "--json") and expects.items.len > 0)) usage("report.sh: result needs --expect <s>... --json <file>");
        const j = readFile(a, rest[1]);
        for (expects.items) |e| {
            if (std.mem.indexOf(u8, j, e) == null) red("cov_report_check", "the gate's result JSON does not hold '{s}': {s}", .{ e, j });
            try w.print("ok result holds {s}\n", .{e});
        }
    } else usage("report.sh: unknown mode");
    writeFile(out_path, report.items);
}

fn census(a: A, args: []const []const u8, w: anytype) !void {
    if (args.len < 1 or !std.mem.eql(u8, args[0], "--covcheck")) usage("report.sh: census needs --covcheck first");
    var i: usize = 1;
    var cc = std.ArrayList([]const u8).empty;
    while (i < args.len and !std.mem.eql(u8, args[i], "--package")) : (i += 1) try cc.append(a, absolute(a, args[i]));
    if (args.len - i < 2) usage("report.sh: census needs --package");
    const pkg = args[i + 1];
    i += 2;
    const t = scratch(a, "cov_report");
    const root = try std.fs.path.join(a, &.{ t, "root" });
    try std.fs.cwd().deleteTree(t);
    try std.fs.cwd().makePath(try std.fs.path.join(a, &.{ root, pkg }));
    defer std.fs.cwd().deleteTree(t) catch {};
    writeFile(try std.fs.path.join(a, &.{ root, pkg, "BUCK" }), "");
    var repo_files = std.ArrayList(u8).empty;
    try repo_files.writer(a).print("{s}/BUCK\x00", .{pkg});
    var expects = std.ArrayList([]const u8).empty;
    var coberturas = std.ArrayList([]const u8).empty;
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "--file") and i + 2 < args.len) {
            writeFile(try std.fs.path.join(a, &.{ root, args[i + 1] }), readFile(a, args[i + 2]));
            try repo_files.writer(a).print("{s}\x00", .{args[i + 1]});
            i += 3;
        } else if (std.mem.eql(u8, args[i], "--expect") and i + 1 < args.len) {
            try expects.append(a, args[i + 1]);
            i += 2;
        } else if (std.mem.eql(u8, args[i], "--cobertura") and i + 1 < args.len) {
            try coberturas.append(a, absolute(a, args[i + 1]));
            i += 2;
        } else {
            std.debug.print("report.sh: unknown argument {s}\n", .{args[i]});
            std.process.exit(2);
        }
    }
    const repo_path = try std.fs.path.join(a, &.{ t, "repo_files" });
    writeFile(repo_path, repo_files.items);
    const result_path = try std.fs.path.join(a, &.{ t, "result.json" });
    var argv = std.ArrayList([]const u8).empty;
    try argv.appendSlice(a, cc.items);
    try argv.appendSlice(a, &.{ "gate", "--package", pkg, "--repo-files", repo_path, "--source-root", root });
    for (coberturas.items) |c| try argv.appendSlice(a, &.{ "--cobertura", c });
    try argv.appendSlice(a, &.{ "--target-bp", "9900", "--mode", "census", "--result-out", result_path, "--summary-out", try std.fs.path.join(a, &.{ t, "summary.md" }) });
    var env = try std.process.getEnvMap(a);
    try env.put("LC_ALL", "C");
    const r = try std.process.Child.run(.{ .allocator = a, .argv = argv.items, .env_map = &env, .max_output_bytes = 1 << 26 });
    const rc = exitCode(r.term);
    if (rc != 0) red("cov_report_check", "covcheck gate exited {d} over the reports: {s}", .{ rc, std.mem.trimRight(u8, try std.mem.concat(a, u8, &.{ r.stdout, r.stderr }), "\n") });
    const result = std.fs.cwd().readFileAlloc(a, result_path, 1 << 26) catch "";
    for (expects.items) |e| {
        if (std.mem.indexOf(u8, result, e) == null) red("cov_report_check", "the result JSON does not hold '{s}': {s}", .{ e, result });
        try w.print("ok result holds {s}\n", .{e});
    }
    if (expects.items.len == 0) red("cov_report_check", "census: no --expect; the result JSON: {s}", .{result});
}

// ---- cov-branch-check -----------------------------------------------------

/// The block counts `llvm-profdata show --counts` printed, sorted numerically, each followed by a comma.
pub fn blockCounts(a: A, show: []const u8) ![]u8 {
    var nums = std.ArrayList(u64).empty;
    var lines = std.mem.splitScalar(u8, show, '\n');
    while (lines.next()) |l| {
        const t = std.mem.trimLeft(u8, l, " ");
        const pre = "Block counts: [";
        if (!std.mem.startsWith(u8, t, pre) or t.len == 0 or t[t.len - 1] != ']') continue;
        var parts = std.mem.splitScalar(u8, t[pre.len .. t.len - 1], ',');
        while (parts.next()) |p| try nums.append(a, std.fmt.parseInt(u64, std.mem.trim(u8, p, " "), 10) catch 0);
    }
    std.mem.sort(u64, nums.items, {}, std.sort.asc(u64));
    var out = std.ArrayList(u8).empty;
    for (nums.items) |x| try out.writer(a).print("{d},", .{x});
    return out.toOwnedSlice(a);
}

/// The function header lines of `show` (`  name:`), joined by blanks.
fn headers(a: A, show: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var lines = std.mem.splitScalar(u8, show, '\n');
    while (lines.next()) |l| {
        if (l.len > 2 and std.mem.startsWith(u8, l, "  ") and l[2] != ' ' and l[l.len - 1] == ':') try out.writer(a).print("{s} ", .{l});
    }
    return out.toOwnedSlice(a);
}

fn firstTwo(a: A, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (it.next()) |l| {
        if (it.peek() == null and l.len == 0) break;
        if (n == 2) break;
        try out.writer(a).print("{s} ", .{l});
        n += 1;
    }
    return out.toOwnedSlice(a);
}

/// cov-branch-check <out> <llvm dir> <profdata> <function> <count>,<count>...
pub fn branchCheck(a: A, args: []const []const u8) !void {
    if (args.len != 5) usage("branch_check: usage error");
    const pd = try std.fs.path.join(a, &.{ absolute(a, args[1]), "bin/llvm-profdata" });
    const fn_arg = try std.fmt.allocPrint(a, "--function={s}", .{args[3]});
    const r = try std.process.Child.run(.{ .allocator = a, .argv = &.{ pd, "show", "--counts", fn_arg, args[2] }, .max_output_bytes = 1 << 26 });
    const show = try std.mem.concat(a, u8, &.{ r.stdout, r.stderr });
    if (exitCode(r.term) != 0) red("branch_check", "llvm-profdata show --counts --function={s} failed: {s}", .{ args[3], try firstTwo(a, show) });
    var shown: []const u8 = "";
    var lines = std.mem.splitScalar(u8, show, '\n');
    var ok = false;
    while (lines.next()) |l| {
        if (std.mem.eql(u8, l, "Functions shown: 1")) ok = true;
        if (std.mem.startsWith(u8, l, "Functions shown: ")) shown = l["Functions shown: ".len..];
    }
    if (!ok) red("branch_check", "llvm-profdata shows {s} function(s) named like '{s}', not exactly 1: {s}", .{ shown, args[3], try headers(a, show) });
    const got = try blockCounts(a, show);
    const want = try std.fmt.allocPrint(a, "{s},", .{args[4]});
    if (!std.mem.eql(u8, got, want)) red("branch_check", "the counters of {s} are '{s}' (sorted), not '{s}': {s}", .{ args[3], std.mem.trimRight(u8, got, ","), args[4], try headers(a, show) });
    writeFile(args[0], show);
}

// ---- cov-plant ------------------------------------------------------------

/// cov-plant <expr> <source> <out>: <out> is <source> with the sed expression applied, and differs.
pub fn plant(a: A, args: []const []const u8) !void {
    if (args.len != 3) usage("cov-plant <expr> <source> <out>");
    const src = readFile(a, args[1]);
    const out = minised.run(a, args[0], src) catch |e| {
        std.debug.print("cov_plant: cannot apply the expression: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    if (std.mem.eql(u8, src, out)) {
        std.debug.print("cov_plant: the expression changes nothing in {s}\n", .{args[1]});
        std.process.exit(1);
    }
    writeFile(args[2], out);
}

// ---- cov-link-line --------------------------------------------------------

/// The recorder: called as `zig`, appends its arguments (one per line, then a
/// `----` line) to the log named in `recorder.conf` beside it and runs the real zig.
pub fn recorder(a: A, argv: []const []const u8) !u8 {
    const dir = std.fs.path.dirname(argv[0]) orelse ".";
    const conf = try std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ dir, "recorder.conf" }), 1 << 16);
    var lines = std.mem.splitScalar(u8, conf, '\n');
    const log = lines.next() orelse return error.BadRecorderConf;
    const real = lines.next() orelse return error.BadRecorderConf;
    var text = std.ArrayList(u8).empty;
    for (argv[1..]) |x| try text.writer(a).print("{s}\n", .{x});
    try text.appendSlice(a, "----\n");
    const f = std.fs.cwd().openFile(log, .{ .mode = .write_only }) catch try std.fs.cwd().createFile(log, .{});
    defer f.close();
    try f.seekFromEnd(0);
    try f.writeAll(text.items);
    var cmd = std.ArrayList([]const u8).empty;
    try cmd.append(a, real);
    try cmd.appendSlice(a, argv[1..]);
    return std.process.execv(a, cmd.items) catch 1;
}

/// A linker command line, one argument per line (with `----` between runs), rewritten
/// to compare two links: the compiler's object `<object>`, the output `<out>`, the
/// target `<target>`, the profile runtime `<runtime>` and the toolchain `<TC>/...`.
pub fn normalize(a: A, argv_text: []const u8, tc: []const u8, target: []const u8, kind: enum { mojo, branch }) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var after_o = false;
    var lines = std.mem.splitScalar(u8, argv_text, '\n');
    while (lines.next()) |l| {
        if (lines.peek() == null and l.len == 0) break;
        if (std.mem.eql(u8, l, "----")) continue;
        if (after_o) {
            try out.appendSlice(a, "<out>\n");
            after_o = false;
            continue;
        }
        if (std.mem.eql(u8, l, "-o")) after_o = true;
        if (std.mem.eql(u8, l, target)) {
            try out.appendSlice(a, "<target>\n");
            continue;
        }
        const is_obj = switch (kind) {
            .mojo => std.mem.startsWith(u8, std.fs.path.basename(l), "mojo_archive-") and std.mem.endsWith(u8, l, ".a") and std.mem.indexOfScalar(u8, l, '/') != null,
            .branch => std.mem.endsWith(u8, l, "/cov_branch_link/pg.o"),
        };
        if (is_obj) {
            try out.appendSlice(a, "<object>\n");
            continue;
        }
        if (std.mem.endsWith(u8, l, "/libclang_rt.profile-x86_64.a")) {
            try out.appendSlice(a, "<runtime>\n");
            continue;
        }
        if (std.mem.startsWith(u8, l, tc) and l.len > tc.len and l[tc.len] == '/') {
            try out.writer(a).print("<TC>/{s}\n", .{l[tc.len + 1 ..]});
            continue;
        }
        try out.writer(a).print("{s}\n", .{l});
    }
    return out.toOwnedSlice(a);
}

/// The branch line without its profile runtime: the whole-archive group that holds only `<runtime>` is removed.
pub fn withoutRuntime(a: A, branch: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var held = false;
    var seen = false;
    var rt = false;
    var lines = std.mem.splitScalar(u8, branch, '\n');
    while (lines.next()) |l| {
        if (lines.peek() == null and l.len == 0) break;
        if (std.mem.eql(u8, l, "-Wl,--whole-archive") and !seen) {
            held = true;
            seen = true;
            continue;
        }
        if (held and std.mem.eql(u8, l, "-Wl,--no-whole-archive")) {
            held = false;
            continue;
        }
        if (held and std.mem.eql(u8, l, "<runtime>")) {
            rt = true;
            continue;
        }
        if (held) {
            try out.writer(a).print("<unexpected in the whole archive> {s}\n", .{l});
            continue;
        }
        try out.writer(a).print("{s}\n", .{l});
    }
    if (!rt) try out.appendSlice(a, "<no profile runtime>\n");
    return out.toOwnedSlice(a);
}

fn runs(text: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        if (std.mem.eql(u8, l, "----")) n += 1;
    }
    return n;
}

fn flatLines(a: A, text: []const u8) []u8 {
    const c = a.dupe(u8, text) catch @panic("oom");
    for (c) |*x| {
        if (x.* == '\n') x.* = ' ';
    }
    return c;
}

fn tail5(a: A, text: []const u8) []u8 {
    var lines = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        if (it.peek() == null and l.len == 0) break;
        lines.append(a, l) catch @panic("oom");
    }
    const from = if (lines.items.len > 5) lines.items.len - 5 else 0;
    var out = std.ArrayList(u8).empty;
    for (lines.items[from..]) |l| out.writer(a).print("{s} ", .{l}) catch @panic("oom");
    return out.items;
}

/// cov-link-line <out> <busybox> <wrapper> <compiler dir> <zig dir> <cc target> <cpu> <test.mojo> <bitcode> <link dir> [-I<dir>...]
pub fn linkLine(a: A, args: []const []const u8) !void {
    if (args.len < 10) usage("link_line: usage error");
    const cwd = std.fs.cwd();
    const out_path = args[0];
    const bb = absolute(a, args[1]);
    const wrapper = absolute(a, args[2]);
    const tc = absolute(a, args[3]);
    const zig = absolute(a, args[4]);
    const target = args[5];
    const cpu = args[6];
    const src = absolute(a, args[7]);
    const bc = absolute(a, args[8]);
    const link = absolute(a, args[9]);
    const k = scratch(a, "link_line");
    try cwd.deleteTree(k);
    try cwd.makePath(try std.fs.path.join(a, &.{ k, "src/tests" }));
    defer cwd.deleteTree(k) catch {};
    var self_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_exe = try std.fs.selfExePath(&self_buf);
    // The stand-in zigs, one per link: this program under the name `zig`, which
    // records its arguments and runs the toolchain's zig.
    for ([_][]const u8{ "mojo", "branch" }) |n| {
        const d = try std.fmt.allocPrint(a, "{s}/zig_{s}", .{ k, n });
        try cwd.makePath(d);
        try cwd.symLink(self_exe, try std.fs.path.join(a, &.{ d, "zig" }), .{});
        writeFile(try std.fs.path.join(a, &.{ d, "recorder.conf" }), try std.fmt.allocPrint(a, "{s}/{s}.argv\n{s}/zig\n", .{ k, n, zig }));
    }
    var env = try std.process.getEnvMap(a);
    try env.put("LC_ALL", "C");
    const test_name = std.fs.path.basename(src);
    const staged = try std.fmt.allocPrint(a, "{s}/src/tests/{s}", .{ k, test_name });
    writeFile(staged, readFile(a, src));

    // 1. The release build of the test, through the wrapper.
    var argv = std.ArrayList([]const u8).empty;
    try argv.appendSlice(a, &.{
        wrapper,
        try std.fmt.allocPrint(a, "--compiler={s}", .{tc}),
        try std.fmt.allocPrint(a, "--zig={s}/zig_mojo", .{k}),
        try std.fmt.allocPrint(a, "--cc-target={s}", .{target}),
        try std.fmt.allocPrint(a, "--source-root={s}/src", .{k}),
        "--",
        "build",
        "--optimization-level",
        "0",
        "--target-cpu",
        cpu,
        "--debug-level",
        "line-tables",
    });
    try argv.appendSlice(a, args[10..]);
    try argv.appendSlice(a, &.{ staged, "-o", try std.fmt.allocPrint(a, "{s}/mojo.exe", .{k}) });
    const m = try std.process.Child.run(.{ .allocator = a, .argv = argv.items, .env_map = &env, .max_output_bytes = 1 << 26 });
    if (exitCode(m.term) != 0) red("link_line", "mojo_compile could not build {s}: {s}", .{ test_name, tail5(a, try std.mem.concat(a, u8, &.{ m.stdout, m.stderr })) });

    // 2. The branch coverage link of its bitcode.
    const b = try std.process.Child.run(.{ .allocator = a, .argv = &.{
        try std.fs.path.join(a, &.{ link, "cov_branch" }),
        "link",
        "--busybox",
        bb,
        "--compiler",
        tc,
        "--zig",
        try std.fmt.allocPrint(a, "{s}/zig_branch", .{k}),
        "--target",
        target,
        "--lld",
        try std.fs.path.join(a, &.{ link, "lld/bin/lld" }),
        "--runtime",
        try std.fs.path.join(a, &.{ link, "llvm/runtime/libclang_rt.profile-x86_64.a" }),
        "--bitcode",
        bc,
        "--out",
        try std.fmt.allocPrint(a, "{s}/branch.exe", .{k}),
    }, .env_map = &env, .max_output_bytes = 1 << 26 });
    if (exitCode(b.term) != 0) red("link_line", "cov_branch link could not link {s}: {s}", .{ std.fs.path.basename(bc), tail5(a, try std.mem.concat(a, u8, &.{ b.stdout, b.stderr })) });

    // One zig run each, normalised; the branch line without its runtime.
    const mojo_argv = readFile(a, try std.fmt.allocPrint(a, "{s}/mojo.argv", .{k}));
    const branch_argv = readFile(a, try std.fmt.allocPrint(a, "{s}/branch.argv", .{k}));
    if (runs(mojo_argv) != 1) red("link_line", "mojo.argv: zig ran {d} times, not once", .{runs(mojo_argv)});
    if (runs(branch_argv) != 1) red("link_line", "branch.argv: zig ran {d} times, not once", .{runs(branch_argv)});
    const mojo_line = try normalize(a, mojo_argv, tc, target, .mojo);
    const branch_full = try normalize(a, branch_argv, tc, target, .branch);
    const branch_line = try withoutRuntime(a, branch_full);
    if (!std.mem.eql(u8, mojo_line, branch_line))
        red("link_line", "the branch coverage link is not the release link plus the profile runtime: release: {s}| branch: {s}", .{ flatLines(a, mojo_line), flatLines(a, branch_line) });
    var report = std.ArrayList(u8).empty;
    try report.writer(a).print("release (mojo build through mojo_compile's cc shim):\n{s}branch coverage (cov_branch link):\n{s}", .{ mojo_line, branch_full });
    writeFile(out_path, report.items);
}
