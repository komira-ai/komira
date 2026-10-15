// Why Zig: build tools are Zig (tools/build/README.md). This replaces
// proto_fixture.sh (a busybox shell script with awk, od, fold, diff, cmp, sed
// and grep) so that checking and writing protobuf wire fixtures runs no shell.
//! proto_fixture: protoc reading and writing wire fixtures, inside a build
//! action (proto_fixture.bzl says what a fixture is and what each leg can and
//! cannot see).
//!
//! usage: proto_fixture check  <busybox> <protoc dir> <report> <n> <proto path dir>...
//!            <m> <import path>... -- {<stem> <root> <hex> <txtpb> <canonical hex> <canonical producer>}...
//!        proto_fixture encode <busybox> <protoc dir> <out hex> <n> <proto path dir>...
//!            <m> <import path>... -- <root> <txtpb>
//!        proto_fixture case   <expect> <verdict> <busybox> <protoc dir> <report-less check arguments: as `check` after <report>>
//!
//! <protoc dir> holds bin/protoc and include/ (the well-known types and
//! google/protobuf/descriptor.proto). <canonical producer> is 1 when the
//! fixture's .hex may be byte-identical to its .canonical.hex, else 0. `check`
//! runs legs 0-5 over each fixture, reports every failure on stderr with its
//! leg, and writes <report> (one PASS line per fixture) only if all of them
//! passed. `encode` writes protoc --encode=<root> of <txtpb> as hex text:
//! lowercase, 64 digits a line. `case` runs `check` over planted fixtures and
//! asserts its verdict: with an empty <expect> the check must accept them, else
//! refuse with a message holding <expect>; <verdict> is `accepted` or `refused`
//! and then the report or the message.
//!
//! The environment of protoc: the busybox applets as PATH, a TMPDIR and HOME of
//! the action's own. Exit status: 0; 1 for a failed check; 2 for a usage error
//! or a failure of the tool's own.

const std = @import("std");

// ---- text helpers ---------------------------------------------------------------

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

/// The hex digits of `text`: white space removed, A-F lowercased.
pub fn hexdigits(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    for (text) |c| {
        if (isWs(c)) continue;
        try out.append(if (c >= 'A' and c <= 'F') c + 32 else c);
    }
    return out.toOwnedSlice();
}

pub const Unhex = union(enum) {
    bytes: []u8,
    /// Why the text is not hex.
    why: []const u8,
};

/// The bytes of a hex fixture, or why it is not one: a character that is not a
/// hex digit or white space, an odd number of digits, or no digits at all.
pub fn unhex(a: std.mem.Allocator, text: []const u8) !Unhex {
    const d = try hexdigits(a, text);
    if (d.len == 0) return .{ .why = "holds no bytes" };
    for (d) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return .{ .why = "holds a character that is neither a hex digit nor white space" };
    }
    if (d.len % 2 != 0) return .{ .why = try std.fmt.allocPrint(a, "holds an odd number of hex digits ({d})", .{d.len}) };
    const out = try a.alloc(u8, d.len / 2);
    for (out, 0..) |*b, i| b.* = try std.fmt.parseInt(u8, d[2 * i .. 2 * i + 2], 16);
    return .{ .bytes = out };
}

/// The hex format proto_encode writes: lowercase, 64 digits a line, each line
/// ending in a line break (an empty input is one line break).
pub fn tohex(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    const hex = "0123456789abcdef";
    var col: usize = 0;
    for (bytes) |b| {
        if (col == 64) {
            try out.append('\n');
            col = 0;
        }
        try out.append(hex[b >> 4]);
        try out.append(hex[b & 15]);
        col += 2;
    }
    try out.append('\n');
    return out.toOwnedSlice();
}

/// The root a .txtpb names on its first line (`# proto-message: <root>`, the root
/// non-empty with no space), or null.
pub fn txtpbRoot(text: []const u8) ?[]const u8 {
    const nl = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const first = text[0..nl];
    const p = "# proto-message: ";
    if (!std.mem.startsWith(u8, first, p)) return null;
    const root = first[p.len..];
    if (root.len == 0 or std.mem.indexOfScalar(u8, root, ' ') != null) return null;
    return root;
}

/// The first line of `text` with its line break, as `head -n 1`.
pub fn firstLine(text: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, text, '\n') orelse return text;
    return text[0 .. nl + 1];
}

/// `text` without its first line (`sed 1d`).
pub fn dropFirstLine(text: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, text, '\n') orelse return text[text.len..];
    return text[nl + 1 ..];
}

/// Each line of `text` behind eight spaces.
pub fn indent(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        if (it.peek() == null and l.len == 0) break;
        try out.appendSlice("        ");
        try out.appendSlice(l);
        try out.append('\n');
    }
    return out.toOwnedSlice();
}

/// The first `n` lines of `text`.
pub fn head(text: []const u8, n: usize) []const u8 {
    var pos: usize = 0;
    var seen: usize = 0;
    while (pos < text.len and seen < n) {
        pos = (std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse return text) + 1;
        seen += 1;
    }
    return text[0..pos];
}

fn countLines(text: []const u8) usize {
    return std.mem.count(u8, text, "\n");
}

// ---- the schema, from protoc's own descriptor set ------------------------------

pub const Field = struct {
    msg: []const u8,
    name: []const u8,
    num: []const u8,
    label: []const u8,
    typ: []const u8,
    type_name: []const u8,
};

pub const Schema = struct {
    messages: []const []const u8,
    fields: []const Field,
};

