//! The kcov guard (tools/build/package/kcov_guard.bzl; README.md, "kcov is
//! never packed"). kcov is GPL-2.0 and a build-only tool: no published
//! artifact may hold it. `guard` refuses, naming each, every file whose sha256
//! is the pinned bin/kcov's or whose bytes contain kcov's usage line (the
//! constants of tools/build/toolchains/kcov/identity.bzl); `cases` runs the
//! guard on inputs whose answer is known, with a fixture file standing for
//! bin/kcov, and writes a validation report. Reads no kcov.
//!
//! This replaces kcov_guard.sh, with the same refusals in the same words.

const std = @import("std");
const U = @import("act_util");

pub const Identity = struct {
    /// KCOV_BIN_SHA256: 64 lower-case hex digits.
    ksum: []const u8,
    /// KCOV_USAGE_LINE: a line of text, not empty, without a newline.
    marker: []const u8,
};

/// A (dest, path) pair: `path` is a file, or a directory whose every regular
/// file is read (symbolic links followed); `dest` is where the packer puts it
/// (`.` for the root of a directory) and what a refusal calls the file.
pub const Pair = struct { dest: []const u8, path: []const u8 };

/// Fails unless the sha256 is 64 lower-case hex digits and the line is not
/// empty: a malformed sha256 would refuse nothing by it, and an empty line
/// every file. (A line with a newline is refused too: it could never match
/// within one line of a file, the shell guard's grep.)
pub fn argsOk(out: *U.Out, mode: []const u8, id: Identity) !void {
    var ok = id.ksum.len == 64;
    for (id.ksum) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) ok = false;
    }
    if (!ok) return U.refuse(out, "kcov_guard {s}: the kcov sha256 '{s}' is not 64 lowercase hex digits (KCOV_BIN_SHA256, tools/build/toolchains/kcov/identity.bzl)\n", .{ mode, id.ksum });
    if (id.marker.len == 0) return U.refuse(out, "kcov_guard {s}: the kcov usage line is empty (KCOV_USAGE_LINE, tools/build/toolchains/kcov/identity.bzl)\n", .{mode});
    if (std.mem.indexOfScalar(u8, id.marker, '\n') != null) return U.refuse(out, "kcov_guard {s}: the kcov usage line has a newline (KCOV_USAGE_LINE, tools/build/toolchains/kcov/identity.bzl)\n", .{mode});
}

/// The refusal line for one file, or null when it is not kcov: by its sha256,
/// else by the usage line anywhere in its bytes (a binary's NUL bytes included).
pub fn judge(a: std.mem.Allocator, id: Identity, name: []const u8, data: []const u8) !?[]u8 {
    const sum = U.sha256Hex(data);
    if (std.mem.eql(u8, &sum, id.ksum)) {
        return try std.fmt.allocPrint(a, "  {s} is kcov's bin/kcov (sha256 {s})\n", .{ name, &sum });
    }
    if (U.contains(data, id.marker)) {
        return try std.fmt.allocPrint(a, "  {s} holds kcov's usage line '{s}': it is kcov, embeds kcov, or copies its help text\n", .{ name, id.marker });
    }
    return null;
}

