// Why Zig: build tools are Zig (tools/build/README.md): the check and the header
// generator of `komira_abi_golden` run as one build action with no shell.
//! abi_golden: the checks and the C header of `komira_abi_golden` (abi_golden.bzl).
//!
//! usage: abi_golden <source.mojo> <golden.tsv> <out header> <label> <header name> [<constants.mojo>]
//!
//! The source is read for its `@export` functions that are `abi("C")`: each
//! one's symbol, return type and argument types. The golden is a tab-separated
//! file: a first line `version<TAB><major>.<minor>`, then one row per symbol,
//! `symbol<TAB>return<TAB>arguments<TAB>since`, where arguments are the types
//! joined by `,` (`-` for none), `None` is a function returning nothing, and
//! `since` is the `<major>.<minor>` that added the symbol. Blank lines and
//! lines starting with `#` after the first are skipped.
//!
//! Every finding is reported before the tool fails: a golden symbol the
//! source lacks, a source symbol the golden lacks, a changed return or
//! argument type, a row whose `since` is above the golden version, a symbol
//! listed twice, and a type outside the type map (see `cValueType`). With no
//! finding, the header is written: include guards, `<stddef.h>` and
//! `<stdint.h>`, the version macros, the opaque handle typedef and one prototype
//! per row, in the golden's order.
//!
//! Types are compared as written, after dropping blanks, with an
//! `UnsafePointer[T, <origin>...]` reduced to `UnsafePointer[T]` and an
//! `OpaquePointer[...]` or `UnsafePointer[NoneType]` to `OpaquePointer`: the
//! origin is a lifetime of the Mojo side and has no C spelling.
//!
//! A golden may also list constants, rows `constant<TAB>NAME<TAB>VALUE<TAB>since`
//! (NAME starts with `KOMIRA_`, VALUE is a decimal integer). They become
//! `#define`s in the header. With a constants file, its top-level
//! `comptime KOMIRA_NAME: <integer type> = <product of integers>` lines are the
//! source of the constants: a golden constant it lacks, one whose value differs
//! and a `KOMIRA_` constant the golden does not list are findings. Constants in
//! the golden with no constants file are a finding too: nothing would hold them.
//!
//! `CStr` (`const char *`) and `ConstBytes` (`const uint8_t *`) are named types
//! like `Handle`: a source that uses one must declare it as
//! `comptime CStr = UnsafePointer[UInt8, ...]` at the top level, and a
//! declaration that is any other type is a finding.
//!
//! Exit status: 0; 1 for findings; 2 for a usage error or a failure of the
//! tool's own.

const std = @import("std");
const Alloc = std.mem.Allocator;

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("abi_golden: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

pub const Findings = struct {
    a: Alloc,
    list: std.ArrayList([]const u8) = .empty,

    pub fn add(self: *Findings, comptime fmt: []const u8, args: anytype) !void {
        try self.list.append(self.a, try std.fmt.allocPrint(self.a, fmt, args));
    }
};

pub const Ver = struct {
    major: u32,
    minor: u32,

    pub fn above(self: Ver, other: Ver) bool {
        if (self.major != other.major) return self.major > other.major;
        return self.minor > other.minor;
    }
};

pub const Sig = struct {
    symbol: []const u8,
    ret: []const u8,
    args: []const []const u8,
    line: usize,
};

pub const Row = struct {
    symbol: []const u8,
    ret: []const u8,
    args: []const []const u8,
    since: Ver,
    line: usize,
};

/// A constant of the golden: `constant<TAB>NAME<TAB>VALUE<TAB>since`.
pub const Const = struct {
    name: []const u8,
    value: i128,
    since: Ver,
    line: usize,
};

pub const Golden = struct {
    version: Ver,
    rows: []const Row,
    consts: []const Const = &.{},
};

/// The range of a header constant: an `int` spells itself, a larger value
/// takes `ULL` and is at most a `uint64_t`.
pub const const_min: i128 = -2147483648;
pub const const_max: i128 = 18446744073709551615;

pub const const_prefix = "KOMIRA_";
const reserved_consts = [_][]const u8{ "KOMIRA_ABI_VERSION_MAJOR", "KOMIRA_ABI_VERSION_MINOR" };

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

pub fn isIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s, 0..) |c, i| {
        const alpha = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
        const digit = c >= '0' and c <= '9';
        if (!(alpha or (digit and i > 0))) return false;
    }
    return true;
}

