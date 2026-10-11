//! The export list and the per-library checks of `native_so`
//! (native_so.zig), as functions of what native_elf.zig and
//! native_callsites.zig read, so each is unit-tested on its own inputs
//! (native_so_test.zig). The numbers are the checks of
//! docs/design/native_packaging.md, "Checks, per library".
//!
//! A check adds one line per finding to a `Red`; the caller fails the build
//! action when any line was added, and otherwise writes the green message
//! the check returns.

const std = @import("std");
const elf = @import("native_elf.zig");

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
        return .{ .alloc = alloc, .lines = std.ArrayList([]const u8).init(alloc) };
    }

    pub fn add(r: *Red, comptime fmt: []const u8, args: anytype) !void {
        try r.lines.append(try std.fmt.allocPrint(r.alloc, fmt, args));
    }

    /// One line `<what>: a, b, c` (at most 40 names, then the count) when
    /// `names` is not empty.
    pub fn names(r: *Red, what: []const u8, list: []const []const u8) !void {
        if (list.len == 0) return;
        var b = std.ArrayList(u8).init(r.alloc);
        try b.writer().print("{s} ({d}):", .{ what, list.len });
        for (list, 0..) |n, i| {
            if (i == 40) {
                try b.writer().print(" ... and {d} more", .{list.len - 40});
                break;
            }
            try b.writer().print(" {s}", .{n});
        }
        try r.lines.append(try b.toOwnedSlice());
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
    var out = std.ArrayList([]const u8).init(alloc);
    for (a) |x| if (!bs.contains(x)) try out.append(x);
    return sorted(alloc, out.items);
}

/// The names the shared object exports, sorted.
pub fn exportsOf(alloc: Alloc, so: Shared) ![][]const u8 {
    var out = std.ArrayList([]const u8).init(alloc);
    for (so.syms) |s| if (s.exported()) try out.append(s.name);
    return sorted(alloc, out.items);
}

fn undefinedOf(alloc: Alloc, so: Shared, weak: bool) ![]Sym {
    var out = std.ArrayList(Sym).init(alloc);
    for (so.syms) |s| {
        if (s.defined) continue;
        if ((s.bind == .weak) == weak) try out.append(s);
    }
    return out.toOwnedSlice();
}

/// A dependent owner's archive as a caller: every name it references (an
/// undefined symbol of one of its members) that none of its members defines.
/// s2n-tls's archive, so, calls the aws-lc functions it needs, which the
/// owner of aws-lc exports though no Mojo library calls them.
pub fn archiveCalls(alloc: Alloc, label: []const u8, syms: []const Sym) !Caller {
    var defs = Set.init(alloc);
    for (syms) |s| if (s.defined and s.bind != .local) try defs.put(s.name, {});
    var out = std.ArrayList([]const u8).init(alloc);
    for (syms) |s| if (!s.defined and !defs.contains(s.name)) try out.append(s.name);
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
    var dups = std.ArrayList([]const u8).init(alloc);
    for (archives) |a| {
        var mine = Set.init(alloc);
        for (a.syms) |s| {
            if (!s.defined or s.bind == .local) continue;
            if (s.exported()) try visible.put(s.name, {});
            if (mine.contains(s.name)) continue;
            try mine.put(s.name, {});
            if (owner.get(s.name)) |other| {
                try dups.append(try std.fmt.allocPrint(alloc, "{s} ({s}, {s})", .{ s.name, other, a.label }));
            } else try owner.put(s.name, a.label);
        }
    }
    try red.names("defined by two archives (one owner per C symbol)", try sorted(alloc, dups.items));

    var all = std.ArrayList([]const u8).init(alloc);
    for (callers) |c| try all.appendSlice(c.calls);
    const calls = try sorted(alloc, all.items);
    var names = std.ArrayList([]const u8).init(alloc);
    var hidden = std.ArrayList([]const u8).init(alloc);
    for (calls) |n| {
        if (visible.contains(n)) {
            try names.append(n);
        } else if (owner.contains(n)) try hidden.append(n);
    }
    try red.names("called names an archive defines only hidden (the library could not export them)", hidden.items);
    const exp = try setOf(alloc, names.items);

    var rep = std.ArrayList(u8).init(alloc);
    const w = rep.writer();
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
    var b = std.ArrayList(u8).init(alloc);
    const w = b.writer();
    try w.print("/* {s}: generated by tools/build/native/native_so.zig (exports).\n   The callers' external_call names its archives define; every other symbol is local. */\n{{\n  global:\n", .{soname});
    for (names) |n| try w.print("    {s};\n", .{n});
    try w.writeAll("  local:\n    *;\n};\n");
    return b.items;
}

