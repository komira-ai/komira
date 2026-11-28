//! The export list and the per-library checks of `native_so`
//! (native_so.zig), as functions of what native_elf.zig, native_macho.zig
//! and native_callsites.zig read, so each is unit-tested on its own inputs
//! (native_so_test.zig, native_macho_test.zig). The numbers are the checks
//! of docs/design/native_packaging.md, "Checks, per library". Checks 4 to 7
//! read a Mach-O library (`Shared.format == .macho`) by their Mach-O rules,
//! the `*MachO` functions below: the same property, held through the load
//! commands and two-level binding instead of the dynamic section and symbol
//! versions.
//!
//! `checkLoader` is `c_shared_lib`'s check (tools/build/node/defs.bzl) of
//! the undefined symbols a library leaves to the program that loads it.
//!
//! A check adds one line per finding to a `Red`; the caller fails the build
//! action when any line was added, and otherwise writes the green message
//! the check returns.

const std = @import("std");
const elf = @import("native_elf.zig");
const macho = @import("native_macho.zig");

pub const Alloc = std.mem.Allocator;
const Sym = elf.Sym;
const Shared = elf.Shared;

/// A static archive of the owner: its label (for messages) and its symbols.
pub const Archive = struct { label: []const u8, syms: []const Sym };

/// A caller of the owner: a Mojo library (its call-site names) or a
/// dependent owner's archive (`archiveCalls`: the names it references).
pub const Caller = struct { label: []const u8, calls: []const []const u8 };

/// A declared NEEDED owner: another komira library's shared library, by its
/// SONAME, with the names it exports.
pub const Owner = struct { soname: []const u8, exports: []const []const u8 };

/// The findings of one check.
pub const Red = struct {
    alloc: Alloc,
    lines: std.ArrayList([]const u8),

    pub fn init(alloc: Alloc) Red {
        return .{ .alloc = alloc, .lines = std.ArrayList([]const u8).empty };
    }

    pub fn add(r: *Red, comptime fmt: []const u8, args: anytype) !void {
        try r.lines.append(r.alloc, try std.fmt.allocPrint(r.alloc, fmt, args));
    }

    /// One line `<what>: a, b, c` (at most 40 names, then the count) when
    /// `names` is not empty.
    pub fn names(r: *Red, what: []const u8, list: []const []const u8) !void {
        if (list.len == 0) return;
        var b = std.ArrayList(u8).empty;
        try b.writer(r.alloc).print("{s} ({d}):", .{ what, list.len });
        for (list, 0..) |n, i| {
            if (i == 40) {
                try b.writer(r.alloc).print(" ... and {d} more", .{list.len - 40});
                break;
            }
            try b.writer(r.alloc).print(" {s}", .{n});
        }
        try r.lines.append(r.alloc, try b.toOwnedSlice(r.alloc));
    }

    pub fn green(r: Red) bool {
        return r.lines.items.len == 0;
    }
};

/// What a NEEDED entry may name besides the declared komira owners: glibc.
/// glibc 2.34 merged libpthread into libc, but an object linked against it
/// still records libpthread.so.0 when it uses a pthread symbol, and the
/// dynamic loader when it uses thread-local storage (probe 3).
pub const glibc_sonames = [_][]const u8{
    "libc.so.6",
    "libpthread.so.0",
    "ld-linux-x86-64.so.2",
    "ld-linux-aarch64.so.1",
};

const komira = "komira_";

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn sorted(alloc: Alloc, list: []const []const u8) ![][]const u8 {
    const out = try alloc.dupe([]const u8, list);
    std.mem.sort([]const u8, out, {}, lessStr);
    var n: usize = 0;
    for (out) |x| {
        if (n > 0 and std.mem.eql(u8, out[n - 1], x)) continue;
        out[n] = x;
        n += 1;
    }
    return out[0..n];
}

const Set = std.StringHashMap(void);

fn setOf(alloc: Alloc, list: []const []const u8) !Set {
    var s = Set.init(alloc);
    for (list) |x| try s.put(x, {});
    return s;
}

/// The elements of `a` that are not in `b`, sorted.
fn minus(alloc: Alloc, a: []const []const u8, b: []const []const u8) ![][]const u8 {
    const bs = try setOf(alloc, b);
    var out = std.ArrayList([]const u8).empty;
    for (a) |x| if (!bs.contains(x)) try out.append(alloc, x);
    return sorted(alloc, out.items);
}

/// The names the shared object exports, sorted.
pub fn exportsOf(alloc: Alloc, so: Shared) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (so.syms) |s| if (s.exported()) try out.append(alloc, s.name);
    return sorted(alloc, out.items);
}

pub fn ownerOf(alloc: Alloc, soname: []const u8, so: Shared) !Owner {
    return .{ .soname = soname, .exports = try exportsOf(alloc, so) };
}

