//! so_report: the ELF record of libkomira and the libraries it loads, as a
//! markdown table, written by one build action
//! (`komira//tools/build/package/libkomira:libkomira_elf_report`).
//!
//!   so_report --out <report.md> [--floor <glibc version>]
//!             --target <name> <libkomira.so>
//!             (--owner <name> <lib.so>)...
//!             (--runtime <name> <lib.so>)...
//!
//! For each file: its size, SONAME, RUNPATH and DT_NEEDED (in order), and the
//! highest `GLIBC_`, `GLIBCXX_` and `CXXABI_` symbol version it requires
//! (native_elf.zig, `readShared`). For each native owner: whether the target
//! needs it directly, only through another needed library, or not at all (the
//! owner is built and declared but nothing reaches it), and how many of the
//! target's undefined symbols it defines. The wheel tag `manylinux_2_<N>` is
//! derived from the highest GLIBC version of the target and the owners; when
//! `--floor` is given and that version is higher, the report says so on its
//! first line. The report is a record: it does not fail on a number.
//!
//! Exit 2: a usage error or a file that cannot be read as 64-bit
//! little-endian ELF.

const std = @import("std");
const elf = @import("native_elf.zig");

const Alloc = std.mem.Allocator;

pub const Role = enum { target, owner, runtime };

pub const Lib = struct {
    /// The file name the report shows (a build output has an opaque name).
    name: []const u8,
    role: Role,
    size: u64,
    so: elf.Shared,
};

/// A dotted version (`2.2.5`) compared component by component.
pub const Version = struct {
    parts: [4]u32 = .{ 0, 0, 0, 0 },
    n: usize = 0,

    pub fn parse(s: []const u8) ?Version {
        var v = Version{};
        var it = std.mem.splitScalar(u8, s, '.');
        while (it.next()) |p| {
            if (v.n == v.parts.len) return null;
            v.parts[v.n] = std.fmt.parseInt(u32, p, 10) catch return null;
            v.n += 1;
        }
        if (v.n == 0) return null;
        return v;
    }

    pub fn order(a: Version, b: Version) std.math.Order {
        for (0..a.parts.len) |i| {
            const o = std.math.order(a.parts[i], b.parts[i]);
            if (o != .eq) return o;
        }
        return .eq;
    }

    pub fn print(v: Version, w: anytype) !void {
        for (v.parts[0..v.n], 0..) |p, i| {
            if (i > 0) try w.writeAll(".");
            try w.print("{d}", .{p});
        }
    }
};

/// The highest version named `<prefix>_<dotted>` among a library's needed
/// versions; null when it needs none of that name.
pub fn highest(so: elf.Shared, prefix: []const u8) ?Version {
    var best: ?Version = null;
    for (so.verneed) |n| {
        if (n.version.len <= prefix.len + 1) continue;
        if (!std.mem.startsWith(u8, n.version, prefix) or n.version[prefix.len] != '_') continue;
        const v = Version.parse(n.version[prefix.len + 1 ..]) orelse continue;
        if (best == null or v.order(best.?) == .gt) best = v;
    }
    return best;
}

fn find(libs: []const Lib, soname: []const u8) ?usize {
    for (libs, 0..) |l, i| {
        const n = l.so.soname orelse l.name;
        if (std.mem.eql(u8, n, soname) or std.mem.eql(u8, l.name, soname)) return i;
    }
    return null;
}

pub const Reach = enum { direct, transitive, none };

/// How the target reaches each library: DT_NEEDED of the target (`direct`),
/// DT_NEEDED of a library it reaches (`transitive`), neither (`none`).
/// Libraries are matched by SONAME or file name; a NEEDED that no input
/// provides (glibc) reaches nothing.
pub fn reach(alloc: Alloc, libs: []const Lib, target: usize) ![]Reach {
    const out = try alloc.alloc(Reach, libs.len);
    @memset(out, .none);
    var queue = std.ArrayList(usize).empty;
    for (libs[target].so.needed) |n| {
        const i = find(libs, n) orelse continue;
        if (out[i] == .none and i != target) {
            out[i] = .direct;
            try queue.append(alloc, i);
        }
    }
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        for (libs[queue.items[head]].so.needed) |n| {
            const i = find(libs, n) orelse continue;
            if (out[i] == .none and i != target) {
                out[i] = .transitive;
                try queue.append(alloc, i);
            }
        }
    }
    return out;
}

