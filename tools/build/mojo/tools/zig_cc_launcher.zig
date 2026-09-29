//! zig_cc_launcher: runs `<zig_dir>/zig <subcommand> <args...>` for the C/C++
//! toolchain (mojo/cxx.bzl), after two adjustments zig needs inside a build
//! action:
//!
//!   * Response files are expanded, recursively. The prelude's C/C++ rules
//!     pass an argument file that names further argument files, and zig
//!     refuses a nested response file. Contents are tokenized like GNU/clang
//!     response files: whitespace separates arguments; single quotes, double
//!     quotes (with backslash escapes) and backslash escapes group them. An
//!     `@name` whose file does not exist is passed on unchanged, as clang does.
//!   * The environment is exactly ZIG_GLOBAL_CACHE_DIR and ZIG_LOCAL_CACHE_DIR,
//!     both under `.zig-cache/` in the working directory. Nothing is inherited.
//!
//! Exit status: zig's; 2 for a usage error, an unreadable response file, or a
//! failure to start zig.

const std = @import("std");

const max_depth = 16;

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("zig_cc_launcher: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_state.allocator();
    const argv = try std.process.argsAlloc(arena);
    if (argv.len < 3) die("usage: zig_cc_launcher <zig_dir> <subcommand> [args...]", .{});

    var out = std.ArrayList([]const u8).init(arena);
    const zig_path = try std.fs.path.join(arena, &.{ argv[1], "zig" });
    try out.append(zig_path);
    try out.append(argv[2]);
    for (argv[3..]) |a| try expand(arena, &out, a, 0);

    var env = std.process.EnvMap.init(arena);
    try env.put("ZIG_GLOBAL_CACHE_DIR", ".zig-cache/global");
    try env.put("ZIG_LOCAL_CACHE_DIR", ".zig-cache/local");
    const err = std.process.execve(arena, out.items, &env);
    die("cannot run {s}: {s}", .{ zig_path, @errorName(err) });
}

fn expand(arena: std.mem.Allocator, out: *std.ArrayList([]const u8), arg: []const u8, depth: u32) !void {
    if (arg.len < 2 or arg[0] != '@') {
        try out.append(arg);
        return;
    }
    if (depth >= max_depth) die("response files nested deeper than {d} at {s}", .{ max_depth, arg });
    const data = std.fs.cwd().readFileAlloc(arena, arg[1..], 1 << 30) catch |e| switch (e) {
        error.FileNotFound => {
            try out.append(arg);
            return;
        },
        else => die("cannot read response file {s}: {s}", .{ arg[1..], @errorName(e) }),
    };
    var toks = std.ArrayList([]const u8).init(arena);
    try tokenize(arena, data, &toks);
    for (toks.items) |t| try expand(arena, out, t, depth + 1);
}

fn tokenize(arena: std.mem.Allocator, data: []const u8, toks: *std.ArrayList([]const u8)) !void {
    var cur = std.ArrayList(u8).init(arena);
    var in_tok = false;
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        const c = data[i];
        switch (c) {
            ' ', '\t', '\r', '\n' => {
                if (in_tok) {
                    try toks.append(try cur.toOwnedSlice());
                    in_tok = false;
                }
            },
            '\\' => {
                in_tok = true;
                if (i + 1 < data.len) {
                    i += 1;
                    try cur.append(data[i]);
                }
            },
            '\'', '"' => {
                in_tok = true;
                const q = c;
                i += 1;
                while (i < data.len and data[i] != q) : (i += 1) {
                    if (q == '"' and data[i] == '\\' and i + 1 < data.len) i += 1;
                    try cur.append(data[i]);
                }
                if (i >= data.len) die("unterminated quote in a response file", .{});
            },
            else => {
                in_tok = true;
                try cur.append(c);
            },
        }
    }
    if (in_tok) try toks.append(try cur.toOwnedSlice());
}
