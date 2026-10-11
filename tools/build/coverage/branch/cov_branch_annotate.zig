//! cov_branch annotate: applies one welded test's merged branch profile to
//! its LLVM bitcode and writes the annotated IR as text, in a build action
//! (`mojo_cov_branch_annotate`, tools/build/mojo/coverage_branch.bzl;
//! README.md, "cov_branch_annotate").
//!
//! usage: cov_branch annotate --lld <lld> --profdata <llvm-profdata>
//!            --bitcode <bitcode> --profile <profdata> --binary <binary>
//!            --out <ir_out>
//!
//!   --lld       Mojo's LLD 24 (lld/bin/lld of the annotate directory)
//!   --profdata  the pinned llvm-profdata (llvm/bin/llvm-profdata of it)
//!   --bitcode   the test's LLVM bitcode ([coverage][bc][<test>]), the
//!               bitcode its instrumented binary was made from
//!   --profile   the merged profile of its run ([coverage][branch][<test>])
//!   --binary    the instrumented binary that run ran
//!               ([coverage][pgo_bin][<test>])
//!
//! Steps:
//!   0. The bitcode holds no branch weights of its own (no "branch_weights"
//!      metadata string): `pgo-instr-use` leaves the `!prof` it finds on a
//!      branch whose block never ran, which would then read as counts. Nor
//!      does it hold entry counts (no "function_entry_count"), which step 3
//!      counts as the functions the pass found in the profile.
//!   1. The profile holds exactly the functions <binary> links. Every
//!      function of the bitcode is instrumented (cov_branch_link.sh), but the
//!      link (--gc-sections, as a release test's) drops a function nothing
//!      live calls, with its counters and its profile data record. A run
//!      writes the record of every function its binary links, zeros
//!      included, and of no other. So the (name MD5, hash) pairs of
//!      <binary>'s `__llvm_prf_data` records and of the profile's functions
//!      (`llvm-profdata show`) must be one multiset: a record the profile
//!      lacks, or holds besides, is a profile of another binary or a merge
//!      that lost records, and fails the action.
//!   2. lld reads the bitcode as cov_branch_link.sh does (an LTO link with
//!      -r at -O0), with the one pass `pgo-instr-use` reading <profdata>, and
//!      prints the module after that pass (`-print-after=pgo-instr-use
//!      -print-module-scope`, on stderr). Before the dump, LLVM names each
//!      function of the bitcode the profile does not hold
//!      (`-pgo-warn-missing-function`): by step 1 and step 3 together, one
//!      the binary does not link, which never ran; its branches carry no
//!      weights and read as never run.
//!   3. Any other line of lld's own fails the action, naming it: a line
//!      starting `lld: ` (after any program name), `warning: ` or `error: `,
//!      or anything before the dump that is not one of those missing-function
//!      lines. lld must write nothing on its standard output. Then what is
//!      left is exactly one dump: the header line `; *** IR Dump After
//!      PGOInstrumentationUse on [module] ***` first, and no other header.
//!      In it, the pass gave an entry count (`!prof` on the `define`) to as
//!      many functions as the profile holds; fewer is a binary made from
//!      other bitcode, or a function whose hash does not match that LLVM
//!      does not warn about.
//!   4. <ir_out> is the dump, header included, each line ending in a newline.
//!
//! lld and llvm-profdata run with this tool's environment, PATH an empty
//! directory of its scratch, TMPDIR a directory of its scratch and LC_ALL=C.
//! The scratch directory is $BUCK_SCRATCH_PATH/cov_branch_annotate (relative
//! to the working directory when it is relative), or .cov_branch_annotate in
//! the working directory without one; it is removed after a success.
//!
//! Exit status: 1 when a step fails, naming it (`BRANCH COVERAGE ANNOTATE
//! FAILED: ...`; lld or llvm-profdata that cannot be started fails its
//! step, bounded_run's message in what it printed), or <ir_out> cannot be
//! written; 2 for a usage error, an input that is missing or empty, or a
//! process this tool cannot create.

const std = @import("std");
const br = @import("bounded_run.zig");
const run_cmd = @import("cov_branch_run.zig");