fn undefinedOf(alloc: Alloc, so: Shared, weak: bool) ![]Sym {
    var out = std.ArrayList(Sym).empty;
    for (so.syms) |s| {
        if (s.defined) continue;
        if ((s.bind == .weak) == weak) try out.append(alloc, s);
    }
    return out.toOwnedSlice(alloc);
}

/// A dependent owner's archive as a caller: every name it references (an
/// undefined symbol of one of its members) that none of its members defines.
/// s2n-tls's archive, so, calls the aws-lc functions it needs, which the
/// owner of aws-lc exports though no Mojo library calls them.
pub fn archiveCalls(alloc: Alloc, label: []const u8, syms: []const Sym) !Caller {
    var defs = Set.init(alloc);
    for (syms) |s| if (s.defined and s.bind != .local) try defs.put(s.name, {});
    var out = std.ArrayList([]const u8).empty;
    for (syms) |s| if (!s.defined and !defs.contains(s.name)) try out.append(alloc, s.name);
    return .{ .label = label, .calls = try sorted(alloc, out.items) };
}

// ---- the export list --------------------------------------------------------

pub const Exports = struct {
    names: [][]const u8,
    report: []const u8,
};

/// The owner's exports: every name a caller passes to `external_call` that
/// one of the archives defines with default or protected visibility. Red
/// when a name is defined (strong, weak or common) by two archives, a called
/// name is defined only hidden, an archive defines none of the exports, or a
/// caller calls none of them.
pub fn exportList(alloc: Alloc, archives: []const Archive, callers: []const Caller, red: *Red) !Exports {
    var owner = std.StringHashMap([]const u8).init(alloc);
    var visible = Set.init(alloc);
    var dups = std.ArrayList([]const u8).empty;
    for (archives) |a| {
        var mine = Set.init(alloc);
        for (a.syms) |s| {
            if (!s.defined or s.bind == .local) continue;
            if (s.exported()) try visible.put(s.name, {});
            if (mine.contains(s.name)) continue;
            try mine.put(s.name, {});
            if (owner.get(s.name)) |other| {
                try dups.append(alloc, try std.fmt.allocPrint(alloc, "{s} ({s}, {s})", .{ s.name, other, a.label }));
            } else try owner.put(s.name, a.label);
        }
    }
    try red.names("defined by two archives (one owner per C symbol)", try sorted(alloc, dups.items));

    var all = std.ArrayList([]const u8).empty;
    for (callers) |c| try all.appendSlice(alloc, c.calls);
    const calls = try sorted(alloc, all.items);
    var names = std.ArrayList([]const u8).empty;
    var hidden = std.ArrayList([]const u8).empty;
    for (calls) |n| {
        if (visible.contains(n)) {
            try names.append(alloc, n);
        } else if (owner.contains(n)) try hidden.append(alloc, n);
    }
    try red.names("called names an archive defines only hidden (the library could not export them)", hidden.items);
    const exp = try setOf(alloc, names.items);

    var rep = std.ArrayList(u8).empty;
    const w = rep.writer(alloc);
    try w.print("{d} exports, from {d} callers and {d} archives\narchives (exports each defines):\n", .{ names.items.len, callers.len, archives.len });
    for (archives) |a| {
        var n: usize = 0;
        for (names.items) |x| {
            if (std.mem.eql(u8, owner.get(x) orelse "", a.label)) n += 1;
        }
        try w.print("  {s}: {d}\n", .{ a.label, n });
        if (n == 0) try red.add("archive {s} defines none of the exports (no caller calls it)", .{a.label});
    }
    try w.writeAll("callers (exports each calls, of its call-site names):\n");
    for (callers) |c| {
        var n: usize = 0;
        for (c.calls) |x| {
            if (exp.contains(x)) n += 1;
        }
        try w.print("  {s}: {d} of {d}\n", .{ c.label, n, c.calls.len });
        if (n == 0) try red.add("caller {s} calls none of the exports (not a caller)", .{c.label});
    }
    return .{ .names = names.items, .report = rep.items };
}

/// The version script exporting exactly `names`; every other symbol local.
pub fn versionScript(alloc: Alloc, soname: []const u8, names: []const []const u8) ![]const u8 {
    var b = std.ArrayList(u8).empty;
    const w = b.writer(alloc);
    try w.print("/* {s}: generated by tools/build/native/native_so.zig (exports).\n   The callers' external_call names its archives define; every other symbol is local. */\n{{\n  global:\n", .{soname});
    for (names) |n| try w.print("    {s};\n", .{n});
    try w.writeAll("  local:\n    *;\n};\n");
    return b.items;
}

/// The exported symbols list (ld64's `-exported_symbols_list`) exporting
/// exactly `names`: one per line, each with the `_` Mach-O prepends to a C
/// name; every other symbol is not exported.
pub fn exportedSymbolsList(alloc: Alloc, names: []const []const u8) ![]const u8 {
    var b = std.ArrayList(u8).empty;
    for (names) |n| try b.writer(alloc).print("_{s}\n", .{n});
    return b.items;
}

