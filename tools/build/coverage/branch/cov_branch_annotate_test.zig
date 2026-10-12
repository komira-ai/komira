//! Unit tests of `cov_branch annotate` (cov_branch_annotate.zig), run by
//! `zig test` as a build action (`:cov_branch_unit`). llvm-profdata and lld
//! are a stand-in (`Fake`, a Runner) that writes what the real program would
//! (`show`'s listing, lld's stderr and stdout, its exit status), and the
//! binary and bitcode are made by hand (cov_branch_annotate_fixture.zig), so
//! every check of the subcommand is reached without a test or LLVM. Each
//! test names the check it covers; what a real annotation does end to end is
//! test 47's (tools/build/tests/coverage_runs.md).

const std = @import("std");
const br = @import("bounded_run.zig");
const run_cmd = @import("cov_branch_run.zig");
const an = @import("cov_branch_annotate.zig");
const fx = @import("cov_branch_annotate_fixture.zig");
const testing = std.testing;

const Fake = struct {
    show_text: []const u8 = "",
    show_err: []const u8 = "",
    show_status: br.Status = .{ .exited = 0 },
    lld_err: []const u8 = "",
    lld_out: []const u8 = "",
    lld_status: br.Status = .{ .exited = 0 },
    /// The step (`show` or `-flavor`) whose process cannot be created.
    fail: ?[]const u8 = null,
    /// Calls at whose start PATH or TMPDIR of the environment given was not
    /// a directory (the script made both before either program ran).
    no_dir: usize = 0,
    calls: std.ArrayList(br.Spec),

    fn runner(self: *Fake) run_cmd.Runner {
        return .{ .ptr = self, .runFn = &run };
    }

    fn write(path: []const u8, data: []const u8) !void {
        try std.fs.cwd().writeFile(path, data);
    }

    fn run(ptr: *anyopaque, alloc: std.mem.Allocator, spec: br.Spec) anyerror!br.Outcome {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        var copy = spec;
        copy.argv = try alloc.dupe([]const u8, spec.argv);
        copy.env = try alloc.dupe([]const u8, spec.env);
        try self.calls.append(copy);
        for ([_][]const u8{ "PATH=", "TMPDIR=" }) |p| {
            const v = for (spec.env) |e| {
                if (std.mem.startsWith(u8, e, p)) break e[p.len..];
            } else "";
            var d = std.fs.cwd().openDir(v, .{}) catch {
                self.no_dir += 1;
                continue;
            };
            d.close();
        }
        if (self.fail) |f| if (std.mem.eql(u8, spec.argv[1], f)) return error.SystemResources;
        var status: br.Status = .{ .exited = 0 };
        if (std.mem.eql(u8, spec.argv[1], "show")) {
            try write(spec.stdout_path.?, self.show_text);
            try write(spec.stderr_path.?, self.show_err);
            status = self.show_status;
        } else if (std.mem.eql(u8, spec.argv[1], "-flavor")) {
            try write(spec.stdout_path.?, self.lld_out);
            try write(spec.stderr_path.?, self.lld_err);
            status = self.lld_status;
        } else return error.UnknownStep;
        return .{ .status = status, .timed_out = false, .pgid = null, .survivors = &.{} };
    }
};

pub const Case = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    root: []const u8 = "",
    err: std.ArrayList(u8) = undefined,
    fake: Fake = undefined,

    pub fn init() !*Case {
        const c = try testing.allocator.create(Case);
        c.* = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator), .tmp = testing.tmpDir(.{}) };
        const al = c.arena.allocator();
        c.root = try c.tmp.dir.realpathAlloc(al, ".");
        c.err = std.ArrayList(u8).init(al);
        c.fake = .{ .calls = std.ArrayList(br.Spec).init(al) };
        // Inputs that pass every check, each test changing one.
        try c.tmp.dir.makePath("tc/lld/bin");
        try c.tmp.dir.makePath("tc/llvm/bin");
        try c.tmp.dir.makePath("out");
        try c.put("tc/lld/bin/lld", "lld");
        try c.put("tc/llvm/bin/llvm-profdata", "llvm-profdata");
        try c.put("in/test_one.bc", try fx.bitcode(al, "body"));
        try c.put("in/test_one.profdata", "indexed");
        try c.put("in/test_one", try fx.binary(al, &fx.FNS));
        // A file beside the scratch directory, as Buck2's scratch holds others.
        try c.put("scratch/keep", "");
        c.fake.show_text = try fx.show(al, &fx.FNS);
        c.fake.lld_err = try std.mem.concat(al, u8, &.{ try fx.missing(al, "unrun"), try fx.dump(al, &fx.FNS) });
        return c;
    }

    pub fn deinit(self: *Case) void {
        self.tmp.cleanup();
        self.arena.deinit();
        testing.allocator.destroy(self);
    }

    pub fn a(self: *Case) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn put(self: *Case, rel: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(rel)) |d| try self.tmp.dir.makePath(d);
        try self.tmp.dir.writeFile(rel, data);
    }

    pub fn k(self: *Case) ![]const u8 {
        return std.fmt.allocPrint(self.a(), "{s}/scratch/cov_branch_annotate", .{self.root});
    }

    fn where(self: *Case) !run_cmd.Where {
        return .{
            .cwd = self.root,
            .k = try self.k(),
            .env = &.{ "HOME=/home/user", "LC_ALL=fr_FR.UTF-8", "PATH=/usr/bin:/bin", "TMPDIR=/tmp", "TMPDIR_OLD=keep", "ZED=1" },
        };
    }

    pub fn argv(self: *Case) []const []const u8 {
        _ = self;
        return &.{ "--lld", "tc/lld/bin/lld", "--profdata", "tc/llvm/bin/llvm-profdata", "--bitcode", "in/test_one.bc", "--profile", "in/test_one.profdata", "--binary", "in/test_one", "--out", "out/test_one.ll" };
    }

    /// Runs the subcommand with `argv` from the case's directory (paths
    /// relative to it, as a build action's are to its working directory).
    pub fn goWith(self: *Case, args: []const []const u8) !u8 {
        self.err.clearRetainingCapacity();
        var old = try std.fs.cwd().openDir(".", .{});
        defer old.close();
        try std.posix.fchdir(self.tmp.dir.fd);
        defer std.posix.fchdir(old.fd) catch {};
        return an.cli(self.a(), args, try self.where(), self.fake.runner(), &self.err);
    }

    pub fn go(self: *Case) !u8 {
        return self.goWith(self.argv());
    }

    pub fn has(self: *Case, text: []const u8) bool {
        return std.mem.indexOf(u8, self.err.items, text) != null;
    }

    /// A refusal: exit 1, `text` in the message, and no output written.
    pub fn refused(self: *Case, text: []const u8) !void {
        const code = try self.go();
        if (code != 1 or !self.has("BRANCH COVERAGE ANNOTATE FAILED: ") or !self.has(text)) {
            std.debug.print("want exit 1 with '{s}'; got {d}:\n{s}\n", .{ text, code, self.err.items });
            return error.TestUnexpectedResult;
        }
        try testing.expectError(error.FileNotFound, self.tmp.dir.access("out/test_one.ll", .{}));
        // The scratch directory is kept for the failed action's reader.
        try self.tmp.dir.access("scratch/cov_branch_annotate", .{});
    }
};

