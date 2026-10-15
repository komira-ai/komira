// Why Zig: build tools are Zig (tools/build/README.md). python_act replaces the
// busybox script of `python_dist` (tools/build/python/defs.bzl), so that action
// runs no shell.
//! python_act: the action of the Python distribution rule.
//!
//!   python_act dist --archive <tgz> --out <dir> --exe <path> --version <v>
//!
//! Unpacks the archive (its single top directory is `python/`) into <out>,
//! removes what it installed into site-packages (pip: no action installs with
//! it, and -S keeps the directory off sys.path), and runs the interpreter
//! <out>/<exe>, which must print <v>: the version, followed by `t` if and only
//! if it is a free-threaded build (`Py_GIL_DISABLED`).
//!
//! The messages and exit statuses are those of the script it replaces.

const std = @import("std");
const U = @import("act_util");

const prog = "python_act";

fn usage(comptime fmt: []const u8, args: anytype) u8 {
    std.debug.print(prog ++ ": " ++ fmt ++ "\n", args);
    return 2;
}

/// What the interpreter runs to say its version: `3.13.1`, with `t` after it
/// for a free-threaded build.
pub const version_program =
    "import sys, sysconfig; print(\"%d.%d.%d\" % sys.version_info[:3] + (\"t\" if sysconfig.get_config_var(\"Py_GIL_DISABLED\") else \"\"))";

/// Removes the entries of every `lib/python3.*/site-packages` of `root`, the
/// hidden ones kept (the shell's `site-packages/*` does not match them).
pub fn clearSitePackages(a: std.mem.Allocator, root: std.fs.Dir) !void {
    var lib = root.openDir("lib", .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer lib.close();
    const names = try U.listNames(a, lib);
    for (names) |n| {
        if (!std.mem.startsWith(u8, n, "python3.")) continue;
        var site = lib.openDir(try std.fmt.allocPrint(a, "{s}/site-packages", .{n}), .{ .iterate = true }) catch continue;
        defer site.close();
        // (Collected first: a directory is not changed while it is read.)
        var found = std.ArrayList(struct { name: []const u8, kind: std.fs.File.Kind }).init(a);
        var it = site.iterate();
        while (try it.next()) |e| try found.append(.{ .name = try a.dupe(u8, e.name), .kind = e.kind });
        for (found.items) |e| {
            if (e.name.len > 0 and e.name[0] == '.') continue;
            if (e.kind == .directory) {
                continue;
            } else {
                try site.deleteFile(e.name);
            }
        }
    }
}

fn cmdDist(a: std.mem.Allocator, args: []const []const u8) u8 {
    const spec = [_]U.Spec{ .{ .name = "archive" }, .{ .name = "out" }, .{ .name = "exe" }, .{ .name = "version" } };
    var bad: []const u8 = "";
    const f = U.parseFlags(a, args, &spec, &bad) catch |e| return usage("dist: {s}: {s}", .{ @errorName(e), bad });
    const archive = f.need("archive") catch return usage("dist needs --archive", .{});
    const out = f.need("out") catch return usage("dist needs --out", .{});
    const exe = f.need("exe") catch return usage("dist needs --exe", .{});
    const want = f.need("version") catch return usage("dist needs --version", .{});

    const bytes = std.fs.cwd().readFileAlloc(a, archive, 1 << 31) catch |e| return usage("cannot read {s}: {s}", .{ archive, @errorName(e) });
    var dest = std.fs.cwd().makeOpenPath(out, .{ .iterate = true }) catch |e| return usage("cannot create {s}: {s}", .{ out, @errorName(e) });
    defer dest.close();
    U.extract.extractTgz(dest, bytes, "python", U.extract.keepAll) catch |e| {
        std.debug.print("python_dist: cannot unpack {s}: {s}\n", .{ archive, @errorName(e) });
        return 2;
    };
    const st = dest.statFile(exe) catch null;
    if (st == null or st.?.kind == .directory or st.?.mode & 0o111 == 0) {
        std.debug.print("python_dist: {s} holds no python/{s}\n", .{ archive, exe });
        return 2;
    }
    clearSitePackages(a, dest) catch |e| return usage("cannot clear site-packages of {s}: {s}", .{ out, @errorName(e) });

    const python = std.fmt.allocPrint(a, "{s}/{s}", .{ out, exe }) catch return 2;
    const r = U.runCapture(a, &.{ python, "-I", "-S", "-c", version_program }, null, null) catch {
        std.debug.print("python_dist: {s} does not run\n", .{python});
        return 2;
    };
    if (r.stderr.len > 0) std.debug.print("{s}", .{r.stderr});
    if (r.code != 0) {
        std.debug.print("python_dist: {s} does not run\n", .{python});
        return 2;
    }
    const got = U.trimNewlines(r.stdout);
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("python_dist: the interpreter in {s} is {s}, the pin says {s}\n", .{ archive, got, want });
        return 2;
    }
    return 0;
}

pub fn main() void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = std.process.argsAlloc(a) catch std.process.exit(2);
    if (argv.len < 2) std.process.exit(usage("usage: python_act dist ...", .{}));
    const plain = a.alloc([]const u8, argv.len - 2) catch std.process.exit(2);
    for (argv[2..], 0..) |s, i| plain[i] = s;
    const rc: u8 = if (std.mem.eql(u8, argv[1], "dist")) cmdDist(a, plain) else usage("unknown subcommand {s}", .{argv[1]});
    if (rc != 0) std.process.exit(rc);
}
