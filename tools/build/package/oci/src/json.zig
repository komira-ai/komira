//! A JSON reader and writer, enough for an OCI image layout (index,
//! manifest, config).
//!
//! RFC 8259 values; a key given twice in one object is refused, so a
//! document cannot say two things about one field. Numbers are kept as text
//! and written back as read. The writer is compact, with every object's keys
//! in sorted order, so a value has one spelling.

const std = @import("std");
const C = @import("common.zig");
const Fail = C.Fail;

pub const Member = struct { k: []const u8, v: Value };

pub const Value = union(enum) {
    nul,
    boolean: bool,
    num: []const u8,
    str: []const u8,
    arr: []Value,
    obj: []Member,

    /// The member `key` of an object; null for a missing key or a non-object.
    pub fn get(self: Value, key: []const u8) ?Value {
        switch (self) {
            .obj => |m| {
                for (m) |e| {
                    if (C.eql(e.k, key)) return e.v;
                }
                return null;
            },
            else => return null,
        }
    }

    pub fn asStr(self: Value) ?[]const u8 {
        return switch (self) {
            .str => |s| s,
            else => null,
        };
    }

    pub fn asArr(self: Value) ?[]Value {
        return switch (self) {
            .arr => |x| x,
            else => null,
        };
    }

    /// Sets the member `key` of an object, replacing one already there.
    pub fn set(self: *Value, key: []const u8, v: Value) Fail!void {
        switch (self.*) {
            .obj => |m| {
                for (m) |*e| {
                    if (C.eql(e.k, key)) {
                        e.v = v;
                        return;
                    }
                }
                const n = C.a().alloc(Member, m.len + 1) catch C.oom();
                @memcpy(n[0..m.len], m);
                n[m.len] = .{ .k = key, .v = v };
                self.* = .{ .obj = n };
            },
            else => return C.fail("cannot set `{s}`: not an object", .{key}),
        }
    }

    /// Removes the member `key` of an object, if there.
    pub fn remove(self: *Value, key: []const u8) void {
        switch (self.*) {
            .obj => |m| {
                var kept = C.list(Member);
                for (m) |e| {
                    if (!C.eql(e.k, key)) C.push(Member, &kept, e);
                }
                self.* = .{ .obj = kept.items };
            },
            else => {},
        }
    }

    /// A copy sharing nothing with `self`.
    pub fn clone(self: Value) Value {
        return switch (self) {
            .arr => |x| blk: {
                const n = C.a().alloc(Value, x.len) catch C.oom();
                for (x, 0..) |v, i| n[i] = v.clone();
                break :blk .{ .arr = n };
            },
            .obj => |m| blk: {
                const n = C.a().alloc(Member, m.len) catch C.oom();
                for (m, 0..) |e, i| n[i] = .{ .k = e.k, .v = e.v.clone() };
                break :blk .{ .obj = n };
            },
            else => self,
        };
    }

    /// Whether `self` and `o` are the same value, members in the same order.
    pub fn eql(self: Value, o: Value) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(o)) return false;
        return switch (self) {
            .nul => true,
            .boolean => |b| b == o.boolean,
            .num => |n| C.eql(n, o.num),
            .str => |s| C.eql(s, o.str),
            .arr => |x| x.len == o.arr.len and for (x, o.arr) |p, q| {
                if (!p.eql(q)) break false;
            } else true,
            .obj => |m| m.len == o.obj.len and for (m, o.obj) |p, q| {
                if (!C.eql(p.k, q.k) or !p.v.eql(q.v)) break false;
            } else true,
        };
    }

    /// Compact JSON, every object's keys in sorted order.
    pub fn toJson(self: Value) []u8 {
        var out = C.list(u8);
        self.write(&out);
        return out.items;
    }

    fn write(self: Value, out: *C.List(u8)) void {
        switch (self) {
            .nul => C.add(out, "null"),
            .boolean => |b| C.add(out, if (b) "true" else "false"),
            .num => |n| C.add(out, n),
            .str => |s| quote(s, out),
            .arr => |x| {
                C.add(out, "[");
                for (x, 0..) |v, i| {
                    if (i > 0) C.add(out, ",");
                    v.write(out);
                }
                C.add(out, "]");
            },
            .obj => |m| {
                const members = C.a().dupe(Member, m) catch C.oom();
                std.mem.sort(Member, members, {}, keyLess);
                C.add(out, "{");
                for (members, 0..) |e, i| {
                    if (i > 0) C.add(out, ",");
                    quote(e.k, out);
                    C.add(out, ":");
                    e.v.write(out);
                }
                C.add(out, "}");
            },
        }
    }
};

