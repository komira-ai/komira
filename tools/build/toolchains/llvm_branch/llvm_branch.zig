// Why Zig: build tools are Zig (tools/build/README.md). This replaces unpack.sh
// and check.sh (busybox shell scripts) of the llvm_branch rules, so that the
// unpack and the checks run no shell.
//! llvm_branch: the actions of the LLVM pieces of branch coverage (defs.bzl,
//! README.md).
//!
//! usage: llvm_branch unpack <conda_payload> <out_dir> <name>=<package.conda>...
//!            -- <dest>=<name>/<member>...
//!        llvm_branch check <mode> <zig_dir> <report_dir> <lld_dir|-> <tools_dir|->
//!            <fixture_dir|-> <key>=<value>...
//!
//! `unpack` writes named members of pinned `.conda` packages into one
//! directory, each a regular file: a member that is a symbolic link in its
//! package is followed (within the package, never to an absolute path or out
//! through `..`) and the file it resolves to is written. Nothing else is
//! written. Exit 2, naming it, on a member that is missing or empty, a link
//! that leaves its package, or a package named by no `<name>=`. The pinned
//! busybox reads neither the zip64 fields nor the zstd payload of a `.conda`,
//! so conda_payload (toolchains/kcov/conda_payload.zig) writes the payload tar
//! first; the program reads only the members asked for.
//!
//! `check` runs one mode (lld, tools, raw_version; README.md, "Checks") and
//! writes <report_dir>/validation.json and what it measured; exit 1 on the
//! first wrong result, naming it. The <key>=<value> arguments are what the
//! mode expects (the `want` of the target).

