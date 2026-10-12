//! native_reach: the call half of mojo_library's native-reach check
//! (tools/build/mojo/native_reach.bzl; README.md in this directory).
//!
//!   native_reach --out <file> --library <label> --src <dir>
//!       (--refuse <prefix>=<owner>)...
//!
//! Reads every `*.mojo` file under <dir> (a library's staged sources; its
//! tests are not among them) and finds each string literal that starts with
//! a refused prefix: `external_call["komira_awslc_RAND_bytes", ...]`, or any
//! other place the source spells such a C name in quotes. A refused prefix is
//! that of an owner (a mojo_library shipping a prefixed vendored archive,
//! tools/build/one_definition/libraries.bzl `THIRD_PARTY_OWNERS`) that is not
//! in this library's Mojo deps closure, so the library calls native code its
//! package would not require.
//!
//! A line is read up to its first `#` outside a string (a comment), and
//! strings are delimited by `"` or `'` on that line, with `\` escaping the
//! next character. A name inside a triple-quoted docstring is read as a
//! string too.
//!
//! Writes <out>, a Buck2 validation result: status failure listing each name
//! found with its file (relative to <dir>) and line, success otherwise.
//! Exit 0 when <out> is written; 2 on a usage error or an unreadable source,
//! with the reason on stderr.

const std = @import("std");

pub const Refuse = struct {
    prefix: []const u8,
    owner: []const u8,
};

pub const Finding = struct {
    path: []const u8,
    line: usize,
    symbol: []const u8,
    refuse: Refuse,
};

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Appends to `out` each string literal of `text` (the contents of `path`)
/// that starts with one of `refuses`' prefixes, outside comments.
pub fn scan(path: []const u8, text: []const u8, refuses: []const Refuse, out: *std.ArrayList(Finding)) !void {
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        var quote: u8 = 0; // the open string's delimiter, 0 outside a string
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            const c = line[i];
            if (quote == 0) {
                if (c == '#') break;
                if (c != '"' and c != '\'') continue;
                quote = c;
                const rest = line[i + 1 ..];
                for (refuses) |r| {
                    if (r.prefix.len == 0 or !std.mem.startsWith(u8, rest, r.prefix)) continue;
                    var e = r.prefix.len;
                    while (e < rest.len and isIdent(rest[e])) e += 1;
                    try out.append(.{ .path = path, .line = line_no, .symbol = rest[0..e], .refuse = r });
                    break;
                }
            } else if (c == '\\') {
                i += 1;
            } else if (c == quote) {
                quote = 0;
            }
        }
    }
}

/// The validation message for `findings` (which `scan` found in `files`
/// files of `library`, against `refuses`), and whether it is a failure.
pub fn message(alloc: std.mem.Allocator, library: []const u8, files: usize, refuses: []const Refuse, findings: []const Finding) ![]const u8 {
    var m = std.ArrayList(u8).init(alloc);
    const w = m.writer();
    if (findings.len == 0) {
        try w.print("{s}: {d} source file(s) checked; none calls a prefixed name of an owner outside its Mojo deps closure (", .{ library, files });
        for (refuses, 0..) |r, i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("{s}* of {s}", .{ r.prefix, r.owner });
        }
        try w.writeAll(")");
        return m.toOwnedSlice();
    }
    try w.print("{s} calls native code of a library that is not in its Mojo deps closure, so its package would not require the library that ships that code; add the owner to its deps (tools/build/mojo/native_reach.bzl):", .{library});
    for (findings) |f| {
        try w.print("\n{s}:{d}: \"{s}\" is {s}'s (prefix {s}), which is not in the closure", .{ f.path, f.line, f.symbol, f.refuse.owner, f.refuse.prefix });
    }
    return m.toOwnedSlice();
}

/// The Buck2 validation result (ValidationInfo) holding `msg`.
pub fn result(alloc: std.mem.Allocator, failed: bool, msg: []const u8) ![]const u8 {
    var m = std.ArrayList(u8).init(alloc);
    try std.json.stringify(.{
        .version = @as(u32, 1),
        .data = .{ .status = @as([]const u8, if (failed) "failure" else "success"), .message = msg },
    }, .{}, m.writer());
    try m.append('\n');
    return m.toOwnedSlice();
}

