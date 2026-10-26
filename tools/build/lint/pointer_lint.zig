//! pointer_lint: the action of the pointer_lint rule (defs.bzl), the Mojo
//! pointer rules of docs/design/mojo_safety_and_idioms.md over every .mojo
//! file of a tree, held against two ledgers.
//!
//!   pointer_lint <result.json> <stage> <prefix> <public root>
//!       <ffi> <ffi name> <holds> <holds name>
//!
//! Reads every file named `*.mojo` under <stage> (a buck-out directory) and
//! writes <result.json>, the validation result Buck2 reads: status "failure"
//! with the findings as the message when there are any, "success" otherwise.
//! Findings name a file of the tree as <prefix><path in the tree> and a
//! ledger row as <name>:<line>. It exits 0 either way; Buck2 fails any build
//! whose graph holds the target. A file it cannot read exits non-zero.
//!
//! The rules, one site each (`readFile` says how a statement is read):
//!
//!   wildcard_origin  a wildcard origin named in code: MutAnyOrigin,
//!                    ImmutAnyOrigin, MutExternalOrigin or MutUntrackedOrigin
//!                    (the Mojo 1.1 name of MutExternalOrigin). One site per
//!                    occurrence. Not a site in a file the FFI ledger lists.
//!   from_address     `unsafe_from_address=`: a pointer made from an integer.
//!   partial_move     a move out of a field through its address:
//!                    `UnsafePointer(to=<expr>.<field>).take_pointee()`, or
//!                    `p.take_pointee()` where an earlier statement of the
//!                    same function bound `p = UnsafePointer(to=<expr>.<field>)`
//!                    (the two-statement form; the site is the take).
//!                    `UnsafePointer[...](to=...)` counts the same. A pointer
//!                    to a whole value (`to=x`, `to=p[]`) is not a partial move.
//!   parallelize      the standard library's `parallelize[`.
//!   libc_redeclare   `external_call["read", ...]` or `external_call["open", ...]`:
//!                    a second declaration of a libc function the standard
//!                    library already binds.
//!   public_pointer   a public function whose signature names UnsafePointer
//!                    or OpaquePointer, in a library file: a file under the
//!                    public root, not under its package's `tests` directory
//!                    (a package is <root>/<pkg> or, test-only,
//!                    <root>/tests/<kind>/<pkg>), and with no path segment
//!                    that starts with `_` (`__init__.mojo` is public).
//!                    Public: a module-level `def`/`fn` whose name does not
//!                    start with `_`, or a method (four spaces in) of a
//!                    module-level struct or trait whose name does not start
//!                    with `_`, the method named without a leading `_` or
//!                    `__<name>__` (a dunder is reached through syntax, so it
//!                    is public). Nested functions are not public.
//!
//! Text is read as code only (mojo_tokens.zig): docstrings and string
//! literals are blanked and comments dropped, so a sentence naming a banned
//! spelling is not a site (libc_redeclare reads the function name in its
//! string, from the same statement with only comments and docstrings
//! dropped). A statement written over several lines is joined until its
//! brackets close, then matched as one and reported at its first line.
//!
//! Limits (a text reader's): a wildcard origin or a pointer type reached
//! through an alias or a type parameter is not seen; a pointer bound in one
//! function and taken in another, or through a second name, is not seen; a
//! partial move through a subscript (`to=x[i]`) is not counted.
//!
//! The ledgers, `#` lines and blank lines comments, rows tab-separated:
//! <ffi>, rows `<file> <reason>`: the FFI modules, whose wildcard origins
//! are not sites; a row's file must hold a line starting `# FFI-BOUNDARY:`
//! (blanks before and after the `#` allowed; the raw line is read, so such a
//! line inside a docstring counts) and name a wildcard origin. <holds>, rows
//! `<rule> <file> <count> <reason>`: the sites that predate the lint. A held
//! file must have exactly <count> sites of that rule: more is a new site,
//! fewer is a row to lower or delete, so the holds only shrink. A row naming
//! no .mojo file of the tree, a repeated row, an unknown rule, a bad count
//! or an empty reason is a finding, in either ledger.

const std = @import("std");
const tok = @import("mojo_tokens.zig");
const Allocator = std.mem.Allocator;