pub const USAGE = "usage: cov_branch annotate --lld L --profdata P --bitcode F --profile F --binary F --out F";

pub const HEADER = "; *** IR Dump After PGOInstrumentationUse on [module] ***";
pub const MISSING = "no profile data available for function ";
/// The metadata strings step 0 refuses (each a substring of the bitcode).
pub const WEIGHTS = "branch_weights";
pub const ENTRY_COUNTS = "function_entry_count";
/// The bytes of one `__llvm_prf_data` record (InstrProfData.inc of the
/// pinned LLVM): the name's MD5 (its first 8 bytes), the function's hash,
/// ..., its counter count (a u32 at byte 56).
pub const RECORD = 72;

pub const Args = struct {
    lld: []const u8,
    profdata: []const u8,
    bitcode: []const u8,
    profile: []const u8,
    binary: []const u8,
    out: []const u8,
};

const NAMES = [_][]const u8{ "--lld", "--profdata", "--bitcode", "--profile", "--binary", "--out" };

/// The arguments after `annotate`, or the reason they are refused.
pub fn parseArgs(alloc: std.mem.Allocator, argv: []const []const u8, why: *[]const u8) !?Args {
    var vals = [_]?[]const u8{null} ** NAMES.len;
    var i: usize = 0;
    while (i < argv.len) : (i += 2) {
        const flag = argv[i];
        if (i + 1 >= argv.len) {
            why.* = try std.fmt.allocPrint(alloc, "{s} needs a value", .{flag});
            return null;
        }
        const k = for (NAMES, 0..) |n, j| {
            if (std.mem.eql(u8, n, flag)) break j;
        } else {
            why.* = try std.fmt.allocPrint(alloc, "unknown argument {s}", .{flag});
            return null;
        };
        if (vals[k] != null) {
            why.* = try std.fmt.allocPrint(alloc, "{s} given twice", .{flag});
            return null;
        }
        if (argv[i + 1].len == 0) {
            why.* = try std.fmt.allocPrint(alloc, "{s} is empty", .{flag});
            return null;
        }
        vals[k] = argv[i + 1];
    }
    for (NAMES, vals) |n, v| {
        if (v == null) {
            why.* = try std.fmt.allocPrint(alloc, "{s} is missing", .{n});
            return null;
        }
    }
    return .{ .lld = vals[0].?, .profdata = vals[1].?, .bitcode = vals[2].?, .profile = vals[3].?, .binary = vals[4].?, .out = vals[5].? };
}

/// The scratch directory (module comment).
pub fn scratchDir(alloc: std.mem.Allocator, cwd: []const u8, buck_scratch: ?[]const u8) ![]const u8 {
    const s = buck_scratch orelse "";
    if (s.len == 0) return std.fmt.allocPrint(alloc, "{s}/.cov_branch_annotate", .{cwd});
    if (std.fs.path.isAbsolute(s)) return std.fmt.allocPrint(alloc, "{s}/cov_branch_annotate", .{s});
    return std.fmt.allocPrint(alloc, "{s}/{s}/cov_branch_annotate", .{ cwd, s });
}

/// The environment of lld and llvm-profdata: `base` with PATH=<k>/bin,
/// TMPDIR=<k>/tmp and LC_ALL=C in place of its own.
pub fn toolEnv(alloc: std.mem.Allocator, base: []const []const u8, k: []const u8) ![]const []const u8 {
    var v = std.ArrayList([]const u8).init(alloc);
    for (try run_cmd.childEnv(alloc, base, try std.fmt.allocPrint(alloc, "{s}/bin", .{k}), true)) |e| {
        if (std.mem.startsWith(u8, e, "TMPDIR=")) continue;
        try v.append(e);
    }
    try v.append(try std.fmt.allocPrint(alloc, "TMPDIR={s}/tmp", .{k}));
    return v.toOwnedSlice();
}

