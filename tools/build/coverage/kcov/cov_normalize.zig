//! cov_normalize: one kcov Cobertura report, rewritten to repository paths
//! with bytes that do not depend on the run.
//!
//! usage: cov_normalize --in <report.xml> --out <file>
//!            --map <ABS>=<REPO>...          (at least one)
//!            [--exclude <PREFIX>]...
//!            --must-contain <REPO_PATH>...  (at least one)
//!            [--forbid <S>]...
//!
//! The report is kcov's, written with `--configure=cobertura-full-paths=1`, so
//! every `<class filename=...>` is an absolute path. Each is, in this order:
//!   1. dropped when it starts with an --exclude PREFIX (counted on stderr);
//!   2. rewritten by the longest --map ABS it starts with: ABS is replaced by
//!      REPO, giving a path relative to the repository root;
//!   3. otherwise refused: an unmapped file is a report the caller did not
//!      expect, and passing it through would hand covcheck a path that names
//!      nothing.
//! ABS and PREFIX are absolute and end with '/', so a prefix matches whole
//! directory names only; REPO is empty (the repository root) or a relative
//! directory ending with '/'.
//!
//! The output is canonical Cobertura, the subset covcheck reads
//! (tools/build/coverage): the XML declaration, `<coverage timestamp="0">`
//! with no rate attributes, `<sources><source>.</source></sources>`, one
//! `<package name="">`, one `<class>` per repository path sorted bytewise
//! (classes that map to the same path are merged), and `<line number hits>`
//! sorted by number. Hits are clamped to 0 or 1, so the bytes do not depend on
//! how often a line ran. A line's `branch` attribute is kept: `true` with its
//! `condition-coverage` "NN% (k/n)", or `false`. Merging two lines: hits 1 if
//! either is 1; `true` wins over `false` over none; two `true` with the same n
//! keep the larger k, and two with different n are refused.
//!
//! Refused, exit 1, with no output written: a malformed report (the same
//! refusals as covcheck's reader: text outside the root, an unclosed or
//! mismatched tag, an unquoted, valueless or repeated attribute, an unknown
//! entity, `<!` markup other than a comment or a DOCTYPE without an internal
//! subset, a root other than <coverage>, a second root, a <class> inside a
//! <class> or without a filename, a <line> without number or hits, a value
//! that is not a decimal number, a line number of 0 or above 10^9, a bad
//! branch or condition-coverage), an unmapped file name, a mapped path that is
//! not a clean relative path (an empty, '.' or '..' segment) or holds a
//! control byte or is not UTF-8, a --must-contain path with no class in the
//! output or whose class has no line, and an output holding any --forbid
//! string, as given or escaped as the output writes it. Every output path is
//! relative and clean (the mapping and the check above), so an absolute
//! sandbox path cannot be one; --forbid (the caller passes its own working
//! directory) is the backstop against one appearing inside a path.
//!
//! The output is written through a temporary file renamed over <file>, so a
//! failed write leaves no file.
//!
//! Exit status: 0 written; 1 refused; 2 bad usage.
//!
//! A static executable: it runs with no shell, no PATH and no network.

const std = @import("std");
const Alloc = std.mem.Allocator;

const usage =
    \\usage: cov_normalize --in <report.xml> --out <file> --map <ABS>=<REPO>...
    \\           [--exclude <PREFIX>]... --must-contain <REPO_PATH>... [--forbid <S>]...
    \\
;

const max_report = 1 << 30;
const max_line: u64 = 1_000_000_000;
const max_branches: u64 = 4096;

fn usageFail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("cov_normalize: " ++ fmt ++ "\n" ++ usage, args);
    std.process.exit(2);
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("cov_normalize: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn oom() noreturn {
    fail("out of memory", .{});
}

// ---- the report ------------------------------------------------------------

const Branch = union(enum) {
    none,
    false_,
    true_: struct { k: u64, n: u64 },
};

const Line = struct {
    number: u64,
    hits: u1,
    branch: Branch,
};

const Class = struct {
    filename: []const u8,
    lines: std.ArrayList(Line),
};

const Attr = struct {
    name: []const u8,
    value: []const u8,
};

