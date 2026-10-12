//! Unit tests of `cov_branch annotate` (cov_branch_annotate.zig) for the
//! order of its refusals, run with cov_branch_annotate_test.zig's cases by
//! `zig test` as a build action (`:cov_branch_unit`). Each test gives one
//! input two faults that each refuse it alone, and checks that the reason
//! named is the one the deleted script reported first (its checks ran in
//! this order: inputs, bitcode magic, branch weights, entry counts, the
//! binary's records, llvm-profdata show, the listing, lost then extra
//! records, lld's status, then over lld's output its diagnostics, its
//! standard output, the dump header, the number of dumps and the entry
//! counts).

const std = @import("std");
const an = @import("cov_branch_annotate.zig");
const fx = @import("cov_branch_annotate_fixture.zig");
const t = @import("cov_branch_annotate_test.zig");
const testing = std.testing;
const Case = t.Case;

const NOT_BC = "BC\xc0\xdf";
const NOT_ELF = "\x7fELF\x01\x01\x01 not 64-bit";

test "order: of two missing inputs, the first of lld, llvm-profdata, bitcode, profile, binary is named" {
    const inputs = [_][]const u8{ "tc/lld/bin/lld", "tc/llvm/bin/llvm-profdata", "in/test_one.bc", "in/test_one.profdata", "in/test_one" };
    // Each two neighbours, and the first and last: one missing, one empty.
    for ([_][2]usize{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 4 }, .{ 0, 4 } }) |p| {
        var c = try Case.init();
        defer c.deinit();
        try c.tmp.dir.deleteFile(inputs[p[0]]);
        try c.put(inputs[p[1]], "");
        try testing.expectEqual(@as(u8, 2), try c.go());
        try testing.expect(c.has(try std.fmt.allocPrint(c.a(), "cov_branch annotate: {s} is missing or empty", .{inputs[p[0]]})));
        try testing.expect(!c.has(try std.fmt.allocPrint(c.a(), "{s} is missing", .{inputs[p[1]]})));
    }
}

test "order: a missing input is named before a bitcode without the magic" {
    var c = try Case.init();
    defer c.deinit();
    try c.put("in/test_one.bc", NOT_BC);
    try c.tmp.dir.deleteFile("in/test_one");
    try testing.expectEqual(@as(u8, 2), try c.go());
    try testing.expect(c.has("cov_branch annotate: in/test_one is missing or empty"));
    try testing.expect(!c.has("not LLVM bitcode"));
}

test "order: the bitcode magic is checked before branch weights and entry counts" {
    for ([_][]const u8{ "branch_weights", "function_entry_count" }) |body| {
        var c = try Case.init();
        defer c.deinit();
        try c.put("in/test_one.bc", try std.mem.concat(c.a(), u8, &.{ NOT_BC, body }));
        try c.refused("in/test_one.bc is not LLVM bitcode");
    }
}

test "order: step 0 is checked before the binary" {
    for ([_][]const u8{ NOT_BC, "BC\xc0\xde branch_weights", "BC\xc0\xde function_entry_count" }, [_][]const u8{ "is not LLVM bitcode", "already holds branch weights", "already holds function entry counts" }) |bc, msg| {
        var c = try Case.init();
        defer c.deinit();
        try c.put("in/test_one.bc", bc);
        try c.put("in/test_one", NOT_ELF);
        try c.refused(msg);
        try testing.expect(!c.has("ELF"));
    }
}

test "order: the ELF identification is checked before the section header table" {
    var c = try Case.init();
    defer c.deinit();
    try c.put("in/test_one", try fx.elf(c.a(), &.{.{ .name = "__llvm_prf_data", .bytes = &fx.record(fx.MAIN) }}, .{ .ident = "\x7fELF\x01\x01\x01", .shentsize = 40 }));
    try c.refused("in/test_one is not a 64-bit little-endian ELF file");
}

test "order: the section header table is checked before the sections it lists" {
    var c = try Case.init();
    defer c.deinit();
    // Entries of 65 bytes said, 64 written: read as 64, the table holds two data sections.
    const data = try fx.dataOf(c.a(), &fx.FNS);
    try c.put("in/test_one", try fx.elf(c.a(), &.{ .{ .name = "__llvm_prf_data", .bytes = data }, .{ .name = "__llvm_prf_data", .bytes = data } }, .{ .shentsize = 65 }));
    try c.refused("in/test_one has no section header table this tool reads (entry size '65'");
}

