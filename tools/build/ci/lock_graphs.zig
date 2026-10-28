//! lock_graphs: the action behind lock_graphs.bxl.
//!
//! usage: lock_graphs <result.json> (<package> <mojo> <mopm.lock> <held> <dir>)...
//!
//! A package built with buildrules' `mojo_package` commits one unit graph per
//! platform subdir in `buildrules.mojo.lock.bzl` (`GRAPHS`). `buildrules mojo
//! sync` plans a graph for linux-64 and for each of linux-aarch64 and osx-arm64
//! that the package's `mopm.lock` records a toolchain for, under the Mojo
//! version the package builds with: `{"toolchain": {"1.0.0": {"linux-64": ...,
//! "osx-arm64": ...}}}`. This tool holds the committed table to that.
//!
//! For each quadruple, <package> is the label (findings name it), <mojo> the
//! Mojo version, <mopm.lock> the package's lock and <held> the subdirs the
//! table holds a graph for, comma separated ("" for linux-64 alone; linux-64
//! is always held). It fails, printing a finding for each subdir the lock
//! records and the table lacks, and for each subdir the table holds that the
//! lock does not record. A lock that is not JSON, or has no toolchain row for
//! <mojo>, is a finding too. Writes <result.json> only when it finds nothing.
//!
//! The same run holds the package's system libraries to its lock. A library the
//! package opens by its bare name at run time is declared in `mopm.toml`
//! (`[native-dependencies] <name> = { ..., mode = "load" }`, of the package or of
//! a path dependency) and, from a mopm that writes `system_libs`, pinned in
//! `mopm.lock` for every platform subdir the lock records a toolchain for;
//! buildrules gives a test run the pinned files, and a lock without the pins
//! leaves the test run to find a library on the machine. <dir> is the package's
//! directory (its `mopm.toml`, its `src/`, and the directories of its path
//! dependencies relative to it). A finding is a declared load with no pins, a
//! subdir with none, and a library opened in the sources that no manifest declares.

const std = @import("std");
const Alloc = std.mem.Allocator;

/// The subdirs `buildrules mojo sync` asks mopm for beside linux-64, in the
/// order it writes them (cli/src/mojo_lock.zig `extra_subdirs`).
pub const extra_subdirs = [_][]const u8{ "linux-aarch64", "osx-arm64" };

pub const Pkg = struct {
    label: []const u8,
    mojo: []const u8,
    lock_path: []const u8,
    held_csv: []const u8,
    /// The package's directory (see the header); "" when system libraries are not checked.
    dir: []const u8 = "",
};

/// A cursor over one line of a mopm.toml, reading the subset of TOML mopm accepts (mopm src/core/toml.zig): bare and quoted keys, dotted keys,
/// basic and literal strings, inline tables.
const Cur = struct {
    s: []const u8,
    i: usize = 0,

    fn ws(c: *Cur) void {
        while (c.i < c.s.len and (c.s[c.i] == ' ' or c.s[c.i] == '\t')) c.i += 1;
    }

    fn peek(c: *Cur) ?u8 {
        return if (c.i < c.s.len) c.s[c.i] else null;
    }

    /// Reads the quoted string at the cursor, decoding escapes of a basic string, into `buf`; text longer than `buf` reads as "". Null when it is
    /// not terminated or has an escape TOML does not define.
    fn quoted(c: *Cur, buf: []u8) ?[]const u8 {
        const q = c.s[c.i];
        c.i += 1;
        var n: usize = 0;
        var over = false;
        while (c.i < c.s.len) {
            var out = c.s[c.i];
            c.i += 1;
            if (out == q) return if (over) "" else buf[0..n];
            if (q == '"' and out == '\\') {
                if (c.i >= c.s.len) return null;
                const e = c.s[c.i];
                c.i += 1;
                out = switch (e) {
                    'b' => 8,
                    't' => '\t',
                    'n' => '\n',
                    'f' => 12,
                    'r' => '\r',
                    '"' => '"',
                    '\\' => '\\',
                    'u', 'U' => blk: {
                        const digits: usize = if (e == 'u') 4 else 8;
                        if (c.i + digits > c.s.len) return null;
                        const cp = std.fmt.parseInt(u32, c.s[c.i .. c.i + digits], 16) catch return null;
                        c.i += digits;
                        break :blk if (cp < 128) @intCast(cp) else 0xff;
                    },
                    else => return null,
                };
            }
            if (n == buf.len) over = true else {
                buf[n] = out;
                n += 1;
            }
        }
        return null;
    }

    /// Skips a value that is not a string or an inline table, up to the `,` or `}` that ends it (or the end of the line).
    fn skipValue(c: *Cur) ?void {
        var depth: usize = 0;
        while (c.i < c.s.len) {
            switch (c.s[c.i]) {
                '"', '\'' => {
                    var b: [1]u8 = undefined;
                    _ = c.quoted(&b) orelse return null;
                    continue;
                },
                '[', '{' => depth += 1,
                ']' => if (depth > 0) {
                    depth -= 1;
                },
                '}' => {
                    if (depth == 0) return;
                    depth -= 1;
                },
                ',' => if (depth == 0) return,
                '#' => {
                    c.i = c.s.len;
                    return;
                },
                else => {},
            }
            c.i += 1;
        }
    }
};

