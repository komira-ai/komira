//! loader_closure: what the dynamic loader would map for each program of a
//! prefix (a toolchain distribution directory), read from the ELF files
//! alone, and the glibc symbol versions they name (README.md).
//!
//!   loader_closure --prefix <dir> --out <validation.json>
//!       [--root <path in prefix>]... [--interp <path>] [--glibc-floor <n>]
//!
//! Every regular file of <dir> that is an ELF file with a PT_INTERP header is
//! a program; each `--root` must be one. For each program it resolves
//! DT_NEEDED breadth first, as glibc's loader does: a name an object already
//! mapped has (the name it was loaded by, or its DT_SONAME) is that object;
//! otherwise the DT_RPATH of the object, then of the object that loaded it,
//! up to the program (an object with a DT_RUNPATH contributes no DT_RPATH, and
//! a needing object with one skips that chain), then LD_LIBRARY_PATH, then
//! the object's DT_RUNPATH. It is red, naming each failure, unless:
//!   - every program's PT_INTERP is <interp> (/lib64/ld-linux-x86-64.so.2);
//!   - every run path entry the loader would read is `$ORIGIN` or
//!     `$ORIGIN/<path>` (or `${ORIGIN}`) that stays inside the prefix: an
//!     absolute entry is searched wherever the prefix is installed, so it is
//!     outside the prefix; a relative or empty one is the working directory;
//!   - every needed name that is not one of glibc's (SYSTEM) is found inside
//!     the prefix through a DT_RPATH, which the loader searches before
//!     LD_LIBRARY_PATH; found only through a DT_RUNPATH, or not found, the
//!     loader would take it from LD_LIBRARY_PATH or the system;
//!   - no glibc name is found inside the prefix: glibc comes from the system;
//!   - every object it maps is an ELF64 little-endian file, and a link it
//!     follows stays inside the prefix;
//!   - with `--glibc-floor <n>`, no ELF file of the prefix names a version
//!     GLIBC_2.<m> with m > n (any string of the file, so a library embedded
//!     as bytes counts too), and at least one names a GLIBC_2. version.
//! Green, it prints what each program maps and writes <out>, the validation
//! result. Red, it writes nothing and exits 1. A usage error exits 2.
//!
//! This reads the files; it runs nothing. Linux x86_64 ELF only: a darwin
//! prefix (Mach-O) has no ELF program and is refused.

const std = @import("std");

/// glibc's libraries: taken from the system, never from the prefix.
pub const SYSTEM = [_][]const u8{ "libc.so.6", "libm.so.6", "libdl.so.2", "libpthread.so.0", "librt.so.1", "ld-linux-x86-64.so.2" };
pub const DEFAULT_INTERP = "/lib64/ld-linux-x86-64.so.2";

const PT_LOAD: u32 = 1;
const PT_DYNAMIC: u32 = 2;
const PT_INTERP: u32 = 3;
const DT_NULL: u64 = 0;
const DT_NEEDED: u64 = 1;
const DT_STRTAB: u64 = 5;
const DT_STRSZ: u64 = 10;
const DT_SONAME: u64 = 14;
const DT_RPATH: u64 = 15;
const DT_RUNPATH: u64 = 29;

/// What the loader reads of one ELF file.
pub const Elf = struct {
    interp: ?[]const u8 = null,
    needed: []const []const u8 = &.{},
    rpath: ?[]const u8 = null,
    runpath: ?[]const u8 = null,
    soname: ?[]const u8 = null,
};

pub const ParseError = error{ NotElf64, Truncated, BadDynamic, OutOfMemory };

pub fn isElf(b: []const u8) bool {
    return b.len >= 4 and std.mem.eql(u8, b[0..4], "\x7fELF");
}

fn rd(comptime T: type, b: []const u8, at: u64) ParseError!T {
    if (at > b.len or b.len - at < @sizeOf(T)) return error.Truncated;
    const i: usize = @intCast(at);
    return std.mem.readInt(T, b[i..][0..@sizeOf(T)], .little);
}