const std = @import("std");
const A = std.mem.Allocator;

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// ---- unpack ---------------------------------------------------------------

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("llvm_branch unpack: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

/// A link target that stays inside its directory: not absolute, no `..`
/// component.
pub fn linkContained(t: []const u8) bool {
    if (t.len == 0 or t[0] == '/') return false;
    var it = std.mem.splitScalar(u8, t, '/');
    while (it.next()) |c| {
        if (std.mem.eql(u8, c, "..")) return false;
    }
    return true;
}

/// The member a link at `m` to `t` names: `t` beside `m`.
pub fn resolveLink(a: A, m: []const u8, t: []const u8) ![]u8 {
    if (std.mem.lastIndexOfScalar(u8, m, '/')) |i| return std.fmt.allocPrint(a, "{s}/{s}", .{ m[0..i], t });
    return a.dupe(u8, t);
}

const Found = union(enum) {
    missing,
    directory,
    link: []const u8,
    /// A regular file; its size.
    file: u64,
};

/// Finds `member` in the tar at `tar_path`; a regular file is written to
/// `dest` when given.
fn find(a: A, tar_path: []const u8, member: []const u8, dest: ?[]const u8) !Found {
    const file = try std.fs.cwd().openFile(tar_path, .{});
    defer file.close();
    var br = std.io.bufferedReader(file.reader());
    var name_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    var link_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    var it = std.tar.iterator(br.reader(), .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    while (try it.next()) |f| {
        var name = std.mem.trimRight(u8, f.name, "/");
        if (std.mem.startsWith(u8, name, "./")) name = name[2..];
        if (!std.mem.eql(u8, name, member)) continue;
        switch (f.kind) {
            .directory => return .directory,
            .sym_link => return .{ .link = try a.dupe(u8, f.link_name) },
            .file => {
                if (f.size == 0) return .{ .file = 0 };
                if (dest) |d| {
                    const mode: std.fs.File.Mode = if (f.mode & 0o111 != 0) 0o755 else 0o644;
                    const out = try std.fs.cwd().createFile(d, .{ .mode = mode });
                    defer out.close();
                    try f.writeAll(out);
                    try out.chmod(mode);
                }
                return .{ .file = f.size };
            },
        }
    }
    return .missing;
}

fn scratchDir(a: A, name: []const u8) ![]u8 {
    const base = std.process.getEnvVarOwned(a, "BUCK_SCRATCH_PATH") catch return std.fmt.allocPrint(a, ".{s}", .{name});
    return std.fs.path.join(a, &.{ base, name });
}

fn writeFile(path: []const u8, data: []const u8) !void {
    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(data);
}

/// Writes the members `specs` (`<dest>=<name>/<member>`) of the payload tars
/// `<pkg_dir>/<name>.tar` under `out`; returns how many. A refusal is
/// `error.Unpack` with the reason in `msg`.
pub fn extractMembers(a: A, pkg_dir: []const u8, out: []const u8, specs: []const []const u8, msg: *std.ArrayList(u8)) !usize {
    var n: usize = 0;
    for (specs) |spec| {
        const eq = std.mem.indexOfScalar(u8, spec, '=') orelse return refuse(msg, "bad destination in '{s}'", .{spec});
        const dest = spec[0..eq];
        const src = spec[eq + 1 ..];
        if (dest.len == 0 or dest[0] == '/' or std.mem.indexOf(u8, dest, "..") != null) return refuse(msg, "bad destination in '{s}'", .{dest});
        const slash = std.mem.indexOfScalar(u8, src, '/') orelse return refuse(msg, "'{s}' names no member (<dest>=<package>/<member>)", .{spec});
        const name = src[0..slash];
        const member = src[slash + 1 ..];
        const tar = try std.fmt.allocPrint(a, "{s}/{s}.tar", .{ pkg_dir, name });
        std.fs.cwd().access(tar, .{}) catch return refuse(msg, "'{s}' names package '{s}', which is not given", .{ spec, name });
        const dest_path = try std.fs.path.join(a, &.{ out, dest });
        if (std.fs.path.dirname(dest_path)) |d| try std.fs.cwd().makePath(d);
        var m: []const u8 = member;
        var hops: usize = 0;
        while (true) {
            switch (try find(a, tar, m, dest_path)) {
                .missing => return refuse(msg, "{s} is not a member of {s}", .{ m, name }),
                .directory => return refuse(msg, "{s}/{s} is not a non-empty file", .{ name, member }),
                .file => |size| {
                    if (size == 0) return refuse(msg, "{s}/{s} is not a non-empty file", .{ name, member });
                    break;
                },
                .link => |target| {
                    if (!linkContained(target)) return refuse(msg, "{s} is a link to '{s}', outside its directory", .{ m, target });
                    m = try resolveLink(a, m, target);
                    hops += 1;
                    if (hops >= 8) return refuse(msg, "{s}: more than 8 links", .{member});
                },
            }
        }
        n += 1;
    }
    return n;
}

fn refuse(msg: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) error{ Unpack, OutOfMemory } {
    try msg.writer().print(fmt, args);
    return error.Unpack;
}

fn unpack(a: A, args: []const []const u8) !void {
    if (args.len < 2) fail("usage: llvm_branch unpack <conda_payload> <out_dir> <name>=<package.conda>... -- <dest>=<name>/<member>...", .{});
    const payload = args[0];
    const out = args[1];
    const t = try scratchDir(a, "llvm_branch_unpack");
    defer std.fs.cwd().deleteTree(t) catch {};
    const pkg_dir = try std.fs.path.join(a, &.{ t, "pkg" });
    try std.fs.cwd().makePath(pkg_dir);
    try std.fs.cwd().makePath(out);
    var i: usize = 2;
    while (i < args.len and !std.mem.eql(u8, args[i], "--")) : (i += 1) {
        const eq = std.mem.indexOfScalar(u8, args[i], '=') orelse fail("bad package argument '{s}'", .{args[i]});
        const name = args[i][0..eq];
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) fail("bad package argument '{s}'", .{args[i]});
        const tar = try std.fmt.allocPrint(a, "{s}/{s}.tar", .{ pkg_dir, name });
        const r = std.process.Child.run(.{ .allocator = a, .argv = &.{ payload, args[i][eq + 1 ..], tar } }) catch |e| fail("conda_payload failed on package {s}: {s}", .{ name, @errorName(e) });
        const ok = switch (r.term) {
            .Exited => |c| c == 0,
            else => false,
        };
        if (!ok) fail("conda_payload failed on package {s}", .{name});
    }
    if (i >= args.len) fail("no '--' before the members", .{});
    var msg = std.ArrayList(u8).init(a);
    const n = extractMembers(a, pkg_dir, out, args[i + 1 ..], &msg) catch |e| switch (e) {
        error.Unpack => fail("{s}", .{msg.items}),
        else => return e,
    };
    if (n == 0) fail("no members named", .{});
}

// ---- check ----------------------------------------------------------------

const Ctx = struct {
    a: A,
    mode: []const u8,
    zig: []const u8,
    report: []const u8,
    lld_dir: []const u8,
    tools_dir: []const u8,
    fixtures: []const u8,
    want_args: []const []const u8,
    t: []const u8,
    env: std.process.EnvMap,
    /// What the last command printed: the script's `$T/log`.
    log: ?[]const u8 = null,
    n: usize = 0,

    fn red(self: *Ctx, comptime fmt: []const u8, args: anytype) noreturn {
        std.debug.print("llvm_branch {s} RED: " ++ fmt ++ "\n", .{self.mode} ++ args);
        if (self.log) |l| {
            std.debug.print("--- log:\n", .{});
            var lines = std.ArrayList([]const u8).init(self.a);
            var it = std.mem.splitScalar(u8, l, '\n');
            while (it.next()) |x| {
                if (it.peek() == null and x.len == 0) break;
                lines.append(x) catch {};
            }
            const from = if (lines.items.len > 40) lines.items.len - 40 else 0;
            for (lines.items[from..]) |x| std.debug.print("{s}\n", .{x});
        }
        std.process.exit(1);
    }

    fn pass(self: *Ctx) void {
        self.n += 1;
    }

    /// The value of `key` among the key=value arguments.
    fn want(self: *Ctx, key: []const u8) []const u8 {
        for (self.want_args) |kv| {
            if (kv.len > key.len and std.mem.startsWith(u8, kv, key) and kv[key.len] == '=') return kv[key.len + 1 ..];
        }
        self.red("no '{s}=' expectation given", .{key});
    }

    /// Runs `argv`; its stdout and stderr, in that order, are the log. Null
    /// when it exits non-zero (the status goes to `code`).
    fn run(self: *Ctx, argv: []const []const u8, code: ?*u32) ?[]const u8 {
        const r = std.process.Child.run(.{ .allocator = self.a, .argv = argv, .env_map = &self.env, .max_output_bytes = 1 << 26 }) catch |e|
            self.red("cannot run {s}: {s}", .{ argv[0], @errorName(e) });
        const out = std.mem.concat(self.a, u8, &.{ r.stdout, r.stderr }) catch @panic("oom");
        self.log = out;
        const c: u32 = switch (r.term) {
            .Exited => |x| x,
            .Signal => |s| 128 + s,
            else => 255,
        };
        if (code) |p| p.* = c;
        return if (c == 0) out else null;
    }

    fn join(self: *Ctx, parts: []const []const u8) []u8 {
        return std.fs.path.join(self.a, parts) catch @panic("oom");
    }

    fn print(self: *Ctx, comptime fmt: []const u8, args: anytype) []u8 {
        return std.fmt.allocPrint(self.a, fmt, args) catch @panic("oom");
    }

    fn writeReport(self: *Ctx, name: []const u8, data: []const u8) void {
        const p = self.join(&.{ self.report, name });
        writeFile(p, data) catch |e| self.red("cannot write {s}: {s}", .{ p, @errorName(e) });
    }

    fn appendReport(self: *Ctx, name: []const u8, data: []const u8) void {
        const p = self.join(&.{ self.report, name });
        const f = std.fs.cwd().openFile(p, .{ .mode = .write_only }) catch |e| self.red("cannot open {s}: {s}", .{ p, @errorName(e) });
        defer f.close();
        f.seekFromEnd(0) catch {};
        f.writeAll(data) catch |e| self.red("cannot write {s}: {s}", .{ p, @errorName(e) });
    }

    fn readFile(self: *Ctx, path: []const u8) []u8 {
        return std.fs.cwd().readFileAlloc(self.a, path, 1 << 28) catch |e| self.red("cannot read {s}: {s}", .{ path, @errorName(e) });
    }

    fn green(self: *Ctx) void {
        std.fs.cwd().deleteTree(self.t) catch {};
        const j = self.print("{{\"version\": 1, \"data\": {{\"status\": \"success\", \"message\": \"llvm_branch {s}: {d} checks passed\"}}}}\n", .{ self.mode, self.n });
        self.writeReport("validation.json", j);
        std.debug.print("llvm_branch {s} GREEN: {d} checks\n", .{ self.mode, self.n });
    }

    fn executable(self: *Ctx, path: []const u8) bool {
        _ = self;
        const st = std.fs.cwd().statFile(path) catch return false;
        return st.mode & 0o111 != 0;
    }

    /// Fails unless `dir` holds exactly the files `names` (regular files; no
    /// link, no other file).
    fn exactly(self: *Ctx, dir: []const u8, names: []const []const u8) void {
        var d = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch |e| self.red("cannot open {s}: {s}", .{ dir, @errorName(e) });
        defer d.close();
        var got = std.ArrayList([]const u8).init(self.a);
        var links = std.ArrayList(u8).init(self.a);
        var w = d.walk(self.a) catch @panic("oom");
        while (w.next() catch |e| self.red("cannot walk {s}: {s}", .{ dir, @errorName(e) })) |e| {
            if (e.kind == .directory) continue;
            got.append(self.a.dupe(u8, e.path) catch @panic("oom")) catch @panic("oom");
            if (e.kind == .sym_link) links.writer().print("./{s}\n", .{e.path}) catch @panic("oom");
        }
        const want_sorted = self.a.dupe([]const u8, names) catch @panic("oom");
        std.mem.sort([]const u8, want_sorted, {}, lessThan);
        std.mem.sort([]const u8, got.items, {}, lessThan);
        var log = std.ArrayList(u8).init(self.a);
        var differ = false;
        for (want_sorted) |x| {
            if (!contains(got.items, x)) {
                log.writer().print("< {s}\n", .{x}) catch @panic("oom");
                differ = true;
            }
        }
        for (got.items) |x| {
            if (!contains(want_sorted, x)) {
                log.writer().print("> {s}\n", .{x}) catch @panic("oom");
                differ = true;
            }
        }
        if (differ) {
            self.log = log.items;
            self.red("{s} does not hold exactly its files (diff: - missing, + extra)", .{dir});
        }
        if (links.items.len > 0) self.red("{s} holds symbolic links: {s}", .{ dir, std.mem.trimRight(u8, links.items, "\n") });
    }
};

fn contains(xs: []const []const u8, x: []const u8) bool {
    for (xs) |y| {
        if (std.mem.eql(u8, x, y)) return true;
    }
    return false;
}

/// `s` as a sorted multiset of the fields `llvm-nm` printed on lines that
/// define `symbol`: the class letters of lines of exactly three fields whose
/// last is `symbol`, each followed by a blank.
pub fn nmClasses(a: A, nm: []const u8, symbol: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    var lines = std.mem.splitScalar(u8, nm, '\n');
    while (lines.next()) |l| {
        var f = std.mem.tokenizeAny(u8, l, " \t");
        var parts: [4][]const u8 = undefined;
        var k: usize = 0;
        while (f.next()) |x| {
            if (k < 4) parts[k] = x;
            k += 1;
        }
        if (k == 3 and std.mem.eql(u8, parts[2], symbol)) {
            try out.appendSlice(parts[1]);
            try out.append(' ');
        }
    }
    return out.toOwnedSlice();
}

/// Whether some line of `nm` has exactly three fields and `symbol` last.
pub fn nmDefines(nm: []const u8, symbol: []const u8) bool {
    var lines = std.mem.splitScalar(u8, nm, '\n');
    while (lines.next()) |l| {
        var f = std.mem.tokenizeAny(u8, l, " \t");
        var k: usize = 0;
        var last: []const u8 = "";
        while (f.next()) |x| {
            k += 1;
            last = x;
        }
        if (k == 3 and std.mem.eql(u8, last, symbol)) return true;
    }
    return false;
}

/// The block counts `llvm-profdata show --counts` printed, sorted numerically,
/// each followed by a comma ("2,3,").
pub fn blockCounts(a: A, show: []const u8) ![]u8 {
    var nums = std.ArrayList(u64).init(a);
    var lines = std.mem.splitScalar(u8, show, '\n');
    while (lines.next()) |l| {
        const t = std.mem.trimLeft(u8, l, " ");
        const pre = "Block counts: [";
        if (!std.mem.startsWith(u8, t, pre) or t.len == 0 or t[t.len - 1] != ']') continue;
        const inner = t[pre.len .. t.len - 1];
        var parts = std.mem.splitScalar(u8, inner, ',');
        while (parts.next()) |p| {
            const clean = try a.alloc(u8, p.len);
            var k: usize = 0;
            for (p) |c| {
                if (c != ' ') {
                    clean[k] = c;
                    k += 1;
                }
            }
            try nums.append(std.fmt.parseInt(u64, clean[0..k], 10) catch 0);
        }
    }
    std.mem.sort(u64, nums.items, {}, std.sort.asc(u64));
    var out = std.ArrayList(u8).init(a);
    for (nums.items) |x| try out.writer().print("{d},", .{x});
    return out.toOwnedSlice();
}

/// The first `n` lines of `text`, each followed by a blank (`head -n N | tr '\n' ' '`).
fn firstLinesSpaced(a: A, text: []const u8, n: usize) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    var it = std.mem.splitScalar(u8, text, '\n');
    var k: usize = 0;
    while (it.next()) |l| {
        if (it.peek() == null and l.len == 0) break;
        if (k == n) break;
        try out.appendSlice(l);
        try out.append(' ');
        k += 1;
    }
    return out.toOwnedSlice();
}