fn unquote(a: std.mem.Allocator, v: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    for (v) |c| {
        if (c != '"') try out.append(c);
    }
    return out.toOwnedSlice();
}

fn isBlockOpen(line: []const u8) bool {
    // ^[a-z_]+ \{$
    if (!std.mem.endsWith(u8, line, " {") or line.len < 3) return false;
    for (line[0 .. line.len - 2]) |c| {
        if (!((c >= 'a' and c <= 'z') or c == '_')) return false;
    }
    return true;
}

/// The messages and fields of the text format `protoc --decode=
/// google.protobuf.FileDescriptorSet` prints for a descriptor set: `M <message>`
/// for every message and one `F` row for every field of one.
pub fn parseSchema(a: std.mem.Allocator, text: []const u8) !Schema {
    var msgs = std.ArrayList([]const u8).init(a);
    var fields = std.ArrayList(Field).init(a);
    var kinds = std.ArrayList([]const u8).init(a); // k[d], 1-based: index d-1
    var full = std.ArrayList([]const u8).init(a); // full[d], index d (0 is "")
    try full.append("");
    var infield: usize = 0;
    var fname: []const u8 = "";
    var fnum: []const u8 = "";
    var flabel: []const u8 = "";
    var ftype: []const u8 = "";
    var ftn: []const u8 = "-";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimLeft(u8, raw, " ");
        const d = kinds.items.len;
        if (isBlockOpen(line)) {
            const k = line[0 .. line.len - 2];
            try kinds.append(k);
            try full.resize(d + 2);
            full.items[d + 1] = full.items[d];
            if (std.mem.eql(u8, k, "field") and d >= 1 and
                (std.mem.eql(u8, kinds.items[d - 1], "message_type") or std.mem.eql(u8, kinds.items[d - 1], "nested_type")))
            {
                infield = d + 1;
                fname = "";
                fnum = "";
                flabel = "";
                ftype = "";
                ftn = "-";
            }
            continue;
        }
        if (std.mem.eql(u8, line, "}")) {
            if (d == 0) continue;
            if (d == infield) {
                try fields.append(.{ .msg = full.items[d - 1], .name = fname, .num = fnum, .label = flabel, .typ = ftype, .type_name = ftn });
                infield = 0;
            }
            _ = kinds.pop();
            continue;
        }
        if (d == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':');
        const key = if (colon) |c| line[0..c] else line;
        const val = if (std.mem.indexOf(u8, line, ": ")) |c| blk: {
            // sub(/^[^:]*: /, ""): the first ": " only if no colon comes before it.
            break :blk if (std.mem.indexOfScalar(u8, line[0..c], ':') == null) line[c + 2 ..] else line;
        } else line;
        const k = kinds.items[d - 1];
        if (d == 1 and std.mem.eql(u8, k, "file") and std.mem.eql(u8, key, "package")) {
            full.items[1] = try unquote(a, val);
        } else if ((std.mem.eql(u8, k, "message_type") or std.mem.eql(u8, k, "nested_type")) and std.mem.eql(u8, key, "name")) {
            const nm = try unquote(a, val);
            const parent = full.items[d - 1];
            full.items[d] = if (parent.len == 0) nm else try std.fmt.allocPrint(a, "{s}.{s}", .{ parent, nm });
            try msgs.append(full.items[d]);
        } else if (d == infield) {
            if (std.mem.eql(u8, key, "name")) {
                fname = try unquote(a, val);
            } else if (std.mem.eql(u8, key, "number")) {
                fnum = val;
            } else if (std.mem.eql(u8, key, "label")) {
                flabel = val;
            } else if (std.mem.eql(u8, key, "type")) {
                ftype = val;
            } else if (std.mem.eql(u8, key, "type_name")) {
                const t = try unquote(a, val);
                ftn = if (t.len > 0 and t[0] == '.') t[1..] else t;
            }
        }
    }
    return .{ .messages = try msgs.toOwnedSlice(), .fields = try fields.toOwnedSlice() };
}

/// The table as `M <message>` and `F <message> <field> <number> <label> <type>
/// <type name or ->` lines, fields after the message they follow in the text.
pub fn tableText(a: std.mem.Allocator, s: Schema) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    for (s.messages) |m| try out.writer().print("M {s}\n", .{m});
    for (s.fields) |f| try out.writer().print("F {s} {s} {s} {s} {s} {s}\n", .{ f.msg, f.name, f.num, f.label, f.typ, f.type_name });
    return out.toOwnedSlice();
}

/// The number of `field {` lines of the descriptor set's text.
pub fn fieldBlocks(text: []const u8) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        if (std.mem.eql(u8, std.mem.trimLeft(u8, l, " "), "field {")) n += 1;
    }
    return n;
}