/// Runs the guard over `pairs` for the target `what`. On a refusal (or a path
/// that is neither a file nor a directory, or one that cannot be read) the
/// text for stderr is in `out` and the result is `error.Refused`.
pub fn guard(a: std.mem.Allocator, out: *U.Out, mode: []const u8, id: Identity, what: []const u8, pairs: []const Pair) !void {
    var refused = std.ArrayList(u8).empty;
    // A file is read whole and freed after it is judged: a bundle holds
    // libraries of tens of megabytes.
    const big = std.heap.page_allocator;
    for (pairs) |p| {
        const st = std.fs.cwd().statFile(p.path) catch |e| switch (e) {
            error.FileNotFound => return U.refuse(out, "kcov_guard {s}: {s}: {s} ({s}) is neither a file nor a directory\n", .{ mode, what, p.path, p.dest }),
            else => return U.refuse(out, "kcov_guard {s}: {s}: cannot stat {s}: {s}\n", .{ mode, what, p.path, @errorName(e) }),
        };
        switch (st.kind) {
            .directory => {
                var dir = std.fs.cwd().openDir(p.path, .{ .iterate = true }) catch |e| return U.refuse(out, "kcov_guard {s}: {s}: cannot list {s}: {s}\n", .{ mode, what, p.path, @errorName(e) });
                defer dir.close();
                const files = U.listFiles(a, dir, true) catch |e| return U.refuse(out, "kcov_guard {s}: {s}: cannot list {s}: {s}\n", .{ mode, what, p.path, @errorName(e) });
                for (files) |rel| {
                    const name = if (std.mem.eql(u8, p.dest, ".")) rel else try std.fmt.allocPrint(a, "{s}/{s}", .{ p.dest, rel });
                    const data = dir.readFileAlloc(big, rel, 1 << 30) catch |e| return U.refuse(out, "kcov_guard {s}: cannot read {s}/{s}: {s}\n", .{ mode, p.path, rel, @errorName(e) });
                    defer big.free(data);
                    if (try judge(a, id, name, data)) |line| try refused.appendSlice(a, line);
                }
            },
            .file => {
                const data = std.fs.cwd().readFileAlloc(big, p.path, 1 << 30) catch |e| return U.refuse(out, "kcov_guard {s}: cannot read {s}: {s}\n", .{ mode, p.path, @errorName(e) });
                defer big.free(data);
                if (try judge(a, id, p.dest, data)) |line| try refused.appendSlice(a, line);
            },
            else => return U.refuse(out, "kcov_guard {s}: {s}: {s} ({s}) is neither a file nor a directory\n", .{ mode, what, p.path, p.dest }),
        }
    }
    if (refused.items.len == 0) return;
    return U.refuse(out, "{s} packs kcov, a build-only tool: kcov is GPL-2.0, and no published artifact may contain it (tools/build/toolchains/kcov/README.md, \"Licences\"). Refused:\n{s}", .{ what, refused.items });
}

/// `guard <ksum> <marker> <out> <what> [<dest> <path>]...`
pub fn runGuard(a: std.mem.Allocator, args: []const []const u8) u8 {
    if (args.len < 4) {
        std.debug.print("usage: pkg_act kcov-guard guard <kcov_sha256> <usage_line> <out> <what> [<dest> <path>]...\n", .{});
        return 2;
    }
    const id = Identity{ .ksum = args[0], .marker = args[1] };
    var out = U.Out.init(a);
    argsOk(&out, "guard", id) catch return fail(out.items);
    const what = args[3];
    const rest = args[4..];
    if (rest.len % 2 != 0) {
        std.debug.print("kcov_guard guard: {s}: <dest> {s} has no <path>\n", .{ what, rest[rest.len - 1] });
        return 1;
    }
    var pairs = std.ArrayList(Pair).empty;
    var i: usize = 0;
    while (i < rest.len) : (i += 2) pairs.append(a, .{ .dest = rest[i], .path = rest[i + 1] }) catch return 2;
    guard(a, &out, "guard", id, what, pairs.items) catch return fail(out.items);
    U.writeAll(std.fs.cwd(), args[2], "ok\n") catch |e| {
        std.debug.print("kcov_guard guard: cannot write {s}: {s}\n", .{ args[2], @errorName(e) });
        return 2;
    };
    return 0;
}

fn fail(text: []const u8) u8 {
    std.debug.print("{s}", .{text});
    return 1;
}

/// The fixture's sha256, written out and not computed, so a wrong hash
/// function is red as well.
pub const fixture_sha256 = "177f9e3e45d0314ec5a7001df49c20a2f2ca26c5ac681aa5a89e387c4b64854b";
pub const fixture_text = "kcov_guard cases: this file stands for bin/kcov; the guard is given its sha256\n";