const Reader = struct {
    alloc: Alloc,
    path: []const u8,
    b: []const u8,

    fn lineOf(self: *const Reader, at: usize) usize {
        var n: usize = 1;
        for (self.b[0..@min(at, self.b.len)]) |c| {
            if (c == '\n') n += 1;
        }
        return n;
    }

    fn bad(self: *const Reader, at: usize, comptime fmt: []const u8, args: anytype) noreturn {
        std.debug.print("cov_normalize: {s}:{d}: ", .{ self.path, self.lineOf(at) });
        std.debug.print(fmt ++ "\n", args);
        std.process.exit(1);
    }

    fn startsAt(self: *const Reader, at: usize, s: []const u8) bool {
        return std.mem.startsWith(u8, self.b[at..], s);
    }

    fn find(self: *const Reader, at: usize, s: []const u8) ?usize {
        return std.mem.indexOfPos(u8, self.b, at, s);
    }

    fn unescape(self: *const Reader, at: usize, v: []const u8) []const u8 {
        if (std.mem.indexOfScalar(u8, v, '&') == null) return v;
        var out = std.ArrayList(u8).init(self.alloc);
        var i: usize = 0;
        while (i < v.len) {
            if (v[i] != '&') {
                out.append(v[i]) catch oom();
                i += 1;
                continue;
            }
            const semi = std.mem.indexOfScalarPos(u8, v, i, ';') orelse self.bad(at, "an '&' with no ';' in an attribute value", .{});
            const ent = v[i + 1 .. semi];
            const c = entity(ent) orelse self.bad(at, "unknown entity '&{s};'", .{ent});
            out.append(c) catch oom();
            i = semi + 1;
        }
        return out.items;
    }

    fn number(self: *const Reader, at: usize, attrs: []const Attr, name: []const u8, tag: []const u8) u64 {
        const v = attrValue(attrs, name) orelse self.bad(at, "<{s}> has no {s}", .{ tag, name });
        return self.decimal(at, v, name);
    }

    fn decimal(self: *const Reader, at: usize, v: []const u8, what: []const u8) u64 {
        if (v.len == 0 or v.len > 18) self.bad(at, "{s} '{s}' is not a decimal number", .{ what, v });
        for (v) |c| {
            if (c < '0' or c > '9') self.bad(at, "{s} '{s}' is not a decimal number", .{ what, v });
        }
        return std.fmt.parseInt(u64, v, 10) catch self.bad(at, "{s} '{s}' is not a decimal number", .{ what, v });
    }

    /// "NN% (k/n)" as k and n.
    fn condition(self: *const Reader, at: usize, v: []const u8) Branch {
        const pct = std.mem.indexOfScalar(u8, v, '%') orelse self.bad(at, "condition-coverage '{s}' is not 'NN% (k/n)'", .{v});
        _ = self.decimal(at, v[0..pct], "condition-coverage");
        const rest = v[pct + 1 ..];
        if (!std.mem.startsWith(u8, rest, " (") or !std.mem.endsWith(u8, rest, ")"))
            self.bad(at, "condition-coverage '{s}' is not 'NN% (k/n)'", .{v});
        const inner = rest[2 .. rest.len - 1];
        const slash = std.mem.indexOfScalar(u8, inner, '/') orelse self.bad(at, "condition-coverage '{s}' is not 'NN% (k/n)'", .{v});
        const k = self.decimal(at, inner[0..slash], "condition-coverage");
        const n = self.decimal(at, inner[slash + 1 ..], "condition-coverage");
        if (n == 0 or k > n) self.bad(at, "condition-coverage '{s}' is not 'NN% (k/n)' with 0 <= k <= n, n > 0", .{v});
        if (n > max_branches) self.bad(at, "condition-coverage '{s}' claims more than {d} branches on one line", .{ v, max_branches });
        return .{ .true_ = .{ .k = k, .n = n } };
    }

    /// The classes of the report, in document order.
    fn read(self: *const Reader) []Class {
        const b = self.b;
        const n = b.len;
        var stack = std.ArrayList([]const u8).init(self.alloc);
        var classes = std.ArrayList(Class).init(self.alloc);
        var current: ?Class = null;
        var saw_root = false;
        var i: usize = 0;
        while (i < n) {
            if (b[i] != '<') {
                if (stack.items.len == 0 and !isSpace(b[i])) self.bad(i, "text outside the root element", .{});
                i += 1;
                continue;
            }
            const start = i;
            if (self.startsAt(i, "<?")) {
                const e = self.find(i + 2, "?>") orelse self.bad(start, "unterminated <?", .{});
                i = e + 2;
                continue;
            }
            if (self.startsAt(i, "<!--")) {
                const e = self.find(i + 4, "-->") orelse self.bad(start, "unterminated comment", .{});
                i = e + 3;
                continue;
            }
            if (self.startsAt(i, "<!DOCTYPE")) {
                const e = self.find(i, ">") orelse self.bad(start, "unterminated DOCTYPE", .{});
                if (std.mem.indexOfScalar(u8, b[i..e], '[') != null) self.bad(start, "a DOCTYPE with an internal subset", .{});
                i = e + 1;
                continue;
            }
            if (i + 1 < n and b[i + 1] == '!') self.bad(start, "unsupported markup '<!' (CDATA is not read)", .{});
            if (i + 1 < n and b[i + 1] == '/') {
                var j = i + 2;
                while (j < n and !isNameEnd(b[j])) j += 1;
                const name = b[i + 2 .. j];
                while (j < n and isSpace(b[j])) j += 1;
                if (j >= n or b[j] != '>') self.bad(start, "unterminated end tag </{s}", .{name});
                if (stack.items.len == 0) self.bad(start, "</{s}> closes nothing", .{name});
                const top = stack.items[stack.items.len - 1];
                if (!std.mem.eql(u8, top, name)) self.bad(start, "</{s}> closes <{s}>", .{ name, top });
                _ = stack.pop();
                if (std.mem.eql(u8, name, "class")) {
                    classes.append(current.?) catch oom();
                    current = null;
                }
                i = j + 1;
                continue;
            }
            // A start tag.
            var j = i + 1;
            while (j < n and !isNameEnd(b[j])) j += 1;
            const tag = b[i + 1 .. j];
            if (tag.len == 0) self.bad(start, "a tag with no name", .{});
            var attrs = std.ArrayList(Attr).init(self.alloc);
            var self_closing = false;
            while (true) {
                while (j < n and isSpace(b[j])) j += 1;
                if (j >= n or b[j] == '<') self.bad(start, "unterminated tag <{s}", .{tag});
                if (b[j] == '>') {
                    j += 1;
                    break;
                }
                if (b[j] == '/') {
                    if (j + 1 < n and b[j + 1] == '>') {
                        self_closing = true;
                        j += 2;
                        break;
                    }
                    self.bad(j, "'/' not followed by '>' in <{s}", .{tag});
                }
                const a0 = j;
                while (j < n and !isNameEnd(b[j])) j += 1;
                const aname = b[a0..j];
                if (aname.len == 0) self.bad(j, "malformed attribute in <{s}", .{tag});
                while (j < n and isSpace(b[j])) j += 1;
                if (j >= n or b[j] != '=') self.bad(a0, "attribute {s} of <{s}> has no value", .{ aname, tag });
                j += 1;
                while (j < n and isSpace(b[j])) j += 1;
                if (j >= n or (b[j] != '"' and b[j] != '\'')) self.bad(a0, "attribute {s} of <{s}> is not quoted", .{ aname, tag });
                const q = b[j];
                const v0 = j + 1;
                const v1 = std.mem.indexOfScalarPos(u8, b, v0, q) orelse self.bad(a0, "unterminated value of {s} in <{s}", .{ aname, tag });
                if (attrValue(attrs.items, aname) != null) self.bad(a0, "attribute {s} of <{s}> is given twice", .{ aname, tag });
                attrs.append(.{ .name = aname, .value = self.unescape(a0, b[v0..v1]) }) catch oom();
                j = v1 + 1;
            }
            if (stack.items.len == 0) {
                if (saw_root) self.bad(start, "a second root element <{s}>", .{tag});
                if (!std.mem.eql(u8, tag, "coverage")) self.bad(start, "the root element is <{s}>, not <coverage>", .{tag});
                saw_root = true;
            }
            const depth = stack.items.len;
            const parent: []const u8 = if (depth >= 1) stack.items[depth - 1] else "";
            const grandparent: []const u8 = if (depth >= 2) stack.items[depth - 2] else "";
            if (std.mem.eql(u8, tag, "class")) {
                if (current != null) self.bad(start, "<class> inside <class>", .{});
                const f = attrValue(attrs.items, "filename") orelse "";
                if (f.len == 0) self.bad(start, "<class> has no filename", .{});
                current = .{ .filename = f, .lines = std.ArrayList(Line).init(self.alloc) };
                if (self_closing) {
                    classes.append(current.?) catch oom();
                    current = null;
                }
            } else if (std.mem.eql(u8, tag, "line") and std.mem.eql(u8, parent, "lines") and std.mem.eql(u8, grandparent, "class")) {
                // A <method>'s <lines> repeat the class's: only these are read.
                const num = self.number(start, attrs.items, "number", tag);
                if (num == 0) self.bad(start, "<line> number 0 (lines start at 1)", .{});
                if (num > max_line) self.bad(start, "<line> number {d} is above 10^9", .{num});
                const hits = self.number(start, attrs.items, "hits", tag);
                var br: Branch = .none;
                if (attrValue(attrs.items, "branch")) |bv| {
                    if (std.mem.eql(u8, bv, "true")) {
                        const cc = attrValue(attrs.items, "condition-coverage") orelse self.bad(start, "a branch line has no condition-coverage", .{});
                        br = self.condition(start, cc);
                    } else if (std.mem.eql(u8, bv, "false")) {
                        br = .false_;
                    } else {
                        self.bad(start, "<line> branch='{s}' is not true or false", .{bv});
                    }
                }
                current.?.lines.append(.{ .number = num, .hits = if (hits > 0) 1 else 0, .branch = br }) catch oom();
            }
            if (!self_closing) stack.append(tag) catch oom();
            i = j;
        }
        if (!saw_root) self.bad(n, "no <coverage> element", .{});
        if (stack.items.len > 0) self.bad(n, "<{s}> is never closed", .{stack.items[stack.items.len - 1]});
        return classes.items;
    }
};

