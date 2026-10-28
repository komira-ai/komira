//! Unit tests of abi_golden.zig's parts: the source reader, the golden reader,
//! the comparison and the header. The whole tool is run by
//! tests//negative/abi_golden and examples//abi_golden.
const std = @import("std");
const G = @import("abi_golden.zig");
const t = std.testing;

const source =
    "from std.ffi import external_call\n" ++
    "\n" ++
    "\"\"\"\n" ++
    "@export\n" ++
    "def in_docstring() abi(\"C\") -> Int32:\n" ++
    "\"\"\"\n" ++
    "\n" ++
    "@export\n" ++
    "def k_add(a: Int32, b: Int32) abi(\"C\") -> Int32:\n" ++
    "    return a + b\n" ++
    "\n" ++
    "@export  # a comment\n" ++
    "@always_inline\n" ++
    "def k_fill(\n" ++
    "    buf: UnsafePointer[UInt8, MutExternalOrigin],\n" ++
    "    n: Int,\n" ++
    ") abi(\"C\"):\n" ++
    "    pass\n" ++
    "\n" ++
    "@export\n" ++
    "def k_open() abi(\"C\") -> OpaquePointer[MutExternalOrigin]:\n" ++
    "    return OpaquePointer[MutExternalOrigin]()\n" ++
    "\n" ++
    "@export\n" ++
    "def mojo_only(a: String) -> String:\n" ++
    "    return a\n" ++
    "\n" ++
    "def not_exported() abi(\"C\") -> Int32:\n" ++
    "    return 1\n";

const golden =
    "version\t1.2\n" ++
    "# comment\n" ++
    "k_add\tInt32\tInt32,Int32\t1.0\n" ++
    "k_fill\tNone\tUnsafePointer[UInt8],Int\t1.1\n" ++
    "\n" ++
    "k_open\tOpaquePointer\t-\t1.2\n";

fn run(a: std.mem.Allocator, src: []const u8, gold: []const u8, f: *G.Findings) !?G.Golden {
    const sigs = try G.parseSource(a, src, f);
    const g = try G.parseGolden(a, gold, f);
    if (g) |gg| try G.check(a, sigs, gg, f);
    return g;
}

fn has(f: G.Findings, needle: []const u8) bool {
    for (f.list.items) |m| {
        if (std.mem.indexOf(u8, m, needle) != null) return true;
    }
    return false;
}

test "parseSource: C ABI exports only, multi-line signatures, decorators, comments and docstrings" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = G.Findings{ .a = a };
    const sigs = try G.parseSource(a, source, &f);
    try t.expectEqual(@as(usize, 0), f.list.items.len);
    try t.expectEqual(@as(usize, 3), sigs.len);
    try t.expectEqualStrings("k_add", sigs[0].symbol);
    try t.expectEqualStrings("Int32", sigs[0].ret);
    try t.expectEqual(@as(usize, 2), sigs[0].args.len);
    try t.expectEqualStrings("k_fill", sigs[1].symbol);
    try t.expectEqualStrings("None", sigs[1].ret);
    try t.expectEqualStrings("UnsafePointer[UInt8]", sigs[1].args[0]);
    try t.expectEqualStrings("Int", sigs[1].args[1]);
    try t.expectEqualStrings("OpaquePointer", sigs[2].ret);
    try t.expectEqual(@as(usize, 0), sigs[2].args.len);
}

test "parseSource: an @export(\"name\") symbol overrides the function name" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = G.Findings{ .a = a };
    const sigs = try G.parseSource(a, "@export(\"k_real\")\ndef impl() abi(\"C\") -> Int32:\n    return 1\n", &f);
    try t.expectEqual(@as(usize, 1), sigs.len);
    try t.expectEqualStrings("k_real", sigs[0].symbol);
}

test "parseSource: forms a C ABI function cannot have are findings" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = G.Findings{ .a = a };
    _ = try G.parseSource(a, "@export\ndef a(x: Int32 = 1) abi(\"C\") -> Int32:\n    return x\n", &f);
    _ = try G.parseSource(a, "@export\ndef b(var x: Int32) abi(\"C\") -> Int32:\n    return x\n", &f);
    _ = try G.parseSource(a, "@export\ndef c[T: AnyType](x: Int32) abi(\"C\") -> Int32:\n    return x\n", &f);
    _ = try G.parseSource(a, "@export\nstruct S:\n    pass\n", &f);
    _ = try G.parseSource(a, "@export\ndef d(x: Int32) raises abi(\"C\") -> Int32:\n    return x\n", &f);
    try t.expect(has(f, "parameter `x: Int32 = 1`"));
    try t.expect(has(f, "parameter `var x: Int32`"));
    try t.expect(has(f, "not a plain function name"));
    try t.expect(has(f, "not followed by a function"));
    try t.expect(has(f, "`raises` before abi"));
}

