// Why Zig: build tools are Zig (tools/build/README.md). These are the three
// scanners the readme_api_coverage action ran as awk programs under a busybox
// shell (EXPORTS_AWK, METHODS_AWK, IDS_AWK), with their line-at-a-time
// semantics kept: the same states, the same regular expressions, as code.
//! readme_api_scan: what readme_api_coverage reads from Mojo source.
//!
//! `exports` reads a package's `__init__.mojo` for the names it exports,
//! `methods` the public methods of the column-0 structs of one file, and `Ids`
//! the identifiers a README program uses in code. The rules are those of
//! docs/readme_api_coverage.md; the unit tests state each.

const std = @import("std");
const A = std.mem.Allocator;

/// The records of an awk program over `text`: lines, the last one not needing
/// its newline, no empty record after a final newline.
pub fn records(a: A, text: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).init(a);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        if (it.peek() == null and l.len == 0) break;
        try out.append(l);
    }
    return out.toOwnedSlice();
}

/// The non-overlapping `"""` on a line, as awk's gsub counts them.
fn triples(line: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, line, i, "\"\"\"")) |at| {
        n += 1;
        i = at + 3;
    }
    return n;
}

fn stripComment(s: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, s, '#')) |i| s[0..i] else s;
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn isIdentStart(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_';
}

fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

/// `^[A-Za-z_][A-Za-z0-9_]*$`.
pub fn isIdent(s: []const u8) bool {
    if (s.len == 0 or !isIdentStart(s[0])) return false;
    for (s[1..]) |c| {
        if (!isIdentChar(c)) return false;
    }
    return true;
}

/// The identifier a string starts with (`match(s, /^[A-Za-z_][A-Za-z0-9_]*/)`).
fn identPrefix(s: []const u8) []const u8 {
    var n: usize = 0;
    while (n < s.len and isIdentChar(s[n])) n += 1;
    return s[0..n];
}

fn skipBlank(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and isBlank(s[i])) i += 1;
    return s[i..];
}

/// `s` starts with `word` and then at least one blank; the rest after the blanks.
fn afterWord(s: []const u8, word: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, s, word)) return null;
    const rest = s[word.len..];
    if (rest.len == 0 or !isBlank(rest[0])) return null;
    return skipBlank(rest);
}

pub const Export = struct {
    /// The bound name; "*" for `from .x import *`.
    name: []const u8,
    /// The name in the module (before `as`).
    orig: []const u8,
    /// Where a struct of that name is looked for: x/y for `from .x.y import`,
    /// `__init__` for a declaration here, `-` for a module (`from . import x`);
    /// for "*", the module as written.
    path: []const u8,
    line: usize,
};

/// An import statement is complete when it does not end in a backslash and its
/// parentheses balance.
fn closed(s: []const u8) bool {
    var end = s.len;
    while (end > 0 and isBlank(s[end - 1])) end -= 1;
    if (end > 0 and s[end - 1] == '\\') return false;
    var o: usize = 0;
    var c: usize = 0;
    for (s) |ch| {
        if (ch == '(') o += 1;
        if (ch == ')') c += 1;
    }
    return o == c;
}

fn emit(a: A, out: *std.ArrayList(Export), stmt: []const u8, ln: usize) !void {
    var s = stmt;
    s = afterWord(s, "from") orelse s;
    // mod: up to the first blank.
    var m: usize = 0;
    while (m < s.len and !isBlank(s[m])) m += 1;
    const mod = s[0..m];
    // `^[^ \t]+[ \t]+import[ \t]+`
    if (m == 0 or m >= s.len) return;
    const rest0 = afterWord(skipBlank(s[m..]), "import") orelse return;
    // gsub(/[()\\]/, " ")
    const rest = try a.dupe(u8, rest0);
    for (rest) |*ch| {
        if (ch.* == '(' or ch.* == ')' or ch.* == '\\') ch.* = ' ';
    }
    var items = std.mem.splitScalar(u8, rest, ',');
    while (items.next()) |raw| {
        const it = std.mem.trim(u8, raw, " \t");
        if (it.len == 0) continue;
        if (std.mem.eql(u8, it, "*")) {
            try out.append(.{ .name = "*", .orig = "*", .path = mod, .line = ln });
            continue;
        }
        var w = std.ArrayList([]const u8).init(a);
        var parts = std.mem.tokenizeAny(u8, it, " \t");
        while (parts.next()) |x| try w.append(x);
        const orig = w.items[0];
        const name = if (w.items.len >= 3 and std.mem.eql(u8, w.items[1], "as")) w.items[2] else orig;
        if (name[0] == '_' or !isIdent(name)) continue;
        var path: []const u8 = "-";
        if (!std.mem.eql(u8, mod, ".")) {
            const p = try a.dupe(u8, mod[1..]);
            for (p) |*ch| {
                if (ch.* == '.') ch.* = '/';
            }
            path = p;
        }
        try out.append(.{ .name = name, .orig = orig, .path = path, .line = ln });
    }
}

