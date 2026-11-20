//! komira_wheel: the `[project]` table of a pyproject.toml, the one source of a
//! wheel's METADATA (docs/design/python_package.md, decision 7).
//!
//! The file is read with a TOML subset, the one the package's pyproject uses:
//! `#` comments; the tables `[project]`, `[project.optional-dependencies]` and
//! `[project.urls]`; `key = value` with a bare or a basic-string ("...") key;
//! values that are a basic string, an array of basic strings, or an array of
//! inline tables of basic strings (`authors = [{ name = "..." }]`). Arrays may
//! span lines and end in a comma. Anything else (another table, a literal
//! string, a number, a boolean, a dotted key, a key given twice) is refused
//! with its line, so the file never says something the wheel does not carry.
//!
//! Every function that can refuse returns `error.Refused` and leaves the
//! reason in a `Diag`; only the command (komira_wheel.zig) turns that into an
//! exit, so the refusals are unit-tested in process.

const std = @import("std");
const Alloc = std.mem.Allocator;

/// The reason of the last refusal.
pub const Diag = struct {
    msg: []const u8 = "",
};

pub const Refused = error{Refused} || Alloc.Error;

pub fn refuse(d: *Diag, alloc: Alloc, comptime fmt: []const u8, args: anytype) Refused {
    d.msg = try std.fmt.allocPrint(alloc, fmt, args);
    return error.Refused;
}

pub const Extra = struct { name: []const u8, requires: []const []const u8 };
pub const Url = struct { label: []const u8, url: []const u8 };

/// What the wheel's METADATA is made from. The required keys are the ones the
/// wheel cannot be described without; the lists default to empty.
pub const Project = struct {
    name: []const u8,
    description: []const u8,
    readme: []const u8,
    requires_python: []const u8,
    license: []const u8,
    license_files: []const []const u8,
    authors: []const []const u8 = &.{},
    keywords: []const []const u8 = &.{},
    classifiers: []const []const u8 = &.{},
    dependencies: []const []const u8 = &.{},
    extras: []const Extra = &.{},
    urls: []const Url = &.{},
};

const Value = union(enum) {
    string: []const u8,
    strings: []const []const u8,
    tables: []const []const [2][]const u8,
};

const Pair = struct { key: []const u8, value: Value, line: usize };