/// The byte an XML predefined entity names; numeric references are not read.
fn entity(name: []const u8) ?u8 {
    const table = [_]struct { []const u8, u8 }{
        .{ "amp", '&' },
        .{ "lt", '<' },
        .{ "gt", '>' },
        .{ "quot", '"' },
        .{ "apos", '\'' },
    };
    for (table) |e| {
        if (std.mem.eql(u8, name, e[0])) return e[1];
    }
    return null;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isNameEnd(c: u8) bool {
    return isSpace(c) or c == '>' or c == '/' or c == '=' or c == '<';
}

fn attrValue(attrs: []const Attr, name: []const u8) ?[]const u8 {
    for (attrs) |a| {
        if (std.mem.eql(u8, a.name, name)) return a.value;
    }
    return null;
}

// ---- mapping and merging ---------------------------------------------------

const Map = struct {
    abs: []const u8,
    repo: []const u8,
};

/// The repository path of `filename`, or null when no --map covers it.
fn mapPath(alloc: Alloc, maps: []const Map, filename: []const u8) ?[]const u8 {
    var best: ?Map = null;
    for (maps) |m| {
        if (std.mem.startsWith(u8, filename, m.abs) and (best == null or m.abs.len > best.?.abs.len)) best = m;
    }
    const m = best orelse return null;
    const out = std.mem.concat(alloc, u8, &.{ m.repo, filename[m.abs.len..] }) catch oom();
    return out;
}

/// Refuses a repository path that is not clean: empty, absolute, with an
/// empty, '.' or '..' segment, or holding a control byte.
fn checkRepoPath(filename: []const u8, repo: []const u8) void {
    if (repo.len == 0 or repo[0] == '/' or repo[repo.len - 1] == '/')
        fail("'{s}' maps to '{s}', which is not a relative file path", .{ filename, repo });
    var it = std.mem.splitScalar(u8, repo, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, ".."))
            fail("'{s}' maps to '{s}', which has an empty, '.' or '..' segment", .{ filename, repo });
    }
    for (repo) |c| {
        if (c < 0x20 or c == 0x7f) fail("'{s}' maps to a path holding control byte 0x{x:0>2}", .{ filename, c });
    }
    // covcheck decodes a file name lossily: a byte that is not UTF-8 would
    // name another file there.
    if (!std.unicode.utf8ValidateSlice(repo)) fail("'{s}' maps to '{s}', which is not UTF-8", .{ filename, repo });
}