/// `line` without a trailing `#` comment (a `#` inside a string stays).
fn stripComment(line: []const u8) []const u8 {
    var quote: u8 = 0;
    for (line, 0..) |c, i| {
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '#') {
            return line[0..i];
        }
    }
    return line;
}

/// `s` split at `sep` outside brackets, parentheses and strings; each piece trimmed.
fn splitTop(a: Alloc, s: []const u8, sep: u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var depth: i32 = 0;
    var quote: u8 = 0;
    var start: usize = 0;
    for (s, 0..) |c, i| {
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        switch (c) {
            '"', '\'' => quote = c,
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -= 1,
            else => if (c == sep and depth == 0) {
                try out.append(a, trim(s[start..i]));
                start = i + 1;
            },
        }
    }
    try out.append(a, trim(s[start..]));
    return out.toOwnedSlice(a);
}

/// The index of the first `c` in `s` outside brackets and parentheses.
fn indexTop(s: []const u8, c: u8) ?usize {
    var depth: i32 = 0;
    for (s, 0..) |x, i| {
        switch (x) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -= 1,
            else => if (x == c and depth == 0) return i,
        }
    }
    return null;
}

/// The canonical spelling of a Mojo type (see the module comment).
pub fn canonType(a: Alloc, raw: []const u8) Alloc.Error![]const u8 {
    var buf = std.ArrayList(u8).empty;
    for (raw) |c| {
        if (c != ' ' and c != '\t' and c != '\r') try buf.append(a, c);
    }
    const s = buf.items;
    if (std.mem.startsWith(u8, s, "OpaquePointer[") and std.mem.endsWith(u8, s, "]")) return "OpaquePointer";
    if (std.mem.startsWith(u8, s, "UnsafePointer[") and std.mem.endsWith(u8, s, "]")) {
        const inner = s["UnsafePointer[".len .. s.len - 1];
        const parts = try splitTop(a, inner, ',');
        var pointee: []const u8 = parts[0];
        for (parts) |p| {
            if (std.mem.indexOfScalar(u8, p, '=') == null) {
                pointee = p;
                break;
            }
        }
        const c = try canonType(a, pointee);
        if (std.mem.eql(u8, c, "NoneType")) return "OpaquePointer";
        return std.fmt.allocPrint(a, "UnsafePointer[{s}]", .{c});
    }
    return buf.toOwnedSlice(a);
}

const scalar_map = [_][2][]const u8{
    .{ "Int8", "int8_t" },
    .{ "Int16", "int16_t" },
    .{ "Int32", "int32_t" },
    .{ "Int64", "int64_t" },
    .{ "UInt8", "uint8_t" },
    .{ "UInt16", "uint16_t" },
    .{ "UInt32", "uint32_t" },
    .{ "UInt64", "uint64_t" },
    // Int and UInt are as wide as a pointer.
    .{ "Int", "ptrdiff_t" },
    .{ "UInt", "size_t" },
    .{ "Float32", "float" },
    .{ "Float64", "double" },
    .{ "OpaquePointer", "void *" },
    // A source alias of the opaque handle the library returns and takes back.
    // The tool trusts the name; it does not read the alias.
    .{ "Handle", "komira_handle" },
    // Pointers the C caller keeps const. In Mojo the pointee is UInt8 either way;
    // `named_aliases` holds the source to that.
    .{ "CStr", "const char *" },
    .{ "ConstBytes", "const uint8_t *" },
};