const Parser = struct {
    alloc: Alloc,
    d: *Diag,
    src: []const u8,
    at: usize = 0,
    line: usize = 1,

    fn peek(p: *Parser) ?u8 {
        return if (p.at < p.src.len) p.src[p.at] else null;
    }

    fn bump(p: *Parser) void {
        if (p.src[p.at] == '\n') p.line += 1;
        p.at += 1;
    }

    /// Spaces and tabs only.
    fn blanks(p: *Parser) void {
        while (p.peek()) |c| {
            if (c != ' ' and c != '\t') break;
            p.bump();
        }
    }

    /// Spaces, tabs, newlines and comments: what may sit between the items of
    /// an array.
    fn gaps(p: *Parser) void {
        while (p.peek()) |c| {
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                p.bump();
            } else if (c == '#') {
                p.comment();
            } else break;
        }
    }

    fn comment(p: *Parser) void {
        while (p.peek()) |c| {
            if (c == '\n') break;
            p.bump();
        }
    }

    /// The end of a line: blanks, an optional comment, then a newline or the
    /// end of the file.
    fn endLine(p: *Parser) Refused!void {
        p.blanks();
        if (p.peek() == '#') p.comment();
        if (p.peek()) |c| {
            if (c == '\r' and p.at + 1 < p.src.len and p.src[p.at + 1] == '\n') p.bump();
            if (p.peek() != '\n') return refuse(p.d, p.alloc, "pyproject line {d}: unexpected `{c}` after a value", .{ p.line, p.peek().? });
            p.bump();
        }
    }

    fn string(p: *Parser) Refused![]const u8 {
        if (p.peek() != '"') return p.unsupported();
        p.bump();
        if (p.at + 1 < p.src.len and p.src[p.at] == '"' and p.src[p.at + 1] == '"')
            return refuse(p.d, p.alloc, "pyproject line {d}: a multi-line string is not read by the wheel rule", .{p.line});
        var out = std.ArrayList(u8).empty;
        while (true) {
            const c = p.peek() orelse return refuse(p.d, p.alloc, "pyproject line {d}: a string is not closed", .{p.line});
            if (c == '\n') return refuse(p.d, p.alloc, "pyproject line {d}: a string is not closed", .{p.line});
            p.bump();
            if (c == '"') break;
            if (c != '\\') {
                try out.append(p.alloc, c);
                continue;
            }
            const e = p.peek() orelse return refuse(p.d, p.alloc, "pyproject line {d}: a string is not closed", .{p.line});
            p.bump();
            switch (e) {
                '"' => try out.append(p.alloc, '"'),
                '\\' => try out.append(p.alloc, '\\'),
                else => return refuse(p.d, p.alloc, "pyproject line {d}: the escape `\\{c}` is not read by the wheel rule", .{ p.line, e }),
            }
        }
        return out.toOwnedSlice(p.alloc);
    }

    fn key(p: *Parser) Refused![]const u8 {
        if (p.peek() == '"') return p.string();
        const start = p.at;
        while (p.peek()) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) break;
            p.bump();
        }
        if (p.at == start) return p.unsupported();
        if (p.peek() == '.') return refuse(p.d, p.alloc, "pyproject line {d}: a dotted key is not read by the wheel rule", .{p.line});
        return p.src[start..p.at];
    }

    fn unsupported(p: *Parser) Refused {
        const c = p.peek() orelse return refuse(p.d, p.alloc, "pyproject line {d}: a value is missing", .{p.line});
        return refuse(p.d, p.alloc, "pyproject line {d}: a value starting `{c}` is not read by the wheel rule (it reads basic strings, arrays of them, and arrays of inline tables of them)", .{ p.line, c });
    }

    fn inlineTable(p: *Parser) Refused![]const [2][]const u8 {
        p.bump(); // {
        var pairs = std.ArrayList([2][]const u8).empty;
        p.blanks();
        if (p.peek() == '}') {
            p.bump();
            return pairs.toOwnedSlice(p.alloc);
        }
        while (true) {
            p.blanks();
            const k = try p.key();
            for (pairs.items) |kv| if (std.mem.eql(u8, kv[0], k))
                return refuse(p.d, p.alloc, "pyproject line {d}: `{s}` is given twice in an inline table", .{ p.line, k });
            p.blanks();
            if (p.peek() != '=') return refuse(p.d, p.alloc, "pyproject line {d}: `=` expected after `{s}`", .{ p.line, k });
            p.bump();
            p.blanks();
            try pairs.append(p.alloc, .{ k, try p.string() });
            p.blanks();
            const c = p.peek() orelse return refuse(p.d, p.alloc, "pyproject line {d}: an inline table is not closed", .{p.line});
            p.bump();
            if (c == '}') break;
            if (c != ',') return refuse(p.d, p.alloc, "pyproject line {d}: `,` or `}}` expected in an inline table", .{p.line});
        }
        return pairs.toOwnedSlice(p.alloc);
    }

    fn array(p: *Parser) Refused!Value {
        p.bump(); // [
        var strings = std.ArrayList([]const u8).empty;
        var tables = std.ArrayList([]const [2][]const u8).empty;
        while (true) {
            p.gaps();
            const c = p.peek() orelse return refuse(p.d, p.alloc, "pyproject line {d}: an array is not closed", .{p.line});
            if (c == ']') {
                p.bump();
                break;
            }
            if (c == '{') {
                if (strings.items.len != 0) return refuse(p.d, p.alloc, "pyproject line {d}: an array mixes strings and tables", .{p.line});
                try tables.append(p.alloc, try p.inlineTable());
            } else {
                if (tables.items.len != 0) return refuse(p.d, p.alloc, "pyproject line {d}: an array mixes strings and tables", .{p.line});
                try strings.append(p.alloc, try p.string());
            }
            p.gaps();
            const sep = p.peek() orelse return refuse(p.d, p.alloc, "pyproject line {d}: an array is not closed", .{p.line});
            if (sep == ',') {
                p.bump();
                continue;
            }
            if (sep != ']') return refuse(p.d, p.alloc, "pyproject line {d}: `,` or `]` expected in an array", .{p.line});
        }
        if (tables.items.len != 0) return .{ .tables = try tables.toOwnedSlice(p.alloc) };
        return .{ .strings = try strings.toOwnedSlice(p.alloc) };
    }

    fn value(p: *Parser) Refused!Value {
        const c = p.peek() orelse return p.unsupported();
        if (c == '[') return p.array();
        return .{ .string = try p.string() };
    }
};