/// A dotted key: how many parts, and whether the first is `native-dependencies` and the last is `mode`.
const KeyPath = struct { n: i32 = 0, first_native: bool = false, last_mode: bool = false };

fn isBare(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-';
}

fn keyPath(c: *Cur) ?KeyPath {
    var kp = KeyPath{};
    while (true) {
        c.ws();
        var buf: [24]u8 = undefined;
        const part: []const u8 = switch (c.peek() orelse return null) {
            '"', '\'' => c.quoted(&buf) orelse return null,
            else => blk: {
                const start = c.i;
                while (c.i < c.s.len and isBare(c.s[c.i])) c.i += 1;
                if (c.i == start) return null;
                break :blk if (c.i - start > buf.len) "" else c.s[start..c.i];
            },
        };
        if (kp.n == 0) kp.first_native = std.mem.eql(u8, part, "native-dependencies");
        kp.last_mode = std.mem.eql(u8, part, "mode");
        kp.n += 1;
        c.ws();
        if (c.peek() == '.') {
            c.i += 1;
            continue;
        }
        return kp;
    }
}

/// Reads `key = value` at the cursor. `level` is the depth of the table the key is written in: -1 for the document root, 0 for the
/// `native-dependencies` table, 1 for one dependency's table. True when the entry, or an inline table in its value, is `mode = "load"` in a
/// dependency's table. Null when the text is not in the subset (the rest of the line is not read).
fn entry(c: *Cur, level: i32, root: bool) ?bool {
    const kp = keyPath(c) orelse return null;
    c.ws();
    if (c.peek() != '=') return null;
    c.i += 1;
    c.ws();
    if (root and !kp.first_native) return false;
    switch (c.peek() orelse return null) {
        '{' => {
            c.i += 1;
            return inlineTable(c, level + kp.n);
        },
        '"', '\'' => {
            var buf: [16]u8 = undefined;
            const v = c.quoted(&buf) orelse return null;
            return level + kp.n - 1 == 1 and kp.last_mode and std.mem.eql(u8, v, "load");
        },
        else => {
            c.skipValue() orelse return null;
            return false;
        },
    }
}

/// Reads the entries of an inline table whose `{` is consumed; `level` is the depth of the table it makes.
fn inlineTable(c: *Cur, level: i32) ?bool {
    while (true) {
        c.ws();
        if (c.peek() == '}') {
            c.i += 1;
            return false;
        }
        if (entry(c, level, false) orelse return null) return true;
        c.ws();
        switch (c.peek() orelse return null) {
            ',' => c.i += 1,
            '}' => {
                c.i += 1;
                return false;
            },
            else => return null,
        }
    }
}