const Cases = struct {
    a: std.mem.Allocator,
    id: Identity,
    root: std.fs.Dir,
    root_path: []const u8,
    exe: []const u8,
    n: usize = 0,
    why: []const u8 = "",

    fn red(self: *Cases, comptime fmt: []const u8, args: anytype) error{Red} {
        self.why = std.fmt.allocPrint(self.a, "kcov_guard cases: RED: " ++ fmt ++ "\n", args) catch "kcov_guard cases: RED\n";
        return error.Red;
    }

    fn path(self: *Cases, rel: []const u8) ![]u8 {
        return std.fs.path.join(self.a, &.{ self.root_path, rel });
    }

    /// The guard over `pairs` in this process: its exit status (0 or 1) and
    /// the text it printed.
    fn run(self: *Cases, case: []const u8, pairs: []const Pair) !struct { rc: u8, text: []const u8 } {
        var out = U.Out.init(self.a);
        guard(self.a, &out, "cases", self.id, case, pairs) catch |e| switch (e) {
            error.Refused => return .{ .rc = 1, .text = out.items },
            else => return e,
        };
        return .{ .rc = 0, .text = out.items };
    }

    /// The guard's exit status is `want`, and a refusal names each of `names`.
    fn expect(self: *Cases, case: []const u8, want: u8, names: []const []const u8, pairs: []const Pair) !void {
        const r = try self.run(case, pairs);
        if (r.rc != want) return self.red("{s}: guard exited {d}, want {d}: {s}", .{ case, r.rc, want, r.text });
        for (names) |n| {
            const needle = try std.fmt.allocPrint(self.a, "  {s} ", .{n});
            if (!U.contains(r.text, needle)) return self.red("{s}: the refusal does not name {s}: {s}", .{ case, n, r.text });
        }
        self.n += 1;
    }

    fn put(self: *Cases, rel: []const u8, data: []const u8) !void {
        try U.makeParent(self.root, rel);
        try U.writeAll(self.root, rel, data);
    }

    /// The guard as the package rules run it, in its own process: the sha256 and the
    /// line reach the checks from their positions, and <out> is written only when
    /// nothing is refused.
    fn cli(self: *Cases, case: []const u8, want: u8, message: []const u8, dir: []const u8) !void {
        const a = self.a;
        self.root.deleteFile("cli.out") catch {};
        const what = try std.fmt.allocPrint(a, "cli_{s}", .{case});
        const out_path = try self.path("cli.out");
        const r = try U.runCapture(a, &.{ self.exe, "kcov-guard", "guard", self.id.ksum, self.id.marker, out_path, what, ".", dir }, null, null);
        if (r.code != want) return self.red("cli_{s}: guard exited {d}, want {d}: {s}", .{ case, r.code, want, r.stderr });
        if (want == 0) {
            const got = try U.readAll(a, self.root, "cli.out");
            if (!std.mem.eql(u8, std.mem.trimRight(u8, got, "\n"), "ok")) return self.red("cli_{s}: accepted, but <out> is not 'ok'", .{case});
            if (r.stderr.len != 0) return self.red("cli_{s}: accepted, but the guard printed {s}", .{ case, r.stderr });
        } else {
            if (self.root.access("cli.out", .{})) |_| {
                return self.red("cli_{s}: refused, but <out> was written", .{case});
            } else |_| {}
            if (!U.contains(r.stderr, message)) return self.red("cli_{s}: the refusal does not say '{s}': {s}", .{ case, message, r.stderr });
        }
        self.n += 1;
    }

    fn all(self: *Cases) !void {
        const a = self.a;
        const marker = self.id.marker;
        // The pinned constants' form is checked first (the package rules' own).
        {
            var out = U.Out.init(a);
            argsOk(&out, "cases", self.id) catch return self.red("the pinned constants: {s}", .{out.items});
        }
        // The fixture stands for bin/kcov: the cases need no kcov.
        try self.put("fixture", fixture_text);
        const fx = U.sha256Hex(fixture_text);
        if (!std.mem.eql(u8, &fx, fixture_sha256)) return self.red("sha: the fixture's sha256 is {s}, want {s}", .{ &fx, fixture_sha256 });
        if (U.contains(fixture_text, marker)) return self.red("the fixture holds the usage line, so the sha256 cases show nothing", .{});
        // From here on every guard run is given the fixture's sha256.
        const fid = Identity{ .ksum = fixture_sha256, .marker = marker };
        self.id = fid;
        const f = self;
        {
            var out = U.Out.init(a);
            argsOk(&out, "cases", fid) catch return f.red("the fixture's constants: {s}", .{out.items});
        }

        // The arguments: a sha256 one digit short, one in upper case, and an
        // empty usage line are refused before any file is read.
        const upper = try std.ascii.allocUpperString(a, fixture_sha256);
        const bad = [_]Identity{
            .{ .ksum = fixture_sha256[0 .. fixture_sha256.len - 1], .marker = marker },
            .{ .ksum = upper, .marker = marker },
            .{ .ksum = fixture_sha256, .marker = "" },
        };
        for (bad) |b| {
            var out = U.Out.init(a);
            if (argsOk(&out, "cases", b)) |_| {
                return f.red("args_ok accepted the sha256 '{s}' and the line '{s}'", .{ b.ksum, b.marker });
            } else |_| {}
            f.n += 1;
        }

        // Refused by sha256 (the fixture holds no usage line): renamed, as a
        // directory's file, as a file, and under a destination path.
        try f.put("copy/lib/libcopy.so", fixture_text);
        const copy_dir = try f.path("copy");
        const copy_so = try f.path("copy/lib/libcopy.so");
        try f.expect("copy_in_dir", 1, &.{"lib/libcopy.so"}, &.{.{ .dest = ".", .path = copy_dir }});
        {
            const r = try f.run("copy_in_dir", &.{.{ .dest = ".", .path = copy_dir }});
            const want = try std.fmt.allocPrint(a, "lib/libcopy.so is kcov's bin/kcov (sha256 {s})", .{fixture_sha256});
            if (!U.contains(r.text, want)) return f.red("copy_in_dir: not refused by sha256: {s}", .{r.text});
        }
        try f.expect("copy_as_file", 1, &.{"lib/mojo/x.mojoc"}, &.{.{ .dest = "lib/mojo/x.mojoc", .path = copy_so }});
        try f.expect("copy_under_dest", 1, &.{"opt/x/lib/libcopy.so"}, &.{.{ .dest = "opt/x", .path = copy_dir }});

        // Refused by the usage line: a kcov built otherwise (another sha256)
        // holding the line, and the line alone between NUL bytes, as in a
        // binary's string table.
        try f.put("changed/bin/tool", try std.fmt.allocPrint(a, "{s}\x00{s}\x00", .{ fixture_text, marker }));
        const changed = try f.path("changed");
        try f.expect("changed", 1, &.{"bin/tool"}, &.{.{ .dest = ".", .path = changed }});
        {
            const r = try f.run("changed", &.{.{ .dest = ".", .path = changed }});
            if (!U.contains(r.text, "bin/tool holds kcov's usage line")) return f.red("changed: not refused by the usage line: {s}", .{r.text});
        }
        try f.put("embed/share/blob.bin", try std.fmt.allocPrint(a, "ELF\x00\x01\x02 text\x00{s}\x00tail", .{marker}));
        const embed = try f.path("embed");
        try f.expect("embedded", 1, &.{"share/blob.bin"}, &.{.{ .dest = ".", .path = embed }});

        // Every offending file is named, across arguments.
        try f.expect("two", 1, &.{ "lib/libcopy.so", "share/blob.bin" }, &.{ .{ .dest = ".", .path = copy_dir }, .{ .dest = ".", .path = embed } });

        // Symlinks are followed: one to the fixture's copy, and one to a
        // directory holding it, are each refused under the link's name.
        try f.root.makePath("link/share");
        try f.root.symLink(copy_so, "link/share/k", .{});
        try f.root.symLink(copy_dir, "link/dir", .{});
        try f.expect("symlinked", 1, &.{ "share/k", "dir/lib/libcopy.so" }, &.{.{ .dest = ".", .path = try f.path("link") }});

        // Accepted: near misses of kcov's line (written out, so a usage line
        // shortened in identity.bzl refuses one and is red here), the line
        // broken by a NUL or a newline, and the fixture with one byte more (the
        // sha256 is of the whole file).
        try f.put("near/share/dots.txt", "Usage: kcov [OPTIONS] out-dir in-file [args..]\n");
        try f.put("near/share/case.txt", "usage: kcov [OPTIONS] out-dir in-file [args...]\n");
        try f.put("near/share/nul.bin", "Usage: kcov [OPTIONS] out-dir\x00in-file [args...]\n");
        try f.put("near/share/newline.txt", "Usage: kcov [OPTIONS] out-dir\nin-file [args...]\n");
        try f.put("near/share/version.txt", "kcov v42\nv42\x00Usage: kcov [OPTIONS]\n");
        try f.put("near/lib/longer.so", try std.fmt.allocPrint(a, "{s}x", .{fixture_text}));
        const near = try f.path("near");
        {
            const r = try f.run("near_misses", &.{.{ .dest = ".", .path = near }});
            if (r.rc != 0) return f.red("near_misses: guard exited {d}, want 0: {s}", .{ r.rc, r.text });
            if (r.text.len != 0) return f.red("near_misses: the guard printed {s}", .{r.text});
            f.n += 1;
        }
        try f.expect("nothing", 0, &.{}, &.{});

        // The guard through its command line, as the package rules run it.
        const sha_msg = try std.fmt.allocPrint(a, "lib/libcopy.so is kcov's bin/kcov (sha256 {s})", .{fixture_sha256});
        const line_msg = try std.fmt.allocPrint(a, "share/blob.bin holds kcov's usage line '{s}'", .{marker});
        try f.cli("sha", 1, sha_msg, copy_dir);
        try f.cli("line", 1, line_msg, embed);
        try f.cli("near", 0, "", near);
    }
};