/// The NUL-terminated string at `at`, without its NUL.
fn cstr(b: []const u8, at: u64, end: u64) ParseError![]const u8 {
    if (at >= end or end > b.len) return error.Truncated;
    const s = b[@intCast(at)..@intCast(end)];
    const n = std.mem.indexOfScalar(u8, s, 0) orelse return error.Truncated;
    return s[0..n];
}

/// The file offset of virtual address `v`, through the PT_LOAD headers.
fn offsetOf(loads: []const [3]u64, v: u64) ParseError!u64 {
    for (loads) |l| {
        if (v >= l[1] and v - l[1] < l[2]) return l[0] + (v - l[1]);
    }
    return error.BadDynamic;
}

/// The string at index `idx` of the string table [s, e), copied into `a`.
fn strAt(a: std.mem.Allocator, b: []const u8, s: u64, e: u64, idx: u64) ParseError![]const u8 {
    if (idx >= e - s) return error.BadDynamic;
    return a.dupe(u8, try cstr(b, s + idx, e));
}

/// Parses the program headers and dynamic section of an ELF64
/// little-endian file. Strings are copied into `a`.
pub fn parse(a: std.mem.Allocator, b: []const u8) ParseError!Elf {
    if (!isElf(b) or b.len < 64) return error.NotElf64;
    if (b[4] != 2 or b[5] != 1) return error.NotElf64;
    const phoff = try rd(u64, b, 0x20);
    const phentsize: u64 = try rd(u16, b, 0x36);
    const phnum: u64 = try rd(u16, b, 0x38);
    if (phnum > 0 and phentsize < 56) return error.Truncated;
    var out = Elf{};
    var loads = std.ArrayList([3]u64).init(a);
    var dyn: ?[2]u64 = null;
    var i: u64 = 0;
    while (i < phnum) : (i += 1) {
        const ph = phoff + i * phentsize;
        const ty = try rd(u32, b, ph);
        const off = try rd(u64, b, ph + 8);
        const vaddr = try rd(u64, b, ph + 16);
        const filesz = try rd(u64, b, ph + 32);
        if (off > b.len or b.len - off < filesz) return error.Truncated;
        switch (ty) {
            PT_LOAD => try loads.append(.{ off, vaddr, filesz }),
            PT_DYNAMIC => {
                if (dyn != null) return error.BadDynamic;
                dyn = .{ off, filesz };
            },
            PT_INTERP => out.interp = try a.dupe(u8, try cstr(b, off, off + filesz)),
            else => {},
        }
    }
    const d = dyn orelse return out;
    var strtab: ?u64 = null;
    var strsz: ?u64 = null;
    var needed = std.ArrayList(u64).init(a);
    var rpath: ?u64 = null;
    var runpath: ?u64 = null;
    var soname: ?u64 = null;
    var at = d[0];
    while (at + 16 <= d[0] + d[1]) : (at += 16) {
        const tag = try rd(u64, b, at);
        const val = try rd(u64, b, at + 8);
        switch (tag) {
            DT_NULL => break,
            DT_NEEDED => try needed.append(val),
            DT_STRTAB => strtab = val,
            DT_STRSZ => strsz = val,
            DT_SONAME => soname = val,
            DT_RPATH => {
                if (rpath != null) return error.BadDynamic;
                rpath = val;
            },
            DT_RUNPATH => {
                if (runpath != null) return error.BadDynamic;
                runpath = val;
            },
            else => {},
        }
    }
    if (needed.items.len == 0 and rpath == null and runpath == null and soname == null) return out;
    const st = try offsetOf(loads.items, strtab orelse return error.BadDynamic);
    const end = st + (strsz orelse return error.BadDynamic);
    var names = std.ArrayList([]const u8).init(a);
    for (needed.items) |n| try names.append(try strAt(a, b, st, end, n));
    out.needed = names.items;
    if (rpath) |r| out.rpath = try strAt(a, b, st, end, r);
    if (runpath) |r| out.runpath = try strAt(a, b, st, end, r);
    if (soname) |s| out.soname = try strAt(a, b, st, end, s);
    return out;
}