/// How many undefined symbols of the target `owner` defines (exports).
pub fn bound(alloc: Alloc, target: elf.Shared, owner: elf.Shared) !usize {
    var defs = std.StringHashMap(void).init(alloc);
    for (owner.syms) |s| if (s.exported()) try defs.put(s.name, {});
    var n: usize = 0;
    for (target.syms) |s| {
        if (!s.defined and defs.contains(s.name)) n += 1;
    }
    return n;
}

/// The highest GLIBC version over the libraries of `role`s the wheel ships
/// (the target and the owners); null when none needs glibc.
pub fn shippedGlibc(libs: []const Lib) ?Version {
    var best: ?Version = null;
    for (libs) |l| {
        if (l.role == .runtime) continue;
        const v = highest(l.so, "GLIBC") orelse continue;
        if (best == null or v.order(best.?) == .gt) best = v;
    }
    return best;
}

fn joined(w: anytype, items: []const []const u8, empty: []const u8) !void {
    if (items.len == 0) return w.writeAll(empty);
    for (items, 0..) |s, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("`{s}`", .{s});
    }
}

fn cell(w: anytype, v: ?Version, prefix: []const u8) !void {
    if (v) |x| {
        try w.print("`{s}_", .{prefix});
        try x.print(w);
        try w.writeAll("`");
    } else try w.writeAll("none");
}

/// Writes the report. `floor` is the glibc version the wheel tag promises.
pub fn report(alloc: Alloc, w: anytype, libs: []const Lib, floor: ?Version) !void {
    var target: ?usize = null;
    for (libs, 0..) |l, i| {
        if (l.role == .target) target = i;
    }
    const ti = target orelse return error.NoTarget;
    const ships = shippedGlibc(libs);
    const over: ?[2]Version = if (floor != null and ships != null and ships.?.order(floor.?) == .gt) .{ ships.?, floor.? } else null;
    if (over) |o| {
        const s = o[0];
        const f = o[1];
        try w.writeAll("**FLOOR EXCEEDED: the target or an owner needs `GLIBC_");
        try s.print(w);
        try w.writeAll("`, above the promised `GLIBC_");
        try f.print(w);
        try w.writeAll("`; the wheel tag is `manylinux_2_");
        try w.print("{d}", .{s.parts[1]});
        try w.writeAll("`, not `manylinux_2_");
        try w.print("{d}", .{f.parts[1]});
        try w.writeAll("`.**\n\n");
    }

    try w.writeAll("| file | role | size (bytes) | SONAME | RUNPATH | RPATH | highest GLIBC | highest GLIBCXX | highest CXXABI |\n");
    try w.writeAll("|---|---|---|---|---|---|---|---|---|\n");
    for (libs) |l| {
        try w.print("| `{s}` | {s} | {d} | ", .{ l.name, @tagName(l.role), l.size });
        if (l.so.soname) |n| try w.print("`{s}`", .{n}) else try w.writeAll("none");
        try w.writeAll(" | ");
        try joined(w, l.so.runpath, "none");
        try w.writeAll(" | ");
        try joined(w, l.so.rpath, "none");
        try w.writeAll(" | ");
        try cell(w, highest(l.so, "GLIBC"), "GLIBC");
        try w.writeAll(" | ");
        try cell(w, highest(l.so, "GLIBCXX"), "GLIBCXX");
        try w.writeAll(" | ");
        try cell(w, highest(l.so, "CXXABI"), "CXXABI");
        try w.writeAll(" |\n");
    }

    try w.writeAll("\n| file | DT_NEEDED, in order |\n|---|---|\n");
    for (libs) |l| {
        try w.print("| `{s}` | ", .{l.name});
        try joined(w, l.so.needed, "none");
        try w.writeAll(" |\n");
    }

    const r = try reach(alloc, libs, ti);
    try w.writeAll("\n| library | role | reached from the target | target's undefined symbols it defines |\n|---|---|---|---|\n");
    var needed_owners: usize = 0;
    var declared_only: usize = 0;
    var total_owners: usize = 0;
    var owner_bytes: u64 = 0;
    for (libs, 0..) |l, i| {
        if (l.role == .target) continue;
        const n = try bound(alloc, libs[ti].so, l.so);
        try w.print("| `{s}` | {s} | {s} | {d} |\n", .{ l.name, @tagName(l.role), switch (r[i]) {
            .direct => "needed (direct)",
            .transitive => "needed (through another library)",
            .none => "declared only",
        }, n });
        if (l.role == .owner) {
            total_owners += 1;
            if (r[i] == .none) declared_only += 1 else {
                needed_owners += 1;
                owner_bytes += l.size;
            }
        }
    }
    try w.print("\nOwners needed: {d} of {d} ({d} bytes); declared only: {d}.\n", .{ needed_owners, total_owners, owner_bytes, declared_only });

    try w.writeAll("\nWheel tag: ");
    if (ships) |s| {
        try w.print("`manylinux_2_{d}` (highest GLIBC of the target and the owners: `GLIBC_", .{s.parts[1]});
        try s.print(w);
        try w.writeAll("`).\n");
    } else try w.writeAll("no GLIBC version is needed by the target or the owners.\n");
}