pub const Rule = enum {
    wildcard_origin,
    from_address,
    partial_move,
    parallelize,
    libc_redeclare,
    public_pointer,

    pub fn describe(r: Rule) []const u8 {
        return switch (r) {
            .wildcard_origin => "a wildcard origin outside a module's FFI internals",
            .from_address => "a pointer made from an integer (unsafe_from_address=)",
            .partial_move => "a partial move through a pointer: move the field out with Optional.take(), OwnedPointer.take(), swap or List.pop()",
            .parallelize => "the standard library's parallelize[: run the work on a ParallelDispatch",
            .libc_redeclare => "a second declaration of libc read or open, which the standard library binds",
            .public_pointer => "a public function takes or returns a pointer",
        };
    }
};

const rule_list = "wildcard_origin, from_address, partial_move, parallelize, libc_redeclare, public_pointer";

pub const Site = struct { rule: Rule, line: usize, text: []const u8 };

pub const File = struct { path: []const u8, contents: []const u8 };

pub const FileResult = struct {
    sites: []const Site,
    /// The file holds a line starting `# FFI-BOUNDARY:` (isMarkerLine).
    marked: bool,
};

const wild_names = [_][]const u8{ "MutAnyOrigin", "ImmutAnyOrigin", "MutExternalOrigin", "MutUntrackedOrigin" };
const ptr_names = [_][]const u8{ "UnsafePointer", "OpaquePointer" };

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn skipBlank(s: []const u8, from: usize) usize {
    var i = from;
    while (i < s.len and isBlank(s[i])) i += 1;
    return i;
}

fn allBlank(s: []const u8) bool {
    return skipBlank(s, 0) == s.len;
}

fn startsWithAt(s: []const u8, at: usize, prefix: []const u8) bool {
    return at <= s.len and std.mem.startsWith(u8, s[at..], prefix);
}

fn nameEnd(s: []const u8, at: usize, names: []const []const u8) ?usize {
    for (names) |n| if (startsWithAt(s, at, n)) return at + n.len;
    return null;
}

/// What follows a name in a bounded match.
const Tail = enum {
    /// a byte that is not a word byte (taken into the match), or the end
    word_end,
    /// blanks, then `[`
    bracket,
};

fn tailEnd(s: []const u8, e: usize, tail: Tail) ?usize {
    switch (tail) {
        .word_end => {
            if (e == s.len) return e;
            return if (isWord(s[e])) null else e + 1;
        },
        .bracket => {
            const j = skipBlank(s, e);
            return if (j < s.len and s[j] == '[') j + 1 else null;
        },
    }
}

/// The end of a match of `(^|[^A-Za-z0-9_])(<names>)<tail>` starting at `m`,
/// where `^` matches at `bol` only.
fn boundedAt(s: []const u8, m: usize, bol: usize, names: []const []const u8, tail: Tail) ?usize {
    if (m == bol) {
        if (nameEnd(s, m, names)) |e| return tailEnd(s, e, tail);
    }
    if (m < s.len and !isWord(s[m])) {
        if (nameEnd(s, m + 1, names)) |e| return tailEnd(s, e, tail);
    }
    return null;
}

/// The number of non-overlapping bounded matches in `s`, each taking the
/// byte before and after its name, as an awk gsub counts them.
fn countBounded(s: []const u8, names: []const []const u8, tail: Tail) usize {
    var n: usize = 0;
    var p: usize = 0;
    outer: while (p < s.len) {
        var m = p;
        while (m < s.len) : (m += 1) {
            if (boundedAt(s, m, 0, names, tail)) |e| {
                n += 1;
                p = e;
                continue :outer;
            }
        }
        break;
    }
    return n;
}

/// `unsafe_from_address`, blanks, `=`.
fn countFromAddress(s: []const u8) usize {
    var n: usize = 0;
    var p: usize = 0;
    while (std.mem.indexOfPos(u8, s, p, "unsafe_from_address")) |k| {
        const j = skipBlank(s, k + "unsafe_from_address".len);
        if (j < s.len and s[j] == '=') {
            n += 1;
            p = j + 1;
        } else p = k + 1;
    }
    return n;
}

/// `external_call`, blanks, `[`.
fn namesExternalCall(s: []const u8) bool {
    var p: usize = 0;
    while (std.mem.indexOfPos(u8, s, p, "external_call")) |k| {
        const j = skipBlank(s, k + "external_call".len);
        if (j < s.len and s[j] == '[') return true;
        p = k + 1;
    }
    return false;
}