/// Each minor m of a `GLIBC_2.<m>` string in `b` with m > `floor`, added to
/// `over` once. Returns whether `b` names any GLIBC_2. version.
pub fn glibcOver(b: []const u8, floor: u32, over: *std.ArrayList(u32)) !bool {
    const key = "GLIBC_2.";
    var any = false;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, b, from, key)) |p| {
        from = p + key.len;
        var e = from;
        while (e < b.len and std.ascii.isDigit(b[e])) e += 1;
        if (e == from) continue;
        any = true;
        const m = std.fmt.parseInt(u32, b[from..e], 10) catch std.math.maxInt(u32);
        if (m > floor and std.mem.indexOfScalar(u32, over.items, m) == null) try over.append(m);
    }
    return any;
}

pub fn isSystem(name: []const u8) bool {
    for (SYSTEM) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}

pub const Options = struct {
    interp: []const u8 = DEFAULT_INTERP,
    glibc_floor: ?u32 = null,
    roots: []const []const u8 = &.{},
};

pub const Report = struct {
    /// Why it is red; empty when green.
    findings: std.ArrayList([]const u8),
    /// What each program maps, one line per name.
    lines: std.ArrayList([]const u8),
    programs: usize = 0,
    /// Distinct objects of the prefix some program maps.
    mapped: usize = 0,
};

/// A run path entry as a directory relative to the prefix, or why the loader
/// would search outside it.
pub const Expanded = union(enum) { dir: []const u8, why: []const u8 };

pub fn expand(a: std.mem.Allocator, entry: []const u8, origin: []const u8) !Expanded {
    if (entry.len == 0) return .{ .why = "an empty run path entry, which is the working directory" };
    if (entry[0] == '/') return .{ .why = try std.fmt.allocPrint(a, "the absolute run path entry '{s}', which is searched wherever the prefix is installed: outside the prefix", .{entry}) };
    var rest: []const u8 = undefined;
    if (std.mem.startsWith(u8, entry, "${ORIGIN}")) {
        rest = entry[9..];
    } else if (std.mem.startsWith(u8, entry, "$ORIGIN")) {
        rest = entry[7..];
    } else if (std.mem.indexOfScalar(u8, entry, '$') != null) {
        return .{ .why = try std.fmt.allocPrint(a, "the run path entry '{s}', which names a token other than $ORIGIN", .{entry}) };
    } else {
        return .{ .why = try std.fmt.allocPrint(a, "the relative run path entry '{s}', which is relative to the working directory", .{entry}) };
    }
    if (rest.len != 0 and rest[0] != '/') return .{ .why = try std.fmt.allocPrint(a, "the run path entry '{s}', which names a token other than $ORIGIN", .{entry}) };
    if (std.mem.indexOfScalar(u8, rest, '$') != null) return .{ .why = try std.fmt.allocPrint(a, "the run path entry '{s}', which names a token after $ORIGIN", .{entry}) };
    var parts = std.ArrayList([]const u8).init(a);
    var it = std.mem.tokenizeScalar(u8, origin, '/');
    while (it.next()) |p| try parts.append(p);
    it = std.mem.tokenizeScalar(u8, rest, '/');
    while (it.next()) |p| {
        if (std.mem.eql(u8, p, ".")) continue;
        if (std.mem.eql(u8, p, "..")) {
            if (parts.items.len == 0) return .{ .why = try std.fmt.allocPrint(a, "the run path entry '{s}', which leaves the prefix", .{entry}) };
            _ = parts.pop();
            continue;
        }
        try parts.append(p);
    }
    return .{ .dir = try std.mem.join(a, "/", parts.items) };
}

fn dirname(rel: []const u8) []const u8 {
    return std.fs.path.dirname(rel) orelse "";
}

