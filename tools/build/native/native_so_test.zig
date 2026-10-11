//! Unit tests of native_so (run by `:native_so_unit`, a build action the
//! tool waits for). Each check is shown green on a shared object shaped as
//! komira_crypto's first green link is, and red on that object with the one
//! defect the check exists for: the planted defects of
//! docs/design/native_packaging.md, "Checks, per library", as inputs.

const std = @import("std");
const elf = @import("native_elf.zig");
const cs = @import("native_callsites.zig");
const checks = @import("native_checks.zig");

const t = std.testing;
const Sym = elf.Sym;

// Nothing is freed: each test's data lives until the process exits.
const A = std.heap.page_allocator;

fn def(name: []const u8) Sym {
    return .{ .name = name, .defined = true, .bind = .global, .vis = .default };
}

fn und(name: []const u8, version: ?[]const u8) Sym {
    return .{ .name = name, .defined = false, .bind = .global, .vis = .default, .version = version };
}

fn weakUnd(name: []const u8) Sym {
    return .{ .name = name, .defined = false, .bind = .weak, .vis = .default };
}

const weak_list = [_][]const u8{ "__gmon_start__", "komira_awslc_OPENSSL_memory_alloc", "sdallocx" };

/// komira_crypto's shape: two exports, glibc only, -Bsymbolic with -z now.
fn good() elf.Shared {
    const syms = A.dupe(Sym, &[_]Sym{
        def("komira_awslc_SHA256"),
        def("komira_crypto_sha256_hw_capable"),
        und("memcpy", "GLIBC_2.14"),
        und("pthread_once", "GLIBC_2.2.5"),
        weakUnd("__gmon_start__"),
        weakUnd("komira_awslc_OPENSSL_memory_alloc"),
        weakUnd("sdallocx"),
    }) catch unreachable;
    return .{
        .soname = "libkomira_crypto_native.so.1",
        .needed = &.{ "libpthread.so.0", "libc.so.6" },
        .flags = 0xa,
        .syms = syms,
        .verneed = &.{
            .{ .file = "libc.so.6", .version = "GLIBC_2.14" },
            .{ .file = "libpthread.so.0", .version = "GLIBC_2.2.5" },
        },
    };
}

const list = [_][]const u8{ "komira_awslc_SHA256", "komira_crypto_sha256_hw_capable" };

fn withSym(s: Sym) elf.Shared {
    var so = good();
    var syms = std.ArrayList(Sym).init(A);
    syms.appendSlice(so.syms) catch unreachable;
    syms.append(s) catch unreachable;
    so.syms = syms.items;
    return so;
}

fn expectRed(red: checks.Red, needle: []const u8) !void {
    try t.expect(!red.green());
    for (red.lines.items) |l| if (std.mem.indexOf(u8, l, needle) != null) return;
    std.debug.print("no finding names `{s}`; findings:\n", .{needle});
    for (red.lines.items) |l| std.debug.print("  {s}\n", .{l});
    return error.TestExpectedRed;
}

// ---- call sites -------------------------------------------------------------

fn scanAll(src: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).init(A);
    var fail = cs.Failure{};
    try cs.scan(src, &out, &fail);
    return cs.sortUnique(out.items);
}

test "call sites: one line, split lines, comments and strings between" {
    const src =
        \\from sys.ffi import external_call
        \\fn f():
        \\    _ = external_call["komira_a", Int]()
        \\    _ = external_call[
        \\        # the name
        \\        "komira_b",
        \\        Int,
        \\    ]()
        \\    _ = ffi.external_call  [ "komira_c" ]()
    ;
    const got = try scanAll(src);
    try t.expectEqual(@as(usize, 3), got.len);
    try t.expectEqualStrings("komira_a", got[0]);
    try t.expectEqualStrings("komira_b", got[1]);
    try t.expectEqualStrings("komira_c", got[2]);
}