/// The C type of a canonical Mojo type that can be an argument or the pointee of
/// a pointer. An unknown type (Bool, String, a struct, a list, `None` in a
/// value position) is refused: `error.UnknownType`.
pub fn cValueType(a: Alloc, canon: []const u8) (Alloc.Error || error{UnknownType})![]const u8 {
    for (scalar_map) |m| {
        if (std.mem.eql(u8, canon, m[0])) return m[1];
    }
    if (std.mem.startsWith(u8, canon, "UnsafePointer[") and std.mem.endsWith(u8, canon, "]")) {
        const c = try cValueType(a, canon["UnsafePointer[".len .. canon.len - 1]);
        if (std.mem.endsWith(u8, c, "*")) return std.fmt.allocPrint(a, "{s}*", .{c});
        return std.fmt.allocPrint(a, "{s} *", .{c});
    }
    return error.UnknownType;
}

/// The C type of a return type: `None` is `void`.
pub fn cReturnType(a: Alloc, canon: []const u8) (Alloc.Error || error{UnknownType})![]const u8 {
    if (std.mem.eql(u8, canon, "None")) return "void";
    return cValueType(a, canon);
}

fn isExportDecorator(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "@export")) return false;
    const rest = line["@export".len..];
    return rest.len == 0 or rest[0] == '(' or rest[0] == ' ';
}

/// The functions of `text` (a Mojo source) that are `@export` and `abi("C")`.
/// A function that is `@export` alone is a Mojo-ABI export and not part of the
/// C ABI. A signature this tool cannot read is a finding, never skipped.
pub fn parseSource(a: Alloc, text: []const u8, f: *Findings) ![]const Sig {
    var lines = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try lines.append(a, l);
    var out = std.ArrayList(Sig).empty;
    var in_doc = false;
    var i: usize = 0;
    while (i < lines.items.len) : (i += 1) {
        const raw = lines.items[i];
        const was_doc = in_doc;
        if (std.mem.count(u8, raw, "\"\"\"") % 2 == 1) in_doc = !in_doc;
        if (was_doc) continue;
        const line = trim(stripComment(raw));
        if (!isExportDecorator(line)) continue;
        var symbol: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, line, '"')) |q| {
            if (std.mem.indexOfScalarPos(u8, line, q + 1, '"')) |e| symbol = line[q + 1 .. e];
        }
        var j = i + 1;
        while (j < lines.items.len) : (j += 1) {
            const l = trim(stripComment(lines.items[j]));
            if (l.len != 0 and l[0] != '@') break;
        }
        if (j >= lines.items.len) {
            try f.add("source line {d}: @export is not followed by a function", .{i + 1});
            break;
        }
        const head = trim(stripComment(lines.items[j]));
        if (!std.mem.startsWith(u8, head, "def ") and !std.mem.startsWith(u8, head, "fn ")) {
            try f.add("source line {d}: @export is not followed by a function", .{i + 1});
            i = j - 1;
            continue;
        }
        // The signature: from the keyword to the `:` that ends it.
        var sig = std.ArrayList(u8).empty;
        var depth: i32 = 0;
        var opened = false;
        var k = j;
        var done = false;
        while (k < lines.items.len and k - j < 64) : (k += 1) {
            const l = trim(stripComment(lines.items[k]));
            try sig.appendSlice(a, l);
            try sig.append(a, ' ');
            for (l) |c| {
                if (c == '(' or c == '[') {
                    depth += 1;
                    opened = true;
                } else if (c == ')' or c == ']') depth -= 1;
            }
            if (opened and depth == 0 and std.mem.endsWith(u8, l, ":")) {
                done = true;
                break;
            }
        }
        if (!done) {
            try f.add("source line {d}: the signature after @export does not end in `:` within 64 lines", .{j + 1});
            i = j;
            continue;
        }
        i = k;
        if (try parseSignature(a, trim(sig.items), symbol, j + 1, f)) |s| try out.append(a, s);
    }
    try checkNamedTypes(a, text, out.items, f);
    return out.toOwnedSlice(a);
}

/// The named C types whose Mojo alias the source must declare, with the
/// canonical type the alias must be.
const named_aliases = [_][2][]const u8{
    .{ "CStr", "UnsafePointer[UInt8]" },
    .{ "ConstBytes", "UnsafePointer[UInt8]" },
};

fn usesType(s: Sig, name: []const u8) bool {
    if (std.mem.eql(u8, s.ret, name)) return true;
    for (s.args) |t| {
        if (std.mem.eql(u8, t, name)) return true;
    }
    return false;
}

