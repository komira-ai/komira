// Why Zig: build tools are Zig (tools/build/README.md); the check runs no shell.
//! so_exports: the C-ABI exports of a Mojo source, and the check of
//! `mojo_shared_lib`'s `exports` against them (defs.bzl).
//!
//!   so_exports names <file.mojo>
//!       prints the name of each function declared `@export` with `abi("C")`,
//!       sorted, one per line.
//!   so_exports check <file.mojo> <out> <label> [<export>...] [-- <unlisted>...]
//!       fails unless the listed exports are exactly the file's `@export`
//!       `abi("C")` functions less the `unlisted` ones, which must be
//!       exported and must not be listed. Every difference is reported, both
//!       directions. When the sets agree, `ok` is written to <out>.
//!
//! The reader is a tokenizer, not a Mojo parser: comments and string
//! literals are tokens of their own, so an `@export` in a docstring or a
//! comment is not a declaration. A declaration is `@export` on its own
//! logical line (other decorators may sit between it and the `def` or `fn`),
//! and its signature, up to the `:` that opens the body, must carry
//! `abi("C")`. An `@export` that takes arguments is refused: the file's
//! exports cannot be read with confidence.
//!
//! Exit status: 0; 1 for a failed check (every difference is reported first);
//! 2 for a usage error or a source the tool cannot read.

const std = @import("std");

const Kind = enum { ident, str, punct, newline };

const Token = struct {
    kind: Kind,
    text: []const u8,
    /// The first token of a logical line (not inside brackets).
    line_start: bool = false,
};

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80;
}

fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}

/// The tokens of `src`: identifiers, string literals (text without the
/// quotes), single punctuation characters and logical line ends. Comments
/// are dropped.
fn tokenize(a: std.mem.Allocator, src: []const u8) ![]Token {
    var out = std.ArrayList(Token).empty;
    var depth: usize = 0;
    var at_start = true;
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == '\n') {
            if (depth == 0) {
                try out.append(a, .{ .kind = .newline, .text = "\n" });
                at_start = true;
            }
            i += 1;
        } else if (c == ' ' or c == '\t' or c == '\r' or c == '\\') {
            i += 1;
        } else if (c == '#') {
            while (i < src.len and src[i] != '\n') i += 1;
        } else if (c == '"' or c == '\'') {
            const triple = i + 2 < src.len and src[i + 1] == c and src[i + 2] == c;
            const q: usize = if (triple) 3 else 1;
            const start = i + q;
            var j = start;
            while (j < src.len) {
                if (src[j] == '\\') {
                    j += 2;
                    continue;
                }
                if (src[j] == c and (!triple or (j + 2 < src.len and src[j + 1] == c and src[j + 2] == c))) break;
                if (!triple and src[j] == '\n') break;
                j += 1;
            }
            const end = @min(j, src.len);
            try out.append(a, .{ .kind = .str, .text = src[start..end], .line_start = at_start });
            at_start = false;
            i = @min(end + q, src.len);
        } else if (isIdentStart(c)) {
            var j = i;
            while (j < src.len and isIdentChar(src[j])) j += 1;
            try out.append(a, .{ .kind = .ident, .text = src[i..j], .line_start = at_start });
            at_start = false;
            i = j;
        } else {
            switch (c) {
                '(', '[', '{' => depth += 1,
                ')', ']', '}' => depth -|= 1,
                else => {},
            }
            try out.append(a, .{ .kind = .punct, .text = src[i .. i + 1], .line_start = at_start });
            at_start = false;
            i += 1;
        }
    }
    return out.toOwnedSlice(a);
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

pub const Error = error{ExportWithArguments} || std.mem.Allocator.Error;

/// The names of the `@export` `abi("C")` functions of `src`, sorted and unique.
pub fn exportedNames(a: std.mem.Allocator, src: []const u8) Error![]const []const u8 {
    const toks = try tokenize(a, src);
    var names = std.ArrayList([]const u8).empty;
    var pending = false;
    var i: usize = 0;
    while (i < toks.len) : (i += 1) {
        const t = toks[i];
        if (!t.line_start) continue;
        if (t.kind == .punct and t.text[0] == '@') {
            const is_export = i + 1 < toks.len and toks[i + 1].kind == .ident and std.mem.eql(u8, toks[i + 1].text, "export");
            if (is_export) {
                // `@export` must end its line; arguments are not read.
                if (i + 2 < toks.len and toks[i + 2].kind != .newline) return error.ExportWithArguments;
                pending = true;
            }
            continue;
        }
        const is_def = t.kind == .ident and (std.mem.eql(u8, t.text, "def") or std.mem.eql(u8, t.text, "fn"));
        if (pending and is_def and i + 1 < toks.len and toks[i + 1].kind == .ident) {
            if (signatureIsC(toks[i + 2 ..])) try names.append(a, toks[i + 1].text);
        }
        pending = false;
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    var uniq = std.ArrayList([]const u8).empty;
    for (names.items) |n| {
        if (uniq.items.len == 0 or !std.mem.eql(u8, uniq.items[uniq.items.len - 1], n)) try uniq.append(a, n);
    }
    return uniq.toOwnedSlice(a);
}

/// Whether the signature that starts at `toks` (after the name) carries
/// `abi("C")` before the `:` that opens the body.
fn signatureIsC(toks: []const Token) bool {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < toks.len) : (i += 1) {
        const t = toks[i];
        switch (t.kind) {
            .newline => if (depth == 0) return false,
            .punct => switch (t.text[0]) {
                '(', '[', '{' => depth += 1,
                ')', ']', '}' => depth -|= 1,
                ':' => if (depth == 0) return false,
                else => {},
            },
            .ident => if (depth == 0 and std.mem.eql(u8, t.text, "abi") and i + 3 < toks.len and
                toks[i + 1].kind == .punct and toks[i + 1].text[0] == '(' and
                toks[i + 2].kind == .str and std.mem.eql(u8, toks[i + 2].text, "C") and
                toks[i + 3].kind == .punct and toks[i + 3].text[0] == ')') return true,
            .str => {},
        }
    }
    return false;
}

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| {
        if (std.mem.eql(u8, x, s)) return true;
    }
    return false;
}

