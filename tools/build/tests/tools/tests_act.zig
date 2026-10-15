// Why Zig: build tools are Zig (tools/build/README.md). These are the actions the
// tests cell's rules ran as busybox shell snippets, so that its tests run no shell.
//! tests_act: the checks the tests cell's rules run as build actions.
//!
//! usage: tests_act gen-check <gen> <mark> <files> <n absent> <m identical>
//!                   <absent>... (<name> <source>)... <present>...
//!        tests_act tests-check <mark> <expected tests> <marker>...
//!        tests_act same-bytes <a> <b> <report>
//!        tests_act test-command <label> <report> -- <command>...
//!        tests_act delete-member <source dir> <dest dir> <member>
//!        tests_act re-probe <toolchain dir> <report>
//!        tests_act loader-trace <wrapper> <launcher> <toolchain> <zig> <cc target> <cpu> <source> <exe> <report>
//!        tests_act proto-gen <protoc dir> <plugin> <corpus> <out dir> <options> <n roots> <root>... <import path>...
//!        tests_act proto-check <gen> <golden dir or ""> <expected error or ""> <mark> <n absent> <absent>... <present>...
//!        tests_act rest-extract <generated file> <out>
//!        tests_act aws-gen <generator> <out dir> <module> <probe 0|1> -- <generator args>...
//!        tests_act aws-refuse <generator> <stamp> <message> <probe 0|1> -- <generator args>...
//!        tests_act aws-cmp <stamp> <gen dir> <module> <golden> <golden probe|-> [<must contain>...]
//!        tests_act bundle-parity <runnable dir> <binary> <bundle> <out>
//!        tests_act stand-in-archive <busybox> <out.tar.gz> <top> (file:<path>|program:<path>)...
//!
//! Each exits 0 when its check holds, 1 when it does not (saying what, on stderr),
//! and 2 for a usage error or a failure of its own. The shell snippets they
//! replace are in this directory's history.
//!
//! gen-check: the generated directory <gen> holds exactly the entries <files> (a
//! space-separated list), no file under it holds an <absent> string, each
//! <source> is byte for byte <gen>/<name>, and some file holds each <present>
//! string; <mark> then holds `ok`.
//! tests-check: the markers (a library's welded tests' `.passed` files) each
//! record `PASS `, and their names without `.passed` are exactly <expected tests>.
//! same-bytes: two non-empty files with the same bytes; <report> gets their sha256.
//! test-command: runs the command and requires it to pass; <report> gets `ok <label>`.
//! delete-member: copies <source dir> to <dest dir> (links kept) and deletes <member>.
//! re-probe: a report of what the worker provides (probes.zig).
//! loader-trace: one compile and one run, with the loader's record of what each
//! mapped and initialized; exits 1 unless both succeed (probes.zig).
//! proto-gen, proto-check, rest-extract: the golden checks of protoc-gen-mojo
//! (proto_checks.zig).
//! aws-gen, aws-refuse, aws-cmp: the checks over aws-client-gen (aws_checks.zig).
//! bundle-parity: a program built as an executable and as a bundle, run through the
//! same cases (parity.zig).
//! stand-in-archive: a `.tar.gz` of the named files and programs (archives.zig).

const std = @import("std");
const A = std.mem.Allocator;
const probes = @import("probes.zig");
const archives = @import("archives.zig");
const proto_checks = @import("proto_checks.zig");
const aws_checks = @import("aws_checks.zig");
const parity = @import("parity.zig");

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(1);
}