test "canonType: blanks and origins are dropped, a NoneType pointer is an OpaquePointer" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("UnsafePointer[UInt8]", try G.canonType(a, " UnsafePointer[ UInt8 , MutExternalOrigin ] "));
    try t.expectEqualStrings("UnsafePointer[UInt8]", try G.canonType(a, "UnsafePointer[mut=True, UInt8, origin]"));
    try t.expectEqualStrings("UnsafePointer[UnsafePointer[Int32]]", try G.canonType(a, "UnsafePointer[UnsafePointer[Int32, O], O]"));
    try t.expectEqualStrings("OpaquePointer", try G.canonType(a, "UnsafePointer[NoneType, MutExternalOrigin]"));
    try t.expectEqualStrings("OpaquePointer", try G.canonType(a, "OpaquePointer[MutExternalOrigin]"));
    try t.expectEqualStrings("Int32", try G.canonType(a, "Int32"));
}

test "cValueType: the type map, and the types it refuses" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("int32_t", try G.cValueType(a, "Int32"));
    try t.expectEqualStrings("uint64_t", try G.cValueType(a, "UInt64"));
    try t.expectEqualStrings("ptrdiff_t", try G.cValueType(a, "Int"));
    try t.expectEqualStrings("size_t", try G.cValueType(a, "UInt"));
    try t.expectEqualStrings("double", try G.cValueType(a, "Float64"));
    try t.expectEqualStrings("void *", try G.cValueType(a, "OpaquePointer"));
    try t.expectEqualStrings("uint8_t *", try G.cValueType(a, "UnsafePointer[UInt8]"));
    try t.expectEqualStrings("uint8_t **", try G.cValueType(a, "UnsafePointer[UnsafePointer[UInt8]]"));
    try t.expectEqualStrings("void **", try G.cValueType(a, "UnsafePointer[OpaquePointer]"));
    try t.expectEqualStrings("komira_handle", try G.cValueType(a, "Handle"));
    try t.expectEqualStrings("void", try G.cReturnType(a, "None"));
    try t.expectError(error.UnknownType, G.cValueType(a, "Bool"));
    try t.expectError(error.UnknownType, G.cValueType(a, "String"));
    try t.expectError(error.UnknownType, G.cValueType(a, "None"));
    try t.expectError(error.UnknownType, G.cValueType(a, "UnsafePointer[None]"));
    try t.expectError(error.UnknownType, G.cValueType(a, "UnsafePointer[Bool]"));
}

test "check: a source and a golden that agree have no finding" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = G.Findings{ .a = a };
    const g = try run(a, source, golden, &f);
    try t.expect(g != null);
    try t.expectEqual(@as(usize, 0), f.list.items.len);
}

test "check: a changed return type, a changed argument type and a changed argument count" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = G.Findings{ .a = a };
    _ = try run(a, source,
        "version\t1.2\n" ++
        "k_add\tInt64\tInt32,Int32\t1.0\n" ++
        "k_fill\tNone\tUnsafePointer[UInt8],Int32\t1.1\n" ++
        "k_open\tOpaquePointer\tInt\t1.2\n", &f);
    try t.expectEqual(@as(usize, 3), f.list.items.len);
    try t.expect(has(f, "`k_add`: the return type changed: golden `Int64`, source `Int32`"));
    try t.expect(has(f, "`k_fill`: the argument types changed: golden (UnsafePointer[UInt8], Int32), source (UnsafePointer[UInt8], Int)"));
    try t.expect(has(f, "`k_open`: the argument types changed: golden (Int), source ()"));
}

test "check: a missing and an extra symbol" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = G.Findings{ .a = a };
    _ = try run(a, source,
        "version\t1.2\n" ++
        "k_add\tInt32\tInt32,Int32\t1.0\n" ++
        "k_gone\tInt32\t-\t1.0\n" ++
        "k_open\tOpaquePointer\t-\t1.2\n", &f);
    try t.expectEqual(@as(usize, 2), f.list.items.len);
    try t.expect(has(f, "missing symbol `k_gone`"));
    try t.expect(has(f, "extra symbol `k_fill`"));
}