fn lineLess(_: void, a: Line, b: Line) bool {
    return a.number < b.number;
}

fn mergeBranch(repo: []const u8, number: u64, a: Branch, b: Branch) Branch {
    return switch (a) {
        .none => b,
        .false_ => switch (b) {
            .true_ => b,
            else => a,
        },
        .true_ => |x| switch (b) {
            .true_ => |y| blk: {
                if (x.n != y.n) fail("{s}:{d}: two reports of the line give {d} and {d} branches", .{ repo, number, x.n, y.n });
                break :blk Branch{ .true_ = .{ .k = @max(x.k, y.k), .n = x.n } };
            },
            else => a,
        },
    };
}

const Out = struct {
    repo: []const u8,
    lines: []Line,
};

fn outLess(_: void, a: Out, b: Out) bool {
    return std.mem.lessThan(u8, a.repo, b.repo);
}

/// The lines of one class sorted by number, each number once.
fn mergeLines(alloc: Alloc, repo: []const u8, lines: []Line) []Line {
    std.mem.sort(Line, lines, {}, lineLess);
    var out = std.ArrayList(Line).init(alloc);
    for (lines) |l| {
        if (out.items.len > 0 and out.items[out.items.len - 1].number == l.number) {
            const last = &out.items[out.items.len - 1];
            last.hits |= l.hits;
            last.branch = mergeBranch(repo, l.number, last.branch, l.branch);
        } else {
            out.append(l) catch oom();
        }
    }
    return out.items;
}