const Prefix = struct {
    a: std.mem.Allocator,
    dir: std.fs.Dir,
    real: []const u8,
    /// path in the prefix -> its parse, for every regular ELF file.
    elfs: std.StringHashMap(Elf),
    report: *Report,

    fn red(self: *Prefix, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.a, fmt, args);
        for (self.report.findings.items) |f| if (std.mem.eql(u8, f, s)) return;
        try self.report.findings.append(s);
    }

    /// The path in the prefix of `rel` with links resolved; `.none` when no
    /// such file exists; `.outside`, red, for a link that leaves the prefix.
    fn locate(self: *Prefix, rel: []const u8) !Located {
        const abs = self.dir.realpathAlloc(self.a, rel) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => return .none,
            else => return e,
        };
        if (abs.len > self.real.len + 1 and std.mem.startsWith(u8, abs, self.real) and abs[self.real.len] == '/')
            return .{ .at = abs[self.real.len + 1 ..] };
        try self.red("{s} resolves to {s}, outside the prefix", .{ rel, abs });
        return .outside;
    }
};

const Mapped = struct {
    rel: []const u8,
    name: []const u8,
    elf: Elf,
    loader: ?usize,
};

const Located = union(enum) { none, outside, at: []const u8 };

/// Where a search found a name: `rel` in the prefix, or a link leaving it
/// (`rel` null, red already).
const Found = struct { rel: ?[]const u8, how: []const u8 };

/// Red for each entry of the run paths of the mapped object `obj` that would
/// search outside the prefix, whether or not a search reaches it: a later
/// dlopen or a name not found earlier would.
fn checkPaths(p: *Prefix, obj: []const u8, elf: Elf) !void {
    for ([_]?[]const u8{ elf.rpath, elf.runpath }, [_][]const u8{ "DT_RPATH", "DT_RUNPATH" }) |rp, tag| {
        var it = std.mem.splitScalar(u8, rp orelse continue, ':');
        while (it.next()) |entry| {
            switch (try expand(p.a, entry, dirname(obj))) {
                .why => |why| try p.red("{s}: its {s} has {s}", .{ obj, tag, why }),
                .dir => {},
            }
        }
    }
}

/// Searches the run path `rp` of the object `obj` for `name`, skipping the
/// entries checkPaths refuses.
fn searchPath(p: *Prefix, obj: []const u8, tag: []const u8, rp: []const u8, name: []const u8) !?Found {
    var it = std.mem.splitScalar(u8, rp, ':');
    while (it.next()) |entry| {
        switch (try expand(p.a, entry, dirname(obj))) {
            .why => {},
            .dir => |d| {
                const cand = if (d.len == 0) name else try std.fmt.allocPrint(p.a, "{s}/{s}", .{ d, name });
                const how = try std.fmt.allocPrint(p.a, "{s} {s} of {s}", .{ tag, entry, obj });
                switch (try p.locate(cand)) {
                    .none => {},
                    .outside => return .{ .rel = null, .how = how },
                    .at => |real| return .{ .rel = real, .how = how },
                }
            },
        }
    }
    return null;
}

