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
