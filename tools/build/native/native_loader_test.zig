//! Unit tests of `checkLoader` (native_checks.zig), the check `c_shared_lib`
//! runs on every library it links (tools/build/node/defs.bzl), run by
//! `:native_so_unit`. A Node-API addon leaves the `napi_` and `node_api_`
//! functions to `node`, which loads it; every other undefined symbol must be
//! bound to a library the addon loads, so a function the sources call and
//! nothing defines fails the build instead of the addon's load. Each case is
//! an ELF library as the reader returns it, or Mach-O bytes read by
//! native_macho.zig, green or red on one defect.

const std = @import("std");
const elf = @import("native_elf.zig");
const checks = @import("native_checks.zig");
const mt = @import("native_macho_test.zig");

const t = std.testing;
const A = std.heap.page_allocator;
const Sym = elf.Sym;

const node_api = [_][]const u8{ "napi_", "node_api_" };
const init = [_][]const u8{"napi_register_module_v1"};

fn def(name: []const u8) Sym {
    return .{ .name = name, .defined = true, .bind = .global, .vis = .default };
}

fn und(name: []const u8, version: ?[]const u8) Sym {
    return .{ .name = name, .defined = false, .bind = .global, .vis = .default, .version = version };
}

/// An ELF addon's shape: its module init exported, glibc's memcpy and
/// dlopen (versioned), two Node-API functions (unversioned: left to
/// `node`) and glibc's weak `__gmon_start__`.
fn addon(extra: []const Sym) elf.Shared {
    var syms = std.ArrayList(Sym).empty;
    syms.appendSlice(A, &.{
        def("napi_register_module_v1"),
        und("memcpy", "GLIBC_2.14"),
        und("dlopen", "GLIBC_2.34"),
        und("napi_create_function", null),
        und("node_api_symbol_for", null),
        .{ .name = "__gmon_start__", .defined = false, .bind = .weak, .vis = .default },
    }) catch unreachable;
    syms.appendSlice(A, extra) catch unreachable;
    return .{ .soname = "komira_addon.node", .needed = &.{"libc.so.6"}, .syms = syms.items };
}

fn expectOnly(red: checks.Red, line: []const u8) !void {
    try t.expectEqual(@as(usize, 1), red.lines.items.len);
    try t.expectEqualStrings(line, red.lines.items[0]);
}

test "loader, ELF: Node-API names left to node and glibc's versioned names are green, the weak reference is not held" {
    var red = checks.Red.init(A);
    const msg = try checks.checkLoader(A, addon(&.{}), &node_api, &init, &red);
    try t.expect(red.green());
    try t.expectEqualStrings("2 strong undefined symbols bound to the libraries it loads and 2 left to the loading program, all napi_* or node_api_*; exports the 1 required", msg);
}

test "loader, ELF: a function nothing the addon loads defines is red, by name" {
    var red = checks.Red.init(A);
    _ = try checks.checkLoader(A, addon(&.{ und("komira_missing_helper", null), und("arrow_result_value", null) }), &node_api, &init, &red);
    try expectOnly(red, "strong undefined symbols left to the loading program that are not napi_* or node_api_* (2): arrow_result_value komira_missing_helper");
}

test "loader: a prefix matches a name's beginning only, and the whole prefix" {
    var red = checks.Red.init(A);
    _ = try checks.checkLoader(A, addon(&.{ und("napi", null), und("napifoo", null), und("my_napi_call", null), und("node_apix", null) }), &node_api, &init, &red);
    try expectOnly(red, "strong undefined symbols left to the loading program that are not napi_* or node_api_* (4): my_napi_call napi napifoo node_apix");
}

test "loader: with no prefix to leave, a library leaves nothing to the loading program, Node-API names included" {
    var red = checks.Red.init(A);
    _ = try checks.checkLoader(A, addon(&.{}), &.{}, &.{}, &red);
    try expectOnly(red, "strong undefined symbols left to the loading program, which may define none of them (2): napi_create_function node_api_symbol_for");

    red = checks.Red.init(A);
    const so = elf.Shared{ .syms = &.{ def("komira_fake_version"), und("strlen", "GLIBC_2.2.5") } };
    const msg = try checks.checkLoader(A, so, &.{}, &.{}, &red);
    try t.expect(red.green());
    try t.expectEqualStrings("1 strong undefined symbols, all bound to the libraries it loads; none left to the loading program; exports the 0 required", msg);
}