/// `external_call["read"` or `"open"`, then `]` or `,` (blanks allowed
/// between the parts).
fn countLibc(s: []const u8) usize {
    var n: usize = 0;
    var p: usize = 0;
    while (std.mem.indexOfPos(u8, s, p, "external_call")) |k| {
        p = k + 1;
        var j = skipBlank(s, k + "external_call".len);
        if (j >= s.len or s[j] != '[') continue;
        j = skipBlank(s, j + 1);
        if (j >= s.len or s[j] != '"') continue;
        j += 1;
        if (!startsWithAt(s, j, "read\"") and !startsWithAt(s, j, "open\"")) continue;
        j = skipBlank(s, j + 5);
        if (j >= s.len or (s[j] != ']' and s[j] != ',')) continue;
        n += 1;
        p = j + 1;
    }
    return n;
}

/// `(^|[^A-Za-z0-9_.])<name>`, blanks, `.`, blanks, `take_pointee`, blanks, `(`.
fn takesThrough(s: []const u8, name: []const u8) bool {
    var p: usize = 0;
    while (std.mem.indexOfPos(u8, s, p, name)) |k| {
        p = k + 1;
        if (k > 0 and (isWord(s[k - 1]) or s[k - 1] == '.')) continue;
        var j = skipBlank(s, k + name.len);
        if (j >= s.len or s[j] != '.') continue;
        j = skipBlank(s, j + 1);
        if (!startsWithAt(s, j, "take_pointee")) continue;
        j = skipBlank(s, j + "take_pointee".len);
        if (j < s.len and s[j] == '(') return true;
    }
    return false;
}

/// After an assignment's `=`: nothing but blanks, or one byte that is not `=`.
const AssignTail = enum { rest_blank, not_eq };

fn assignAt(s: []const u8, i: usize, tail: AssignTail) bool {
    if (i >= s.len or !(std.ascii.isAlphabetic(s[i]) or s[i] == '_')) return false;
    var k = i;
    while (k < s.len and isWord(s[k])) k += 1;
    k = skipBlank(s, k);
    if (k < s.len and s[k] == ':') {
        while (k < s.len and s[k] != '=') k += 1;
    }
    if (k >= s.len or s[k] != '=') return false;
    k += 1;
    return switch (tail) {
        .rest_blank => allBlank(s[k..]),
        .not_eq => k < s.len and s[k] != '=',
    };
}

/// `s` is `[var] <name>[: <type>] = ...`: `^[ \t]*(var[ \t]+)?<name>[ \t]*(:[^=]*)?=` and the tail.
fn isAssignment(s: []const u8, tail: AssignTail) bool {
    const i = skipBlank(s, 0);
    if (startsWithAt(s, i, "var") and i + 3 < s.len and isBlank(s[i + 3])) {
        if (assignAt(s, skipBlank(s, i + 3), tail)) return true;
    }
    return assignAt(s, i, tail);
}

/// The name an assignment binds: blanks and a `var ` dropped, up to the
/// first byte that is not a word byte.
fn assignedName(s: []const u8) []const u8 {
    var i = skipBlank(s, 0);
    if (startsWithAt(s, i, "var") and i + 3 < s.len and isBlank(s[i + 3])) i = skipBlank(s, i + 3);
    var j = i;
    while (j < s.len and isWord(s[j])) j += 1;
    return s[i..j];
}

/// `^[ \t]*to[ \t]*=` and `\.[ \t]*<identifier>[ \t]*$`: the address of a field.
fn isFieldAddress(arg: []const u8) bool {
    var i = skipBlank(arg, 0);
    if (!startsWithAt(arg, i, "to")) return false;
    i = skipBlank(arg, i + 2);
    if (i >= arg.len or arg[i] != '=') return false;
    var e = arg.len;
    while (e > 0 and isBlank(arg[e - 1])) e -= 1;
    var b = e;
    while (b > 0 and isWord(arg[b - 1])) b -= 1;
    if (b == e or std.ascii.isDigit(arg[b])) return false;
    while (b > 0 and isBlank(arg[b - 1])) b -= 1;
    return b > 0 and arg[b - 1] == '.';
}

/// `^[ \t]*\.[ \t]*take_pointee[ \t]*\(`.
fn startsTake(after: []const u8) bool {
    var j = skipBlank(after, 0);
    if (j >= after.len or after[j] != '.') return false;
    j = skipBlank(after, j + 1);
    if (!startsWithAt(after, j, "take_pointee")) return false;
    j = skipBlank(after, j + "take_pointee".len);
    return j < after.len and after[j] == '(';
}

/// A name of the form `__<...>__`: `^__[A-Za-z0-9_]*__`.
fn isDunder(nm: []const u8) bool {
    if (!std.mem.startsWith(u8, nm, "__")) return false;
    var e: usize = 0;
    while (e < nm.len and isWord(nm[e])) e += 1;
    return e >= 4 and std.mem.indexOfPos(u8, nm[0..e], 2, "__") != null;
}