fn hasEntry(env: []const []const u8, e: []const u8) bool {
    for (env) |x| if (std.mem.eql(u8, x, e)) return true;
    return false;
}

fn countPrefix(env: []const []const u8, p: []const u8) usize {
    var n: usize = 0;
    for (env) |x| n += @intFromBool(std.mem.startsWith(u8, x, p));
    return n;
}

test "a passing annotation: show's and lld's command lines and environment, the dump written, the scratch removed" {
    var c = try Case.init();
    defer c.deinit();
    try testing.expectEqual(@as(u8, 0), try c.go());
    try testing.expectEqualStrings("", c.err.items);
    // The dump, from its header on: the missing-function line before it dropped.
    const ir = try c.tmp.dir.readFileAlloc(c.a(), "out/test_one.ll", 1 << 20);
    try testing.expectEqualStrings(try fx.dump(c.a(), &fx.FNS), ir);
    try testing.expectError(error.FileNotFound, c.tmp.dir.access("scratch/cov_branch_annotate", .{}));
    // Only it: what else the scratch holds stays.
    try c.tmp.dir.access("scratch/keep", .{});
    // Both programs found PATH and TMPDIR made, as directories.
    try testing.expectEqual(@as(usize, 0), c.fake.no_dir);

    const k = try c.k();
    const ab = struct {
        fn f(cc: *Case, p: []const u8) ![]const u8 {
            return std.fmt.allocPrint(cc.a(), "{s}/{s}", .{ cc.root, p });
        }
    }.f;
    try testing.expectEqual(@as(usize, 2), c.fake.calls.items.len);
    const show = c.fake.calls.items[0];
    const want_show = [_][]const u8{ try ab(c, "tc/llvm/bin/llvm-profdata"), "show", "--all-functions", try ab(c, "in/test_one.profdata") };
    try testing.expectEqual(want_show.len, show.argv.len);
    for (want_show, show.argv) |w, g| try testing.expectEqualStrings(w, g);
    const lld = c.fake.calls.items[1];
    const want_lld = [_][]const u8{
        try ab(c, "tc/lld/bin/lld"),                                                                    "-flavor",                            "gnu", "-r", "-m", "elf_x86_64",
        try ab(c, "in/test_one.bc"),                                                                    "-o",                                 try std.fmt.allocPrint(c.a(), "{s}/use.o", .{k}),
        "--lto-O0",                                                                                     "--lto-newpm-passes=pgo-instr-use",   "-mllvm",
        try std.fmt.allocPrint(c.a(), "-pgo-test-profile-file={s}", .{try ab(c, "in/test_one.profdata")}), "-mllvm",                          "-pgo-warn-missing-function",
        "-mllvm",                                                                                       "-print-after=pgo-instr-use",         "-mllvm",
        "-print-module-scope",
    };
    try testing.expectEqual(want_lld.len, lld.argv.len);
    for (want_lld, lld.argv) |w, g| try testing.expectEqualStrings(w, g);
    // Both run with this tool's environment, PATH, TMPDIR and LC_ALL its own.
    for ([_]br.Spec{ show, lld }) |s| {
        try testing.expect(hasEntry(s.env, try std.fmt.allocPrint(c.a(), "PATH={s}/bin", .{k})));
        try testing.expect(hasEntry(s.env, try std.fmt.allocPrint(c.a(), "TMPDIR={s}/tmp", .{k})));
        try testing.expect(hasEntry(s.env, "LC_ALL=C"));
        try testing.expect(hasEntry(s.env, "HOME=/home/user"));
        try testing.expect(hasEntry(s.env, "ZED=1"));
        // Only TMPDIR itself is replaced, not a variable whose name starts with it.
        try testing.expect(hasEntry(s.env, "TMPDIR_OLD=keep"));
        try testing.expectEqual(@as(usize, 1), countPrefix(s.env, "PATH="));
        try testing.expectEqual(@as(usize, 1), countPrefix(s.env, "TMPDIR="));
        try testing.expectEqual(@as(usize, 1), countPrefix(s.env, "LC_ALL="));
        try testing.expect(s.limit_ms == null);
        try testing.expect(!s.stderr_to_stdout);
    }
}

test "the dump's last line gets a newline when lld's stderr has none" {
    var c = try Case.init();
    defer c.deinit();
    const d = try fx.dump(c.a(), &fx.FNS);
    c.fake.lld_err = d[0 .. d.len - 1];
    try testing.expectEqual(@as(u8, 0), try c.go());
    try testing.expectEqualStrings(d, try c.tmp.dir.readFileAlloc(c.a(), "out/test_one.ll", 1 << 20));
}

test "a blank last line of the dump is kept: only one final newline ends the text" {
    var c = try Case.init();
    defer c.deinit();
    const d = try fx.dump(c.a(), &fx.FNS);
    const blank = try std.mem.concat(c.a(), u8, &.{ d, "\n" });
    c.fake.lld_err = blank;
    try testing.expectEqual(@as(u8, 0), try c.go());
    try testing.expectEqualStrings(blank, try c.tmp.dir.readFileAlloc(c.a(), "out/test_one.ll", 1 << 20));
}