/// What the command line asks: the report path, the floor and the files.
pub const Args = struct {
    out: []const u8,
    floor: ?Version,
    files: []const File,
};

pub const File = struct { name: []const u8, role: Role, path: []const u8 };

pub const ArgError = error{ Usage, BadFloor, NoOut, NotOneTarget };

/// Reads the arguments after the program name; a mistake is an error, never a
/// default.
pub fn parseArgs(alloc: Alloc, argv: []const []const u8) (ArgError || Alloc.Error)!Args {
    var files = std.ArrayList(File).empty;
    var out: ?[]const u8 = null;
    var floor: ?Version = null;
    var i: usize = 0;
    while (i < argv.len) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--out") and i + 1 < argv.len) {
            out = argv[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, a, "--floor") and i + 1 < argv.len) {
            floor = Version.parse(argv[i + 1]) orelse return error.BadFloor;
            i += 2;
        } else if (i + 2 < argv.len and (std.mem.eql(u8, a, "--target") or std.mem.eql(u8, a, "--owner") or std.mem.eql(u8, a, "--runtime"))) {
            const role: Role = if (a[2] == 't') .target else if (a[2] == 'o') .owner else .runtime;
            try files.append(alloc, .{ .name = argv[i + 1], .role = role, .path = argv[i + 2] });
            i += 3;
        } else return error.Usage;
    }
    var n_target: usize = 0;
    for (files.items) |f| {
        if (f.role == .target) n_target += 1;
    }
    if (n_target != 1) return error.NotOneTarget;
    return .{ .out = out orelse return error.NoOut, .floor = floor, .files = files.items };
}

fn usage(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("so_report: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn load(alloc: Alloc, f: File) Lib {
    const b = std.fs.cwd().readFileAlloc(alloc, f.path, 1 << 31) catch |err|
        usage("cannot read {s}: {s}", .{ f.path, @errorName(err) });
    const so = elf.readShared(alloc, b) catch usage("{s}: {s}", .{ f.path, elf.why });
    return .{ .name = f.name, .role = f.role, .size = b.len, .so = so };
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    const argv = try std.process.argsAlloc(alloc);
    const args = parseArgs(alloc, argv[1..]) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => usage("{s}: so_report --out <report.md> [--floor <v>] --target <name> <so> (--owner|--runtime <name> <so>)...", .{@errorName(err)}),
    };
    var libs = std.ArrayList(Lib).empty;
    for (args.files) |f| try libs.append(alloc, load(alloc, f));
    var b = std.ArrayList(u8).empty;
    try report(alloc, b.writer(alloc), libs.items, args.floor);
    var f = std.fs.cwd().createFile(args.out, .{}) catch |err| usage("cannot write {s}: {s}", .{ args.out, @errorName(err) });
    defer f.close();
    f.writeAll(b.items) catch |err| usage("cannot write {s}: {s}", .{ args.out, @errorName(err) });
}

test {
    _ = @import("so_report_test.zig");
}