test "call sites: names in comments, docstrings and strings are not read" {
    const src =
        \\# external_call["komira_comment", Int]
        \\fn f():
        \\    """Calls `external_call["komira_doc", Int]`.
        \\    external_call["komira_doc2"]
        \\    """
        \\    var s = "external_call[\"komira_str\"]"
        \\    var q = 'external_call["komira_str2"]'
        \\    _ = external_call["komira_real", Int]()
    ;
    const got = try scanAll(src);
    try t.expectEqual(@as(usize, 1), got.len);
    try t.expectEqualStrings("komira_real", got[0]);
}

test "call sites: a name that is not a string literal is refused with its line" {
    var out = std.ArrayList([]const u8).init(A);
    var fail = cs.Failure{};
    try t.expectError(error.CallSite, cs.scan("x\n\n_ = external_call[NAME, Int]()\n", &out, &fail));
    try t.expectEqual(@as(usize, 3), fail.line);
    try t.expectError(error.CallSite, cs.scan("_ = external_call[\"\", Int]()\n", &out, &fail));
}

// ---- the export list and version script -------------------------------------

test "exports: called and defined visible; libc names and uncalled symbols left out" {
    var red = checks.Red.init(A);
    const archives = [_]checks.Archive{
        .{ .label = "aws-lc", .syms = &.{ def("komira_awslc_SHA256"), def("komira_awslc_internal"), und("memcpy", null) } },
        .{ .label = "sha256_hw", .syms = &.{def("komira_crypto_sha256_hw_capable")} },
    };
    const callers = [_]checks.Caller{.{ .label = "komira_crypto", .calls = &.{ "explicit_bzero", "komira_awslc_SHA256", "komira_crypto_sha256_hw_capable" } }};
    const e = try checks.exportList(A, &archives, &callers, &red);
    try t.expect(red.green());
    try t.expectEqual(@as(usize, 2), e.names.len);
    try t.expectEqualStrings("komira_awslc_SHA256", e.names[0]);
    const script = try checks.versionScript(A, "libx.so.1", e.names);
    const globals = try checks.scriptGlobals(A, script);
    try t.expectEqual(@as(usize, 2), globals.len);
    try t.expectEqualStrings("komira_crypto_sha256_hw_capable", globals[1]);
    try t.expect(std.mem.indexOf(u8, script, "local:\n    *;") != null);
}

test "exports: a weak definition in two archives is red" {
    var red = checks.Red.init(A);
    var w = def("komira_x");
    w.bind = .weak;
    const archives = [_]checks.Archive{
        .{ .label = "a", .syms = &.{ def("komira_a"), w } },
        .{ .label = "b", .syms = &.{w} },
    };
    const callers = [_]checks.Caller{.{ .label = "c", .calls = &.{"komira_a"} }};
    _ = try checks.exportList(A, &archives, &callers, &red);
    try expectRed(red, "komira_x (a, b)");
}

test "exports: a hidden definition, an uncalled archive and a non-caller are red" {
    var red = checks.Red.init(A);
    var h = def("komira_hidden");
    h.vis = .hidden;
    const archives = [_]checks.Archive{
        .{ .label = "a", .syms = &.{ def("komira_a"), h } },
        .{ .label = "unused", .syms = &.{def("komira_u")} },
    };
    const callers = [_]checks.Caller{
        .{ .label = "c", .calls = &.{ "komira_a", "komira_hidden" } },
        .{ .label = "nobody", .calls = &.{"memcpy"} },
    };
    _ = try checks.exportList(A, &archives, &callers, &red);
    try expectRed(red, "komira_hidden");
    try expectRed(red, "archive unused defines none");
    try expectRed(red, "caller nobody calls none");
}

// ---- checks 1 to 7: green on the good object, red on each planted defect -----

