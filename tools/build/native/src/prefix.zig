//! What `prefix_tool` computes, on text: the names a prefix header renames
//! and the header itself (`header`), and the verdict on a prefixed archive's
//! symbols (`check`). Nothing here reads a file or runs a program (cli.zig
//! does), so the unit tests (prefix_test.zig) reach every rule.
//!
//! Names are sorted as `LC_ALL=C sort -u` sorts them: by bytes, each once.

const std = @import("std");

/// A refusal: its text is `msg`.
pub const Fail = error{Fail};

pub var msg: []const u8 = "";

var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);

/// One arena: the tool runs once and exits, so nothing is freed.
pub fn a() std.mem.Allocator {
    return arena_state.allocator();
}

pub fn oom() noreturn {
    @panic("out of memory");
}

pub fn fmt(comptime f: []const u8, args: anytype) []u8 {
    return std.fmt.allocPrint(a(), f, args) catch oom();
}

/// Sets the refusal text and returns the error that carries it.
pub fn fail(comptime f: []const u8, args: anytype) Fail {
    msg = fmt(f, args);
    return error.Fail;
}

fn startsWith(s: []const u8, p: []const u8) bool {
    return std.mem.startsWith(u8, s, p);
}

fn add(l: *std.ArrayList(u8), s: []const u8) void {
    l.appendSlice(a(), s) catch oom();
}

/// The lines of `s`, split at `\n`; the last line's `\n` is optional.
pub fn lines(s: []const u8) [][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |l| out.append(a(), l) catch oom();
    // "a\nb\n" splits into a, b and an empty last piece: no line.
    if (out.items.len > 0 and out.items[out.items.len - 1].len == 0) _ = out.pop();
    return out.items;
}

fn less(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

/// `names` sorted by bytes, each once (a new slice).
pub fn sortedUnique(names: []const []const u8) [][]const u8 {
    const v = a().dupe([]const u8, names) catch oom();
    std.mem.sort([]const u8, v, {}, less);
    var n: usize = 0;
    for (v) |x| {
        if (n > 0 and std.mem.eql(u8, v[n - 1], x)) continue;
        v[n] = x;
        n += 1;
    }
    return v[0..n];
}

/// A name the header never renames: aws-lc's util/read_symbols.go skip list
/// (C++ names, i386 PIC thunks, MSVC constants, the MSVC C runtime's inline
/// stdio helpers and jemalloc's `sdallocx`), and `__umodti3`, a compiler
/// builtin the compiler calls by that name.
pub fn skipped(name: []const u8) bool {
    for ([_][]const u8{ "_Z", "__x86.get_pc_thunk.", "__real@" }) |p| {
        if (startsWith(name, p)) return true;
    }
    const exact = [_][]const u8{
        "__local_stdio_printf_options", "__local_stdio_scanf_options", "_vscprintf",
        "_vscprintf_l",                 "_vsscanf_l",                  "_xmm",
        "sscanf",                       "vsnprintf",                   "sdallocx",
        "__umodti3",
    };
    for (exact) |x| {
        if (std.mem.eql(u8, name, x)) return true;
    }
    return false;
}

/// The names a header renames: every line of `armap` (`elfsyms armap`) and
/// every `extra`, sorted, each once, less the `skipped` ones. Refused when a
/// name is empty, or fewer than `min` are left (an empty or wrong archive
/// must not give a header that renames nothing); `archive` is the path the
/// message names.
pub fn symbols(armap: []const u8, extra: []const []const u8, archive: []const u8, min: u64) Fail![][]const u8 {
    var all = std.ArrayList([]const u8).empty;
    all.appendSlice(a(), lines(armap)) catch oom();
    all.appendSlice(a(), extra) catch oom();
    var out = std.ArrayList([]const u8).empty;
    for (sortedUnique(all.items)) |n| {
        if (n.len == 0) return fail("prefix_header: an empty name read from {s}", .{archive});
        if (!skipped(n)) out.append(a(), n) catch oom();
    }
    if (out.items.len < min) {
        return fail("prefix_header: only {d} names read from {s} (at least {d} expected)", .{ out.items.len, archive, min });
    }
    return out.items;
}

/// `names`, one per line.
pub fn symbolsFile(names: []const []const u8) []u8 {
    var out = std.ArrayList(u8).empty;
    for (names) |n| {
        add(&out, n);
        add(&out, "\n");
    }
    return out.items;
}

pub const Style = enum { boringssl, strip };

/// A prefix or strip: a C identifier's characters, one or more.
pub fn identifier(what: []const u8, s: []const u8) Fail!void {
    if (s.len == 0) return fail("prefix_tool: {s} is empty", .{what});
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) {
            return fail("prefix_tool: {s} {s}: only letters, digits and _ may be in it", .{ what, s });
        }
    }
}

/// The include guard of a `strip` header: KOMIRA_PREFIX_, `prefix` in
/// upper case with every other byte than A-Z and 0-9 made `_`, then H.
pub fn guard(prefix: []const u8) []u8 {
    var out = std.ArrayList(u8).empty;
    add(&out, "KOMIRA_PREFIX_");
    for (prefix) |c| {
        const u = std.ascii.toUpper(c);
        out.append(a(), if (std.ascii.isUpper(u) or std.ascii.isDigit(u)) u else '_') catch oom();
    }
    add(&out, "H");
    return out.items;
}