/// True when a mopm.toml text declares a native dependency with `mode = "load"` in its `[native-dependencies]` table. Every spelling mopm's
/// manifest reader accepts for that key counts: an inline table (`lz4 = { mode = "load" }`), the dependency's own table
/// (`[native-dependencies.lz4]`), a dotted key (`lz4.mode = "load"`, or `native-dependencies.lz4.mode = ...` before the first header), a quoted
/// key or header part, a literal string (`'load'`) and escapes in the string. The word in any other table, a comment or a value does not count.
pub fn declaresLoad(text: []const u8) bool {
    var table: ?i32 = null; // the depth of the current table when it is one of ours; null in any other
    var root = true;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var c = Cur{ .s = line };
        if (line[0] == '[') {
            root = false;
            table = null;
            if (line.len > 1 and line[1] == '[') continue;
            c.i = 1;
            const kp = keyPath(&c) orelse continue;
            c.ws();
            if (c.peek() != ']') continue;
            if (kp.first_native and kp.n <= 2) table = kp.n - 1;
            continue;
        }
        const level: i32 = if (root) -1 else (table orelse continue);
        if (entry(&c, level, root) orelse false) return true;
    }
    return false;
}

/// True when a Mojo source text opens a shared library at run time: a call of `OwnedDLHandle(`, `DLHandle(` or `dlopen(` in code. A comment, a
/// string literal and a docstring (a `"""` or `'''` string, which may span lines) that name one are not calls. The reading is lexical and tracks
/// only those; a call hidden in a macro-like string template is not seen, which the lock check's other findings do not cover.
pub fn opensLibrary(text: []const u8) bool {
    var i: usize = 0;
    var triple: u8 = 0; // the quote of the docstring being read, 0 in code
    var single: u8 = 0; // the quote of the one-line string being read, 0 in code
    while (i < text.len) {
        const ch = text[i];
        if (triple != 0) {
            if (ch == '\\') {
                i += 2;
            } else if (ch == triple and std.mem.startsWith(u8, text[i..], &[_]u8{ ch, ch, ch })) {
                triple = 0;
                i += 3;
            } else i += 1;
            continue;
        }
        if (single != 0) {
            if (ch == '\\') {
                i += 2;
            } else {
                if (ch == single or ch == '\n') single = 0;
                i += 1;
            }
            continue;
        }
        if (ch == '#') {
            while (i < text.len and text[i] != '\n') i += 1;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            if (std.mem.startsWith(u8, text[i..], &[_]u8{ ch, ch, ch })) {
                triple = ch;
                i += 3;
            } else {
                single = ch;
                i += 1;
            }
            continue;
        }
        if (std.mem.startsWith(u8, text[i..], "DLHandle(") or std.mem.startsWith(u8, text[i..], "dlopen(")) return true;
        i += 1;
    }
    return false;
}

/// The findings of the system libraries of one package. `lock_text` is its mopm.lock; `declared` says whether the manifest of the package or of
/// a path dependency declares a load; `opens` whether a source of the package opens a library; `mojo` and `label` as in `Pkg`.
pub fn checkSystemLibs(a: Alloc, label: []const u8, mojo: []const u8, lock_text: []const u8, declared: bool, opens: bool) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    if (opens and !declared) {
        try out.append(a, try std.fmt.allocPrint(a, "{s}: a source of the package opens a shared library at run time, but no `[native-dependencies]` entry of its mopm.toml (or of a path dependency) has `mode = \"load\"`, so its lock pins no system library and a test run would find one on the machine: declare the library and run `mopm lock` and `buildrules mojo sync`", .{label}));
    }
    if (!declared) return try out.toOwnedSlice(a);
    var why: []const u8 = "";
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, lock_text, .{}) catch return try out.toOwnedSlice(a);
    if (root != .object) return try out.toOwnedSlice(a);
    var subdirs = std.ArrayList([]const u8).empty;
    try subdirs.append(a, "linux-64");
    if (try recorded(a, lock_text, mojo, &why)) |extra| try subdirs.appendSlice(a, extra);
    const libs = root.object.get("system_libs") orelse {
        try out.append(a, try std.fmt.allocPrint(a, "{s}: its mopm.toml declares a native dependency with `mode = \"load\"` but its mopm.lock has no `system_libs`, so its tests run with whatever library the machine has (a lock written by a mopm older than 0.0.83 pins none): run `mopm lock` with mopm 0.0.83 or later and `buildrules mojo sync`", .{label}));
        return try out.toOwnedSlice(a);
    };
    for (subdirs.items) |sd| {
        const ok = libs == .object and blk: {
            const list = libs.object.get(sd) orelse break :blk false;
            break :blk list == .array and list.array.items.len > 0;
        };
        if (!ok)
            try out.append(a, try std.fmt.allocPrint(a, "{s}: its mopm.lock `system_libs` pins no library for {s}, which its lock records a toolchain for, so a test run on that platform would use the machine's library: run `mopm lock` and `buildrules mojo sync`", .{ label, sd }));
    }
    return try out.toOwnedSlice(a);
}