const Table = enum { none, project, extras, urls };

const Tables = struct {
    project: std.ArrayList(Pair) = .empty,
    extras: std.ArrayList(Pair) = .empty,
    urls: std.ArrayList(Pair) = .empty,

    fn of(self: *Tables, t: Table) *std.ArrayList(Pair) {
        return switch (t) {
            .project => &self.project,
            .extras => &self.extras,
            .urls => &self.urls,
            .none => unreachable,
        };
    }
};

fn tableOf(name: []const u8) ?Table {
    if (std.mem.eql(u8, name, "project")) return .project;
    if (std.mem.eql(u8, name, "project.optional-dependencies")) return .extras;
    if (std.mem.eql(u8, name, "project.urls")) return .urls;
    return null;
}

fn parseTables(alloc: Alloc, d: *Diag, src: []const u8) Refused!Tables {
    var p = Parser{ .alloc = alloc, .d = d, .src = src };
    var t = Tables{};
    var seen = [_]bool{false} ** 4;
    var cur: Table = .none;
    while (true) {
        p.gaps();
        const c = p.peek() orelse break;
        if (c == '[') {
            const line = p.line;
            p.bump();
            if (p.peek() == '[') return refuse(d, alloc, "pyproject line {d}: an array of tables is not read by the wheel rule", .{line});
            const start = p.at;
            while (p.peek()) |h| {
                if (h == ']' or h == '\n') break;
                p.bump();
            }
            if (p.peek() != ']') return refuse(d, alloc, "pyproject line {d}: a table header is not closed", .{line});
            const name = std.mem.trim(u8, src[start..p.at], " \t");
            p.bump();
            try p.endLine();
            cur = tableOf(name) orelse return refuse(d, alloc, "pyproject line {d}: the table [{s}] is not read by the wheel rule (it reads [project], [project.optional-dependencies] and [project.urls]; the wheel is built by a Buck2 rule, not a build backend)", .{ line, name });
            if (seen[@intFromEnum(cur)]) return refuse(d, alloc, "pyproject line {d}: the table [{s}] is given twice", .{ line, name });
            seen[@intFromEnum(cur)] = true;
            continue;
        }
        const line = p.line;
        if (cur == .none) return refuse(d, alloc, "pyproject line {d}: a key outside any table", .{line});
        const k = try p.key();
        p.blanks();
        if (p.peek() != '=') return refuse(d, alloc, "pyproject line {d}: `=` expected after `{s}`", .{ line, k });
        p.bump();
        p.blanks();
        const v = try p.value();
        try p.endLine();
        const list = t.of(cur);
        for (list.items) |prev| if (std.mem.eql(u8, prev.key, k))
            return refuse(d, alloc, "pyproject line {d}: `{s}` is given twice (first on line {d})", .{ line, k, prev.line });
        try list.append(alloc, .{ .key = k, .value = v, .line = line });
    }
    return t;
}

fn wantString(d: *Diag, alloc: Alloc, pr: Pair) Refused![]const u8 {
    if (pr.value != .string) return refuse(d, alloc, "pyproject line {d}: `{s}` must be a string", .{ pr.line, pr.key });
    return pr.value.string;
}