fn closure(p: *Prefix, root: []const u8, seen: *std.StringHashMap(void)) !void {
    var maps = std.ArrayList(Mapped).init(p.a);
    try maps.append(.{ .rel = root, .name = root, .elf = p.elfs.get(root).?, .loader = null });
    var i: usize = 0;
    while (i < maps.items.len) : (i += 1) {
        const obj = maps.items[i];
        try checkPaths(p, obj.rel, obj.elf);
        next: for (obj.elf.needed) |name| {
            for (maps.items) |m| {
                if (std.mem.eql(u8, m.name, name)) continue :next;
                if (m.elf.soname) |s| if (std.mem.eql(u8, s, name)) continue :next;
            }
            var found: ?Found = null;
            if (obj.elf.runpath == null) {
                var l: ?usize = i;
                while (l) |li| {
                    const m = maps.items[li];
                    l = m.loader;
                    if (m.elf.runpath != null) continue;
                    if (m.elf.rpath) |rp| {
                        found = try searchPath(p, m.rel, "DT_RPATH", rp, name);
                        if (found != null) break;
                    }
                }
            }
            if (found == null) {
                if (obj.elf.runpath) |rp| {
                    if (try searchPath(p, obj.rel, "DT_RUNPATH", rp, name)) |f| {
                        const at = f.rel orelse continue;
                        try p.red("{s} finds {s} at {s} only through its DT_RUNPATH, which the loader searches after LD_LIBRARY_PATH: it would take {s} from LD_LIBRARY_PATH (link it with a DT_RPATH)", .{ obj.rel, name, at, name });
                        continue;
                    }
                }
            }
            const f = found orelse {
                if (isSystem(name)) {
                    try p.report.lines.append(try std.fmt.allocPrint(p.a, "{s}: {s} <- {s}: the system's", .{ root, name, obj.rel }));
                } else {
                    try p.red("{s} needs {s}, which is not in the prefix: the loader would take it from LD_LIBRARY_PATH or the system", .{ obj.rel, name });
                }
                continue;
            };
            const at = f.rel orelse continue;
            if (isSystem(name)) {
                try p.red("{s} loads {s} from the prefix ({s}, through {s}): a glibc library must come from the system", .{ obj.rel, name, at, f.how });
                continue;
            }
            const elf = p.elfs.get(at) orelse {
                try p.red("{s} needs {s}, found at {s}, which is not an ELF64 little-endian file", .{ obj.rel, name, at });
                continue;
            };
            try p.report.lines.append(try std.fmt.allocPrint(p.a, "{s}: {s} <- {s}: {s} (through {s})", .{ root, name, obj.rel, at, f.how }));
            try maps.append(.{ .rel = at, .name = name, .elf = elf, .loader = i });
            if (!seen.contains(at)) {
                try seen.put(at, {});
                p.report.mapped += 1;
            }
        }
    }
}