test "check: since above the golden version, and a symbol twice" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = G.Findings{ .a = a };
    _ = try run(a, source,
        "version\t1.1\n" ++
        "k_add\tInt32\tInt32,Int32\t1.0\n" ++
        "k_add\tInt32\tInt32,Int32\t1.0\n" ++
        "k_fill\tNone\tUnsafePointer[UInt8],Int\t1.1\n" ++
        "k_open\tOpaquePointer\t-\t1.2\n", &f);
    try t.expect(has(f, "`k_open`: since 1.2 is above the golden version 1.1"));
    try t.expect(has(f, "`k_add` is listed twice"));
    try t.expectEqual(@as(usize, 2), f.list.items.len);
    try t.expect(G.Ver.above(.{ .major = 2, .minor = 0 }, .{ .major = 1, .minor = 9 }));
    try t.expect(!G.Ver.above(.{ .major = 1, .minor = 9 }, .{ .major = 1, .minor = 9 }));
}

test "check: a type outside the map is a finding in the source and in the golden" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = G.Findings{ .a = a };
    _ = try run(a, "@export\ndef k_flag(x: Bool) abi(\"C\") -> Int32:\n    return 1\n", "version\t1.0\nk_flag\tInt32\tBool\t1.0\n", &f);
    try t.expectEqual(@as(usize, 2), f.list.items.len);
    try t.expect(has(f, "source: `k_flag`: the argument type `Bool` is not in the type map"));
    try t.expect(has(f, "golden: `k_flag`: the argument type `Bool` is not in the type map"));
}

test "parseGolden: the first line, the field count and the since are checked" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = G.Findings{ .a = a };
    try t.expect((try G.parseGolden(a, "k_add\tInt32\t-\t1.0\n", &f)) == null);
    try t.expect((try G.parseGolden(a, "version\t1\n", &f)) == null);
    try t.expect(has(f, "is not `version<TAB>"));
    var f2 = G.Findings{ .a = a };
    const g = try G.parseGolden(a, "version\t1.0\nk_a\tInt32\t-\n9bad\tInt32\t-\t1.0\nk_b\tInt32\t-\tx\n", &f2);
    try t.expect(g != null);
    try t.expectEqual(@as(usize, 3), f2.list.items.len);
    try t.expect(has(f2, "3 tab-separated fields, want 4"));
    try t.expect(has(f2, "`9bad` is not a C identifier"));
    try t.expect(has(f2, "since `x`"));
}

test "header: guards, includes, versions, handle typedef and one prototype per row" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = G.Findings{ .a = a };
    const g = (try G.parseGolden(a, golden, &f)).?;
    const h = try G.header(a, g, "komira.h", "abi.tsv");
    try t.expect(std.mem.indexOf(u8, h, "#ifndef KOMIRA_H\n#define KOMIRA_H\n") != null);
    try t.expect(std.mem.indexOf(u8, h, "#include <stddef.h>\n#include <stdint.h>\n") != null);
    try t.expect(std.mem.indexOf(u8, h, "#define KOMIRA_ABI_VERSION_MAJOR 1\n#define KOMIRA_ABI_VERSION_MINOR 2\n") != null);
    try t.expect(std.mem.indexOf(u8, h, "typedef struct komira_handle_s *komira_handle;") != null);
    try t.expect(std.mem.indexOf(u8, h, "/* since 1.0 */\nint32_t k_add(int32_t, int32_t);\n") != null);
    try t.expect(std.mem.indexOf(u8, h, "void k_fill(uint8_t *, ptrdiff_t);\n") != null);
    try t.expect(std.mem.indexOf(u8, h, "void *k_open(void);\n") != null);
    try t.expect(std.mem.endsWith(u8, h, "#endif /* KOMIRA_H */\n"));
}

const consts_golden =
    "version\t1.1\n" ++
    "constant\tKOMIRA_OK\t0\t1.0\n" ++
    "constant\tKOMIRA_ERR_TOO_LARGE\t-5\t1.1\n" ++
    "constant\tKOMIRA_MAX_INPUT_BYTES\t67108864\t1.1\n" ++
    "constant\tKOMIRA_BIG\t4294967296\t1.1\n";

const consts_source =
    "# a comment\n" ++
    "comptime KOMIRA_OK: Int32 = 0\n" ++
    "\"\"\"The call succeeded.\"\"\"\n" ++
    "comptime KOMIRA_ERR_TOO_LARGE: Int32 = -5  # too long\n" ++
    "comptime KOMIRA_MAX_INPUT_BYTES: UInt64 = 64 * 1024 * 1024\n" ++
    "comptime KOMIRA_BIG: UInt64 = 4096 * 1024 * 1024\n" ++
    "comptime ABI_MAJOR: Int32 = 1\n" ++
    "comptime KOMIRA_NAME: String = \"x\"\n" ++
    "    comptime KOMIRA_INDENTED: Int32 = 9\n";