/// Whether every field row is complete: a number of digits, `LABEL_` and `TYPE_`
/// words, no empty field.
pub fn rowsComplete(s: Schema) bool {
    for (s.fields) |f| {
        if (f.msg.len == 0 or f.name.len == 0 or f.type_name.len == 0) return false;
        if (std.mem.indexOfScalar(u8, f.msg, ' ') != null or std.mem.indexOfScalar(u8, f.name, ' ') != null or std.mem.indexOfScalar(u8, f.type_name, ' ') != null) return false;
        if (f.num.len == 0) return false;
        for (f.num) |c| {
            if (c < '0' or c > '9') return false;
        }
        if (!std.mem.startsWith(u8, f.label, "LABEL_") or !std.mem.startsWith(u8, f.typ, "TYPE_")) return false;
        for (f.label["LABEL_".len..]) |c| {
            if (!(c >= 'A' and c <= 'Z')) return false;
        }
        for (f.typ["TYPE_".len..]) |c| {
            if (!((c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9'))) return false;
        }
    }
    for (s.messages) |m| {
        if (m.len == 0 or std.mem.indexOfScalar(u8, m, ' ') != null) return false;
    }
    return true;
}

fn declares(s: Schema, root: []const u8) bool {
    for (s.messages) |m| {
        if (std.mem.eql(u8, m, root)) return true;
    }
    return false;
}

fn fieldOf(s: Schema, msg: []const u8, name: []const u8) ?Field {
    for (s.fields) |f| {
        if (std.mem.eql(u8, f.msg, msg) and std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

// ---- the wire, walked at the top level --------------------------------------------

pub const Tag = struct { num: u64, count: usize };

const Wire = struct {
    d: []const u8,
    p: usize = 0,
    broken: bool = false,

    fn byte(self: *Wire) u8 {
        if (self.p >= self.d.len) {
            self.broken = true;
            return 0;
        }
        const b = self.d[self.p];
        self.p += 1;
        return b;
    }

    fn varint(self: *Wire) u64 {
        var v: u64 = 0;
        var shift: u6 = 0;
        var n: usize = 0;
        while (true) {
            const b = self.byte();
            if (self.broken) return v;
            if (shift < 64) v |= (@as(u64, b & 0x7f)) << shift;
            n += 1;
            if (b < 128) return v;
            if (n >= 10) {
                self.broken = true;
                return v;
            }
            shift += 7;
        }
    }

    fn skip(self: *Wire, w: u64) void {
        switch (w) {
            0 => _ = self.varint(),
            1 => self.p +|= 8,
            2 => {
                const len = self.varint();
                self.p +|= @intCast(@min(len, std.math.maxInt(usize) / 2));
            },
            5 => self.p +|= 4,
            3 => {
                var depth: usize = 1;
                while (depth > 0 and !self.broken) {
                    const t = self.varint();
                    if (t % 8 == 3) {
                        depth += 1;
                    } else if (t % 8 == 4) {
                        depth -= 1;
                    } else self.skip(t % 8);
                }
            },
            else => self.broken = true,
        }
        if (self.p > self.d.len) self.broken = true;
    }
};

/// `<field number> <times>` for each field number at the top level of the
/// bytes (a group is skipped whole), by field number. Stops at bytes that are not
/// a message, which leg 1 reports.
pub fn topTags(a: std.mem.Allocator, bytes: []const u8) ![]Tag {
    var w = Wire{ .d = bytes };
    var counts = std.AutoHashMap(u64, usize).init(a);
    while (w.p < bytes.len and !w.broken) {
        const t = w.varint();
        if (w.broken) break;
        w.skip(t % 8);
        if (!w.broken) {
            const e = try counts.getOrPut(t / 8);
            if (!e.found_existing) e.value_ptr.* = 0;
            e.value_ptr.* += 1;
        }
    }
    var out = std.ArrayList(Tag).init(a);
    var it = counts.iterator();
    while (it.next()) |e| try out.append(.{ .num = e.key_ptr.*, .count = e.value_ptr.* });
    std.mem.sort(Tag, out.items, {}, struct {
        fn lt(_: void, x: Tag, y: Tag) bool {
            return x.num < y.num;
        }
    }.lt);
    return out.toOwnedSlice();
}

/// Leg 0's duplicate lines: each singular (not repeated) field of `root` the
/// tags show written more than once.
pub fn duplicates(a: std.mem.Allocator, s: Schema, root: []const u8, tags: []const Tag) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    for (tags) |t| {
        if (t.count <= 1) continue;
        for (s.fields) |f| {
            if (!std.mem.eql(u8, f.msg, root) or std.mem.eql(u8, f.label, "LABEL_REPEATED")) continue;
            const n = std.fmt.parseInt(u64, f.num, 10) catch continue;
            if (n == t.num) try out.writer().print("{s} (field {d}) written {d} times\n", .{ f.name, t.num, t.count });
        }
    }
    return out.toOwnedSlice();
}

// ---- leg 2 and 5: protoc's decode -------------------------------------------------

/// Leg 2: the lines of the decode that are a bare field number (`99: 1`, `99 {`),
/// as `grep -n` prints them, at most 20.
pub fn unknownFields(a: std.mem.Allocator, decoded: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    var lines = std.mem.splitScalar(u8, decoded, '\n');
    var n: usize = 0;
    var shown: usize = 0;
    while (lines.next()) |l| {
        n += 1;
        if (lines.peek() == null and l.len == 0) break;
        const t = std.mem.trimLeft(u8, l, " \t\r\n\x0b\x0c");
        var i: usize = 0;
        while (i < t.len and t[i] >= '0' and t[i] <= '9') i += 1;
        if (i == 0) continue;
        const rest = t[i..];
        if (!(std.mem.startsWith(u8, rest, ":") or std.mem.eql(u8, rest, " {") or std.mem.startsWith(u8, rest, " {"))) continue;
        if (shown == 20) break;
        try out.writer().print("{d}:{s}\n", .{ n, l });
        shown += 1;
    }
    return out.toOwnedSlice();
}

fn isIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}

pub const Walk = struct {
    /// Lines of the decode that cannot be placed in a message by the schema.
    unplaced: []const u8,
    /// Enum values printed as numbers.
    enums: []const u8,
};

/// Leg 5: each line of the decode is placed in its message by walking it from
/// `root` with the schema; a line that cannot be placed is reported (never
/// skipped), and so is an enum field printed as a number. Both at most 20 lines.
pub fn walkEnums(a: std.mem.Allocator, s: Schema, root: []const u8, decoded: []const u8) !Walk {
    var unplaced = std.ArrayList(u8).init(a);
    var enums = std.ArrayList(u8).init(a);
    var nu: usize = 0;
    var ne: usize = 0;
    var st = std.ArrayList([]const u8).init(a);
    try st.append(root);
    var lines = std.mem.splitScalar(u8, decoded, '\n');
    var fnr: usize = 0;
    while (lines.next()) |raw| {
        fnr += 1;
        if (lines.peek() == null and raw.len == 0) break;
        const line = std.mem.trimLeft(u8, raw, " ");
        if (std.mem.eql(u8, line, "}")) {
            if (st.items.len > 0) _ = st.pop();
            continue;
        }
        const top: []const u8 = if (st.items.len > 0) st.items[st.items.len - 1] else "?";
        if (std.mem.endsWith(u8, line, " {") and isIdent(line[0 .. line.len - 2])) {
            const f = line[0 .. line.len - 2];
            if (std.mem.eql(u8, top, "?")) {
                try st.append("?");
            } else if (groupOrField(s, top, f)) |fd| {
                try st.append(fd.type_name);
            } else {
                if (nu < 20) try unplaced.writer().print("{d}: `{s}` in {s}\n", .{ fnr, f, top });
                nu += 1;
                try st.append("?");
            }
            continue;
        }
        if (std.mem.endsWith(u8, line, " {")) {
            try st.append("?");
            continue;
        }
        if (std.mem.eql(u8, top, "?")) continue;
        const colon = std.mem.indexOf(u8, line, ": ") orelse continue;
        const f = line[0..colon];
        if (!isIdent(f)) continue;
        const v = line[colon + 2 ..];
        if (groupOrField(s, top, f)) |fd| {
            if (std.mem.eql(u8, fd.typ, "TYPE_ENUM") and v.len > 0 and
                ((v[0] >= '0' and v[0] <= '9') or (v[0] == '-' and v.len > 1 and v[1] >= '0' and v[1] <= '9')))
            {
                if (ne < 20) try enums.writer().print("{d}: {s}    ({s}.{s}, {s})\n", .{ fnr, raw, top, f, fd.type_name });
                ne += 1;
            }
        } else {
            if (nu < 20) try unplaced.writer().print("{d}: `{s}` in {s}\n", .{ fnr, f, top });
            nu += 1;
        }
    }
    return .{ .unplaced = try unplaced.toOwnedSlice(), .enums = try enums.toOwnedSlice() };
}

/// The field `f` of message `msg`: by its name, or (a group is printed under its
/// type name) by the last component of the type name of a TYPE_GROUP field.
fn groupOrField(s: Schema, msg: []const u8, f: []const u8) ?Field {
    if (fieldOf(s, msg, f)) |fd| return fd;
    for (s.fields) |fd| {
        if (!std.mem.eql(u8, fd.msg, msg) or !std.mem.eql(u8, fd.typ, "TYPE_GROUP")) continue;
        const short = if (std.mem.lastIndexOfScalar(u8, fd.type_name, '.')) |i| fd.type_name[i + 1 ..] else fd.type_name;
        if (std.mem.eql(u8, short, f)) return fd;
    }
    return null;
}

// ---- a unified diff, for leg 1 ------------------------------------------------------

fn splitLines(a: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).init(a);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        if (it.peek() == null and l.len == 0) break;
        try out.append(l);
    }
    return out.toOwnedSlice();
}

/// `diff -u -L <label1> -L <label2> <a> <b>`: null when the texts are equal.
/// Lines are compared as lines; three lines of context.
pub fn unifiedDiff(a: std.mem.Allocator, label1: []const u8, label2: []const u8, t1: []const u8, t2: []const u8) !?[]u8 {
    if (std.mem.eql(u8, t1, t2)) return null;
    const x = try splitLines(a, t1);
    const y = try splitLines(a, t2);
    const n = x.len;
    const m = y.len;
    // The longest common subsequence of lines, from the ends (so a diff of two
    // large files that share a prefix and a suffix stays cheap).
    var pre: usize = 0;
    while (pre < n and pre < m and std.mem.eql(u8, x[pre], y[pre])) pre += 1;
    var suf: usize = 0;
    while (suf < n - pre and suf < m - pre and std.mem.eql(u8, x[n - 1 - suf], y[m - 1 - suf])) suf += 1;
    const xs = x[pre .. n - suf];
    const ys = y[pre .. m - suf];
    const w = ys.len + 1;
    const table = try a.alloc(u32, (xs.len + 1) * w);
    @memset(table, 0);
    var i: usize = xs.len;
    while (i > 0) {
        i -= 1;
        var j: usize = ys.len;
        while (j > 0) {
            j -= 1;
            table[i * w + j] = if (std.mem.eql(u8, xs[i], ys[j])) table[(i + 1) * w + j + 1] + 1 else @max(table[(i + 1) * w + j], table[i * w + j + 1]);
        }
    }
    // Ops over the whole files: ' ' common, '-' only in the first, '+' only in the second.
    const Op = struct { kind: u8, line: []const u8 };
    var ops = std.ArrayList(Op).init(a);
    for (x[0..pre]) |l| try ops.append(.{ .kind = ' ', .line = l });
    var p: usize = 0;
    var q: usize = 0;
    while (p < xs.len or q < ys.len) {
        if (p < xs.len and q < ys.len and std.mem.eql(u8, xs[p], ys[q])) {
            try ops.append(.{ .kind = ' ', .line = xs[p] });
            p += 1;
            q += 1;
        } else if (p < xs.len and (q == ys.len or table[(p + 1) * w + q] >= table[p * w + q + 1])) {
            try ops.append(.{ .kind = '-', .line = xs[p] });
            p += 1;
        } else {
            try ops.append(.{ .kind = '+', .line = ys[q] });
            q += 1;
        }
    }
    for (x[n - suf ..]) |l| try ops.append(.{ .kind = ' ', .line = l });

    var out = std.ArrayList(u8).init(a);
    try out.writer().print("--- {s}\n+++ {s}\n", .{ label1, label2 });
    const context = 3;
    // The line number of each op in the old and the new file.
    const old_at = try a.alloc(usize, ops.items.len + 1);
    const new_at = try a.alloc(usize, ops.items.len + 1);
    var l1: usize = 1;
    var l2: usize = 1;
    for (ops.items, 0..) |op, k| {
        old_at[k] = l1;
        new_at[k] = l2;
        if (op.kind != '+') l1 += 1;
        if (op.kind != '-') l2 += 1;
    }
    var k: usize = 0;
    while (k < ops.items.len) {
        while (k < ops.items.len and ops.items[k].kind == ' ') k += 1;
        if (k == ops.items.len) break;
        // A hunk: the changes from k, merged while the common run between two is no longer than twice the context.
        const first = k;
        var last = k;
        var j = k + 1;
        while (j < ops.items.len) : (j += 1) {
            if (ops.items[j].kind != ' ') {
                last = j;
            } else if (j - last > 2 * context) break;
        }
        const start = if (first >= context) first - context else 0;
        const stop = @min(ops.items.len, last + context + 1);
        var olds: usize = 0;
        var news: usize = 0;
        for (ops.items[start..stop]) |op| {
            if (op.kind != '+') olds += 1;
            if (op.kind != '-') news += 1;
        }
        const o1 = if (olds == 0) old_at[start] - 1 else old_at[start];
        const n1 = if (news == 0) new_at[start] - 1 else new_at[start];
        try out.writer().print("@@ -{d},{d} +{d},{d} @@\n", .{ o1, olds, n1, news });
        for (ops.items[start..stop]) |op| try out.writer().print("{c}{s}\n", .{ op.kind, op.line });
        k = stop;
    }
    return try out.toOwnedSlice();
}

// ---- running protoc ------------------------------------------------------------------

pub fn exitCodeOf(term: std.process.Child.Term) u8 {
    return switch (term) {
        .Exited => |c| c,
        .Signal => |s| @truncate(128 +% s),
        else => 1,
    };
}

const Run = struct { code: u8, out: []u8, err: []u8 };

fn runWith(a: std.mem.Allocator, argv: []const []const u8, env: *const std.process.EnvMap, stdin: ?[]const u8) !Run {
    var child = std.process.Child.init(argv, a);
    child.env_map = env;
    child.stdin_behavior = if (stdin != null) .Pipe else .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    if (stdin) |bytes| {
        child.stdin.?.writeAll(bytes) catch {};
        child.stdin.?.close();
        child.stdin = null;
    }
    var out = std.ArrayList(u8).init(a);
    var err = std.ArrayList(u8).init(a);
    try child.collectOutput(&out, &err, 1 << 28);
    const term = try child.wait();
    return .{ .code = exitCodeOf(term), .out = try out.toOwnedSlice(), .err = try err.toOwnedSlice() };
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("proto_fixture: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn readFile(a: std.mem.Allocator, path: []const u8) []u8 {
    return std.fs.cwd().readFileAlloc(a, path, 1 << 28) catch |e| die("cannot read {s}: {s}", .{ path, @errorName(e) });
}

const Ctx = struct {
    a: std.mem.Allocator,
    protoc: []const u8,
    protoc_dir: []const u8,
    proto_paths: []const []const u8,
    files: []const []const u8,
    env: std.process.EnvMap,
    t: []const u8,
    nbad: usize = 0,

    /// protoc over the schema: the proto paths, `extra`, then the files; stdin to stdout.
    fn run(self: *Ctx, extra: []const []const u8, stdin: ?[]const u8) !Run {
        var argv = std.ArrayList([]const u8).init(self.a);
        try argv.append(self.protoc);
        for (self.proto_paths) |p| try argv.append(try std.fmt.allocPrint(self.a, "--proto_path={s}", .{p}));
        try argv.append(try std.fmt.allocPrint(self.a, "--proto_path={s}/include", .{self.protoc_dir}));
        try argv.appendSlice(extra);
        try argv.appendSlice(self.files);
        return runWith(self.a, argv.items, &self.env, stdin);
    }

    fn bad(self: *Ctx, stem: []const u8, leg: []const u8, msg: []const u8, details: ?[]const u8) !void {
        std.debug.print("proto_fixture: {s}: {s}: {s}\n", .{ stem, leg, msg });
        if (details) |d| std.debug.print("{s}", .{try indent(self.a, d)});
        self.nbad += 1;
    }
};

fn setup(a: std.mem.Allocator, args: []const []const u8, t: []const u8) !struct { ctx: Ctx, rest: []const []const u8 } {
    // args: <busybox> <protoc dir> <mode> <out> <n> paths... <m> files... -- ...
    const cwd = try std.fs.cwd().realpathAlloc(a, ".");
    const abs = struct {
        fn of(al: std.mem.Allocator, base: []const u8, p: []const u8) ![]u8 {
            return if (std.fs.path.isAbsolute(p)) al.dupe(u8, p) else std.fs.path.join(al, &.{ base, p });
        }
    }.of;
    const bb = try abs(a, cwd, args[0]);
    const protoc_dir = try abs(a, cwd, args[1]);
    var i: usize = 4;
    const n = std.fmt.parseInt(usize, args[i], 10) catch die("usage error: {s} is not a number", .{args[i]});
    i += 1;
    if (i + n >= args.len) die("usage error", .{});
    var paths = std.ArrayList([]const u8).init(a);
    for (args[i .. i + n]) |p| try paths.append(try abs(a, cwd, p));
    i += n;
    const m = std.fmt.parseInt(usize, args[i], 10) catch die("usage error: {s} is not a number", .{args[i]});
    i += 1;
    if (i + m >= args.len) die("usage error", .{});
    const files = args[i .. i + m];
    i += m;
    if (!std.mem.eql(u8, args[i], "--")) die("usage error (no --)", .{});
    i += 1;

    const bin = try std.fs.path.join(a, &.{ t, "bin" });
    const tmp = try std.fs.path.join(a, &.{ t, "tmp" });
    const home = try std.fs.path.join(a, &.{ t, "home" });
    for ([_][]const u8{ bin, tmp, home }) |d| try std.fs.cwd().makePath(d);
    var env = try std.process.getEnvMap(a);
    var install = std.process.Child.init(&.{ bb, "--install", "-s", bin }, a);
    install.env_map = &env;
    const installed = install.spawnAndWait() catch |e| die("cannot run {s}: {s}", .{ bb, @errorName(e) });
    if (exitCodeOf(installed) != 0) die("{s} --install -s {s} failed", .{ bb, bin });
    try env.put("PATH", bin);
    try env.put("TMPDIR", tmp);
    try env.put("HOME", home);
    return .{
        .ctx = .{ .a = a, .protoc = try std.fs.path.join(a, &.{ protoc_dir, "bin", "protoc" }), .protoc_dir = protoc_dir, .proto_paths = try paths.toOwnedSlice(), .files = files, .env = env, .t = t },
        .rest = args[i..],
    };
}

fn encode(ctx: *Ctx, out_path: []const u8, rest: []const []const u8) !u8 {
    const a = ctx.a;
    if (rest.len != 2) die("encode takes <root> <txtpb>", .{});
    const root = rest[0];
    const txtpb_path = rest[1];
    const txtpb = readFile(a, txtpb_path);
    const named = txtpbRoot(txtpb);
    if (named == null or !std.mem.eql(u8, named.?, root)) {
        const first = std.mem.trimRight(u8, firstLine(txtpb), "\n");
        std.debug.print("proto_encode: {s} must begin with the line '# proto-message: {s}'; its first line is: {s}\n", .{ txtpb_path, root, first });
        return 1;
    }
    const r = try ctx.run(&.{try std.fmt.allocPrint(a, "--encode={s}", .{root})}, txtpb);
    if (r.code != 0) {
        std.debug.print("proto_encode: protoc refused to encode {s} as {s}:\n{s}", .{ txtpb_path, root, try indent(a, r.err) });
        return 1;
    }
    if (r.out.len == 0) {
        std.debug.print("proto_encode: {s} encodes to zero bytes (every field at its default): no fixture to write\n", .{txtpb_path});
        return 1;
    }
    const f = std.fs.cwd().createFile(out_path, .{}) catch |e| die("cannot create {s}: {s}", .{ out_path, @errorName(e) });
    defer f.close();
    try f.writeAll(try tohex(a, r.out));
    return 0;
}

fn check(ctx: *Ctx, out_path: []const u8, rest: []const []const u8) !u8 {
    const a = ctx.a;
    if (rest.len == 0 or rest.len % 6 != 0) die("check takes groups of <stem> <root> <hex> <txtpb> <canonical hex> <canonical producer>", .{});

    // The schema, from protoc's own descriptor set.
    const set_path = try std.fs.path.join(a, &.{ ctx.t, "schema.pb" });
    const r1 = try ctx.run(&.{ "--include_imports", try std.fmt.allocPrint(a, "--descriptor_set_out={s}", .{set_path}) }, null);
    var schema_err = std.ArrayList(u8).init(a);
    try schema_err.appendSlice(r1.err);
    var ok = r1.code == 0;
    var decoded_set: []const u8 = "";
    if (ok) {
        const set_bytes = readFile(a, set_path);
        var argv = std.ArrayList([]const u8).init(a);
        try argv.append(ctx.protoc);
        try argv.append(try std.fmt.allocPrint(a, "--proto_path={s}/include", .{ctx.protoc_dir}));
        try argv.append("--decode=google.protobuf.FileDescriptorSet");
        try argv.append("google/protobuf/descriptor.proto");
        const r2 = try runWith(a, argv.items, &ctx.env, set_bytes);
        try schema_err.appendSlice(r2.err);
        ok = r2.code == 0;
        decoded_set = r2.out;
    }
    if (!ok) {
        std.debug.print("proto_fixture: SCHEMA: protoc cannot write or read the schema's descriptor set:\n{s}", .{try indent(a, schema_err.items)});
        return 1;
    }
    const schema = try parseSchema(a, decoded_set);
    const nfields = fieldBlocks(decoded_set);
    if (schema.fields.len != nfields or !rowsComplete(schema)) {
        const table = try tableText(a, schema);
        std.debug.print("proto_fixture: SCHEMA: the descriptor set holds {d} field(s), but its table is not one complete row for each:\n{s}", .{ nfields, try indent(a, head(table, 20)) });
        return 1;
    }

    var report = std.ArrayList(u8).init(a);
    const ver = (try runWith(a, &.{ ctx.protoc, "--version" }, &ctx.env, null)).out;
    try report.writer().print("protoc: {s}\n", .{std.mem.trimRight(u8, ver, "\n")});

    var gi: usize = 0;
    while (gi < rest.len) : (gi += 6) {
        const stem = rest[gi];
        const root = rest[gi + 1];
        const hex_path = rest[gi + 2];
        const txtpb_path = rest[gi + 3];
        const canon_path = rest[gi + 4];
        const producer = rest[gi + 5];
        const hexn = std.fs.path.basename(hex_path);
        const txtpbn = std.fs.path.basename(txtpb_path);
        const canonn = std.fs.path.basename(canon_path);
        const before = ctx.nbad;

        const in_bytes = switch (try unhex(a, readFile(a, hex_path))) {
            .bytes => |b| b,
            .why => |w| {
                try ctx.bad(stem, "FIXTURE", try std.fmt.allocPrint(a, "{s} {s}", .{ hexn, w }), null);
                continue;
            },
        };
        const canon_bytes = switch (try unhex(a, readFile(a, canon_path))) {
            .bytes => |b| b,
            .why => |w| {
                try ctx.bad(stem, "FIXTURE", try std.fmt.allocPrint(a, "{s} {s}", .{ canonn, w }), null);
                continue;
            },
        };
        if (!declares(schema, root)) {
            try ctx.bad(stem, "FIXTURE", try std.fmt.allocPrint(a, "the schema declares no message {s}", .{root}), null);
            continue;
        }
        const txtpb = readFile(a, txtpb_path);
        const expected = dropFirstLine(txtpb);

        // LEG 0.
        if (!std.mem.eql(u8, producer, "1") and std.mem.eql(u8, in_bytes, canon_bytes)) {
            try ctx.bad(stem, "LEG 0", try std.fmt.allocPrint(a, "{s} is byte for byte {s}, protoc's encoding: both ends of legs 1 and 3 are protoc and no producer is checked (a producer that writes protoc's bytes is declared in `canonical_producer`)", .{ hexn, canonn }), null);
        }
        const dup = try duplicates(a, schema, root, try topTags(a, in_bytes));
        if (dup.len > 0) {
            try ctx.bad(stem, "LEG 0", try std.fmt.allocPrint(a, "{s} writes a singular field of {s} more than once (protoc's decode shows only the last):", .{ hexn, root }), dup);
        }

        // LEG 1.
        var decoded = false;
        var decoded_text: []const u8 = "";
        const d1 = try ctx.run(&.{try std.fmt.allocPrint(a, "--decode={s}", .{root})}, in_bytes);
        if (d1.code != 0) {
            try ctx.bad(stem, "LEG 1", try std.fmt.allocPrint(a, "protoc refused to decode {s} as {s}: the bytes are not a {s} message", .{ hexn, root, root }), d1.err);
        } else {
            decoded = true;
            decoded_text = d1.out;
            if (try unifiedDiff(a, txtpbn, "protoc --decode", expected, decoded_text)) |diff| {
                try ctx.bad(stem, "LEG 1", try std.fmt.allocPrint(a, "protoc's decode of {s} as {s} differs from {s} after its first line (- the .txtpb, + protoc):", .{ hexn, root, txtpbn }), head(diff, 40));
            }
        }

        // LEG 2.
        if (decoded) {
            const unknown = try unknownFields(a, decoded_text);
            if (unknown.len > 0) {
                try ctx.bad(stem, "LEG 2", try std.fmt.allocPrint(a, "{s} carries field numbers {s} does not declare (protoc prints them as bare numbers):", .{ hexn, root }), head(unknown, 20));
            }
        }

        // LEG 3.
        const e3 = try ctx.run(&.{try std.fmt.allocPrint(a, "--encode={s}", .{root})}, txtpb);
        if (e3.code != 0) {
            try ctx.bad(stem, "LEG 3", try std.fmt.allocPrint(a, "protoc refused to encode {s} as {s}:", .{ txtpbn, root }), e3.err);
        } else if (!std.mem.eql(u8, e3.out, canon_bytes)) {
            try ctx.bad(stem, "LEG 3", try std.fmt.allocPrint(a, "{s} is not protoc's encoding of {s} ({d} bytes; protoc writes {d}, as hex):", .{ canonn, txtpbn, canon_bytes.len, e3.out.len }), try tohex(a, e3.out));
        }

        // LEG 4.
        if (txtpbRoot(txtpb)) |named| {
            if (!std.mem.eql(u8, named, root)) {
                try ctx.bad(stem, "LEG 4", try std.fmt.allocPrint(a, "{s} names {s} on its '# proto-message:' line, but the fixture is checked as {s}", .{ txtpbn, named, root }), null);
            }
        } else {
            try ctx.bad(stem, "LEG 4", try std.fmt.allocPrint(a, "{s} does not begin with the line '# proto-message: {s}'; its first line is:", .{ txtpbn, root }), firstLine(txtpb));
        }

        // LEG 5.
        if (decoded) {
            const walk = try walkEnums(a, schema, root, decoded_text);
            if (walk.unplaced.len > 0) {
                try ctx.bad(stem, "LEG 5", try std.fmt.allocPrint(a, "cannot place these lines of protoc's decode in {s} with the schema's descriptor set, so their enum values are unchecked:", .{root}), walk.unplaced);
            }
            if (walk.enums.len > 0) {
                try ctx.bad(stem, "LEG 5", try std.fmt.allocPrint(a, "{s} carries enum values the schema does not name (protoc prints them as numbers):", .{hexn}), walk.enums);
            }
        }

        if (ctx.nbad == before) {
            try report.writer().print("PASS {s} {s}: {d} bytes, {d} canonical, {d} lines\n", .{ stem, root, in_bytes.len, canon_bytes.len, countLines(decoded_text) });
        }
    }
    if (ctx.nbad != 0) {
        std.debug.print("proto_fixture: FAILED: {d} failure(s) (legs: 0 producer, 1 decode == .txtpb, 2 no unknown fields, 3 encode == .canonical.hex, 4 root, 5 enum values named)\n", .{ctx.nbad});
        return 1;
    }
    const f = std.fs.cwd().createFile(out_path, .{}) catch |e| die("cannot create {s}: {s}", .{ out_path, @errorName(e) });
    defer f.close();
    try f.writeAll(report.items);
    return 0;
}

fn scratch(a: std.mem.Allocator, cwd: []const u8) ![]u8 {
    var rnd: [4]u8 = undefined;
    std.crypto.random.bytes(&rnd);
    const hex = std.fmt.bytesToHex(rnd, .lower);
    return std.fmt.allocPrint(a, "{s}/.komira_proto_fixture.{s}", .{ cwd, &hex });
}

/// `case`: the check over planted fixtures, its verdict asserted.
fn caseMode(a: std.mem.Allocator, args: []const []const u8) !u8 {
    if (args.len < 6) die("usage: proto_fixture case <expect> <verdict> <busybox> <protoc dir> <check arguments>", .{});
    const expect = args[0];
    const verdict = args[1];
    const cwd = try std.fs.cwd().realpathAlloc(a, ".");
    const t = try scratch(a, cwd);
    try std.fs.cwd().makePath(t);
    defer std.fs.cwd().deleteTree(t) catch {};
    const report = try std.fs.path.join(a, &.{ t, "report" });
    const self = try std.fs.selfExePathAlloc(a);
    var argv = std.ArrayList([]const u8).init(a);
    try argv.appendSlice(&.{ self, "check", args[2], args[3], report });
    try argv.appendSlice(args[4..]);
    const env = try std.process.getEnvMap(a);
    const r = try runWith(a, argv.items, &env, null);
    const have_report = if (std.fs.cwd().statFile(report)) |_| true else |_| false;
    const out = std.fs.cwd().createFile(verdict, .{}) catch |e| die("cannot create {s}: {s}", .{ verdict, @errorName(e) });
    defer out.close();
    if (expect.len == 0) {
        if (r.code != 0) {
            std.debug.print("proto_fixture_case: the check refused fixtures it must accept:\n{s}", .{r.err});
            return 1;
        }
        const rep = std.fs.cwd().readFileAlloc(a, report, 1 << 24) catch "";
        if (rep.len == 0) {
            std.debug.print("proto_fixture_case: the check wrote no report\n", .{});
            return 1;
        }
        try out.writeAll("accepted\n");
        try out.writeAll(rep);
    } else if (r.code == 0) {
        std.debug.print("proto_fixture_case: the check accepted fixtures it must refuse with: {s}\n", .{expect});
        return 1;
    } else if (std.mem.indexOf(u8, r.err, expect) == null) {
        std.debug.print("proto_fixture_case: the check refused, but not with: {s}\n{s}", .{ expect, r.err });
        return 1;
    } else if (have_report) {
        std.debug.print("proto_fixture_case: the check refused but wrote its report\n", .{});
        return 1;
    } else {
        try out.writeAll("refused\n");
        try out.writeAll(r.err);
    }
    return 0;
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len < 2) die("usage: proto_fixture (check|encode|case) ...", .{});
    if (std.mem.eql(u8, argv[1], "case")) {
        const rc = try caseMode(a, argv[2..]);
        if (rc != 0) std.process.exit(rc);
        return;
    }
    const mode = argv[1];
    if (!std.mem.eql(u8, mode, "check") and !std.mem.eql(u8, mode, "encode")) die("unknown mode '{s}'", .{mode});
    // proto_fixture <mode> <busybox> <protoc dir> <out> ...: the shell script's
    // order was <busybox> <protoc dir> <mode> <out>, so the arguments are
    // reordered to its.
    if (argv.len < 8) die("usage error", .{});
    var args = std.ArrayList([]const u8).init(a);
    try args.appendSlice(&.{ argv[2], argv[3], mode });
    try args.appendSlice(argv[4..]);
    const cwd = try std.fs.cwd().realpathAlloc(a, ".");
    const t = try scratch(a, cwd);
    try std.fs.cwd().makePath(t);
    defer std.fs.cwd().deleteTree(t) catch {};
    const s = try setup(a, args.items, t);
    var ctx = s.ctx;
    const out_path = args.items[3];
    const rc = if (std.mem.eql(u8, mode, "encode")) try encode(&ctx, out_path, s.rest) else try check(&ctx, out_path, s.rest);
    if (rc != 0) {
        std.fs.cwd().deleteTree(t) catch {};
        std.process.exit(rc);
    }
}