/// The report of a check, or null when `listed` is `exported` less `unlisted`.
pub fn differences(a: std.mem.Allocator, label: []const u8, file: []const u8, exported: []const []const u8, listed: []const []const u8, unlisted: []const []const u8) !?[]u8 {
    var out = std.ArrayList(u8).empty;
    const w = out.writer(a);
    var missing = std.ArrayList(u8).empty; // exported, not listed
    var extra = std.ArrayList(u8).empty; // listed, not exported
    var bad_unlisted = std.ArrayList(u8).empty; // unlisted, but not exported
    var both = std.ArrayList(u8).empty; // unlisted and listed
    for (exported) |n| {
        if (!contains(listed, n) and !contains(unlisted, n)) try missing.writer(a).print(" {s}", .{n});
    }
    for (listed) |n| {
        if (!contains(exported, n)) try extra.writer(a).print(" {s}", .{n});
        if (contains(unlisted, n)) try both.writer(a).print(" {s}", .{n});
    }
    for (unlisted) |n| {
        if (!contains(exported, n)) try bad_unlisted.writer(a).print(" {s}", .{n});
    }
    if (missing.items.len + extra.items.len + bad_unlisted.items.len + both.items.len == 0) return null;
    try w.print("mojo_shared_lib: {s}: `exports` differs from the @export abi(\"C\") functions of {s}\n", .{ label, file });
    if (extra.items.len > 0) try w.print("  listed in `exports`, but {s} has no @export abi(\"C\") function of that name:{s}\n", .{ file, extra.items });
    if (missing.items.len > 0) try w.print("  @export abi(\"C\") in {s}, but not in `exports` (or `unlisted_exports`):{s}\n", .{ file, missing.items });
    if (bad_unlisted.items.len > 0) try w.print("  in `unlisted_exports`, but {s} has no @export abi(\"C\") function of that name:{s}\n", .{ file, bad_unlisted.items });
    if (both.items.len > 0) try w.print("  in both `exports` and `unlisted_exports`:{s}\n", .{both.items});
    return try out.toOwnedSlice(a);
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("so_exports: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    const usage = "usage: so_exports names <file.mojo> | so_exports check <file.mojo> <out> <label> [<export>...] [-- <unlisted>...]";
    if (argv.len < 3) die(usage, .{});
    const path = argv[2];
    const src = std.fs.cwd().readFileAlloc(a, path, 1 << 26) catch |e| die("cannot read {s}: {s}", .{ path, @errorName(e) });
    const exported = exportedNames(a, src) catch |e| switch (e) {
        error.ExportWithArguments => die("{s}: an @export that takes arguments is not read; write a bare @export", .{path}),
        else => return e,
    };
    if (std.mem.eql(u8, argv[1], "names")) {
        var buf: [4096]u8 = undefined;
        var bw = std.fs.File.stdout().writer(&buf);
        for (exported) |n| try bw.interface.print("{s}\n", .{n});
        try bw.interface.flush();
        return;
    }
    if (!std.mem.eql(u8, argv[1], "check") or argv.len < 5) die(usage, .{});
    const out_path = argv[3];
    const label = argv[4];
    var split = argv.len;
    for (argv[5..], 5..) |s, k| {
        if (std.mem.eql(u8, s, "--")) {
            split = k;
            break;
        }
    }
    const listed = argv[5..split];
    const unlisted = if (split < argv.len) argv[split + 1 ..] else argv[0..0];
    if (try differences(a, label, path, exported, listed, unlisted)) |report| {
        std.debug.print("{s}", .{report});
        std.process.exit(1);
    }
    const f = std.fs.cwd().createFile(out_path, .{}) catch |e| die("cannot create {s}: {s}", .{ out_path, @errorName(e) });
    defer f.close();
    f.writeAll("ok\n") catch |e| die("cannot write {s}: {s}", .{ out_path, @errorName(e) });
}