// ---- writing ---------------------------------------------------------------

fn writeEscaped(w: anytype, s: []const u8) void {
    for (s) |c| {
        const one = [1]u8{c};
        const r: []const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&apos;",
            else => &one,
        };
        w.writeAll(r) catch oom();
    }
}

fn render(alloc: Alloc, classes: []const Out) []const u8 {
    var buf = std.ArrayList(u8).init(alloc);
    const w = buf.writer();
    w.writeAll("<?xml version=\"1.0\" ?>\n" ++
        "<coverage timestamp=\"0\">\n" ++
        "\t<sources>\n" ++
        "\t\t<source>.</source>\n" ++
        "\t</sources>\n" ++
        "\t<packages>\n" ++
        "\t\t<package name=\"\">\n" ++
        "\t\t\t<classes>\n") catch oom();
    for (classes) |c| {
        w.writeAll("\t\t\t\t<class name=\"") catch oom();
        writeEscaped(w, c.repo);
        w.writeAll("\" filename=\"") catch oom();
        writeEscaped(w, c.repo);
        w.writeAll("\">\n\t\t\t\t\t<lines>\n") catch oom();
        for (c.lines) |l| {
            w.print("\t\t\t\t\t\t<line number=\"{d}\" hits=\"{d}\"", .{ l.number, l.hits }) catch oom();
            switch (l.branch) {
                .none => {},
                .false_ => w.writeAll(" branch=\"false\"") catch oom(),
                .true_ => |x| w.print(" branch=\"true\" condition-coverage=\"{d}% ({d}/{d})\"", .{ x.k * 100 / x.n, x.k, x.n }) catch oom(),
            }
            w.writeAll("/>\n") catch oom();
        }
        w.writeAll("\t\t\t\t\t</lines>\n\t\t\t\t</class>\n") catch oom();
    }
    w.writeAll("\t\t\t</classes>\n" ++
        "\t\t</package>\n" ++
        "\t</packages>\n" ++
        "</coverage>\n") catch oom();
    return buf.items;
}

/// Writes `bytes` to `path` through a temporary file renamed over it, so a
/// failed write leaves no file, partial or temporary: the error is returned,
/// and the deferred `deinit` removes the temporary file.
fn writeOut(path: []const u8, bytes: []const u8) !void {
    var af = try std.fs.cwd().atomicFile(path, .{});
    defer af.deinit();
    try af.file.writeAll(bytes);
    try af.finish();
}

// ---- main ------------------------------------------------------------------