/// The numbers after `; expected version = ` on the lines of a merge log,
/// each followed by a blank, less the last blank.
pub fn expectedVersions(a: A, log: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    var lines = std.mem.splitScalar(u8, log, '\n');
    const key = "; expected version = ";
    while (lines.next()) |l| {
        const at = std.mem.lastIndexOf(u8, l, key) orelse continue;
        var e = at + key.len;
        const s = e;
        while (e < l.len and l[e] >= '0' and l[e] <= '9') e += 1;
        if (e == s) continue;
        try out.appendSlice(l[s..e]);
        try out.append(' ');
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] == ' ') _ = out.pop();
    return out.toOwnedSlice();
}

const raw_magic: u64 = 0xff6c70726f667281;

fn rawVersion(c: *Ctx, path: []const u8) u32 {
    const d = c.readFile(path);
    if (d.len < 16) c.red("{s} is too short to be a raw profile", .{path});
    const magic = std.mem.readInt(u64, d[0..8], .little);
    if (magic != raw_magic) c.red("{s} does not start with the 64-bit raw profile magic (got '{x:0>16}')", .{ path, magic });
    return std.mem.readInt(u32, d[8..12], .little);
}

fn mergeVersion(c: *Ctx) []const u8 {
    // `llvm-profdata --version | sed -n 's/^ *LLVM version //p'`
    const exe = c.join(&.{ c.tools_dir, "bin/llvm-profdata" });
    const out = c.run(&.{ exe, "--version" }, null) orelse "";
    var res = std.ArrayList(u8).init(c.a);
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |l| {
        const t = std.mem.trimLeft(u8, l, " ");
        if (std.mem.startsWith(u8, t, "LLVM version ")) {
            if (res.items.len > 0) res.append('\n') catch {};
            res.appendSlice(t["LLVM version ".len..]) catch {};
        }
    }
    return res.items;
}