/// The C names of an exported symbols list `exportedSymbolsList` wrote,
/// sorted: each line without its leading `_`. A line without one names no C
/// symbol and is kept whole, so check 1 shows it.
pub fn symbolsListNames(alloc: Alloc, text: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        try out.append(alloc, if (line.len > 1 and line[0] == '_') line[1..] else line);
    }
    return sorted(alloc, out.items);
}

/// The global names of a version script `versionScript` wrote: the lines
/// between `global:` and `local:`, without their `;`.
pub fn scriptGlobals(alloc: Alloc, text: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    var in_global = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.eql(u8, line, "global:")) {
            in_global = true;
        } else if (std.mem.eql(u8, line, "local:")) {
            in_global = false;
        } else if (in_global and line.len > 0) {
            try out.append(alloc, std.mem.trimRight(u8, line, ";"));
        }
    }
    return sorted(alloc, out.items);
}

/// The lines of a file, without empty ones, sorted.
pub fn lines(alloc: Alloc, text: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| if (l.len > 0) try out.append(alloc, l);
    return sorted(alloc, out.items);
}

// ---- checks 1 to 7 ---------------------------------------------------------

/// 1. Every export starts komira_, and the exports equal the generated list
/// (and the version script's global names equal it too; for a Mach-O
/// library, the exported symbols list's names).
pub fn check1(alloc: Alloc, so: Shared, list: []const []const u8, script: []const []const u8, red: *Red) ![]const u8 {
    const what = if (so.format == .macho) "exported symbols list" else "version script";
    const exp = try exportsOf(alloc, so);
    var bad = std.ArrayList([]const u8).empty;
    for (exp) |n| if (!std.mem.startsWith(u8, n, komira)) try bad.append(alloc, n);
    try red.names("exports without the komira_ prefix", bad.items);
    try red.names("listed names the library does not export", try minus(alloc, list, exp));
    try red.names("exports not in the generated list", try minus(alloc, exp, list));
    try red.names(try std.fmt.allocPrint(alloc, "{s} names not in the list", .{what}), try minus(alloc, script, list));
    try red.names(try std.fmt.allocPrint(alloc, "listed names not in the {s}", .{what}), try minus(alloc, list, script));
    if (exp.len == 0) try red.add("the library exports nothing", .{});
    return std.fmt.allocPrint(alloc, "{d} exports, all komira_, exactly the generated list and the {s}", .{ exp.len, what });
}

/// 2. Every name a caller calls that the owner's archives define is
/// exported: read from the archives and the callers again, independently of
/// the generated list, so a name the generator or the link dropped is red.
pub fn check2(alloc: Alloc, so: Shared, archives: []const Archive, callers: []const Caller, red: *Red) ![]const u8 {
    var defined = Set.init(alloc);
    for (archives) |a| {
        for (a.syms) |s| if (s.defined and s.bind != .local) try defined.put(s.name, {});
    }
    var want = std.ArrayList([]const u8).empty;
    for (callers) |c| {
        for (c.calls) |n| if (defined.contains(n)) try want.append(alloc, n);
    }
    const wanted = try sorted(alloc, want.items);
    if (wanted.len == 0) try red.add("no caller calls a name the archives define (nothing to check)", .{});
    try red.names("names a caller calls that the archives define but the library does not export", try minus(alloc, wanted, try exportsOf(alloc, so)));
    return std.fmt.allocPrint(alloc, "all {d} names the callers call from the archives are exported", .{wanted.len});
}

/// 3. Every strong undefined komira_ symbol is exported by a declared NEEDED
/// owner (`owners`), and every declared owner exports at least one of them
/// (an owner bound by nothing is not this library's owner). A weak undefined
/// komira_ symbol must be on `weak`.
pub fn check3(alloc: Alloc, so: Shared, weak: []const []const u8, owners: []const Owner, red: *Red) ![]const u8 {
    var by = std.StringHashMap([]const u8).init(alloc);
    for (owners) |o| {
        for (o.exports) |e| if (!by.contains(e)) try by.put(e, o.soname);
    }
    var bound = std.StringHashMap(usize).init(alloc);
    var strong = std.ArrayList([]const u8).empty;
    var strong_n: usize = 0;
    for (try undefinedOf(alloc, so, false)) |s| {
        if (!std.mem.startsWith(u8, s.name, komira)) continue;
        strong_n += 1;
        if (by.get(s.name)) |o| {
            const g = try bound.getOrPut(o);
            g.value_ptr.* = if (g.found_existing) g.value_ptr.* + 1 else 1;
        } else try strong.append(alloc, s.name);
    }
    try red.names("strong undefined komira_ symbols no declared NEEDED owner exports", try sorted(alloc, strong.items));
    var idle = std.ArrayList([]const u8).empty;
    for (owners) |o| if (!bound.contains(o.soname)) try idle.append(alloc, o.soname);
    try red.names("declared NEEDED owners exporting none of the library's undefined komira_ symbols", idle.items);
    const ws = try setOf(alloc, weak);
    var unlisted = std.ArrayList([]const u8).empty;
    var n: usize = 0;
    for (try undefinedOf(alloc, so, true)) |s| {
        if (!std.mem.startsWith(u8, s.name, komira)) continue;
        n += 1;
        if (!ws.contains(s.name)) try unlisted.append(alloc, s.name);
    }
    try red.names("weak undefined komira_ symbols not on the weak list", try sorted(alloc, unlisted.items));
    var b = std.ArrayList(u8).empty;
    try b.writer(alloc).print("{d} strong undefined komira_ symbols", .{strong_n});
    if (owners.len == 0) {
        try b.appendSlice(alloc, " (no declared owner)");
    } else {
        try b.appendSlice(alloc, ", each exported by a declared NEEDED owner:");
        for (owners) |o| try b.writer(alloc).print(" {s} {d}", .{ o.soname, bound.get(o.soname) orelse 0 });
    }
    try b.writer(alloc).print("; {d} weak undefined komira_ symbols, all listed", .{n});
    return b.items;
}