test "usage errors: a missing, repeated, empty or unknown flag, a flag without a value" {
    const cases = [_]struct { args: []const []const u8, msg: []const u8 }{
        .{ .args = &.{}, .msg = "--lld is missing" },
        .{ .args = &.{ "--lld", "a", "--lld", "b" }, .msg = "--lld given twice" },
        .{ .args = &.{ "--out", "" }, .msg = "--out is empty" },
        .{ .args = &.{ "--busybox", "bb" }, .msg = "unknown argument --busybox" },
        // A flag is matched whole: one that only starts with a known flag is unknown.
        .{ .args = &.{ "--lldx", "l" }, .msg = "unknown argument --lldx" },
        .{ .args = &.{"--binary"}, .msg = "--binary needs a value" },
        .{ .args = &.{ "--lld", "l", "--profdata", "p", "--bitcode", "b", "--profile", "f", "--binary", "x" }, .msg = "--out is missing" },
    };
    for (cases) |cs| {
        var c = try Case.init();
        defer c.deinit();
        try testing.expectEqual(@as(u8, 2), try c.goWith(cs.args));
        try testing.expect(c.has("cov_branch annotate: usage error: "));
        try testing.expect(c.has(cs.msg));
        try testing.expect(c.has(an.USAGE));
        try testing.expectEqual(@as(usize, 0), c.fake.calls.items.len);
    }
}

test "each input missing or empty is exit 2, naming it, before anything runs" {
    const inputs = [_][]const u8{ "tc/lld/bin/lld", "tc/llvm/bin/llvm-profdata", "in/test_one.bc", "in/test_one.profdata", "in/test_one" };
    for (inputs) |f| {
        for ([_]bool{ true, false }) |empty| {
            var c = try Case.init();
            defer c.deinit();
            if (empty) try c.put(f, "") else try c.tmp.dir.deleteFile(f);
            try testing.expectEqual(@as(u8, 2), try c.go());
            try testing.expect(c.has(try std.fmt.allocPrint(c.a(), "cov_branch annotate: {s} is missing or empty", .{f})));
            try testing.expectEqual(@as(usize, 0), c.fake.calls.items.len);
            // The scratch is made only once the inputs are found.
            try testing.expectError(error.FileNotFound, c.tmp.dir.access("scratch/cov_branch_annotate", .{}));
        }
    }
}

test "step 0: a bitcode without the magic is refused" {
    var c = try Case.init();
    defer c.deinit();
    try c.put("in/test_one.bc", "BC\xc0\xdf rest");
    try c.refused("in/test_one.bc is not LLVM bitcode");
    try testing.expectEqual(@as(usize, 0), c.fake.calls.items.len);
    // The magic alone is enough, as the script's `od -N 4` read it.
    try c.put("in/test_one.bc", "BC\xc0\xde");
    try testing.expectEqual(@as(u8, 0), try c.go());
}

test "step 0: branch weights or entry counts in the bitcode are refused, each alone" {
    {
        var c = try Case.init();
        defer c.deinit();
        try c.put("in/test_one.bc", try fx.bitcode(c.a(), "\x00\x01branch_weights\x07"));
        try c.refused("in/test_one.bc already holds branch weights before the profile is applied");
        try testing.expectEqual(@as(usize, 0), c.fake.calls.items.len);
    }
    {
        var c = try Case.init();
        defer c.deinit();
        try c.put("in/test_one.bc", try fx.bitcode(c.a(), "\x00function_entry_count\xff"));
        try c.refused("in/test_one.bc already holds function entry counts before the profile is applied");
        try testing.expectEqual(@as(usize, 0), c.fake.calls.items.len);
    }
    {
        // A near miss of either is no refusal.
        var c = try Case.init();
        defer c.deinit();
        try c.put("in/test_one.bc", try fx.bitcode(c.a(), "branch_weight function_entry_coun"));
        try testing.expectEqual(@as(u8, 0), try c.go());
    }
    {
        // Both: branch weights are named, as the script checked them first.
        var c = try Case.init();
        defer c.deinit();
        try c.put("in/test_one.bc", try fx.bitcode(c.a(), "function_entry_count branch_weights"));
        try c.refused("in/test_one.bc already holds branch weights before the profile is applied");
    }
}

test "step 1: a file that is not a 64-bit little-endian ELF file is refused" {
    for ([_][]const u8{ "\x7fELF\x01\x01\x01", "\x7fELF\x02\x02\x01", "\x7fELG\x02\x01\x01" }) |ident| {
        var c = try Case.init();
        defer c.deinit();
        try c.put("in/test_one", try fx.elf(c.a(), &.{}, .{ .ident = ident }));
        try c.refused("in/test_one is not a 64-bit little-endian ELF file");
    }
    var c = try Case.init();
    defer c.deinit();
    try c.put("in/test_one", "\x7fELF\x02");
    try c.refused("in/test_one is not a 64-bit little-endian ELF file");
}

test "step 1: a section header table the tool does not read is refused" {
    const odds = [_]fx.Odd{
        .{ .shentsize = 40 },
        .{ .shnum = 0 },
        .{ .shstrndx = 5 },
        // Off by one each way: the names index equal to the count, an entry of 65 bytes.
        .{ .shstrndx = 3 },
        .{ .shentsize = 65 },
        .{ .shoff = 1 << 40 },
        .{ .cut = 60 },
    };
    for (odds) |o| {
        var c = try Case.init();
        defer c.deinit();
        try c.put("in/test_one", try fx.elf(c.a(), &.{.{ .name = "__llvm_prf_data", .bytes = &fx.record(fx.MAIN) }}, o));
        try c.refused("in/test_one has no section header table this tool reads");
    }
    // The table cut short by one entry.
    var c = try Case.init();
    defer c.deinit();
    const b = try fx.binary(c.a(), &fx.FNS);
    try c.put("in/test_one", b[0 .. b.len - 1]);
    try c.refused("in/test_one has no section header table this tool reads");
}