/// Null when llvm-profdata merges the raw profile `file` into `out`; otherwise
/// why not. A refusal is a version refusal only when llvm-profdata says so in
/// LLVM's words (`raw profile version mismatch: ... expected version = <M>`);
/// the log also holds `file`'s path, which may contain any word.
fn accepts(c: *Ctx, file: []const u8, out: []const u8) ?[]const u8 {
    const av = rawVersion(c, file);
    const exe = c.join(&.{ c.tools_dir, "bin/llvm-profdata" });
    if (c.run(&.{ exe, "merge", "-o", out, file }, null) != null) return null;
    const log = c.log orelse "";
    const pv = mergeVersion(c);
    const head = firstLinesSpaced(c.a, log, 2) catch @panic("oom");
    if (std.mem.indexOf(u8, log, "raw profile version mismatch") != null) {
        const ev = expectedVersions(c.a, log) catch @panic("oom");
        return c.print("raw profile version {d} not accepted by llvm-profdata {s}, which expects {s}: {s}", .{ av, pv, ev, head });
    }
    return c.print("llvm-profdata merge failed on {s} (raw version {d}): {s}", .{ file, av, head });
}

fn lldMode(c: *Ctx) void {
    const major = c.want("lld");
    c.exactly(c.lld_dir, &.{ "bin/lld", "lib/libgcc_s.so.1", "lib/libstdc++.so.6" });
    const lld = c.join(&.{ c.lld_dir, "bin/lld" });
    if (!c.executable(lld)) c.red("bin/lld is not executable", .{});
    c.pass();
    const out = c.run(&.{ lld, "-flavor", "gnu", "--version" }, null) orelse c.red("lld -flavor gnu --version failed", .{});
    c.writeReport("lld_version.txt", out);
    const needle = c.print("LLD {s}.", .{major});
    if (std.mem.indexOf(u8, out, needle) == null)
        c.red("lld -flavor gnu --version does not print 'LLD {s}.': the Mojo package's lld is another LLVM. A new Mojo is a new instrumenter: re-run the version coupling (README.md, Updating) before changing lld= in BUCK", .{major});
    c.pass();
    c.green();
}

