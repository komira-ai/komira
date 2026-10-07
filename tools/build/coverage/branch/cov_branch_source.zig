//! cov_branch_source: the source side of cov_branch_classify (README.md,
//! "cov_branch_classify"): which file names are the library's measured
//! sources, the functions they declare `@always_inline("nodebug")`, the
//! class of the token at a branch's line and column, the head of a `for`
//! line's iterable and the span of an `if`/`elif`/`while` header. Imported
//! by cov_branch_classify.zig; no `main` of its own.

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
    // Where the standard library's sources are named (`--stdlib`).
    stdlib: []const u8,
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
    for_in,
    string,
    plus,
    call,
    subscript,
    floordiv,
    mod,
    unknown,

    pub fn decision(c: Class) bool {
        return switch (c) {
            .if_, .elif, .while_, .and_, .or_, .for_in => true,
            else => false,
        };
    }

    /// The instruction kinds the class has shown (README.md's evidence). A
    /// select at a call and a br at a subscript are taken only in the
    /// shapes README.md names (cov_branch_ir.zig); a String's lifetime code
    /// (`string`) is told by its shape, at any token.
    pub fn takes(c: Class, k: Kind) bool {
        return switch (c) {
            .if_, .elif => k != .rhs,
            .and_, .or_, .string, .call => k == .br or k == .select,
            .while_, .for_in, .plus, .subscript => k == .br,
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

/// The index just past the string literal opening at `s[i]` (a quote).
fn skipString(s: []const u8, i: usize) usize {
    const q = s[i];
    var j = i + 1;
    while (j < s.len and s[j] != q) : (j += 1) {
        if (s[j] == '\\') j += 1;
    }
    return @min(s.len, j + 1);
}

/// Whether the code of `line` (outside string literals and the comment)
/// holds a decision word: if, elif, while, for, and, or.
pub fn decisionLine(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == '#') return false;
        if (c == '"' or c == '\'') {
            i = skipString(line, i);
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

/// The index of the bracket closing the one at `s[i]` (`(`, `[` or `{`;
/// strings skipped), or null.
fn closing(s: []const u8, i: usize) ?usize {
    var depth: usize = 0;
    var j = i;
    while (j < s.len) {
        switch (s[j]) {
            '"', '\'' => {
                j = skipString(s, j);
                continue;
            },
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => {
                depth -= 1;
                if (depth == 0) return j;
            },
            else => {},
        }
        j += 1;
    }
    return null;
}

/// The `[`, `(` or `{` opening the bracket closing at `lines[idx][i]`,
/// on that line or up to 64 lines before it (strings and comments are not
/// skipped: a bracket in one would be miscounted, and the call refused or
/// named wrongly as any unmatched one is).
fn openingBack(lines: []const []const u8, idx: usize, i: usize) ?struct { line: usize, pos: usize } {
    var depth: usize = 0;
    var ln = idx;
    var j = i + 1;
    while (true) {
        const s = lines[ln];
        while (j > 0) {
            j -= 1;
            switch (s[j]) {
                ')', ']', '}' => depth += 1,
                '(', '[', '{' => {
                    depth -= 1;
                    if (depth == 0) return .{ .line = ln, .pos = j };
                },
                else => {},
            }
        }
        if (ln == 0 or idx - ln >= 64) return null;
        ln -= 1;
        j = lines[ln].len;
    }
}

/// The offset in `it` (an iterable's text) of its head, where Mojo puts a
/// loop's iteration branch (README.md, "Classes"): a call's `(`, an
/// attribute's last `.`, a bare name's first character, a list literal's
/// `[`; null for anything else (a subscript, an operator, a tuple). The
/// chain starts at a name or a string literal (`"ab".as_bytes()`).
fn headOf(it: []const u8) ?usize {
    if (it.len == 0) return null;
    if (it[0] == '[') return if (closing(it, 0) == it.len - 1) 0 else null;
    var j: usize = 0;
    var head: ?usize = 0;
    if (it[0] == '"' or it[0] == '\'') {
        j = skipString(it, 0);
        if (j >= it.len or it[j] != '.') return null; // a bare literal
        head = null;
    } else {
        if (!isIdent(it[0]) or std.ascii.isDigit(it[0])) return null;
        while (j < it.len and isIdent(it[j])) j += 1;
    }
    while (j < it.len) {
        switch (it[j]) {
            '.' => {
                const dot = j;
                j += 1;
                const k = j;
                while (j < it.len and isIdent(it[j])) j += 1;
                if (j == k) return null;
                head = dot;
            },
            '(', '[' => {
                const end = closing(it, j) orelse return null;
                head = if (it[j] == '(') j else null;
                j = end + 1;
            },
            else => return null,
        }
    }
    return head;
}

/// The 1-based column of the head of the iterable of `for <targets> in
/// <iterable>:` at `lines[idx]` (the iterable may run on over following
/// lines, as a list literal does), or null: no such line, no head, or a
/// head on another line than the `for`'s.
pub fn forHead(alloc: Alloc, lines: []const []const u8, idx: usize) ?u64 {
    const line = lines[idx];
    if (!std.mem.eql(u8, firstWord(line), "for")) return null;
    const at_for = std.mem.indexOf(u8, line, "for").?;
    var depth: usize = 0;
    var in_at: ?usize = null;
    var ln = idx;
    var i = at_for + 3;
    // The `:` closing the header at depth 0: on line `ln`, at `i`.
    const colon_at = outer: while (ln < lines.len and ln < idx + 64) : ({
        ln += 1;
        i = 0;
    }) {
        const l = lines[ln];
        while (i < l.len) {
            switch (l[i]) {
                '"', '\'' => {
                    i = skipString(l, i);
                    continue;
                },
                '#' => break,
                '(', '[', '{' => depth += 1,
                ')', ']', '}' => depth -|= 1,
                ':' => if (depth == 0) break :outer i,
                ' ' => if (depth == 0 and in_at == null and ln == idx and std.mem.startsWith(u8, l[i..], " in ")) {
                    in_at = i + 4;
                },
                else => {},
            }
            i += 1;
        }
    } else return null;
    const from = in_at orelse return null;
    if (ln == idx and colon_at < from) return null;
    const last = lines[ln];
    var e = colon_at + 1;
    while (e < last.len and (last[e] == ' ' or last[e] == '\t' or last[e] == '\r')) e += 1;
    if (e < last.len and last[e] != '#') return null; // code after the ':'
    var raw: []const u8 = undefined;
    if (ln == idx) {
        raw = line[from..colon_at];
    } else {
        var parts = std.ArrayList([]const u8).init(alloc);
        parts.append(line[from..]) catch oom();
        for (lines[idx + 1 .. ln]) |mid| parts.append(mid) catch oom();
        parts.append(last[0..colon_at]) catch oom();
        raw = std.mem.join(alloc, "\n", parts.items) catch oom();
    }
    const lead = raw.len - std.mem.trimLeft(u8, raw, " ").len;
    const it = std.mem.trim(u8, raw, " \t\r\n");
    const h = headOf(it) orelse return null;
    if (from + lead + h >= line.len) return null; // the head is on a later line
    return from + lead + h + 1;
}

/// A source span, 1-based lines and columns, both ends inside.
pub const Span = struct { l1: u64, c1: u64, l2: u64, c2: u64 };

pub fn inSpan(s: Span, line: u64, col: u64) bool {
    if (line < s.l1 or line > s.l2) return false;
    if (line == s.l1 and col < s.c1) return false;
    if (line == s.l2 and col > s.c2) return false;
    return true;
}

/// The header of the `if`, `elif` or `while` statement whose keyword is at
/// `line`:`col` (the line's first word): from the keyword to the `:` that
/// closes it at bracket depth 0, across continuation lines; null when the
/// token there is no such keyword (a ternary `if`, another token).
pub fn headerSpan(lines: []const []const u8, line: u64, col: u64) ?Span {
    if (line < 1 or line > lines.len) return null;
    const l = lines[@intCast(line - 1)];
    const w = firstWord(l);
    if (!std.mem.eql(u8, w, "if") and !std.mem.eql(u8, w, "elif") and !std.mem.eql(u8, w, "while")) return null;
    const start = std.mem.indexOf(u8, l, w).?;
    if (col != start + 1) return null;
    var depth: usize = 0;
    var ln: usize = @intCast(line - 1);
    var i = start + w.len;
    var n: usize = 0;
    while (ln < lines.len and n < 64) : (n += 1) {
        const s = lines[ln];
        while (i < s.len) {
            switch (s[i]) {
                '"', '\'' => {
                    i = skipString(s, i);
                    continue;
                },
                '#' => break,
                '(', '[', '{' => depth += 1,
                ')', ']', '}' => depth -|= 1,
                ':' => if (depth == 0) return .{ .l1 = line, .c1 = col, .l2 = ln + 1, .c2 = i + 1 },
                else => {},
            }
            i += 1;
        }
        ln += 1;
        i = 0;
    }
    return null;
}

pub const Token = struct { class: Class, token: []const u8, callee: []const u8 = "" };

/// The class of the token at 1-based byte column `col` of `lines[idx]`, the
/// token as it reads there (for a message), and for a call the callee's
/// name. The lines around it are read for a `for` header or a call's
/// `name[...](` that runs over several lines.
pub fn classify(alloc: Alloc, lines: []const []const u8, idx: usize, col: u64) Token {
    const line = lines[idx];
    if (col == 0 or col > line.len) return .{ .class = .unknown, .token = "<column outside the line>" };
    const i: usize = @intCast(col - 1);
    const c = line[i];
    const on_for = std.mem.eql(u8, firstWord(line), "for");
    if (forHead(alloc, lines, idx)) |h| {
        if (h == col) {
            var e = i + 1;
            if (isIdent(c)) {
                while (e < line.len and isIdent(line[e])) e += 1;
            }
            return .{ .class = .for_in, .token = line[i..e] };
        }
    }
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
            // A call: `name(`, or `name[...](` (the name before the `[`,
            // which may be on an earlier line).
            var nl = line;
            var name_end = i;
            if (i > 0 and line[i - 1] == ']') {
                const o = openingBack(lines, idx, i - 1) orelse return .{ .class = .unknown, .token = snippet };
                nl = lines[o.line];
                name_end = o.pos;
            }
            var k = name_end;
            while (k > 0 and isIdent(nl[k - 1])) k -= 1;
            if (k == name_end) return .{ .class = .unknown, .token = snippet };
            const tok = if (nl.ptr == line.ptr) line[k .. i + 1] else nl[k .. name_end + 1];
            // Off a `for` line's head, a call may be another iteration.
            if (on_for) return .{ .class = .unknown, .token = tok };
            return .{ .class = .call, .token = tok, .callee = nl[k..name_end] };
        },
        '[' => {
            // Indexing follows a name, a `]` or a `)`; any other `[` opens a
            // list literal, a decision only as a loop's head (above).
            if (i > 0 and (isIdent(line[i - 1]) or line[i - 1] == ']' or line[i - 1] == ')'))
                return .{ .class = .subscript, .token = "[" };
            return .{ .class = .unknown, .token = snippet };
        },
        '+' => return if (next == '=') .{ .class = .unknown, .token = "+=" } else .{ .class = .plus, .token = "+" },
        '%' => return if (next == '=') .{ .class = .unknown, .token = "%=" } else .{ .class = .mod, .token = "%" },
        '/' => {
            if (next == '/') {
                const assign = i + 2 < line.len and line[i + 2] == '=';
                return .{ .class = .floordiv, .token = if (assign) "//=" else "//" };
            }
            return .{ .class = .unknown, .token = snippet };
        },
        else => return .{ .class = .unknown, .token = snippet },
    }
}