test "step 1: two data or counter sections, or none, are refused" {
    const a = std.heap.page_allocator;
    const data = try fx.dataOf(a, &fx.FNS);
    const cnts = fx.cntsSize(&fx.FNS);
    const cases = [_]struct { s: []const fx.Section, msg: []const u8 }{
        .{ .s = &.{ .{ .name = "__llvm_prf_data", .bytes = data }, .{ .name = "__llvm_prf_cnts", .size = cnts }, .{ .name = "__llvm_prf_data", .bytes = data } }, .msg = "in/test_one has two __llvm_prf_data sections" },
        .{ .s = &.{ .{ .name = "__llvm_prf_cnts", .size = cnts }, .{ .name = "__llvm_prf_data", .bytes = data }, .{ .name = "__llvm_prf_cnts", .size = cnts } }, .msg = "in/test_one has two __llvm_prf_cnts sections" },
        .{ .s = &.{.{ .name = "__llvm_prf_cnts", .size = cnts }}, .msg = "no __llvm_prf_data or no __llvm_prf_cnts section: it is not an instrumented binary" },
        .{ .s = &.{.{ .name = "__llvm_prf_data", .bytes = data }}, .msg = "no __llvm_prf_data or no __llvm_prf_cnts section: it is not an instrumented binary" },
        // Names compared whole: neither a longer name nor a prefix is the section.
        .{ .s = &.{ .{ .name = "__llvm_prf_datax", .bytes = data }, .{ .name = "__llvm_prf_cnts", .size = cnts } }, .msg = "no __llvm_prf_data or no __llvm_prf_cnts section" },
        .{ .s = &.{ .{ .name = "__llvm_prf_dat", .bytes = data }, .{ .name = "__llvm_prf_cnts", .size = cnts } }, .msg = "no __llvm_prf_data or no __llvm_prf_cnts section" },
        .{ .s = &.{ .{ .name = "__llvm_prf_data", .bytes = data }, .{ .name = "__llvm_prf_cntsx", .size = cnts } }, .msg = "no __llvm_prf_data or no __llvm_prf_cnts section" },
        // A name ends at a NUL or a newline only, not at a space.
        .{ .s = &.{ .{ .name = "__llvm_prf_data x", .bytes = data }, .{ .name = "__llvm_prf_cnts", .size = cnts } }, .msg = "no __llvm_prf_data or no __llvm_prf_cnts section" },
    };
    for (cases) |cs| {
        var c = try Case.init();
        defer c.deinit();
        try c.put("in/test_one", try fx.elf(c.a(), cs.s, .{}));
        try c.refused(cs.msg);
    }
}

test "step 1: a section name ends at a newline as at a NUL, within its 16 bytes" {
    var c = try Case.init();
    defer c.deinit();
    try c.put("in/test_one", try fx.elf(c.a(), &.{
        .{ .name = "__llvm_prf_cnts", .size = fx.cntsSize(&fx.FNS) },
        .{ .name = "__llvm_prf_data\nx", .bytes = try fx.dataOf(c.a(), &fx.FNS) },
    }, .{}));
    try testing.expectEqual(@as(u8, 0), try c.go());
    try testing.expectEqualStrings("", c.err.items);
}

test "step 1: a data section that is not whole 72-byte records, or whose counters do not fill the counter section, is refused" {
    const a = std.heap.page_allocator;
    const data = try fx.dataOf(a, &fx.FNS);
    const cnts = fx.cntsSize(&fx.FNS);
    const cases = [_]struct { s: []const fx.Section, msg: []const u8 }{
        .{ .s = &.{ .{ .name = "__llvm_prf_data", .bytes = "" }, .{ .name = "__llvm_prf_cnts", .size = 0 } }, .msg = "in/test_one's __llvm_prf_data is 0 bytes, not a whole number of 72-byte records" },
        .{ .s = &.{ .{ .name = "__llvm_prf_data", .bytes = data[0..73] }, .{ .name = "__llvm_prf_cnts", .size = cnts } }, .msg = "in/test_one's __llvm_prf_data is 73 bytes, not a whole number of 72-byte records" },
        .{ .s = &.{ .{ .name = "__llvm_prf_data", .bytes = data[0..80] }, .{ .name = "__llvm_prf_cnts", .size = cnts } }, .msg = "in/test_one's __llvm_prf_data is 80 bytes, not a whole number of 72-byte records" },
        .{ .s = &.{ .{ .name = "__llvm_prf_data", .bytes = data }, .{ .name = "__llvm_prf_cnts", .size = cnts + 8 } }, .msg = "in/test_one's 3 profile data records count 6 counters, but its __llvm_prf_cnts is 56 bytes: not the 72-byte record this tool reads" },
        .{ .s = &.{ .{ .name = "__llvm_prf_data", .bytes = data }, .{ .name = "__llvm_prf_cnts", .size = cnts - 8 } }, .msg = "count 6 counters, but its __llvm_prf_cnts is 40 bytes" },
    };
    for (cases) |cs| {
        var c = try Case.init();
        defer c.deinit();
        try c.put("in/test_one", try fx.elf(c.a(), cs.s, .{}));
        try c.refused(cs.msg);
    }
}

test "step 1: a data section past the end of the file is refused" {
    var c = try Case.init();
    defer c.deinit();
    // The header says two more records than the file holds there, the
    // records at the very end of the file; their counter counts read as 0
    // past it, so the counters still fill the counter section.
    const data = try fx.dataOf(c.a(), &fx.FNS);
    var b = std.ArrayList(u8).init(c.a());
    try b.appendSlice(try fx.elf(c.a(), &.{
        .{ .name = "__llvm_prf_cnts", .size = fx.cntsSize(&fx.FNS) },
        .{ .name = "__llvm_prf_data", .size = data.len + 2 * 72, .offset = 0 },
    }, .{}));
    const off = b.items.len;
    try b.appendSlice(data);
    // The data section's header is the third (null, cnts, data): offset at +24.
    const shoff = std.mem.readInt(u64, b.items[40..48], .little);
    std.mem.writeInt(u64, b.items[shoff + 2 * 64 + 24 ..][0..8], off, .little);
    try c.put("in/test_one", b.items);
    try c.refused("could not read 5 records from in/test_one's __llvm_prf_data");
}