const libs23 = [_][]const u8{ "libLLVM.so.23.1", "libgcc_s.so.1", "libiconv.so.2", "libstdc++.so.6", "libxml2.so.16", "libz.so.1", "libzstd.so.1" };
const runtime = "runtime/libclang_rt.profile-x86_64.a";

fn toolsMode(c: *Ctx) void {
    const version = c.want("profdata");
    const symbols = c.want("symbols");
    var names = std.ArrayList([]const u8).init(c.a);
    names.appendSlice(&.{ "bin/llvm-nm", "bin/llvm-profdata", runtime }) catch @panic("oom");
    for (libs23) |l| names.append(c.print("lib/{s}", .{l})) catch @panic("oom");
    c.exactly(c.tools_dir, names.items);
    const profdata = c.join(&.{ c.tools_dir, "bin/llvm-profdata" });
    const nm = c.join(&.{ c.tools_dir, "bin/llvm-nm" });
    if (!c.executable(profdata) or !c.executable(nm)) c.red("bin/llvm-profdata or bin/llvm-nm is not executable", .{});
    c.pass();
    const out = c.run(&.{ profdata, "--version" }, null) orelse c.red("llvm-profdata --version failed", .{});
    c.writeReport("profdata_version.txt", out);
    const needle = c.print("LLVM version {s}", .{version});
    if (std.mem.indexOf(u8, out, needle) == null) c.red("llvm-profdata --version does not print 'LLVM version {s}' (the profdata= of BUCK)", .{version});
    c.pass();
    const rt = c.join(&.{ c.tools_dir, runtime });
    const head = blk: {
        const f = std.fs.cwd().openFile(rt, .{}) catch |e| c.red("cannot open {s}: {s}", .{ rt, @errorName(e) });
        defer f.close();
        var buf: [8]u8 = undefined;
        const n = f.readAll(&buf) catch 0;
        break :blk buf[0..n];
    };
    if (!std.mem.eql(u8, head, "!<arch>\n")) c.red("{s} is not an ar archive", .{runtime});
    const listing = c.run(&.{ nm, "-g", "--defined-only", rt }, null) orelse c.red("llvm-nm failed on {s}", .{runtime});
    var syms = std.mem.splitScalar(u8, symbols, ',');
    while (syms.next()) |s| {
        if (s.len == 0) continue;
        if (!nmDefines(listing, s)) c.red("{s} does not define {s}: it is not the profile runtime a coverage build links", .{ runtime, s });
    }
    c.pass();
    c.green();
}