test "order: a second data or counter section is named where the table holds it, before a missing one" {
    const a = std.heap.page_allocator;
    const data = try fx.dataOf(a, &fx.FNS);
    const cnts = fx.cntsSize(&fx.FNS);
    const D = fx.Section{ .name = "__llvm_prf_data", .bytes = data };
    const C = fx.Section{ .name = "__llvm_prf_cnts", .size = cnts };
    const cases = [_]struct { s: []const fx.Section, msg: []const u8 }{
        // Two data sections and no counter section.
        .{ .s = &.{ D, D }, .msg = "in/test_one has two __llvm_prf_data sections" },
        // Two counter sections and no data section.
        .{ .s = &.{ C, C }, .msg = "in/test_one has two __llvm_prf_cnts sections" },
        // Both doubled: the one whose second header comes first.
        .{ .s = &.{ C, C, D, D }, .msg = "in/test_one has two __llvm_prf_cnts sections" },
        .{ .s = &.{ D, D, C, C }, .msg = "in/test_one has two __llvm_prf_data sections" },
        .{ .s = &.{ D, C, C, D }, .msg = "in/test_one has two __llvm_prf_cnts sections" },
    };
    for (cases) |cs| {
        var c = try Case.init();
        defer c.deinit();
        try c.put("in/test_one", try fx.elf(c.a(), cs.s, .{}));
        try c.refused(cs.msg);
    }
}

test "order: a missing section before an empty data section; its size before its counters" {
    const a = std.heap.page_allocator;
    const data = try fx.dataOf(a, &fx.FNS);
    const cases = [_]struct { s: []const fx.Section, msg: []const u8 }{
        // No counter section, and a data section of 0 bytes.
        .{ .s = &.{.{ .name = "__llvm_prf_data", .bytes = "" }}, .msg = "no __llvm_prf_data or no __llvm_prf_cnts section" },
        // 80 bytes, whose counters (3, the first record's) do not fill 8 bytes either.
        .{ .s = &.{ .{ .name = "__llvm_prf_data", .bytes = data[0..80] }, .{ .name = "__llvm_prf_cnts", .size = 8 } }, .msg = "in/test_one's __llvm_prf_data is 80 bytes, not a whole number of 72-byte records" },
    };
    for (cases) |cs| {
        var c = try Case.init();
        defer c.deinit();
        try c.put("in/test_one", try fx.elf(c.a(), cs.s, .{}));
        try c.refused(cs.msg);
    }
}

test "order: the counters are checked before records past the end of the file" {
    var c = try Case.init();
    defer c.deinit();
    // As "a data section past the end of the file", the counter section
    // 8 bytes larger than the records' counters.
    const data = try fx.dataOf(c.a(), &fx.FNS);
    var b = std.ArrayList(u8).init(c.a());
    try b.appendSlice(try fx.elf(c.a(), &.{
        .{ .name = "__llvm_prf_cnts", .size = fx.cntsSize(&fx.FNS) + 8 },
        .{ .name = "__llvm_prf_data", .size = data.len + 2 * 72, .offset = 0 },
    }, .{}));
    const off = b.items.len;
    try b.appendSlice(data);
    const shoff = std.mem.readInt(u64, b.items[40..48], .little);
    std.mem.writeInt(u64, b.items[shoff + 2 * 64 + 24 ..][0..8], off, .little);
    try c.put("in/test_one", b.items);
    try c.refused("in/test_one's 5 profile data records count 6 counters, but its __llvm_prf_cnts is 56 bytes");
}

test "order: the binary is checked before llvm-profdata runs" {
    var c = try Case.init();
    defer c.deinit();
    try c.put("in/test_one", NOT_ELF);
    c.fake.show_status = .{ .exited = 1 };
    c.fake.show_err = "error: bad profile\n";
    try c.refused("in/test_one is not a 64-bit little-endian ELF file");
    try testing.expectEqual(@as(usize, 0), c.fake.calls.items.len);
}

test "order: show's status is checked before its listing" {
    var c = try Case.init();
    defer c.deinit();
    c.fake.show_status = .{ .exited = 1 };
    c.fake.show_err = "error: bad profile\n";
    c.fake.show_text = "  main:\n    Hash: 0xZZ\nTotal functions: 7\n";
    try c.refused("llvm-profdata show failed on in/test_one.profdata: error: bad profile \n");
}

test "order: an unreadable line is named before the count, and the first of two" {
    var c = try Case.init();
    defer c.deinit();
    // Line 2 is unread, line 6 too, and one function is read against 7.
    c.fake.show_text = "  a:\n    Counters: 1\n  b:\n    Hash: 0x1\n  c:\n  d:\n    Hash: 0x2\nTotal functions: 7\n";
    try c.refused("the function list of in/test_one.profdata could not be read (llvm-profdata show, line 2)\n");
}