/// `cases <ksum> <marker> <report_dir>`: writes `<report_dir>/validation.json`.
pub fn runCases(a: std.mem.Allocator, args: []const []const u8, exe: []const u8) u8 {
    if (args.len != 3) {
        std.debug.print("usage: pkg_act kcov-guard cases <kcov_sha256> <usage_line> <report_dir>\n", .{});
        return 2;
    }
    const cwd = std.fs.cwd().realpathAlloc(a, ".") catch return 2;
    const report = args[2];
    std.fs.cwd().makePath(report) catch |e| {
        std.debug.print("kcov_guard cases: cannot create {s}: {s}\n", .{ report, @errorName(e) });
        return 2;
    };
    // The fixtures live in a scratch directory beside the report, removed after.
    const scratch = U.scratchRoot(a, cwd, std.posix.getenv("BUCK_SCRATCH_PATH")) catch return 2;
    const work = std.fs.path.join(a, &.{ scratch, "kcov_guard_cases" }) catch return 2;
    std.fs.cwd().deleteTree(work) catch {};
    std.fs.cwd().makePath(work) catch |e| {
        std.debug.print("kcov_guard cases: cannot create {s}: {s}\n", .{ work, @errorName(e) });
        return 2;
    };
    defer std.fs.cwd().deleteTree(work) catch {};
    var root = std.fs.cwd().openDir(work, .{ .iterate = true }) catch return 2;
    defer root.close();
    var c = Cases{ .a = a, .id = .{ .ksum = args[0], .marker = args[1] }, .root = root, .root_path = work, .exe = exe };
    c.all() catch |e| {
        if (e == error.Red) {
            std.debug.print("{s}", .{c.why});
        } else {
            std.debug.print("kcov_guard cases: {s}\n", .{@errorName(e)});
        }
        return 1;
    };
    const json = std.fmt.allocPrint(a, "{{\"version\": 1, \"data\": {{\"status\": \"success\", \"message\": \"kcov_guard cases: {d} cases passed\"}}}}\n", .{c.n}) catch return 2;
    const path = std.fs.path.join(a, &.{ report, "validation.json" }) catch return 2;
    U.writeAll(std.fs.cwd(), path, json) catch |e| {
        std.debug.print("kcov_guard cases: cannot write {s}: {s}\n", .{ path, @errorName(e) });
        return 2;
    };
    return 0;
}