fn rawVersionMode(c: *Ctx) void {
    const functions = c.want("functions");
    const counts = c.want("counts");
    const raw = c.want("raw");
    const triple = c.want("triple");
    const w = c.join(&.{ c.t, "w" });
    std.fs.cwd().makePath(w) catch |e| c.red("cannot create {s}: {s}", .{ w, @errorName(e) });
    const zig = c.join(&.{ c.zig, "zig" });
    const lld = c.join(&.{ c.lld_dir, "bin/lld" });
    const nm = c.join(&.{ c.tools_dir, "bin/llvm-nm" });
    const rt = c.join(&.{ c.tools_dir, runtime });
    const bc = c.join(&.{ w, "fixture.bc" });
    const fix = c.join(&.{ c.fixtures, "profile_fixture.c" });
    _ = c.run(&.{ zig, "cc", "-target", triple, "-c", "-emit-llvm", "-O0", "-g0", "-fno-sanitize=undefined", fix, "-o", bc }, null) orelse
        c.red("zig cc could not compile the fixture to bitcode", .{});
    {
        const d = c.readFile(bc);
        if (d.len < 4 or !std.mem.eql(u8, d[0..4], "\x42\x43\xc0\xde")) c.red("zig cc -emit-llvm did not write LLVM bitcode", .{});
    }
    c.pass();
    const pg = c.join(&.{ w, "pg.o" });
    _ = c.run(&.{ lld, "-flavor", "gnu", "-r", "-m", "elf_x86_64", bc, "-o", pg, "--lto-O0", "--lto-newpm-passes=pgo-instr-gen,instrprof,default<O0>" }, null) orelse
        c.red("lld could not instrument the fixture", .{});
    // Who defines the version the runtime writes: the instrumented object
    // strongly, the runtime archive weakly (llvm-nm classes: an upper-case
    // letter is global; U is undefined, W and V are weak).
    const pg_nm = c.run(&.{ nm, pg }, null) orelse c.red("llvm-nm failed on the instrumented fixture", .{});
    const pg_class = nmClasses(c.a, pg_nm, "__llvm_profile_raw_version") catch @panic("oom");
    if (!(pg_class.len == 2 and std.mem.indexOfScalar(u8, "ABDGRST", pg_class[0]) != null and pg_class[1] == ' '))
        c.red("the instrumented fixture does not define __llvm_profile_raw_version strongly (llvm-nm class '{s}'): the version in the raw profile would be the runtime's default, not LLVM 24's", .{std.mem.trimRight(u8, pg_class, " ")});
    const rt_nm = c.run(&.{ nm, "--defined-only", rt }, null) orelse c.red("llvm-nm failed on {s}", .{runtime});
    const rt_class = nmClasses(c.a, rt_nm, "__llvm_profile_raw_version") catch @panic("oom");
    if (!(rt_class.len == 2 and (rt_class[0] == 'V' or rt_class[0] == 'W') and rt_class[1] == ' '))
        c.red("{s} does not define __llvm_profile_raw_version once and weakly (llvm-nm classes '{s}'): it would override or clash with the instrumenter's", .{ runtime, std.mem.trimRight(u8, rt_class, " ") });
    c.writeReport("raw_version_symbol.txt", c.print("__llvm_profile_raw_version: instrumented fixture {s}, runtime {s}\n", .{ std.mem.trimRight(u8, pg_class, " "), std.mem.trimRight(u8, rt_class, " ") }));
    c.pass();
    const exe = c.join(&.{ w, "pg.exe" });
    _ = c.run(&.{ zig, "cc", "-target", triple, pg, "-Wl,--whole-archive", rt, "-Wl,--no-whole-archive", "-o", exe }, null) orelse
        c.red("zig cc could not link the instrumented fixture with the profile runtime", .{});
    const profraw = c.join(&.{ w, "pg.profraw" });
    c.env.put("LLVM_PROFILE_FILE", profraw) catch @panic("oom");
    var rc: u32 = 0;
    _ = c.run(&.{exe}, &rc);
    _ = c.env.remove("LLVM_PROFILE_FILE");
    if (rc != 0) c.red("the instrumented fixture exited {d}", .{rc});
    {
        const st = std.fs.cwd().statFile(profraw) catch c.red("the instrumented fixture wrote no raw profile", .{});
        if (st.size == 0) c.red("the instrumented fixture wrote no raw profile", .{});
    }
    c.pass();
    const v = rawVersion(c, profraw);
    const flags = std.mem.readInt(u32, c.readFile(profraw)[12..16], .little);
    c.writeReport("raw_version.txt", c.print("raw profile version {d}, variant flags 0x{x:0>8}\n", .{ v, flags }));
    if (flags & 0x01000000 == 0)
        c.red("the raw profile's variant flags 0x{x:0>8} lack the IR-instrumentation bit 0x01000000: its version word is the runtime's default, not the instrumenter's", .{flags});
    c.pass();
    const profdata_out = c.join(&.{ w, "pg.profdata" });
    if (accepts(c, profraw, profdata_out)) |why| c.red("{s} (README.md, The version coupling)", .{why});
    const raw_n = std.fmt.parseInt(u32, raw, 10) catch c.red("raw={s} is not a number", .{raw});
    if (v != raw_n)
        c.red("llvm-profdata accepts raw version {d}, but RAW_PROFILE_VERSION of defs.bzl, which every branch coverage run requires of each raw profile, is {s}: change it to {d} (README.md, Updating)", .{ v, raw, v });
    c.pass();
    const profdata = c.join(&.{ c.tools_dir, "bin/llvm-profdata" });
    const show = c.run(&.{ profdata, "show", profdata_out }, null) orelse c.red("llvm-profdata show failed", .{});
    c.writeReport("show.txt", show);
    const total = c.print("Total functions: {s}", .{functions});
    if (!hasLine(show, total)) c.red("llvm-profdata show does not report '{s}'", .{total});
    const colon = std.mem.indexOfScalar(u8, counts, ':') orelse c.red("counts={s} is not <function>:<count>,...", .{counts});
    const fname = counts[0..colon];
    const fn_arg = c.print("--function={s}", .{fname});
    const shown = c.run(&.{ profdata, "show", "--counts", fn_arg, profdata_out }, null) orelse c.red("llvm-profdata show --function={s} failed", .{fname});
    c.writeReport(c.print("show_{s}.txt", .{fname}), shown);
    const got = blockCounts(c.a, shown) catch @panic("oom");
    const expect = c.print("{s},", .{counts[colon + 1 ..]});
    if (!std.mem.eql(u8, got, expect)) c.red("llvm-profdata show reports the counters of {s} as '{s}', not '{s}'", .{ fname, got, counts[colon + 1 ..] });
    c.pass();
    // The version is the low byte of a little-endian field whose next three
    // bytes are 0 (a version of 255 or more would need more than one byte).
    if (v >= 255) c.red("raw version {d} does not fit the one-byte doctoring of check 7", .{v});
    const doctored = c.join(&.{ w, "doctored.profraw" });
    {
        const d = c.readFile(profraw);
        d[8] = @intCast(v + 1);
        writeFile(doctored, d) catch |e| c.red("could not write the doctored profile: {s}", .{@errorName(e)});
    }
    if (rawVersion(c, doctored) != v + 1) c.red("could not write version {d} into the doctored profile", .{v + 1});
    const why = accepts(c, doctored, c.join(&.{ w, "doctored.profdata" })) orelse
        c.red("llvm-profdata accepted raw version {d}: the version check cannot fail", .{v + 1});
    const want_prefix = c.print("raw profile version {d} not accepted by llvm-profdata ", .{v + 1});
    const want_mid = c.print(", which expects {d}: ", .{v});
    if (!(std.mem.startsWith(u8, why, want_prefix) and std.mem.indexOf(u8, why, want_mid) != null))
        c.red("the doctored profile was refused, but not for its version: {s}", .{why});
    c.appendReport("raw_version.txt", c.print("doctored: {s}\n", .{why}));
    c.pass();
    c.green();
}