/// A named type a signature uses must be declared at the top level of the
/// source as `comptime <Name> = <type>` with the type `named_aliases` expects,
/// so a mapping to `const char *` cannot hide a pointer to anything else.
fn checkNamedTypes(a: Alloc, text: []const u8, sigs: []const Sig, f: *Findings) !void {
    for (named_aliases) |na| {
        var used: ?Sig = null;
        for (sigs) |s| {
            if (usesType(s, na[0])) used = s;
        }
        var declared = false;
        var it = std.mem.splitScalar(u8, text, '\n');
        var n: usize = 0;
        const head = try std.fmt.allocPrint(a, "comptime {s} =", .{na[0]});
        while (it.next()) |raw| {
            n += 1;
            if (!std.mem.startsWith(u8, raw, head)) continue;
            declared = true;
            const got = try canonType(a, trim(stripComment(raw[head.len..])));
            if (!std.mem.eql(u8, got, na[1])) {
                try f.add("source line {d}: `{s}` is declared as `{s}` and must be `{s}` (the header makes it a pointer to const)", .{ n, na[0], got, na[1] });
            }
        }
        if (used) |s| {
            if (!declared) try f.add("source line {d}: `{s}` uses the type `{s}` and the source declares no `comptime {s} = ...`", .{ s.line, s.symbol, na[0], na[0] });
        }
    }
}

fn parseSignature(a: Alloc, s: []const u8, symbol: ?[]const u8, line: usize, f: *Findings) !?Sig {
    const after_kw = trim(s[(std.mem.indexOfScalar(u8, s, ' ') orelse 0)..]);
    const open = std.mem.indexOfScalar(u8, after_kw, '(') orelse {
        try f.add("source line {d}: cannot read the signature `{s}`", .{ line, s });
        return null;
    };
    const name = trim(after_kw[0..open]);
    if (!isIdent(name)) {
        try f.add("source line {d}: `{s}` is not a plain function name (a generic function has no C ABI)", .{ line, name });
        return null;
    }
    var depth: i32 = 0;
    var close: ?usize = null;
    for (after_kw[open..], 0..) |c, n| {
        if (c == '(') depth += 1;
        if (c == ')') {
            depth -= 1;
            if (depth == 0) {
                close = open + n;
                break;
            }
        }
    }
    const rparen = close orelse {
        try f.add("source line {d}: unbalanced parentheses in the signature of `{s}`", .{ line, name });
        return null;
    };
    const params = after_kw[open + 1 .. rparen];
    const rest = trim(after_kw[rparen + 1 ..]);
    const marker = "abi(\"C\")";
    const at = std.mem.indexOf(u8, rest, marker) orelse return null; // a Mojo-ABI export
    const before = trim(rest[0..at]);
    if (before.len != 0) {
        try f.add("source line {d}: `{s}`: `{s}` before abi(\"C\") is not supported in a C ABI function", .{ line, name, before });
        return null;
    }
    var tail = trim(rest[at + marker.len ..]);
    if (!std.mem.endsWith(u8, tail, ":")) {
        try f.add("source line {d}: cannot read the end of the signature of `{s}`", .{ line, name });
        return null;
    }
    tail = trim(tail[0 .. tail.len - 1]);
    var ret: []const u8 = "None";
    if (tail.len != 0) {
        if (!std.mem.startsWith(u8, tail, "->")) {
            try f.add("source line {d}: `{s}`: `{s}` after abi(\"C\") is not supported in a C ABI function", .{ line, name, tail });
            return null;
        }
        ret = try canonType(a, tail[2..]);
    }
    var args = std.ArrayList([]const u8).empty;
    for (try splitTop(a, params, ',')) |p| {
        if (p.len == 0) continue; // a trailing comma, or no parameters
        const colon = indexTop(p, ':') orelse {
            try f.add("source line {d}: `{s}`: parameter `{s}` has no type", .{ line, name, p });
            return null;
        };
        const pname = trim(p[0..colon]);
        const ptype = trim(p[colon + 1 ..]);
        if (!isIdent(pname) or indexTop(ptype, '=') != null) {
            try f.add("source line {d}: `{s}`: parameter `{s}` has a form a C ABI function does not (a convention, a default or a marker)", .{ line, name, p });
            return null;
        }
        try args.append(a, try canonType(a, ptype));
    }
    return Sig{
        .symbol = symbol orelse name,
        .ret = ret,
        .args = try args.toOwnedSlice(a),
        .line = line,
    };
}