/// The check of the prefix `prefix`. Everything is allocated in `a` (an
/// arena: nothing is freed but file contents).
pub fn check(a: std.mem.Allocator, prefix: []const u8, opts: Options) !Report {
    var report = Report{ .findings = std.ArrayList([]const u8).init(a), .lines = std.ArrayList([]const u8).init(a) };
    var dir = try std.fs.cwd().openDir(prefix, .{ .iterate = true });
    defer dir.close();
    var p = Prefix{ .a = a, .dir = dir, .real = try dir.realpathAlloc(a, "."), .elfs = std.StringHashMap(Elf).init(a), .report = &report };

    // Every regular file, in path order; a file read once per inode.
    var paths = std.ArrayList([]const u8).init(a);
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next()) |e| {
        if (e.kind == .file) try paths.append(try a.dupe(u8, e.path));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    var by_inode = std.AutoHashMap(u64, Elf).init(a);
    var over = std.ArrayList(u32).init(a);
    var any_glibc = false;
    const bytes_alloc = std.heap.page_allocator;
    for (paths.items) |rel| {
        const st = try dir.statFile(rel);
        if (by_inode.get(@intCast(st.inode))) |elf| {
            try p.elfs.put(rel, elf);
            continue;
        }
        const f = try dir.openFile(rel, .{});
        var magic: [4]u8 = undefined;
        const n = try f.readAll(&magic);
        f.close();
        if (!isElf(magic[0..n])) continue;
        const b = try dir.readFileAlloc(bytes_alloc, rel, std.math.maxInt(u32));
        defer bytes_alloc.free(b);
        const elf = parse(a, b) catch |e| {
            try p.red("{s}: {s}", .{ rel, switch (e) {
                error.NotElf64 => "an ELF file that is not ELF64 little-endian",
                error.Truncated => "a truncated or malformed ELF file",
                error.BadDynamic => "an ELF file whose dynamic section cannot be read",
                error.OutOfMemory => return e,
            } });
            continue;
        };
        if (opts.glibc_floor) |floor| {
            over.clearRetainingCapacity();
            if (try glibcOver(b, floor, &over)) any_glibc = true;
            if (over.items.len != 0) {
                std.mem.sort(u32, over.items, {}, std.sort.asc(u32));
                var names = std.ArrayList(u8).init(a);
                for (over.items, 0..) |m, k| try names.writer().print("{s}GLIBC_2.{d}", .{ if (k == 0) "" else " ", m });
                try p.red("{s} needs {s}, above the floor GLIBC_2.{d}", .{ rel, names.items, floor });
            }
        }
        try by_inode.put(@intCast(st.inode), elf);
        try p.elfs.put(rel, elf);
    }
    if (opts.glibc_floor != null and !any_glibc and p.elfs.count() > 0)
        try p.red("no ELF file of the prefix names a GLIBC_2. symbol version: not linked against glibc, so the floor check sees nothing", .{});

    for (opts.roots) |r| {
        const elf = p.elfs.get(r) orelse {
            try p.red("{s} is not a regular ELF file of the prefix", .{r});
            continue;
        };
        if (elf.interp == null) try p.red("{s} has no PT_INTERP: not a dynamically linked program", .{r});
    }
    var seen = std.StringHashMap(void).init(a);
    for (paths.items) |rel| {
        const elf = p.elfs.get(rel) orelse continue;
        const interp = elf.interp orelse continue;
        report.programs += 1;
        if (!std.mem.eql(u8, interp, opts.interp))
            try p.red("{s} has the interpreter {s}, not {s}", .{ rel, interp, opts.interp });
        try closure(&p, rel, &seen);
    }
    if (report.programs == 0) try p.red("the prefix holds no dynamically linked program (no ELF file with a PT_INTERP)", .{});
    return report;
}

fn usage() noreturn {
    std.debug.print("usage: loader_closure --prefix <dir> --out <validation.json> [--root <path>]... [--interp <path>] [--glibc-floor <n>]\n", .{});
    std.process.exit(2);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    var prefix: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var opts = Options{};
    var roots = std.ArrayList([]const u8).init(a);
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) usage();
        const k = args[i];
        const v = args[i + 1];
        if (std.mem.eql(u8, k, "--prefix")) {
            prefix = v;
        } else if (std.mem.eql(u8, k, "--out")) {
            out = v;
        } else if (std.mem.eql(u8, k, "--root")) {
            try roots.append(v);
        } else if (std.mem.eql(u8, k, "--interp")) {
            opts.interp = v;
        } else if (std.mem.eql(u8, k, "--glibc-floor")) {
            opts.glibc_floor = std.fmt.parseInt(u32, v, 10) catch usage();
        } else usage();
    }
    opts.roots = roots.items;
    const report = try check(a, prefix orelse usage(), opts);
    if (report.findings.items.len != 0) {
        for (report.findings.items) |f| std.debug.print("loader_closure RED: {s}\n", .{f});
        std.process.exit(1);
    }
    const stdout = std.io.getStdOut().writer();
    for (report.lines.items) |l| try stdout.print("{s}\n", .{l});
    const floor = if (opts.glibc_floor) |f| try std.fmt.allocPrint(a, ", nothing above GLIBC_2.{d}", .{f}) else "";
    const msg = try std.fmt.allocPrint(a, "loader_closure: {d} programs, {d} libraries of the prefix through DT_RPATH, the rest glibc's{s}", .{ report.programs, report.mapped, floor });
    try stdout.print("loader_closure GREEN: {s}\n", .{msg});
    const file = try std.fs.cwd().createFile(out orelse usage(), .{});
    defer file.close();
    try file.writer().print("{{\"version\": 1, \"data\": {{\"status\": \"success\", \"message\": \"{s}\"}}}}\n", .{msg});
}