test "check 1: green; red on an unprefixed export and on an export off the list" {
    var red = checks.Red.init(A);
    _ = try checks.check1(A, good(), &list, &list, &red);
    try t.expect(red.green());
    // Planted: an unprefixed export (a shim defining a libc name).
    red = checks.Red.init(A);
    _ = try checks.check1(A, withSym(def("explicit_bzero")), &list, &list, &red);
    try expectRed(red, "without the komira_ prefix (1): explicit_bzero");
    // Planted: a prefixed export not in the list.
    red = checks.Red.init(A);
    _ = try checks.check1(A, withSym(def("komira_awslc_extra")), &list, &list, &red);
    try expectRed(red, "not in the generated list (1): komira_awslc_extra");
    // The version script disagreeing with the list.
    red = checks.Red.init(A);
    _ = try checks.check1(A, good(), &list, list[0..1], &red);
    try expectRed(red, "not in the version script");
}

test "check 2: green; red on a called name the library does not export" {
    const archives = [_]checks.Archive{.{ .label = "a", .syms = &.{ def("komira_awslc_SHA256"), def("komira_crypto_sha256_hw_capable"), def("komira_awslc_HMAC") } }};
    var red = checks.Red.init(A);
    const callers = [_]checks.Caller{.{ .label = "c", .calls = &.{ "explicit_bzero", "komira_awslc_SHA256", "komira_crypto_sha256_hw_capable" } }};
    _ = try checks.check2(A, good(), &archives, &callers, &red);
    try t.expect(red.green());
    // Planted: a caller name missing from the exports.
    red = checks.Red.init(A);
    const more = [_]checks.Caller{.{ .label = "c", .calls = &.{ "komira_awslc_HMAC", "komira_awslc_SHA256" } }};
    _ = try checks.check2(A, good(), &archives, &more, &red);
    try expectRed(red, "does not export (1): komira_awslc_HMAC");
}

test "check 3: green; red on a strong undefined komira_ symbol and an unlisted weak one" {
    var red = checks.Red.init(A);
    _ = try checks.check3(A, good(), &weak_list, &red);
    try t.expect(red.green());
    red = checks.Red.init(A);
    _ = try checks.check3(A, withSym(und("komira_planted_missing", null)), &weak_list, &red);
    try expectRed(red, "strong undefined komira_ symbols no declared NEEDED owner exports (1): komira_planted_missing");
    red = checks.Red.init(A);
    _ = try checks.check3(A, withSym(weakUnd("komira_awslc_OPENSSL_memory_free")), &weak_list, &red);
    try expectRed(red, "komira_awslc_OPENSSL_memory_free");
}

test "check 4: green with libpthread, libc and ld-linux; red on an extra NEEDED, a run path, a SONAME" {
    var red = checks.Red.init(A);
    var so = good();
    so.needed = &.{ "libpthread.so.0", "libc.so.6", "ld-linux-x86-64.so.2" };
    _ = try checks.check4(A, so, "libkomira_crypto_native.so.1", &red);
    try t.expect(red.green());
    // Planted: an extra NEEDED.
    red = checks.Red.init(A);
    so.needed = &.{ "libc.so.6", "libm.so.6" };
    _ = try checks.check4(A, so, "libkomira_crypto_native.so.1", &red);
    try expectRed(red, "neither glibc nor a declared owner (1): libm.so.6");
    red = checks.Red.init(A);
    so = good();
    so.runpath = &.{"$ORIGIN"};
    _ = try checks.check4(A, so, "libkomira_crypto_native.so.1", &red);
    try expectRed(red, "RUNPATH");
    red = checks.Red.init(A);
    _ = try checks.check4(A, good(), "libother.so.1", &red);
    try expectRed(red, "SONAME is libkomira_crypto_native.so.1, not libother.so.1");
    red = checks.Red.init(A);
    so = good();
    so.needed = &.{"libpthread.so.0"};
    _ = try checks.check4(A, so, "libkomira_crypto_native.so.1", &red);
    try expectRed(red, "libc.so.6 is not NEEDED");
}

