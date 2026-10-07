//! cov_branch_source: the source side of cov_branch_classify (README.md,
//! "cov_branch_classify"): which file names are the library's measured
//! sources, the functions they declare `@always_inline("nodebug")`, and the
//! class of the token at a branch's line and column. Imported by
//! cov_branch_classify.zig; no `main` of its own.

const std = @import("std");
const Alloc = std.mem.Allocator;

pub const max_src = 1 << 26;

pub fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("cov_branch_classify: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn oom() noreturn {
    fail("out of memory", .{});
}

// ---- files -----------------------------------------------------------------

pub const Where = enum { measured, excluded, unmapped, other_src };

pub const File = struct {
    where: Where,
    name: []const u8,
    repo: []const u8 = "",
    lines: [][]const u8 = &.{},
    exec: std.AutoHashMap(u64, void),
    branches: usize = 0,
};

pub const Opts = struct {
    prefix: []const u8,
    // PREFIX after its content-hash segment (`src/<lib>/`), or null.
    hash_tail: ?[]const u8,
    repo: []const u8,
    gens: [][]const u8,
    excludes: [][]const u8,
    exclude_files: [][]const u8,
};

pub fn cleanRel(rel: []const u8) bool {
    if (rel.len == 0) return false;
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
    }
    for (rel) |c| {
        if (c < 0x20 or c == 0x7f or c == '\\') return false;
    }
    return std.unicode.utf8ValidateSlice(rel);
}

pub fn isHash(s: []const u8) bool {
    if (s.len != 16) return false;
    for (s) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
}

/// The text after PREFIX's last segment of 16 hex digits and its '/', or null.
pub fn hashTail(prefix: []const u8) ?[]const u8 {
    var end = prefix.len;
    while (end > 0) {
        const slash = std.mem.lastIndexOfScalar(u8, prefix[0 .. end - 1], '/') orelse return null;
        if (end - 1 - (slash + 1) == 16 and isHash(prefix[slash + 1 .. end - 1])) return prefix[end..];
        end = slash + 1;
    }
    return null;
}

/// Whether `name` holds `/<16 hex>/<tail>`: a [src] of the library.
pub fn holdsSrc(name: []const u8, tail: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, name, from, tail)) |at| {
        from = at + 1;
        if (at >= 18 and name[at - 1] == '/' and name[at - 18] == '/' and isHash(name[at - 17 .. at - 1])) return true;
    }
    return false;
}

pub fn placeFile(alloc: Alloc, o: *const Opts, name: []const u8) File {
    var f = File{ .where = .unmapped, .name = name, .exec = std.AutoHashMap(u64, void).init(alloc) };
    if (std.mem.startsWith(u8, name, o.prefix)) {
        const rel = name[o.prefix.len..];
        for (o.gens) |g| {
            if (std.mem.eql(u8, g, rel)) {
                f.where = .excluded;
                return f;
            }
        }
        if (!cleanRel(rel)) fail("the measured file name '{s}' is not a clean relative path under --map ('{s}'): an empty, '.' or '..' segment, a control byte, a '\\' or not UTF-8", .{ name, o.prefix });
        f.where = .measured;
        f.repo = std.mem.concat(alloc, u8, &.{ o.repo, rel }) catch oom();
        const src = std.fs.cwd().readFileAlloc(alloc, name, max_src) catch |err|
            fail("{s} ({s}): cannot read the measured source: {s}", .{ f.repo, name, @errorName(err) });
        var lines = std.ArrayList([]const u8).init(alloc);
        var it = std.mem.splitScalar(u8, src, '\n');
        while (it.next()) |l| lines.append(l) catch oom();
        f.lines = lines.items;
        return f;
    }
    if (o.hash_tail) |t| {
        if (holdsSrc(name, t)) {
            f.where = .other_src;
            return f;
        }
    }
    for (o.exclude_files) |e| {
        if (std.mem.eql(u8, e, name)) f.where = .excluded;
    }
    for (o.excludes) |e| {
        if (std.mem.startsWith(u8, name, e)) f.where = .excluded;
    }
    return f;
}