fn keyLess(_: void, x: Member, y: Member) bool {
    return std.mem.lessThan(u8, x.k, y.k);
}

/// `s` as a JSON string: `"` and `\` escaped, control characters as their
/// short escape or a four-digit one, everything else as is (UTF-8).
fn quote(s: []const u8, out: *C.List(u8)) void {
    C.add(out, "\"");
    for (s) |c| {
        switch (c) {
            '"' => C.add(out, "\\\""),
            '\\' => C.add(out, "\\\\"),
            '\n' => C.add(out, "\\n"),
            '\r' => C.add(out, "\\r"),
            '\t' => C.add(out, "\\t"),
            0x08 => C.add(out, "\\b"),
            0x0c => C.add(out, "\\f"),
            else => {
                if (c < 0x20) {
                    C.add(out, C.fmt("\\u{x:0>4}", .{c}));
                } else {
                    C.push(u8, out, c);
                }
            },
        }
    }
    C.add(out, "\"");
}

const MAX_DEPTH: usize = 64;

pub fn parse(text: []const u8) Fail!Value {
    var p = Parser{ .s = text };
    p.ws();
    const v = try p.value();
    p.ws();
    if (p.i != p.s.len) return p.err("bytes after the value");
    return v;
}

const Parser = struct {
    s: []const u8,
    i: usize = 0,
    depth: usize = 0,

    fn err(self: *Parser, what: []const u8) Fail {
        return C.fail("JSON: {s} at byte {d}", .{ what, self.i });
    }

    fn peek(self: *Parser) ?u8 {
        return if (self.i < self.s.len) self.s[self.i] else null;
    }

    /// Whether the next byte is `c`.
    fn is(self: *Parser, c: u8) bool {
        return self.i < self.s.len and self.s[self.i] == c;
    }

    fn ws(self: *Parser) void {
        while (self.peek()) |c| {
            if (c != ' ' and c != '\t' and c != '\n' and c != '\r') break;
            self.i += 1;
        }
    }

    fn eat(self: *Parser, c: u8) Fail!void {
        if (self.is(c)) {
            self.i += 1;
        } else {
            return self.err(C.fmt("expected `{c}`", .{c}));
        }
    }

    fn word(self: *Parser, w: []const u8, v: Value) Fail!Value {
        if (C.startsWith(self.s[self.i..], w)) {
            self.i += w.len;
            return v;
        }
        return self.err("not a JSON literal");
    }

    fn value(self: *Parser) Fail!Value {
        const c = self.peek() orelse return self.err("expected a value");
        return switch (c) {
            '{' => self.object(),
            '[' => self.array(),
            '"' => .{ .str = try self.string() },
            't' => self.word("true", .{ .boolean = true }),
            'f' => self.word("false", .{ .boolean = false }),
            'n' => self.word("null", .nul),
            '-', '0'...'9' => self.number(),
            else => self.err("expected a value"),
        };
    }

    fn enter(self: *Parser, open: u8) Fail!void {
        self.depth += 1;
        if (self.depth > MAX_DEPTH) return self.err("nested too deep");
        try self.eat(open);
        self.ws();
    }

    /// After a member or element: true at the closing `close`, false after a `,`.
    fn next(self: *Parser, close: u8) Fail!bool {
        self.ws();
        if (self.is(',')) {
            self.i += 1;
            self.ws();
            return false;
        }
        if (self.is(close)) {
            self.i += 1;
            self.depth -= 1;
            return true;
        }
        return self.err(C.fmt("expected `,` or `{c}`", .{close}));
    }

    fn object(self: *Parser) Fail!Value {
        try self.enter('{');
        var m = C.list(Member);
        if (self.is('}')) {
            self.i += 1;
            self.depth -= 1;
            return .{ .obj = m.items };
        }
        while (true) {
            if (!self.is('"')) return self.err("expected a key");
            const k = try self.string();
            for (m.items) |e| {
                if (C.eql(e.k, k)) return self.err(C.fmt("key `{s}` given twice", .{k}));
            }
            self.ws();
            try self.eat(':');
            self.ws();
            const v = try self.value();
            C.push(Member, &m, .{ .k = k, .v = v });
            if (try self.next('}')) return .{ .obj = m.items };
        }
    }

    fn array(self: *Parser) Fail!Value {
        try self.enter('[');
        var x = C.list(Value);
        if (self.is(']')) {
            self.i += 1;
            self.depth -= 1;
            return .{ .arr = x.items };
        }
        while (true) {
            C.push(Value, &x, try self.value());
            if (try self.next(']')) return .{ .arr = x.items };
        }
    }

    fn digits(self: *Parser) usize {
        const at = self.i;
        while (self.peek()) |c| {
            if (c < '0' or c > '9') break;
            self.i += 1;
        }
        return self.i - at;
    }

    fn number(self: *Parser) Fail!Value {
        const at = self.i;
        if (self.is('-')) self.i += 1;
        if (self.is('0')) {
            self.i += 1;
        } else if (self.digits() == 0) {
            return self.err("a number without digits");
        }
        if (self.is('.')) {
            self.i += 1;
            if (self.digits() == 0) return self.err("no digits after `.`");
        }
        if (self.is('e') or self.is('E')) {
            self.i += 1;
            if (self.is('+') or self.is('-')) self.i += 1;
            if (self.digits() == 0) return self.err("no digits in the exponent");
        }
        return .{ .num = C.dupe(self.s[at..self.i]) };
    }

    fn hex4(self: *Parser) Fail!u32 {
        if (self.s.len - self.i < 4) return self.err("a short \\u escape");
        // Four hex digits, nothing else: no sign, no other byte.
        var v: u32 = 0;
        for (self.s[self.i .. self.i + 4]) |b| {
            const d: u32 = switch (b) {
                '0'...'9' => b - '0',
                'a'...'f' => b - 'a' + 10,
                'A'...'F' => b - 'A' + 10,
                else => return self.err("a bad \\u escape"),
            };
            v = v * 16 + d;
        }
        self.i += 4;
        return v;
    }

    fn string(self: *Parser) Fail![]const u8 {
        try self.eat('"');
        var out = C.list(u8);
        while (true) {
            const c = self.peek() orelse return self.err("an unterminated string");
            self.i += 1;
            switch (c) {
                '"' => break,
                '\\' => {
                    const e = self.peek() orelse return self.err("an unterminated escape");
                    self.i += 1;
                    const ch: u32 = switch (e) {
                        '"' => '"',
                        '\\' => '\\',
                        '/' => '/',
                        'b' => 0x08,
                        'f' => 0x0c,
                        'n' => '\n',
                        'r' => '\r',
                        't' => '\t',
                        'u' => blk: {
                            const hi = try self.hex4();
                            if (hi >= 0xD800 and hi < 0xDC00) {
                                if (!C.startsWith(self.s[self.i..], "\\u")) return self.err("a lone high surrogate");
                                self.i += 2;
                                const lo = try self.hex4();
                                if (!(lo >= 0xDC00 and lo < 0xE000)) return self.err("a bad low surrogate");
                                break :blk 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00);
                            }
                            break :blk hi;
                        },
                        else => return self.err("an unknown escape"),
                    };
                    if (ch >= 0xD800 and ch < 0xE000) return self.err("a lone surrogate");
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(@intCast(ch), &buf) catch unreachable;
                    C.add(&out, buf[0..n]);
                },
                0...0x1f => return self.err("a control character in a string"),
                else => C.push(u8, &out, c),
            }
        }
        if (!C.utf8Valid(out.items)) return self.err("a string that is not UTF-8");
        return out.items;
    }
};
