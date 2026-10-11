//! The scenarios of the pointer lint (pointer_lint.zig), run by
//! `zig test pointer_lint_test.zig` (BUCK: :pointer_lint_test, which the
//! tool is built behind). Each test is one scenario: a rule's site in each
//! form a statement takes, a near miss that is not a site, a library-file
//! decision, or a ledger defect, with the exact line a finding prints.

const std = @import("std");
const pl = @import("pointer_lint.zig");
const testing = std.testing;

/// The sites of one library file (src/komira_a/m.mojo), as
/// `<line>: <rule>: <text>` lines.
fn sitesOf(arena: *std.heap.ArenaAllocator, path: []const u8, src: []const u8) ![]const []const u8 {
    const a = arena.allocator();
    const res = try pl.readFile(a, path, src, "src/");
    var out = std.ArrayList([]const u8).init(a);
    for (res.sites) |s| try out.append(try std.fmt.allocPrint(a, "{d}: {s}: {s}", .{ s.line, @tagName(s.rule), s.text }));
    return out.items;
}

fn expectSites(path: []const u8, src: []const u8, want: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try sitesOf(&arena, path, src);
    if (got.len != want.len) {
        std.debug.print("want {d} sites, got {d}:\n", .{ want.len, got.len });
        for (got) |g| std.debug.print("  {s}\n", .{g});
        return error.TestUnexpectedResult;
    }
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

const lib = "src/komira_a/m.mojo";

test "wildcard origin: one site per occurrence, two in one signature" {
    try expectSites(lib,
        \\def _f(p: UnsafePointer[UInt8, MutAnyOrigin], q: UnsafePointer[UInt8, ImmutAnyOrigin]):
        \\    var r: UnsafePointer[UInt8, MutUntrackedOrigin]
        \\    comptime O = MutExternalOrigin
    , &.{
        "1: wildcard_origin: def _f(p: UnsafePointer[UInt8, MutAnyOrigin], q: UnsafePointer[UInt8, ImmutAnyOrigin]):",
        "1: wildcard_origin: def _f(p: UnsafePointer[UInt8, MutAnyOrigin], q: UnsafePointer[UInt8, ImmutAnyOrigin]):",
        "2: wildcard_origin: var r: UnsafePointer[UInt8, MutUntrackedOrigin]",
        "3: wildcard_origin: comptime O = MutExternalOrigin",
    });
}

test "from_address over three lines is one site at its first line" {
    try expectSites(lib,
        \\def _f(a: Int):
        \\    var p = UnsafePointer[UInt8, o](
        \\        unsafe_from_address
        \\        = a)
    , &.{"2: from_address: var p = UnsafePointer[UInt8, o]( unsafe_from_address = a)"});
}

test "partial move: one line, over three lines, with type parameters" {
    try expectSites(lib,
        \\def _f(mut r: Record):
        \\    var a = UnsafePointer(to=r.f).take_pointee()
        \\    var b = UnsafePointer(
        \\        to=r.g
        \\    ).take_pointee()
        \\    var c = UnsafePointer[Record, o](to = r . h).take_pointee()
    , &.{
        "2: partial_move: var a = UnsafePointer(to=r.f).take_pointee()",
        "3: partial_move: var b = UnsafePointer( to=r.g ).take_pointee()",
        "6: partial_move: var c = UnsafePointer[Record, o](to = r . h).take_pointee()",
    });
}

test "partial move, two statements: the take is the site and names the binding line" {
    try expectSites(lib,
        \\def _f(mut r: Record):
        \\    var p = UnsafePointer(to=r.name)
        \\    var v = p.take_pointee()
        \\    var q: UnsafePointer[Record, o] = UnsafePointer[Record, o](to=r.f)
        \\    _ = q . take_pointee()
    , &.{
        "3: partial_move: var v = p.take_pointee() (bound to a field's address at line 2)",
        "5: partial_move: _ = q . take_pointee() (bound to a field's address at line 4)",
    });
}

test "not a partial move: a whole value, a subscript, an address never taken" {
    try expectSites(lib,
        \\def _f(mut r: Record, p: UnsafePointer[Record, o], items: List[Record]):
        \\    var a = UnsafePointer(to=r).take_pointee()
        \\    var b = UnsafePointer(to=p[]).take_pointee()
        \\    var c = UnsafePointer(to=items[0]).take_pointee()
        \\    var q = UnsafePointer(to=r.name)
        \\    _ = q[]
    , &.{});
}

test "not a partial move: a name rebound before the take, or taken in another function" {
    try expectSites(lib,
        \\def _f(mut r: Record):
        \\    var t = UnsafePointer(to=r.name)
        \\    t = UnsafePointer(to=r)
        \\    _ = t.take_pointee()
        \\    var u = UnsafePointer(to=r.name)
        \\
        \\
        \\def _g(u: UnsafePointer[Record, o]):
        \\    _ = u.take_pointee()
        \\    _ = self.u.take_pointee()
    , &.{});
}

test "a name bound in one method is not the name of the next" {
    try expectSites(lib,
        \\struct _S:
        \\    def _bind(self, mut r: Record):
        \\        var w = UnsafePointer(to=r.name)
        \\
        \\    def _take(self, w: UnsafePointer[Record, o]):
        \\        _ = w.take_pointee()
    , &.{});
}

test "parallelize: plain and qualified, not a longer name" {
    try expectSites(lib,
        \\def _f(n: Int):
        \\    parallelize[_worker](n)
        \\    algorithm.parallelize [_worker](n)
        \\    my_parallelize[_worker](n)
    , &.{
        "2: parallelize: parallelize[_worker](n)",
        "3: parallelize: algorithm.parallelize [_worker](n)",
    });
}

test "libc read and open: the string kept, a trailing comment dropped" {
    try expectSites(lib,
        \\def _f():
        \\    _ = external_call["read", Int](0, 0, 0)  # reads
        \\    _ = external_call["write", Int](1, "\"#", 0); _ = external_call["read", Int](0)
        \\    _ = external_call[
        \\        "open", Int
        \\    ](0, 0)
        \\    _ = external_call["readlink", Int](0, 0, 0)
        \\    _ = external_call["openat", Int](0, 0, 0)
        \\    _ = external_call["write", Int](1, 0, 0)  # not external_call["read", Int]
    , &.{
        "2: libc_redeclare: _ = external_call[\"read\", Int](0, 0, 0) ",
        "3: libc_redeclare: _ = external_call[\"write\", Int](1, \"\\\"#\", 0); _ = external_call[\"read\", Int](0)",
        "4: libc_redeclare: _ = external_call[ \"open\", Int ](0, 0)",
    });
}

test "public pointer: a function, a return type, a dunder, a trait method, a long signature" {
    try expectSites(lib,
        \\def get(p: UnsafePointer[UInt8, o]) -> Int:
        \\    return 0
        \\
        \\fn raw() -> OpaquePointer:
        \\    ...
        \\
        \\struct Buf:
        \\    var p: UnsafePointer[UInt8, o]
        \\
        \\    def __init__(out self, p: UnsafePointer[UInt8, o]):
        \\        self.p = p
        \\
        \\    def _raw(self) -> UnsafePointer[UInt8, o]:
        \\        return self.p
        \\
        \\trait Source:
        \\    def data(
        \\        self,
        \\        n: Int,
        \\    ) -> UnsafePointer[
        \\        UInt8, o
        \\    ]:
        \\        ...
    , &.{
        "1: public_pointer: def get(p: UnsafePointer[UInt8, o]) -> Int:",
        "4: public_pointer: fn raw() -> OpaquePointer:",
        "10: public_pointer: def __init__(out self, p: UnsafePointer[UInt8, o]):",
        "17: public_pointer: def data( self, n: Int, ) -> UnsafePointer[ UInt8, o ]:",
    });
}

test "not public: a private function, a private struct's method, a nested function, a decorated method" {
    try expectSites(lib,
        \\def _private(p: UnsafePointer[UInt8, o]) -> Int:
        \\    return 0
        \\
        \\struct _Impl:
        \\    def get(self) -> UnsafePointer[UInt8, o]:
        \\        ...
        \\
        \\def value(x: Int) -> Int:
        \\    def inner(p: UnsafePointer[UInt8, o]) -> Int:
        \\        return 0
        \\    return x
        \\
        \\struct _Hidden:
        \\    @always_inline
        \\    def get(self) -> UnsafePointer[UInt8, o]:
        \\        ...
    , &.{});
}

test "a banned spelling in a docstring, a comment or a string is not a site" {
    try expectSites(lib,
        \\"""Near misses: MutAnyOrigin, unsafe_from_address=, parallelize[w](n),
        \\external_call["read", Int] and UnsafePointer(to=x.f).take_pointee().
        \\"""
        \\# MutUntrackedOrigin, unsafe_from_address=1, parallelize[w](n).
        \\comptime NOTE = "UnsafePointer(to=self.f).take_pointee() and MutExternalOrigin"
        \\comptime NOTE2 = 'external_call["open", Int] and ImmutAnyOrigin'
        \\struct MutAnyOriginal:
        \\    var unsafe_from_address_count: Int
        \\
        \\def _f():
        \\    x = 1  # a """ in a comment opens no docstring
        \\    '''A docstring in single quotes may name MutAnyOrigin
        \\    and unsafe_from_address= as well.
        \\    '''
    , &.{});
}

test "a library file: under the root, not in a package's tests, no private segment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { path: []const u8, lib: bool }{
        .{ .path = "src/komira_a/m.mojo", .lib = true },
        .{ .path = "src/komira_a/__init__.mojo", .lib = true },
        .{ .path = "src/komira_a/sub/__init__.mojo", .lib = true },
        .{ .path = "src/komira_a/_impl.mojo", .lib = false },
        .{ .path = "src/komira_a/_sub/m.mojo", .lib = false },
        .{ .path = "src/komira_a/tests/test_a.mojo", .lib = false },
        .{ .path = "src/tests/e2e/komira_c_e2e/plant.mojo", .lib = true },
        .{ .path = "src/tests/e2e/komira_c_e2e/tests/test_c.mojo", .lib = false },
        .{ .path = "src/tests/e2e/x.mojo", .lib = false },
        .{ .path = "tools/gen/main.mojo", .lib = false },
        .{ .path = "srcx/komira_a/m.mojo", .lib = false },
    };
    for (cases) |c| {
        const got = try pl.isLibFile(a, c.path, "src/");
        if (got != c.lib) std.debug.print("{s}: want {}, got {}\n", .{ c.path, c.lib, got });
        try testing.expectEqual(c.lib, got);
    }
}

