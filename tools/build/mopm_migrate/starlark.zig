//! The part of Starlark a komira BUCK file uses, read as data: `load(...)` and rule calls at the
//! top level, whose arguments are strings, integers, `True`/`False`/`None`, lists, dicts and
//! `glob(...)` calls. Every node keeps its byte span in the source, so a caller can write a value
//! back exactly as it was written.
//!
//! What it refuses, with the line, rather than guess at: a variable (an assignment, or a name used
//! as a value), a comprehension, an operator between values (`+`, `%`, `if`, ...), `def`, a
//! triple-quoted or raw string, an escape other than `\\ \" \' \n \t`, and anything after a call on
//! its line but a comment. A refusal tells the migration to stop: a file this reads differently
//! from Buck2 would be migrated wrongly.
const std = @import("std");

const Allocator = std.mem.Allocator;

/// `why` holds the refusal text when `error.Refused` is returned.
pub const Error = error{ Refused, OutOfMemory };

pub const Ctx = struct {
    a: Allocator,
    why: []const u8 = "",

    pub fn refuse(self: *Ctx, comptime fmt: []const u8, args: anytype) Error {
        self.why = try std.fmt.allocPrint(self.a, fmt, args);
        return error.Refused;
    }
};

pub const Value = struct {
    start: usize,
    end: usize,
    kind: Kind,

    pub const Kind = union(enum) {
        str: []const u8,
        int: i64,
        boolean: bool,
        none,
        list: []Value,
        dict: []Pair,
        call: Call,
    };

    /// The value as written in `src`.
    pub fn text(self: Value, src: []const u8) []const u8 {
        return src[self.start..self.end];
    }
};

pub const Pair = struct { key: Value, value: Value };

pub const Arg = struct { name: ?[]const u8, value: Value };

pub const Call = struct {
    func: []const u8,
    args: []Arg,

    /// The keyword argument `name`, or null.
    pub fn kwarg(self: Call, name: []const u8) ?Value {
        for (self.args) |arg| {
            if (arg.name) |n| if (std.mem.eql(u8, n, name)) return arg.value;
        }
        return null;
    }
};

pub const Stmt = struct {
    call: Call,
    start: usize,
    end: usize,
    line: usize,
    /// The comment lines directly above the statement (no blank line between), as written, without
    /// the final newline; empty when there are none.
    comment: []const u8,
};