/// Whether the library calls outside komira at all: a strong undefined symbol
/// without the komira_ prefix. A shim of atomics alone (async_api's
/// pool depth) needs nothing of glibc, so the link records no libc.so.6 and
/// no GLIBC_ version, and that is green. A Mach-O library is read the same
/// way, for libSystem (check4MachO).
pub fn callsGlibc(so: Shared) bool {
    for (so.syms) |s| {
        if (!s.defined and s.bind != .weak and !std.mem.startsWith(u8, s.name, komira)) return true;
    }
    return false;
}

fn isGlibc(name: []const u8) bool {
    for (glibc_sonames) |g| if (std.mem.eql(u8, g, name)) return true;
    return false;
}

/// The run path a library with a komira NEEDED owner carries: the owner is
/// installed next to it, and a program's own run path is not searched for
/// its dependencies' dependencies.
pub const origin = "$ORIGIN";

fn contains(list: []const []const u8, x: []const u8) bool {
    for (list) |y| if (std.mem.eql(u8, x, y)) return true;
    return false;
}

/// 4. SONAME is `soname`; NEEDED is glibc (libc.so.6 among it whenever the
/// library calls outside komira, `callsGlibc`) and exactly the declared owners (`owners`, their SONAMEs); DT_RUNPATH is `$ORIGIN`
/// alone when an owner is declared, and absent otherwise; no DT_RPATH.
pub fn check4(alloc: Alloc, so: Shared, soname: []const u8, owners: []const []const u8, red: *Red) ![]const u8 {
    if (so.format == .macho) return check4MachO(alloc, so, soname, owners, red);
    if (so.soname) |s| {
        if (!std.mem.eql(u8, s, soname)) try red.add("SONAME is {s}, not {s}", .{ s, soname });
    } else try red.add("no SONAME (want {s})", .{soname});
    var other = std.ArrayList([]const u8).empty;
    var libc = false;
    for (so.needed) |n| {
        if (std.mem.eql(u8, n, "libc.so.6")) libc = true;
        if (!isGlibc(n) and !contains(owners, n)) try other.append(alloc, n);
    }
    try red.names("NEEDED entries that are neither glibc nor a declared owner", other.items);
    var absent = std.ArrayList([]const u8).empty;
    for (owners) |o| if (!contains(so.needed, o)) try absent.append(alloc, o);
    try red.names("declared owners not NEEDED", absent.items);
    if (!libc and callsGlibc(so)) try red.add("libc.so.6 is not NEEDED, but the library has undefined symbols outside komira_ (not linked against glibc?)", .{});
    if (owners.len == 0) {
        try red.names("RUNPATH entries (no komira owner is NEEDED, so none is wanted)", so.runpath);
    } else if (so.runpath.len == 0) {
        try red.add("no RUNPATH, but a komira owner is NEEDED: the loader would not find {s} next to this library (want RUNPATH {s})", .{ owners[0], origin });
    } else {
        var extra = std.ArrayList([]const u8).empty;
        for (so.runpath) |r| if (!std.mem.eql(u8, r, origin)) try extra.append(alloc, r);
        try red.names("RUNPATH entries other than $ORIGIN", extra.items);
        if (so.runpath.len > 1 and extra.items.len == 0) try red.add("RUNPATH lists $ORIGIN {d} times", .{so.runpath.len});
    }
    try red.names("RPATH entries", so.rpath);
    var b = std.ArrayList(u8).empty;
    try b.writer(alloc).print("SONAME {s}; NEEDED", .{soname});
    for (so.needed) |n| try b.writer(alloc).print(" {s}", .{n});
    try b.appendSlice(alloc, if (owners.len == 0) "; no run path" else "; RUNPATH $ORIGIN");
    return b.items;
}