/// `s` starts with `<word>` and a blank.
fn startsKeyword(s: []const u8, word: []const u8) bool {
    return std.mem.startsWith(u8, s, word) and s.len > word.len and isBlank(s[word.len]);
}

/// After `^[ \t]*(fn|def)[ \t]+` when a letter or `_` follows: the rest.
fn defName(s: []const u8) ?[]const u8 {
    const i = skipBlank(s, 0);
    for ([_][]const u8{ "fn", "def" }) |kw| {
        if (!startsWithAt(s, i, kw)) continue;
        const j = skipBlank(s, i + kw.len);
        if (j == i + kw.len or j >= s.len) continue;
        if (std.ascii.isAlphabetic(s[j]) or s[j] == '_') return s[j..];
    }
    return null;
}

/// A library file: under `root` (the public root and `/`), outside its
/// package's `tests` directory, and no path segment starting with `_` but a
/// final `__init__.mojo`. A package is <root><pkg>, or a test-only one
/// <root>tests/<kind>/<pkg> (docs/architecture.md#end-to-end-tests): only a
/// `tests` directory below the package root is skipped.
pub fn isLibFile(a: Allocator, path: []const u8, root: []const u8) !bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    var q: []const u8 = path;
    if (std.mem.eql(u8, path, "__init__.mojo") or std.mem.endsWith(u8, path, "/__init__.mojo")) {
        const cut = path.len - "__init__.mojo".len;
        const head = if (cut > 0) path[0 .. cut - 1] else "";
        q = try std.mem.concat(a, u8, &.{ head, "/init.mojo" });
    }
    if (q[0] == '_' or std.mem.indexOf(u8, q, "/_") != null) return false;
    var r: []const u8 = q[@min(root.len, q.len)..];
    if (std.mem.startsWith(u8, r, "tests/")) {
        // tests/<kind>/<pkg>/: a test-only package's root.
        var segs: usize = 0;
        var k: usize = 0;
        var cut: ?usize = null;
        while (k < r.len) : (k += 1) {
            if (r[k] != '/') continue;
            if (k > 0 and r[k - 1] == '/') break;
            segs += 1;
            if (segs == 3) {
                cut = k + 1;
                break;
            }
        }
        r = if (cut) |c| r[c..] else try std.mem.concat(a, u8, &.{ "tests/", r });
    } else if (std.mem.indexOfScalar(u8, r, '/')) |s| {
        if (s > 0) r = r[s + 1 ..];
    }
    const slashed = try std.mem.concat(a, u8, &.{ "/", r });
    return std.mem.indexOf(u8, slashed, "/tests/") == null;
}

/// Reads one file: its sites, in order, and whether it is marked as an FFI
/// module. `root` is the public root and `/`.
pub fn readFile(a: Allocator, path: []const u8, contents: []const u8, root: []const u8) !FileResult {
    var r = Reader{
        .a = a,
        .sites = std.ArrayList(Site).empty,
        .libfile = try isLibFile(a, path, root),
        .bound = std.StringHashMap(usize).init(a),
        .buf = std.ArrayList(u8).empty,
        .rbuf = std.ArrayList(u8).empty,
    };
    var marked = false;
    var lx = tok.Lexer{};
    var spans = std.ArrayList(tok.Span).empty;
    var code = std.ArrayList(u8).empty;
    var lit = std.ArrayList(u8).empty;
    var it = Lines{ .text = contents };
    var ln: usize = 0;
    while (it.next()) |line| {
        ln += 1;
        try lx.scan(a, line, &spans);
        if (isMarkerLine(line)) marked = true;
        code.clearRetainingCapacity();
        lit.clearRetainingCapacity();
        try tok.view(a, line, spans.items, .blank, &code);
        try tok.view(a, line, spans.items, .keep, &lit);
        try r.line(ln, code.items, lit.items);
    }
    try r.flush();
    return .{ .sites = r.sites.items, .marked = marked };
}

/// `^[[:space:]]*#[[:space:]]*FFI-BOUNDARY:`, read from the raw line: a
/// line of a docstring that starts so counts too.
fn isMarkerLine(line: []const u8) bool {
    var i = skipSpace(line, 0);
    if (i >= line.len or line[i] != '#') return false;
    i = skipSpace(line, i + 1);
    return std.mem.startsWith(u8, line[i..], "FFI-BOUNDARY:");
}

fn skipSpace(s: []const u8, from: usize) usize {
    var i = from;
    while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
    return i;
}