/// `name` renamed in the `strip` style: `prefix` in place of `strip` when
/// `name` starts with it, else `prefix` + `_` + `name`, so every renamed
/// name starts with `prefix`.
pub fn stripRenamed(prefix: []const u8, strip: []const u8, name: []const u8) []u8 {
    if (startsWith(name, strip)) return fmt("{s}{s}", .{ prefix, name[strip.len..] });
    return fmt("{s}_{s}", .{ prefix, name });
}

/// The header defining each of `names` (sorted, each once) to its renamed
/// form:
///   boringssl  aws-lc's own boringssl_prefix_symbols.h: X -> <prefix>_X
///   strip      `stripRenamed`
/// Its first line names prefix_header.sh, the shell script this tool
/// replaced: the text is kept so the header's bytes, and with them the key
/// of every compile that includes it, are what they were.
pub fn header(style: Style, prefix: []const u8, strip: []const u8, names: []const []const u8) Fail![]u8 {
    try identifier("prefix", prefix);
    var out = std.ArrayList(u8).empty;
    const w = out.writer(a());
    switch (style) {
        .boringssl => {
            w.print("/* Generated by komira//tools/build/native (prefix_header.sh): aws-lc's\n", .{}) catch oom();
            w.print("   boringssl_prefix_symbols.h for the prefix {s}, {d} names. */\n", .{ prefix, names.len }) catch oom();
            add(&out, "#ifndef BORINGSSL_PREFIX_SYMBOLS_H\n#define BORINGSSL_PREFIX_SYMBOLS_H\n");
            w.print("#ifndef BORINGSSL_PREFIX\n#define BORINGSSL_PREFIX {s}\n#endif\n", .{prefix}) catch oom();
            add(&out, "#define BORINGSSL_ADD_PREFIX(a, b) BORINGSSL_ADD_PREFIX_INNER(a, b)\n");
            add(&out, "#define BORINGSSL_ADD_PREFIX_INNER(a, b) a ## _ ## b\n");
            for (names) |n| w.print("#define {s} BORINGSSL_ADD_PREFIX(BORINGSSL_PREFIX, {s})\n", .{ n, n }) catch oom();
            add(&out, "#endif\n");
        },
        .strip => {
            if (strip.len == 0) return fail("prefix_header: style strip needs a non-empty strip", .{});
            try identifier("strip", strip);
            const g = guard(prefix);
            w.print("/* Generated by komira//tools/build/native (prefix_header.sh): {d} names,\n", .{names.len}) catch oom();
            w.print("   each renamed to start with {s}. */\n", .{prefix}) catch oom();
            w.print("#ifndef {s}\n#define {s}\n", .{ g, g }) catch oom();
            for (names) |n| w.print("#define {s} {s}\n", .{ n, stripRenamed(prefix, strip, n) }) catch oom();
            add(&out, "#endif\n");
        },
    }
    return out.items;
}

/// The symbols of an archive's members (`elfsyms symtab`), each list sorted
/// and each name once.
pub const Symtab = struct {
    def: [][]const u8,
    und: [][]const u8,
    weak_und: [][]const u8,
};

/// Reads `elfsyms symtab` lines, `DEF|UND <bind> <type> <visibility> <name>`
/// (fields split at runs of spaces and tabs; a symbol without a name has
/// four). Any other line is refused: a reader whose output this tool does not
/// understand must not pass a check.
pub fn readSymtab(text: []const u8) Fail!Symtab {
    var def = std.ArrayList([]const u8).empty;
    var und = std.ArrayList([]const u8).empty;
    var weak = std.ArrayList([]const u8).empty;
    for (lines(text), 1..) |l, at| {
        var f: [5][]const u8 = .{ "", "", "", "", "" };
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, l, " \t");
        while (it.next()) |t| {
            if (n == 5) return fail("archive_check: symtab line {d} has more than 5 fields: {s}", .{ at, l });
            f[n] = t;
            n += 1;
        }
        const is_def = std.mem.eql(u8, f[0], "DEF");
        const is_und = std.mem.eql(u8, f[0], "UND");
        if (n < 4 or !(is_def or is_und)) return fail("archive_check: symtab line {d} is not DEF|UND <bind> <type> <visibility> <name>: {s}", .{ at, l });
        if (is_def) def.append(a(), f[4]) catch oom();
        if (is_und) und.append(a(), f[4]) catch oom();
        if (is_und and std.mem.eql(u8, f[1], "WEAK")) weak.append(a(), f[4]) catch oom();
    }
    return .{ .def = sortedUnique(def.items), .und = sortedUnique(und.items), .weak_und = sortedUnique(weak.items) };
}