/// The global names of a version script `versionScript` wrote: the lines
/// between `global:` and `local:`, without their `;`.
pub fn scriptGlobals(alloc: Alloc, text: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).init(alloc);
    var in_global = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.eql(u8, line, "global:")) {
            in_global = true;
        } else if (std.mem.eql(u8, line, "local:")) {
            in_global = false;
        } else if (in_global and line.len > 0) {
            try out.append(std.mem.trimRight(u8, line, ";"));
        }
    }
    return sorted(alloc, out.items);
}

/// The lines of a file, without empty ones, sorted.
pub fn lines(alloc: Alloc, text: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).init(alloc);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| if (l.len > 0) try out.append(l);
    return sorted(alloc, out.items);
}

// ---- checks 1 to 7 ---------------------------------------------------------

/// 1. Every export starts komira_, and the exports equal the generated list
/// (and the version script's global names equal it too).
pub fn check1(alloc: Alloc, so: Shared, list: []const []const u8, script: []const []const u8, red: *Red) ![]const u8 {
    const exp = try exportsOf(alloc, so);
    var bad = std.ArrayList([]const u8).init(alloc);
    for (exp) |n| if (!std.mem.startsWith(u8, n, komira)) try bad.append(n);
    try red.names("exports without the komira_ prefix", bad.items);
    try red.names("listed names the library does not export", try minus(alloc, list, exp));
    try red.names("exports not in the generated list", try minus(alloc, exp, list));
    try red.names("version script names not in the list", try minus(alloc, script, list));
    try red.names("listed names not in the version script", try minus(alloc, list, script));
    if (exp.len == 0) try red.add("the library exports nothing", .{});
    return std.fmt.allocPrint(alloc, "{d} exports, all komira_, exactly the generated list and the version script", .{exp.len});
}