/// The lines of a text: split at `\n`, no empty last line after a final `\n`.
const Lines = struct {
    text: []const u8,
    pos: usize = 0,

    fn next(self: *Lines) ?[]const u8 {
        if (self.pos >= self.text.len) return null;
        const e = std.mem.indexOfScalarPos(u8, self.text, self.pos, '\n') orelse self.text.len;
        const l = self.text[self.pos..e];
        self.pos = e + 1;
        return l;
    }
};

const Reader = struct {
    a: Allocator,
    sites: std.ArrayList(Site),
    libfile: bool,
    /// Inside a module-level struct or trait, and whether its name is private.
    container: bool = false,
    cpriv: bool = false,
    /// The names bound to a field's address in this function, and where.
    bound: std.StringHashMap(usize),
    /// The name the current statement bound.
    fresh: []const u8 = "",
    /// The statement being joined: code, code with string literals kept,
    /// first line, indentation and open brackets.
    pending: bool = false,
    buf: std.ArrayList(u8),
    rbuf: std.ArrayList(u8),
    pline: usize = 0,
    pind: usize = 0,
    dep: i64 = 0,

    fn line(self: *Reader, ln: usize, code: []const u8, lit: []const u8) !void {
        if (self.pending) {
            try self.buf.append(self.a, ' ');
            try self.buf.appendSlice(self.a, code);
            try self.rbuf.append(self.a, ' ');
            try self.rbuf.appendSlice(self.a, lit);
            self.dep += tok.depth(code);
            if (self.dep <= 0) try self.flush();
            return;
        }
        if (allBlank(code)) return;
        self.pending = true;
        self.buf.clearRetainingCapacity();
        self.rbuf.clearRetainingCapacity();
        try self.buf.appendSlice(self.a, code);
        try self.rbuf.appendSlice(self.a, lit);
        self.pline = ln;
        self.dep = tok.depth(code);
        self.pind = skipBlank(code, 0);
        if (self.dep <= 0) try self.flush();
    }

    fn flush(self: *Reader) !void {
        if (self.pending) try self.statement(self.buf.items, self.rbuf.items, self.pline, self.pind);
        self.pending = false;
    }

    fn emit(self: *Reader, rule: Rule, ln: usize, text: []const u8, suffix: []const u8) !void {
        var out = std.ArrayList(u8).empty;
        var blank = false;
        for ([_][]const u8{ text, suffix }) |part| for (part) |c| {
            if (isBlank(c)) {
                blank = true;
                continue;
            }
            if (blank and out.items.len > 0) try out.append(self.a, ' ');
            blank = false;
            try out.append(self.a, c);
        };
        if (blank and out.items.len > 0) try out.append(self.a, ' ');
        const t = out.items[0..@min(out.items.len, 160)];
        try self.sites.append(self.a, .{ .rule = rule, .line = ln, .text = t });
    }

    fn emitN(self: *Reader, n: usize, rule: Rule, ln: usize, text: []const u8) !void {
        var k: usize = 0;
        while (k < n) : (k += 1) try self.emit(rule, ln, text, "");
    }

    fn statement(self: *Reader, s: []const u8, raw: []const u8, ln: usize, ind: usize) !void {
        self.fresh = "";
        if (ind == 0 and !(s.len > 0 and s[0] == '@')) {
            // A module-level line: decides what the indented lines below belong to.
            self.container = false;
            self.cpriv = false;
            self.bound.clearRetainingCapacity();
            if (startsKeyword(s, "struct") or startsKeyword(s, "trait")) {
                self.container = true;
                const kw: usize = if (s[0] == 's') "struct".len else "trait".len;
                const nm = s[skipBlank(s, kw)..];
                self.cpriv = nm.len > 0 and nm[0] == '_';
            }
        }
        if (defName(s)) |nm| {
            // A new function: the two-statement form is read within one.
            self.bound.clearRetainingCapacity();
            if (self.libfile and (ind == 0 or (ind == 4 and self.container and !self.cpriv))) {
                const public = isDunder(nm) or !(nm.len > 0 and nm[0] == '_');
                if (public and countBounded(s, &ptr_names, .word_end) > 0) try self.emit(.public_pointer, ln, s, "");
            }
        }
        try self.emitN(countBounded(s, &wild_names, .word_end), .wildcard_origin, ln, s);
        try self.emitN(countFromAddress(s), .from_address, ln, s);
        try self.emitN(countBounded(s, &[_][]const u8{"parallelize"}, .bracket), .parallelize, ln, s);
        if (namesExternalCall(s)) try self.emitN(countLibc(raw), .libc_redeclare, ln, raw);
        // The two-statement form: a take through a name bound to a field's address.
        var it = self.bound.iterator();
        while (it.next()) |e| {
            if (!takesThrough(s, e.key_ptr.*)) continue;
            const suffix = try std.fmt.allocPrint(self.a, " (bound to a field's address at line {d})", .{e.value_ptr.*});
            try self.emit(.partial_move, ln, s, suffix);
        }
        try self.pointers(s, ln);
        // A name assigned anything else is no longer bound.
        if (isAssignment(s, .not_eq)) {
            const nm = assignedName(s);
            if (!std.mem.eql(u8, nm, self.fresh)) _ = self.bound.remove(nm);
        }
    }

    /// Each `UnsafePointer(to=<expr>.<field>)` in `s`: a site when
    /// `.take_pointee(` follows it; else, when it is the whole right-hand
    /// side of `[var] <name> = ...`, `name` is bound to a field's address.
    fn pointers(self: *Reader, s: []const u8, ln: usize) !void {
        var off: usize = 0;
        while (findPointer(s, off)) |m| {
            var i = m.bracket;
            if (s[i] == '[') {
                const j = tok.closing(s, i) orelse return;
                i = skipBlank(s, j + 1);
                if (i >= s.len or s[i] != '(') {
                    off = i;
                    continue;
                }
            }
            const j = tok.closing(s, i) orelse return;
            const arg = s[i + 1 .. j];
            const after = s[j + 1 ..];
            if (isFieldAddress(arg)) {
                if (startsTake(after)) {
                    try self.emit(.partial_move, ln, s, "");
                } else if (allBlank(after)) {
                    const lhs = s[0 .. m.start + 1];
                    if (isAssignment(lhs, .rest_blank)) {
                        const nm = try self.a.dupe(u8, assignedName(lhs));
                        try self.bound.put(nm, ln);
                        self.fresh = nm;
                    }
                }
            }
            off = j + 1;
        }
    }
};