/// The functions the library's sources declare `@always_inline("nodebug")`:
/// name -> `<repo path>:<line>` of the declaration.
pub fn nodebugNames(alloc: Alloc, o: *const Opts) std.StringHashMap([]const u8) {
    var names = std.StringHashMap([]const u8).init(alloc);
    var dir = std.fs.cwd().openDir(o.prefix, .{ .iterate = true }) catch |err|
        fail("--map's [src] '{s}' cannot be opened: {s}", .{ o.prefix, @errorName(err) });
    defer dir.close();
    var walker = dir.walk(alloc) catch oom();
    while (walker.next() catch |err| fail("walking '{s}': {s}", .{ o.prefix, @errorName(err) })) |w| {
        if (w.kind == .directory or !std.mem.endsWith(u8, w.basename, ".mojo")) continue;
        const rel = alloc.dupe(u8, w.path) catch oom();
        const src = dir.readFileAlloc(alloc, rel, max_src) catch |err| fail("{s}{s}: {s}", .{ o.prefix, rel, @errorName(err) });
        var lines = std.mem.splitScalar(u8, src, '\n');
        var armed = false;
        var ln: usize = 0;
        while (lines.next()) |raw| {
            ln += 1;
            const l = std.mem.trim(u8, raw, " \t\r");
            if (std.mem.startsWith(u8, l, "@always_inline(") and std.mem.indexOf(u8, l, "\"nodebug\"") != null) {
                armed = true;
                continue;
            }
            if (!armed or l.len == 0 or l[0] == '@' or l[0] == '#') continue;
            armed = false;
            const rest = if (std.mem.startsWith(u8, l, "def ")) l[4..] else if (std.mem.startsWith(u8, l, "fn ")) l[3..] else continue;
            var j: usize = 0;
            while (j < rest.len and isIdent(rest[j])) j += 1;
            if (j == 0) continue;
            names.put(rest[0..j], std.fmt.allocPrint(alloc, "{s}{s}:{d}", .{ o.repo, rel, ln }) catch oom()) catch oom();
        }
    }
    return names;
}

// ---- tokens ----------------------------------------------------------------

pub const Kind = enum { br, rhs, select, @"switch" };

pub const Class = enum {
    if_,
    elif,
    while_,
    and_,
    or_,
    for_range,
    plus,
    call,
    floordiv,
    mod,
    unknown,

    pub fn decision(c: Class) bool {
        return switch (c) {
            .if_, .elif, .while_, .and_, .or_, .for_range => true,
            else => false,
        };
    }

    /// The instruction kinds the class has shown (README.md's evidence).
    pub fn takes(c: Class, k: Kind) bool {
        return switch (c) {
            .if_, .elif => k != .rhs,
            .and_, .or_ => k == .br or k == .select,
            .while_, .for_range, .plus, .call => k == .br,
            .floordiv, .mod => k == .select,
            .unknown => false,
        };
    }
};

pub fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

pub fn firstWord(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    var j = i;
    while (j < line.len and isIdent(line[j])) j += 1;
    return line[i..j];
}

/// Whether the code of `line` (outside string literals and the comment)
/// holds a decision word: if, elif, while, for, and, or.
pub fn decisionLine(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == '#') return false;
        if (c == '"' or c == '\'') {
            i += 1;
            while (i < line.len and line[i] != c) : (i += 1) {
                if (line[i] == '\\') i += 1;
            }
            i += 1;
            continue;
        }
        if (!isIdent(c)) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < line.len and isIdent(line[j])) j += 1;
        for ([_][]const u8{ "if", "elif", "while", "for", "and", "or" }) |w| {
            if (std.mem.eql(u8, line[i..j], w)) return true;
        }
        i = j;
    }
    return false;
}

/// The class of the token at 1-based byte column `col` of `line`, and the
/// token as it reads there (for a message).
pub fn classify(line: []const u8, col: u64) struct { class: Class, token: []const u8 } {
    if (col == 0 or col > line.len) return .{ .class = .unknown, .token = "<column outside the line>" };
    const i: usize = @intCast(col - 1);
    const c = line[i];
    var end = i + 1;
    if (isIdent(c)) {
        while (end < line.len and isIdent(line[end])) end += 1;
        const word = line[i..end];
        if (i > 0 and isIdent(line[i - 1])) return .{ .class = .unknown, .token = word };
        const words = [_]struct { []const u8, Class }{
            .{ "if", .if_ }, .{ "elif", .elif }, .{ "while", .while_ }, .{ "and", .and_ }, .{ "or", .or_ },
        };
        for (words) |w| {
            if (std.mem.eql(u8, word, w[0])) return .{ .class = w[1], .token = word };
        }
        return .{ .class = .unknown, .token = word };
    }
    const next: u8 = if (i + 1 < line.len) line[i + 1] else 0;
    const snippet = line[i..@min(line.len, i + 3)];
    switch (c) {
        '(' => {
            var k = i;
            while (k > 0 and isIdent(line[k - 1])) k -= 1;
            if (k == i) return .{ .class = .unknown, .token = snippet };
            const callee = line[k .. i + 1];
            if (std.mem.eql(u8, firstWord(line), "for")) {
                const before = std.mem.trimRight(u8, line[0..k], " ");
                if (std.mem.eql(u8, callee, "range(") and std.mem.endsWith(u8, before, " in"))
                    return .{ .class = .for_range, .token = callee };
                return .{ .class = .unknown, .token = callee };
            }
            return .{ .class = .call, .token = callee };
        },
        '+' => return if (next == '=') .{ .class = .unknown, .token = "+=" } else .{ .class = .plus, .token = "+" },
        '%' => return if (next == '=') .{ .class = .unknown, .token = "%=" } else .{ .class = .mod, .token = "%" },
        '/' => {
            if (next == '/' and !(i + 2 < line.len and line[i + 2] == '=')) return .{ .class = .floordiv, .token = "//" };
            return .{ .class = .unknown, .token = snippet };
        },
        else => return .{ .class = .unknown, .token = snippet },
    }
}