pub const Args = struct {
    out: []const u8,
    library: []const u8,
    src: []const u8,
    refuses: []const Refuse,
};

/// Parses argv (without the program name); null with `why` set on a usage error.
pub fn parseArgs(alloc: std.mem.Allocator, argv: []const []const u8, why: *[]const u8) !?Args {
    var out: ?[]const u8 = null;
    var library: ?[]const u8 = null;
    var src: ?[]const u8 = null;
    var refuses = std.ArrayList(Refuse).init(alloc);
    var i: usize = 0;
    while (i < argv.len) : (i += 2) {
        if (i + 1 >= argv.len) {
            why.* = "every flag takes a value";
            return null;
        }
        const flag = argv[i];
        const v = argv[i + 1];
        if (std.mem.eql(u8, flag, "--out")) {
            out = v;
        } else if (std.mem.eql(u8, flag, "--library")) {
            library = v;
        } else if (std.mem.eql(u8, flag, "--src")) {
            src = v;
        } else if (std.mem.eql(u8, flag, "--refuse")) {
            const eq = std.mem.indexOfScalar(u8, v, '=') orelse {
                why.* = "--refuse takes <prefix>=<owner>";
                return null;
            };
            if (eq == 0 or eq + 1 == v.len) {
                why.* = "--refuse takes <prefix>=<owner>, both non-empty";
                return null;
            }
            try refuses.append(.{ .prefix = v[0..eq], .owner = v[eq + 1 ..] });
        } else {
            why.* = "unknown flag";
            return null;
        }
    }
    if (out == null or library == null or src == null) {
        why.* = "--out, --library and --src are required";
        return null;
    }
    if (refuses.items.len == 0) {
        why.* = "no --refuse: the check would find nothing (the rule writes the result itself then)";
        return null;
    }
    return .{ .out = out.?, .library = library.?, .src = src.?, .refuses = refuses.items };
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The `*.mojo` files under `dir`, relative to it, sorted.
pub fn mojoFiles(alloc: std.mem.Allocator, dir: std.fs.Dir) ![][]const u8 {
    var files = std.ArrayList([]const u8).init(alloc);
    var walker = try dir.walk(alloc);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind == .directory) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".mojo")) continue;
        try files.append(try alloc.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, files.items, {}, lessThan);
    return files.toOwnedSlice();
}

/// Scans `a.src` and writes `a.out`.
pub fn run(alloc: std.mem.Allocator, a: Args) !void {
    var dir = try std.fs.cwd().openDir(a.src, .{ .iterate = true });
    defer dir.close();
    const files = try mojoFiles(alloc, dir);
    var findings = std.ArrayList(Finding).init(alloc);
    for (files) |f| {
        const text = try dir.readFileAlloc(alloc, f, 64 << 20);
        try scan(f, text, a.refuses, &findings);
    }
    const msg = try message(alloc, a.library, files.len, a.refuses, findings.items);
    const out = try result(alloc, findings.items.len > 0, msg);
    try std.fs.cwd().writeFile(a.out, out);
}

pub fn main() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    const stderr = std.io.getStdErr().writer();
    const raw = std.process.argsAlloc(alloc) catch std.process.exit(2);
    const argv = alloc.alloc([]const u8, raw.len) catch std.process.exit(2);
    for (raw, 0..) |arg, i| argv[i] = arg;
    var why: []const u8 = "";
    const parsed = parseArgs(alloc, argv[1..], &why) catch std.process.exit(2);
    const a = parsed orelse {
        stderr.print("native_reach: {s}\nusage: native_reach --out <file> --library <label> --src <dir> (--refuse <prefix>=<owner>)...\n", .{why}) catch {};
        std.process.exit(2);
    };
    run(alloc, a) catch |err| {
        stderr.print("native_reach: {s}: {s}\n", .{ a.src, @errorName(err) }) catch {};
        std.process.exit(2);
    };
}

// The unit tests, run by `zig test` on this file (BUCK: `:native_reach_unit`).
test {
    _ = @import("native_reach_test.zig");
}