const PointerMatch = struct { start: usize, bracket: usize };

/// The leftmost `(^|[^A-Za-z0-9_])UnsafePointer[ \t]*[[(]` in `s` from
/// `off`, where `^` matches at `off`.
fn findPointer(s: []const u8, off: usize) ?PointerMatch {
    var m = off;
    while (m < s.len) : (m += 1) {
        var e: ?usize = null;
        if (m == off and startsWithAt(s, m, "UnsafePointer")) {
            e = m + "UnsafePointer".len;
        } else if (!isWord(s[m]) and startsWithAt(s, m + 1, "UnsafePointer")) {
            e = m + 1 + "UnsafePointer".len;
        }
        if (e) |end| {
            const j = skipBlank(s, end);
            if (j < s.len and (s[j] == '[' or s[j] == '(')) return .{ .start = m, .bracket = j };
        }
    }
    return null;
}

pub const Input = struct {
    files: []const File,
    /// The public root, without its `/`.
    public_root: []const u8,
    ffi: []const u8,
    ffi_name: []const u8,
    holds: []const u8,
    holds_name: []const u8,
    /// What a finding names a file of the tree by: this, then its path.
    site_prefix: []const u8,
};

fn isSpaceOnly(s: []const u8) bool {
    return skipSpace(s, 0) == s.len;
}

/// A ledger line that is a comment: `^[[:space:]]*(#|$)`.
fn isCommentRow(s: []const u8) bool {
    const i = skipSpace(s, 0);
    return i == s.len or s[i] == '#';
}