test "parseGolden: constant rows are read, and a bad name, value, range, since or repeat is a finding" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = G.Findings{ .a = a };
    const g = (try G.parseGolden(a, consts_golden, &f)).?;
    try t.expectEqual(@as(usize, 0), f.list.items.len);
    try t.expectEqual(@as(usize, 4), g.consts.len);
    try t.expectEqual(@as(i128, -5), g.consts[1].value);
    try t.expectEqual(@as(u32, 1), g.consts[1].since.minor);
    try t.expectEqual(@as(usize, 0), g.rows.len);

    var f2 = G.Findings{ .a = a };
    const bad =
        "version\t1.0\n" ++
        "constant\tOK\t0\t1.0\n" ++
        "constant\tKOMIRA_ABI_VERSION_MAJOR\t1\t1.0\n" ++
        "constant\tKOMIRA_A\t0x10\t1.0\n" ++
        "constant\tKOMIRA_B\t-2147483649\t1.0\n" ++
        "constant\tKOMIRA_C\t18446744073709551616\t1.0\n" ++
        "constant\tKOMIRA_D\t1\tone\n" ++
        "constant\tKOMIRA_E\t1\t1.0\n" ++
        "constant\tKOMIRA_E\t2\t1.0\n";
    const g2 = (try G.parseGolden(a, bad, &f2)).?;
    try t.expectEqual(@as(usize, 7), f2.list.items.len);
    try t.expect(has(f2, "constant `OK` is not a C identifier starting with KOMIRA_"));
    try t.expect(has(f2, "`KOMIRA_ABI_VERSION_MAJOR` is defined by the header itself"));
    try t.expect(has(f2, "KOMIRA_A: value `0x10` is not a decimal integer"));
    try t.expect(has(f2, "KOMIRA_B: value -2147483649 is outside the header's range"));
    try t.expect(has(f2, "KOMIRA_C: value 18446744073709551616 is outside the header's range"));
    try t.expect(has(f2, "KOMIRA_D: since `one`"));
    try t.expect(has(f2, "constant `KOMIRA_E` is listed twice (first at line 8)"));
    try t.expectEqual(@as(usize, 2), g2.consts.len);
}

test "parseConstants: top-level integer comptimes of the prefix, products and negatives" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = G.Findings{ .a = a };
    const cs = try G.parseConstants(a, consts_source, &f);
    try t.expectEqual(@as(usize, 0), f.list.items.len);
    try t.expectEqual(@as(usize, 4), cs.len);
    try t.expectEqualStrings("KOMIRA_OK", cs[0].name);
    try t.expectEqual(@as(i128, -5), cs[1].value);
    try t.expectEqual(@as(i128, 67108864), cs[2].value);
    try t.expectEqual(@as(i128, 4294967296), cs[3].value);

    var f2 = G.Findings{ .a = a };
    const none = try G.parseConstants(a, "comptime KOMIRA_X: Int32 = 1 + 2\ncomptime KOMIRA_Y: Int32 = OTHER\n", &f2);
    try t.expectEqual(@as(usize, 0), none.len);
    try t.expectEqual(@as(usize, 2), f2.list.items.len);
    try t.expect(has(f2, "constants line 1: `KOMIRA_X` is not a product of integers"));
}