/// The exports of one `__init__.mojo` of package `pkg`: the names its imports
/// of its own modules bind at column 0 (relative, or by the package's name,
/// parenthesised and backslash-continued forms included), and the column-0
/// declarations. Lines in triple-quoted strings and comments are not read.
pub fn exports(a: A, pkg: []const u8, text: []const u8) ![]Export {
    var out = std.ArrayList(Export).init(a);
    const own = try std.fmt.allocPrint(a, "from {s}.", .{pkg});
    var instr = false;
    var pending: ?[]const u8 = null;
    var start: usize = 0;
    const ls = try records(a, text);
    for (ls, 1..) |line, nr| {
        const n = triples(line);
        if (instr) {
            if (n % 2 == 1) instr = false;
            continue;
        }
        if (n % 2 == 1) {
            instr = true;
            continue;
        }
        if (pending) |p| {
            const s = stripComment(line);
            var base = p;
            // sub(/\\[ \t]*$/, "", pending)
            var end = base.len;
            while (end > 0 and isBlank(base[end - 1])) end -= 1;
            if (end > 0 and base[end - 1] == '\\') base = base[0 .. end - 1];
            const joined = try std.fmt.allocPrint(a, "{s} {s}", .{ base, s });
            if (closed(joined)) {
                try emit(a, &out, joined, start);
                pending = null;
            } else pending = joined;
            continue;
        }
        const own_hit = std.mem.startsWith(u8, line, own);
        const rel_hit = if (afterWord(line, "from")) |r| r.len > 0 and r[0] == '.' else false;
        if (rel_hit or own_hit) {
            var s = stripComment(line);
            if (std.mem.startsWith(u8, s, own)) s = try std.fmt.allocPrint(a, "from .{s}", .{s[own.len..]});
            if (closed(s)) {
                try emit(a, &out, s, nr);
            } else {
                pending = s;
                start = nr;
            }
            continue;
        }
        inline for (.{ "def", "fn", "struct", "trait", "comptime", "alias" }) |kw| {
            if (afterWord(line, kw)) |rest| {
                if (rest.len > 0 and isIdentStart(rest[0])) {
                    const name = identPrefix(rest);
                    if (name[0] != '_') try out.append(.{ .name = name, .orig = name, .path = "__init__", .line = nr });
                }
                break;
            }
        }
    }
    return out.toOwnedSlice();
}

pub const Method = struct {
    strukt: []const u8,
    name: []const u8,
    file: []const u8,
    line: usize,
};

fn depth(s: []const u8) i64 {
    var d: i64 = 0;
    for (s) |c| {
        if (c == '[' or c == '(') d += 1;
        if (c == ']' or c == ')') d -= 1;
    }
    return d;
}

fn endsWithColon(s: []const u8) bool {
    var end = s.len;
    while (end > 0 and isBlank(s[end - 1])) end -= 1;
    return end > 0 and s[end - 1] == ':';
}