fn isCount(s: []const u8) bool {
    if (s.len == 0 or s[0] < '1' or s[0] > '9') return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

const Held = struct { count: []const u8, n: u64, row: usize, file: []const u8, rule: Rule };

/// The findings over the files, sorted bytewise.
pub fn check(a: Allocator, input: Input) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var known = std.StringHashMap(void).init(a);
    var marked = std.StringHashMap(void).init(a);
    const root = try std.mem.concat(a, u8, &.{ input.public_root, "/" });
    var results = std.ArrayList(FileResult).empty;
    for (input.files) |f| {
        try known.put(f.path, {});
        const res = try readFile(a, f.path, f.contents, root);
        if (res.marked) try marked.put(f.path, {});
        try results.append(a, res);
    }

    // The FFI modules: path -> row.
    var ffi = std.StringArrayHashMap(usize).init(a);
    var rows = Lines{ .text = input.ffi };
    var fnr: usize = 0;
    while (rows.next()) |row| {
        fnr += 1;
        if (isCommentRow(row)) continue;
        const where = try std.fmt.allocPrint(a, "{s}:{d}: ", .{ input.ffi_name, fnr });
        const nf = std.mem.count(u8, row, "\t") + 1;
        if (nf != 2) {
            try out.append(a, try std.fmt.allocPrint(a, "{s}a row has 2 tab-separated fields (file, reason), not {d}", .{ where, nf }));
            continue;
        }
        var fields = std.mem.splitScalar(u8, row, '\t');
        const file = fields.next().?;
        const reason = fields.next().?;
        if (!known.contains(file)) {
            try out.append(a, try std.fmt.allocPrint(a, "{s}{s} is not a .mojo file of the tree; delete the row", .{ where, file }));
        } else if (isSpaceOnly(reason)) {
            try out.append(a, try std.fmt.allocPrint(a, "{s}empty reason: say which foreign resource the module owns", .{where}));
        } else if (ffi.contains(file)) {
            try out.append(a, try std.fmt.allocPrint(a, "{s}a second row for {s}", .{ where, file }));
        } else if (!marked.contains(file)) {
            try out.append(a, try std.fmt.allocPrint(a, "{s}{s} carries no `# FFI-BOUNDARY:` comment line, so it is not an FFI module", .{ where, file }));
        } else try ffi.put(file, fnr);
    }

    // The holds: "<rule>\t<file>" -> row.
    var held = std.StringArrayHashMap(Held).init(a);
    rows = Lines{ .text = input.holds };
    fnr = 0;
    while (rows.next()) |row| {
        fnr += 1;
        if (isCommentRow(row)) continue;
        const where = try std.fmt.allocPrint(a, "{s}:{d}: ", .{ input.holds_name, fnr });
        const nf = std.mem.count(u8, row, "\t") + 1;
        if (nf != 4) {
            try out.append(a, try std.fmt.allocPrint(a, "{s}a row has 4 tab-separated fields (rule, file, count, reason), not {d}", .{ where, nf }));
            continue;
        }
        var fields = std.mem.splitScalar(u8, row, '\t');
        const rule_name = fields.next().?;
        const file = fields.next().?;
        const count = fields.next().?;
        const reason = fields.next().?;
        const rule = std.meta.stringToEnum(Rule, rule_name) orelse {
            try out.append(a, try std.fmt.allocPrint(a, "{s}unknown rule `{s}` (rules: {s})", .{ where, rule_name, rule_list }));
            continue;
        };
        const key = try std.fmt.allocPrint(a, "{s}\t{s}", .{ rule_name, file });
        if (!known.contains(file)) {
            try out.append(a, try std.fmt.allocPrint(a, "{s}{s} is not a .mojo file of the tree; delete the row", .{ where, file }));
        } else if (!isCount(count)) {
            try out.append(a, try std.fmt.allocPrint(a, "{s}count `{s}` is not a positive whole number", .{ where, count }));
        } else if (isSpaceOnly(reason)) {
            try out.append(a, try std.fmt.allocPrint(a, "{s}empty reason: say why this file still holds the sites", .{where}));
        } else if (held.contains(key)) {
            try out.append(a, try std.fmt.allocPrint(a, "{s}a second row for {s} in {s}", .{ where, rule_name, file }));
        } else {
            const n = std.fmt.parseInt(u64, count, 10) catch std.math.maxInt(u64);
            try held.put(key, .{ .count = count, .n = n, .row = fnr, .file = file, .rule = rule });
        }
    }

    // The sites, per rule and file; an FFI module's wildcard origins apart.
    var fsites = std.StringHashMap(void).init(a);
    var sites = std.StringArrayHashMap(std.ArrayList([]const u8)).init(a);
    for (input.files, results.items) |f, res| {
        for (res.sites) |s| {
            if (s.rule == .wildcard_origin and ffi.contains(f.path)) {
                try fsites.put(f.path, {});
                continue;
            }
            const key = try std.fmt.allocPrint(a, "{s}\t{s}", .{ @tagName(s.rule), f.path });
            const gop = try sites.getOrPut(key);
            if (!gop.found_existing) gop.value_ptr.* = std.ArrayList([]const u8).empty;
            try gop.value_ptr.append(a, try std.fmt.allocPrint(a, "{s}{s}:{d}: {s}: {s} -- {s}", .{ input.site_prefix, f.path, s.line, @tagName(s.rule), s.text, s.rule.describe() }));
        }
    }
    var sit = sites.iterator();
    while (sit.next()) |e| {
        const list = e.value_ptr.items;
        const h: ?Held = held.get(e.key_ptr.*);
        if (h != null and list.len <= h.?.n) continue;
        for (list) |l| {
            if (h) |hh| {
                try out.append(a, try std.fmt.allocPrint(a, "{s} ({d} sites, held {s})", .{ l, list.len, hh.count }));
            } else try out.append(a, l);
        }
    }
    var hit = held.iterator();
    while (hit.next()) |e| {
        const c: usize = if (sites.get(e.key_ptr.*)) |l| l.items.len else 0;
        const h = e.value_ptr.*;
        if (c >= h.n) continue;
        if (c > 0) {
            try out.append(a, try std.fmt.allocPrint(a, "{s}:{d}: {s} in {s} is held at {s} and has {d}: lower the count to {d}", .{ input.holds_name, h.row, @tagName(h.rule), h.file, h.count, c, c }));
        } else {
            try out.append(a, try std.fmt.allocPrint(a, "{s}:{d}: {s} in {s} is held at {s} and has 0: delete the row", .{ input.holds_name, h.row, @tagName(h.rule), h.file, h.count }));
        }
    }
    var fit = ffi.iterator();
    while (fit.next()) |e| {
        if (!fsites.contains(e.key_ptr.*)) {
            try out.append(a, try std.fmt.allocPrint(a, "{s}:{d}: {s} names no wildcard origin; delete the row", .{ input.ffi_name, e.value_ptr.*, e.key_ptr.* }));
        }
    }
    std.mem.sort([]const u8, out.items, {}, lessThan);
    return out.items;
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

/// The report: the findings with `stage` (a site prefix) named `prefix`,
/// then, when no file was read, a line saying so.
pub fn report(a: Allocator, findings: []const []const u8, stage: []const u8, prefix: []const u8, checked: usize) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (findings) |f| {
        try out.append(a, if (stage.len > 0) try std.mem.replaceOwned(u8, a, f, stage, prefix) else f);
    }
    if (checked == 0) try out.append(a, "pointer_lint: checked nothing (no inputs, or no lines to check)");
    return out.items;
}