/// lld's command line for step 2 (`bc`, `prof` and `k` absolute).
pub fn lldArgv(alloc: std.mem.Allocator, lld: []const u8, bc: []const u8, prof: []const u8, k: []const u8) ![]const []const u8 {
    return alloc.dupe([]const u8, &.{
        lld,
        "-flavor",
        "gnu",
        "-r",
        "-m",
        "elf_x86_64",
        bc,
        "-o",
        try std.fmt.allocPrint(alloc, "{s}/use.o", .{k}),
        "--lto-O0",
        "--lto-newpm-passes=pgo-instr-use",
        "-mllvm",
        try std.fmt.allocPrint(alloc, "-pgo-test-profile-file={s}", .{prof}),
        "-mllvm",
        "-pgo-warn-missing-function",
        "-mllvm",
        "-print-after=pgo-instr-use",
        "-mllvm",
        "-print-module-scope",
    });
}

/// The lines of `text`: split at each newline, a final newline ending the
/// last line rather than starting an empty one (as awk and grep read).
pub fn lines(alloc: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var v = std.ArrayList([]const u8).init(alloc);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try v.append(l);
    if (v.items.len > 0 and v.items[v.items.len - 1].len == 0) _ = v.pop();
    return v.toOwnedSlice();
}

/// The first `n` bytes of `s` (`cut -c1-N` in the C locale).
fn cut(s: []const u8, n: usize) []const u8 {
    return s[0..@min(s.len, n)];
}

/// The first `n` of `ls`, each cut to `width` bytes and followed by a space
/// (`head -n N | cut -c1-W | tr '\n' ' '`).
pub fn joinHead(alloc: std.mem.Allocator, ls: []const []const u8, n: usize, width: usize) ![]const u8 {
    var out = std.ArrayList(u8).init(alloc);
    for (ls[0..@min(ls.len, n)]) |l| {
        try out.appendSlice(cut(l, width));
        try out.append(' ');
    }
    return out.toOwnedSlice();
}

/// Whether `line` matches `^[^ ]*<lit>`: `lit` (which holds a space) after
/// a prefix with no space.
pub fn afterWord(line: []const u8, lit: []const u8) ?usize {
    const ls = std.mem.indexOfScalar(u8, lit, ' ').?;
    const fs = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    if (fs < ls) return null;
    const p = fs - ls;
    if (!std.mem.startsWith(u8, line[p..], lit)) return null;
    return p + lit.len;
}

/// A line LLVM prints for a function of the bitcode the profile does not
/// hold: `^[^ ]*lld: warning: [^ ]*: no profile data available for function
/// ` and ` Hash = [0-9]+ up to 0 count discarded$`.
pub fn isMissingLine(line: []const u8) bool {
    const a = afterWord(line, "lld: warning: ") orelse return false;
    if (afterWord(line[a..], ": " ++ MISSING) == null) return false;
    const tail = " up to 0 count discarded";
    if (!std.mem.endsWith(u8, line, tail)) return false;
    const head = line[0 .. line.len - tail.len];
    var d = head.len;
    while (d > 0 and std.ascii.isDigit(head[d - 1])) d -= 1;
    return d < head.len and std.mem.endsWith(u8, head[0..d], " Hash = ");
}

/// A line of lld's own inside the dump: `^([^ ]*lld: |warning: |error: )`.
pub fn isDiagLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "warning: ") or std.mem.startsWith(u8, line, "error: ") or afterWord(line, "lld: ") != null;
}

/// A function the pass gave an entry count: `^define .* !prof ![0-9]`.
pub fn isCountedDefine(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "define ")) return false;
    var at: usize = "define ".len;
    while (std.mem.indexOfPos(u8, line, at, " !prof !")) |p| {
        const d = p + " !prof !".len;
        if (d < line.len and std.ascii.isDigit(line[d])) return true;
        at = p + 1;
    }
    return false;
}

/// Why the bitcode `bc` (named `name`) is refused before the profile is
/// applied (its magic, step 0), or null.
pub fn checkBitcode(alloc: std.mem.Allocator, name: []const u8, bc: []const u8) !?[]const u8 {
    if (bc.len < 4 or !std.mem.eql(u8, bc[0..4], "\x42\x43\xc0\xde")) {
        return try std.fmt.allocPrint(alloc, "{s} is not LLVM bitcode", .{name});
    }
    if (std.mem.indexOf(u8, bc, WEIGHTS) != null) {
        return try std.fmt.allocPrint(alloc, "{s} already holds branch weights before the profile is applied (a \"branch_weights\" metadata string): pgo-instr-use keeps them on branches that never ran, where they would read as counts", .{name});
    }
    if (std.mem.indexOf(u8, bc, ENTRY_COUNTS) != null) {
        return try std.fmt.allocPrint(alloc, "{s} already holds function entry counts before the profile is applied (a \"function_entry_count\" metadata string): step 3 counts the functions pgo-instr-use found in the profile by their entry counts", .{name});
    }
    return null;
}

