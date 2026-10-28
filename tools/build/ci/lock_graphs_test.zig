//! Unit tests of lock_graphs.zig: which subdirs a mopm.lock asks graphs for, and each finding. The whole check,
//! over every package of the repository, is the pull request check's `buck2 bxl tools/build/ci/lock_graphs.bxl:check`.
const std = @import("std");
const L = @import("lock_graphs.zig");
const t = std.testing;

const lock_three =
    \\{"toolchain": {"1.0.0": {"linux-64": "aa", "linux-aarch64": "bb", "osx-arm64": "cc"}}}
;
const lock_one =
    \\{"toolchain": {"1.0.0": {"linux-64": "aa"}}}
;

fn findings(a: std.mem.Allocator, text: []const u8, held: []const u8) ![]const []const u8 {
    return L.check(a, .{ .label = "komira//src/komira_x:table", .mojo = "1.0.0", .lock_path = "src/komira_x/mopm.lock", .held_csv = held }, text);
}

test "a table that holds exactly the subdirs its lock records is clean, for one platform and for three" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    try t.expectEqual(@as(usize, 0), (try findings(ar.allocator(), lock_one, "")).len);
    try t.expectEqual(@as(usize, 0), (try findings(ar.allocator(), lock_three, "linux-aarch64,osx-arm64")).len);
    // the order the table lists them in does not matter
    try t.expectEqual(@as(usize, 0), (try findings(ar.allocator(), lock_three, "osx-arm64,linux-aarch64")).len);
}

test "a graph deleted from the table is a finding that names the package and the subdir" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const f = try findings(a, lock_three, "linux-aarch64");
    try t.expectEqual(@as(usize, 1), f.len);
    try t.expect(std.mem.indexOf(u8, f[0], "komira//src/komira_x:table") != null);
    try t.expect(std.mem.indexOf(u8, f[0], "osx-arm64") != null);
    try t.expect(std.mem.indexOf(u8, f[0], "holds no graph") != null);
    const g = try findings(a, lock_three, "osx-arm64");
    try t.expectEqual(@as(usize, 1), g.len);
    try t.expect(std.mem.indexOf(u8, g[0], "linux-aarch64") != null);
    // both gone: one finding each
    try t.expectEqual(@as(usize, 2), (try findings(a, lock_three, "")).len);
}

test "a graph the lock does not record is a finding" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const f = try findings(a, lock_one, "osx-arm64");
    try t.expectEqual(@as(usize, 1), f.len);
    try t.expect(std.mem.indexOf(u8, f[0], "holds a graph for osx-arm64") != null);
    try t.expect(std.mem.indexOf(u8, f[0], "records no toolchain") != null);
}

test "only the Mojo version the package builds with counts" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const text =
        \\{"toolchain": {"0.9.0": {"linux-64": "aa", "osx-arm64": "cc"}, "1.0.0": {"linux-64": "aa"}}}
    ;
    try t.expectEqual(@as(usize, 0), (try findings(ar.allocator(), text, "")).len);
}

test "a subdir sync does not plan for is ignored, as sync ignores it" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const text =
        \\{"toolchain": {"1.0.0": {"linux-64": "aa", "linux-ppc64le": "dd"}}}
    ;
    try t.expectEqual(@as(usize, 0), (try findings(ar.allocator(), text, "")).len);
}

test "a lock that cannot say is a finding, never a pass" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const bad = [_][]const u8{
        "not json",
        "[1]",
        "{}",
        "{\"toolchain\": 3}",
        "{\"toolchain\": {}}",
        "{\"toolchain\": {\"1.0.0\": \"x\"}}",
    };
    for (bad) |text| {
        const f = try findings(a, text, "");
        try t.expectEqual(@as(usize, 1), f.len);
        try t.expect(std.mem.indexOf(u8, f[0], "komira//src/komira_x:table") != null);
        try t.expect(std.mem.indexOf(u8, f[0], "unusable") != null);
    }
}

// The system libraries of a package: a declared load must be pinned in its lock, a source that opens a library must be declared.

const lock_pinned_three =
    \\{"toolchain": {"1.0.0": {"linux-64": "aa", "linux-aarch64": "bb", "osx-arm64": "cc"}},
    \\ "system_libs": {"linux-64": [{"name": "lz4-c"}], "linux-aarch64": [{"name": "lz4-c"}], "osx-arm64": [{"name": "lz4-c"}]}}
;

fn libFindings(a: std.mem.Allocator, lock: []const u8, declared: bool, opens: bool) ![]const []const u8 {
    return L.checkSystemLibs(a, "komira//src/komira_x:table", "1.0.0", lock, declared, opens);
}

test "declaresLoad reads only the native-dependencies table and only mode load" {
    try t.expect(L.declaresLoad("[package]\nname = \"x\"\n\n[native-dependencies]\nlz4 = { version = \">=1.9.3,<2\", kind = \"shared\", mode = \"load\" }\n"));
    try t.expect(L.declaresLoad("[native-dependencies]\nlz4={version=\"1\",mode=\"load\"}\n"));
    // a link-mode dependency, a comment, a load word in another table and a package with none are not loads
    try t.expect(!L.declaresLoad("[native-dependencies]\nlz4 = { version = \"1\", kind = \"static\", mode = \"link\" }\n"));
    try t.expect(!L.declaresLoad("[native-dependencies]\n# lz4 = { mode = \"load\" }\n"));
    try t.expect(!L.declaresLoad("[package]\ndescription = \"mode = \\\"load\\\"\"\n[native-dependencies]\n"));
    try t.expect(!L.declaresLoad("[package]\nname = \"x\"\n"));
}