pub fn main() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    const argv = std.process.argsAlloc(alloc) catch oom();

    var in_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var maps = std.ArrayList(Map).init(alloc);
    var excludes = std.ArrayList([]const u8).init(alloc);
    var musts = std.ArrayList([]const u8).init(alloc);
    var forbids = std.ArrayList([]const u8).init(alloc);
    var a: usize = 1;
    while (a < argv.len) : (a += 2) {
        const flag = argv[a];
        if (a + 1 >= argv.len) usageFail("{s} has no value", .{flag});
        const v: []const u8 = argv[a + 1];
        if (std.mem.eql(u8, flag, "--in")) {
            if (in_path != null) usageFail("--in given twice", .{});
            in_path = v;
        } else if (std.mem.eql(u8, flag, "--out")) {
            if (out_path != null) usageFail("--out given twice", .{});
            out_path = v;
        } else if (std.mem.eql(u8, flag, "--map")) {
            const eq = std.mem.indexOfScalar(u8, v, '=') orelse usageFail("--map '{s}' is not ABS=REPO", .{v});
            const abs = v[0..eq];
            const repo = v[eq + 1 ..];
            if (abs.len < 2 or abs[0] != '/' or abs[abs.len - 1] != '/') usageFail("--map ABS '{s}' must be absolute and end with '/'", .{abs});
            if (repo.len > 0 and (repo[0] == '/' or repo[repo.len - 1] != '/')) usageFail("--map REPO '{s}' must be empty or relative and end with '/'", .{repo});
            for (maps.items) |m| {
                if (std.mem.eql(u8, m.abs, abs)) usageFail("--map ABS '{s}' given twice", .{abs});
            }
            maps.append(.{ .abs = abs, .repo = repo }) catch oom();
        } else if (std.mem.eql(u8, flag, "--exclude")) {
            if (v.len < 2 or v[0] != '/' or v[v.len - 1] != '/') usageFail("--exclude '{s}' must be absolute and end with '/'", .{v});
            excludes.append(v) catch oom();
        } else if (std.mem.eql(u8, flag, "--must-contain")) {
            if (v.len == 0 or v[0] == '/') usageFail("--must-contain '{s}' must be a repository path", .{v});
            musts.append(v) catch oom();
        } else if (std.mem.eql(u8, flag, "--forbid")) {
            if (v.len == 0) usageFail("--forbid is empty", .{});
            forbids.append(v) catch oom();
        } else {
            usageFail("unknown flag '{s}'", .{flag});
        }
    }
    const in_file = in_path orelse usageFail("--in is required", .{});
    const out_file = out_path orelse usageFail("--out is required", .{});
    if (maps.items.len == 0) usageFail("at least one --map is required", .{});
    if (musts.items.len == 0) usageFail("at least one --must-contain is required", .{});

    const text = std.fs.cwd().readFileAlloc(alloc, in_file, max_report) catch |err| fail("{s}: {s}", .{ in_file, @errorName(err) });
    const reader = Reader{ .alloc = alloc, .path = in_file, .b = text };
    const classes = reader.read();

    // Map, refuse the unmapped, and group by repository path.
    var by_repo = std.StringArrayHashMap(std.ArrayList(Line)).init(alloc);
    var excluded: usize = 0;
    var unmapped: usize = 0;
    for (classes) |c| {
        var is_excluded = false;
        for (excludes.items) |e| {
            if (std.mem.startsWith(u8, c.filename, e)) is_excluded = true;
        }
        if (is_excluded) {
            excluded += 1;
            continue;
        }
        const repo = mapPath(alloc, maps.items, c.filename) orelse {
            std.debug.print("cov_normalize: unmapped file name '{s}': no --map or --exclude prefix covers it\n", .{c.filename});
            unmapped += 1;
            continue;
        };
        checkRepoPath(c.filename, repo);
        const slot = by_repo.getOrPut(repo) catch oom();
        if (!slot.found_existing) slot.value_ptr.* = std.ArrayList(Line).init(alloc);
        slot.value_ptr.appendSlice(c.lines.items) catch oom();
    }
    if (unmapped > 0) fail("{d} unmapped file name(s) in {s}; nothing written", .{ unmapped, in_file });

    var outs = std.ArrayList(Out).init(alloc);
    var it = by_repo.iterator();
    while (it.next()) |e| {
        outs.append(.{ .repo = e.key_ptr.*, .lines = mergeLines(alloc, e.key_ptr.*, e.value_ptr.items) }) catch oom();
    }
    std.mem.sort(Out, outs.items, {}, outLess);

    for (musts.items) |m| {
        const lines = by_repo.get(m) orelse fail("no class for {s} (--must-contain): its source was not in the report; nothing written", .{m});
        // A class with no line is no evidence that kcov read the source.
        if (lines.items.len == 0) fail("the class for {s} has no line (--must-contain): kcov did not read its source; nothing written", .{m});
    }

    const bytes = render(alloc, outs.items);
    // A forbidden string is looked for as given and as the output writes it
    // in an attribute (escaped): `a&b` in a path is `a&amp;b` in the bytes.
    for (forbids.items) |s| {
        var esc = std.ArrayList(u8).init(alloc);
        writeEscaped(esc.writer(), s);
        if (std.mem.indexOf(u8, bytes, s) != null or std.mem.indexOf(u8, bytes, esc.items) != null)
            fail("the output would hold '{s}' (--forbid); nothing written", .{s});
    }

    writeOut(out_file, bytes) catch |err| fail("{s}: {s}; nothing written", .{ out_file, @errorName(err) });
    std.debug.print("cov_normalize: {d} class(es) read, {d} excluded, {d} written\n", .{ classes.len, excluded, outs.items.len });
}