/// The path dependencies a lock records (`"source": "path"`), as paths relative to the package.
fn pathDeps(a: Alloc, lock_text: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, lock_text, .{}) catch return try out.toOwnedSlice(a);
    if (root != .object) return try out.toOwnedSlice(a);
    const pk = root.object.get("packages") orelse return try out.toOwnedSlice(a);
    if (pk != .array) return try out.toOwnedSlice(a);
    for (pk.array.items) |row| {
        if (row != .object) continue;
        const src = row.object.get("source") orelse continue;
        const path = row.object.get("path") orelse continue;
        if (src == .string and path == .string and std.mem.eql(u8, src.string, "path")) try out.append(a, path.string);
    }
    return try out.toOwnedSlice(a);
}

/// Reads the package directory `dir`: whether its manifest or a path dependency's declares a load, and whether a source opens a library.
pub fn scanPackage(a: Alloc, dir: []const u8, lock_text: []const u8, declared: *bool, opens: *bool) !void {
    const own = try std.fmt.allocPrint(a, "{s}/mopm.toml", .{dir});
    const own_text = try std.fs.cwd().readFileAlloc(a, own, 1 << 22);
    if (declaresLoad(own_text)) declared.* = true;
    for (try pathDeps(a, lock_text)) |rel| {
        const dep = try std.fmt.allocPrint(a, "{s}/{s}/mopm.toml", .{ dir, rel });
        const text = std.fs.cwd().readFileAlloc(a, dep, 1 << 22) catch continue;
        if (declaresLoad(text)) declared.* = true;
    }
    const src = try std.fmt.allocPrint(a, "{s}/src", .{dir});
    var d = std.fs.cwd().openDir(src, .{ .iterate = true }) catch return;
    defer d.close();
    var walker = try d.walk(a);
    while (try walker.next()) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.path, ".mojo")) continue;
        const text = try d.readFileAlloc(a, e.path, 1 << 24);
        if (opensLibrary(text)) {
            opens.* = true;
            return;
        }
    }
}

/// The subdirs of `extra_subdirs` the lock text records a toolchain for under `mojo`; null (with `why` set) when the text is not a lock that has
/// a toolchain row for `mojo`.
pub fn recorded(a: Alloc, lock_text: []const u8, mojo: []const u8, why: *[]const u8) !?[]const []const u8 {
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, lock_text, .{}) catch {
        why.* = "it is not JSON";
        return null;
    };
    if (root != .object) {
        why.* = "it is not a JSON object";
        return null;
    }
    const tc = root.object.get("toolchain") orelse {
        why.* = "it has no \"toolchain\" member";
        return null;
    };
    if (tc != .object) {
        why.* = "its \"toolchain\" is not an object";
        return null;
    }
    const row = tc.object.get(mojo) orelse {
        why.* = try std.fmt.allocPrint(a, "its \"toolchain\" has no row for Mojo {s}", .{mojo});
        return null;
    };
    if (row != .object) {
        why.* = try std.fmt.allocPrint(a, "its toolchain row for Mojo {s} is not an object", .{mojo});
        return null;
    }
    var out = std.ArrayList([]const u8).empty;
    for (extra_subdirs) |sd| {
        if (row.object.get(sd) != null) try out.append(a, sd);
    }
    return try out.toOwnedSlice(a);
}