test "step 1: llvm-profdata show failing is refused with its first two lines" {
    var c = try Case.init();
    defer c.deinit();
    c.fake.show_status = .{ .exited = 1 };
    c.fake.show_err = "error: in/test_one.profdata: bad magic\nline two\nline three\n";
    try c.refused("llvm-profdata show failed on in/test_one.profdata: error: in/test_one.profdata: bad magic line two \n");
    try testing.expect(!c.has("line three"));
    // Its lines are not cut (the script's `head -n 2 | tr`).
    c.fake.show_err = "e" ** 400 ++ "\n";
    try c.refused("llvm-profdata show failed on in/test_one.profdata: " ++ "e" ** 400 ++ " \n");
    // Any other status fails too, a signal among them, its listing written or not.
    c.fake.show_err = "";
    c.fake.show_status = .{ .exited = 2 };
    try c.refused("llvm-profdata show failed on in/test_one.profdata: \n");
    c.fake.show_status = .{ .signaled = 9 };
    try c.refused("llvm-profdata show failed on in/test_one.profdata: \n");
}

test "a process that cannot be created is exit 2, naming the program" {
    for ([_][]const u8{ "show", "-flavor" }, [_][]const u8{ "tc/llvm/bin/llvm-profdata", "tc/lld/bin/lld" }) |step, prog| {
        var c = try Case.init();
        defer c.deinit();
        c.fake.fail = step;
        try testing.expectEqual(@as(u8, 2), try c.go());
        try testing.expect(c.has(try std.fmt.allocPrint(c.a(), "cov_branch annotate: cannot run {s}: SystemResources\n", .{prog})));
        try testing.expectError(error.FileNotFound, c.tmp.dir.access("out/test_one.ll", .{}));
        // The scratch is kept after the failure.
        try c.tmp.dir.access("scratch/cov_branch_annotate", .{});
    }
}

test "step 1: a listing the tool cannot read is refused with its line" {
    const listings = [_]struct { text: []const u8, line: []const u8 }{
        // A name not followed by its hash.
        .{ .text = "Counters:\n  main:\n    Counters: 3\n    Hash: 0x01\nTotal functions: 1\n", .line = "line 3" },
        // A hash in capitals, or with no digit.
        .{ .text = "Counters:\n  main:\n    Hash: 0xABC\nTotal functions: 1\n", .line = "line 3" },
        .{ .text = "Counters:\n  main:\n    Hash: 0x\nTotal functions: 1\n", .line = "line 3" },
        // A hash with a letter past f.
        .{ .text = "Counters:\n  main:\n    Hash: 0x1g\nTotal functions: 1\n", .line = "line 3" },
        // The hash line starts the line: five spaces before it are not four.
        .{ .text = "Counters:\n  main:\n     Hash: 0x01\nTotal functions: 1\n", .line = "line 3" },
        // Two names in a row.
        .{ .text = "  a:\n  b:\n    Hash: 0x1\nTotal functions: 1\n", .line = "line 2" },
    };
    for (listings) |l| {
        var c = try Case.init();
        defer c.deinit();
        c.fake.show_text = l.text;
        try c.refused(try std.fmt.allocPrint(c.a(), "the function list of in/test_one.profdata could not be read (llvm-profdata show, {s})", .{l.line}));
    }
}

test "step 1: a line of three spaces before its text is not a function name" {
    var c = try Case.init();
    defer c.deinit();
    const s = try fx.show(c.a(), &fx.FNS);
    c.fake.show_text = try std.mem.replaceOwned(u8, c.a(), s, "Counters:\n", "Counters:\n   x:\n");
    try testing.expectEqual(@as(u8, 0), try c.go());
    try testing.expectEqualStrings("", c.err.items);
}

test "step 1: a name line is two spaces, then a name ending in a colon; the name may be empty" {
    // One space, or no colon at the end: not a name line, so not read.
    for ([_][]const u8{ "Counters:\n x:\n", "Counters:\n  x\n" }) |odd| {
        var c = try Case.init();
        defer c.deinit();
        c.fake.show_text = try std.mem.replaceOwned(u8, c.a(), try fx.show(c.a(), &fx.FNS), "Counters:\n", odd);
        try testing.expectEqual(@as(u8, 0), try c.go());
        try testing.expectEqualStrings("", c.err.items);
    }
    // `  :` names a function whose name is empty (its MD5 is that of no bytes).
    var c = try Case.init();
    defer c.deinit();
    const four = fx.FNS ++ [_]fx.Fn{.{ .name = "", .hash = 5 }};
    try c.put("in/test_one", try fx.binary(c.a(), &four));
    c.fake.show_text = try fx.show(c.a(), &four);
    try testing.expect(std.mem.indexOf(u8, c.fake.show_text, "\n  :\n") != null);
    c.fake.lld_err = try fx.dump(c.a(), &four);
    try testing.expectEqual(@as(u8, 0), try c.go());
    try testing.expectEqualStrings("", c.err.items);
}

test "step 1: only a line that starts `Total functions: ` gives the count" {
    var c = try Case.init();
    defer c.deinit();
    c.fake.show_text = try std.mem.concat(c.a(), u8, &.{ try fx.show(c.a(), &fx.FNS), "x Total functions: 3\n" });
    try testing.expectEqual(@as(u8, 0), try c.go());
    try testing.expectEqualStrings("", c.err.items);
}

test "step 1: the functions read must be the count show reports, given once" {
    const a = std.heap.page_allocator;
    const base = try fx.show(a, &fx.FNS);
    const cases = [_]struct { text: []const u8, msg: []const u8 }{
        .{ .text = try std.mem.replaceOwned(u8, a, base, "Total functions: 3", "Total functions: 4"), .msg = "read 3 functions from in/test_one.profdata, but llvm-profdata show reports '4'" },
        .{ .text = try std.mem.replaceOwned(u8, a, base, "Total functions: 3", "Total: 3"), .msg = "but llvm-profdata show reports 'none'" },
        .{ .text = try std.mem.concat(a, u8, &.{ base, "Total functions: 3\n" }), .msg = "but llvm-profdata show reports '3\n3'" },
        .{ .text = try std.mem.replaceOwned(u8, a, base, "Total functions: 3", "Total functions: 3x"), .msg = "reports 'none'" },
        // Decimal digits only, at least one; compared as the string show printed.
        .{ .text = try std.mem.replaceOwned(u8, a, base, "Total functions: 3", "Total functions: 3a"), .msg = "reports 'none'" },
        .{ .text = try std.mem.replaceOwned(u8, a, base, "Total functions: 3", "Total functions: "), .msg = "reports 'none'" },
        .{ .text = try std.mem.replaceOwned(u8, a, base, "Total functions: 3", "Total functions: 03"), .msg = "read 3 functions from in/test_one.profdata, but llvm-profdata show reports '03'" },
        // A name at the end with no hash line is not a function read.
        .{ .text = try std.mem.concat(a, u8, &.{ try std.mem.replaceOwned(u8, a, base, "Total functions: 3", "Total functions: 4"), "  late:\n" }), .msg = "read 3 functions" },
    };
    for (cases) |cs| {
        var c = try Case.init();
        defer c.deinit();
        c.fake.show_text = cs.text;
        try c.refused(cs.msg);
    }
}

