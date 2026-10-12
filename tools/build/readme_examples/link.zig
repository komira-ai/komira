//! The link block of a packaged README: the commands a user copies to run or
//! build a program against the package, which the packer writes
//! (tools/build/package/pack/readme_link.zig) and kci's install validation
//! runs with (src/kci_validate, readme_link.mojo). Pure: no I/O.
//!
//! The block is the fenced block whose info string is exactly
//! `sh komira-link`. It holds two commands, one per line, in this order:
//!
//!     mojo run ARGS... PROGRAM.mojo
//!     mojo build ARGS... PROGRAM.mojo -o OUT
//!
//! ARGS are what `parse` returns: the words between the verb and the
//! program. A word is split on spaces and tabs; a single-quoted part is
//! taken as it stands, quotes removed; outside quotes `$` may only begin
//! `$CONDA_PREFIX` (the environment, which kci puts in its place), and none
//! of `"`, `\`, a backquote, `;`, `|`, `&`, `<`, `>`, `(` or `)` may appear:
//! a block a shell would read another way than this parser is refused, never
//! guessed. `$CONDA_PREFIX` inside quotes is refused too, since it would mean
//! the literal text to a shell and the environment to kci.
//!
//! No block is no commands (a package without native files). A second
//! block, an unclosed one, a fence whose info string names the marker some
//! other way (`komira_link`, `sh komira-link x`), a blank or extra line, or
//! a command of another shape is refused, naming `<readme>:<line>`.

const std = @import("std");
const md = @import("markdown");
const Allocator = std.mem.Allocator;

pub const INFO = "sh komira-link";
const ENV = "$CONDA_PREFIX";

pub const Commands = struct {
    run: []const []const u8,
    build: []const []const u8,
};

pub const Parsed = union(enum) {
    /// The README holds no link block.
    none,
    commands: Commands,
    /// Why the block is refused, naming `<readme>:<line>`.
    refused: []const u8,
};

fn refused(alloc: Allocator, display: []const u8, line: usize, comptime f: []const u8, args: anytype) Allocator.Error!Parsed {
    const why = try std.fmt.allocPrint(alloc, f, args);
    return .{ .refused = try std.fmt.allocPrint(alloc, "{s}:{d}: {s}", .{ display, line, why }) };
}

/// Whether an info string names the marker in any spelling.
fn namesMarker(info: []const u8) bool {
    var lower: [256]u8 = undefined;
    const n = @min(info.len, lower.len);
    for (info[0..n], 0..) |c, i| lower[i] = std.ascii.toLower(c);
    const l = lower[0..n];
    return std.mem.indexOf(u8, l, "komira-link") != null or std.mem.indexOf(u8, l, "komira_link") != null or
        std.mem.indexOf(u8, l, "komiralink") != null;
}

/// The words of one command line (file header), or why it is refused.
pub const Words = union(enum) { words: []const []const u8, refused: []const u8 };

pub fn words(alloc: Allocator, line: []const u8) Allocator.Error!Words {
    var out = std.ArrayList([]const u8).init(alloc);
    var cur = std.ArrayList(u8).init(alloc);
    var in_word = false;
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == ' ' or c == '\t') {
            if (in_word) try out.append(try cur.toOwnedSlice());
            in_word = false;
            i += 1;
            continue;
        }
        in_word = true;
        if (c == '\'') {
            const end = std.mem.indexOfScalarPos(u8, line, i + 1, '\'') orelse return .{ .refused = "an unclosed single quote" };
            const quoted = line[i + 1 .. end];
            if (std.mem.indexOf(u8, quoted, ENV) != null) return .{ .refused = "`$CONDA_PREFIX` inside single quotes: a shell would not expand it" };
            try cur.appendSlice(quoted);
            i = end + 1;
            continue;
        }
        if (std.mem.indexOfScalar(u8, "\"\\`;|&<>()", c) != null) {
            return .{ .refused = try std.fmt.allocPrint(alloc, "`{c}`: the block is plain words, `$CONDA_PREFIX` and single quotes, nothing a shell reads another way", .{c}) };
        }
        if (c == '$') {
            const rest = line[i..];
            const ok = std.mem.startsWith(u8, rest, ENV) and (rest.len == ENV.len or !(std.ascii.isAlphanumeric(rest[ENV.len]) or rest[ENV.len] == '_'));
            if (!ok) return .{ .refused = "`$` outside quotes begins only `$CONDA_PREFIX`" };
            try cur.appendSlice(ENV);
            i += ENV.len;
            continue;
        }
        try cur.append(c);
        i += 1;
    }
    if (in_word) try out.append(try cur.toOwnedSlice());
    return .{ .words = try out.toOwnedSlice() };
}