/// An `allow` pattern: a symbol name, or a name's beginning followed by `*`
/// (`_Z*` is every C++ name). Letters, digits and `_ $ @` only: no
/// regular expression (`_Z.*` is refused, not read as `_Z.` and a star).
pub fn validAllow(p: []const u8) Fail!void {
    const body = if (std.mem.endsWith(u8, p, "*")) p[0 .. p.len - 1] else p;
    if (body.len == 0) return fail("prefix_tool: allow {s}: a name, or a name's beginning followed by *", .{p});
    for (body) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '$' or c == '@')) {
            return fail("prefix_tool: allow {s}: a name, or a name's beginning followed by *", .{p});
        }
    }
}

/// Whether `name` matches one of `allow`.
pub fn allowed(allow: []const []const u8, name: []const u8) bool {
    for (allow) |p| {
        if (std.mem.endsWith(u8, p, "*")) {
            if (startsWith(name, p[0 .. p.len - 1])) return true;
        } else if (std.mem.eql(u8, name, p)) return true;
    }
    return false;
}

/// The names of `names` that neither start with `prefix` nor are allowed.
pub fn unprefixed(names: []const []const u8, prefix: []const u8, allow: []const []const u8) [][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (names) |n| {
        if (!startsWith(n, prefix) and !allowed(allow, n)) out.append(a(), n) catch oom();
    }
    return out.items;
}

/// The names in both `x` and `y` (each sorted, each name once).
pub fn common(x: []const []const u8, y: []const []const u8) [][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    var j: usize = 0;
    while (i < x.len and j < y.len) {
        switch (std.mem.order(u8, x[i], y[j])) {
            .lt => i += 1,
            .gt => j += 1,
            .eq => {
                out.append(a(), x[i]) catch oom();
                i += 1;
                j += 1;
            },
        }
    }
    return out.items;
}

/// What a check found. Red: `stderr` names each failure. Green: `stdout`
/// says what it found and `result` is the validation result (JSON).
pub const Verdict = struct {
    red: bool,
    stdout: []u8,
    stderr: []u8,
    result: []u8,
};

/// The check of a prefixed archive (README.md), red when
///   - a defined symbol neither starts with `prefix` nor is allowed,
///   - a weak undefined symbol neither starts with `prefix` nor is allowed
///     (a hook any other object of the process could define),
///   - an undefined symbol is one of the library's own unprefixed names
///     (the lines of each of `names_files`): a reference the renaming missed,
///   - fewer than `min` defined symbols start with `prefix`.
/// Each red finding lists at most 50 names. `archive` is the path the
/// messages name.
pub fn check(symtab: []const u8, names_files: []const []const u8, archive: []const u8, prefix: []const u8, min: u64, allow: []const []const u8) Fail!Verdict {
    try identifier("prefix", prefix);
    for (allow) |p| try validAllow(p);
    const s = try readSymtab(symtab);
    var all = std.ArrayList([]const u8).empty;
    for (names_files) |t| all.appendSlice(a(), lines(t)) catch oom();
    const names = sortedUnique(all.items);

    const bad_def = unprefixed(s.def, prefix, allow);
    const bad_weak = unprefixed(s.weak_und, prefix, allow);
    const bad_und = common(s.und, names);
    var ndef: usize = 0;
    for (s.def) |n| {
        if (startsWith(n, prefix)) ndef += 1;
    }

    var err = std.ArrayList(u8).empty;
    const reds = [_]struct { []const []const u8, []const u8 }{
        .{ bad_def, fmt("defined symbols without the prefix {s}", .{prefix}) },
        .{ bad_weak, fmt("weak undefined symbols without the prefix {s}", .{prefix}) },
        .{ bad_und, "undefined references to the library's own unprefixed names" },
    };
    for (reds) |r| {
        if (r[0].len == 0) continue;
        err.writer(a()).print("archive_check RED: {d} {s} in {s}:\n", .{ r[0].len, r[1], archive }) catch oom();
        for (r[0][0..@min(r[0].len, 50)]) |n| err.writer(a()).print("  {s}\n", .{n}) catch oom();
    }
    if (ndef < min) {
        err.writer(a()).print("archive_check RED: only {d} defined symbols start with {s} in {s} (at least {d} expected)\n", .{ ndef, prefix, archive, min }) catch oom();
    }
    if (err.items.len > 0) return .{ .red = true, .stdout = "", .stderr = err.items, .result = "" };

    // The message goes into JSON: the prefix is an identifier and the rest
    // is words and numbers, so it holds no quote or backslash.
    const m = fmt("{d} defined symbols start with {s}, {d} defined in all (the rest allowed); {d} weak undefined, each prefixed or allowed; no undefined reference among {d} unprefixed names", .{ ndef, prefix, s.def.len, s.weak_und.len, names.len });
    const shown = if (allow.len == 0) "-" else std.mem.join(a(), "|", allow) catch oom();
    return .{
        .red = false,
        .stdout = fmt("archive_check GREEN: {s} (allowed without the prefix: {s})\n", .{ m, shown }),
        .stderr = "",
        .result = fmt("{{\"version\": 1, \"data\": {{\"status\": \"success\", \"message\": \"{s}\"}}}}\n", .{m}),
    };
}