fn wantStrings(d: *Diag, alloc: Alloc, pr: Pair) Refused![]const []const u8 {
    return switch (pr.value) {
        .strings => |s| s,
        .tables, .string => refuse(d, alloc, "pyproject line {d}: `{s}` must be an array of strings", .{ pr.line, pr.key }),
    };
}

/// A header value of METADATA is one line: a value holding a newline or a
/// carriage return would start a second field.
fn oneLine(d: *Diag, alloc: Alloc, what: []const u8, s: []const u8) Refused![]const u8 {
    if (s.len == 0) return refuse(d, alloc, "pyproject: `{s}` is empty", .{what});
    if (std.mem.indexOfAny(u8, s, "\r\n") != null) return refuse(d, alloc, "pyproject: `{s}` holds a line break", .{what});
    return s;
}

/// A distribution or extra name in its normalised form (PEP 503, PEP 685):
/// lowercase letters and digits, single `-` between them. Any other spelling
/// is refused rather than rewritten, so the file states the name the wheel has.
pub fn normalName(s: []const u8) bool {
    if (s.len == 0 or s[0] == '-' or s[s.len - 1] == '-') return false;
    for (s, 0..) |c, i| {
        if (c == '-') {
            if (s[i - 1] == '-') return false;
            continue;
        }
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c))) return false;
    }
    return true;
}

const project_keys = [_][]const u8{
    "authors",     "classifiers",   "dependencies", "description",     "dynamic",
    "keywords",    "license",       "license-files", "name",           "readme",
    "requires-python",
};

