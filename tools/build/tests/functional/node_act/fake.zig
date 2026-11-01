//! One stand-in program for node, an npm package's executable and esbuild, by
//! the name it is run as (the driver test copies it under each name):
//!
//!   node  --version      prints the first line of ../LICENSE (next to bin/),
//!                        or v1.2.3; exits 9 unless its environment is exactly
//!                        LD_LIBRARY_PATH ending in /lib
//!   node  -e JS FILE WHERE NAME VERSION
//!                        the package.json check: exits 1 with WHERE on stderr
//!                        when FILE holds BADPKG; prints "node -e env=<n>
//!                        ld=<LD_LIBRARY_PATH>" on stdout
//!   node  --test --test-reporter=tap FILE...
//!                        prints "test-mode files=<n>" (exits 8 unless the files
//!                        are absolute), then runs FILE as SCRIPT below
//!   node  SCRIPT ARGS    a test: SCRIPT's lines say what to do: `env`
//!                        (print the environment's facts), `args` (print the
//!                        arguments), `stdout TEXT`, `stderr TEXT`, `exit N`
//!   tool  --version      prints 1.0.0 (tool_other: 9.9.9; tool_broken: exits 3)
//!   esbuild ENTRY ...    writes the working directory's name, the arguments and
//!                        the environment's size to --outfile=; exits 4 for the
//!                        entry FAIL
const std = @import("std");

fn envCount() usize {
    var n: usize = 0;
    var it = std.process.getEnvMap(std.heap.page_allocator) catch return 0;
    n = it.count();
    it.deinit();
    return n;
}

fn isDir(p: []const u8) bool {
    var d = std.fs.cwd().openDir(p, .{}) catch return false;
    d.close();
    return true;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    const out = std.fs.File.stdout().deprecatedWriter();
    const base = std.fs.path.basename(args[0]);
    if (std.mem.eql(u8, base, "node")) {
        if (args.len >= 2 and std.mem.eql(u8, args[1], "--version")) {
            const ld = std.process.getEnvVarOwned(a, "LD_LIBRARY_PATH") catch "";
            if (envCount() != 1 or !std.mem.endsWith(u8, ld, "/lib")) std.process.exit(9);
            const dir = std.fs.path.dirname(args[0]) orelse ".";
            const lic = try std.fs.path.join(a, &.{ dir, "..", "LICENSE" });
            const text = std.fs.cwd().readFileAlloc(a, lic, 1 << 16) catch "v1.2.3\n";
            const first = std.mem.sliceTo(text, '\n');
            try out.print("{s}\n", .{first});
            return;
        }
        if (args.len >= 2 and std.mem.eql(u8, args[1], "-e")) {
            const ld = std.process.getEnvVarOwned(a, "LD_LIBRARY_PATH") catch "(unset)";
            try out.print("node -e env={d} ld={s}\n", .{ envCount(), ld });
            const body = std.fs.cwd().readFileAlloc(a, args[3], 1 << 20) catch "";
            if (std.mem.indexOf(u8, body, "BADPKG") != null) {
                std.debug.print("{s} does not state \"name\":\"{s}\" at its top level\n", .{ args[4], args[5] });
                std.process.exit(1);
            }
            return;
        }
        var first: usize = 1;
        if (args.len >= 2 and std.mem.eql(u8, args[1], "--test")) {
            if (args.len < 4 or !std.mem.eql(u8, args[2], "--test-reporter=tap") or !std.fs.path.isAbsolute(args[3])) std.process.exit(8);
            try out.print("test-mode files={d}\n", .{args.len - 3});
            first = 3;
        }
        const script = try std.fs.cwd().readFileAlloc(a, args[first], 1 << 20);
        var code: u8 = 0;
        var lines = std.mem.splitScalar(u8, script, '\n');
        while (lines.next()) |line| {
            if (std.mem.eql(u8, line, "env")) {
                const home = std.process.getEnvVarOwned(a, "HOME") catch "";
                const tmp = std.process.getEnvVarOwned(a, "TMPDIR") catch "";
                const ld = std.process.getEnvVarOwned(a, "LD_LIBRARY_PATH") catch "(unset)";
                try out.print("env: n={d} LC_ALL={s} TZ={s} home={s} tmp={s} ld_ends_lib={s}\n", .{
                    envCount(),
                    std.process.getEnvVarOwned(a, "LC_ALL") catch "(unset)",
                    std.process.getEnvVarOwned(a, "TZ") catch "(unset)",
                    if (isDir(home)) "dir" else "none",
                    if (isDir(tmp)) "dir" else "none",
                    if (std.mem.endsWith(u8, ld, "/lib")) "yes" else "no",
                });
            } else if (std.mem.eql(u8, line, "args")) {
                for (args[2..]) |x| try out.print("arg: {s}\n", .{x});
            } else if (std.mem.startsWith(u8, line, "stdout ")) {
                try out.print("{s}\n", .{line[7..]});
            } else if (std.mem.startsWith(u8, line, "stderr ")) {
                std.debug.print("{s}\n", .{line[7..]});
            } else if (std.mem.startsWith(u8, line, "exit ")) {
                code = try std.fmt.parseInt(u8, line[5..], 10);
            }
        }
        if (code != 0) std.process.exit(code);
        return;
    }
    if (std.mem.startsWith(u8, base, "tool")) {
        if (std.mem.eql(u8, base, "tool_broken")) std.process.exit(3);
        try out.print("{s}\n", .{if (std.mem.eql(u8, base, "tool_other")) "9.9.9" else "1.0.0"});
        return;
    }
    if (std.mem.eql(u8, base, "esbuild")) {
        if (std.mem.eql(u8, args[1], "FAIL")) {
            std.debug.print("esbuild: the entry fails\n", .{});
            std.process.exit(4);
        }
        var outfile: []const u8 = "";
        for (args[1..]) |x| {
            if (std.mem.startsWith(u8, x, "--outfile=")) outfile = x["--outfile=".len..];
        }
        var cwd_buf: [4096]u8 = undefined;
        const cwd = try std.process.getCwd(&cwd_buf);
        var body = std.ArrayList(u8).empty;
        try body.writer(a).print("cwd={s}\nenv={d}\n", .{ std.fs.path.basename(cwd), envCount() });
        for (args[1..]) |x| {
            if (std.mem.startsWith(u8, x, "--outfile=")) continue;
            try body.writer(a).print("arg={s}\n", .{x});
        }
        try body.writer(a).print("outfile_absolute={s}\n", .{if (std.fs.path.isAbsolute(outfile)) "yes" else "no"});
        const f = try std.fs.cwd().createFile(outfile, .{});
        defer f.close();
        try f.writeAll(body.items);
        return;
    }
    std.debug.print("fake: run as {s}\n", .{base});
    std.process.exit(7);
}
