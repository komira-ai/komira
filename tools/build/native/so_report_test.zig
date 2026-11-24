//! Unit tests of so_report.zig (run by `:so_report_unit`): the version order,
//! what the target reaches, the symbols an owner defines for it, and the
//! report as text, each on values or on the built shared object of
//! native_elf_test.zig.

const std = @import("std");
const elf = @import("native_elf.zig");
const fx = @import("native_elf_test.zig");
const rep = @import("so_report.zig");

const t = std.testing;
const A = std.heap.page_allocator;
const Lib = rep.Lib;
const Version = rep.Version;

fn need(version: []const u8) elf.Need {
    return .{ .file = "libc.so.6", .version = version };
}

fn und(name: []const u8) elf.Sym {
    return .{ .name = name, .defined = false, .bind = .global, .vis = .default };
}

fn def(name: []const u8) elf.Sym {
    return .{ .name = name, .defined = true, .bind = .global, .vis = .default };
}

fn lib(name: []const u8, role: rep.Role, size: u64, so: elf.Shared) Lib {
    var s = so;
    s.soname = name;
    return .{ .name = name, .role = role, .size = size, .so = s };
}

fn text(libs: []const Lib, floor: ?Version) ![]const u8 {
    var b = std.ArrayList(u8).empty;
    try rep.report(A, b.writer(A), libs, floor);
    return b.items;
}

test "version: parsed by component, so 2.34 is above 2.9 and 2.2.5 is below 2.14" {
    const v = Version.parse;
    try t.expectEqual(std.math.Order.gt, v("2.34").?.order(v("2.9").?));
    try t.expectEqual(std.math.Order.lt, v("2.2.5").?.order(v("2.14").?));
    try t.expectEqual(std.math.Order.eq, v("2.34").?.order(v("2.34.0").?));
    try t.expect(v("") == null);
    try t.expect(v("2.x") == null);
    try t.expect(v("1.2.3.4.5") == null);
}

test "highest: per prefix, numerically, and GLIBC does not read GLIBCXX" {
    const so = elf.Shared{ .verneed = &.{
        need("GLIBC_2.2.5"),
        need("GLIBC_2.34"),
        need("GLIBC_2.9"),
        need("GLIBCXX_3.4.30"),
        need("GLIBCXX_3.4.9"),
        need("CXXABI_1.3.13"),
        need("GCC_3.0"),
        need("GLIBC_PRIVATE"),
    } };
    var b = std.ArrayList(u8).empty;
    try rep.highest(so, "GLIBC").?.print(b.writer(A));
    try t.expectEqualStrings("2.34", b.items);
    b.clearRetainingCapacity();
    try rep.highest(so, "GLIBCXX").?.print(b.writer(A));
    try t.expectEqualStrings("3.4.30", b.items);
    b.clearRetainingCapacity();
    try rep.highest(so, "CXXABI").?.print(b.writer(A));
    try t.expectEqualStrings("1.3.13", b.items);
    try t.expect(rep.highest(.{}, "GLIBC") == null);
}

test "reach: direct, through another library, and declared only; glibc reaches nothing" {
    const libs = [_]Lib{
        lib("libk.so", .target, 1, .{ .needed = &.{ "libowner_a.so.1", "libc.so.6", "libKGEN.so" } }),
        lib("libowner_a.so.1", .owner, 1, .{ .needed = &.{ "libowner_b.so.1", "libc.so.6" } }),
        lib("libowner_b.so.1", .owner, 1, .{}),
        lib("libowner_c.so.1", .owner, 1, .{ .needed = &.{"libowner_a.so.1"} }),
        lib("libKGEN.so", .runtime, 1, .{ .needed = &.{"libMSupport.so"} }),
        lib("libMSupport.so", .runtime, 1, .{}),
    };
    const r = try rep.reach(A, &libs, 0);
    try t.expectEqual(rep.Reach.none, r[0]);
    try t.expectEqual(rep.Reach.direct, r[1]);
    try t.expectEqual(rep.Reach.transitive, r[2]);
    // c needs a, but nothing the target loads needs c.
    try t.expectEqual(rep.Reach.none, r[3]);
    try t.expectEqual(rep.Reach.direct, r[4]);
    try t.expectEqual(rep.Reach.transitive, r[5]);
}