fn contains(list: []const []const u8, x: []const u8) bool {
    for (list) |l| if (std.mem.eql(u8, l, x)) return true;
    return false;
}

/// The findings for one package: `lock_text` is its mopm.lock.
pub fn check(a: Alloc, p: Pkg, lock_text: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var why: []const u8 = "";
    const want = (try recorded(a, lock_text, p.mojo, &why)) orelse {
        try out.append(a, try std.fmt.allocPrint(a, "{s}: cannot tell which subdirs its graphs must cover: {s} is unusable ({s})", .{ p.label, p.lock_path, why }));
        return try out.toOwnedSlice(a);
    };
    var held = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, p.held_csv, ',');
    while (it.next()) |s| {
        if (s.len > 0) try held.append(a, s);
    }
    for (want) |sd| {
        if (!contains(held.items, sd))
            try out.append(a, try std.fmt.allocPrint(a, "{s}: its mopm.lock records a toolchain for {s} (Mojo {s}) but GRAPHS of buildrules.mojo.lock.bzl holds no graph for it, so a build for that platform has none to use and the committed table is not what `buildrules mojo sync` writes: run `buildrules mojo sync` for the package", .{ p.label, sd, p.mojo }));
    }
    for (held.items) |sd| {
        if (std.mem.eql(u8, sd, "linux-64")) continue;
        if (!contains(want, sd))
            try out.append(a, try std.fmt.allocPrint(a, "{s}: GRAPHS of buildrules.mojo.lock.bzl holds a graph for {s} but its mopm.lock records no toolchain for {s} under Mojo {s}, so `buildrules mojo sync` would not write it: run `buildrules mojo sync` for the package", .{ p.label, sd, sd, p.mojo }));
    }
    return try out.toOwnedSlice(a);
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("lock_graphs: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len < 2 or (argv.len - 2) % 5 != 0) die("usage: lock_graphs <result.json> (<package> <mojo> <mopm.lock> <held> <dir>)...", .{});
    const n = (argv.len - 2) / 5;
    if (n == 0) die("checked nothing: no package given", .{});
    var report = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const base = 2 + 5 * i;
        const p = Pkg{ .label = argv[base], .mojo = argv[base + 1], .lock_path = argv[base + 2], .held_csv = argv[base + 3], .dir = argv[base + 4] };
        const text = std.fs.cwd().readFileAlloc(a, p.lock_path, 1 << 26) catch |e| die("{s}: cannot read {s}: {s}", .{ p.label, p.lock_path, @errorName(e) });
        for (try check(a, p, text)) |f| {
            try report.appendSlice(a, f);
            try report.append(a, '\n');
        }
        var declared = false;
        var opens = false;
        scanPackage(a, p.dir, text, &declared, &opens) catch |e| die("{s}: cannot read the package directory {s}: {s}", .{ p.label, p.dir, @errorName(e) });
        for (try checkSystemLibs(a, p.label, p.mojo, text, declared, opens)) |f| {
            try report.appendSlice(a, f);
            try report.append(a, '\n');
        }
    }
    if (report.items.len > 0) {
        std.debug.print("lock_graphs: {d} finding(s)\n{s}", .{ std.mem.count(u8, report.items, "\n"), report.items });
        std.process.exit(1);
    }
    const f = std.fs.cwd().createFile(argv[1], .{}) catch |e| die("cannot create {s}: {s}", .{ argv[1], @errorName(e) });
    defer f.close();
    try f.deprecatedWriter().print("{{\"version\": 1, \"data\": {{\"status\": \"success\", \"message\": \"lock_graphs: {d} packages checked\"}}}}\n", .{n});
}