test "order: the count of the listing is checked before its records are compared" {
    var c = try Case.init();
    defer c.deinit();
    // HELPER and SMALL lost, and a count of 3 for the 1 function listed.
    const s = try fx.show(c.a(), &.{fx.MAIN});
    c.fake.show_text = try std.mem.replaceOwned(u8, c.a(), s, "Total functions: 1", "Total functions: 3");
    try c.refused("read 1 functions from in/test_one.profdata, but llvm-profdata show reports '3'");
}

test "order: step 1 is checked before lld runs" {
    var c = try Case.init();
    defer c.deinit();
    c.fake.show_text = try fx.show(c.a(), &.{ fx.MAIN, fx.HELPER });
    c.fake.lld_status = .{ .exited = 1 };
    c.fake.lld_err = "ld.lld: error: boom\n";
    try c.refused("the profile in/test_one.profdata holds no record of 1 of the 3 functions in/test_one links");
    try testing.expectEqual(@as(usize, 1), c.fake.calls.items.len);
}

test "order: an extra function of the profile is named before lld runs" {
    var c = try Case.init();
    defer c.deinit();
    c.fake.show_text = try fx.show(c.a(), &.{ fx.MAIN, fx.HELPER, fx.SMALL, .{ .name = "extra", .hash = 1 } });
    c.fake.lld_status = .{ .exited = 1 };
    c.fake.lld_err = "ld.lld: error: boom\n";
    try c.refused("the profile in/test_one.profdata holds 1 function(s) in/test_one does not link, the first extra: a profile of another binary");
    try testing.expectEqual(@as(usize, 1), c.fake.calls.items.len);
}

test "order: lld's status is checked before what it printed" {
    var c = try Case.init();
    defer c.deinit();
    c.fake.lld_status = .{ .exited = 1 };
    c.fake.lld_err = "lld: error: boom\n";
    c.fake.lld_out = "x";
    try c.refused("BRANCH COVERAGE ANNOTATE FAILED: lld could not apply the profile in/test_one.profdata to in/test_one.bc (pgo-instr-use)\n");
    try testing.expect(!c.has("diagnostic"));
}

test "order: over lld's output, diagnostics, standard output, header, number of dumps, entry counts" {
    const a = std.heap.page_allocator;
    const d = try fx.dump(a, &fx.FNS);
    const two = try std.mem.concat(a, u8, &.{ d, d });
    const short = try fx.dump(a, &.{ fx.MAIN, fx.HELPER });
    const boom = "lld: error: boom\n";
    const diag = "lld reported 1 diagnostic(s) applying the profile: lld: error: boom \n";
    const stdout = "lld wrote to its standard output: x \n";
    const header = "lld's output does not start with the dump header '" ++ fx.HEADER ++ "': \n";
    const dumps = "lld printed 2 IR dumps, expected exactly one";
    const cases = [_]struct { pair: []const u8, err: []const u8, out: []const u8 = "", msg: []const u8 }{
        .{ .pair = "diagnostic, stdout", .err = try std.mem.concat(a, u8, &.{ boom, d }), .out = "x", .msg = diag },
        .{ .pair = "diagnostic, header", .err = boom, .msg = diag },
        .{ .pair = "diagnostic, dumps", .err = try std.mem.concat(a, u8, &.{ boom, two }), .msg = diag },
        .{ .pair = "diagnostic, entry counts", .err = try std.mem.concat(a, u8, &.{ boom, short }), .msg = diag },
        .{ .pair = "stdout, header", .err = "", .out = "x", .msg = stdout },
        .{ .pair = "stdout, dumps", .err = two, .out = "x", .msg = stdout },
        .{ .pair = "stdout, entry counts", .err = short, .out = "x", .msg = stdout },
        // No dump: no header, no dump counted, no entry count found.
        .{ .pair = "header, dumps / entry counts", .err = "", .msg = header },
        // Two whole dumps: six entry counts for three functions.
        .{ .pair = "dumps, entry counts", .err = two, .msg = dumps },
    };
    // Every pair is tried, each one that fails named.
    var failed: usize = 0;
    for (cases) |cs| {
        var c = try Case.init();
        defer c.deinit();
        c.fake.lld_err = cs.err;
        c.fake.lld_out = cs.out;
        c.refused(cs.msg) catch {
            std.debug.print("pair: {s}\n", .{cs.pair});
            failed += 1;
        };
    }
    try testing.expectEqual(@as(usize, 0), failed);
}