test "reach: a NEEDED cycle ends and never marks the target" {
    const libs = [_]Lib{
        lib("libk.so", .target, 1, .{ .needed = &.{"liba.so"} }),
        lib("liba.so", .owner, 1, .{ .needed = &.{"libk.so"} }),
    };
    const r = try rep.reach(A, &libs, 0);
    try t.expectEqual(rep.Reach.none, r[0]);
    try t.expectEqual(rep.Reach.direct, r[1]);
}

test "bound: counts the target's undefined symbols the owner exports, not defined or hidden ones" {
    const target = elf.Shared{ .syms = &.{ und("f"), und("g"), und("h"), def("f_own"), und("hid") } };
    const owner = elf.Shared{ .syms = &.{
        def("f"),
        def("g"),
        def("f_own"),
        .{ .name = "hid", .defined = true, .bind = .global, .vis = .hidden },
    } };
    try t.expectEqual(@as(usize, 2), try rep.bound(A, target, owner));
    try t.expectEqual(@as(usize, 0), try rep.bound(A, target, .{}));
}

test "report: the whole table for a target, a needed owner, a declared-only owner and a runtime library" {
    const libs = [_]Lib{
        lib("libk.so", .target, 1000, .{
            .runpath = &.{ "$ORIGIN/lib", "$ORIGIN" },
            .needed = &.{ "libo.so.1", "libKGEN.so", "libc.so.6" },
            .verneed = &.{ need("GLIBC_2.34"), need("GLIBC_2.2.5") },
            .syms = &.{ und("o_call"), und("dlopen") },
        }),
        lib("libo.so.1", .owner, 20, .{ .syms = &.{def("o_call")}, .verneed = &.{need("GLIBC_2.17")} }),
        lib("libz.so.1", .owner, 30, .{}),
        lib("libKGEN.so", .runtime, 400, .{ .verneed = &.{ need("GLIBCXX_3.4.30"), need("CXXABI_1.3.13"), need("GLIBC_2.38") } }),
    };
    try t.expectEqualStrings(
        \\| file | role | size (bytes) | SONAME | RUNPATH | RPATH | highest GLIBC | highest GLIBCXX | highest CXXABI |
        \\|---|---|---|---|---|---|---|---|---|
        \\| `libk.so` | target | 1000 | `libk.so` | `$ORIGIN/lib`, `$ORIGIN` | none | `GLIBC_2.34` | none | none |
        \\| `libo.so.1` | owner | 20 | `libo.so.1` | none | none | `GLIBC_2.17` | none | none |
        \\| `libz.so.1` | owner | 30 | `libz.so.1` | none | none | none | none | none |
        \\| `libKGEN.so` | runtime | 400 | `libKGEN.so` | none | none | `GLIBC_2.38` | `GLIBCXX_3.4.30` | `CXXABI_1.3.13` |
        \\
        \\| file | DT_NEEDED, in order |
        \\|---|---|
        \\| `libk.so` | `libo.so.1`, `libKGEN.so`, `libc.so.6` |
        \\| `libo.so.1` | none |
        \\| `libz.so.1` | none |
        \\| `libKGEN.so` | none |
        \\
        \\| library | role | reached from the target | target's undefined symbols it defines |
        \\|---|---|---|---|
        \\| `libo.so.1` | owner | needed (direct) | 1 |
        \\| `libz.so.1` | owner | declared only | 0 |
        \\| `libKGEN.so` | runtime | needed (direct) | 0 |
        \\
        \\Owners needed: 1 of 2 (20 bytes); declared only: 1.
        \\
        \\Wheel tag: `manylinux_2_34` (highest GLIBC of the target and the owners: `GLIBC_2.34`).
        \\
    , try text(&libs, Version.parse("2.34")));
}