/// The public methods of every column-0 struct of one file: a `def`/`fn` at
/// four spaces in the struct's body. A struct's header may span lines: its
/// body starts after the line that closes its brackets and ends with `:`.
/// Underscore names, write_to and write_repr_to are not counted (syntax and
/// print reach them, not their names).
pub fn methods(a: A, file: []const u8, text: []const u8, out: *std.ArrayList(Method)) !void {
    var instr = false;
    var cur: []const u8 = "";
    var hdr = false;
    var d: i64 = 0;
    const ls = try records(a, text);
    for (ls, 1..) |line, nr| {
        const n = triples(line);
        if (instr) {
            if (n % 2 == 1) instr = false;
            continue;
        }
        if (n % 2 == 1) {
            instr = true;
            continue;
        }
        if (hdr) {
            const s = stripComment(line);
            d += depth(s);
            if (d <= 0 and endsWithColon(s)) hdr = false;
            continue;
        }
        if (line.len > 0 and !isBlank(line[0]) and line[0] != '#') {
            cur = "";
            if (afterWord(line, "struct")) |rest| {
                if (rest.len > 0 and isIdentStart(rest[0])) {
                    cur = identPrefix(rest);
                    const s = stripComment(line);
                    d = depth(s);
                    hdr = !(d <= 0 and endsWithColon(s));
                }
            }
            continue;
        }
        if (cur.len > 0 and std.mem.startsWith(u8, line, "    ")) {
            const body = line[4..];
            const rest = afterWord(body, "def") orelse afterWord(body, "fn") orelse continue;
            if (rest.len == 0 or !isIdentStart(rest[0])) continue;
            const name = identPrefix(rest);
            if (name[0] == '_' or std.mem.eql(u8, name, "write_to") or std.mem.eql(u8, name, "write_repr_to")) continue;
            try out.append(.{ .strukt = cur, .name = name, .file = file, .line = nr });
        }
    }
}

/// The identifiers a README's programs use in code. Feed it every line of
/// every program, in order: the string state and a parenthesised import carry
/// over, as they did in one awk run over all the programs. Keys are `n\t<id>`
/// for an identifier and also `a\t<id>` when it is an attribute (`.id`).
pub const Ids = struct {
    /// The open string's quote: empty, `"`, `'`, or a triple of either.
    q: []const u8 = "",
    imp: i64 = 0,

    fn scan(self: *Ids, a: A, s: []const u8) ![]u8 {
        var out = std.ArrayList(u8).init(a);
        var i: usize = 0;
        while (i < s.len) {
            if (self.q.len > 0) {
                if (std.mem.startsWith(u8, s[i..], self.q)) {
                    i += self.q.len;
                    self.q = "";
                    try out.append(' ');
                    continue;
                }
                if (s[i] == '\\') {
                    i += 2;
                    continue;
                }
                i += 1;
                continue;
            }
            const c = s[i];
            if (c == '#') break;
            if (c == '"' or c == '\'') {
                const three: []const u8 = if (c == '"') "\"\"\"" else "'''";
                self.q = if (std.mem.startsWith(u8, s[i..], three)) three else if (c == '"') "\"" else "'";
                i += self.q.len;
                try out.append(' ');
                continue;
            }
            try out.append(c);
            i += 1;
        }
        if (self.q.len == 1) self.q = "";
        return out.toOwnedSlice();
    }

    pub fn feed(self: *Ids, a: A, line: []const u8, keys: *std.StringHashMap(void)) !void {
        if (std.mem.eql(u8, line, "def main() raises:")) return;
        const instr = self.q.len > 0;
        const s = try self.scan(a, line);
        var parens: i64 = 0;
        for (s) |c| {
            if (c == '(') parens += 1;
            if (c == ')') parens -= 1;
        }
        if (self.imp > 0) {
            self.imp += parens;
            return;
        }
        if (!instr) {
            const t = std.mem.trimLeft(u8, line, " \t");
            if ((afterWord(t, "from") != null or afterWord(t, "import") != null)) {
                self.imp = @max(parens, 0);
                return;
            }
        }
        // gsub(/\./, " .") then everything but [A-Za-z0-9_.] to a blank.
        var spaced = std.ArrayList(u8).init(a);
        for (s) |c| {
            if (c == '.') {
                try spaced.append(' ');
                try spaced.append('.');
            } else if (isIdentChar(c)) {
                try spaced.append(c);
            } else try spaced.append(' ');
        }
        var prev: []const u8 = "";
        var toks = std.mem.tokenizeScalar(u8, spaced.items, ' ');
        while (toks.next()) |tok| {
            const attr = tok[0] == '.';
            const t = if (attr) tok[1..] else tok;
            if (!isIdent(t)) {
                prev = "";
                continue;
            }
            if (!attr and isDeclWord(prev)) {
                prev = t;
                continue;
            }
            try keys.put(try std.fmt.allocPrint(a, "n\t{s}", .{t}), {});
            if (attr) try keys.put(try std.fmt.allocPrint(a, "a\t{s}", .{t}), {});
            prev = if (attr) "" else t;
        }
    }
};

fn isDeclWord(s: []const u8) bool {
    inline for (.{ "def", "fn", "struct", "trait", "comptime", "alias", "var" }) |w| {
        if (std.mem.eql(u8, s, w)) return true;
    }
    return false;
}