test "check 5: green at the floor; red above it, on GLIBC_PRIVATE, and on no glibc at all" {
    var red = checks.Red.init(A);
    var so = good();
    so.verneed = &.{ .{ .file = "libc.so.6", .version = "GLIBC_2.34" }, .{ .file = "libc.so.6", .version = "GLIBC_2.2.5" } };
    _ = try checks.check5(A, so, "2.34", &red);
    try t.expect(red.green());
    // Planted: a GLIBC_2.38 symbol (strlcpy).
    red = checks.Red.init(A);
    so = withSym(und("strlcpy", "GLIBC_2.38"));
    so.verneed = &.{ .{ .file = "libc.so.6", .version = "GLIBC_2.14" }, .{ .file = "libc.so.6", .version = "GLIBC_2.38" } };
    _ = try checks.check5(A, so, "2.34", &red);
    try expectRed(red, "needs GLIBC_2.38 from libc.so.6, above the floor glibc 2.34; symbols (1): strlcpy");
    red = checks.Red.init(A);
    so = good();
    so.verneed = &.{.{ .file = "libc.so.6", .version = "GLIBC_PRIVATE" }};
    _ = try checks.check5(A, so, "2.34", &red);
    try expectRed(red, "GLIBC_PRIVATE");
    red = checks.Red.init(A);
    so = good();
    so.verneed = &.{};
    _ = try checks.check5(A, so, "2.34", &red);
    try expectRed(red, "needs no GLIBC_ version");
    try t.expect(checks.versionAbove(&.{ 2, 38 }, &.{ 2, 34 }));
    try t.expect(!checks.versionAbove(&.{ 2, 2, 5 }, &.{ 2, 34 }));
    try t.expect(!checks.versionAbove(&.{ 2, 34 }, &.{ 2, 34, 0 }));
}

test "check 6: green on 0xa (symbolic and bind-now); red on 0x8 and on no DT_FLAGS" {
    var red = checks.Red.init(A);
    _ = try checks.check6(A, good(), &red);
    try t.expect(red.green());
    // Planted: the link without -Bsymbolic keeps zig's -z now: DT_FLAGS 0x8.
    red = checks.Red.init(A);
    var so = good();
    so.flags = 0x8;
    _ = try checks.check6(A, so, &red);
    try expectRed(red, "DT_FLAGS 0x8 lacks DF_SYMBOLIC");
    red = checks.Red.init(A);
    so.flags = null;
    _ = try checks.check6(A, so, &red);
    try expectRed(red, "no DT_FLAGS");
}

test "check 7: green; red on an unversioned strong undefined name, an unlisted weak one, a stale list" {
    var red = checks.Red.init(A);
    _ = try checks.check7(A, good(), &weak_list, &red);
    try t.expect(red.green());
    red = checks.Red.init(A);
    _ = try checks.check7(A, withSym(und("planted_undefined", null)), &weak_list, &red);
    try expectRed(red, "neither GLIBC_-versioned nor komira_ (1): planted_undefined");
    // Planted: an undefined name outside the recorded weak list.
    red = checks.Red.init(A);
    _ = try checks.check7(A, withSym(weakUnd("planted_weak")), &weak_list, &red);
    try expectRed(red, "not on the recorded weak list (1): planted_weak");
    red = checks.Red.init(A);
    _ = try checks.check7(A, good(), &(weak_list ++ [_][]const u8{"_ITM_registerTMCloneTable"}), &red);
    try expectRed(red, "no longer references (update the list) (1): _ITM_registerTMCloneTable");
}

// ---- the readers refuse what they cannot read -------------------------------

test "readers: a thin archive, a non-archive and a non-ELF shared object are errors" {
    try t.expectError(error.BadElf, elf.readArchive(A, "!<thin>\nxxxx"));
    try t.expectError(error.BadElf, elf.readArchive(A, "not an archive"));
    try t.expectError(error.BadElf, elf.readArchive(A, "!<arch>\n"));
    try t.expectError(error.BadElf, elf.readShared(A, "\x7fELF"));
    // A member header announcing 64 bytes, and none after it.
    const member = comptime blk: {
        var m = [_]u8{' '} ** 60;
        @memcpy(m[0..2], "x/");
        @memcpy(m[48..50], "64");
        @memcpy(m[58..60], "`\n");
        break :blk m;
    };
    const short = "!<arch>\n" ++ member;
    try t.expectError(error.BadElf, elf.readArchive(A, short));
}