fn usage(comptime what: []const u8) noreturn {
    std.debug.print("tests_act: usage: " ++ what ++ "\n", .{});
    std.process.exit(2);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn readAll(a: A, path: []const u8) []u8 {
    return std.fs.cwd().readFileAlloc(a, path, 1 << 30) catch |e| {
        std.debug.print("tests_act: cannot read {s}: {s}\n", .{ path, @errorName(e) });
        std.process.exit(2);
    };
}

fn writeAll(path: []const u8, data: []const u8) void {
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

/// The entries of `dir` (`ls -A`), sorted and joined, each followed by a blank.
pub fn listingWords(a: A, dir: std.fs.Dir) ![]u8 {
    var names = std.ArrayList([]const u8).init(a);
    var it = dir.iterate();
    while (try it.next()) |e| try names.append(try a.dupe(u8, e.name));
    std.mem.sort([]const u8, names.items, {}, lessThan);
    var out = std.ArrayList(u8).init(a);
    for (names.items) |n| {
        try out.appendSlice(n);
        try out.append(' ');
    }
    return out.toOwnedSlice();
}

/// The files under `dir` (recursively, links not followed) that hold `needle`, sorted.
pub fn grepFiles(a: A, dir: std.fs.Dir, base: []const u8, needle: []const u8) ![][]const u8 {
    var hits = std.ArrayList([]const u8).init(a);
    var w = try dir.walk(a);
    while (try w.next()) |e| {
        if (e.kind != .file) continue;
        const data = try dir.readFileAlloc(a, e.path, 1 << 30);
        if (std.mem.indexOf(u8, data, needle) != null) try hits.append(try std.fs.path.join(a, &.{ base, e.path }));
    }
    std.mem.sort([]const u8, hits.items, {}, lessThan);
    return hits.toOwnedSlice();
}

fn genCheck(a: A, args: []const []const u8) void {
    if (args.len < 5) usage("gen-check <gen> <mark> <files> <n absent> <m identical> ...");
    const gen = args[0];
    const mark = args[1];
    const files = args[2];
    const n = std.fmt.parseInt(usize, args[3], 10) catch usage("gen-check: n absent is a number");
    const m = std.fmt.parseInt(usize, args[4], 10) catch usage("gen-check: m identical is a number");
    const rest = args[5..];
    if (rest.len < n + 2 * m) usage("gen-check: fewer arguments than the counts name");
    var dir = std.fs.cwd().openDir(gen, .{ .iterate = true }) catch |e| {
        std.debug.print("tests_act: cannot open {s}: {s}\n", .{ gen, @errorName(e) });
        std.process.exit(2);
    };
    defer dir.close();
    const got = listingWords(a, dir) catch @panic("oom");
    const want = std.fmt.allocPrint(a, "{s} ", .{files}) catch @panic("oom");
    if (!std.mem.eql(u8, got, want)) {
        fail("the generated directory holds: {s}\nexpected exactly:              {s}", .{ got, files });
    }
    for (rest[0..n]) |s| {
        const hits = grepFiles(a, dir, gen, s) catch @panic("oom");
        if (hits.len > 0) {
            for (hits) |h| std.debug.print("{s}\n", .{h});
            fail("the generated files above hold `{s}`, which must be absent", .{s});
        }
    }
    var i: usize = 0;
    while (i < m) : (i += 1) {
        const name = rest[n + 2 * i];
        const src = rest[n + 2 * i + 1];
        const want_bytes = readAll(a, src);
        const got_path = std.fs.path.join(a, &.{ gen, name }) catch @panic("oom");
        const got_bytes = std.fs.cwd().readFileAlloc(a, got_path, 1 << 30) catch "\x00missing";
        if (!std.mem.eql(u8, want_bytes, got_bytes)) fail("the generated {s} is not byte for byte {s}", .{ name, src });
    }
    for (rest[n + 2 * m ..]) |s| {
        const hits = grepFiles(a, dir, gen, s) catch @panic("oom");
        if (hits.len == 0) fail("no generated file holds `{s}`", .{s});
    }
    writeAll(mark, "ok\n");
}

fn testsCheck(a: A, args: []const []const u8) void {
    if (args.len < 2) usage("tests-check <mark> <expected tests> <marker>...");
    const mark = args[0];
    const want = args[1];
    var got = std.ArrayList([]const u8).init(a);
    for (args[2..]) |m| {
        const b = std.fs.path.basename(m);
        if (!std.mem.endsWith(u8, b, ".passed")) fail("`{s}` is not a test pass marker", .{b});
        const text = readAll(a, m);
        if (!hasPassLine(text)) fail("the welded test {s} did not pass: {s}", .{ b[0 .. b.len - ".passed".len], std.mem.trimRight(u8, text, "\n") });
        got.append(b[0 .. b.len - ".passed".len]) catch @panic("oom");
    }
    std.mem.sort([]const u8, got.items, {}, lessThan);
    var joined = std.ArrayList(u8).init(a);
    for (got.items) |g| joined.writer().print("{s} ", .{g}) catch @panic("oom");
    const want_words = std.fmt.allocPrint(a, "{s} ", .{want}) catch @panic("oom");
    if (!std.mem.eql(u8, joined.items, want_words))
        fail("the library's welded tests that passed: {s}\nexpected exactly:                       {s}", .{ joined.items, want });
    writeAll(mark, "ok\n");
}

/// Whether some line of `text` starts with `PASS `.
pub fn hasPassLine(text: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        if (std.mem.startsWith(u8, l, "PASS ")) return true;
    }
    return false;
}

fn sameBytes(a: A, args: []const []const u8) void {
    if (args.len != 3) usage("same-bytes <a> <b> <report>");
    const x = std.fs.cwd().readFileAlloc(a, args[0], 1 << 30) catch "";
    const y = std.fs.cwd().readFileAlloc(a, args[1], 1 << 30) catch "";
    if (x.len == 0 or y.len == 0) fail("BAD: a precompile wrote an empty package", .{});
    if (!std.mem.eql(u8, x, y)) fail("BAD: the same package precompiled under two staging paths differs: the .mojoc records where it was built ({s} {s})", .{ args[0], args[1] });
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(x, &h, .{});
    writeAll(args[2], std.fmt.allocPrint(a, "same bytes: {s}\n", .{std.fmt.fmtSliceHexLower(&h)}) catch @panic("oom"));
}

fn testCommand(a: A, args: []const []const u8) void {
    if (args.len < 4 or !std.mem.eql(u8, args[2], "--")) usage("test-command <label> <report> -- <command>...");
    const label = args[0];
    var child = std.process.Child.init(args[3..], a);
    const term = child.spawnAndWait() catch |e| {
        std.debug.print("tests_act: cannot run {s}: {s}\n", .{ args[3], @errorName(e) });
        std.process.exit(2);
    };
    const code: u32 = switch (term) {
        .Exited => |c| c,
        .Signal => |s| 128 + s,
        else => 255,
    };
    if (code != 0) fail("test_command_case: the test command of {s} exited {d}", .{ label, code });
    writeAll(args[1], std.fmt.allocPrint(a, "ok {s}\n", .{label}) catch @panic("oom"));
}

/// Copies the tree `src` to `dest`: directories, files (modes normalized to
/// 0755/0644 by the executable bit) and links.
pub fn copyTree(a: A, src: std.fs.Dir, dest: std.fs.Dir) !void {
    var w = try src.walk(a);
    while (try w.next()) |e| {
        switch (e.kind) {
            .directory => try dest.makePath(e.path),
            .file => {
                if (std.fs.path.dirname(e.path)) |d| try dest.makePath(d);
                const st = try src.statFile(e.path);
                const mode: std.fs.File.Mode = if (st.mode & 0o111 != 0) 0o755 else 0o644;
                const data = try src.readFileAlloc(a, e.path, 1 << 30);
                const f = try dest.createFile(e.path, .{ .mode = mode });
                defer f.close();
                try f.writeAll(data);
                try f.chmod(mode);
            },
            .sym_link => {
                if (std.fs.path.dirname(e.path)) |d| try dest.makePath(d);
                var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
                const target = try src.readLink(e.path, &buf);
                try dest.symLink(target, e.path, .{});
            },
            else => {},
        }
    }
}

fn deleteMember(a: A, args: []const []const u8) void {
    if (args.len != 3) usage("delete-member <source dir> <dest dir> <member>");
    const cwd = std.fs.cwd();
    cwd.makePath(args[1]) catch |e| fail("tests_act: cannot create {s}: {s}", .{ args[1], @errorName(e) });
    var src = cwd.openDir(args[0], .{ .iterate = true }) catch |e| fail("tests_act: cannot open {s}: {s}", .{ args[0], @errorName(e) });
    defer src.close();
    var dest = cwd.openDir(args[1], .{}) catch |e| fail("tests_act: cannot open {s}: {s}", .{ args[1], @errorName(e) });
    defer dest.close();
    copyTree(a, src, dest) catch |e| fail("tests_act: cannot copy {s}: {s}", .{ args[0], @errorName(e) });
    dest.deleteFile(args[2]) catch |e| fail("tests_act: cannot delete {s}: {s}", .{ args[2], @errorName(e) });
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len < 2) usage("tests_act <subcommand> ...");
    const cmd = argv[1];
    const rest = argv[2..];
    if (std.mem.eql(u8, cmd, "gen-check")) return genCheck(a, rest);
    if (std.mem.eql(u8, cmd, "tests-check")) return testsCheck(a, rest);
    if (std.mem.eql(u8, cmd, "same-bytes")) return sameBytes(a, rest);
    if (std.mem.eql(u8, cmd, "test-command")) return testCommand(a, rest);
    if (std.mem.eql(u8, cmd, "delete-member")) return deleteMember(a, rest);
    if (std.mem.eql(u8, cmd, "re-probe")) return probes.reProbe(a, rest) catch |e| fail("tests_act: re-probe: {s}", .{@errorName(e)});
    if (std.mem.eql(u8, cmd, "loader-trace")) std.process.exit(probes.loaderTrace(a, rest) catch |e| fail("tests_act: loader-trace: {s}", .{@errorName(e)}));
    if (std.mem.eql(u8, cmd, "stand-in-archive")) return archives.standInArchive(a, rest) catch |e| fail("tests_act: stand-in-archive: {s}", .{@errorName(e)});
    if (std.mem.eql(u8, cmd, "proto-gen")) return proto_checks.protoGen(a, rest) catch |e| fail("tests_act: proto-gen: {s}", .{@errorName(e)});
    if (std.mem.eql(u8, cmd, "proto-check")) return proto_checks.protoCheck(a, rest) catch |e| fail("tests_act: proto-check: {s}", .{@errorName(e)});
    if (std.mem.eql(u8, cmd, "rest-extract")) return proto_checks.restExtract(a, rest) catch |e| fail("tests_act: rest-extract: {s}", .{@errorName(e)});
    if (std.mem.eql(u8, cmd, "aws-gen")) return aws_checks.gen(a, rest) catch |e| fail("tests_act: aws-gen: {s}", .{@errorName(e)});
    if (std.mem.eql(u8, cmd, "aws-refuse")) return aws_checks.refuse(a, rest) catch |e| fail("tests_act: aws-refuse: {s}", .{@errorName(e)});
    if (std.mem.eql(u8, cmd, "aws-cmp")) return aws_checks.cmp(a, rest) catch |e| fail("tests_act: aws-cmp: {s}", .{@errorName(e)});
    if (std.mem.eql(u8, cmd, "bundle-parity")) std.process.exit(parity.parity(a, rest) catch |e| fail("tests_act: bundle-parity: {s}", .{@errorName(e)}));
    std.debug.print("tests_act: unknown subcommand {s}\n", .{cmd});
    std.process.exit(2);
}