pub fn parseVer(s: []const u8) ?Ver {
    const dot = std.mem.indexOfScalar(u8, s, '.') orelse return null;
    const major = std.fmt.parseInt(u32, s[0..dot], 10) catch return null;
    const minor = std.fmt.parseInt(u32, s[dot + 1 ..], 10) catch return null;
    return .{ .major = major, .minor = minor };
}

/// The golden of `text`; null (with findings) when it has no readable first line.
pub fn parseGolden(a: Alloc, text: []const u8, f: *Findings) !?Golden {
    var it = std.mem.splitScalar(u8, text, '\n');
    const first = trim(it.next() orelse "");
    var ver: Ver = undefined;
    if (std.mem.startsWith(u8, first, "version\t")) {
        ver = parseVer(trim(first["version\t".len..])) orelse {
            try f.add("golden line 1: `{s}` is not `version<TAB><major>.<minor>`", .{first});
            return null;
        };
    } else {
        try f.add("golden line 1: `{s}` is not `version<TAB><major>.<minor>`", .{first});
        return null;
    }
    var rows = std.ArrayList(Row).empty;
    var consts = std.ArrayList(Const).empty;
    var n: usize = 1;
    while (it.next()) |raw| {
        n += 1;
        const l = trim(raw);
        if (l.len == 0 or l[0] == '#') continue;
        var fields = std.ArrayList([]const u8).empty;
        var fit = std.mem.splitScalar(u8, l, '\t');
        while (fit.next()) |x| try fields.append(a, trim(x));
        if (fields.items.len != 4) {
            try f.add("golden line {d}: {d} tab-separated fields, want 4 (symbol, return, arguments, since)", .{ n, fields.items.len });
            continue;
        }
        if (std.mem.eql(u8, fields.items[0], "constant")) {
            if (try parseConstRow(fields.items, n, f)) |c| {
                for (consts.items) |p| {
                    if (std.mem.eql(u8, p.name, c.name)) try f.add("golden line {d}: constant `{s}` is listed twice (first at line {d})", .{ n, c.name, p.line });
                }
                try consts.append(a, c);
            }
            continue;
        }
        const symbol = fields.items[0];
        if (!isIdent(symbol)) {
            try f.add("golden line {d}: `{s}` is not a C identifier", .{ n, symbol });
            continue;
        }
        const since = parseVer(fields.items[3]) orelse {
            try f.add("golden line {d}: {s}: since `{s}` is not `<major>.<minor>`", .{ n, symbol, fields.items[3] });
            continue;
        };
        var args = std.ArrayList([]const u8).empty;
        if (!std.mem.eql(u8, fields.items[2], "-")) {
            for (try splitTop(a, fields.items[2], ',')) |t| try args.append(a, try canonType(a, t));
        }
        try rows.append(a, .{
            .symbol = symbol,
            .ret = try canonType(a, fields.items[1]),
            .args = try args.toOwnedSlice(a),
            .since = since,
            .line = n,
        });
    }
    return Golden{ .version = ver, .rows = try rows.toOwnedSlice(a), .consts = try consts.toOwnedSlice(a) };
}