/// What step 1 reads of the binary: one "<name MD5 prefix> <hash>" per
/// record (16 hex digits each), sorted, and how many records its
/// `__llvm_prf_data` holds; or why it is refused.
pub const BinaryRecords = struct {
    recs: []const []const u8 = &.{},
    records: u64 = 0,
    why: ?[]const u8 = null,
};

/// The little-endian field of `n` bytes at `off`, or null past the end.
fn field(b: []const u8, off: u64, n: usize) ?u64 {
    if (off > b.len or b.len - off < n) return null;
    const o: usize = @intCast(off);
    var v: u64 = 0;
    var j: usize = n;
    while (j > 0) : (j -= 1) v = (v << 8) | b[o + j - 1];
    return v;
}

/// The bytes of `b` from `off`, at most `n` (fewer at its end).
fn span(b: []const u8, off: u64, n: u64) []const u8 {
    if (off >= b.len) return b[0..0];
    const o: usize = @intCast(off);
    return b[o..@min(b.len, o + @as(usize, @intCast(@min(n, b.len))))];
}

fn sortStrings(items: [][]const u8) void {
    std.mem.sort([]const u8, items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
}

/// Step 1, the binary's side (`name` names it in messages).
pub fn binaryRecords(alloc: std.mem.Allocator, name: []const u8, bin: []const u8) !BinaryRecords {
    const refuse = struct {
        fn f(a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !BinaryRecords {
            return .{ .why = try std.fmt.allocPrint(a, fmt, args) };
        }
    }.f;
    if (bin.len < 6 or !std.mem.eql(u8, bin[0..6], "\x7fELF\x02\x01")) return refuse(alloc, "{s} is not a 64-bit little-endian ELF file", .{name});
    const shoff = field(bin, 40, 8);
    const shentsize = field(bin, 58, 2);
    const shnum = field(bin, 60, 2);
    const shstrndx = field(bin, 62, 2);
    // The table must lie in the file (`od` past the end reads nothing).
    const table_ok = shoff != null and shentsize != null and shnum != null and shstrndx != null and shentsize.? == 64 and shnum.? > 0 and shstrndx.? < shnum.? and
        shoff.? <= bin.len and (bin.len - shoff.?) / 64 >= shnum.?;
    if (!table_ok) {
        return refuse(alloc, "{s} has no section header table this tool reads (entry size '{?d}', {?d} entries, names at {?d})", .{ name, shentsize, shnum, shstrndx });
    }
    const strtab = field(bin, shoff.? + shstrndx.? * 64 + 24, 8).?;
    var data_off: ?u64 = null;
    var data_size: u64 = 0;
    var cnts_size: ?u64 = null;
    var i: u64 = 0;
    while (i < shnum.?) : (i += 1) {
        const h = shoff.? + i * 64;
        // The name: up to 16 bytes at its offset, cut at a NUL or newline.
        const raw = span(bin, strtab +| field(bin, h, 4).?, 16);
        const end = std.mem.indexOfAny(u8, raw, "\x00\n") orelse raw.len;
        const sec = raw[0..end];
        if (std.mem.eql(u8, sec, "__llvm_prf_data")) {
            if (data_off != null) return refuse(alloc, "{s} has two __llvm_prf_data sections", .{name});
            data_off = field(bin, h + 24, 8).?;
            data_size = field(bin, h + 32, 8).?;
        } else if (std.mem.eql(u8, sec, "__llvm_prf_cnts")) {
            if (cnts_size != null) return refuse(alloc, "{s} has two __llvm_prf_cnts sections", .{name});
            cnts_size = field(bin, h + 32, 8).?;
        }
    }
    if (data_off == null or cnts_size == null) return refuse(alloc, "{s} has no __llvm_prf_data or no __llvm_prf_cnts section: it is not an instrumented binary", .{name});
    if (data_size == 0 or data_size % RECORD != 0) return refuse(alloc, "{s}'s __llvm_prf_data is {d} bytes, not a whole number of 72-byte records", .{ name, data_size });
    const records = data_size / RECORD;
    // What the file holds of the section (all of it, unless it is cut short).
    const data = span(bin, data_off.?, data_size);
    var counters: u64 = 0;
    var w: usize = 0;
    while (w * 4 < data.len) : (w += 1) {
        if (w % (RECORD / 4) != 14) continue;
        var word = [_]u8{0} ** 4;
        const s = data[w * 4 .. @min(data.len, w * 4 + 4)];
        @memcpy(word[0..s.len], s);
        counters +%= std.mem.readInt(u32, &word, .little);
    }
    if (counters *% 8 != cnts_size.?) {
        return refuse(alloc, "{s}'s {d} profile data records count {d} counters, but its __llvm_prf_cnts is {d} bytes: not the 72-byte record this tool reads", .{ name, records, counters, cnts_size.? });
    }
    const whole = data.len / RECORD;
    if (whole != records) return refuse(alloc, "could not read {d} records from {s}'s __llvm_prf_data", .{ records, name });
    const recs = try alloc.alloc([]const u8, whole);
    for (recs, 0..) |*r, n| {
        const rec = data[n * RECORD ..][0..RECORD];
        r.* = try std.fmt.allocPrint(alloc, "{s} {x:0>16}", .{ std.fmt.fmtSliceHexLower(rec[0..8]), std.mem.readInt(u64, rec[8..16], .little) });
    }
    sortStrings(recs);
    return .{ .recs = recs, .records = records };
}

/// What step 1 reads of `llvm-profdata show --all-functions`: each
/// function's "<name MD5 prefix> <hash>", its name, and the `Total
/// functions:` count; or why it is refused.
pub const ProfileFunctions = struct {
    /// "<md5 prefix> <hash> <n>", n the function's 1-based place in the
    /// listing, sorted as strings.
    full: []const []const u8 = &.{},
    /// The names, by n - 1.
    names: []const []const u8 = &.{},
    /// The count `show` reports, as it printed it.
    fns: []const u8 = "",
    why: ?[]const u8 = null,
};

/// Step 1, the profile's side (`name` names the profile in messages). A
/// name line is two spaces, the name and a colon; the next line must be
/// `    Hash: 0x<hex>`.
pub fn profileFunctions(alloc: std.mem.Allocator, name: []const u8, show: []const u8) !ProfileFunctions {
    var full = std.ArrayList([]const u8).init(alloc);
    var names = std.ArrayList([]const u8).init(alloc);
    var totals = std.ArrayList([]const u8).init(alloc);
    var held = false;
    const ls = try lines(alloc, show);
    for (ls, 1..) |l, nr| {
        const is_name = l.len >= 3 and std.mem.startsWith(u8, l, "  ") and l[2] != ' ' and l[l.len - 1] == ':';
        if (!held and is_name) {
            try names.append(l[2 .. l.len - 1]);
            held = true;
            continue;
        }
        if (held) {
            const p = "    Hash: 0x";
            const hex = if (std.mem.startsWith(u8, l, p)) l[p.len..] else "";
            const ok = hex.len > 0 and for (hex) |c| {
                if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) break false;
            } else true;
            if (!ok) {
                return .{ .why = try std.fmt.allocPrint(alloc, "the function list of {s} could not be read (llvm-profdata show, line {d})", .{ name, nr }) };
            }
            var md5: [16]u8 = undefined;
            std.crypto.hash.Md5.hash(names.items[names.items.len - 1], &md5, .{});
            const pad = if (hex.len < 16) 16 - hex.len else 0;
            try full.append(try std.fmt.allocPrint(alloc, "{s} {s}{s} {d}", .{ std.fmt.fmtSliceHexLower(md5[0..8]), "0000000000000000"[0..pad], hex, names.items.len }));
            held = false;
            continue;
        }
        const t = "Total functions: ";
        if (std.mem.startsWith(u8, l, t) and l.len > t.len) {
            const d = l[t.len..];
            for (d) |c| {
                if (!std.ascii.isDigit(c)) break;
            } else try totals.append(d);
        }
    }
    const fns = if (totals.items.len == 0) "none" else try std.mem.join(alloc, "\n", totals.items);
    const read = try std.fmt.allocPrint(alloc, "{d}", .{full.items.len});
    if (!std.mem.eql(u8, read, fns)) {
        return .{ .why = try std.fmt.allocPrint(alloc, "read {s} functions from {s}, but llvm-profdata show reports '{s}'", .{ read, name, fns }) };
    }
    sortStrings(full.items);
    return .{ .full = try full.toOwnedSlice(), .names = try names.toOwnedSlice(), .fns = fns };
}

/// The first two fields of a "<md5> <hash> <n>" line.
fn pairOf(s: []const u8) []const u8 {
    const a = std.mem.indexOfScalar(u8, s, ' ') orelse return s;
    const b = std.mem.indexOfScalarPos(u8, s, a + 1, ' ') orelse return s;
    return s[0..b];
}

/// `a` minus `b`, both sorted, as multisets (`comm -23`).
pub fn minus(alloc: std.mem.Allocator, a: []const []const u8, b: []const []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(alloc);
    var j: usize = 0;
    for (a) |x| {
        while (j < b.len and std.mem.lessThan(u8, b[j], x)) j += 1;
        if (j < b.len and std.mem.eql(u8, b[j], x)) {
            j += 1;
            continue;
        }
        try out.append(x);
    }
    return out.toOwnedSlice();
}

/// Step 1: why the binary's records and the profile's functions are not
/// one multiset, or null.
pub fn compareRecords(alloc: std.mem.Allocator, prof_name: []const u8, bin_name: []const u8, bin: BinaryRecords, prof: ProfileFunctions) !?[]const u8 {
    const pairs = try alloc.alloc([]const u8, prof.full.len);
    for (prof.full, pairs) |f, *p| p.* = pairOf(f);
    // `full` is sorted with its place appended; the pairs alone sort the same
    // but for equal pairs, which minus() does not tell apart.
    sortStrings(pairs);
    const lost = try minus(alloc, bin.recs, pairs);
    if (lost.len > 0) {
        return try std.fmt.allocPrint(alloc, "the profile {s} holds no record of {d} of the {d} functions {s} links (name MD5 prefix, hash: {s}): a run writes the record of every function its binary links, ran or not, so this is a profile of another binary, or a merge that lost records", .{ prof_name, lost.len, bin.records, bin_name, try joinHead(alloc, lost, 3, std.math.maxInt(usize)) });
    }
    const extra = try minus(alloc, pairs, bin.recs);
    if (extra.len > 0) {
        var first: []const u8 = "";
        outer: for (prof.full) |f| {
            for (extra) |x| {
                if (std.mem.eql(u8, pairOf(f), x)) {
                    const n = try std.fmt.parseInt(usize, f[std.mem.lastIndexOfScalar(u8, f, ' ').? + 1 ..], 10);
                    first = prof.names[n - 1];
                    break :outer;
                }
            }
        }
        return try std.fmt.allocPrint(alloc, "the profile {s} holds {d} function(s) {s} does not link, the first {s}: a profile of another binary", .{ prof_name, extra.len, bin_name, cut(first, 300) });
    }
    return null;
}

/// Steps 3 and 4 over what lld wrote (`err`, `out`): the dump, or why it
/// is refused. `fns` is the profile's count of functions (step 1).
pub const Dump = struct {
    ir: []const u8 = "",
    why: ?[]const u8 = null,
};

pub fn checkDump(alloc: std.mem.Allocator, err: []const u8, out: []const u8, fns: []const u8, prof_name: []const u8, bc_name: []const u8) !Dump {
    const ls = try lines(alloc, err);
    var diag = std.ArrayList([]const u8).init(alloc);
    var start: ?usize = null;
    for (ls, 0..) |l, i| {
        if (std.mem.eql(u8, l, HEADER)) {
            start = i;
            break;
        }
        if (!isMissingLine(l)) try diag.append(l);
    }
    const dump = if (start) |s| ls[s..] else ls[0..0];
    for (dump) |l| {
        if (isDiagLine(l)) try diag.append(l);
    }
    if (diag.items.len > 0) {
        // Counted as `grep -c .` counts: the lines that are not empty.
        var n: usize = 0;
        for (diag.items) |x| n += @intFromBool(x.len > 0);
        return .{ .why = try std.fmt.allocPrint(alloc, "lld reported {d} diagnostic(s) applying the profile: {s}", .{ n, try joinHead(alloc, diag.items, 5, 300) }) };
    }
    if (out.len > 0) {
        return .{ .why = try std.fmt.allocPrint(alloc, "lld wrote to its standard output: {s}", .{try joinHead(alloc, try lines(alloc, out), 3, std.math.maxInt(usize))}) };
    }
    if (dump.len == 0 or !std.mem.eql(u8, dump[0], HEADER)) {
        return .{ .why = try std.fmt.allocPrint(alloc, "lld's output does not start with the dump header '{s}': {s}", .{ HEADER, if (dump.len > 0) cut(dump[0], 200) else "" }) };
    }
    var headers: usize = 0;
    var found: usize = 0;
    var size: usize = 0;
    for (dump) |l| {
        if (std.mem.indexOf(u8, l, "; *** IR Dump ") != null) headers += 1;
        if (isCountedDefine(l)) found += 1;
        size += l.len + 1;
    }
    if (headers != 1) return .{ .why = try std.fmt.allocPrint(alloc, "lld printed {d} IR dumps, expected exactly one", .{headers}) };
    const f = try std.fmt.allocPrint(alloc, "{d}", .{found});
    if (!std.mem.eql(u8, f, fns)) {
        return .{ .why = try std.fmt.allocPrint(alloc, "pgo-instr-use found {s} of the {s} functions of the profile {s} in {s}: the binary that wrote it was not made from this bitcode", .{ f, fns, prof_name, bc_name }) };
    }
    const ir = try alloc.alloc(u8, size);
    var at: usize = 0;
    for (dump) |l| {
        @memcpy(ir[at..][0..l.len], l);
        ir[at + l.len] = '\n';
        at += l.len + 1;
    }
    return .{ .ir = ir };
}

/// One process of a step, through `runner`.
fn step(runner: run_cmd.Runner, alloc: std.mem.Allocator, spec: br.Spec) !br.Outcome {
    return runner.runFn(runner.ptr, alloc, spec);
}

fn red(err: *std.ArrayList(u8), why: []const u8) !u8 {
    try err.writer().print("BRANCH COVERAGE ANNOTATE FAILED: {s}\n", .{why});
    return 1;
}

fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.fs.cwd().readFileAlloc(alloc, path, std.math.maxInt(usize));
}