/// The validation result Buck2 reads, for a report of `lines` over
/// `checked` files: at most 200 lines in its message.
pub fn resultJson(a: Allocator, lines: []const []const u8, checked: usize) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    const w = out.writer(a);
    if (lines.len == 0) {
        try w.print("{{\"version\": 1, \"data\": {{\"status\": \"success\", \"message\": \"pointer_lint: {d} checked\"}}}}\n", .{checked});
        return out.items;
    }
    try w.print("{{\"version\": 1, \"data\": {{\"status\": \"failure\", \"message\": \"pointer_lint: {d} finding line(s)\\n", .{lines.len});
    for (lines[0..@min(lines.len, 200)]) |l| {
        for (l) |c| switch (c) {
            '\\' => try w.writeAll("\\\\"),
            '"' => try w.writeAll("\\\""),
            '\t' => try w.writeAll("\\t"),
            0...8, 11...31 => {},
            else => try w.writeByte(c),
        };
        try w.writeAll("\\n");
    }
    try w.writeAll("\"}}\n");
    return out.items;
}

const usage = "usage: pointer_lint <result.json> <stage> <prefix> <public root> <ffi> <ffi name> <holds> <holds name>\n";

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len != 9) {
        std.fs.File.stderr().writeAll(usage) catch {};
        std.process.exit(2);
    }
    const stage = argv[2];
    var files = std.ArrayList(File).empty;
    var dir = try std.fs.cwd().openDir(stage, .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(a);
    while (try walker.next()) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".mojo")) continue;
        const path = try a.dupe(u8, entry.path);
        try files.append(a, .{ .path = path, .contents = try dir.readFileAlloc(a, path, 1 << 30) });
    }
    const max = 1 << 30;
    const input = Input{
        .files = files.items,
        .public_root = argv[4],
        .ffi = try std.fs.cwd().readFileAlloc(a, argv[5], max),
        .ffi_name = argv[6],
        .holds = try std.fs.cwd().readFileAlloc(a, argv[7], max),
        .holds_name = argv[8],
        .site_prefix = try std.mem.concat(a, u8, &.{ stage, "/" }),
    };
    const lines = try report(a, try check(a, input), input.site_prefix, argv[3], files.items.len);
    const json = try resultJson(a, lines, files.items.len);
    try std.fs.cwd().writeFile(.{ .sub_path = argv[1], .data = json });
}