test "a test file or a file outside the root has no public pointer" {
    const src = "def get(p: UnsafePointer[UInt8, o]) -> Int:\n    return 0\n";
    try expectSites("src/komira_a/tests/test_a.mojo", src, &.{});
    try expectSites("tools/gen/main.mojo", src, &.{});
    try expectSites("src/komira_b/__init__.mojo", src, &.{"1: public_pointer: def get(p: UnsafePointer[UInt8, o]) -> Int:"});
}

// ---- the ledgers ----

const tree_ffi =
    \\"""Owns the C handle."""
    \\# FFI-BOUNDARY: this module owns the handle and frees it in __del__.
    \\def _h(p: UnsafePointer[UInt8, MutAnyOrigin]):
    \\    pass
    \\
;
const tree_held =
    \\def _f(n: Int):
    \\    parallelize[_worker](n)
    \\    parallelize[_worker](n)
    \\
;

fn expectFindings(files: []const pl.File, ffi: []const u8, holds: []const u8, want: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try pl.check(arena.allocator(), .{
        .files = files,
        .public_root = "src",
        .ffi = ffi,
        .ffi_name = "F",
        .holds = holds,
        .holds_name = "H",
        .site_prefix = "P/",
    });
    if (got.len != want.len) {
        std.debug.print("want {d} findings, got {d}:\n", .{ want.len, got.len });
        for (got) |g| std.debug.print("  {s}\n", .{g});
        return error.TestUnexpectedResult;
    }
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

const tree = [_]pl.File{
    .{ .path = "src/komira_a/ffi.mojo", .contents = tree_ffi },
    .{ .path = "src/komira_a/held.mojo", .contents = tree_held },
};
const ffi_ok = "# the FFI modules\nsrc/komira_a/ffi.mojo\towns the C handle\n";
const holds_ok = "# holds\n\nparallelize\tsrc/komira_a/held.mojo\t2\tpredates the dispatcher\n";

test "every site held at its exact count, an FFI module's origins exempt: no finding" {
    try expectFindings(&tree, ffi_ok, holds_ok, &.{});
}

test "one site more than a row holds names every site and both counts" {
    const more = [_]pl.File{ tree[0], .{ .path = "src/komira_a/held.mojo", .contents = tree_held ++ "    parallelize[_w](n)\n" } };
    try expectFindings(&more, ffi_ok, holds_ok, &.{
        "P/src/komira_a/held.mojo:2: parallelize: parallelize[_worker](n) -- the standard library's parallelize[: run the work on a ParallelDispatch (3 sites, held 2)",
        "P/src/komira_a/held.mojo:3: parallelize: parallelize[_worker](n) -- the standard library's parallelize[: run the work on a ParallelDispatch (3 sites, held 2)",
        "P/src/komira_a/held.mojo:4: parallelize: parallelize[_w](n) -- the standard library's parallelize[: run the work on a ParallelDispatch (3 sites, held 2)",
    });
}

test "a site no row holds" {
    try expectFindings(&tree, ffi_ok, "", &.{
        "P/src/komira_a/held.mojo:2: parallelize: parallelize[_worker](n) -- the standard library's parallelize[: run the work on a ParallelDispatch",
        "P/src/komira_a/held.mojo:3: parallelize: parallelize[_worker](n) -- the standard library's parallelize[: run the work on a ParallelDispatch",
    });
}

test "a row above its sites is lowered or deleted" {
    try expectFindings(&tree, ffi_ok, "parallelize\tsrc/komira_a/held.mojo\t3\tr\nfrom_address\tsrc/komira_a/held.mojo\t1\tr\n", &.{
        "H:1: parallelize in src/komira_a/held.mojo is held at 3 and has 2: lower the count to 2",
        "H:2: from_address in src/komira_a/held.mojo is held at 1 and has 0: delete the row",
    });
}

test "a wildcard origin row for an FFI module holds nothing" {
    try expectFindings(&tree, ffi_ok, holds_ok ++ "wildcard_origin\tsrc/komira_a/ffi.mojo\t1\tr\n", &.{
        "H:4: wildcard_origin in src/komira_a/ffi.mojo is held at 1 and has 0: delete the row",
    });
}

test "a malformed hold row: fields, rule, file, count, reason, repeat" {
    try expectFindings(&tree, ffi_ok, holds_ok ++
        "parallelize\tsrc/komira_a/held.mojo\t2\n" ++
        "pointer_magic\tsrc/komira_a/held.mojo\t2\tr\n" ++
        "parallelize\tsrc/komira_a/gone.mojo\t2\tr\n" ++
        "from_address\tsrc/komira_a/held.mojo\t0\tr\n" ++
        "from_address\tsrc/komira_a/held.mojo\t1\t  \n" ++
        "parallelize\tsrc/komira_a/held.mojo\t2\tagain\n", &.{
        "H:4: a row has 4 tab-separated fields (rule, file, count, reason), not 3",
        "H:5: unknown rule `pointer_magic` (rules: wildcard_origin, from_address, partial_move, parallelize, libc_redeclare, public_pointer)",
        "H:6: src/komira_a/gone.mojo is not a .mojo file of the tree; delete the row",
        "H:7: count `0` is not a positive whole number",
        "H:8: empty reason: say why this file still holds the sites",
        "H:9: a second row for parallelize in src/komira_a/held.mojo",
    });
}

test "an FFI row: fields, file, reason, repeat, unmarked, no origin" {
    const more = [_]pl.File{
        tree[0],
        tree[1],
        .{ .path = "src/komira_a/clean.mojo", .contents = "# FFI-BOUNDARY: owns nothing yet.\ndef _f():\n    pass\n" },
        .{ .path = "src/komira_a/mention.mojo", .contents = "\"\"\"See the `# FFI-BOUNDARY:` comments.\"\"\"\ndef _f(p: UnsafePointer[UInt8, MutAnyOrigin]):\n    pass\n" },
    };
    try expectFindings(&more, ffi_ok ++
        "src/komira_a/held.mojo\n" ++
        "src/komira_a/gone.mojo\tr\n" ++
        "src/komira_a/clean.mojo\t \n" ++
        "src/komira_a/ffi.mojo\tagain\n" ++
        "src/komira_a/mention.mojo\tr\n" ++
        "src/komira_a/clean.mojo\tr\n", holds_ok, &.{
        "F:3: a row has 2 tab-separated fields (file, reason), not 1",
        "F:4: src/komira_a/gone.mojo is not a .mojo file of the tree; delete the row",
        "F:5: empty reason: say which foreign resource the module owns",
        "F:6: a second row for src/komira_a/ffi.mojo",
        "F:7: src/komira_a/mention.mojo carries no `# FFI-BOUNDARY:` comment line, so it is not an FFI module",
        "F:8: src/komira_a/clean.mojo names no wildcard origin; delete the row",
        "P/src/komira_a/mention.mojo:2: wildcard_origin: def _f(p: UnsafePointer[UInt8, MutAnyOrigin]): -- a wildcard origin outside a module's FFI internals",
    });
}

test "a marker line is read raw: one inside a docstring marks the module" {
    const more = [_]pl.File{
        .{ .path = "src/komira_a/ffi.mojo", .contents = "def _h(p: UnsafePointer[UInt8, MutAnyOrigin]):\n    \"\"\"Calls C.\n\n    # FFI-BOUNDARY: owns the handle.\n    \"\"\"\n" },
        tree[1],
    };
    try expectFindings(&more, ffi_ok, holds_ok, &.{});
}

test "an FFI module's other sites are sites" {
    const more = [_]pl.File{ .{ .path = "src/komira_a/ffi.mojo", .contents = tree_ffi ++ "def _g(a: Int):\n    var p = UnsafePointer[UInt8, o](unsafe_from_address=a)\n" }, tree[1] };
    try expectFindings(&more, ffi_ok, holds_ok, &.{
        "P/src/komira_a/ffi.mojo:6: from_address: var p = UnsafePointer[UInt8, o](unsafe_from_address=a) -- a pointer made from an integer (unsafe_from_address=)",
    });
}

// ---- the result ----

test "the report names the stage by the prefix and says when nothing was read" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = try pl.report(a, &.{ "out/tree/src/a.mojo:1: x", "H:2: y" }, "out/tree/", "komira//", 1);
    try testing.expectEqualStrings("komira//src/a.mojo:1: x", lines[0]);
    try testing.expectEqualStrings("H:2: y", lines[1]);
    const none = try pl.report(a, &.{}, "out/tree/", "komira//", 0);
    try testing.expectEqual(@as(usize, 1), none.len);
    try testing.expectEqualStrings("pointer_lint: checked nothing (no inputs, or no lines to check)", none[0]);
}

test "the result: success with the count, or failure with escaped lines, at most 200" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "{\"version\": 1, \"data\": {\"status\": \"success\", \"message\": \"pointer_lint: 7 checked\"}}\n",
        try pl.resultJson(a, &.{}, 7),
    );
    try testing.expectEqualStrings(
        "{\"version\": 1, \"data\": {\"status\": \"failure\", \"message\": \"pointer_lint: 1 finding line(s)\\na\\\\b\\\"c\\td\\n\"}}\n",
        try pl.resultJson(a, &.{"a\\b\"c\td\x01"}, 7),
    );
    var many: [250][]const u8 = undefined;
    for (&many) |*l| l.* = "x";
    const big = try pl.resultJson(a, &many, 1);
    try testing.expect(std.mem.indexOf(u8, big, "250 finding line(s)") != null);
    try testing.expectEqual(@as(usize, 200), std.mem.count(u8, big, "x\\n"));
}