/// A dotted version (`2.34`) as numbers; null if any part is not a number.
pub fn parseVersion(alloc: Alloc, v: []const u8) !?[]u32 {
    var out = std.ArrayList(u32).empty;
    var it = std.mem.splitScalar(u8, v, '.');
    while (it.next()) |p| {
        const n = std.fmt.parseInt(u32, p, 10) catch return null;
        try out.append(alloc, n);
    }
    return out.items;
}

/// a > b, comparing part by part (a missing part is 0).
pub fn versionAbove(a: []const u32, b: []const u32) bool {
    const n = @max(a.len, b.len);
    for (0..n) |i| {
        const x = if (i < a.len) a[i] else 0;
        const y = if (i < b.len) b[i] else 0;
        if (x != y) return x > y;
    }
    return false;
}

/// 5. Every GLIBC_ version the object needs is a release at or below
/// `floor` (the platform row's os_floor).
pub fn check5(alloc: Alloc, so: Shared, floor: []const u8, red: *Red) ![]const u8 {
    if (so.format == .macho) return check5MachO(alloc, so, floor, red);
    const fl = (try parseVersion(alloc, floor)) orelse {
        try red.add("the floor {s} is not a dotted version", .{floor});
        return "";
    };
    var highest: []const u8 = "";
    var highest_n: []const u32 = &.{};
    var seen: usize = 0;
    for (so.verneed) |need| {
        if (!isGlibc(need.file)) continue;
        if (!std.mem.startsWith(u8, need.version, "GLIBC_")) {
            try red.add("needs {s} from {s}, not a GLIBC_ release version", .{ need.version, need.file });
            continue;
        }
        const v = (try parseVersion(alloc, need.version["GLIBC_".len..])) orelse {
            try red.add("needs {s} from {s}, not a GLIBC_ release version", .{ need.version, need.file });
            continue;
        };
        seen += 1;
        if (versionAbove(v, highest_n)) {
            highest = need.version;
            highest_n = v;
        }
        if (versionAbove(v, fl)) {
            var users = std.ArrayList([]const u8).empty;
            for (so.syms) |s| {
                if (s.version) |sv| if (std.mem.eql(u8, sv, need.version)) try users.append(alloc, s.name);
            }
            if (users.items.len == 0) {
                try red.add("needs {s} from {s}, above the floor glibc {s}; no dynamic symbol carries it", .{ need.version, need.file, floor });
            } else try red.names(try std.fmt.allocPrint(alloc, "needs {s} from {s}, above the floor glibc {s}; symbols", .{ need.version, need.file, floor }), try sorted(alloc, users.items));
        }
    }
    if (seen == 0) {
        if (callsGlibc(so)) {
            try red.add("needs no GLIBC_ version at all, but has undefined symbols outside komira_ (not linked against glibc?)", .{});
        } else return std.fmt.allocPrint(alloc, "needs nothing of glibc (no undefined symbol outside komira_), at or below the floor {s}", .{floor});
    }
    return std.fmt.allocPrint(alloc, "highest glibc version needed {s}, at or below the floor {s}", .{ highest, floor });
}

/// 6. DT_FLAGS carries DF_SYMBOLIC (zig links with -z now, so the value
/// also carries DF_BIND_NOW: 0xa).
pub fn check6(alloc: Alloc, so: Shared, red: *Red) ![]const u8 {
    if (so.format == .macho) return check6MachO(alloc, so, red);
    const f = so.flags orelse {
        try red.add("no DT_FLAGS entry: not linked -Bsymbolic", .{});
        return "";
    };
    if (f & elf.DF_SYMBOLIC == 0) try red.add("DT_FLAGS 0x{x} lacks DF_SYMBOLIC (0x2): not linked -Bsymbolic", .{f});
    return std.fmt.allocPrint(alloc, "DT_FLAGS 0x{x}: DF_SYMBOLIC{s}", .{ f, if (f & elf.DF_BIND_NOW != 0) ", DF_BIND_NOW" else "" });
}

/// 7. Every strong undefined symbol is GLIBC_-versioned or a komira_ symbol
/// (check 3's), and the weak undefined ones are exactly `weak`.
pub fn check7(alloc: Alloc, so: Shared, weak: []const []const u8, red: *Red) ![]const u8 {
    if (so.format == .macho) return check7MachO(alloc, so, weak, red);
    var stray = std.ArrayList([]const u8).empty;
    var strong_n: usize = 0;
    for (try undefinedOf(alloc, so, false)) |s| {
        strong_n += 1;
        if (std.mem.startsWith(u8, s.name, komira)) continue;
        if (s.version) |v| if (std.mem.startsWith(u8, v, "GLIBC_")) continue;
        try stray.append(alloc, if (s.version) |v| try std.fmt.allocPrint(alloc, "{s}@{s}", .{ s.name, v }) else s.name);
    }
    try red.names("strong undefined symbols neither GLIBC_-versioned nor komira_", try sorted(alloc, stray.items));
    var have = std.ArrayList([]const u8).empty;
    for (try undefinedOf(alloc, so, true)) |s| try have.append(alloc, s.name);
    const ws = try sorted(alloc, weak);
    try red.names("weak undefined symbols not on the recorded weak list", try minus(alloc, have.items, ws));
    try red.names("recorded weak names the library no longer references (update the list)", try minus(alloc, ws, have.items));
    return std.fmt.allocPrint(alloc, "{d} strong undefined symbols, all GLIBC_ or komira_; weak undefined exactly the {d} recorded", .{ strong_n, ws.len });
}