test "step 1: a function the binary links that the profile lacks is refused, with the first three" {
    var c = try Case.init();
    defer c.deinit();
    c.fake.show_text = try fx.show(c.a(), &.{fx.HELPER});
    try c.refused("the profile in/test_one.profdata holds no record of 2 of the 3 functions in/test_one links (name MD5 prefix, hash: ");
    try testing.expect(c.has("a run writes the record of every function its binary links, ran or not"));
    // The pairs of the two lost: MAIN's and SMALL's MD5 prefixes and hashes.
    var md5: [16]u8 = undefined;
    std.crypto.hash.Md5.hash("main", &md5, .{});
    try testing.expect(c.has(try std.fmt.allocPrint(c.a(), "{s} 123456789abcdef0", .{std.fmt.fmtSliceHexLower(md5[0..8])})));
    try testing.expect(c.has(" 0000000000000042 "));
    try testing.expectEqual(@as(usize, 1), c.fake.calls.items.len);
}

test "step 1: of four or more lost records, three are named" {
    var c = try Case.init();
    defer c.deinit();
    try c.put("in/test_one", try fx.binary(c.a(), &(fx.FNS ++ [_]fx.Fn{ .{ .name = "e1", .hash = 1 }, .{ .name = "e2", .hash = 2 } })));
    c.fake.show_text = try fx.show(c.a(), &.{fx.HELPER});
    try c.refused("holds no record of 4 of the 5 functions in/test_one links (name MD5 prefix, hash: ");
    const from = std.mem.indexOf(u8, c.err.items, "hash: ").? + "hash: ".len;
    const to = std.mem.indexOf(u8, c.err.items, "): a run").?;
    // Three "<md5 prefix> <hash> " pairs: six spaces.
    try testing.expectEqual(@as(usize, 6), std.mem.count(u8, c.err.items[from..to], " "));
}

test "step 1: the same function hash with another name, or the same name with another hash, is a lost record" {
    for ([_]fx.Fn{ .{ .name = "mainx", .hash = fx.MAIN.hash, .counters = 3 }, .{ .name = "main", .hash = fx.MAIN.hash + 1, .counters = 3 } }) |f| {
        var c = try Case.init();
        defer c.deinit();
        c.fake.show_text = try fx.show(c.a(), &.{ f, fx.HELPER, fx.SMALL });
        try c.refused("holds no record of 1 of the 3 functions");
    }
}

test "step 1: records compare as a multiset: a record the binary holds twice and the profile once is lost" {
    var c = try Case.init();
    defer c.deinit();
    try c.put("in/test_one", try fx.binary(c.a(), &.{ fx.MAIN, fx.MAIN, fx.HELPER, fx.SMALL }));
    try c.refused("holds no record of 1 of the 4 functions in/test_one links");
}

test "step 1: a function of the profile the binary does not link is refused, naming the first" {
    var c = try Case.init();
    defer c.deinit();
    const long = "x" ** 400;
    c.fake.show_text = try fx.show(c.a(), &.{ fx.MAIN, fx.HELPER, fx.SMALL, .{ .name = long, .hash = 7 } });
    try c.refused("the profile in/test_one.profdata holds 1 function(s) in/test_one does not link, the first " ++ "x" ** 300 ++ ": a profile of another binary");
    try testing.expect(!c.has("x" ** 301));
}

test "step 1: of several extra functions, the one first by name MD5 and hash is named" {
    var c = try Case.init();
    defer c.deinit();
    const extra = [_]fx.Fn{ .{ .name = "e1", .hash = 1 }, .{ .name = "e2", .hash = 2 }, .{ .name = "e3", .hash = 3 } };
    c.fake.show_text = try fx.show(c.a(), &(fx.FNS ++ extra));
    var first: []const u8 = "";
    var best: []const u8 = "";
    for (extra) |e| {
        const r = fx.record(e);
        const key = try std.fmt.allocPrint(c.a(), "{s}", .{std.fmt.fmtSliceHexLower(r[0..8])});
        if (best.len == 0 or std.mem.lessThan(u8, key, best)) {
            best = key;
            first = e.name;
        }
    }
    try c.refused(try std.fmt.allocPrint(c.a(), "holds 3 function(s) in/test_one does not link, the first {s}: ", .{first}));
}

test "step 1: a hash of fewer than 16 digits is read with leading zeros" {
    var c = try Case.init();
    defer c.deinit();
    const s = try fx.show(c.a(), &fx.FNS);
    c.fake.show_text = try std.mem.replaceOwned(u8, c.a(), s, "Hash: 0x0000000000000042", "Hash: 0x42");
    try testing.expect(!std.mem.eql(u8, s, c.fake.show_text));
    try testing.expectEqual(@as(u8, 0), try c.go());
    // Fifteen digits get one zero.
    const t = c.fake.show_text;
    c.fake.show_text = try std.mem.replaceOwned(u8, c.a(), t, "Hash: 0x0102030405060708", "Hash: 0x102030405060708");
    try testing.expect(!std.mem.eql(u8, t, c.fake.show_text));
    try testing.expectEqual(@as(u8, 0), try c.go());
}

test "step 2: lld failing is refused, after the last 20 lines it printed, each cut to 300 bytes" {
    var c = try Case.init();
    defer c.deinit();
    var e = std.ArrayList(u8).init(c.a());
    for (0..25) |i| try e.writer().print("line {d}\n", .{i});
    try e.appendSlice("y" ** 400);
    c.fake.lld_err = e.items;
    c.fake.lld_status = .{ .exited = 1 };
    try c.refused("lld could not apply the profile in/test_one.profdata to in/test_one.bc (pgo-instr-use)");
    try testing.expect(!c.has("line 5\n"));
    try testing.expect(c.has("line 6\nline 7\n"));
    try testing.expect(c.has("y" ** 300 ++ "\nBRANCH COVERAGE ANNOTATE FAILED"));
    // Cut to 300 bytes exactly.
    try testing.expect(c.has("line 24\n" ++ "y" ** 300 ++ "\n"));
    // A signal is a failure too, and so is any other exit status.
    c.fake.lld_status = .{ .signaled = 9 };
    try c.refused("lld could not apply the profile");
    c.fake.lld_status = .{ .exited = 2 };
    try c.refused("lld could not apply the profile");
}