/// One `constant<TAB>NAME<TAB>VALUE<TAB>since` row (`fields` has four entries).
fn parseConstRow(fields: []const []const u8, n: usize, f: *Findings) !?Const {
    const name = fields[1];
    if (!isIdent(name) or !std.mem.startsWith(u8, name, const_prefix)) {
        try f.add("golden line {d}: constant `{s}` is not a C identifier starting with {s}", .{ n, name, const_prefix });
        return null;
    }
    for (reserved_consts) |r| {
        if (std.mem.eql(u8, name, r)) {
            try f.add("golden line {d}: constant `{s}` is defined by the header itself from the golden version", .{ n, name });
            return null;
        }
    }
    const value = std.fmt.parseInt(i128, fields[2], 10) catch {
        try f.add("golden line {d}: {s}: value `{s}` is not a decimal integer", .{ n, name, fields[2] });
        return null;
    };
    if (value < const_min or value > const_max) {
        try f.add("golden line {d}: {s}: value {d} is outside the header's range ({d} to {d})", .{ n, name, value, const_min, const_max });
        return null;
    }
    const since = parseVer(fields[3]) orelse {
        try f.add("golden line {d}: {s}: since `{s}` is not `<major>.<minor>`", .{ n, name, fields[3] });
        return null;
    };
    return Const{ .name = name, .value = value, .since = since, .line = n };
}

/// A constant read from the constants file.
pub const SrcConst = struct {
    name: []const u8,
    value: i128,
    line: usize,
};

const const_types = [_][]const u8{ "Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32", "UInt64", "Int", "UInt" };

/// The product of decimal integers (`64 * 1024 * 1024`, `-5`), or null.
fn evalProduct(s: []const u8) ?i128 {
    var acc: i128 = 1;
    var it = std.mem.splitScalar(u8, s, '*');
    while (it.next()) |raw| {
        const v = std.fmt.parseInt(i128, trim(raw), 10) catch return null;
        acc = std.math.mul(i128, acc, v) catch return null;
    }
    return acc;
}

/// The top-level `comptime KOMIRA_NAME: <integer type> = <product>` lines of
/// `text`. One whose value is not a product of integers is a finding: the tool
/// does not evaluate Mojo.
pub fn parseConstants(a: Alloc, text: []const u8, f: *Findings) ![]const SrcConst {
    var out = std.ArrayList(SrcConst).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (it.next()) |raw| {
        n += 1;
        if (!std.mem.startsWith(u8, raw, "comptime " ++ const_prefix)) continue;
        const rest = raw["comptime ".len..];
        const colon = std.mem.indexOfScalar(u8, rest, ':') orelse continue;
        const name = trim(rest[0..colon]);
        const eq = std.mem.indexOfScalar(u8, rest, '=') orelse continue;
        if (eq < colon) continue;
        const ty = trim(rest[colon + 1 .. eq]);
        var integer = false;
        for (const_types) |c| {
            if (std.mem.eql(u8, ty, c)) integer = true;
        }
        if (!integer) continue; // not an ABI constant
        const value = evalProduct(trim(stripComment(rest[eq + 1 ..]))) orelse {
            try f.add("constants line {d}: `{s}` is not a product of integers", .{ n, name });
            continue;
        };
        try out.append(a, .{ .name = name, .value = value, .line = n });
    }
    return out.toOwnedSlice(a);
}

/// Compare the golden's constants with the constants file's.
pub fn checkConstants(g: Golden, src: ?[]const SrcConst, f: *Findings) !void {
    for (g.consts) |c| {
        if (c.since.above(g.version)) {
            try f.add("golden line {d}: `{s}`: since {d}.{d} is above the golden version {d}.{d}", .{ c.line, c.name, c.since.major, c.since.minor, g.version.major, g.version.minor });
        }
    }
    const have = src orelse {
        if (g.consts.len > 0) try f.add("the golden lists {d} constants and the target has no constants_src to check them against", .{g.consts.len});
        return;
    };
    for (g.consts) |c| {
        var found: ?SrcConst = null;
        for (have) |s| {
            if (std.mem.eql(u8, s.name, c.name)) found = s;
        }
        const s = found orelse {
            try f.add("missing constant `{s}`: the golden lists it (line {d}) and the constants file has no such comptime", .{ c.name, c.line });
            continue;
        };
        if (s.value != c.value) try f.add("`{s}`: the value changed: golden {d}, source {d} (constants line {d})", .{ c.name, c.value, s.value, s.line });
    }
    for (have, 0..) |s, i| {
        for (have[0..i]) |p| {
            if (std.mem.eql(u8, p.name, s.name)) try f.add("constants line {d}: `{s}` is declared twice (first at line {d})", .{ s.line, s.name, p.line });
        }
        var listed = false;
        for (g.consts) |c| {
            if (std.mem.eql(u8, s.name, c.name)) listed = true;
        }
        if (!listed) try f.add("extra constant `{s}`: the constants file declares it (line {d}) and the golden has no row for it", .{ s.name, s.line });
    }
}