pub fn lineOf(src: []const u8, pos: usize) usize {
    var n: usize = 1;
    for (src[0..@min(pos, src.len)]) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

const Parser = struct {
    c: *Ctx,
    src: []const u8,
    i: usize = 0,

    fn fail(self: *Parser, comptime fmt: []const u8, args: anytype) Error {
        const line = lineOf(self.src, self.i);
        const msg = try std.fmt.allocPrint(self.c.a, fmt, args);
        return self.c.refuse("BUCK line {d}: {s}", .{ line, msg });
    }

    fn peek(self: *Parser) u8 {
        return if (self.i < self.src.len) self.src[self.i] else 0;
    }

    /// Spaces, newlines and comments inside brackets.
    fn skipSpace(self: *Parser) void {
        while (self.i < self.src.len) {
            const ch = self.src[self.i];
            if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
                self.i += 1;
            } else if (ch == '#') {
                while (self.i < self.src.len and self.src[self.i] != '\n') self.i += 1;
            } else break;
        }
    }

    fn isIdentStart(ch: u8) bool {
        return std.ascii.isAlphabetic(ch) or ch == '_';
    }

    fn isIdentChar(ch: u8) bool {
        return std.ascii.isAlphanumeric(ch) or ch == '_';
    }

    fn ident(self: *Parser) []const u8 {
        const s = self.i;
        while (self.i < self.src.len and isIdentChar(self.src[self.i])) self.i += 1;
        return self.src[s..self.i];
    }

    fn string(self: *Parser) Error!Value {
        const start = self.i;
        const q = self.src[self.i];
        if (self.src.len >= self.i + 3 and self.src[self.i + 1] == q and self.src[self.i + 2] == q) {
            return self.fail("a triple-quoted string", .{});
        }
        self.i += 1;
        var out = std.ArrayList(u8).empty;
        while (true) {
            if (self.i >= self.src.len or self.src[self.i] == '\n') return self.fail("a string with no closing quote", .{});
            const ch = self.src[self.i];
            if (ch == q) break;
            if (ch == '\\') {
                self.i += 1;
                const e = self.peek();
                const decoded: u8 = switch (e) {
                    '\\', '"', '\'' => e,
                    'n' => '\n',
                    't' => '\t',
                    else => return self.fail("the escape \\{c} in a string", .{e}),
                };
                try out.append(self.c.a, decoded);
            } else {
                try out.append(self.c.a, ch);
            }
            self.i += 1;
        }
        self.i += 1;
        return .{ .start = start, .end = self.i, .kind = .{ .str = try out.toOwnedSlice(self.c.a) } };
    }

    /// After a value: only `,`, a closer or `:` may follow. A name or operator there is an
    /// expression this reader does not evaluate.
    fn afterValue(self: *Parser) Error!void {
        self.skipSpace();
        const ch = self.peek();
        switch (ch) {
            ',', ')', ']', '}', ':', '=' => {},
            '+', '%', '*', '-', '|', '&', '/', '<', '>', '!', '.', '~', '^' => return self.fail("an operator '{c}' between values", .{ch}),
            else => if (isIdentStart(ch)) {
                const save = self.i;
                const word = self.ident();
                self.i = save;
                if (std.mem.eql(u8, word, "for")) return self.fail("a comprehension", .{});
                return self.fail("an expression operator '{s}'", .{word});
            } else return self.fail("unexpected '{c}'", .{ch}),
        }
    }

    fn value(self: *Parser) Error!Value {
        self.skipSpace();
        const start = self.i;
        const ch = self.peek();
        if (ch == '"' or ch == '\'') {
            const v = try self.string();
            try self.afterValue();
            return v;
        }
        if (std.ascii.isDigit(ch) or (ch == '-' and self.i + 1 < self.src.len and std.ascii.isDigit(self.src[self.i + 1]))) {
            self.i += 1;
            while (std.ascii.isDigit(self.peek())) self.i += 1;
            const n = std.fmt.parseInt(i64, self.src[start..self.i], 10) catch return self.fail("an integer out of range", .{});
            try self.afterValue();
            return .{ .start = start, .end = self.i, .kind = .{ .int = n } };
        }
        if (ch == '[') {
            self.i += 1;
            var items = std.ArrayList(Value).empty;
            while (true) {
                self.skipSpace();
                if (self.peek() == ']') break;
                try items.append(self.c.a, try self.value());
                self.skipSpace();
                if (self.peek() == ',') {
                    self.i += 1;
                } else if (self.peek() != ']') return self.fail("expected ',' or ']' in a list", .{});
            }
            self.i += 1;
            const end = self.i;
            try self.afterValue();
            return .{ .start = start, .end = end, .kind = .{ .list = try items.toOwnedSlice(self.c.a) } };
        }
        if (ch == '{') {
            self.i += 1;
            var pairs = std.ArrayList(Pair).empty;
            while (true) {
                self.skipSpace();
                if (self.peek() == '}') break;
                const k = try self.value();
                self.skipSpace();
                if (self.peek() != ':') return self.fail("expected ':' in a dict", .{});
                self.i += 1;
                const v = try self.value();
                try pairs.append(self.c.a, .{ .key = k, .value = v });
                self.skipSpace();
                if (self.peek() == ',') {
                    self.i += 1;
                } else if (self.peek() != '}') return self.fail("expected ',' or '}}' in a dict", .{});
            }
            self.i += 1;
            const end = self.i;
            try self.afterValue();
            return .{ .start = start, .end = end, .kind = .{ .dict = try pairs.toOwnedSlice(self.c.a) } };
        }
        if (isIdentStart(ch)) {
            const word = self.ident();
            if (std.mem.eql(u8, word, "True") or std.mem.eql(u8, word, "False")) {
                try self.afterValue();
                return .{ .start = start, .end = self.i, .kind = .{ .boolean = word[0] == 'T' } };
            }
            if (std.mem.eql(u8, word, "None")) {
                try self.afterValue();
                return .{ .start = start, .end = self.i, .kind = .none };
            }
            self.skipSpace();
            if (self.peek() == '(') {
                const call = try self.callArgs(word);
                const end = self.i;
                try self.afterValue();
                return .{ .start = start, .end = end, .kind = .{ .call = call } };
            }
            if (isIdentStart(self.peek()) and std.mem.eql(u8, self.ident(), "for")) return self.fail("a comprehension", .{});
            self.i = start;
            return self.fail("the variable '{s}' used as a value", .{word});
        }
        return self.fail("unexpected '{c}'", .{ch});
    }

    /// At '(' after the function name; leaves the position after ')'.
    fn callArgs(self: *Parser, func: []const u8) Error!Call {
        self.i += 1;
        var args = std.ArrayList(Arg).empty;
        while (true) {
            self.skipSpace();
            if (self.peek() == ')') break;
            var name: ?[]const u8 = null;
            if (isIdentStart(self.peek())) {
                const save = self.i;
                const word = self.ident();
                self.skipSpace();
                if (self.peek() == '=' and (self.i + 1 >= self.src.len or self.src[self.i + 1] != '=')) {
                    self.i += 1;
                    name = word;
                } else self.i = save;
            }
            try args.append(self.c.a, .{ .name = name, .value = try self.value() });
            self.skipSpace();
            if (self.peek() == ',') {
                self.i += 1;
            } else if (self.peek() != ')') return self.fail("expected ',' or ')' in the arguments of {s}", .{func});
        }
        self.i += 1;
        return .{ .func = func, .args = try args.toOwnedSlice(self.c.a) };
    }
};