/// The `[project]` of `src`, every key checked; a key the wheel rule does not
/// read is refused, as is a required one missing.
pub fn parse(alloc: Alloc, d: *Diag, src: []const u8) Refused!Project {
    const t = try parseTables(alloc, d, src);
    var name: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var readme: ?[]const u8 = null;
    var requires_python: ?[]const u8 = null;
    var license: ?[]const u8 = null;
    var license_files: ?[]const []const u8 = null;
    var dynamic_ok = false;
    var pr = Project{ .name = "", .description = "", .readme = "", .requires_python = "", .license = "", .license_files = &.{} };
    for (t.project.items) |kv| {
        const k = kv.key;
        if (std.mem.eql(u8, k, "name")) {
            name = try oneLine(d, alloc, k, try wantString(d, alloc, kv));
        } else if (std.mem.eql(u8, k, "description")) {
            description = try oneLine(d, alloc, k, try wantString(d, alloc, kv));
        } else if (std.mem.eql(u8, k, "readme")) {
            readme = try wantString(d, alloc, kv);
        } else if (std.mem.eql(u8, k, "requires-python")) {
            requires_python = try oneLine(d, alloc, k, try wantString(d, alloc, kv));
        } else if (std.mem.eql(u8, k, "license")) {
            license = try oneLine(d, alloc, k, try wantString(d, alloc, kv));
        } else if (std.mem.eql(u8, k, "license-files")) {
            license_files = try wantStrings(d, alloc, kv);
        } else if (std.mem.eql(u8, k, "dynamic")) {
            const dyn = try wantStrings(d, alloc, kv);
            if (dyn.len != 1 or !std.mem.eql(u8, dyn[0], "version"))
                return refuse(d, alloc, "pyproject line {d}: `dynamic` must be exactly [\"version\"]: the wheel rule stamps the version and states every other field from the file", .{kv.line});
            dynamic_ok = true;
        } else if (std.mem.eql(u8, k, "authors")) {
            if (kv.value != .tables) return refuse(d, alloc, "pyproject line {d}: `authors` must be an array of inline tables", .{kv.line});
            var names = std.ArrayList([]const u8).empty;
            for (kv.value.tables) |tb| {
                if (tb.len != 1 or !std.mem.eql(u8, tb[0][0], "name"))
                    return refuse(d, alloc, "pyproject line {d}: an author must be exactly {{ name = \"...\" }} (the wheel rule writes no e-mail address)", .{kv.line});
                const n = try oneLine(d, alloc, "authors", tb[0][1]);
                if (std.mem.indexOfScalar(u8, n, ',') != null) return refuse(d, alloc, "pyproject line {d}: an author name holds `,`, which separates authors in METADATA", .{kv.line});
                try names.append(alloc, n);
            }
            pr.authors = try names.toOwnedSlice(alloc);
        } else if (std.mem.eql(u8, k, "keywords")) {
            pr.keywords = try wantStrings(d, alloc, kv);
            for (pr.keywords) |w| if (std.mem.indexOfScalar(u8, try oneLine(d, alloc, k, w), ',') != null)
                return refuse(d, alloc, "pyproject line {d}: the keyword `{s}` holds `,`, which separates keywords in METADATA", .{ kv.line, w });
        } else if (std.mem.eql(u8, k, "classifiers")) {
            pr.classifiers = try wantStrings(d, alloc, kv);
            for (pr.classifiers) |c| _ = try oneLine(d, alloc, k, c);
        } else if (std.mem.eql(u8, k, "dependencies")) {
            pr.dependencies = try wantStrings(d, alloc, kv);
            for (pr.dependencies) |r| _ = try oneLine(d, alloc, k, r);
        } else {
            return refuse(d, alloc, "pyproject line {d}: `{s}` of [project] is not read by the wheel rule, so the wheel would not carry it (it reads: {s})", .{ kv.line, k, try std.mem.join(alloc, ", ", &project_keys) });
        }
    }
    var extras = std.ArrayList(Extra).empty;
    for (t.extras.items) |kv| {
        if (!normalName(kv.key)) return refuse(d, alloc, "pyproject line {d}: the extra `{s}` is not a normalised name (lowercase letters, digits, single `-`)", .{ kv.line, kv.key });
        const reqs = try wantStrings(d, alloc, kv);
        for (reqs) |r| if (std.mem.indexOfScalar(u8, try oneLine(d, alloc, kv.key, r), ';') != null)
            return refuse(d, alloc, "pyproject line {d}: the requirement `{s}` of the extra `{s}` has a marker; the wheel rule writes the extra's marker itself and reads none in the file", .{ kv.line, r, kv.key });
        try extras.append(alloc, .{ .name = kv.key, .requires = reqs });
    }
    std.mem.sort(Extra, extras.items, {}, struct {
        fn less(_: void, a: Extra, b: Extra) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    pr.extras = try extras.toOwnedSlice(alloc);
    var urls = std.ArrayList(Url).empty;
    for (t.urls.items) |kv| {
        const label = try oneLine(d, alloc, "a label of [project.urls]", kv.key);
        if (std.mem.indexOfScalar(u8, label, ',') != null) return refuse(d, alloc, "pyproject line {d}: the URL label `{s}` holds `,`, which ends the label in METADATA", .{ kv.line, label });
        try urls.append(alloc, .{ .label = label, .url = try oneLine(d, alloc, label, try wantString(d, alloc, kv)) });
    }
    pr.urls = try urls.toOwnedSlice(alloc);

    pr.name = name orelse return refuse(d, alloc, "pyproject: [project] has no `name`", .{});
    if (!normalName(pr.name)) return refuse(d, alloc, "pyproject: the name `{s}` is not a normalised name (lowercase letters, digits, single `-`)", .{pr.name});
    pr.description = description orelse return refuse(d, alloc, "pyproject: [project] has no `description`", .{});
    pr.readme = readme orelse return refuse(d, alloc, "pyproject: [project] has no `readme`", .{});
    pr.requires_python = requires_python orelse return refuse(d, alloc, "pyproject: [project] has no `requires-python`", .{});
    pr.license = license orelse return refuse(d, alloc, "pyproject: [project] has no `license` (an SPDX expression)", .{});
    pr.license_files = license_files orelse return refuse(d, alloc, "pyproject: [project] has no `license-files`", .{});
    if (pr.license_files.len == 0) return refuse(d, alloc, "pyproject: `license-files` is empty, and a wheel without its licence text is refused", .{});
    if (!dynamic_ok) return refuse(d, alloc, "pyproject: [project] has no `dynamic = [\"version\"]`: the wheel rule stamps the version", .{});
    return pr;
}