// ---- checks 4 to 7 of a Mach-O library -------------------------------------

/// What a Mach-O library may load besides the declared komira owners: the
/// system's C library (libSystem, glibc's counterpart) and its C++ runtime
/// (an owner with `cxx_runtime` links the system libc++, which macOS ships
/// and keeps ABI-stable, where an ELF owner links zig's statically).
pub const macos_system_dylibs = [_][]const u8{
    "/usr/lib/libSystem.B.dylib",
    "/usr/lib/libc++.1.dylib",
};

fn isMacSystem(name: []const u8) bool {
    for (macos_system_dylibs) |d| if (std.mem.eql(u8, d, name)) return true;
    return false;
}

/// The run path a Mach-O library with a komira owner carries: the owners'
/// install names are `@rpath/<file>`, found beside the library.
pub const loader_path = "@loader_path";

/// 4, Mach-O. The install name (LC_ID_DYLIB) is `soname`; the loaded
/// dylibs are the system's (`macos_system_dylibs`; libSystem among them
/// whenever the library calls outside komira) and exactly the declared
/// owners (their install names); LC_RPATH is `@loader_path` alone when an
/// owner is declared, and absent otherwise. Every dylib is loaded by a plain
/// LC_LOAD_DYLIB: a re-export would hand the loaded library's whole API on
/// as this library's own (exports check 1 cannot see in LC_SYMTAB), and a
/// weak, upward or lazy load is never what an owner's link asks for.
pub fn check4MachO(alloc: Alloc, so: Shared, soname: []const u8, owners: []const []const u8, red: *Red) ![]const u8 {
    const id = so.soname orelse "";
    if (!std.mem.eql(u8, id, soname)) try red.add("install name is {s}, not {s}", .{ id, soname });
    var other = std.ArrayList([]const u8).empty;
    var system = false;
    for (so.needed) |n| {
        if (std.mem.eql(u8, n, macos_system_dylibs[0])) system = true;
        if (!isMacSystem(n) and !contains(owners, n)) try other.append(alloc, n);
    }
    try red.names("loaded dylibs that are neither the system's nor a declared owner", other.items);
    var odd = std.ArrayList([]const u8).empty;
    for (so.needed, 0..) |n, i| {
        const cmd = if (i < so.load_cmds.len) so.load_cmds[i] else macho.LC_LOAD_DYLIB;
        if (cmd != macho.LC_LOAD_DYLIB) try odd.append(alloc, try std.fmt.allocPrint(alloc, "{s} ({s})", .{ n, macho.loadName(cmd) }));
    }
    try red.names("dylibs loaded by a command other than LC_LOAD_DYLIB", odd.items);
    var absent = std.ArrayList([]const u8).empty;
    for (owners) |o| if (!contains(so.needed, o)) try absent.append(alloc, o);
    try red.names("declared owners not loaded", absent.items);
    if (!system and callsGlibc(so)) try red.add("libSystem is not loaded, but the library has undefined symbols outside komira_ (not linked against the system?)", .{});
    if (owners.len == 0) {
        try red.names("LC_RPATH entries (no komira owner is loaded, so none is wanted)", so.runpath);
    } else if (so.runpath.len == 0) {
        try red.add("no LC_RPATH, but a komira owner is loaded: dyld would not find {s} beside this library (want LC_RPATH {s})", .{ owners[0], loader_path });
    } else {
        var extra = std.ArrayList([]const u8).empty;
        for (so.runpath) |r| if (!std.mem.eql(u8, r, loader_path)) try extra.append(alloc, r);
        try red.names("LC_RPATH entries other than @loader_path", extra.items);
        if (so.runpath.len > 1 and extra.items.len == 0) try red.add("LC_RPATH lists @loader_path {d} times", .{so.runpath.len});
    }
    var b = std.ArrayList(u8).empty;
    try b.writer(alloc).print("install name {s}; loads", .{soname});
    for (so.needed) |n| try b.writer(alloc).print(" {s}", .{n});
    try b.appendSlice(alloc, if (owners.len == 0) "; no run path" else "; LC_RPATH @loader_path");
    return b.items;
}