fn joinTypes(a: Alloc, ts: []const []const u8) ![]const u8 {
    if (ts.len == 0) return "()";
    return std.fmt.allocPrint(a, "({s})", .{try std.mem.join(a, ", ", ts)});
}

fn sameTypes(x: []const []const u8, y: []const []const u8) bool {
    if (x.len != y.len) return false;
    for (x, y) |p, q| {
        if (!std.mem.eql(u8, p, q)) return false;
    }
    return true;
}

fn checkTypes(a: Alloc, who: []const u8, symbol: []const u8, ret: []const u8, args: []const []const u8, f: *Findings) !void {
    _ = cReturnType(a, ret) catch |e| switch (e) {
        error.UnknownType => try f.add("{s}: `{s}`: the return type `{s}` is not in the type map", .{ who, symbol, ret }),
        else => return e,
    };
    for (args) |t| {
        _ = cValueType(a, t) catch |e| switch (e) {
            error.UnknownType => try f.add("{s}: `{s}`: the argument type `{s}` is not in the type map", .{ who, symbol, t }),
            else => return e,
        };
    }
}

/// Compare the source's functions with the golden; every difference is a finding.
pub fn check(a: Alloc, sigs: []const Sig, g: Golden, f: *Findings) !void {
    for (sigs, 0..) |s, i| {
        for (sigs[0..i]) |p| {
            if (std.mem.eql(u8, p.symbol, s.symbol)) try f.add("source line {d}: `{s}` is exported twice (first at line {d})", .{ s.line, s.symbol, p.line });
        }
        try checkTypes(a, "source", s.symbol, s.ret, s.args, f);
    }
    for (g.rows, 0..) |r, i| {
        for (g.rows[0..i]) |p| {
            if (std.mem.eql(u8, p.symbol, r.symbol)) try f.add("golden line {d}: `{s}` is listed twice (first at line {d})", .{ r.line, r.symbol, p.line });
        }
        try checkTypes(a, "golden", r.symbol, r.ret, r.args, f);
        if (r.since.above(g.version)) {
            try f.add("golden line {d}: `{s}`: since {d}.{d} is above the golden version {d}.{d}", .{ r.line, r.symbol, r.since.major, r.since.minor, g.version.major, g.version.minor });
        }
        var found: ?Sig = null;
        for (sigs) |s| {
            if (std.mem.eql(u8, s.symbol, r.symbol)) {
                found = s;
                break;
            }
        }
        const s = found orelse {
            try f.add("missing symbol `{s}`: the golden lists it (line {d}) and the source has no @export abi(\"C\") function of that name", .{ r.symbol, r.line });
            continue;
        };
        if (!std.mem.eql(u8, s.ret, r.ret)) {
            try f.add("`{s}`: the return type changed: golden `{s}`, source `{s}` (source line {d})", .{ r.symbol, r.ret, s.ret, s.line });
        }
        if (!sameTypes(s.args, r.args)) {
            try f.add("`{s}`: the argument types changed: golden {s}, source {s} (source line {d})", .{ r.symbol, try joinTypes(a, r.args), try joinTypes(a, s.args), s.line });
        }
    }
    for (sigs) |s| {
        var listed = false;
        for (g.rows) |r| {
            if (std.mem.eql(u8, s.symbol, r.symbol)) listed = true;
        }
        if (!listed) try f.add("extra symbol `{s}`: the source exports it (line {d}) and the golden has no row for it", .{ s.symbol, s.line });
    }
}

/// The include guard of a header file name: `komira.h` is `KOMIRA_H`.
pub fn guardName(a: Alloc, header_name: []const u8) ![]const u8 {
    const out = try a.alloc(u8, header_name.len);
    for (header_name, 0..) |c, i| out[i] = if (std.ascii.isAlphanumeric(c)) std.ascii.toUpper(c) else '_';
    return out;
}