test "step 3: a diagnostic of lld before the dump is refused, a missing-function line alone is not" {
    const a = std.heap.page_allocator;
    const d = try fx.dump(a, &fx.FNS);
    const cases = [_]struct { pre: []const u8, n: []const u8, first: []const u8 }{
        .{ .pre = "lld: warning: ld-temp.o: function control flow change detected (hash mismatch) main Hash = 1\n", .n = "1", .first = "lld: warning: ld-temp.o: function control flow change detected (hash mismatch)" },
        // Not quite a missing-function line: each part of its pattern broken.
        .{ .pre = "lld: warning: ld-temp.o: no profile data available for function f Hash = 12 up to 0 count discarded!\n", .n = "1", .first = "count discarded!" },
        .{ .pre = "lld: warning: ld-temp.o: no profile data available for function f Hash = up to 0 count discarded\n", .n = "1", .first = "Hash = up to" },
        .{ .pre = "lld: warning: ld-temp.o: no profile data available for function f Hash = 1x up to 0 count discarded\n", .n = "1", .first = "1x up" },
        // The hash is decimal digits, at least one, after ` Hash = ` with both its spaces.
        .{ .pre = "lld: warning: ld-temp.o: no profile data available for function f Hash =  up to 0 count discarded\n", .n = "1", .first = "Hash =  up" },
        .{ .pre = "lld: warning: ld-temp.o: no profile data available for function f Hash = 1a up to 0 count discarded\n", .n = "1", .first = "1a up" },
        .{ .pre = "lld: warning: ld-temp.o: no profile data available for function fHash = 1 up to 0 count discarded\n", .n = "1", .first = "fHash" },
        .{ .pre = "lld: warning: ld-temp.o: no profile data available for function f Hash =1 up to 0 count discarded\n", .n = "1", .first = "Hash =1 up" },
        .{ .pre = "lld: warning: ld temp.o: no profile data available for function f Hash = 1 up to 0 count discarded\n", .n = "1", .first = "ld temp.o" },
        .{ .pre = "x lld: warning: ld-temp.o: no profile data available for function f Hash = 1 up to 0 count discarded\n", .n = "1", .first = "x lld" },
        .{ .pre = "lld: error: ld-temp.o: no profile data available for function f Hash = 1 up to 0 count discarded\n", .n = "1", .first = "lld: error" },
        // Any other line, an empty one among them (counted as grep -c . counts).
        .{ .pre = "something\n\n", .n = "1", .first = "something  " },
    };
    for (cases) |cs| {
        var c = try Case.init();
        defer c.deinit();
        c.fake.lld_err = try std.mem.concat(c.a(), u8, &.{ try fx.missing(c.a(), "unrun"), cs.pre, d });
        try c.refused(try std.fmt.allocPrint(c.a(), "lld reported {s} diagnostic(s) applying the profile: ", .{cs.n}));
        try testing.expect(c.has(cs.first));
    }
    // A program name before `lld: ` is still lld's line; so are several.
    var c = try Case.init();
    defer c.deinit();
    c.fake.lld_err = try std.mem.concat(c.a(), u8, &.{ "/x/ld.lld: warning: ld-temp.o: no profile data available for function g Hash = 9 up to 0 count discarded\n", try fx.missing(c.a(), "h"), d });
    try testing.expectEqual(@as(u8, 0), try c.go());
    // The word before `: no profile` is any word without a space, an empty one too.
    c.fake.lld_err = try std.mem.concat(c.a(), u8, &.{
        "lld: warning: other.o: no profile data available for function g Hash = 9 up to 0 count discarded\n",
        "lld: warning: : no profile data available for function k Hash = 9 up to 0 count discarded\n",
        d,
    });
    try testing.expectEqual(@as(u8, 0), try c.go());
    try testing.expectEqualStrings("", c.err.items);
}

test "step 3: a line of lld's own inside the dump is refused; the first five named, each cut to 300 bytes" {
    const a = std.heap.page_allocator;
    const d = try fx.dump(a, &fx.FNS);
    // A missing-function line is lld's own too, once the dump has started.
    for ([_][]const u8{ "lld: warning: late\n", "ld.lld: error: late\n", "warning: late\n", "error: late\n", "lld: warning: ld-temp.o: no profile data available for function late Hash = 1234 up to 0 count discarded\n" }) |l| {
        var c = try Case.init();
        defer c.deinit();
        c.fake.lld_err = try std.mem.concat(c.a(), u8, &.{ d, l });
        try c.refused(try std.fmt.allocPrint(c.a(), "lld reported 1 diagnostic(s) applying the profile: {s} \n", .{l[0 .. l.len - 1]}));
    }
    var c = try Case.init();
    defer c.deinit();
    var e = std.ArrayList(u8).init(c.a());
    for (0..7) |i| try e.writer().print("warning: {d}{s}\n", .{ i, "z" ** 400 });
    c.fake.lld_err = try std.mem.concat(c.a(), u8, &.{ d, e.items });
    try c.refused("lld reported 7 diagnostic(s) applying the profile: warning: 0");
    try testing.expect(c.has("warning: 4"));
    try testing.expect(!c.has("warning: 5"));
    try testing.expect(!c.has("z" ** 300));
    // Each cut to 300 bytes exactly: "warning: 0" and 290 of its z's.
    try testing.expect(c.has("warning: 0" ++ "z" ** 290 ++ " warning: 1"));
    // A line that only holds `warning: `, `error: ` or `lld: ` later in it is
    // IR, and so is one that starts `warning:` or `error:` without the space.
    c.fake.lld_err = try std.mem.concat(c.a(), u8, &.{ d, "  ; warning: in a comment\n  call void @f() ; lld: no\n  ; error: in a comment\nwarning:x\nerror:x\n" });
    try testing.expectEqual(@as(u8, 0), try c.go());
}