fn isProgram(w: []const u8) bool {
    return w.len > ".mojo".len and std.mem.endsWith(u8, w, ".mojo");
}

/// The ARGS of `ws` for verb `verb` (file header), or null when the line has
/// another shape.
fn argsOf(ws: []const []const u8, verb: []const u8) ?[]const []const u8 {
    if (ws.len < 3 or !std.mem.eql(u8, ws[0], "mojo") or !std.mem.eql(u8, ws[1], verb)) return null;
    const tail: usize = if (std.mem.eql(u8, verb, "build")) 3 else 1;
    if (ws.len < 2 + tail) return null;
    const prog = ws.len - tail;
    if (!isProgram(ws[prog])) return null;
    if (tail == 3 and !std.mem.eql(u8, ws[prog + 1], "-o")) return null;
    const args = ws[2..prog];
    for (args) |a| if (isProgram(a)) return null;
    return args;
}

/// The link block of README `text`, named `display` in refusals.
pub fn parse(alloc: Allocator, text: []const u8, display: []const u8) Allocator.Error!Parsed {
    const lines = try md.splitLines(alloc, text);
    const fences = try md.fences(alloc, lines);
    var found: ?md.Fence = null;
    for (fences) |f| {
        if (!namesMarker(f.info)) continue;
        if (!std.mem.eql(u8, f.info, INFO)) {
            return refused(alloc, display, f.open_line + 1, "`{s}` is not `{s}`: the link block's info string is exactly that", .{ f.info, INFO });
        }
        if (found) |first| {
            return refused(alloc, display, f.open_line + 1, "a second `{s}` block (the first is at line {d})", .{ INFO, first.open_line + 1 });
        }
        found = f;
    }
    const f = found orelse return .none;
    const close = f.close_line orelse return refused(alloc, display, f.open_line + 1, "the `{s}` block is never closed", .{INFO});
    const body = lines[f.open_line + 1 .. close];
    if (body.len != 2) {
        return refused(alloc, display, f.open_line + 1, "the `{s}` block holds {d} lines; it holds two: `mojo run ...` then `mojo build ...`", .{ INFO, body.len });
    }
    var out: [2][]const []const u8 = undefined;
    const verbs = [_][]const u8{ "run", "build" };
    const shapes = [_][]const u8{ "mojo run ARGS... PROGRAM.mojo", "mojo build ARGS... PROGRAM.mojo -o OUT" };
    for (body, 0..) |l, k| {
        const n = f.open_line + 2 + k;
        const ws = switch (try words(alloc, l)) {
            .words => |w| w,
            .refused => |why| return refused(alloc, display, n, "{s}", .{why}),
        };
        out[k] = argsOf(ws, verbs[k]) orelse return refused(alloc, display, n, "line {d} of the block is not `{s}`", .{ k + 1, shapes[k] });
    }
    return .{ .commands = .{ .run = out[0], .build = out[1] } };
}

/// The `run\t<word>` and `build\t<word>` lines of `c`, one per argument:
/// what `link` writes and `link-check` compares.
pub fn argsText(alloc: Allocator, c: Commands) Allocator.Error![]const u8 {
    var out = std.ArrayList(u8).init(alloc);
    for (c.run) |a| try out.writer().print("run\t{s}\n", .{a});
    for (c.build) |a| try out.writer().print("build\t{s}\n", .{a});
    return out.toOwnedSlice();
}