test "report: a GLIBC above the floor is named on the first line and sets the tag; at the floor it is not" {
    const libs = [_]Lib{
        lib("libk.so", .target, 1, .{ .verneed = &.{need("GLIBC_2.34")} }),
        lib("libo.so.1", .owner, 1, .{ .verneed = &.{need("GLIBC_2.38")} }),
    };
    const over = try text(&libs, Version.parse("2.34"));
    try t.expect(std.mem.startsWith(u8, over, "**FLOOR EXCEEDED: the target or an owner needs `GLIBC_2.38`, above the promised `GLIBC_2.34`; the wheel tag is `manylinux_2_38`, not `manylinux_2_34`.**\n\n| file"));
    try t.expect(std.mem.endsWith(u8, over, "Wheel tag: `manylinux_2_38` (highest GLIBC of the target and the owners: `GLIBC_2.38`).\n"));
    const ok = try text(libs[0..1], Version.parse("2.34"));
    try t.expect(std.mem.startsWith(u8, ok, "| file"));
    // A runtime library above the floor is not shipped, so it does not move the tag.
    const rt = [_]Lib{ libs[0], lib("libr.so", .runtime, 1, .{ .verneed = &.{need("GLIBC_2.38")} }) };
    try t.expect(std.mem.startsWith(u8, try text(&rt, Version.parse("2.34")), "| file"));
    try t.expect(std.mem.startsWith(u8, try text(&libs, null), "| file"));
}

test "report: no target is an error" {
    const libs = [_]Lib{lib("libo.so.1", .owner, 1, .{})};
    try t.expectError(error.NoTarget, text(&libs, null));
}

test "report: a built shared object is read with its size, run paths and versions" {
    const bytes = fx.fixture(.{});
    const so = try elf.readShared(A, bytes);
    const libs = [_]Lib{.{ .name = "libkomira_t.so.1", .role = .target, .size = bytes.len, .so = so }};
    const out = try text(&libs, null);
    var want = std.ArrayList(u8).empty;
    try want.writer(A).print("| `libkomira_t.so.1` | target | {d} | `libkomira_t.so.1` | `$ORIGIN/lib`, `/opt/runpath` | `/opt/rpath` | `GLIBC_2.14` | none | none |\n", .{bytes.len});
    try t.expect(std.mem.indexOf(u8, out, want.items) != null);
    try t.expect(std.mem.indexOf(u8, out, "| `libkomira_t.so.1` | `libpthread.so.0`, `libstray.so.1`, `libc.so.6` |\n") != null);
}

test "report: a target and owners that need no glibc say so and give no tag" {
    const libs = [_]Lib{lib("libk.so", .target, 1, .{})};
    const out = try text(&libs, Version.parse("2.34"));
    try t.expect(std.mem.endsWith(u8, out, "Wheel tag: no GLIBC version is needed by the target or the owners.\n"));
    try t.expect(std.mem.startsWith(u8, out, "| file"));
}

test "highest: a bare prefix with no version is ignored" {
    try t.expect(rep.highest(.{ .verneed = &.{ need("GLIBC_"), need("GLIBC") } }, "GLIBC") == null);
}

test "args: a full command line is read in order" {
    const a = try rep.parseArgs(A, &.{ "--out", "o.md", "--floor", "2.34", "--target", "libk.so", "/p/k", "--owner", "libo.so.1", "/p/o", "--runtime", "libr.so", "/p/r" });
    try t.expectEqualStrings("o.md", a.out);
    try t.expectEqual(std.math.Order.eq, a.floor.?.order(Version.parse("2.34").?));
    try t.expectEqual(@as(usize, 3), a.files.len);
    try t.expectEqual(rep.Role.target, a.files[0].role);
    try t.expectEqual(rep.Role.owner, a.files[1].role);
    try t.expectEqual(rep.Role.runtime, a.files[2].role);
    try t.expectEqualStrings("libo.so.1", a.files[1].name);
    try t.expectEqualStrings("/p/o", a.files[1].path);
    try t.expect((try rep.parseArgs(A, &.{ "--out", "o.md", "--target", "k", "/p" })).floor == null);
}

test "args: each mistake is its own error" {
    try t.expectError(error.NoOut, rep.parseArgs(A, &.{ "--target", "k", "/p" }));
    try t.expectError(error.NotOneTarget, rep.parseArgs(A, &.{ "--out", "o" }));
    try t.expectError(error.NotOneTarget, rep.parseArgs(A, &.{ "--out", "o", "--target", "a", "/a", "--target", "b", "/b" }));
    try t.expectError(error.BadFloor, rep.parseArgs(A, &.{ "--out", "o", "--floor", "x", "--target", "k", "/p" }));
    try t.expectError(error.Usage, rep.parseArgs(A, &.{ "--out", "o", "--target", "k" }));
    try t.expectError(error.Usage, rep.parseArgs(A, &.{ "--bogus" }));
    try t.expectError(error.Usage, rep.parseArgs(A, &.{ "--out" }));
}
