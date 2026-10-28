//! A stand-in for rustc and for zig, for the launcher's process tests
//! (driver_test.zig). One program under two names: run as `rustc` it records
//! what the launcher gave it and does what FAKE_MODE says; run as `zig` (the
//! launcher's linker shim runs it) it records its arguments. Everything is
//! appended to the file FAKE_LOG names.
//!
//! FAKE_MODE (rustc):
//!   ok           write "compiled\n" to FAKE_OUT
//!   none         write nothing
//!   empty_file   create FAKE_OUT empty
//!   cwd          write the working directory into FAKE_OUT
//!   exit:N       exit N, writing nothing
//!   signal       end by SIGKILL
//!   link         run the linker named by `-C linker=` with a.o -o a.out, record
//!                its exit status, then write FAKE_OUT as `ok` does
const std = @import("std");

fn append(path: []const u8, text: []const u8) !void {
    const f = std.fs.cwd().createFile(path, .{ .truncate = false }) catch |e| {
        std.debug.print("fake: cannot open the log {s}: {s}\n", .{ path, @errorName(e) });
        return e;
    };
    defer f.close();
    try f.seekFromEnd(0);
    try f.writeAll(text);
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    const log = std.process.getEnvVarOwned(a, "FAKE_LOG") catch @panic("FAKE_LOG is not set");
    const base = std.fs.path.basename(argv[0]);

    if (std.mem.eql(u8, base, "zig")) {
        for (argv[1..]) |arg| try append(log, try std.fmt.allocPrint(a, "zig-arg={s}\n", .{arg}));
        return;
    }

    for (argv[1..]) |arg| try append(log, try std.fmt.allocPrint(a, "arg={s}\n", .{arg}));
    const cwd = try std.fs.cwd().realpathAlloc(a, ".");
    try append(log, try std.fmt.allocPrint(a, "cwd={s}\n", .{cwd}));
    const names = [_][]const u8{
        "PATH",           "HOME",       "TMPDIR",     "XDG_CACHE_HOME",
        "ZIG_GLOBAL_CACHE_DIR", "ZIG_LOCAL_CACHE_DIR", "LD_LIBRARY_PATH", "LD_PRELOAD",
        "RUSTFLAGS",      "RUSTC_BOOTSTRAP", "KEPT",
    };
    for (names) |n| {
        const v = std.process.getEnvVarOwned(a, n) catch "(unset)";
        try append(log, try std.fmt.allocPrint(a, "env {s}={s}\n", .{ n, v }));
    }
    // The applets are on PATH: `cat` is a link in the first PATH directory.
    if (std.process.getEnvVarOwned(a, "PATH")) |path| {
        const cat = try std.fs.path.join(a, &.{ path, "cat" });
        const has = if (std.fs.cwd().access(cat, .{})) |_| "yes" else |_| "no";
        try append(log, try std.fmt.allocPrint(a, "applet cat={s}\n", .{has}));
    } else |_| {}

    const mode = std.process.getEnvVarOwned(a, "FAKE_MODE") catch "ok";
    const out = std.process.getEnvVarOwned(a, "FAKE_OUT") catch "out.rlib";
    if (std.mem.startsWith(u8, mode, "exit:")) {
        std.process.exit(try std.fmt.parseInt(u8, mode[5..], 10));
    } else if (std.mem.eql(u8, mode, "signal")) {
        try std.posix.raise(std.posix.SIG.KILL);
    } else if (std.mem.eql(u8, mode, "none")) {
        return;
    } else if (std.mem.eql(u8, mode, "empty_file")) {
        const f = try std.fs.cwd().createFile(out, .{});
        f.close();
        return;
    } else if (std.mem.eql(u8, mode, "cwd")) {
        const f = try std.fs.cwd().createFile(out, .{});
        defer f.close();
        try f.writeAll("debug info: ");
        try f.writeAll(cwd);
        try f.writeAll("/src/lib.rs\n");
        return;
    }
    if (std.mem.eql(u8, mode, "link")) {
        var linker: []const u8 = "";
        for (argv[1..]) |arg| {
            if (std.mem.startsWith(u8, arg, "linker=")) linker = arg["linker=".len..];
        }
        const r = try std.process.Child.run(.{ .allocator = a, .argv = &.{ linker, "a.o", "-o", "a.out" } });
        const code: u8 = switch (r.term) {
            .Exited => |c| c,
            else => 255,
        };
        try append(log, try std.fmt.allocPrint(a, "linker-exit={d}\n", .{code}));
    } else if (!std.mem.eql(u8, mode, "ok")) {
        @panic("unknown FAKE_MODE");
    }
    const f = try std.fs.cwd().createFile(out, .{});
    defer f.close();
    try f.writeAll("compiled\n");
}