/// Whether `path` names a file (or a link to one) that is not empty.
fn nonEmpty(path: []const u8) bool {
    const st = std.fs.cwd().statFile(path) catch return false;
    return st.size > 0;
}

/// Steps 0 to 4 (module comment). Messages go to `err`; returns the exit status.
pub fn runAll(alloc: std.mem.Allocator, a: Args, where: run_cmd.Where, runner: run_cmd.Runner, err: *std.ArrayList(u8)) !u8 {
    const k = where.k;
    for ([_][]const u8{ a.lld, a.profdata, a.bitcode, a.profile, a.binary }) |f| {
        if (!nonEmpty(f)) {
            try err.writer().print("cov_branch annotate: {s} is missing or empty\n", .{f});
            return 2;
        }
    }
    try std.fs.cwd().makePath(try std.fmt.allocPrint(alloc, "{s}/bin", .{k}));
    try std.fs.cwd().makePath(try std.fmt.allocPrint(alloc, "{s}/tmp", .{k}));
    const env = try toolEnv(alloc, where.env, k);
    const lld = try run_cmd.abs(alloc, where.cwd, a.lld);
    const prof = try run_cmd.abs(alloc, where.cwd, a.profile);
    const bc = try run_cmd.abs(alloc, where.cwd, a.bitcode);

    // 0. No branch weights before the profile is applied, and no entry counts.
    const bc_bytes = readFile(alloc, bc) catch |e| return red(err, try std.fmt.allocPrint(alloc, "could not read {s}: {s}", .{ a.bitcode, @errorName(e) }));
    if (try checkBitcode(alloc, a.bitcode, bc_bytes)) |why| return red(err, why);

    // 1. The profile holds exactly the functions the binary links.
    const bin_bytes = readFile(alloc, a.binary) catch |e| return red(err, try std.fmt.allocPrint(alloc, "could not read {s}: {s}", .{ a.binary, @errorName(e) }));
    const recs = try binaryRecords(alloc, a.binary, bin_bytes);
    if (recs.why) |why| return red(err, why);
    const show_txt = try std.fmt.allocPrint(alloc, "{s}/show.txt", .{k});
    const show_err = try std.fmt.allocPrint(alloc, "{s}/show.err", .{k});
    const s = step(runner, alloc, .{
        .argv = &.{ try run_cmd.abs(alloc, where.cwd, a.profdata), "show", "--all-functions", prof },
        .env = env,
        .stdout_path = show_txt,
        .stderr_path = show_err,
    }) catch |e| {
        try err.writer().print("cov_branch annotate: cannot run {s}: {s}\n", .{ a.profdata, @errorName(e) });
        return 2;
    };
    if (s.shellStatus() != 0) {
        const head = try joinHead(alloc, try lines(alloc, readFile(alloc, show_err) catch ""), 2, std.math.maxInt(usize));
        return red(err, try std.fmt.allocPrint(alloc, "llvm-profdata show failed on {s}: {s}", .{ a.profile, head }));
    }
    const fns = try profileFunctions(alloc, a.profile, readFile(alloc, show_txt) catch "");
    if (fns.why) |why| return red(err, why);
    if (try compareRecords(alloc, a.profile, a.binary, recs, fns)) |why| return red(err, why);

    // 2. The profile applied, the module printed after the pass.
    const lld_out = try std.fmt.allocPrint(alloc, "{s}/out", .{k});
    const lld_err = try std.fmt.allocPrint(alloc, "{s}/err", .{k});
    const l = step(runner, alloc, .{
        .argv = try lldArgv(alloc, lld, bc, prof, k),
        .env = env,
        .stdout_path = lld_out,
        .stderr_path = lld_err,
    }) catch |e| {
        try err.writer().print("cov_branch annotate: cannot run {s}: {s}\n", .{ a.lld, @errorName(e) });
        return 2;
    };
    const lld_text = readFile(alloc, lld_err) catch "";
    if (l.shellStatus() != 0) {
        // Its message is at the end of what it printed (the dump, if any, first).
        const ls = try lines(alloc, lld_text);
        for (ls[ls.len -| 20..]) |x| {
            try err.appendSlice(cut(x, 300));
            try err.append('\n');
        }
        return red(err, try std.fmt.allocPrint(alloc, "lld could not apply the profile {s} to {s} (pgo-instr-use)", .{ a.profile, a.bitcode }));
    }

    // 3. Only the functions the profile does not hold before the header, no
    // other diagnostic, one dump, and an entry count for each function of
    // the profile.
    const dump = try checkDump(alloc, lld_text, readFile(alloc, lld_out) catch "", fns.fns, a.profile, a.bitcode);
    if (dump.why) |why| return red(err, why);

    // 4. The dump.
    std.fs.cwd().writeFile(try run_cmd.abs(alloc, where.cwd, a.out), dump.ir) catch |e| {
        try err.writer().print("cov_branch annotate: cannot write {s}: {s}\n", .{ a.out, @errorName(e) });
        return 1;
    };
    std.fs.cwd().deleteTree(k) catch {};
    return 0;
}

/// `cov_branch annotate <argv>`: parses and runs. Returns the exit status;
/// messages go to `err`.
pub fn cli(alloc: std.mem.Allocator, argv: []const []const u8, where: run_cmd.Where, runner: run_cmd.Runner, err: *std.ArrayList(u8)) !u8 {
    var why: []const u8 = "";
    const a = (try parseArgs(alloc, argv, &why)) orelse {
        try err.writer().print("cov_branch annotate: usage error: {s}\n{s}\n", .{ why, USAGE });
        return 2;
    };
    return runAll(alloc, a, where, runner, err);
}