test "checkConstants: agreement, a changed value, a missing and an extra constant, no file, since" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f0 = G.Findings{ .a = a };
    const g = (try G.parseGolden(a, consts_golden, &f0)).?;
    const cs = try G.parseConstants(a, consts_source, &f0);

    var f = G.Findings{ .a = a };
    try G.checkConstants(g, cs, &f);
    try t.expectEqual(@as(usize, 0), f.list.items.len);

    // A value that moved.
    var moved = try a.dupe(G.SrcConst, cs);
    moved[1].value = -6;
    var f1 = G.Findings{ .a = a };
    try G.checkConstants(g, moved, &f1);
    try t.expectEqual(@as(usize, 1), f1.list.items.len);
    try t.expect(has(f1, "`KOMIRA_ERR_TOO_LARGE`: the value changed: golden -5, source -6"));

    // One the file dropped, and one it added.
    var f2 = G.Findings{ .a = a };
    try G.checkConstants(g, cs[1..], &f2);
    try t.expect(has(f2, "missing constant `KOMIRA_OK`"));
    var f3 = G.Findings{ .a = a };
    var more = std.ArrayList(G.SrcConst).empty;
    try more.appendSlice(a, cs);
    try more.append(a, .{ .name = "KOMIRA_NEW", .value = 7, .line = 99 });
    try G.checkConstants(g, more.items, &f3);
    try t.expectEqual(@as(usize, 1), f3.list.items.len);
    try t.expect(has(f3, "extra constant `KOMIRA_NEW`"));

    // Constants in the golden and nothing to hold them to.
    var f4 = G.Findings{ .a = a };
    try G.checkConstants(g, null, &f4);
    try t.expect(has(f4, "the golden lists 4 constants and the target has no constants_src"));

    // A constants file with an empty golden: every constant is extra.
    var f5 = G.Findings{ .a = a };
    const empty = (try G.parseGolden(a, "version\t1.0\n", &f5)).?;
    try G.checkConstants(empty, cs, &f5);
    try t.expectEqual(@as(usize, 4), f5.list.items.len);

    // since above the version.
    var f6 = G.Findings{ .a = a };
    const late = (try G.parseGolden(a, "version\t1.0\nconstant\tKOMIRA_OK\t0\t1.1\n", &f6)).?;
    try G.checkConstants(late, &.{.{ .name = "KOMIRA_OK", .value = 0, .line = 1 }}, &f6);
    try t.expect(has(f6, "`KOMIRA_OK`: since 1.1 is above the golden version 1.0"));
}

test "header: constants are defines after the versions, a value above int takes ULL" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = G.Findings{ .a = a };
    const g = (try G.parseGolden(a, consts_golden, &f)).?;
    const h = try G.header(a, g, "komira.h", "komira.tsv");
    try t.expect(std.mem.indexOf(u8, h, "/* since 1.0 */\n#define KOMIRA_OK (0)\n") != null);
    try t.expect(std.mem.indexOf(u8, h, "#define KOMIRA_ERR_TOO_LARGE (-5)\n") != null);
    try t.expect(std.mem.indexOf(u8, h, "#define KOMIRA_MAX_INPUT_BYTES (67108864)\n") != null);
    try t.expect(std.mem.indexOf(u8, h, "#define KOMIRA_BIG (4294967296ULL)\n") != null);
    const minor = std.mem.indexOf(u8, h, "KOMIRA_ABI_VERSION_MINOR").?;
    try t.expect(std.mem.indexOf(u8, h, "KOMIRA_OK").? > minor);
    // No constants, no block: the earlier golden's header is unchanged.
    var f2 = G.Findings{ .a = a };
    const plain = try G.header(a, (try G.parseGolden(a, golden, &f2)).?, "komira.h", "abi.tsv");
    try t.expect(std.mem.indexOf(u8, plain, "#define KOMIRA_OK") == null);
}

test "named types: CStr and ConstBytes map to const C pointers and the source must declare them" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("const char *", try G.cValueType(a, "CStr"));
    try t.expectEqualStrings("const uint8_t *", try G.cValueType(a, "ConstBytes"));
    const fn_src = "@export\ndef k_open(path: CStr, plan: ConstBytes) abi(\"C\") -> Int32:\n    return 0\n";

    var f = G.Findings{ .a = a };
    _ = try G.parseSource(a, "comptime CStr = UnsafePointer[UInt8, MutUntrackedOrigin]\ncomptime ConstBytes = UnsafePointer[UInt8, MutUntrackedOrigin]\n" ++ fn_src, &f);
    try t.expectEqual(@as(usize, 0), f.list.items.len);

    // Used and never declared.
    var f1 = G.Findings{ .a = a };
    _ = try G.parseSource(a, fn_src, &f1);
    try t.expectEqual(@as(usize, 2), f1.list.items.len);
    try t.expect(has(f1, "uses the type `CStr` and the source declares no `comptime CStr = ...`"));
    try t.expect(has(f1, "uses the type `ConstBytes`"));

    // Declared as some other type: a `const char *` over an Int32 pointer.
    var f2 = G.Findings{ .a = a };
    _ = try G.parseSource(a, "comptime CStr = UnsafePointer[Int32, MutUntrackedOrigin]\ncomptime ConstBytes = UnsafePointer[UInt8, MutUntrackedOrigin]\n" ++ fn_src, &f2);
    try t.expectEqual(@as(usize, 1), f2.list.items.len);
    try t.expect(has(f2, "`CStr` is declared as `UnsafePointer[Int32]` and must be `UnsafePointer[UInt8]`"));
}