test "loader: a required export that is absent, or defined with hidden visibility, is red" {
    var red = checks.Red.init(A);
    var so = addon(&.{});
    so.syms = so.syms[1..];
    _ = try checks.checkLoader(A, so, &node_api, &init, &red);
    try expectOnly(red, "names the library must export and does not (1): napi_register_module_v1");

    red = checks.Red.init(A);
    var hidden = addon(&.{});
    var syms = std.ArrayList(Sym).empty;
    try syms.append(A, .{ .name = "napi_register_module_v1", .defined = true, .bind = .global, .vis = .hidden });
    try syms.appendSlice(A, hidden.syms[1..]);
    hidden.syms = syms.items;
    _ = try checks.checkLoader(A, hidden, &node_api, &init, &red);
    try expectOnly(red, "names the library must export and does not (1): napi_register_module_v1");
}

const N_UNDF_EXT: u8 = 0x01;

/// A Mach-O addon linked with `-undefined dynamic_lookup`: the module init
/// exported, memcpy bound to libSystem (ordinal 1), Node-API names bound to
/// flat lookup (ordinal 0xfe), and `extra`.
fn machoAddon(extra: []const mt.NSym) !elf.Shared {
    var syms = std.ArrayList(mt.NSym).empty;
    try syms.appendSlice(A, &.{
        .{ .name = "_napi_register_module_v1", .ty = mt.N_SECT_EXT },
        .{ .name = "_memcpy", .ty = N_UNDF_EXT, .desc = 0x0100 },
        .{ .name = "_napi_get_undefined", .ty = N_UNDF_EXT, .desc = 0xfe00 },
        .{ .name = "_napi_create_function", .ty = N_UNDF_EXT, .desc = 0xfe00 },
        .{ .name = "_node_api_get_module_file_name", .ty = N_UNDF_EXT, .desc = 0xfe00 },
        // A weak reference left to flat lookup: null when nothing defines it.
        .{ .name = "_komira_weak_hook", .ty = N_UNDF_EXT, .desc = 0xfe40 },
    });
    try syms.appendSlice(A, extra);
    return elf.readShared(A, mt.dylib(.{
        .ids = &.{"@rpath/komira_addon.node"},
        .loads = &.{.{ .name = "/usr/lib/libSystem.B.dylib" }},
        .rpaths = &.{},
        .syms = syms.items,
    }));
}

test "loader, Mach-O: Node-API names bound to flat lookup and libSystem's names are green" {
    var red = checks.Red.init(A);
    const msg = try checks.checkLoader(A, try machoAddon(&.{}), &node_api, &init, &red);
    try t.expect(red.green());
    try t.expectEqualStrings("1 strong undefined symbols bound to the libraries it loads and 3 left to the loading program, all napi_* or node_api_*; exports the 1 required", msg);
}

test "loader, Mach-O: a name left to flat lookup, the main executable or the library itself is red unless it is Node-API's" {
    var red = checks.Red.init(A);
    _ = try checks.checkLoader(A, try machoAddon(&.{
        .{ .name = "_komira_missing_helper", .ty = N_UNDF_EXT, .desc = 0xfe00 },
        .{ .name = "_from_the_executable", .ty = N_UNDF_EXT, .desc = 0xff00 },
        .{ .name = "_from_itself", .ty = N_UNDF_EXT, .desc = 0x0000 },
        .{ .name = "_napi_from_the_executable", .ty = N_UNDF_EXT, .desc = 0xff00 },
    }), &node_api, &init, &red);
    try expectOnly(red, "strong undefined symbols left to the loading program that are not napi_* or node_api_* (3): from_itself from_the_executable komira_missing_helper");
}

test "loader, Mach-O: an undefined symbol with no library recorded is left to the loading program" {
    var red = checks.Red.init(A);
    const so = elf.Shared{ .format = .macho, .syms = &.{ def("napi_register_module_v1"), und("napi_get_null", null), und("strlen", null) } };
    _ = try checks.checkLoader(A, so, &node_api, &init, &red);
    try expectOnly(red, "strong undefined symbols left to the loading program that are not napi_* or node_api_* (1): strlen");
}

test "loader, Mach-O: the module init kept private (N_PEXT) is not exported, and is red" {
    var red = checks.Red.init(A);
    const so = try elf.readShared(A, mt.dylib(.{
        .ids = &.{"@rpath/komira_addon.node"},
        .loads = &.{.{ .name = "/usr/lib/libSystem.B.dylib" }},
        .rpaths = &.{},
        .syms = &.{
            .{ .name = "_napi_register_module_v1", .ty = 0x1f },
            .{ .name = "_napi_get_undefined", .ty = N_UNDF_EXT, .desc = 0xfe00 },
        },
    }));
    _ = try checks.checkLoader(A, so, &node_api, &init, &red);
    try expectOnly(red, "names the library must export and does not (1): napi_register_module_v1");
}