/// The C header of `g`, whose types `check` found all in the type map.
pub fn header(a: Alloc, g: Golden, header_name: []const u8, golden_name: []const u8) ![]const u8 {
    var o = std.ArrayList(u8).empty;
    const w = o.writer(a);
    const guard = try guardName(a, header_name);
    try w.print("/* {s}: the C ABI of the library, version {d}.{d}.\n", .{ header_name, g.version.major, g.version.minor });
    try w.print(" * Generated from {s} by komira_abi_golden. Do not edit. */\n", .{golden_name});
    try w.print("#ifndef {s}\n#define {s}\n\n", .{ guard, guard });
    try w.writeAll("#include <stddef.h>\n#include <stdint.h>\n\n");
    try w.writeAll("#ifdef __cplusplus\nextern \"C\" {\n#endif\n\n");
    try w.print("#define KOMIRA_ABI_VERSION_MAJOR {d}\n#define KOMIRA_ABI_VERSION_MINOR {d}\n\n", .{ g.version.major, g.version.minor });
    for (g.consts) |c| {
        try w.print("/* since {d}.{d} */\n#define {s} ({d}{s})\n", .{ c.since.major, c.since.minor, c.name, c.value, if (c.value > 2147483647) "ULL" else "" });
    }
    if (g.consts.len > 0) try w.writeAll("\n");
    try w.writeAll("/* An opaque handle: never dereferenced by a caller. */\n");
    try w.writeAll("typedef struct komira_handle_s *komira_handle;\n\n");
    for (g.rows) |r| {
        const ret = try cReturnType(a, r.ret);
        try w.print("/* since {d}.{d} */\n", .{ r.since.major, r.since.minor });
        try w.print("{s}{s}{s}(", .{ ret, if (std.mem.endsWith(u8, ret, "*")) "" else " ", r.symbol });
        if (r.args.len == 0) try w.writeAll("void");
        for (r.args, 0..) |t, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll(try cValueType(a, t));
        }
        try w.writeAll(");\n");
    }
    try w.writeAll("\n#ifdef __cplusplus\n}\n#endif\n\n");
    try w.print("#endif /* {s} */\n", .{guard});
    return o.toOwnedSlice(a);
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len != 6 and argv.len != 7) die("usage: abi_golden <source.mojo> <golden.tsv> <out header> <label> <header name> [<constants.mojo>]", .{});
    const src_path = argv[1];
    const golden_path = argv[2];
    const out_path = argv[3];
    const label = argv[4];
    const header_name = argv[5];

    const src = std.fs.cwd().readFileAlloc(a, src_path, 1 << 26) catch |e| die("cannot read {s}: {s}", .{ src_path, @errorName(e) });
    const gtext = std.fs.cwd().readFileAlloc(a, golden_path, 1 << 26) catch |e| die("cannot read {s}: {s}", .{ golden_path, @errorName(e) });
    var f = Findings{ .a = a };
    const sigs = try parseSource(a, src, &f);
    const golden = try parseGolden(a, gtext, &f);
    var consts: ?[]const SrcConst = null;
    if (argv.len == 7) {
        const ctext = std.fs.cwd().readFileAlloc(a, argv[6], 1 << 26) catch |e| die("cannot read {s}: {s}", .{ argv[6], @errorName(e) });
        consts = try parseConstants(a, ctext, &f);
    }
    if (golden) |g| {
        try check(a, sigs, g, &f);
        try checkConstants(g, consts, &f);
    }
    if (golden == null or f.list.items.len > 0) {
        for (f.list.items) |m| std.debug.print("komira_abi_golden: {s}: {s}\n", .{ label, m });
        std.process.exit(1);
    }
    const text = try header(a, golden.?, header_name, std.fs.path.basename(golden_path));
    const out = std.fs.cwd().createFile(out_path, .{}) catch |e| die("cannot create {s}: {s}", .{ out_path, @errorName(e) });
    defer out.close();
    out.writeAll(text) catch |e| die("cannot write {s}: {s}", .{ out_path, @errorName(e) });
}