test "opensLibrary sees a call and ignores a comment that names one" {
    try t.expect(L.opensLibrary("var h = OwnedDLHandle(\"libsnappy.so.1\")\n"));
    try t.expect(L.opensLibrary("    var h = DLHandle(path)\n"));
    try t.expect(L.opensLibrary("x = dlopen(name, 2)\n"));
    try t.expect(!L.opensLibrary("# opened at run time with OwnedDLHandle(...)\n"));
    try t.expect(!L.opensLibrary("from std.ffi import OwnedDLHandle\n"));
}

test "a package that loads no library and opens none is clean whatever its lock holds" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    try t.expectEqual(@as(usize, 0), (try libFindings(ar.allocator(), lock_three, false, false)).len);
    try t.expectEqual(@as(usize, 0), (try libFindings(ar.allocator(), lock_pinned_three, false, false)).len);
}

test "a declared load whose lock pins every recorded subdir is clean" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    try t.expectEqual(@as(usize, 0), (try libFindings(ar.allocator(), lock_pinned_three, true, true)).len);
    const one =
        \\{"toolchain": {"1.0.0": {"linux-64": "aa"}}, "system_libs": {"linux-64": [{"name": "lz4-c"}]}}
    ;
    try t.expectEqual(@as(usize, 0), (try libFindings(ar.allocator(), one, true, true)).len);
}

test "a declared load with no system_libs in the lock is one finding that names the package and the mopm to use" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const f = try libFindings(ar.allocator(), lock_three, true, true);
    try t.expectEqual(@as(usize, 1), f.len);
    try t.expect(std.mem.indexOf(u8, f[0], "komira//src/komira_x:table") != null);
    try t.expect(std.mem.indexOf(u8, f[0], "has no `system_libs`") != null);
    try t.expect(std.mem.indexOf(u8, f[0], "0.0.83") != null);
}

test "a subdir the lock records and system_libs does not pin is a finding for that subdir" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const missing_mac =
        \\{"toolchain": {"1.0.0": {"linux-64": "aa", "linux-aarch64": "bb", "osx-arm64": "cc"}},
        \\ "system_libs": {"linux-64": [{"name": "lz4-c"}], "linux-aarch64": [{"name": "lz4-c"}]}}
    ;
    const f = try libFindings(a, missing_mac, true, true);
    try t.expectEqual(@as(usize, 1), f.len);
    try t.expect(std.mem.indexOf(u8, f[0], "osx-arm64") != null);
    const empty_linux =
        \\{"toolchain": {"1.0.0": {"linux-64": "aa"}}, "system_libs": {"linux-64": []}}
    ;
    const g = try libFindings(a, empty_linux, true, true);
    try t.expectEqual(@as(usize, 1), g.len);
    try t.expect(std.mem.indexOf(u8, g[0], "linux-64") != null);
    const not_object =
        \\{"toolchain": {"1.0.0": {"linux-64": "aa"}}, "system_libs": 3}
    ;
    try t.expectEqual(@as(usize, 1), (try libFindings(a, not_object, true, true)).len);
}

test "a source that opens a library with no declared load is a finding, whatever the lock holds" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const f = try libFindings(a, lock_three, false, true);
    try t.expectEqual(@as(usize, 1), f.len);
    try t.expect(std.mem.indexOf(u8, f[0], "opens a shared library") != null);
    try t.expectEqual(@as(usize, 1), (try libFindings(a, lock_pinned_three, false, true)).len);
}

test "a lock that is not JSON adds no system-library finding: the toolchain finding already says it is unusable" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    try t.expectEqual(@as(usize, 0), (try libFindings(ar.allocator(), "not json", true, false)).len);
}

test "scanPackage reads the manifest, a path dependency's manifest and the sources" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("pkg/src/pkg");
    try tmp.dir.makePath("dep");
    try tmp.dir.writeFile(.{ .sub_path = "pkg/mopm.toml", .data = "[package]\nname = \"pkg\"\n" });
    try tmp.dir.writeFile(.{ .sub_path = "pkg/src/pkg/a.mojo", .data = "# OwnedDLHandle(\"x\") in a comment\nfn f():\n    pass\n" });
    try tmp.dir.writeFile(.{ .sub_path = "dep/mopm.toml", .data = "[native-dependencies]\nsnappy = { mode = \"load\" }\n" });
    const root = try tmp.dir.realpathAlloc(a, ".");
    const dir = try std.fmt.allocPrint(a, "{s}/pkg", .{root});
    const lock_dep =
        \\{"packages": [{"name": "dep", "version": "0.1.0", "source": "path", "path": "../dep"}]}
    ;
    var declared = false;
    var opens = false;
    try L.scanPackage(a, dir, "{\"packages\": []}", &declared, &opens);
    try t.expect(!declared and !opens);
    // the dependency's manifest counts when the lock records it as a path package
    try L.scanPackage(a, dir, lock_dep, &declared, &opens);
    try t.expect(declared and !opens);
    // a source that calls it counts
    try tmp.dir.writeFile(.{ .sub_path = "pkg/src/pkg/b.mojo", .data = "var h = OwnedDLHandle(\"libsnappy.so.1\")\n" });
    declared = false;
    try L.scanPackage(a, dir, "{\"packages\": []}", &declared, &opens);
    try t.expect(!declared and opens);
}
