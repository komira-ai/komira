//! A JSON reader for bench reports (RFC 8259): objects keep their keys in
//! the order written, and a key written twice is an error, as are NaN,
//! infinities, numbers out of the range of a double, trailing input and a
//! nesting deeper than 64. The input must be UTF-8 (cli.zig checks it).

const std = @import("std");
const C = @import("common.zig");
const Fail = C.Fail;

pub const Member = struct { k: []const u8, v: Value };

pub const Value = union(enum) {
    nul,
    boolean: bool,
    num: f64,
    str: []const u8,
    arr: []Value,
    obj: []Member,

    /// The kind of the value, as an error message names it.
    pub fn kind(self: Value) []const u8 {
        return switch (self) {
            .nul => "null",
            .boolean => "a boolean",
            .num => "a number",
            .str => "a string",
            .arr => "an array",
            .obj => "an object",
        };
    }
};

const max_depth = 64;

/// Parses one JSON document; the refusal names the byte offset.
pub fn parse(input: []const u8) Fail!Value {
    var p = Parser{ .s = input, .i = 0 };
    p.ws();
    const v = try p.value(0);
    p.ws();
    if (p.i != p.s.len) return p.err("trailing input after the value");
    return v;
}

const Parser = struct {
    s: []const u8,
    i: usize,

    fn err(self: *const Parser, what: []const u8) Fail {
        return C.fail("byte {d}: {s}", .{ self.i, what });
    }

    fn ws(self: *Parser) void {
        while (self.i < self.s.len) : (self.i += 1) {
            switch (self.s[self.i]) {
                ' ', '\t', '\n', '\r' => {},
                else => return,
            }
        }
    }

    fn peek(self: *const Parser) ?u8 {
        return if (self.i < self.s.len) self.s[self.i] else null;
    }

    fn lit(self: *Parser, word: []const u8, v: Value) Fail!Value {
        if (!std.mem.startsWith(u8, self.s[self.i..], word)) return self.err("not a JSON value");
        self.i += word.len;
        return v;
    }

    fn value(self: *Parser, depth: usize) Fail!Value {
        if (depth > max_depth) return self.err("nesting deeper than 64");
        const c = self.peek() orelse return self.err("unexpected end of input");
        return switch (c) {
            '{' => self.object(depth),
            '[' => self.array(depth),
            '"' => Value{ .str = try self.string() },
            't' => self.lit("true", Value{ .boolean = true }),
            'f' => self.lit("false", Value{ .boolean = false }),
            'n' => self.lit("null", .nul),
            '-', '0'...'9' => self.number(),
            else => self.err("not a JSON value"),
        };
    }

    fn object(self: *Parser, depth: usize) Fail!Value {
        self.i += 1;
        var out = C.list(Member);
        self.ws();
        if (self.peek() == '}') {
            self.i += 1;
            return Value{ .obj = out.items };
        }
        while (true) {
            self.ws();
            if (self.peek() != '"') return self.err("expected a key");
            const key = try self.string();
            for (out.items) |m| {
                if (C.eql(m.k, key)) return self.err(C.fmt("key '{s}' written twice", .{key}));
            }
            self.ws();
            if (self.peek() != ':') return self.err("expected ':'");
            self.i += 1;
            self.ws();
            const v = try self.value(depth + 1);
            C.push(Member, &out, .{ .k = key, .v = v });
            self.ws();
            if (self.peek() == ',') {
                self.i += 1;
            } else if (self.peek() == '}') {
                self.i += 1;
                return Value{ .obj = out.items };
            } else return self.err("expected ',' or '}'");
        }
    }

    fn array(self: *Parser, depth: usize) Fail!Value {
        self.i += 1;
        var out = C.list(Value);
        self.ws();
        if (self.peek() == ']') {
            self.i += 1;
            return Value{ .arr = out.items };
        }
        while (true) {
            self.ws();
            C.push(Value, &out, try self.value(depth + 1));
            self.ws();
            if (self.peek() == ',') {
                self.i += 1;
            } else if (self.peek() == ']') {
                self.i += 1;
                return Value{ .arr = out.items };
            } else return self.err("expected ',' or ']'");
        }
    }

    /// Four hex digits, and nothing else (no sign, no underscore).
    fn hex4(self: *Parser) Fail!u21 {
        if (self.s.len - self.i < 4) return self.err("short \\u escape");
        var v: u21 = 0;
        for (self.s[self.i .. self.i + 4]) |c| {
            const d: u21 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => return self.err("bad \\u escape"),
            };
            v = v * 16 + d;
        }
        self.i += 4;
        return v;
    }

    fn string(self: *Parser) Fail![]const u8 {
        self.i += 1;
        var out = C.list(u8);
        while (true) {
            const start = self.i;
            while (self.i < self.s.len) : (self.i += 1) {
                const c = self.s[self.i];
                if (c == '"' or c == '\\' or c < 0x20) break;
            }
            C.add(&out, self.s[start..self.i]);
            const c = self.peek() orelse return self.err("unterminated string");
            if (c == '"') {
                self.i += 1;
                return out.items;
            }
            if (c != '\\') return self.err("control character in a string");
            self.i += 1;
            const e = self.peek() orelse return self.err("unterminated string");
            self.i += 1;
            switch (e) {
                '"' => C.push(u8, &out, '"'),
                '\\' => C.push(u8, &out, '\\'),
                '/' => C.push(u8, &out, '/'),
                'b' => C.push(u8, &out, 8),
                'f' => C.push(u8, &out, 12),
                'n' => C.push(u8, &out, '\n'),
                'r' => C.push(u8, &out, '\r'),
                't' => C.push(u8, &out, '\t'),
                'u' => {
                    var cp = try self.hex4();
                    if (cp >= 0xd800 and cp < 0xdc00) {
                        if (!std.mem.startsWith(u8, self.s[self.i..], "\\u")) return self.err("unpaired surrogate");
                        self.i += 2;
                        const lo = try self.hex4();
                        if (lo < 0xdc00 or lo >= 0xe000) return self.err("unpaired surrogate");
                        cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
                    } else if (cp >= 0xdc00 and cp < 0xe000) {
                        return self.err("unpaired surrogate");
                    }
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &buf) catch return self.err("unpaired surrogate");
                    C.add(&out, buf[0..n]);
                },
                else => return self.err("bad escape"),
            }
        }
    }

    fn digits(self: *Parser) usize {
        const s = self.i;
        while (self.i < self.s.len and std.ascii.isDigit(self.s[self.i])) self.i += 1;
        return self.i - s;
    }

    fn number(self: *Parser) Fail!Value {
        const start = self.i;
        if (self.peek() == '-') self.i += 1;
        const int_start = self.i;
        if (self.digits() == 0) return self.err("expected a digit");
        if (self.s[int_start] == '0' and self.i - int_start > 1) return self.err("leading zero");
        if (self.peek() == '.') {
            self.i += 1;
            if (self.digits() == 0) return self.err("expected a digit after '.'");
        }
        if (self.peek() == 'e' or self.peek() == 'E') {
            self.i += 1;
            if (self.peek() == '+' or self.peek() == '-') self.i += 1;
            if (self.digits() == 0) return self.err("expected a digit in the exponent");
        }
        const v = std.fmt.parseFloat(f64, self.s[start..self.i]) catch return self.err("bad number");
        if (!std.math.isFinite(v)) return self.err("number out of range");
        return Value{ .num = v };
    }
};