/// The top-level statements of a BUCK file, each a call.
pub fn parse(c: *Ctx, src: []const u8) Error![]Stmt {
    var p = Parser{ .c = c, .src = src };
    var stmts = std.ArrayList(Stmt).empty;
    var block: ?usize = null;
    while (p.i < src.len) {
        const ls = p.i;
        var j = ls;
        while (j < src.len and (src[j] == ' ' or src[j] == '\t' or src[j] == '\r')) j += 1;
        if (j >= src.len) break;
        if (src[j] == '\n') {
            block = null;
            p.i = j + 1;
            continue;
        }
        if (src[j] == '#') {
            if (block == null) block = ls;
            while (p.i < src.len and src[p.i] != '\n') p.i += 1;
            if (p.i < src.len) p.i += 1;
            continue;
        }
        if (j != ls) return p.fail("an indented line outside a call", .{});
        if (!Parser.isIdentStart(src[p.i])) return p.fail("unexpected '{c}' at the start of a statement", .{src[p.i]});
        const start = p.i;
        const word = p.ident();
        for ([_][]const u8{ "def", "for", "if", "else", "elif", "return", "pass" }) |kw| {
            if (std.mem.eql(u8, word, kw)) {
                p.i = start;
                return p.fail("the statement '{s}'", .{kw});
            }
        }
        while (p.peek() == ' ') p.i += 1;
        if (p.peek() != '(') {
            p.i = start;
            return p.fail("'{s}' is not a call: an assignment or a variable", .{word});
        }
        const call = try p.callArgs(word);
        const end = p.i;
        while (p.peek() == ' ') p.i += 1;
        if (p.peek() == '#') {
            while (p.i < src.len and src[p.i] != '\n') p.i += 1;
        }
        if (p.i < src.len and p.peek() != '\n' and p.peek() != '\r') return p.fail("text after the call to {s}", .{word});
        const comment = if (block) |b| std.mem.trimRight(u8, src[b..start], "\n") else "";
        try stmts.append(c.a, .{ .call = call, .start = start, .end = end, .line = lineOf(src, start), .comment = comment });
        block = null;
    }
    return stmts.toOwnedSlice(c.a);
}