test "step 3: lld writing to its standard output is refused" {
    var c = try Case.init();
    defer c.deinit();
    c.fake.lld_out = "one\ntwo\nthree\nfour\n";
    try c.refused("lld wrote to its standard output: one two three \n");
    // One byte is enough; lines are not cut (the script's `head -n 3 | tr`).
    c.fake.lld_out = "x";
    try c.refused("lld wrote to its standard output: x \n");
    // A diagnostic as well: the diagnostic is named, as the script checked it first.
    c.fake.lld_err = try std.mem.concat(c.a(), u8, &.{ "lld: error: boom\n", try fx.dump(c.a(), &fx.FNS) });
    try c.refused("lld reported 1 diagnostic(s) applying the profile: lld: error: boom \n");
    // No dump at all as well: the standard output is named, checked before the header.
    c.fake.lld_err = "";
    try c.refused("lld wrote to its standard output: x \n");
    c.fake.lld_out = "o" ** 400 ++ "\n";
    try c.refused("lld wrote to its standard output: " ++ "o" ** 400 ++ " \n");
}

test "step 3: no dump, or two, is refused" {
    {
        var c = try Case.init();
        defer c.deinit();
        c.fake.lld_err = "";
        try c.refused("lld's output does not start with the dump header '" ++ fx.HEADER ++ "': \n");
    }
    {
        // A header with trailing text is not the header.
        var c = try Case.init();
        defer c.deinit();
        const d = try fx.dump(c.a(), &fx.FNS);
        c.fake.lld_err = try std.mem.replaceOwned(u8, c.a(), d, fx.HEADER, fx.HEADER ++ " ");
        try c.refused("diagnostic(s) applying the profile: " ++ fx.HEADER ++ "  ; ModuleID");
    }
    {
        var c = try Case.init();
        defer c.deinit();
        const d = try fx.dump(c.a(), &fx.FNS);
        c.fake.lld_err = try std.mem.concat(c.a(), u8, &.{ d, "; *** IR Dump After Other on [module] ***\n" });
        try c.refused("lld printed 2 IR dumps, expected exactly one");
    }
    {
        // A header is counted anywhere in its line, as `grep -c -F` counts.
        var c = try Case.init();
        defer c.deinit();
        const d = try fx.dump(c.a(), &fx.FNS);
        c.fake.lld_err = try std.mem.concat(c.a(), u8, &.{ d, "  ; *** IR Dump After Other on [module] ***\n" });
        try c.refused("lld printed 2 IR dumps, expected exactly one");
    }
    {
        // The dump starts at the first header: a second whole dump is a second dump.
        var c = try Case.init();
        defer c.deinit();
        const d = try fx.dump(c.a(), &fx.FNS);
        c.fake.lld_err = try std.mem.concat(c.a(), u8, &.{ try fx.missing(c.a(), "unrun"), d, d });
        try c.refused("lld printed 2 IR dumps, expected exactly one");
    }
    {
        // `; *** IR Dump` not followed by a space is no header.
        var c = try Case.init();
        defer c.deinit();
        c.fake.lld_err = try std.mem.concat(c.a(), u8, &.{ try fx.dump(c.a(), &fx.FNS), "; *** IR Dumps\n" });
        try testing.expectEqual(@as(u8, 0), try c.go());
    }
}

test "step 3: an entry count for fewer or more functions than the profile holds is refused" {
    for ([_]usize{ 2, 4 }) |n| {
        var c = try Case.init();
        defer c.deinit();
        const more = [_]fx.Fn{ fx.MAIN, fx.HELPER, fx.SMALL, .{ .name = "extra", .hash = 1 } };
        c.fake.lld_err = try fx.dump(c.a(), more[0..n]);
        try c.refused(try std.fmt.allocPrint(c.a(), "pgo-instr-use found {d} of the 3 functions of the profile in/test_one.profdata in in/test_one.bc: the binary that wrote it was not made from this bitcode", .{n}));
    }
}

test "isCountedDefine: a define with !prof !<digit> after its name" {
    try testing.expect(an.isCountedDefine("define void @f() !prof !7 {"));
    try testing.expect(an.isCountedDefine("define internal i1 @g(i64 %0) #3 !dbg !5 !prof !12 {"));
    try testing.expect(!an.isCountedDefine("define void @f() !prof !x {"));
    try testing.expect(!an.isCountedDefine("define void @f() {"));
    try testing.expect(!an.isCountedDefine("declare void @f() !prof !7"));
    try testing.expect(!an.isCountedDefine(" define void @f() !prof !7 {"));
    try testing.expect(!an.isCountedDefine("define !prof !7"));
    try testing.expect(an.isCountedDefine("define  !prof !7"));
    // ` !prof !` with its space, a digit after it, at any of its places.
    try testing.expect(!an.isCountedDefine("define void @f()!prof !7 {"));
    try testing.expect(!an.isCountedDefine("defined void @f() !prof !7 {"));
    try testing.expect(!an.isCountedDefine("define void @f() !prof !"));
    try testing.expect(an.isCountedDefine("define void @f() !prof !x !prof !7 {"));
}

test "the dump cannot be written: exit 1, naming it" {
    var c = try Case.init();
    defer c.deinit();
    const args = c.argv();
    var v = try c.a().dupe([]const u8, args);
    v[v.len - 1] = "nowhere/test_one.ll";
    try testing.expectEqual(@as(u8, 1), try c.goWith(v));
    try testing.expect(c.has("cov_branch annotate: cannot write nowhere/test_one.ll: FileNotFound"));
    // The scratch directory is kept, as after a refusal.
    try c.tmp.dir.access("scratch/cov_branch_annotate/err", .{});
}

test "the scratch directory follows BUCK_SCRATCH_PATH" {
    const a = testing.allocator;
    const cases = [_]struct { s: ?[]const u8, want: []const u8 }{
        .{ .s = null, .want = "/w/.cov_branch_annotate" },
        .{ .s = "", .want = "/w/.cov_branch_annotate" },
        .{ .s = "/abs/s", .want = "/abs/s/cov_branch_annotate" },
        .{ .s = "rel/s", .want = "/w/rel/s/cov_branch_annotate" },
    };
    for (cases) |cs| {
        const got = try an.scratchDir(a, "/w", cs.s);
        defer a.free(got);
        try testing.expectEqualStrings(cs.want, got);
    }
}