/// 2. Every name a caller calls that the owner's archives define is
/// exported: read from the archives and the callers again, independently of
/// the generated list, so a name the generator or the link dropped is red.
pub fn check2(alloc: Alloc, so: Shared, archives: []const Archive, callers: []const Caller, red: *Red) ![]const u8 {
    var defined = Set.init(alloc);
    for (archives) |a| {
        for (a.syms) |s| if (s.defined and s.bind != .local) try defined.put(s.name, {});
    }
    var want = std.ArrayList([]const u8).init(alloc);
    for (callers) |c| {
        for (c.calls) |n| if (defined.contains(n)) try want.append(n);
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
    var strong = std.ArrayList([]const u8).init(alloc);
    var strong_n: usize = 0;
    for (try undefinedOf(alloc, so, false)) |s| {
        if (!std.mem.startsWith(u8, s.name, komira)) continue;
        strong_n += 1;
        if (by.get(s.name)) |o| {
            const g = try bound.getOrPut(o);
            g.value_ptr.* = if (g.found_existing) g.value_ptr.* + 1 else 1;
        } else try strong.append(s.name);
    }
    try red.names("strong undefined komira_ symbols no declared NEEDED owner exports", try sorted(alloc, strong.items));
    var idle = std.ArrayList([]const u8).init(alloc);
    for (owners) |o| if (!bound.contains(o.soname)) try idle.append(o.soname);
    try red.names("declared NEEDED owners exporting none of the library's undefined komira_ symbols", idle.items);
    const ws = try setOf(alloc, weak);
    var unlisted = std.ArrayList([]const u8).init(alloc);
    var n: usize = 0;
    for (try undefinedOf(alloc, so, true)) |s| {
        if (!std.mem.startsWith(u8, s.name, komira)) continue;
        n += 1;
        if (!ws.contains(s.name)) try unlisted.append(s.name);
    }
    try red.names("weak undefined komira_ symbols not on the weak list", try sorted(alloc, unlisted.items));
    var b = std.ArrayList(u8).init(alloc);
    try b.writer().print("{d} strong undefined komira_ symbols", .{strong_n});
    if (owners.len == 0) {
        try b.appendSlice(" (no declared owner)");
    } else {
        try b.appendSlice(", each exported by a declared NEEDED owner:");
        for (owners) |o| try b.writer().print(" {s} {d}", .{ o.soname, bound.get(o.soname) orelse 0 });
    }
    try b.writer().print("; {d} weak undefined komira_ symbols, all listed", .{n});
    return b.items;
}

/// Whether the library calls outside komira at all: a strong undefined symbol
/// without the komira_ prefix. A shim of atomics alone (komira_async_api's
/// pool depth) needs nothing of glibc, so the link records no libc.so.6 and
/// no GLIBC_ version, and that is green.
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
    if (so.soname) |s| {
        if (!std.mem.eql(u8, s, soname)) try red.add("SONAME is {s}, not {s}", .{ s, soname });
    } else try red.add("no SONAME (want {s})", .{soname});
    var other = std.ArrayList([]const u8).init(alloc);
    var libc = false;
    for (so.needed) |n| {
        if (std.mem.eql(u8, n, "libc.so.6")) libc = true;
        if (!isGlibc(n) and !contains(owners, n)) try other.append(n);
    }
    try red.names("NEEDED entries that are neither glibc nor a declared owner", other.items);
    var absent = std.ArrayList([]const u8).init(alloc);
    for (owners) |o| if (!contains(so.needed, o)) try absent.append(o);
    try red.names("declared owners not NEEDED", absent.items);
    if (!libc and callsGlibc(so)) try red.add("libc.so.6 is not NEEDED, but the library has undefined symbols outside komira_ (not linked against glibc?)", .{});
    if (owners.len == 0) {
        try red.names("RUNPATH entries (no komira owner is NEEDED, so none is wanted)", so.runpath);
    } else if (so.runpath.len == 0) {
        try red.add("no RUNPATH, but a komira owner is NEEDED: the loader would not find {s} next to this library (want RUNPATH {s})", .{ owners[0], origin });
    } else {
        var extra = std.ArrayList([]const u8).init(alloc);
        for (so.runpath) |r| if (!std.mem.eql(u8, r, origin)) try extra.append(r);
        try red.names("RUNPATH entries other than $ORIGIN", extra.items);
        if (so.runpath.len > 1 and extra.items.len == 0) try red.add("RUNPATH lists $ORIGIN {d} times", .{so.runpath.len});
    }
    try red.names("RPATH entries", so.rpath);
    var b = std.ArrayList(u8).init(alloc);
    try b.writer().print("SONAME {s}; NEEDED", .{soname});
    for (so.needed) |n| try b.writer().print(" {s}", .{n});
    try b.appendSlice(if (owners.len == 0) "; no run path" else "; RUNPATH $ORIGIN");
    return b.items;
}

/// A dotted version (`2.34`) as numbers; null if any part is not a number.
pub fn parseVersion(alloc: Alloc, v: []const u8) !?[]u32 {
    var out = std.ArrayList(u32).init(alloc);
    var it = std.mem.splitScalar(u8, v, '.');
    while (it.next()) |p| {
        const n = std.fmt.parseInt(u32, p, 10) catch return null;
        try out.append(n);
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
            var users = std.ArrayList([]const u8).init(alloc);
            for (so.syms) |s| {
                if (s.version) |sv| if (std.mem.eql(u8, sv, need.version)) try users.append(s.name);
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
    var stray = std.ArrayList([]const u8).init(alloc);
    var strong_n: usize = 0;
    for (try undefinedOf(alloc, so, false)) |s| {
        strong_n += 1;
        if (std.mem.startsWith(u8, s.name, komira)) continue;
        if (s.version) |v| if (std.mem.startsWith(u8, v, "GLIBC_")) continue;
        try stray.append(if (s.version) |v| try std.fmt.allocPrint(alloc, "{s}@{s}", .{ s.name, v }) else s.name);
    }
    try red.names("strong undefined symbols neither GLIBC_-versioned nor komira_", try sorted(alloc, stray.items));
    var have = std.ArrayList([]const u8).init(alloc);
    for (try undefinedOf(alloc, so, true)) |s| try have.append(s.name);
    const ws = try sorted(alloc, weak);
    try red.names("weak undefined symbols not on the recorded weak list", try minus(alloc, have.items, ws));
    try red.names("recorded weak names the library no longer references (update the list)", try minus(alloc, ws, have.items));
    return std.fmt.allocPrint(alloc, "{d} strong undefined symbols, all GLIBC_ or komira_; weak undefined exactly the {d} recorded", .{ strong_n, ws.len });
}