fn hasLine(text: []const u8, line: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        if (std.mem.eql(u8, l, line)) return true;
    }
    return false;
}

fn check(a: A, args: []const []const u8) !void {
    if (args.len < 6) {
        std.debug.print("usage: llvm_branch check <mode> <zig_dir> <report_dir> <lld_dir|-> <tools_dir|-> <fixture_dir|-> <key>=<value>...\n", .{});
        std.process.exit(2);
    }
    const mode = args[0];
    const t = try scratchDir(a, try std.fmt.allocPrint(a, "llvm_branch_{s}", .{mode}));
    try std.fs.cwd().makePath(try std.fs.path.join(a, &.{ t, "home" }));
    var env = try std.process.getEnvMap(a);
    try env.put("LC_ALL", "C");
    try env.put("ZIG_GLOBAL_CACHE_DIR", try std.fs.path.join(a, &.{ t, "zig-global" }));
    try env.put("ZIG_LOCAL_CACHE_DIR", try std.fs.path.join(a, &.{ t, "zig-local" }));
    try env.put("HOME", try std.fs.path.join(a, &.{ t, "home" }));
    const opt = struct {
        fn f(s: []const u8) []const u8 {
            return if (std.mem.eql(u8, s, "-")) "" else s;
        }
    }.f;
    var c = Ctx{ .a = a, .mode = mode, .zig = args[1], .report = args[2], .lld_dir = opt(args[3]), .tools_dir = opt(args[4]), .fixtures = opt(args[5]), .want_args = args[6..], .t = t, .env = env };
    try std.fs.cwd().makePath(c.report);
    if (std.mem.eql(u8, mode, "lld")) {
        if (c.lld_dir.len == 0) c.red("lld needs <lld_dir>", .{});
        lldMode(&c);
    } else if (std.mem.eql(u8, mode, "tools")) {
        if (c.tools_dir.len == 0) c.red("tools needs <tools_dir>", .{});
        toolsMode(&c);
    } else if (std.mem.eql(u8, mode, "raw_version")) {
        if (c.lld_dir.len == 0 or c.tools_dir.len == 0 or c.fixtures.len == 0) c.red("raw_version needs <lld_dir>, <tools_dir> and <fixture_dir>", .{});
        rawVersionMode(&c);
    } else c.red("unknown mode '{s}'", .{mode});
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "unpack")) return unpack(a, argv[2..]);
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "check")) return check(a, argv[2..]);
    std.debug.print("usage: llvm_branch unpack|check ...\n", .{});
    std.process.exit(2);
}