/// 5, Mach-O. The library is built for macOS with a minimum OS version
/// (LC_BUILD_VERSION) at or below `floor` (the platform row's os_floor,
/// `11.0`): dyld refuses to load it on an older macOS, as an ELF library
/// needing a newer GLIBC_ version fails on an older glibc.
pub fn check5MachO(alloc: Alloc, so: Shared, floor: []const u8, red: *Red) ![]const u8 {
    const fl = (try parseVersion(alloc, floor)) orelse {
        try red.add("the floor {s} is not a dotted version", .{floor});
        return "";
    };
    const minos = so.minos orelse {
        try red.add("no LC_BUILD_VERSION: the library records no minimum macOS version", .{});
        return "";
    };
    if ((so.platform orelse 0) != macho.PLATFORM_MACOS) try red.add("built for platform {d}, not macOS ({d})", .{ so.platform orelse 0, macho.PLATFORM_MACOS });
    const v = (try parseVersion(alloc, minos)).?;
    if (versionAbove(v, fl)) try red.add("minimum macOS version {s} is above the floor {s}", .{ minos, floor });
    return std.fmt.allocPrint(alloc, "minimum macOS version {s}, at or below the floor {s}", .{ minos, floor });
}

/// 6, Mach-O. ld64 has no -Bsymbolic; what it guards is that the library's
/// own references bind to its own definitions. In Mach-O they do unless the
/// library is linked flat (MH_FORCE_FLAT, or MH_TWOLEVEL missing: every
/// undefined name looked up in every image) or a definition is weak and
/// exported (dyld coalesces a weak definition with another image's copy).
pub fn check6MachO(alloc: Alloc, so: Shared, red: *Red) ![]const u8 {
    if (so.mh_flags & macho.MH_TWOLEVEL == 0) try red.add("header flags 0x{x} lack MH_TWOLEVEL (0x80): linked with a flat namespace", .{so.mh_flags});
    if (so.mh_flags & macho.MH_FORCE_FLAT != 0) try red.add("header flags 0x{x} carry MH_FORCE_FLAT (0x100): linked -flat_namespace", .{so.mh_flags});
    var weak = std.ArrayList([]const u8).empty;
    for (so.syms) |s| if (s.exported() and s.bind == .weak) try weak.append(alloc, s.name);
    try red.names("exported weak definitions (dyld may bind them to another image's copy)", try sorted(alloc, weak.items));
    return std.fmt.allocPrint(alloc, "header flags 0x{x}: two-level namespace, no exported weak definition", .{so.mh_flags});
}

/// 7, Mach-O. Every strong undefined symbol is komira_ (check 3's) or
/// binds, by its two-level ordinal, to a system dylib
/// (`macos_system_dylibs`); a flat lookup, the main executable or the
/// library itself is not a place any undefined symbol, komira_ included, may
/// bind to (check 3 matches komira_ names to owners by name alone). The weak
/// undefined ones are exactly `weak`.
pub fn check7MachO(alloc: Alloc, so: Shared, weak: []const []const u8, red: *Red) ![]const u8 {
    var stray = std.ArrayList([]const u8).empty;
    var strong_n: usize = 0;
    var unbound = std.ArrayList([]const u8).empty;
    for (so.syms) |s| {
        if (s.defined) continue;
        const l = s.lib orelse continue;
        if (std.mem.eql(u8, l, macho.lib_flat) or std.mem.eql(u8, l, macho.lib_self) or std.mem.eql(u8, l, macho.lib_executable))
            try unbound.append(alloc, try std.fmt.allocPrint(alloc, "{s} from {s}", .{ s.name, l }));
    }
    try red.names("undefined symbols bound to no loaded dylib", try sorted(alloc, unbound.items));
    for (try undefinedOf(alloc, so, false)) |s| {
        strong_n += 1;
        if (std.mem.startsWith(u8, s.name, komira)) continue;
        if (s.lib) |l| if (isMacSystem(l)) continue;
        try stray.append(alloc, try std.fmt.allocPrint(alloc, "{s} from {s}", .{ s.name, s.lib orelse "<no library>" }));
    }
    try red.names("strong undefined symbols neither bound to a system dylib nor komira_", try sorted(alloc, stray.items));
    var have = std.ArrayList([]const u8).empty;
    for (try undefinedOf(alloc, so, true)) |s| try have.append(alloc, s.name);
    const ws = try sorted(alloc, weak);
    try red.names("weak undefined symbols not on the recorded weak list", try minus(alloc, have.items, ws));
    try red.names("recorded weak names the library no longer references (update the list)", try minus(alloc, ws, have.items));
    return std.fmt.allocPrint(alloc, "{d} strong undefined symbols, all system or komira_; weak undefined exactly the {d} recorded", .{ strong_n, ws.len });
}

// ---- what a c_shared_lib leaves to the program that loads it -----------------

/// Whether the undefined symbol `s` is bound to a library `so` loads. ELF:
/// it carries a symbol version (glibc's `GLIBC_2.x`; glibc is the one
/// library a c_shared_lib links, and its names are the versioned ones). Mach-O: its two-level ordinal names a
/// loaded dylib. Anything else is left to the program that loads `so`: an
/// unversioned ELF symbol, or a Mach-O one bound to flat lookup (a
/// `-undefined dynamic_lookup` link), to the main executable or to the
/// library itself.
fn boundToLoaded(so: Shared, s: Sym) bool {
    if (so.format == .elf) return s.version != null;
    const l = s.lib orelse return false;
    return !(std.mem.eql(u8, l, macho.lib_flat) or std.mem.eql(u8, l, macho.lib_self) or std.mem.eql(u8, l, macho.lib_executable));
}

fn startsWithAny(name: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |p| if (std.mem.startsWith(u8, name, p)) return true;
    return false;
}

/// The `loader` check of `c_shared_lib` (tools/build/node/defs.bzl): every
/// strong undefined symbol of `so` is bound to a library it loads, or starts
/// with one of `leave`, the names the loading program defines (a Node-API
/// addon's `napi_` and `node_api_`, which `node` exports); and `so` exports
/// each of `exports`. With `leave` empty no symbol may be left to the loading
/// program. A weak undefined symbol is not held: when nothing defines it, it
/// is null and the load does not fail.
pub fn checkLoader(alloc: Alloc, so: Shared, leave: []const []const u8, exports: []const []const u8, red: *Red) ![]const u8 {
    var stray = std.ArrayList([]const u8).empty;
    var bound_n: usize = 0;
    var left_n: usize = 0;
    for (try undefinedOf(alloc, so, false)) |s| {
        if (boundToLoaded(so, s)) {
            bound_n += 1;
        } else if (startsWithAny(s.name, leave)) {
            left_n += 1;
        } else try stray.append(alloc, s.name);
    }
    var allowed = std.ArrayList(u8).empty;
    for (leave, 0..) |p, i| try allowed.writer(alloc).print("{s}{s}*", .{ if (i == 0) "" else " or ", p });
    const what = if (leave.len == 0)
        "strong undefined symbols left to the loading program, which may define none of them"
    else
        try std.fmt.allocPrint(alloc, "strong undefined symbols left to the loading program that are not {s}", .{allowed.items});
    try red.names(what, try sorted(alloc, stray.items));
    try red.names("names the library must export and does not", try minus(alloc, exports, try exportsOf(alloc, so)));
    if (leave.len == 0) return std.fmt.allocPrint(alloc, "{d} strong undefined symbols, all bound to the libraries it loads; none left to the loading program; exports the {d} required", .{ bound_n, exports.len });
    return std.fmt.allocPrint(alloc, "{d} strong undefined symbols bound to the libraries it loads and {d} left to the loading program, all {s}; exports the {d} required", .{ bound_n, left_n, allowed.items, exports.len });
}

// ---- the README program calls the library's C (slice 10) ---------------------

/// One program of the library's welded README gate, compiled to an object:
/// its file name and its symbols (elf.readProgram).
pub const Program = struct { name: []const u8, syms: []const Sym };

/// docs/design/native_packaging.md, "Every owner is called, not only
/// loaded": some README program of the owning library references (or
/// defines) one of the owner's `exports`. Compiled to an object, a program
/// has every C function it reaches through `external_call` as an undefined
/// symbol (a `.mojoc` holds no machine code, so the library's Mojo is
/// compiled into the program); a README that never reaches the C names no
/// export, and the installed README run would pass with a broken shared
/// library or without its `-l`.
pub fn checkReadme(alloc: Alloc, exports: []const []const u8, programs: []const Program, red: *Red) ![]const u8 {
    if (exports.len == 0) {
        try red.add("the library exports nothing, so no README program can call it", .{});
        return "";
    }
    if (programs.len == 0) {
        try red.add("the library's README holds no ```mojo example, so no README program calls its C: add an example that does", .{});
        return "";
    }
    const ex = try setOf(alloc, exports);
    var hits = std.ArrayList([]const u8).empty;
    var names = std.ArrayList([]const u8).empty;
    var calling: usize = 0;
    for (programs) |p| {
        try names.append(alloc, p.name);
        const before = hits.items.len;
        for (p.syms) |s| if (ex.contains(s.name)) try hits.append(alloc, try std.fmt.allocPrint(alloc, "{s} in {s}", .{ s.name, p.name }));
        if (hits.items.len > before) calling += 1;
    }
    if (hits.items.len == 0) {
        try red.names("no README program references any export of the library (add a README example that calls its C, so the installed README run calls its shared library); the programs", names.items);
        try red.names("the exports", exports);
        return "";
    }
    const h = try sorted(alloc, hits.items);
    return std.fmt.allocPrint(alloc, "{d} of {d} README programs reference an export: {s}{s}", .{ calling, programs.len, h[0], if (h.len > 1) " and more" else "" });
}
